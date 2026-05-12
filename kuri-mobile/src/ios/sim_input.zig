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
