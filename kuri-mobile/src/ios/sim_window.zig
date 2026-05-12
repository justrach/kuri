//! Locate the Simulator.app window for a given UDID and convert
//! "device pixel" coordinates (matching `xcrun simctl io <udid> screenshot`)
//! into macOS *screen points* suitable for CGEvent.
//!
//! Strategy:
//!   1. Activate Simulator.app and grab its frontmost window's position+size
//!      via osascript (System Events). These are macOS points.
//!   2. Take a one-off `simctl io <udid> screenshot` to a temp PNG and read
//!      the IHDR chunk for the device's pixel resolution.
//!   3. Treat the window as: title bar at top (~28 macOS points) + content
//!      area = device_screen scaled to fit. Scale = content_h_pts / pixel_h.
//!   4. screen_x = win_x + dev_pixel_x * scale
//!      screen_y = win_y + title_bar_pts + dev_pixel_y * scale
//!
//! This keeps the user-facing coordinate model identical to Android
//! (`adb shell input tap <x_pixel> <y_pixel>`), so the same test scripts work
//! across platforms.

const std = @import("std");
const io = @import("../common/io.zig");
const sim_input = @import("sim_input.zig");

pub const WindowRect = struct { x: f64, y: f64, w: f64, h: f64 };

/// macOS title bar height in points for a standard window. Simulator.app uses
/// the regular system title bar, so this is stable across recent macOS.
const TITLE_BAR_PTS: f64 = 28.0;

/// Bring Simulator.app to the front. Without this, CGEvent posts can land
/// in whatever window currently has focus.
pub fn activate(gpa: std.mem.Allocator) !void {
    const r = try io.runCommand(gpa, &.{
        "osascript", "-e", "tell application \"Simulator\" to activate",
    }, 64 * 1024);
    gpa.free(r.stdout);
    // Give the WindowServer a beat to bring the window forward.
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 120 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
}

/// Read frontmost Simulator window rect (macOS points, top-left origin).
pub fn frontWindowRect(gpa: std.mem.Allocator) !WindowRect {
    // Returns "x, y, w, h" on a single line.
    const script =
        \\tell application "System Events"
        \\  tell process "Simulator"
        \\    set p to position of window 1
        \\    set s to size of window 1
        \\    return (item 1 of p as string) & "," & (item 2 of p as string) & "," & (item 1 of s as string) & "," & (item 2 of s as string)
        \\  end tell
        \\end tell
    ;
    const r = try io.runCommand(gpa, &.{ "osascript", "-e", script }, 4096);
    defer gpa.free(r.stdout);
    return parseRect(std.mem.trim(u8, r.stdout, " \t\r\n"));
}

fn parseRect(s: []const u8) !WindowRect {
    var it = std.mem.splitScalar(u8, s, ',');
    const xs = it.next() orelse return error.BadRect;
    const ys = it.next() orelse return error.BadRect;
    const ws = it.next() orelse return error.BadRect;
    const hs = it.next() orelse return error.BadRect;
    return .{
        .x = try std.fmt.parseFloat(f64, std.mem.trim(u8, xs, " ")),
        .y = try std.fmt.parseFloat(f64, std.mem.trim(u8, ys, " ")),
        .w = try std.fmt.parseFloat(f64, std.mem.trim(u8, ws, " ")),
        .h = try std.fmt.parseFloat(f64, std.mem.trim(u8, hs, " ")),
    };
}

pub const PixelSize = struct { w: u32, h: u32 };

/// Take a one-off screenshot to a temp PNG and read the IHDR chunk.
/// We avoid linking against a PNG decoder — the IHDR is at a fixed offset
/// and is exactly what we need (image pixel width/height).
pub fn devicePixelSize(gpa: std.mem.Allocator, udid: []const u8) !PixelSize {
    // Mkstemp-style path; /tmp is fine for a short-lived screenshot.
    var path_buf: [256]u8 = undefined;
    const stamp: i64 = @intCast(std.c.getpid());
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/kuri-mobile-sim-{d}.png", .{stamp});

    const r = try io.runCommand(gpa, &.{
        "xcrun", "simctl", "io", udid, "screenshot", path,
    }, 1024);
    gpa.free(r.stdout);

    // Read first 24 bytes: 8-byte PNG signature + 4 chunk len + 4 "IHDR"
    // + 4 width + 4 height (big-endian).
    var pbuf: [256]u8 = undefined;
    if (path.len >= pbuf.len) return error.NameTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = std.c.open(pbuf[0..path.len :0], .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);

    var hdr: [24]u8 = undefined;
    const n = std.c.read(fd, &hdr, hdr.len);
    if (n < 24) return error.ShortRead;
    if (!std.mem.eql(u8, hdr[0..8], "\x89PNG\r\n\x1a\n")) return error.NotPng;
    if (!std.mem.eql(u8, hdr[12..16], "IHDR")) return error.NoIhdr;
    const w = std.mem.readInt(u32, hdr[16..20], .big);
    const h = std.mem.readInt(u32, hdr[20..24], .big);

    // Best-effort cleanup; we don't care if it fails.
    _ = std.c.unlink(pbuf[0..path.len :0]);

    return .{ .w = w, .h = h };
}

/// Convert a device pixel coord (matching the screenshot's pixel grid) to
/// a macOS screen point we can hand to CGEvent.
pub fn deviceToScreen(
    win: WindowRect,
    px: PixelSize,
    dev_x: f64,
    dev_y: f64,
) sim_input.CGPoint {
    const content_h = win.h - TITLE_BAR_PTS;
    const scale_x = win.w / @as(f64, @floatFromInt(px.w));
    const scale_y = content_h / @as(f64, @floatFromInt(px.h));
    return .{
        .x = win.x + dev_x * scale_x,
        .y = win.y + TITLE_BAR_PTS + dev_y * scale_y,
    };
}

test "parseRect basic" {
    const r = try parseRect("100, 200, 400, 800");
    try std.testing.expectEqual(@as(f64, 100), r.x);
    try std.testing.expectEqual(@as(f64, 200), r.y);
    try std.testing.expectEqual(@as(f64, 400), r.w);
    try std.testing.expectEqual(@as(f64, 800), r.h);
}

test "deviceToScreen maps origin and far corner" {
    const win = WindowRect{ .x = 100, .y = 50, .w = 400, .h = 828 }; // content = 800
    const px = PixelSize{ .w = 1200, .h = 2400 }; // 3x scale
    const a = deviceToScreen(win, px, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 100), a.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 78), a.y, 0.001);
    const b = deviceToScreen(win, px, 1200, 2400);
    try std.testing.expectApproxEqAbs(@as(f64, 500), b.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 878), b.y, 0.001);
}
