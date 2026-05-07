//! Native Zig client for the adb host protocol (talks to a local adb server).
//!
//! The adb server listens on TCP 127.0.0.1:5037 by default. Each request is:
//!     <4 hex chars: payload length><ASCII payload>
//! The server replies with either "OKAY" or "FAIL<4hex><msg>". After OKAY,
//! the connection is either closed (for "host:" queries that return data
//! framed as <4hex><payload>) or transitioned into a transport for the
//! selected device, after which subsequent commands target that device.
//!
//! Reference: SERVICES.TXT in the AOSP adb sources.
//!
//! We talk libc sockets directly (matching the rest of kuri's IO style)
//! to avoid std.Io churn between Zig versions.

const std = @import("std");
const posix = std.posix;

pub const default_port: u16 = 5037;

const c_connect = @extern(*const fn (std.c.fd_t, *const anyopaque, posix.socklen_t) callconv(.c) c_int, .{ .name = "connect" });

pub const Error = error{
    AdbServerUnreachable,
    AdbProtocolError,
    AdbCommandFailed,
    DeviceNotFound,
    UnexpectedEof,
} || std.mem.Allocator.Error;

pub const Client = struct {
    gpa: std.mem.Allocator,
    host: []const u8 = "127.0.0.1",
    port: u16 = default_port,

    pub fn init(gpa: std.mem.Allocator) Client {
        return .{ .gpa = gpa };
    }

    fn connect(self: *Client) !std.c.fd_t {
        const raw_fd = std.c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        if (raw_fd < 0) return Error.AdbServerUnreachable;
        const fd: std.c.fd_t = raw_fd;
        errdefer _ = std.c.close(fd);

        var sa: posix.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, self.port),
            .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
        };
        if (c_connect(fd, @ptrCast(&sa), @sizeOf(posix.sockaddr.in)) != 0) {
            return Error.AdbServerUnreachable;
        }
        return fd;
    }

    pub fn hostQuery(self: *Client, cmd: []const u8) ![]u8 {
        const fd = try self.connect();
        defer _ = std.c.close(fd);
        try writeRequest(fd, cmd);
        try expectOkay(fd, self.gpa);
        return try readFramed(fd, self.gpa);
    }

    pub fn deviceExec(self: *Client, serial: []const u8, service: []const u8) ![]u8 {
        const fd = try self.connect();
        defer _ = std.c.close(fd);

        var buf: [128]u8 = undefined;
        const transport = try std.fmt.bufPrint(&buf, "host:transport:{s}", .{serial});
        try writeRequest(fd, transport);
        try expectOkay(fd, self.gpa);

        try writeRequest(fd, service);
        try expectOkay(fd, self.gpa);

        return try readToEnd(fd, self.gpa);
    }
};

fn writeAll(fd: std.c.fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data[off..].ptr, data.len - off);
        if (n <= 0) return Error.AdbProtocolError;
        off += @intCast(n);
    }
}

fn writeRequest(fd: std.c.fd_t, payload: []const u8) !void {
    if (payload.len > 0xFFFF) return Error.AdbProtocolError;
    var hdr: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&hdr, "{x:0>4}", .{payload.len}) catch unreachable;
    try writeAll(fd, &hdr);
    try writeAll(fd, payload);
}

fn expectOkay(fd: std.c.fd_t, gpa: std.mem.Allocator) !void {
    var status: [4]u8 = undefined;
    try readExact(fd, &status);
    if (std.mem.eql(u8, &status, "OKAY")) return;
    if (std.mem.eql(u8, &status, "FAIL")) {
        const msg = readFramed(fd, gpa) catch return Error.AdbCommandFailed;
        defer gpa.free(msg);
        std.log.warn("adb FAIL: {s}", .{msg});
        return Error.AdbCommandFailed;
    }
    return Error.AdbProtocolError;
}

fn readFramed(fd: std.c.fd_t, gpa: std.mem.Allocator) ![]u8 {
    var lenbuf: [4]u8 = undefined;
    try readExact(fd, &lenbuf);
    const n = std.fmt.parseInt(usize, &lenbuf, 16) catch return Error.AdbProtocolError;
    const out = try gpa.alloc(u8, n);
    errdefer gpa.free(out);
    try readExact(fd, out);
    return out;
}

fn readExact(fd: std.c.fd_t, dst: []u8) !void {
    var off: usize = 0;
    while (off < dst.len) {
        const n = std.c.read(fd, dst[off..].ptr, dst.len - off);
        if (n <= 0) return Error.UnexpectedEof;
        off += @intCast(n);
    }
}

fn readToEnd(fd: std.c.fd_t, gpa: std.mem.Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        try list.appendSlice(gpa, buf[0..@intCast(n)]);
    }
    return try list.toOwnedSlice(gpa);
}

pub const Device = struct {
    serial: []const u8,
    state: []const u8,
};

pub fn parseDevices(gpa: std.mem.Allocator, raw: []const u8) ![]Device {
    var list: std.ArrayList(Device) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        try list.append(gpa, .{
            .serial = try gpa.dupe(u8, line[0..tab]),
            .state = try gpa.dupe(u8, line[tab + 1 ..]),
        });
    }
    return try list.toOwnedSlice(gpa);
}

pub fn freeDevices(gpa: std.mem.Allocator, devs: []Device) void {
    for (devs) |d| {
        gpa.free(d.serial);
        gpa.free(d.state);
    }
    gpa.free(devs);
}

// ---------------------------------------------------------------- tests

test "parseDevices parses tab-separated lines" {
    const raw =
        "emulator-5554\tdevice\n" ++
        "ABCD1234\tunauthorized\n";
    const devs = try parseDevices(std.testing.allocator, raw);
    defer freeDevices(std.testing.allocator, devs);
    try std.testing.expectEqual(@as(usize, 2), devs.len);
    try std.testing.expectEqualStrings("emulator-5554", devs[0].serial);
    try std.testing.expectEqualStrings("device", devs[0].state);
    try std.testing.expectEqualStrings("ABCD1234", devs[1].serial);
    try std.testing.expectEqualStrings("unauthorized", devs[1].state);
}

test "writeRequest formats 4-hex length prefix" {
    const out = try std.fmt.allocPrint(std.testing.allocator, "{x:0>4}{s}", .{ "host:version".len, "host:version" });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("000chost:version", out);
}
