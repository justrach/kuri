//! Native Zig client for usbmuxd (`/var/run/usbmuxd` Unix domain socket).
//!
//! usbmuxd is the macOS daemon that multiplexes connections to attached
//! iOS devices over USB. We speak its plist-based message protocol to
//! enumerate paired devices. Service-level access (lockdownd, instruments,
//! XCUITest) requires a TLS handshake with a per-device pairing record
//! and is intentionally NOT implemented here in v1 — we delegate that to
//! Apple's `xcrun devicectl` for now and document this as a v2 follow-up.
//!
//! Reference: https://github.com/libimobiledevice/usbmuxd/blob/master/docs/protocol.md

const std = @import("std");
const posix = std.posix;

pub const socket_path = "/var/run/usbmuxd";

const c_connect = @extern(*const fn (std.c.fd_t, *const anyopaque, posix.socklen_t) callconv(.c) c_int, .{ .name = "connect" });

pub const Header = extern struct {
    length: u32,
    version: u32,
    message: u32,
    tag: u32,
};

pub const message_plist: u32 = 8;
pub const protocol_version: u32 = 1;

pub const Device = struct {
    udid: []const u8,
    device_id: u32,
    product_id: u32,
    connection: []const u8, // "USB" / "Network"
};

pub fn freeDevices(gpa: std.mem.Allocator, devs: []const Device) void {
    for (devs) |d| {
        gpa.free(d.udid);
        gpa.free(d.connection);
    }
    gpa.free(devs);
}

/// Connect to usbmuxd and return the list of currently attached devices.
/// Returns an empty slice if the socket is missing (no Xcode / not macOS).
pub fn listDevices(gpa: std.mem.Allocator) ![]Device {
    const raw_fd = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (raw_fd < 0) return &.{};
    const fd: std.c.fd_t = raw_fd;
    defer _ = std.c.close(fd);

    var addr: posix.sockaddr.un = std.mem.zeroes(posix.sockaddr.un);
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    if (c_connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0) return &.{};

    const request_plist =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0"><dict>
        \\<key>MessageType</key><string>ListDevices</string>
        \\<key>ProgName</key><string>kuri-mobile</string>
        \\<key>ClientVersionString</key><string>0.0.1</string>
        \\</dict></plist>
    ;

    var hdr: Header = .{
        .length = @intCast(@sizeOf(Header) + request_plist.len),
        .version = protocol_version,
        .message = message_plist,
        .tag = 1,
    };
    try writeAll(fd, std.mem.asBytes(&hdr));
    try writeAll(fd, request_plist);

    // Read response header.
    var resp_hdr: Header = undefined;
    try readExact(fd, std.mem.asBytes(&resp_hdr));
    if (resp_hdr.length < @sizeOf(Header)) return error.UsbmuxProtocolError;
    const body_len = resp_hdr.length - @sizeOf(Header);
    const body = try gpa.alloc(u8, body_len);
    defer gpa.free(body);
    try readExact(fd, body);

    // Parse the response plist via a tiny scanner — avoids pulling in a
    // CoreFoundation/plist dependency for a single message type.
    return try parseListResponse(gpa, body);
}

fn readExact(fd: std.c.fd_t, dst: []u8) !void {
    var off: usize = 0;
    while (off < dst.len) {
        const n = std.c.read(fd, dst[off..].ptr, dst.len - off);
        if (n <= 0) return error.UnexpectedEof;
        off += @intCast(n);
    }
}

