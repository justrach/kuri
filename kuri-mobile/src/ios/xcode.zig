//! Locating and invoking the active Xcode toolchain.
//!
//! Everything iOS-side used to shell out to bare `xcrun`, which resolves
//! through `xcode-select`. On a machine where `xcode-select -p` points at
//! /Library/Developer/CommandLineTools — a common state, and the default
//! after installing CLT — there is no `simctl` there, so `xcrun` fails with
//! "unable to find utility". Because `runCommand` only reports *captured
//! output* and never the exit status, that failure surfaced as an empty
//! stdout, which `listDevices` then parsed into zero devices. The user saw
//! `kuri ios list-devices` exit 0 with no output: a harness silently
//! reporting "no devices" when the real answer is "Xcode isn't selected".
//!
//! So we resolve a developer directory that actually carries `simctl` and
//! invoke its tools by absolute path, bypassing `xcrun` entirely. Exit
//! statuses are checked, and failures carry the tool's own diagnostic.

const std = @import("std");
const io = @import("../common/io.zig");

/// Resolved once per process; a CLI run never needs to re-probe.
///
/// Held in a static buffer rather than an allocation on purpose: the value
/// lives for the whole process, so an allocated cache is a leak by
/// construction, and the DebugAllocator would print a stack trace on every
/// single command. Nothing to free, nothing to report.
var cached_buf: [4096]u8 = undefined;
var cached_len: usize = 0;
var cached_set: bool = false;

fn getEnv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

/// Existence probe via `open`, matching the libc-only idiom the rest of
/// kuri-mobile uses (Zig 0.16 pared back the std.fs surface we'd want).
fn fileExists(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const fd = std.c.open(buf[0..path.len :0], .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return false;
    _ = std.c.close(fd);
    return true;
}

/// A developer dir only counts if it actually carries `simctl`. This is the
/// exact check that distinguishes a real Xcode.app from CommandLineTools.
fn carriesSimctl(gpa: std.mem.Allocator, dir: []const u8) bool {
    const p = std.fmt.allocPrint(gpa, "{s}/usr/bin/simctl", .{dir}) catch return false;
    defer gpa.free(p);
    return fileExists(p);
}

fn cache(dir: []const u8) ![]const u8 {
    if (dir.len > cached_buf.len) return error.XcodeNotFound;
    @memcpy(cached_buf[0..dir.len], dir);
    cached_len = dir.len;
    cached_set = true;
    return cached_buf[0..cached_len];
}

/// Resolve a developer directory containing a usable `simctl`.
pub fn developerDir(gpa: std.mem.Allocator) ![]const u8 {
    if (cached_set) return cached_buf[0..cached_len];

    // 1. An explicit DEVELOPER_DIR override always wins.
    if (getEnv("DEVELOPER_DIR")) |d| {
        if (carriesSimctl(gpa, d)) return cache(d);
    }

    // 2. Whatever xcode-select points at — accepted only if it has simctl,
    //    which is what rejects a CommandLineTools-only selection.
    if (io.runCommand(gpa, &.{ "xcode-select", "-p" }, 4096)) |r| {
        defer gpa.free(r.stdout);
        const trimmed = std.mem.trim(u8, r.stdout, " \t\r\n");
        if (trimmed.len > 0 and carriesSimctl(gpa, trimmed)) return cache(trimmed);
    } else |_| {}

    // 3. Fall back to a normally-installed Xcode, so the common
    //    "CLT is selected but Xcode.app is right there" case just works.
    const candidates = [_][]const u8{
        "/Applications/Xcode.app/Contents/Developer",
        "/Applications/Xcode-beta.app/Contents/Developer",
    };
    for (candidates) |cand| {
        if (carriesSimctl(gpa, cand)) return cache(cand);
    }

    return error.XcodeNotFound;
}

/// Absolute path to a tool in the resolved toolchain. Caller frees.
pub fn toolPath(gpa: std.mem.Allocator, tool: []const u8) ![]const u8 {
    const dir = try developerDir(gpa);
    return std.fmt.allocPrint(gpa, "{s}/usr/bin/{s}", .{ dir, tool });
}

/// Decode a waitpid status into an exit code.
fn exitCode(term: i32) i32 {
    return (term >> 8) & 0xFF;
}

fn buildArgv(
    gpa: std.mem.Allocator,
    path: []const u8,
    argv: []const []const u8,
) !std.ArrayList([]const u8) {
    var full: std.ArrayList([]const u8) = .empty;
    errdefer full.deinit(gpa);
    try full.append(gpa, path);
    try full.appendSlice(gpa, argv);
    return full;
}

/// Run an Xcode tool and check its exit status. Returns captured output on
/// success; on failure prints the tool's own diagnostic and returns
/// error.CommandFailed. `runCommand` merges stderr into stdout, so that
/// captured text *is* the diagnostic.
pub fn run(
    gpa: std.mem.Allocator,
    tool: []const u8,
    argv: []const []const u8,
    max_output: usize,
) ![]u8 {
    const path = try toolPath(gpa, tool);
    defer gpa.free(path);

    var full = try buildArgv(gpa, path, argv);
    defer full.deinit(gpa);

    const r = try io.runCommand(gpa, full.items, max_output);
    const code = exitCode(r.term);
    if (code != 0) {
        defer gpa.free(r.stdout);
        var arena_impl = std.heap.ArenaAllocator.init(gpa);
        defer arena_impl.deinit();
        io.printStderr(arena_impl.allocator(), "{s} failed (exit {d}): {s}\n", .{
            tool,
            code,
            std.mem.trim(u8, r.stdout, " \t\r\n"),
        });
        return error.CommandFailed;
    }
    return r.stdout;
}

/// Like `run`, but a non-zero exit is reported to the caller instead of
/// being treated as fatal. Used where failure is a legitimate outcome
/// (e.g. terminating an app that isn't running).
pub fn tryRun(
    gpa: std.mem.Allocator,
    tool: []const u8,
    argv: []const []const u8,
    max_output: usize,
) !struct { stdout: []u8, code: i32 } {
    const path = try toolPath(gpa, tool);
    defer gpa.free(path);

    var full = try buildArgv(gpa, path, argv);
    defer full.deinit(gpa);

    const r = try io.runCommand(gpa, full.items, max_output);
    return .{ .stdout = r.stdout, .code = exitCode(r.term) };
}

test "exitCode decodes waitpid status" {
    // waitpid encodes the exit status in the high byte.
    try std.testing.expectEqual(@as(i32, 0), exitCode(0));
    try std.testing.expectEqual(@as(i32, 1), exitCode(1 << 8));
    try std.testing.expectEqual(@as(i32, 72), exitCode(72 << 8));
}

test "fileExists distinguishes real and missing paths" {
    try std.testing.expect(fileExists("/usr/bin/true"));
    try std.testing.expect(!fileExists("/nonexistent/kuri/xcode/probe"));
}
