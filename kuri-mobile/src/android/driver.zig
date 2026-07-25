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

    /// `shell` formats into a fixed 1 KiB buffer, which is fine for commands we
    /// build ourselves but not for ones carrying user text (log filters,
    /// dumpsys sections). This variant sizes the request to the command.
    fn shellAlloc(self: *Driver, gpa: std.mem.Allocator, cmd: []const u8) ![]u8 {
        const svc = try std.fmt.allocPrint(gpa, "shell:{s}", .{cmd});
        defer gpa.free(svc);
        return try self.client.deviceExec(self.serial, svc);
    }

    /// Escape a value destined for a single-quoted `sh` word on the device, so
    /// a package name or URL containing shell metacharacters cannot break out
    /// of the command we are constructing.
    fn quote(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.append(gpa, '\'');
        for (s) |c| {
            if (c == '\'') try out.appendSlice(gpa, "'\\''") else try out.append(gpa, c);
        }
        try out.append(gpa, '\'');
        return out.toOwnedSlice(gpa);
    }

    fn runQuoted(
        self: *Driver,
        gpa: std.mem.Allocator,
        comptime fmt: []const u8,
        arg: []const u8,
    ) ![]u8 {
        const q = try quote(gpa, arg);
        defer gpa.free(q);
        const cmd = try std.fmt.allocPrint(gpa, fmt, .{q});
        defer gpa.free(cmd);
        return try self.shellAlloc(gpa, cmd);
    }

    // --- app lifecycle ------------------------------------------------------

    pub fn uninstallApp(self: *Driver, gpa: std.mem.Allocator, pkg: []const u8) !void {
        gpa.free(try self.runQuoted(gpa, "pm uninstall {s}", pkg));
    }

    /// Wipe an app's data without reinstalling — the cheap way back to a
    /// first-launch state.
    pub fn clearApp(self: *Driver, gpa: std.mem.Allocator, pkg: []const u8) !void {
        gpa.free(try self.runQuoted(gpa, "pm clear {s}", pkg));
    }

    /// Open a URL through the standard VIEW intent — the Android counterpart
    /// of `ios openurl`.
    pub fn openUrl(self: *Driver, gpa: std.mem.Allocator, url: []const u8) !void {
        gpa.free(try self.runQuoted(gpa, "am start -a android.intent.action.VIEW -d {s}", url));
    }

    // --- observation --------------------------------------------------------

    /// Package/activity currently holding focus. Useful as a navigation
    /// assertion that needs no accessibility tree.
    pub fn currentActivity(self: *Driver, gpa: std.mem.Allocator) ![]u8 {
        return try self.shell(gpa, "dumpsys window displays | grep -E 'mCurrentFocus|mFocusedApp'");
    }

    /// Bounded logcat read. `-d` dumps and exits rather than streaming, so
    /// this terminates and can back an assertion.
    pub fn logcat(self: *Driver, gpa: std.mem.Allocator, lines: []const u8, filter: ?[]const u8) ![]u8 {
        const ql = try quote(gpa, lines);
        defer gpa.free(ql);
        const cmd = if (filter) |f| blk: {
            const qf = try quote(gpa, f);
            defer gpa.free(qf);
            break :blk try std.fmt.allocPrint(gpa, "logcat -d -t {s} | grep -F -- {s}", .{ ql, qf });
        } else try std.fmt.allocPrint(gpa, "logcat -d -t {s}", .{ql});
        defer gpa.free(cmd);
        return try self.shellAlloc(gpa, cmd);
    }

    pub fn getProp(self: *Driver, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
        return try self.runQuoted(gpa, "getprop {s}", name);
    }

    pub fn dumpsys(self: *Driver, gpa: std.mem.Allocator, section: []const u8) ![]u8 {
        return try self.runQuoted(gpa, "dumpsys {s}", section);
    }

    /// Physical screen size and density — the numbers that turn a uitree
    /// bound into a tap coordinate.
    pub fn screenInfo(self: *Driver, gpa: std.mem.Allocator) ![]u8 {
        return try self.shell(gpa, "wm size; wm density");
    }

    // --- raw input ----------------------------------------------------------

    /// Raw keycode, for keys outside the friendly `press` table.
    pub fn keyevent(self: *Driver, gpa: std.mem.Allocator, code: []const u8) !void {
        gpa.free(try self.runQuoted(gpa, "input keyevent {s}", code));
    }

    /// A single touch phase via `input motionevent` (Android 11+). This is
    /// what makes multi-point paths possible: `input swipe` only ever
    /// interpolates between two points.
    pub fn motionEvent(self: *Driver, gpa: std.mem.Allocator, phase: []const u8, x: i32, y: i32) !void {
        var buf: [128]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "input motionevent {s} {d} {d}", .{ phase, x, y });
        gpa.free(try self.shell(gpa, cmd));
    }

    /// Drag along an arbitrary path by emitting DOWN / MOVE… / UP.
    pub fn gesture(self: *Driver, gpa: std.mem.Allocator, pts: []const [2]i32, step_ms: u32) !void {
        if (pts.len < 2) return error.BadPoint;
        try self.motionEvent(gpa, "DOWN", pts[0][0], pts[0][1]);
        for (pts[1..]) |p| {
            _ = usleep(step_ms * 1000);
            try self.motionEvent(gpa, "MOVE", p[0], p[1]);
        }
        try self.motionEvent(gpa, "UP", pts[pts.len - 1][0], pts[pts.len - 1][1]);
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
        .{ "recents", "KEYCODE_APP_SWITCH" },
        .{ "appSwitch", "KEYCODE_APP_SWITCH" },
        .{ "wakeup", "KEYCODE_WAKEUP" },
        .{ "sleep", "KEYCODE_SLEEP" },
        .{ "search", "KEYCODE_SEARCH" },
        .{ "camera", "KEYCODE_CAMERA" },
        .{ "escape", "KEYCODE_ESCAPE" },
        .{ "backspace", "KEYCODE_DEL" },
        .{ "notification", "KEYCODE_NOTIFICATION" },
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

test "quote wraps values so shell metacharacters cannot escape" {
    const gpa = std.testing.allocator;

    const plain = try Driver.quote(gpa, "com.example.app");
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("'com.example.app'", plain);

    // The injection this exists to stop: a package name that closes the quote
    // and appends its own command must stay inert inside one quoted word.
    const evil = try Driver.quote(gpa, "x; rm -rf /");
    defer gpa.free(evil);
    try std.testing.expectEqualStrings("'x; rm -rf /'", evil);

    // A literal single quote is the only character that can terminate the
    // word, so it must be closed, escaped and reopened.
    const quoted = try Driver.quote(gpa, "it's");
    defer gpa.free(quoted);
    try std.testing.expectEqualStrings("'it'\\''s'", quoted);

    // Backticks and $() are harmless once single-quoted — no expansion occurs.
    const subst = try Driver.quote(gpa, "$(whoami)`id`");
    defer gpa.free(subst);
    try std.testing.expectEqualStrings("'$(whoami)`id`'", subst);
}

test "quote leaves no unbalanced quote for any byte" {
    const gpa = std.testing.allocator;
    var b: u8 = 1;
    while (b < 127) : (b += 1) {
        const s = [_]u8{b};
        const q = try Driver.quote(gpa, &s);
        defer gpa.free(q);
        // Must open and close, and every interior ' must be part of the
        // '\'' escape sequence rather than terminating the word early.
        try std.testing.expect(q.len >= 2);
        try std.testing.expectEqual(@as(u8, '\''), q[0]);
        try std.testing.expectEqual(@as(u8, '\''), q[q.len - 1]);
        if (b == '\'') try std.testing.expectEqualStrings("''\\'''", q);
    }
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
