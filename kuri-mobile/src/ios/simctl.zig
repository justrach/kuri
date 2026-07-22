//! iOS Simulator driver via `xcrun simctl`.

const std = @import("std");
const io = @import("../common/io.zig");

pub const Sim = struct {
    udid: []const u8,

    pub fn init(udid: []const u8) Sim {
        return .{ .udid = udid };
    }

    pub fn screenshot(self: Sim, gpa: std.mem.Allocator, path: []const u8) !void {
        const r = try io.runCommand(gpa, &.{ "xcrun", "simctl", "io", self.udid, "screenshot", path }, 64 * 1024 * 1024);
        defer gpa.free(r.stdout);
        try ensureSuccess(r.term, r.stdout);
    }

    pub fn launch(self: Sim, gpa: std.mem.Allocator, bundle_id: []const u8) !void {
        const r = try io.runCommand(gpa, &.{ "xcrun", "simctl", "launch", self.udid, bundle_id }, 1024 * 1024);
        defer gpa.free(r.stdout);
        try ensureSuccess(r.term, r.stdout);
    }

    pub fn terminate(self: Sim, gpa: std.mem.Allocator, bundle_id: []const u8) !void {
        const r = try io.runCommand(gpa, &.{ "xcrun", "simctl", "terminate", self.udid, bundle_id }, 1024 * 1024);
        defer gpa.free(r.stdout);
        try ensureSuccess(r.term, r.stdout);
    }

    pub fn listApps(self: Sim, gpa: std.mem.Allocator) ![]u8 {
        const r = try io.runCommand(gpa, &.{ "xcrun", "simctl", "listapps", self.udid }, 16 * 1024 * 1024);
        errdefer gpa.free(r.stdout);
        try ensureSuccess(r.term, r.stdout);
        return r.stdout;
    }

    /// Open a URL in the default handler (https/http → Safari).
    /// This is the "navigate" primitive on iOS Simulator — it's how
    /// you tell Safari to load a page without typing in the address bar.
    pub fn openUrl(self: Sim, gpa: std.mem.Allocator, url: []const u8) !void {
        const r = try io.runCommand(gpa, &.{ "xcrun", "simctl", "openurl", self.udid, url }, 1024 * 1024);
        defer gpa.free(r.stdout);
        try ensureSuccess(r.term, r.stdout);
    }

    pub fn boot(self: Sim, gpa: std.mem.Allocator) !void {
        const r = try io.runCommand(gpa, &.{ "xcrun", "simctl", "boot", self.udid }, 1024 * 1024);
        defer gpa.free(r.stdout);
        try ensureSuccess(r.term, r.stdout);
    }

    pub fn shutdown(self: Sim, gpa: std.mem.Allocator) !void {
        const r = try io.runCommand(gpa, &.{ "xcrun", "simctl", "shutdown", self.udid }, 1024 * 1024);
        defer gpa.free(r.stdout);
        try ensureSuccess(r.term, r.stdout);
    }
};

fn ensureSuccess(term: i32, output: []const u8) !void {
    if (term == 0) return;
    if (output.len != 0) {
        io.writeStderr(output);
        if (output[output.len - 1] != '\n') io.writeStderr("\n");
    }
    return error.SimctlCommandFailed;
}

pub const SimDevice = struct {
    udid: []const u8,
    name: []const u8,
    state: []const u8,
};

pub fn listDevices(gpa: std.mem.Allocator) ![]SimDevice {
    const r = try io.runCommand(gpa, &.{ "xcrun", "simctl", "list", "devices", "--json" }, 16 * 1024 * 1024);
    defer gpa.free(r.stdout);
    try ensureSuccess(r.term, r.stdout);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, r.stdout, .{});
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

test "simctl command status is not silently ignored" {
    try ensureSuccess(0, "");
    try std.testing.expectError(error.SimctlCommandFailed, ensureSuccess(256, "simctl failed"));
    try std.testing.expectError(error.SimctlCommandFailed, ensureSuccess(9, "terminated"));
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
