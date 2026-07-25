//! Native CGEvent-based mouse/keyboard input targeting Simulator.app.
//! We deliberately avoid `cliclick` and other external binaries — only
//! ApplicationServices.framework is required.
//!
//! Events are delivered to Simulator.app *by pid* via `CGEventPostToPid`
//! rather than injected into the global HID stream with `CGEventPost`.
//! That distinction is the whole reason this tool is usable on a machine
//! someone is working on: a HID-tap post goes to whatever window happens to
//! be frontmost, which forced kuri to raise Simulator.app first — stealing
//! focus and warping the cursor out from under the user on every tap. A
//! pid-targeted post lands in Simulator's own event queue, so the simulator
//! can be driven in the background with the cursor left alone.
//!
//! `setTargetPid` must be called before any input; with no target set these
//! fall back to the old global-tap behaviour, which is correct only when
//! Simulator.app is already frontmost.
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
extern "c" fn CGEventPostToPid(pid: i32, event: CGEventRef) void;
extern "c" fn CFRelease(cf: ?*const anyopaque) void;

/// Simulator.app's pid, when the caller has resolved one. Process-global
/// because a CLI run drives exactly one simulator and threading it through
/// every input entry point would add a parameter that is never anything else.
var target_pid: ?i32 = null;

/// Direct subsequent events at a specific process. Passing null restores the
/// global-HID-tap behaviour, which requires the target to be frontmost.
pub fn setTargetPid(pid: ?i32) void {
    target_pid = pid;
}

/// Deliver an event to the target process, or to the global tap if none was
/// set. Releases the event.
fn post(ev: CGEventRef) void {
    if (ev == null) return;
    if (target_pid) |pid| {
        CGEventPostToPid(pid, ev);
    } else {
        CGEventPost(kCGHIDEventTap, ev);
    }
    CFRelease(@ptrCast(ev));
}

fn postMouse(t: u32, p: CGPoint) void {
    post(CGEventCreateMouseEvent(null, t, p, kCGMouseButtonLeft));
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

/// Drag along an arbitrary path. `swipe` is the two-point case; this exists
/// for motions whose shape matters — an arc that dismisses a sheet, an
/// L-shaped drag, a signature — where interpolating straight from first to
/// last point would produce a different gesture entirely.
///
/// `duration_ms` is spread across the whole path, so each leg gets a share
/// proportional to the number of legs rather than a fixed per-leg cost.
pub fn gesture(points: []const CGPoint, duration_ms: u64) void {
    if (builtin.os.tag != .macos) return;
    if (points.len < 2) return;

    const legs: u64 = @intCast(points.len - 1);
    const min_dur: u64 = 80;
    const total = if (duration_ms < min_dur) min_dur else duration_ms;
    const step_ms: u64 = 16;

    // Total interpolation steps, split evenly between legs. At least 3 per leg
    // so even a long path still reads as a drag and not a teleport.
    var per_leg: u64 = (total / step_ms) / legs;
    if (per_leg < 3) per_leg = 3;
    if (per_leg > 120) per_leg = 120;

    postMouse(kCGEventMouseMoved, points[0]);
    postMouse(kCGEventLeftMouseDown, points[0]);
    sleepMs(20);

    var leg: usize = 0;
    while (leg < points.len - 1) : (leg += 1) {
        const a = points[leg];
        const b = points[leg + 1];
        var i: u64 = 1;
        while (i <= per_leg) : (i += 1) {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(per_leg));
            postMouse(kCGEventLeftMouseDragged, .{
                .x = a.x + (b.x - a.x) * t,
                .y = a.y + (b.y - a.y) * t,
            });
            sleepMs(step_ms);
        }
    }
    postMouse(kCGEventLeftMouseUp, points[points.len - 1]);
}

/// Raw touch primitives, for gestures the named commands don't cover.
///
/// These deliberately leave the button held across process exits: `touch down`
/// followed later by `touch up` is the whole point. That also means a stray
/// `down` with no matching `up` leaves the Simulator with a stuck press.
pub fn touchDown(p: CGPoint) void {
    if (builtin.os.tag != .macos) return;
    postMouse(kCGEventMouseMoved, p);
    postMouse(kCGEventLeftMouseDown, p);
}

pub fn touchMove(p: CGPoint) void {
    if (builtin.os.tag != .macos) return;
    postMouse(kCGEventLeftMouseDragged, p);
}

pub fn touchUp(p: CGPoint) void {
    if (builtin.os.tag != .macos) return;
    postMouse(kCGEventLeftMouseUp, p);
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
extern "c" fn CGEventKeyboardSetUnicodeString(
    event: CGEventRef,
    stringLength: c_ulong,
    unicodeString: [*]const u16,
) void;

/// Type arbitrary text by attaching a Unicode payload to a keyboard event,
/// rather than mapping characters onto virtual keycodes.
///
/// This replaces an `osascript ... keystroke` call. AppleScript's keystroke
/// is delivered to whatever application is frontmost, so the old path was
/// only correct if kuri first raised Simulator.app — meaning `ios type` had
/// to steal the user's window, and would otherwise type into whatever they
/// were working in. A Unicode CGEvent posted to Simulator's pid has neither
/// problem, and drops the osascript dependency for this path entirely.
///
/// Events carry a bounded chunk each because CGEvent's Unicode payload is not
/// meant for unbounded strings; 16 UTF-16 units per event is comfortably
/// within what the API handles.
pub fn typeUtf16(units: []const u16) void {
    if (builtin.os.tag != .macos) return;
    var i: usize = 0;
    while (i < units.len) {
        const end = @min(i + 16, units.len);
        const chunk = units[i..end];
        for ([_]bool{ true, false }) |is_down| {
            const ev = CGEventCreateKeyboardEvent(null, 0, is_down);
            if (ev == null) continue;
            CGEventKeyboardSetUnicodeString(ev, @intCast(chunk.len), chunk.ptr);
            post(ev);
        }
        // A short gap keeps fast typing from outrunning the text field's own
        // input handling, which drops characters when events arrive back to back.
        sleepMs(8);
        i = end;
    }
}

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
    post(ev);
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
