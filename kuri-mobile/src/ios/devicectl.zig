//! Real-device iOS ops via `devicectl` (Apple CoreDevice).
//!
//! Invoked through xcode.zig by absolute path with a checked exit status, for
//! the same reason simctl is: `xcrun devicectl` resolves through
//! `xcode-select`, which frequently points at CommandLineTools — where
//! devicectl does not exist. Combined with an unchecked exit status that made
//! every `--device` command report success while doing nothing at all.
//!
//! v1 strategy: shell out to devicectl. v2 can replace this with a native
//! lockdownd/Instruments service tunnel speaking usbmuxd-over-TLS.
//!
//! Scope note: devicectl exposes no screenshot and no UI hierarchy, so
//! `tap`/`swipe`/`uitree` remain simulator-only regardless of what is plugged
//! in — those need XCUITest. What a real device *does* support is lifecycle,
//! installation and inspection, which is what this module covers.
//!
//! Structured output: devicectl never writes JSON to stdout. `--json-output
//! <path>` is its only machine-readable channel, so the calls that need a
//! parsed answer (a launched pid, a process list) route through `runJson`,
//! which writes to a scratch file and reads it back.

const std = @import("std");
const io = @import("../common/io.zig");
const xcode = @import("xcode.zig");

const max_out = 16 * 1024 * 1024;
const max_json = 32 * 1024 * 1024;

fn run(gpa: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    return xcode.run(gpa, "devicectl", argv, max_out);
}

fn runDiscard(gpa: std.mem.Allocator, argv: []const []const u8) !void {
    gpa.free(try run(gpa, argv));
}

/// A per-process scratch path for `--json-output`. Caller frees.
fn scratchPath(gpa: std.mem.Allocator, tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "/tmp/kuri-devicectl-{d}-{s}.json", .{ std.c.getpid(), tag });
}

/// Run devicectl with `--json-output` appended and return the parsed document.
/// Caller calls `.deinit()` on the result.
fn runJson(
    gpa: std.mem.Allocator,
    tag: []const u8,
    argv: []const []const u8,
) !std.json.Parsed(std.json.Value) {
    const path = try scratchPath(gpa, tag);
    defer gpa.free(path);
    defer io.removeFile(path);

    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.appendSlice(gpa, argv);
    try full.append(gpa, "--json-output");
    try full.append(gpa, path);

    gpa.free(try run(gpa, full.items));

    const text = try io.readFile(gpa, path, max_json);
    defer gpa.free(text);
    return std.json.parseFromSlice(std.json.Value, gpa, text, .{});
}

/// Paired devices and their availability. devicectl only writes JSON to a
/// file on disk — never stdout — so this returns its human-readable table.
pub fn listDevices(gpa: std.mem.Allocator) ![]u8 {
    return run(gpa, &.{ "list", "devices" });
}

// --- lifecycle --------------------------------------------------------------

/// Launch an app and return the pid devicectl reports.
///
/// The pid is the point: `devicectl device process terminate` takes `--pid`,
/// never a bundle id, so without carrying the identifier out of launch there
/// is no way to stop what you started. A launch that reports success but no
/// identifier is treated as a failure rather than passed on as a zero, which
/// would later terminate the wrong thing.
pub fn launch(gpa: std.mem.Allocator, udid: []const u8, bundle_id: []const u8) !i64 {
    var parsed = try runJson(gpa, "launch", &.{
        "device", "process", "launch", "--device", udid, bundle_id,
    });
    defer parsed.deinit();
    return processIdentifier(parsed.value) orelse error.NoProcessIdentifier;
}

/// `{"result": {"process": {"processIdentifier": N}}}` — the shape devicectl
/// writes for a successful launch.
fn processIdentifier(root: std.json.Value) ?i64 {
    const result = objectGet(root, "result") orelse return null;
    const process = objectGet(result, "process") orelse return null;
    const pid = objectGet(process, "processIdentifier") orelse return null;
    return switch (pid) {
        .integer => |v| if (v > 0) v else null,
        else => null,
    };
}

fn objectGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

pub fn terminate(gpa: std.mem.Allocator, udid: []const u8, pid: i64) !void {
    var buf: [24]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&buf, "{d}", .{pid});
    return runDiscard(gpa, &.{
        "device", "process", "terminate", "--device", udid, "--pid", pid_str,
    });
}

/// Install a `.app` bundle onto a physical device. Requires the bundle to be
/// signed with a provisioning profile the device trusts — an unsigned
/// simulator build will be rejected here, which is expected, not a kuri bug.
pub fn install(gpa: std.mem.Allocator, udid: []const u8, app_path: []const u8) !void {
    return runDiscard(gpa, &.{ "device", "install", "app", "--device", udid, app_path });
}

pub fn uninstall(gpa: std.mem.Allocator, udid: []const u8, bundle_id: []const u8) !void {
    return runDiscard(gpa, &.{ "device", "uninstall", "app", "--device", udid, bundle_id });
}

pub fn reboot(gpa: std.mem.Allocator, udid: []const u8) !void {
    return runDiscard(gpa, &.{ "device", "reboot", "--device", udid });
}

