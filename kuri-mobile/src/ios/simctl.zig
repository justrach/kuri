//! iOS Simulator driver via `simctl`.
//!
//! Invoked through xcode.zig by absolute path rather than `xcrun`, and every
//! call checks its exit status — see xcode.zig for why that matters.

const std = @import("std");
const io = @import("../common/io.zig");
const xcode = @import("xcode.zig");

pub const Sim = struct {
    udid: []const u8,

    pub fn init(udid: []const u8) Sim {
        return .{ .udid = udid };
    }

    pub fn screenshot(self: Sim, gpa: std.mem.Allocator, path: []const u8) !void {
        const out = try xcode.run(gpa, "simctl", &.{ "io", self.udid, "screenshot", path }, 64 * 1024 * 1024);
        gpa.free(out);
    }

    pub fn launch(self: Sim, gpa: std.mem.Allocator, bundle_id: []const u8) !void {
        const out = try xcode.run(gpa, "simctl", &.{ "launch", self.udid, bundle_id }, 1024 * 1024);
        gpa.free(out);
    }

    pub fn terminate(self: Sim, gpa: std.mem.Allocator, bundle_id: []const u8) !void {
        const out = try xcode.run(gpa, "simctl", &.{ "terminate", self.udid, bundle_id }, 1024 * 1024);
        gpa.free(out);
    }

    pub fn listApps(self: Sim, gpa: std.mem.Allocator) ![]u8 {
        return xcode.run(gpa, "simctl", &.{ "listapps", self.udid }, 16 * 1024 * 1024);
    }

    /// Open a URL in the default handler (https/http → Safari).
    /// This is the "navigate" primitive on iOS Simulator — it's how
    /// you tell Safari to load a page without typing in the address bar.
    pub fn openUrl(self: Sim, gpa: std.mem.Allocator, url: []const u8) !void {
        const out = try xcode.run(gpa, "simctl", &.{ "openurl", self.udid, url }, 1024 * 1024);
        gpa.free(out);
    }

    pub fn boot(self: Sim, gpa: std.mem.Allocator) !void {
        const out = try xcode.run(gpa, "simctl", &.{ "boot", self.udid }, 1024 * 1024);
        gpa.free(out);
    }

    pub fn shutdown(self: Sim, gpa: std.mem.Allocator) !void {
        const out = try xcode.run(gpa, "simctl", &.{ "shutdown", self.udid }, 1024 * 1024);
        gpa.free(out);
    }

    /// Erase back to factory state. simctl refuses to erase a booted device,
    /// so shut down first — and tolerate that shutdown failing, because
    /// "already shut down" is the common and entirely fine case.
    pub fn erase(self: Sim, gpa: std.mem.Allocator) !void {
        const r = try xcode.tryRun(gpa, "simctl", &.{ "shutdown", self.udid }, 1024 * 1024);
        gpa.free(r.stdout);
        const out = try xcode.run(gpa, "simctl", &.{ "erase", self.udid }, 1024 * 1024);
        gpa.free(out);
    }

    pub fn install(self: Sim, gpa: std.mem.Allocator, app_path: []const u8) !void {
        const out = try xcode.run(gpa, "simctl", &.{ "install", self.udid, app_path }, 4 * 1024 * 1024);
        gpa.free(out);
    }

    pub fn uninstall(self: Sim, gpa: std.mem.Allocator, bundle_id: []const u8) !void {
        const out = try xcode.run(gpa, "simctl", &.{ "uninstall", self.udid, bundle_id }, 1024 * 1024);
        gpa.free(out);
    }

    // --- Location -----------------------------------------------------------

    /// `simctl location <udid> set <lat>,<lon>`. Coordinates are passed as one
    /// comma-joined argument, which is the shape simctl expects.
    pub fn setLocation(self: Sim, gpa: std.mem.Allocator, lat: []const u8, lon: []const u8) !void {
        const pair = try std.fmt.allocPrint(gpa, "{s},{s}", .{ lat, lon });
        defer gpa.free(pair);
        const out = try xcode.run(gpa, "simctl", &.{ "location", self.udid, "set", pair }, 1024 * 1024);
        gpa.free(out);
    }

    pub fn clearLocation(self: Sim, gpa: std.mem.Allocator) !void {
        const out = try xcode.run(gpa, "simctl", &.{ "location", self.udid, "clear" }, 1024 * 1024);
        gpa.free(out);
    }

    /// Record the screen for `duration_ms`, then SIGINT so the container is
    /// finalised. simctl overwrites only with --force; without it a second
    /// recording to the same path fails instead of silently clobbering.
    pub fn recordVideo(
        self: Sim,
        gpa: std.mem.Allocator,
        path: []const u8,
        duration_ms: u64,
    ) !void {
        const tool = try xcode.toolPath(gpa, "simctl");
        defer gpa.free(tool);
        const argv = [_][]const u8{
            tool, "io", self.udid, "recordVideo", "--force", path,
        };
        const r = try io.runCommandFor(gpa, &argv, duration_ms, 1024 * 1024);
        defer gpa.free(r.stdout);
        if (!xcode.fileExists(path)) {
            io.writeStderr("recording produced no file — is the simulator booted?\n");
            return error.CommandFailed;
        }
    }

    // --- Permissions --------------------------------------------------------

    /// Grant / revoke / reset a TCC permission for a bundle id.
    pub fn privacy(
        self: Sim,
        gpa: std.mem.Allocator,
        action: []const u8,
        service: []const u8,
        bundle_id: ?[]const u8,
    ) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "privacy", self.udid, action, service });
        if (bundle_id) |b| try argv.append(gpa, b);
        const out = try xcode.run(gpa, "simctl", argv.items, 1024 * 1024);
        gpa.free(out);
    }

    // --- Accessibility / appearance ----------------------------------------

    /// `simctl ui <udid> <option> [value]`. With no value this prints the
    /// current setting, which is what makes it usable as an assertion.
    pub fn ui(self: Sim, gpa: std.mem.Allocator, option: []const u8, value: ?[]const u8) ![]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "ui", self.udid, option });
        if (value) |v| try argv.append(gpa, v);
        return xcode.run(gpa, "simctl", argv.items, 1024 * 1024);
    }

    /// Pin the status bar so screenshots are byte-comparable across runs.
    pub fn statusBar(self: Sim, gpa: std.mem.Allocator, extra: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "status_bar", self.udid, "override" });
        try argv.appendSlice(gpa, extra);
        const out = try xcode.run(gpa, "simctl", argv.items, 1024 * 1024);
        gpa.free(out);
    }

    pub fn statusBarClear(self: Sim, gpa: std.mem.Allocator) !void {
        const out = try xcode.run(gpa, "simctl", &.{ "status_bar", self.udid, "clear" }, 1024 * 1024);
        gpa.free(out);
    }

    /// `simctl spawn <udid> defaults write <domain> <key> -int <value>`.
    /// Used to flip runtime-side settings that have no simctl verb — notably
    /// app accessibility, which gates the host-visible a11y tree.
    pub fn spawnDefaultsWrite(
        self: Sim,
        gpa: std.mem.Allocator,
        domain: []const u8,
        key: []const u8,
        int_value: []const u8,
    ) ![]u8 {
        return xcode.run(gpa, "simctl", &.{
            "spawn", self.udid, "defaults", "write", domain, key, "-int", int_value,
        }, 1024 * 1024);
    }

    // --- Diagnostics --------------------------------------------------------

    /// Retrospective os_log query against the simulator.
    ///
    /// Deliberately `log show --last`, not `log stream`: a bounded query
    /// terminates, so it can back an assertion ("did the app request a
    /// haptic in the last 30s?"). A stream would block until killed.
    pub fn logShow(
        self: Sim,
        gpa: std.mem.Allocator,
        last: []const u8,
        predicate: ?[]const u8,
    ) ![]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{
            "spawn", self.udid, "log", "show", "--last", last, "--style", "compact",
        });
        if (predicate) |p| try argv.appendSlice(gpa, &.{ "--predicate", p });
        return xcode.run(gpa, "simctl", argv.items, 64 * 1024 * 1024);
    }
};

