//! Native CGEvent-based mouse/keyboard input targeting the focused window
//! (Simulator.app, after we activate it). We deliberately avoid `cliclick`
//! and other external binaries — only ApplicationServices.framework and
//! `osascript` (already shipped with macOS) are required.
//!
//! Coordinates passed in here are *macOS screen points* (the global desktop
//! coordinate space CGEvent expects). The conversion from "device-pixel"
//! coordinates a user types on the CLI into screen points happens in
//! sim_window.zig — this module is intentionally dumb about iOS.
//!
//! macOS only.

const std = @import("std");
const builtin = @import("builtin");

// --- Minimal extern decls so we don't need a full @cImport tree ---
// (Constants from CGEventTypes.h / CGEvent.h.)

pub const CGPoint = extern struct { x: f64, y: f64 };

const CGEventRef = ?*opaque {};
const CGEventSourceRef = ?*opaque {};

const kCGEventLeftMouseDown: u32 = 1;
const kCGEventLeftMouseUp: u32 = 2;
const kCGEventMouseMoved: u32 = 5;
const kCGEventLeftMouseDragged: u32 = 6;
const kCGMouseButtonLeft: u32 = 0;
const kCGHIDEventTap: u32 = 0;

extern "c" fn CGEventCreateMouseEvent(
    source: CGEventSourceRef,
    mouseType: u32,
    mouseCursorPosition: CGPoint,
    mouseButton: u32,
) CGEventRef;
extern "c" fn CGEventPost(tap: u32, event: CGEventRef) void;
extern "c" fn CFRelease(cf: ?*const anyopaque) void;

fn postMouse(t: u32, p: CGPoint) void {
    const ev = CGEventCreateMouseEvent(null, t, p, kCGMouseButtonLeft);
    if (ev == null) return;
    CGEventPost(kCGHIDEventTap, ev);
    CFRelease(@ptrCast(ev));
}

fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}

/// Single tap at a screen-point.
pub fn tap(p: CGPoint) void {
    if (builtin.os.tag != .macos) return;
    // Move first so the OS routes the click to the window under that point.
    postMouse(kCGEventMouseMoved, p);
    postMouse(kCGEventLeftMouseDown, p);
    sleepMs(40);
    postMouse(kCGEventLeftMouseUp, p);
}

/// Double tap (two quick taps at the same point).
pub fn doubleTap(p: CGPoint) void {
    if (builtin.os.tag != .macos) return;
    tap(p);
    sleepMs(60);
    tap(p);
}

/// Long press: mouse down, hold for `hold_ms`, mouse up.
pub fn longPress(p: CGPoint, hold_ms: u64) void {
    if (builtin.os.tag != .macos) return;
    postMouse(kCGEventMouseMoved, p);
    postMouse(kCGEventLeftMouseDown, p);
    sleepMs(hold_ms);
    postMouse(kCGEventLeftMouseUp, p);
}

/// Swipe / pan. Linear interpolation between (a) and (b) over `duration_ms`,
/// posting kCGEventLeftMouseDragged events every ~16ms (~60fps) so iOS
/// recognises the motion as a pan gesture rather than a tap.
pub fn swipe(a: CGPoint, b: CGPoint, duration_ms: u64) void {
    if (builtin.os.tag != .macos) return;
    const min_dur: u64 = 80;
    const dur = if (duration_ms < min_dur) min_dur else duration_ms;
    const step_ms: u64 = 16;
    var steps: u64 = dur / step_ms;
    if (steps < 6) steps = 6;
    if (steps > 240) steps = 240;

    postMouse(kCGEventMouseMoved, a);
    postMouse(kCGEventLeftMouseDown, a);
    sleepMs(20);

    var i: u64 = 1;
    while (i <= steps) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const p = CGPoint{
            .x = a.x + (b.x - a.x) * t,
            .y = a.y + (b.y - a.y) * t,
        };
        postMouse(kCGEventLeftMouseDragged, p);
        sleepMs(step_ms);
    }
    postMouse(kCGEventLeftMouseUp, b);
}