// --- inspection -------------------------------------------------------------

/// Every installed app, system apps included.
///
/// `--include-default-apps` is not optional for correctness here: devicectl
/// defaults to *developer apps only*, so without it a command documented as
/// "list installed apps" silently omits Settings, Safari, Photos and every
/// other system app, while still exiting 0. Nothing in the output hints that
/// a filter was applied.
///
/// `--include-all-apps` would be the obvious flag but is the wrong one: it
/// documents that other filtering options are ignored, which would break the
/// `--bundle-id` lookups below.
const include_all = [_][]const u8{ "--include-default-apps", "--include-app-clips" };

pub fn listApps(gpa: std.mem.Allocator, udid: []const u8) ![]u8 {
    return run(gpa, &.{
        "device",   "info",             "apps", "--device", udid,
        include_all[0], include_all[1],
    });
}

/// Whether `bundle_id` is currently installed. devicectl's own `--bundle-id`
/// filter does the matching, so this never has to parse an app table.
pub fn appInstalled(gpa: std.mem.Allocator, udid: []const u8, bundle_id: []const u8) !bool {
    var parsed = try runJson(gpa, "apps", &.{
        "device",       "info",         "apps", "--device", udid, "--bundle-id", bundle_id,
        include_all[0], include_all[1],
    });
    defer parsed.deinit();
    return countApps(parsed.value) > 0;
}

/// `{"result": {"apps": [...]}}`.
fn countApps(root: std.json.Value) usize {
    const result = objectGet(root, "result") orelse return 0;
    const apps = objectGet(result, "apps") orelse return 0;
    return switch (apps) {
        .array => |a| a.items.len,
        else => 0,
    };
}

pub fn details(gpa: std.mem.Allocator, udid: []const u8) ![]u8 {
    return run(gpa, &.{ "device", "info", "details", "--device", udid });
}

pub fn processes(gpa: std.mem.Allocator, udid: []const u8) ![]u8 {
    return run(gpa, &.{ "device", "info", "processes", "--device", udid });
}

/// Find the pid of a running process whose executable lives inside the app
/// bundle for `bundle_id`.
///
/// Two hops, because neither table alone carries both halves: `info apps`
/// maps a bundle id to its on-device bundle URL, and `info processes` maps an
/// executable path to a pid. A process belongs to the app when its executable
/// path sits under that bundle URL.
///
/// Returns null when the app is installed but not running — a normal outcome,
/// not an error.
pub fn findProcess(
    gpa: std.mem.Allocator,
    udid: []const u8,
    bundle_id: []const u8,
) !?i64 {
    var apps = try runJson(gpa, "apps", &.{
        "device",       "info",         "apps", "--device", udid, "--bundle-id", bundle_id,
        include_all[0], include_all[1],
    });
    defer apps.deinit();
    const bundle_url = firstAppUrl(apps.value) orelse return null;

    var procs = try runJson(gpa, "procs", &.{
        "device", "info", "processes", "--device", udid,
    });
    defer procs.deinit();
    return pidUnderBundle(procs.value, bundle_url);
}

/// The `url` of the first entry in `{"result": {"apps": [...]}}`.
fn firstAppUrl(root: std.json.Value) ?[]const u8 {
    const result = objectGet(root, "result") orelse return null;
    const apps = objectGet(result, "apps") orelse return null;
    const arr = switch (apps) {
        .array => |a| a,
        else => return null,
    };
    if (arr.items.len == 0) return null;
    const url = objectGet(arr.items[0], "url") orelse return null;
    return switch (url) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

/// Scan `{"result": {"runningProcesses": [{processIdentifier, executable}]}}`
/// for the first process whose executable path lies inside `bundle_url`.
///
/// Paths are compared on their trailing component chain rather than verbatim:
/// devicectl reports the app bundle as a `file://` URL while executables come
/// back as plain absolute paths, so a literal prefix test would never match.
fn pidUnderBundle(root: std.json.Value, bundle_url: []const u8) ?i64 {
    const bundle_path = stripFileScheme(bundle_url);
    if (bundle_path.len == 0) return null;

    const result = objectGet(root, "result") orelse return null;
    const list = objectGet(result, "runningProcesses") orelse return null;
    const arr = switch (list) {
        .array => |a| a,
        else => return null,
    };

    for (arr.items) |entry| {
        const exe_val = objectGet(entry, "executable") orelse continue;
        const exe = switch (exe_val) {
            .string => |s| stripFileScheme(s),
            else => continue,
        };
        if (!isUnder(exe, bundle_path)) continue;
        const pid_val = objectGet(entry, "processIdentifier") orelse continue;
        switch (pid_val) {
            .integer => |v| if (v > 0) return v,
            else => {},
        }
    }
    return null;
}

/// Whether `path` names something inside directory `dir`.
///
/// A bare `startsWith` would call /var/Demo.appendix/x a child of /var/Demo.app,
/// so the byte after the prefix has to be a separator for the match to mean
/// what it says.
fn isUnder(path: []const u8, dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) return false;
    return path.len > dir.len and path[dir.len] == '/';
}