// --- Host-side helpers ------------------------------------------------------
// These drive Simulator.app itself rather than a simulated device, so they run
// host binaries by absolute path instead of going through the Xcode toolchain.

/// Launch Simulator.app and bring it forward. Idempotent — `open -a` on an
/// already-running app just activates it.
pub fn openSimulatorApp(gpa: std.mem.Allocator) !void {
    const r = try io.runCommand(gpa, &.{ "/usr/bin/open", "-a", "Simulator" }, 1024 * 1024);
    defer gpa.free(r.stdout);
    if (((r.term >> 8) & 0xFF) != 0) return error.CommandFailed;
}

/// Connect or disconnect the host hardware keyboard.
///
/// This is what governs whether the *software* keyboard appears: with the
/// hardware keyboard connected iOS suppresses the on-screen one, so a test
/// that wants to tap keys must disconnect it first. The setting belongs to
/// Simulator.app (a host preference), not to any individual device, and is
/// read at window focus — so an already-open window may need a re-focus.
pub fn setHardwareKeyboard(gpa: std.mem.Allocator, connected: bool) !void {
    const r = try io.runCommand(gpa, &.{
        "/usr/bin/defaults",              "write",
        "com.apple.iphonesimulator",      "ConnectHardwareKeyboard",
        "-bool",                          if (connected) "YES" else "NO",
    }, 1024 * 1024);
    defer gpa.free(r.stdout);
    if (((r.term >> 8) & 0xFF) != 0) return error.CommandFailed;
}

