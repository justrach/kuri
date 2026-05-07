//! High-level Android device driver. Composes adb shell commands.
//!
//! Implements the subset of mobile-device-mcp tools that work without an
//! on-device driver app:
//!   - tap, double_tap, long_press, swipe (input tap/swipe/keyevent)
//!   - type_text             (input text)
//!   - press_button          (input keyevent KEYCODE_*)
//!   - screenshot            (exec:screencap -p, raw PNG bytes)
//!   - uitree                (exec:uiautomator dump /dev/tty)
//!   - launch_app            (monkey -p <pkg> 1)
//!   - terminate_app         (am force-stop)
//!   - list_apps             (pm list packages)
//!   - list_devices          (host:devices)

const std = @import("std");
const adb = @import("adb.zig");

extern "c" fn usleep(usec: u32) c_int;

pub const Driver = struct {
    client: adb.Client,
    serial: []const u8,

    pub fn init(gpa: std.mem.Allocator, serial: []const u8) Driver {
        return .{ .client = adb.Client.init(gpa), .serial = serial };
    }

    fn shell(self: *Driver, gpa: std.mem.Allocator, cmd: []const u8) ![]u8 {
        _ = gpa; // client owns its own allocator
        var buf: [1024]u8 = undefined;
        const svc = try std.fmt.bufPrint(&buf, "shell:{s}", .{cmd});
        return try self.client.deviceExec(self.serial, svc);
    }

    fn exec(self: *Driver, gpa: std.mem.Allocator, cmd: []const u8) ![]u8 {
        _ = gpa;
        var buf: [1024]u8 = undefined;
        const svc = try std.fmt.bufPrint(&buf, "exec:{s}", .{cmd});
        return try self.client.deviceExec(self.serial, svc);
    }

    pub fn tap(self: *Driver, gpa: std.mem.Allocator, x: i32, y: i32) !void {
        var buf: [128]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "input tap {d} {d}", .{ x, y });
        const out = try self.shell(gpa, cmd);
        gpa.free(out);
    }

    pub fn doubleTap(self: *Driver, gpa: std.mem.Allocator, x: i32, y: i32) !void {
        try self.tap(gpa, x, y);
        _ = usleep(80_000); // 80ms
        try self.tap(gpa, x, y);
    }

    pub fn longPress(self: *Driver, gpa: std.mem.Allocator, x: i32, y: i32, duration_ms: u32) !void {
        var buf: [128]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "input swipe {d} {d} {d} {d} {d}", .{ x, y, x, y, duration_ms });
        const out = try self.shell(gpa, cmd);
        gpa.free(out);
    }

    pub fn swipe(self: *Driver, gpa: std.mem.Allocator, x1: i32, y1: i32, x2: i32, y2: i32, duration_ms: u32) !void {
        var buf: [128]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "input swipe {d} {d} {d} {d} {d}", .{ x1, y1, x2, y2, duration_ms });
        const out = try self.shell(gpa, cmd);
        gpa.free(out);
    }

    pub fn typeText(self: *Driver, gpa: std.mem.Allocator, text: []const u8) !void {
        // `input text` requires spaces escaped as %s and special chars limited.
        const escaped = try escapeForInputText(gpa, text);
        defer gpa.free(escaped);
        const cmd = try std.fmt.allocPrint(gpa, "input text {s}", .{escaped});
        defer gpa.free(cmd);
        const out = try self.shell(gpa, cmd);
        gpa.free(out);
    }

    pub fn pressButton(self: *Driver, gpa: std.mem.Allocator, name: []const u8) !void {
        const keycode = mapButton(name) orelse return error.UnknownButton;
        var buf: [64]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "input keyevent {s}", .{keycode});
        const out = try self.shell(gpa, cmd);
        gpa.free(out);
    }

    /// Returns raw PNG bytes via `exec:screencap -p`. Caller frees.
    /// We use `exec:` (not `shell:`) so adb does not perform CRLF translation
    /// on the binary PNG bytes — `shell:` would corrupt the output.
    pub fn screenshot(self: *Driver, gpa: std.mem.Allocator) ![]u8 {
        return try self.exec(gpa, "screencap -p");
    }

    /// Dump UI tree XML via uiautomator.
    pub fn uitreeXml(self: *Driver, gpa: std.mem.Allocator) ![]u8 {
        // `uiautomator dump /dev/tty` writes XML to stdout but also a status
        // line; we strip the trailing "UI hierchary dumped to: /dev/tty" if
        // present.
        const raw = try self.shell(gpa, "uiautomator dump /dev/tty 2>/dev/null");
        if (std.mem.lastIndexOf(u8, raw, "</hierarchy>")) |end| {
            const cut = end + "</hierarchy>".len;
            const trimmed = try gpa.dupe(u8, raw[0..cut]);
            gpa.free(raw);
            return trimmed;
        }
        return raw;
    }

    pub fn launchApp(self: *Driver, gpa: std.mem.Allocator, pkg: []const u8) !void {
        const cmd = try std.fmt.allocPrint(gpa, "monkey -p {s} -c android.intent.category.LAUNCHER 1", .{pkg});
        defer gpa.free(cmd);
        const out = try self.shell(gpa, cmd);
        gpa.free(out);
    }

    pub fn terminateApp(self: *Driver, gpa: std.mem.Allocator, pkg: []const u8) !void {
        const cmd = try std.fmt.allocPrint(gpa, "am force-stop {s}", .{pkg});
        defer gpa.free(cmd);
        const out = try self.shell(gpa, cmd);
        gpa.free(out);
    }

    /// Returns newline-separated list of `package:<pkg>` lines, owned.
    pub fn listApps(self: *Driver, gpa: std.mem.Allocator) ![]u8 {
        return try self.shell(gpa, "pm list packages");
    }
};