fn writeAll(fd: std.c.fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data[off..].ptr, data.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

/// Extract <key>SerialNumber</key><string>...</string> and friends from
/// each <dict> inside the DeviceList array. Pragmatic and good enough
/// for plain XML plists (which is what usbmuxd emits).
fn parseListResponse(gpa: std.mem.Allocator, xml: []const u8) ![]Device {
    var list: std.ArrayList(Device) = .empty;
    errdefer freeDevicesArrayList(gpa, &list);

    // Walk DeviceList array, bracketed by <array>...</array> after the
    // "DeviceList" key.
    const dl_key = "<key>DeviceList</key>";
    const dl_pos = std.mem.indexOf(u8, xml, dl_key) orelse return try list.toOwnedSlice(gpa);
    const arr_start = std.mem.indexOfPos(u8, xml, dl_pos, "<array>") orelse return try list.toOwnedSlice(gpa);
    const arr_end = std.mem.indexOfPos(u8, xml, arr_start, "</array>") orelse return try list.toOwnedSlice(gpa);
    const region = xml[arr_start..arr_end];

    var i: usize = 0;
    while (std.mem.indexOfPos(u8, region, i, "<dict>")) |dict_start| {
        const dict_end = std.mem.indexOfPos(u8, region, dict_start, "</dict>") orelse break;
        const dict_xml = region[dict_start..dict_end];
        const props = std.mem.indexOf(u8, dict_xml, "<key>Properties</key>");
        const target = if (props) |p| dict_xml[p..] else dict_xml;

        const udid = extractString(target, "SerialNumber") orelse {
            i = dict_end + 7;
            continue;
        };
        const conn = extractString(target, "ConnectionType") orelse "USB";
        const did = extractInteger(target, "DeviceID") orelse 0;
        const pid = extractInteger(target, "ProductID") orelse 0;

        try list.append(gpa, .{
            .udid = try gpa.dupe(u8, udid),
            .device_id = @intCast(did),
            .product_id = @intCast(pid),
            .connection = try gpa.dupe(u8, conn),
        });
        i = dict_end + 7;
    }
    return try list.toOwnedSlice(gpa);
}

fn freeDevicesArrayList(gpa: std.mem.Allocator, list: *std.ArrayList(Device)) void {
    for (list.items) |d| {
        gpa.free(d.udid);
        gpa.free(d.connection);
    }
    list.deinit(gpa);
}

fn extractString(xml: []const u8, key: []const u8) ?[]const u8 {
    var key_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&key_buf, "<key>{s}</key>", .{key}) catch return null;
    const k = std.mem.indexOf(u8, xml, needle) orelse return null;
    const s = std.mem.indexOfPos(u8, xml, k, "<string>") orelse return null;
    const e = std.mem.indexOfPos(u8, xml, s, "</string>") orelse return null;
    return xml[s + "<string>".len .. e];
}

fn extractInteger(xml: []const u8, key: []const u8) ?u64 {
    var key_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&key_buf, "<key>{s}</key>", .{key}) catch return null;
    const k = std.mem.indexOf(u8, xml, needle) orelse return null;
    const s = std.mem.indexOfPos(u8, xml, k, "<integer>") orelse return null;
    const e = std.mem.indexOfPos(u8, xml, s, "</integer>") orelse return null;
    return std.fmt.parseInt(u64, xml[s + "<integer>".len .. e], 10) catch null;
}

test "extractString picks correct value" {
    const xml = "<dict><key>SerialNumber</key><string>00008030-001234567890002E</string></dict>";
    try std.testing.expectEqualStrings("00008030-001234567890002E", extractString(xml, "SerialNumber").?);
}

test "parseListResponse handles empty DeviceList" {
    const xml =
        \\<plist><dict><key>DeviceList</key><array></array></dict></plist>
    ;
    const devs = try parseListResponse(std.testing.allocator, xml);
    defer freeDevices(std.testing.allocator, devs);
    try std.testing.expectEqual(@as(usize, 0), devs.len);
}

test "parseListResponse extracts one device" {
    const xml =
        \\<plist><dict>
        \\<key>DeviceList</key><array>
        \\<dict><key>DeviceID</key><integer>5</integer>
        \\<key>MessageType</key><string>Attached</string>
        \\<key>Properties</key><dict>
        \\<key>ConnectionType</key><string>USB</string>
        \\<key>DeviceID</key><integer>5</integer>
        \\<key>ProductID</key><integer>4776</integer>
        \\<key>SerialNumber</key><string>00008030-ABCDEF01234567</string>
        \\</dict></dict>
        \\</array></dict></plist>
    ;
    const devs = try parseListResponse(std.testing.allocator, xml);
    defer freeDevices(std.testing.allocator, devs);
    try std.testing.expectEqual(@as(usize, 1), devs.len);
    try std.testing.expectEqualStrings("00008030-ABCDEF01234567", devs[0].udid);
    try std.testing.expectEqualStrings("USB", devs[0].connection);
    try std.testing.expectEqual(@as(u32, 5), devs[0].device_id);
    try std.testing.expectEqual(@as(u32, 4776), devs[0].product_id);
}
