//! Single source of truth for the `ios` command surface.
//!
//! Both the human help text and the machine-readable `ios tools` output are
//! rendered from this one table. Keeping them derived from the same data is
//! the point: a command that gains a flag but not a help line is the usual
//! way a CLI's documentation goes quietly stale, and an agent reading
//! `ios tools --json` to decide what it can call cannot afford that drift.
//!
//! Rendering lives in common/toolinfo.zig so iOS and Android describe
//! themselves identically.

const std = @import("std");
const toolinfo = @import("../common/toolinfo.zig");

pub const Tool = toolinfo.Tool;
pub const Scope = toolinfo.Scope;

pub const all = [_]Tool{
    // --- discovery / lifecycle ---------------------------------------------
    .{
        .name = "tools",
        .args = "[--json]",
        .summary = "list every ios command, its arguments and where it can run",
        .category = "meta",
        .scope = .both,
    },
    .{
        .name = "list-devices",
        .aliases = &.{"devices"},
        .summary = "list simulators and physically attached devices",
        .category = "lifecycle",
        .scope = .both,
    },
    .{
        .name = "boot",
        .flags = &.{"--udid"},
        .summary = "boot a simulator",
        .category = "lifecycle",
        .scope = .virtual,
    },
    .{
        .name = "shutdown",
        .flags = &.{"--udid"},
        .summary = "shut down a simulator",
        .category = "lifecycle",
        .scope = .virtual,
    },
    .{
        .name = "erase",
        .flags = &.{"--udid"},
        .summary = "erase a simulator back to factory state (shuts it down first)",
        .category = "lifecycle",
        .scope = .virtual,
    },
    .{
        .name = "open-sim",
        .summary = "launch Simulator.app and bring it to the front",
        .category = "lifecycle",
        .scope = .virtual,
    },
    .{
        .name = "install",
        .args = "<path.app>",
        .summary = "install a built .app bundle onto the simulator",
        .category = "lifecycle",
        .scope = .virtual,
    },
    .{
        .name = "uninstall",
        .args = "<bundle-id>",
        .summary = "remove an installed app",
        .category = "lifecycle",
        .scope = .virtual,
    },
    .{
        .name = "launch",
        .args = "<bundle-id>",
        .flags = &.{ "--udid", "--simulator", "--device" },
        .summary = "launch an app by bundle id",
        .category = "lifecycle",
        .scope = .both,
    },
    .{
        .name = "terminate",
        .args = "<bundle-id>",
        .flags = &.{ "--udid", "--simulator", "--device" },
        .summary = "terminate a running app",
        .category = "lifecycle",
        .scope = .both,
    },
    .{
        .name = "list-apps",
        .flags = &.{"--udid"},
        .summary = "list installed apps and their bundle ids",
        .category = "lifecycle",
        .scope = .virtual,
    },
    .{
        .name = "openurl",
        .aliases = &.{"navigate"},
        .args = "<url>",
        .summary = "open a URL in its default handler (https -> Safari)",
        .category = "lifecycle",
        .scope = .virtual,
    },
    .{
        .name = "background",
        .args = "[bundle-id]",
        .flags = &.{"--for"},
        .summary = "press Home, wait, then re-foreground the app",
        .category = "lifecycle",
        .scope = .virtual,
    },

    // --- observation --------------------------------------------------------
    .{
        .name = "screenshot",
        .args = "[path.png]",
        .flags = &.{"--udid"},
        .summary = "capture a PNG of the simulator screen",
        .category = "observe",
        .scope = .virtual,
    },
    .{
        .name = "uitree",
        .summary = "dump the app's accessibility tree (role, id, label, device-pixel bounds)",
        .category = "observe",
        .scope = .virtual,
    },
    .{
        .name = "find",
        .flags = &.{"--label"},
        .summary = "print elements matching a label/identifier, with tap-ready centroids",
        .category = "observe",
        .scope = .virtual,
    },
    .{
        .name = "wait-for-ui",
        .flags = &.{ "--label", "--timeout", "--absent" },
        .summary = "block until an element appears (or disappears with --absent)",
        .category = "observe",
        .scope = .virtual,
    },
    .{
        .name = "record-video",
        .args = "<path.mp4>",
        .flags = &.{"--for"},
        .summary = "record the screen for a bounded duration",
        .category = "observe",
        .scope = .virtual,
    },
    .{
        .name = "log",
        .flags = &.{ "--last", "--predicate" },
        .summary = "bounded os_log query (terminates, so it can back an assertion)",
        .category = "observe",
        .scope = .virtual,
    },

    // --- input --------------------------------------------------------------
    .{
        .name = "tap",
        .args = "<x> <y>",
        .flags = &.{"--label"},
        .summary = "tap a point, or an element by accessibility label",
        .category = "input",
        .scope = .virtual,
    },
    .{
        .name = "doubletap",
        .aliases = &.{"dbltap"},
        .args = "<x> <y>",
        .flags = &.{"--label"},
        .summary = "double tap",
        .category = "input",
        .scope = .virtual,
    },
    .{
        .name = "longpress",
        .aliases = &.{"long-press"},
        .args = "<x> <y> [hold_ms]",
        .flags = &.{"--label"},
        .summary = "press and hold (default 500ms)",
        .category = "input",
        .scope = .virtual,
    },
    .{
        .name = "swipe",
        .aliases = &.{ "scroll", "pan" },
        .args = "<x1> <y1> <x2> <y2> [duration_ms]",
        .summary = "drag between two points",
        .category = "input",
        .scope = .virtual,
    },
    .{
        .name = "gesture",
        .aliases = &.{"drag"},
        .args = "<x1,y1> <x2,y2> [x3,y3 ...]",
        .flags = &.{"--for"},
        .summary = "drag along a multi-point path (arcs, L-shapes, signatures)",
        .category = "input",
        .scope = .virtual,
    },
    .{
        .name = "touch",
        .args = "<down|up|move> <x> <y>",
        .summary = "raw touch primitive; compose gestures the built-ins don't cover",
        .category = "input",
        .scope = .virtual,
    },
    .{
        .name = "type",
        .args = "<text...>",
        .summary = "type Unicode text into the focused field",
        .category = "input",
        .scope = .virtual,
    },
    .{
        .name = "key",
        .args = "<name>",
        .flags = &.{ "--cmd", "--shift", "--ctrl", "--opt" },
        .summary = "press a named key with optional modifiers (e.g. `key return --cmd`)",
        .category = "input",
        .scope = .virtual,
    },
    .{
        .name = "key-sequence",
        .args = "<name> [name ...]",
        .summary = "press several named keys in order",
        .category = "input",
        .scope = .virtual,
    },
    .{
        .name = "button",
        .args = "<home|lock|volup|voldown|action|rotate>",
        .summary = "press a hardware button via the Simulator's own a11y tree",
        .category = "input",
        .scope = .virtual,
    },
    .{
        .name = "batch",
        .args = "<action> [action ...]",
        .summary = "run several actions in one process, e.g. tap:120,400 type:hi key:return",
        .category = "input",
        .scope = .virtual,
    },

    // --- device state -------------------------------------------------------
    .{
        .name = "privacy",
        .args = "<grant|revoke|reset> <service> [bundle-id]",
        .summary = "set a TCC permission (camera is not exposed by simctl)",
        .category = "state",
        .scope = .virtual,
    },
    .{
        .name = "ui",
        .args = "<appearance|content-size|increase-contrast> [value]",
        .summary = "appearance and Dynamic Type settings; prints current value if omitted",
        .category = "state",
        .scope = .virtual,
    },
    .{
        .name = "status-bar",
        .aliases = &.{"status_bar"},
        .args = "override --time 9:41 ... | clear",
        .summary = "pin the status bar so screenshots are comparable across runs",
        .category = "state",
        .scope = .virtual,
    },
    .{
        .name = "set-location",
        .args = "<lat> <lon>",
        .summary = "set the simulated GPS location",
        .category = "state",
        .scope = .virtual,
    },
    .{
        .name = "reset-location",
        .summary = "clear the simulated GPS location",
        .category = "state",
        .scope = .virtual,
    },
    .{
        .name = "keyboard",
        .args = "<on|off>",
        .summary = "connect/disconnect the hardware keyboard (affects whether the software keyboard shows)",
        .category = "state",
        .scope = .virtual,
    },
};