/// `file:///private/var/...` -> `/private/var/...`, with any trailing slash
/// removed so it composes as a prefix. Non-URL input is returned unchanged.
fn stripFileScheme(s: []const u8) []const u8 {
    const prefix = "file://";
    var out = s;
    if (std.mem.startsWith(u8, out, prefix)) out = out[prefix.len..];
    while (out.len > 1 and out[out.len - 1] == '/') out = out[0 .. out.len - 1];
    return out;
}

/// Whether the screen is locked. An automation run that silently does nothing
/// because the phone is locked is a common and confusing failure.
pub fn lockState(gpa: std.mem.Allocator, udid: []const u8) ![]u8 {
    return run(gpa, &.{ "device", "info", "lockState", "--device", udid });
}

pub fn displays(gpa: std.mem.Allocator, udid: []const u8) ![]u8 {
    return run(gpa, &.{ "device", "info", "displays", "--device", udid });
}

// --- tests ------------------------------------------------------------------
//
// These pin the JSON shapes devicectl emits. They are the only part of the
// real-device path that can be checked without hardware attached, and they
// cover exactly the decoding that would otherwise fail silently: a missing
// pid must not decode as 0, and a process match must not be made on a
// coincidental path.

fn parse(text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
}

test "processIdentifier reads a launched pid" {
    var p = try parse(
        \\{"result":{"process":{"processIdentifier":867}}}
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(?i64, 867), processIdentifier(p.value));
}

test "processIdentifier rejects a missing or non-positive pid" {
    inline for (.{
        \\{"result":{"process":{}}}
        ,
        \\{"result":{"process":{"processIdentifier":0}}}
        ,
        \\{"result":{}}
        ,
        \\{}
        ,
    }) |doc| {
        var p = try parse(doc);
        defer p.deinit();
        try std.testing.expectEqual(@as(?i64, null), processIdentifier(p.value));
    }
}

test "countApps distinguishes installed from absent" {
    var present = try parse(
        \\{"result":{"apps":[{"bundleIdentifier":"io.kuri.demo"}]}}
    );
    defer present.deinit();
    try std.testing.expectEqual(@as(usize, 1), countApps(present.value));

    var absent = try parse(
        \\{"result":{"apps":[]}}
    );
    defer absent.deinit();
    try std.testing.expectEqual(@as(usize, 0), countApps(absent.value));
}

test "stripFileScheme normalises devicectl paths" {
    try std.testing.expectEqualStrings("/var/Demo.app", stripFileScheme("file:///var/Demo.app"));
    try std.testing.expectEqualStrings("/var/Demo.app", stripFileScheme("file:///var/Demo.app/"));
    try std.testing.expectEqualStrings("/var/Demo.app", stripFileScheme("/var/Demo.app"));
}

test "pidUnderBundle matches the executable inside the app bundle" {
    var p = try parse(
        \\{"result":{"runningProcesses":[
        \\  {"processIdentifier":11,"executable":"file:///usr/libexec/other"},
        \\  {"processIdentifier":42,"executable":"file:///var/Bundle/Demo.app/Demo"}
        \\]}}
    );
    defer p.deinit();
    try std.testing.expectEqual(
        @as(?i64, 42),
        pidUnderBundle(p.value, "file:///var/Bundle/Demo.app"),
    );
}

test "pidUnderBundle returns null when the app is not running" {
    var p = try parse(
        \\{"result":{"runningProcesses":[
        \\  {"processIdentifier":11,"executable":"file:///usr/libexec/other"}
        \\]}}
    );
    defer p.deinit();
    try std.testing.expectEqual(
        @as(?i64, null),
        pidUnderBundle(p.value, "file:///var/Bundle/Demo.app"),
    );
}

test "pidUnderBundle does not match a bundle that is only a name prefix" {
    // Demo.appendix shares every byte of Demo.app and would pass a bare
    // startsWith, terminating an unrelated process.
    var p = try parse(
        \\{"result":{"runningProcesses":[
        \\  {"processIdentifier":7,"executable":"file:///var/Bundle/Demo.appendix/Other"}
        \\]}}
    );
    defer p.deinit();
    try std.testing.expectEqual(
        @as(?i64, null),
        pidUnderBundle(p.value, "file:///var/Bundle/Demo.app"),
    );
}

test "isUnder requires a path separator at the boundary" {
    try std.testing.expect(isUnder("/var/Demo.app/Demo", "/var/Demo.app"));
    try std.testing.expect(!isUnder("/var/Demo.appendix/x", "/var/Demo.app"));
    try std.testing.expect(!isUnder("/var/Demo.app", "/var/Demo.app"));
}

test "firstAppUrl reads the on-device bundle location" {
    var p = try parse(
        \\{"result":{"apps":[{"bundleIdentifier":"io.kuri.demo","url":"file:///var/Bundle/Demo.app/"}]}}
    );
    defer p.deinit();
    try std.testing.expectEqualStrings("file:///var/Bundle/Demo.app/", firstAppUrl(p.value).?);
}
