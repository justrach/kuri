//! Single source of truth for the `android` command surface.
//!
//! Mirrors ios/tools.zig; rendering is shared via common/toolinfo.zig so the
//! two platforms describe themselves identically and an agent can consume
//! `android tools --json` and `ios tools --json` with one parser.
//!
//! Almost everything here rides the adb wire protocol's `shell:` service, so
//! unlike iOS there is no simulator/device split — an emulator and a handset
//! answer the same commands. Scopes are `.both` accordingly.

const std = @import("std");
const toolinfo = @import("../common/toolinfo.zig");

pub const Tool = toolinfo.Tool;
pub const Scope = toolinfo.Scope;

pub const all = [_]Tool{
    // --- discovery / lifecycle ---------------------------------------------
    .{
        .name = "tools",
        .args = "[--json]",
        .summary = "list every android command, its arguments and where it can run",
        .category = "meta",
        .scope = .both,
    },
    .{
        .name = "list-devices",
        .aliases = &.{"devices"},
        .summary = "list attached devices and emulators with their adb state",
        .category = "lifecycle",
        .scope = .both,
    },
    .{
        .name = "launch",
        .args = "<package>",
        .summary = "launch an app via its LAUNCHER intent",
        .category = "lifecycle",
        .scope = .both,
    },
    .{
        .name = "terminate",
        .args = "<package>",
        .summary = "force-stop an app",
        .category = "lifecycle",
        .scope = .both,
    },
    .{
        .name = "list-apps",
        .summary = "list installed package names",
        .category = "lifecycle",
        .scope = .both,
    },
    .{
        .name = "uninstall",
        .args = "<package>",
        .summary = "remove an installed app",
        .category = "lifecycle",
        .scope = .both,
    },
    .{
        .name = "clear",
        .args = "<package>",
        .summary = "wipe an app's data — the cheap way back to a first-launch state",
        .category = "lifecycle",
        .scope = .both,
    },
    .{
        .name = "openurl",
        .aliases = &.{"navigate"},
        .args = "<url>",
        .summary = "open a URL through the standard VIEW intent",
        .category = "lifecycle",
        .scope = .both,
    },

    // --- observation --------------------------------------------------------
    .{
        .name = "screenshot",
        .args = "[path.png]",
        .summary = "capture a PNG of the screen",
        .category = "observe",
        .scope = .both,
    },
    .{
        .name = "uitree",
        .summary = "dump the uiautomator hierarchy as a flat element list with bounds",
        .category = "observe",
        .scope = .both,
    },
    .{
        .name = "find",
        .flags = &.{"--label"},
        .summary = "print elements matching a label/id, with tap-ready centroids",
        .category = "observe",
        .scope = .both,
    },
    .{
        .name = "wait-for-ui",
        .flags = &.{ "--label", "--timeout", "--absent" },
        .summary = "block until an element appears (or disappears with --absent)",
        .category = "observe",
        .scope = .both,
    },
    .{
        .name = "current-activity",
        .summary = "package/activity holding focus — a navigation assertion needing no tree",
        .category = "observe",
        .scope = .both,
    },
    .{
        .name = "logcat",
        .flags = &.{ "--last", "--predicate" },
        .summary = "bounded logcat read (-d, so it terminates and can back an assertion)",
        .category = "observe",
        .scope = .both,
    },
    .{
        .name = "screen-info",
        .summary = "physical size and density — turns uitree bounds into tap coordinates",
        .category = "observe",
        .scope = .both,
    },
    .{
        .name = "getprop",
        .args = "<name>",
        .summary = "read a system property",
        .category = "observe",
        .scope = .both,
    },
    .{
        .name = "dumpsys",
        .args = "<section>",
        .summary = "raw dumpsys for a service (battery, notification, power, …)",
        .category = "observe",
        .scope = .both,
    },

    // --- input --------------------------------------------------------------
    .{
        .name = "tap",
        .args = "<x> <y>",
        .flags = &.{"--label"},
        .summary = "tap a point, or an element by label",
        .category = "input",
        .scope = .both,
    },
    .{
        .name = "double-tap",
        .aliases = &.{"doubletap"},
        .args = "<x> <y>",
        .summary = "double tap",
        .category = "input",
        .scope = .both,
    },
    .{
        .name = "long-press",
        .aliases = &.{"longpress"},
        .args = "<x> <y> [hold_ms]",
        .summary = "press and hold (default 500ms)",
        .category = "input",
        .scope = .both,
    },
    .{
        .name = "swipe",
        .aliases = &.{ "scroll", "pan" },
        .args = "<x1> <y1> <x2> <y2> [duration_ms]",
        .summary = "drag between two points",
        .category = "input",
        .scope = .both,
    },
    .{
        .name = "gesture",
        .aliases = &.{"drag"},
        .args = "<x1,y1> <x2,y2> [x3,y3 ...]",
        .flags = &.{"--for"},
        .summary = "drag along a multi-point path via input motionevent (Android 11+)",
        .category = "input",
        .scope = .both,
    },
    .{
        .name = "touch",
        .args = "<down|up|move> <x> <y>",
        .summary = "raw motionevent phase, for gestures the built-ins don't cover",
        .category = "input",
        .scope = .both,
    },
    .{
        .name = "type",
        .args = "<text...>",
        .summary = "type text into the focused field",
        .category = "input",
        .scope = .both,
    },
    .{
        .name = "press",
        .args = "<home|back|menu|enter|recents|…>",
        .summary = "press a named hardware/navigation key",
        .category = "input",
        .scope = .both,
    },
    .{
        .name = "keyevent",
        .args = "<KEYCODE_* or number>",
        .summary = "send a raw keycode, for keys outside the named table",
        .category = "input",
        .scope = .both,
    },
    .{
        .name = "batch",
        .args = "<action> [action ...]",
        .summary = "run several actions over one adb session, e.g. tap:120,400 type:hi press:enter",
        .category = "input",
        .scope = .both,
    },
};

const categories = [_]toolinfo.Category{
    .{ .key = "meta", .title = "Discovery" },
    .{ .key = "lifecycle", .title = "Device & app lifecycle" },
    .{ .key = "observe", .title = "Observation" },
    .{ .key = "input", .title = "Input" },
};

pub fn lookup(name: []const u8) ?Tool {
    return toolinfo.lookup(&all, name);
}

pub fn renderText(gpa: std.mem.Allocator) ![]u8 {
    return toolinfo.renderText(gpa, &all, &categories);
}

pub fn renderJson(gpa: std.mem.Allocator) ![]u8 {
    return toolinfo.renderJson(gpa, .android, &all);
}

test "lookup resolves canonical names and aliases" {
    try std.testing.expect(lookup("tap") != null);
    try std.testing.expectEqualStrings("swipe", lookup("scroll").?.name);
    try std.testing.expectEqualStrings("gesture", lookup("drag").?.name);
    try std.testing.expectEqualStrings("openurl", lookup("navigate").?.name);
    try std.testing.expect(lookup("definitely-not-a-command") == null);
}

test "table satisfies the shared invariants" {
    try toolinfo.verifyTable(&all, &categories);
}

test "json round-trips with every tool present" {
    try toolinfo.verifyJson(.android, &all);
}