const categories = [_]toolinfo.Category{
    .{ .key = "meta", .title = "Discovery" },
    .{ .key = "lifecycle", .title = "Device & app lifecycle" },
    .{ .key = "observe", .title = "Observation" },
    .{ .key = "input", .title = "Input (Simulator only, device-pixel coords matching screenshot)" },
    .{ .key = "state", .title = "Device state" },
};


pub fn lookup(name: []const u8) ?Tool {
    return toolinfo.lookup(&all, name);
}

pub fn renderText(gpa: std.mem.Allocator) ![]u8 {
    return toolinfo.renderText(gpa, &all, &categories);
}

pub fn renderJson(gpa: std.mem.Allocator) ![]u8 {
    return toolinfo.renderJson(gpa, .ios, &all);
}

test "lookup resolves canonical names and aliases" {
    try std.testing.expect(lookup("tap") != null);
    try std.testing.expectEqualStrings("swipe", lookup("scroll").?.name);
    try std.testing.expectEqualStrings("doubletap", lookup("dbltap").?.name);
    try std.testing.expectEqualStrings("gesture", lookup("drag").?.name);
    try std.testing.expect(lookup("definitely-not-a-command") == null);
}

test "table satisfies the shared invariants" {
    try toolinfo.verifyTable(&all, &categories);
}

test "json round-trips with every tool present" {
    try toolinfo.verifyJson(.ios, &all);
}

test "renderText mentions every tool name" {
    const gpa = std.testing.allocator;
    const text = try renderText(gpa);
    defer gpa.free(text);
    for (all) |t| try std.testing.expect(std.mem.indexOf(u8, text, t.name) != null);
}
