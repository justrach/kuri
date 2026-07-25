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

const std = @import("std");
const xcode = @import("xcode.zig");

const max_out = 16 * 1024 * 1024;

fn run(gpa: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    return xcode.run(gpa, "devicectl", argv, max_out);
}

fn runDiscard(gpa: std.mem.Allocator, argv: []const []const u8) !void {
    gpa.free(try run(gpa, argv));
}

/// Paired devices and their availability. devicectl only writes JSON to a
/// file on disk — never stdout — so this returns its human-readable table.
pub fn listDevices(gpa: std.mem.Allocator) ![]u8 {
    return run(gpa, &.{ "list", "devices" });
}

// --- lifecycle --------------------------------------------------------------

pub fn launch(gpa: std.mem.Allocator, udid: []const u8, bundle_id: []const u8) !void {
    return runDiscard(gpa, &.{ "device", "process", "launch", "--device", udid, bundle_id });
}

pub fn terminate(gpa: std.mem.Allocator, udid: []const u8, bundle_id: []const u8) !void {
    return runDiscard(gpa, &.{ "device", "process", "terminate", "--device", udid, bundle_id });
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

pub fn listApps(gpa: std.mem.Allocator, udid: []const u8) ![]u8 {
    return run(gpa, &.{ "device", "info", "apps", "--device", udid });
}

pub fn details(gpa: std.mem.Allocator, udid: []const u8) ![]u8 {
    return run(gpa, &.{ "device", "info", "details", "--device", udid });
}

pub fn processes(gpa: std.mem.Allocator, udid: []const u8) ![]u8 {
    return run(gpa, &.{ "device", "info", "processes", "--device", udid });
}

/// Whether the screen is locked. An automation run that silently does nothing
/// because the phone is locked is a common and confusing failure.
pub fn lockState(gpa: std.mem.Allocator, udid: []const u8) ![]u8 {
    return run(gpa, &.{ "device", "info", "lockState", "--device", udid });
}

pub fn displays(gpa: std.mem.Allocator, udid: []const u8) ![]u8 {
    return run(gpa, &.{ "device", "info", "displays", "--device", udid });
}
