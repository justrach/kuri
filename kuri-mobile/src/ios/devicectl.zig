//! Real-device iOS ops via `xcrun devicectl` (Apple CoreDevice).
//!
//! v1 strategy: shell out to devicectl. v2 can replace with native
//! lockdownd/Instruments service-tunnel speaking usbmuxd-over-TLS.

const std = @import("std");
const io = @import("../common/io.zig");

pub fn listDevicesJson(gpa: std.mem.Allocator) ![]u8 {
    const r = try io.runCommand(gpa, &.{ "xcrun", "devicectl", "list", "devices", "--json-output", "-" }, 16 * 1024 * 1024);
    return r.stdout;
}

pub fn launch(gpa: std.mem.Allocator, udid: []const u8, bundle_id: []const u8) !void {
    const r = try io.runCommand(gpa, &.{ "xcrun", "devicectl", "device", "process", "launch", "--device", udid, bundle_id }, 1024 * 1024);
    gpa.free(r.stdout);
}

pub fn terminate(gpa: std.mem.Allocator, udid: []const u8, bundle_id: []const u8) !void {
    const r = try io.runCommand(gpa, &.{ "xcrun", "devicectl", "device", "process", "terminate", "--device", udid, bundle_id }, 1024 * 1024);
    gpa.free(r.stdout);
}
