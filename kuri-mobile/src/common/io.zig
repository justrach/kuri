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

/// Run a command for a bounded time, then interrupt it and collect output.
///
/// Some tools have no natural end — `simctl io … recordVideo` runs until it
/// receives SIGINT, at which point it finalises the file. `runCommand` would
/// block forever on those. The interrupt has to be a *graceful* SIGINT rather
/// than SIGKILL, or the recording is left truncated and unplayable.
///
/// Output is drained after the signal rather than concurrently: the commands
/// this is used for emit only a few lines, so the pipe buffer cannot fill.
pub fn runCommandFor(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    duration_ms: u64,
    max_output: usize,
) !struct { stdout: []u8, term: i32 } {
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

    sleepMs(duration_ms);
    _ = std.c.kill(pid, std.c.SIG.INT);

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

extern "c" fn clock_gettime(clk_id: std.c.clockid_t, tp: *std.c.timespec) c_int;

/// Milliseconds from an arbitrary monotonic origin — for measuring deadlines.
///
/// std.time carries only unit constants now, and a wall clock would let an NTP
/// step turn a bounded wait into an unbounded one, so this reads CLOCK_MONOTONIC
/// through libc like the rest of this file.
pub fn monotonicMs() i64 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    if (clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

pub fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}

/// Read a whole file into an allocated slice. Caller frees.
///
/// Needed because `devicectl` never writes JSON to stdout — its only
/// machine-readable channel is `--json-output <path>`, so reading it back off
/// disk is the entire structured-output path for real devices.
pub fn readFile(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return error.NameTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = std.c.open(pbuf[0..path.len :0], .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        const bytes: usize = @intCast(n);
        if (out.items.len + bytes > max_bytes) return error.FileTooLarge;
        try out.appendSlice(allocator, buf[0..bytes]);
    }
    return out.toOwnedSlice(allocator);
}

/// Best-effort unlink, for scratch files whose removal is not worth an error.
pub fn removeFile(path: []const u8) void {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    _ = std.c.unlink(pbuf[0..path.len :0]);
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