/// TCC services `simctl privacy` accepts, as of Xcode 26.6.
pub const privacy_services = [_][]const u8{
    "all",        "calendar",    "contacts-limited", "contacts",
    "location",   "location-always", "photos-add",  "photos",
    "media-library", "microphone", "motion",        "reminders",
    "siri",
};

/// Services people reach for that `simctl privacy` genuinely does not
/// implement. Worth naming explicitly: silently passing `camera` through to
/// simctl produces a confusing failure, and camera permission is exactly
/// what a first-use camera-authorization bug needs to reset.
pub const privacy_unsupported = [_][]const u8{ "camera", "speech-recognition", "speech" };

pub fn isPrivacyService(name: []const u8) bool {
    for (privacy_services) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

pub fn isPrivacyUnsupported(name: []const u8) bool {
    for (privacy_unsupported) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

pub const SimDevice = struct {
    udid: []const u8,
    name: []const u8,
    state: []const u8,
};

pub fn listDevices(gpa: std.mem.Allocator) ![]SimDevice {
    const stdout = try xcode.run(gpa, "simctl", &.{ "list", "devices", "--json" }, 16 * 1024 * 1024);
    defer gpa.free(stdout);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, stdout, .{});
    defer parsed.deinit();

    var list: std.ArrayList(SimDevice) = .empty;
    errdefer freeFromList(gpa, &list);

    const root = parsed.value;
    if (root != .object) return try list.toOwnedSlice(gpa);
    const devices_val = root.object.get("devices") orelse return try list.toOwnedSlice(gpa);
    if (devices_val != .object) return try list.toOwnedSlice(gpa);

    var it = devices_val.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .array) continue;
        for (kv.value_ptr.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const udid_v = obj.get("udid") orelse continue;
            const name_v = obj.get("name") orelse continue;
            const state_v = obj.get("state") orelse continue;
            if (udid_v != .string or name_v != .string or state_v != .string) continue;
            try list.append(gpa, .{
                .udid = try gpa.dupe(u8, udid_v.string),
                .name = try gpa.dupe(u8, name_v.string),
                .state = try gpa.dupe(u8, state_v.string),
            });
        }
    }
    return try list.toOwnedSlice(gpa);
}

pub fn freeSimDevices(gpa: std.mem.Allocator, devs: []const SimDevice) void {
    for (devs) |d| {
        gpa.free(d.udid);
        gpa.free(d.name);
        gpa.free(d.state);
    }
    gpa.free(devs);
}

fn freeFromList(gpa: std.mem.Allocator, list: *std.ArrayList(SimDevice)) void {
    for (list.items) |d| {
        gpa.free(d.udid);
        gpa.free(d.name);
        gpa.free(d.state);
    }
    list.deinit(gpa);
}

test "privacy service classification" {
    try std.testing.expect(isPrivacyService("microphone"));
    try std.testing.expect(isPrivacyService("photos"));
    try std.testing.expect(!isPrivacyService("camera"));
    // camera is the one people most expect to work, so it must be
    // classified as explicitly-unsupported rather than merely unknown.
    try std.testing.expect(isPrivacyUnsupported("camera"));
    try std.testing.expect(!isPrivacyUnsupported("microphone"));
}