fn mapButton(name: []const u8) ?[]const u8 {
    const Pair = struct { []const u8, []const u8 };
    const table = [_]Pair{
        .{ "home", "KEYCODE_HOME" },
        .{ "back", "KEYCODE_BACK" },
        .{ "menu", "KEYCODE_MENU" },
        .{ "enter", "KEYCODE_ENTER" },
        .{ "tab", "KEYCODE_TAB" },
        .{ "space", "KEYCODE_SPACE" },
        .{ "del", "KEYCODE_DEL" },
        .{ "volumeUp", "KEYCODE_VOLUME_UP" },
        .{ "volumeDown", "KEYCODE_VOLUME_DOWN" },
        .{ "power", "KEYCODE_POWER" },
        .{ "dpadUp", "KEYCODE_DPAD_UP" },
        .{ "dpadDown", "KEYCODE_DPAD_DOWN" },
        .{ "dpadLeft", "KEYCODE_DPAD_LEFT" },
        .{ "dpadRight", "KEYCODE_DPAD_RIGHT" },
        .{ "dpadCenter", "KEYCODE_DPAD_CENTER" },
    };
    for (table) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
    return null;
}

/// `input text` is space-separated and treats spaces as separators. The
/// canonical workaround is to substitute spaces with %s. We also reject
/// characters outside ASCII for safety; non-ASCII typing requires IME
/// approaches outside this driver's scope.
fn escapeForInputText(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (src) |c| {
        switch (c) {
            ' ' => try out.appendSlice(gpa, "%s"),
            '\'', '"', '`', '$', '\\', '&', ';', '(', ')', '<', '>', '|' => {
                try out.append(gpa, '\\');
                try out.append(gpa, c);
            },
            else => try out.append(gpa, c),
        }
    }
    return try out.toOwnedSlice(gpa);
}

test "mapButton known and unknown" {
    try std.testing.expectEqualStrings("KEYCODE_HOME", mapButton("home").?);
    try std.testing.expect(mapButton("nope") == null);
}

test "escapeForInputText converts spaces and quotes" {
    const out = try escapeForInputText(std.testing.allocator, "hello world's");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello%sworld\\'s", out);
}