// --- Keyboard ---------------------------------------------------------------
// `type` (in cli.zig) routes plain text through System Events `keystroke`,
// which is Unicode-safe and needs no keycode table. That path cannot express
// modified keys, so hardware-keyboard shortcuts — Command-Return being the
// motivating case — go through CGEvent with an explicit virtual keycode and
// modifier flag set.

extern "c" fn CGEventCreateKeyboardEvent(
    source: CGEventSourceRef,
    virtualKey: u16,
    keyDown: bool,
) CGEventRef;
extern "c" fn CGEventSetFlags(event: CGEventRef, flags: u64) void;

/// CGEventFlags bits (CGEventTypes.h).
pub const mod_shift: u64 = 0x00020000;
pub const mod_control: u64 = 0x00040000;
pub const mod_option: u64 = 0x00080000;
pub const mod_command: u64 = 0x00100000;

pub const NamedKey = struct { name: []const u8, code: u16 };

/// Virtual keycodes from Carbon's Events.h. Only the keys that matter for
/// driving an iOS app are listed; extend as needed.
pub const named_keys = [_]NamedKey{
    .{ .name = "return", .code = 36 },
    .{ .name = "enter", .code = 76 },
    .{ .name = "tab", .code = 48 },
    .{ .name = "space", .code = 49 },
    .{ .name = "delete", .code = 51 },
    .{ .name = "escape", .code = 53 },
    .{ .name = "left", .code = 123 },
    .{ .name = "right", .code = 124 },
    .{ .name = "down", .code = 125 },
    .{ .name = "up", .code = 126 },
};

pub fn lookupKey(name: []const u8) ?u16 {
    for (named_keys) |k| {
        if (std.ascii.eqlIgnoreCase(k.name, name)) return k.code;
    }
    return null;
}

/// Map a modifier name to its CGEventFlags bit. Accepts the common aliases
/// so `--cmd`, `--command` and `--meta` all work.
pub fn lookupModifier(name: []const u8) ?u64 {
    const table = .{
        .{ "cmd", mod_command },     .{ "command", mod_command }, .{ "meta", mod_command },
        .{ "shift", mod_shift },     .{ "ctrl", mod_control },    .{ "control", mod_control },
        .{ "opt", mod_option },      .{ "option", mod_option },   .{ "alt", mod_option },
    };
    inline for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(entry[0], name)) return entry[1];
    }
    return null;
}

fn postKey(code: u16, flags: u64, down: bool) void {
    const ev = CGEventCreateKeyboardEvent(null, code, down);
    if (ev == null) return;
    if (flags != 0) CGEventSetFlags(ev, flags);
    CGEventPost(kCGHIDEventTap, ev);
    CFRelease(@ptrCast(ev));
}

/// Press and release `code` with `flags` held. Flags are applied to both the
/// down and up events so the receiving app sees a consistent modifier state.
pub fn keyPress(code: u16, flags: u64) void {
    if (builtin.os.tag != .macos) return;
    postKey(code, flags, true);
    sleepMs(30);
    postKey(code, flags, false);
}

test "lookupKey is case-insensitive and covers Return" {
    try std.testing.expectEqual(@as(u16, 36), lookupKey("return").?);
    try std.testing.expectEqual(@as(u16, 36), lookupKey("RETURN").?);
    try std.testing.expectEqual(@as(u16, 53), lookupKey("escape").?);
    try std.testing.expect(lookupKey("f13") == null);
}

test "lookupModifier accepts aliases" {
    try std.testing.expectEqual(mod_command, lookupModifier("cmd").?);
    try std.testing.expectEqual(mod_command, lookupModifier("Command").?);
    try std.testing.expectEqual(mod_option, lookupModifier("alt").?);
    try std.testing.expectEqual(mod_control, lookupModifier("ctrl").?);
    try std.testing.expect(lookupModifier("hyper") == null);
}
