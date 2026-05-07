//! Tiny libc-backed stdout/stderr helpers, mirroring kuri's compat.zig.
//! Zig 0.16 removed std.fs.File from the public std API surface we used,
//! so we go straight to libc.

const std = @import("std");

pub fn writeStdout(data: []const u8) void {
    write_fd(1, data);
}

pub fn writeStderr(data: []const u8) void {
    write_fd(2, data);
}

fn write_fd(fd: c_int, data: []const u8) void {
    var sent: usize = 0;
    while (sent < data.len) {
        const n = std.c.write(fd, data[sent..].ptr, data.len - sent);
        if (n <= 0) break;
        sent += @intCast(n);
    }
}

/// Like std.debug.print but to stdout. Allocates with arena.
pub fn printStdout(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(arena, fmt, args) catch return;
    writeStdout(s);
}

pub fn printStderr(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(arena, fmt, args) catch return;
    writeStderr(s);
}

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// Run a command and capture stdout (+stderr) as a single allocated slice.
/// Mirrors kuri/src/compat.zig::runCommand.
pub fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, max_output: usize) !struct { stdout: []u8, term: i32 } {
    var arg_storage: std.ArrayList([:0]u8) = .empty;
    defer {
        for (arg_storage.items) |arg| allocator.free(arg);
        arg_storage.deinit(allocator);
    }
    for (argv) |arg| {
        const duped = try allocator.allocSentinel(u8, arg.len, 0);
        @memcpy(duped[0..arg.len], arg);
        try arg_storage.append(allocator, duped);
    }

    const c_argv = try allocator.alloc(?[*:0]const u8, arg_storage.items.len + 1);
    defer allocator.free(c_argv);
    for (arg_storage.items, 0..) |arg, i| c_argv[i] = arg.ptr;
    c_argv[arg_storage.items.len] = null;

    var pipe_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeCreateFailed;

    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.dup2(pipe_fds[1], 1);
        _ = std.c.dup2(pipe_fds[1], 2);
        _ = std.c.close(pipe_fds[1]);
        _ = execvp(c_argv[0].?, @ptrCast(c_argv.ptr));
        std.c._exit(127);
    }

    _ = std.c.close(pipe_fds[1]);
    defer _ = std.c.close(pipe_fds[0]);

    var result: std.ArrayList(u8) = .empty;
    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(pipe_fds[0], &read_buf, read_buf.len);
        if (n <= 0) break;
        const bytes: usize = @intCast(n);
        if (result.items.len + bytes > max_output) break;
        try result.appendSlice(allocator, read_buf[0..bytes]);
    }

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    return .{ .stdout = try result.toOwnedSlice(allocator), .term = @intCast(status) };
}

/// Write bytes to a file path (overwriting). Uses libc to avoid std.fs.File.
pub fn writeFile(path: []const u8, data: []const u8) !void {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return error.NameTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = std.c.open(pbuf[0..path.len :0], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    var sent: usize = 0;
    while (sent < data.len) {
        const n = std.c.write(fd, data[sent..].ptr, data.len - sent);
        if (n <= 0) return error.WriteFailed;
        sent += @intCast(n);
    }
}
