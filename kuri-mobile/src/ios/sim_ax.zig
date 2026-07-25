//! Simulator *hardware buttons* via the macOS Accessibility API.
//!
//! Simulator.app publishes its own chrome to the host AX tree: the bezel
//! buttons (Action, Volume Up, Volume Down, Sleep/Wake) hang off the device
//! window, and the toolbar carries Home, Rotate and Save Screen. Each one
//! responds to `AXUIElementPerformAction(kAXPressAction)`, which gives us
//! Home/Lock/Volume without an on-device driver.
//!
//! Note the boundary carefully, because it is easy to over-read: this
//! exposes only Simulator.app's *own* controls. The running iOS app's a11y
//! tree is NOT bridged into host AX — verified against Xcode 26.6, both on
//! Simulator.app's pid and on the simulated app's host pid (a simulated app
//! is a real host process, but AX on it yields a single empty node), and
//! CoreSimulator no longer ships the accessibility bridge that idb once
//! used. A real iOS UI tree still requires XCUITest. See `uitree` in cli.zig.
//!
//! macOS only. Requires Accessibility permission for the calling terminal
//! (System Settings → Privacy & Security → Accessibility), the same grant
//! that CGEvent-based tap/swipe already needs.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("../common/io.zig");

const Ref = ?*anyopaque;

const kAXErrorSuccess: i32 = 0;
const kCFStringEncodingUTF8: u32 = 0x08000100;

extern "c" fn AXUIElementCreateApplication(pid: i32) Ref;
extern "c" fn AXUIElementCopyAttributeValue(element: Ref, attribute: Ref, value: *Ref) i32;
extern "c" fn AXUIElementPerformAction(element: Ref, action: Ref) i32;
extern "c" fn AXIsProcessTrusted() bool;
extern "c" fn CFStringCreateWithCString(alloc: Ref, cstr: [*:0]const u8, encoding: u32) Ref;
extern "c" fn CFStringGetCString(theString: Ref, buffer: [*]u8, bufferSize: i64, encoding: u32) bool;
extern "c" fn CFArrayGetCount(theArray: Ref) i64;
extern "c" fn CFArrayGetValueAtIndex(theArray: Ref, idx: i64) Ref;
extern "c" fn CFGetTypeID(cf: Ref) u64;
extern "c" fn CFStringGetTypeID() u64;
extern "c" fn CFArrayGetTypeID() u64;
extern "c" fn CFRelease(cf: Ref) void;
extern "c" fn CFRetain(cf: Ref) Ref;

/// Elements fetched with `CFArrayGetValueAtIndex` follow CoreFoundation's
/// Get Rule: they are owned by the array, not by us. Any element that
/// outlives the array it came from must be retained first — otherwise
/// releasing the array frees it and the caller reads freed memory.
fn retained(el: Ref) Ref {
    if (el == null) return null;
    return CFRetain(el);
}

/// A pressable Simulator control, keyed by the CLI name we accept.
pub const Button = struct {
    /// CLI-facing name.
    cli: []const u8,
    /// The AXTitle or AXDescription Simulator.app publishes for it.
    ax_label: []const u8,
};

/// Names verified against Xcode 26.6's Simulator. Bezel buttons carry an
/// AXTitle; toolbar buttons carry only an AXDescription, so lookup checks
/// both attributes rather than assuming one.
pub const buttons = [_]Button{
    .{ .cli = "home", .ax_label = "Home" },
    .{ .cli = "lock", .ax_label = "Sleep/Wake" },
    .{ .cli = "volup", .ax_label = "Volume Up" },
    .{ .cli = "voldown", .ax_label = "Volume Down" },
    .{ .cli = "action", .ax_label = "Action" },
    .{ .cli = "rotate", .ax_label = "Rotate" },
};

pub fn lookup(name: []const u8) ?Button {
    for (buttons) |b| {
        if (std.mem.eql(u8, b.cli, name)) return b;
    }
    // Accept the on-screen label too ("Volume Up"), case-insensitively.
    for (buttons) |b| {
        if (std.ascii.eqlIgnoreCase(b.ax_label, name)) return b;
    }
    return null;
}

fn cfStr(s: [*:0]const u8) Ref {
    return CFStringCreateWithCString(null, s, kCFStringEncodingUTF8);
}

/// Copy a string attribute into `out`, returning the populated slice.
fn stringAttr(el: Ref, attr: [*:0]const u8, out: []u8) ?[]const u8 {
    const key = cfStr(attr);
    defer if (key != null) CFRelease(key);
    var val: Ref = null;
    if (AXUIElementCopyAttributeValue(el, key, &val) != kAXErrorSuccess) return null;
    if (val == null) return null;
    defer CFRelease(val);
    if (CFGetTypeID(val) != CFStringGetTypeID()) return null;
    if (!CFStringGetCString(val, out.ptr, @intCast(out.len), kCFStringEncodingUTF8)) return null;
    return std.mem.sliceTo(out, 0);
}

fn matches(el: Ref, want: []const u8) bool {
    var buf: [256]u8 = undefined;
    if (stringAttr(el, "AXTitle", &buf)) |t| {
        if (std.mem.eql(u8, t, want)) return true;
    }
    if (stringAttr(el, "AXDescription", &buf)) |d| {
        if (std.mem.eql(u8, d, want)) return true;
    }
    return false;
}

/// Depth-first search for a control carrying `want` as title or description.
/// The menu bar is skipped: it is enormous (every Recent Items entry) and
/// never holds the controls we're after.
fn find(el: Ref, want: []const u8, depth: u32) Ref {
    if (depth > 8) return null;

    var role_buf: [128]u8 = undefined;
    if (stringAttr(el, "AXRole", &role_buf)) |role| {
        if (std.mem.eql(u8, role, "AXMenuBar")) return null;
    }

    // Retain at the match point, not at the call site: as the recursion
    // unwinds, every level releases its own children array, which would
    // otherwise free this element before the caller ever sees it.
    if (depth > 0 and matches(el, want)) return retained(el);

    const kids_key = cfStr("AXChildren");
    defer if (kids_key != null) CFRelease(kids_key);
    var kids: Ref = null;
    if (AXUIElementCopyAttributeValue(el, kids_key, &kids) != kAXErrorSuccess) return null;
    if (kids == null) return null;
    defer CFRelease(kids);
    if (CFGetTypeID(kids) != CFArrayGetTypeID()) return null;

    const n = CFArrayGetCount(kids);
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        const child = CFArrayGetValueAtIndex(kids, i);
        if (find(child, want, depth + 1)) |hit| return hit;
    }
    return null;
}

/// `find` already returns a retained element; this is just the named entry
/// point making the ownership contract obvious. Caller releases.
fn findRetained(root: Ref, want: []const u8) Ref {
    return find(root, want, 0);
}

/// Whether this process holds macOS Accessibility trust, which every
/// CGEvent-driven input and the whole `uitree` path depend on. Exposed so
/// `doctor` can report it as a checkable precondition rather than letting it
/// surface later as a confusing per-command failure.
pub fn accessibilityTrusted() bool {
    if (builtin.os.tag != .macos) return false;
    return AXIsProcessTrusted();
}

/// Whether Simulator.app has a window on screen. The accessibility tree hangs
/// off a window, so a running-but-windowless Simulator supports no `uitree`,
/// `find` or `wait-for-ui` — which callers need to distinguish from a missing
/// Accessibility grant, since the remedy is completely different.
pub fn hasOpenWindow(gpa: std.mem.Allocator) bool {
    if (builtin.os.tag != .macos) return false;
    if (!AXIsProcessTrusted()) return false;
    const pid = (simulatorPid(gpa) catch return false) orelse return false;
    const app = AXUIElementCreateApplication(pid);
    if (app == null) return false;
    defer CFRelease(app);
    const w = firstWindow(app) orelse return false;
    CFRelease(w);
    return true;
}

/// PID of the running Simulator.app, or null if it isn't running.
pub fn simulatorPid(gpa: std.mem.Allocator) !?i32 {
    const r = try io.runCommand(gpa, &.{ "pgrep", "-x", "Simulator" }, 4096);
    defer gpa.free(r.stdout);
    const trimmed = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    // pgrep may list several; the first is fine — they share the AX tree.
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    const first = std.mem.trim(u8, it.next() orelse return null, " \t\r");
    return std.fmt.parseInt(i32, first, 10) catch null;
}

/// Press a Simulator hardware/toolbar button by CLI name.
pub fn press(gpa: std.mem.Allocator, name: []const u8) !void {
    if (builtin.os.tag != .macos) return error.MacOsOnly;

    const btn = lookup(name) orelse return error.UnknownButton;

    if (!AXIsProcessTrusted()) return error.AccessibilityNotTrusted;

    const pid = (try simulatorPid(gpa)) orelse return error.SimulatorNotRunning;

    const app = AXUIElementCreateApplication(pid);
    if (app == null) return error.AccessibilityNotTrusted;
    defer CFRelease(app);

    const el = findRetained(app, btn.ax_label) orelse return error.ButtonNotFound;
    defer CFRelease(el);

    const action = cfStr("AXPress");
    defer if (action != null) CFRelease(action);
    if (AXUIElementPerformAction(el, action) != kAXErrorSuccess) return error.ButtonPressFailed;
}

test "lookup resolves cli names and on-screen labels" {
    try std.testing.expectEqualStrings("Home", lookup("home").?.ax_label);
    try std.testing.expectEqualStrings("Sleep/Wake", lookup("lock").?.ax_label);
    try std.testing.expectEqualStrings("Volume Up", lookup("Volume Up").?.ax_label);
    try std.testing.expectEqualStrings("Volume Up", lookup("volume up").?.ax_label);
    try std.testing.expect(lookup("nope") == null);
}

// --- iOS accessibility tree -------------------------------------------------
//
// Simulator.app *does* bridge the running iOS app's accessibility tree into
// the host AX hierarchy — but only once the simulated runtime has app
// accessibility switched on. With it off, the device-screen AXGroup is
// present but childless, which looks exactly like "no bridge exists".
//
// Verified on Xcode 26.6 from a clean `simctl erase` + boot: the AXGroup is
// empty, and after `defaults write com.apple.Accessibility
// ApplicationAccessibilityEnabled 1` inside the sim it fills with the app's
// real elements (labels, values, frames). So a driverless uitree is possible
// on the Simulator; no XCUITest bundle required.
//
// Real devices are still XCUITest-only — there is no host process to inspect.

const uitree = @import("../common/uitree.zig");
const sim_window = @import("sim_window.zig");
const simctl = @import("simctl.zig");

const kAXValueTypeCGPoint: u32 = 1;
const kAXValueTypeCGSize: u32 = 2;

const CGPointC = extern struct { x: f64, y: f64 };
const CGSizeC = extern struct { w: f64, h: f64 };

extern "c" fn AXValueGetValue(value: Ref, theType: u32, valuePtr: ?*anyopaque) bool;

/// Turn on app accessibility inside the simulated runtime. Idempotent, and
/// cheap enough to run before every dump rather than making callers
/// remember a separate setup step.
pub fn enableAppAccessibility(gpa: std.mem.Allocator, udid: []const u8) !void {
    const out = try simctl.Sim.init(udid).spawnDefaultsWrite(
        gpa,
        "com.apple.Accessibility",
        "ApplicationAccessibilityEnabled",
        "1",
    );
    gpa.free(out);
}

fn pointAttr(el: Ref, attr: [*:0]const u8) ?CGPointC {
    const key = cfStr(attr);
    defer if (key != null) CFRelease(key);
    var val: Ref = null;
    if (AXUIElementCopyAttributeValue(el, key, &val) != kAXErrorSuccess) return null;
    if (val == null) return null;
    defer CFRelease(val);
    var p: CGPointC = .{ .x = 0, .y = 0 };
    if (!AXValueGetValue(val, kAXValueTypeCGPoint, &p)) return null;
    return p;
}

fn sizeAttr(el: Ref, attr: [*:0]const u8) ?CGSizeC {
    const key = cfStr(attr);
    defer if (key != null) CFRelease(key);
    var val: Ref = null;
    if (AXUIElementCopyAttributeValue(el, key, &val) != kAXErrorSuccess) return null;
    if (val == null) return null;
    defer CFRelease(val);
    var s: CGSizeC = .{ .w = 0, .h = 0 };
    if (!AXValueGetValue(val, kAXValueTypeCGSize, &s)) return null;
    return s;
}

fn boolAttr(el: Ref, attr: [*:0]const u8, default: bool) bool {
    var buf: [32]u8 = undefined;
    if (stringAttr(el, attr, &buf)) |s| {
        if (std.mem.eql(u8, s, "0") or std.ascii.eqlIgnoreCase(s, "false")) return false;
        if (std.mem.eql(u8, s, "1") or std.ascii.eqlIgnoreCase(s, "true")) return true;
    }
    return default;
}

/// Roles that represent something a user can act on. Used to set the
/// `clickable` flag in the unified element list.
fn isInteractive(role: []const u8) bool {
    const roles = [_][]const u8{
        "AXButton",   "AXLink",       "AXCheckBox", "AXRadioButton",
        "AXTextField","AXTextArea",   "AXSlider",   "AXPopUpButton",
        "AXMenuItem", "AXIncrementor","AXSwitch",   "AXSegmentedControl",
    };
    for (roles) |r| {
        if (std.mem.eql(u8, r, role)) return true;
    }
    return false;
}

const Ctx = struct {
    gpa: std.mem.Allocator,
    list: *std.ArrayList(uitree.Element),
    win: sim_window.WindowRect,
    px: sim_window.PixelSize,
    ref: u32 = 0,
};

fn collect(ctx: *Ctx, el: Ref, depth: u32) !void {
    if (depth > 40) return;

    var role_buf: [128]u8 = undefined;
    const role = stringAttr(el, "AXRole", &role_buf) orelse "";

    var text_buf: [512]u8 = undefined;
    var desc_buf: [512]u8 = undefined;
    var id_buf: [256]u8 = undefined;
    const text = stringAttr(el, "AXValue", &text_buf) orelse "";
    // iOS accessibilityLabel surfaces as AXDescription; AXTitle is rarer but
    // does appear, so fall back to it rather than dropping the label.
    var title_buf: [512]u8 = undefined;
    const desc = stringAttr(el, "AXDescription", &desc_buf) orelse
        (stringAttr(el, "AXTitle", &title_buf) orelse "");
    // accessibilityIdentifier — the stable hook tests should prefer.
    const id = stringAttr(el, "AXIdentifier", &id_buf) orelse "";

    var bounds: ?uitree.Bounds = null;
    if (pointAttr(el, "AXPosition")) |p| {
        if (sizeAttr(el, "AXSize")) |s| {
            const tl = sim_window.screenToDevice(ctx.win, ctx.px, p.x, p.y);
            const br = sim_window.screenToDevice(ctx.win, ctx.px, p.x + s.w, p.y + s.h);
            bounds = .{
                .x1 = @intFromFloat(tl[0]),
                .y1 = @intFromFloat(tl[1]),
                .x2 = @intFromFloat(br[0]),
                .y2 = @intFromFloat(br[1]),
            };
        }
    }

    const e: uitree.Element = .{
        .ref = ctx.ref,
        .class = try ctx.gpa.dupe(u8, role),
        .text = try ctx.gpa.dupe(u8, text),
        .id = try ctx.gpa.dupe(u8, id),
        .desc = try ctx.gpa.dupe(u8, desc),
        .bounds = bounds,
        .clickable = isInteractive(role),
        .enabled = boolAttr(el, "AXEnabled", true),
    };

    // Same rule as the Android walker: keep anything with a label, an
    // identifier, or an action; drop pure layout wrappers.
    if (e.text.len != 0 or e.desc.len != 0 or e.id.len != 0 or e.clickable) {
        try ctx.list.append(ctx.gpa, e);
        ctx.ref += 1;
    } else {
        ctx.gpa.free(e.class);
        ctx.gpa.free(e.text);
        ctx.gpa.free(e.id);
        ctx.gpa.free(e.desc);
    }

    const kids_key = cfStr("AXChildren");
    defer if (kids_key != null) CFRelease(kids_key);
    var kids: Ref = null;
    if (AXUIElementCopyAttributeValue(el, kids_key, &kids) != kAXErrorSuccess) return;
    if (kids == null) return;
    defer CFRelease(kids);
    if (CFGetTypeID(kids) != CFArrayGetTypeID()) return;

    const n = CFArrayGetCount(kids);
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        try collect(ctx, CFArrayGetValueAtIndex(kids, i), depth + 1);
    }
}

/// Locate the AXGroup that hosts the simulated screen's content.
///
/// The device window also carries Simulator's own chrome (bezel buttons, the
/// toolbar, device-name labels). The iOS app lives in the one AXGroup child
/// that actually has children — which is precisely why an un-bridged
/// simulator looks empty rather than absent.
fn deviceScreenGroup(window: Ref) ?Ref {
    const kids_key = cfStr("AXChildren");
    defer if (kids_key != null) CFRelease(kids_key);
    var kids: Ref = null;
    if (AXUIElementCopyAttributeValue(window, kids_key, &kids) != kAXErrorSuccess) return null;
    if (kids == null) return null;
    defer CFRelease(kids);
    if (CFGetTypeID(kids) != CFArrayGetTypeID()) return null;

    const n = CFArrayGetCount(kids);
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        const child = CFArrayGetValueAtIndex(kids, i);
        var rb: [128]u8 = undefined;
        const role = stringAttr(child, "AXRole", &rb) orelse continue;
        if (!std.mem.eql(u8, role, "AXGroup")) continue;

        var gk: Ref = null;
        const kk = cfStr("AXChildren");
        defer if (kk != null) CFRelease(kk);
        if (AXUIElementCopyAttributeValue(child, kk, &gk) != kAXErrorSuccess) continue;
        if (gk == null) continue;
        defer CFRelease(gk);
        if (CFGetTypeID(gk) != CFArrayGetTypeID()) continue;
        if (CFArrayGetCount(gk) > 0) return retained(child);
    }
    return null;
}

fn firstWindow(app: Ref) ?Ref {
    const kids_key = cfStr("AXChildren");
    defer if (kids_key != null) CFRelease(kids_key);
    var kids: Ref = null;
    if (AXUIElementCopyAttributeValue(app, kids_key, &kids) != kAXErrorSuccess) return null;
    if (kids == null) return null;
    defer CFRelease(kids);
    if (CFGetTypeID(kids) != CFArrayGetTypeID()) return null;

    const n = CFArrayGetCount(kids);
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        const child = CFArrayGetValueAtIndex(kids, i);
        var rb: [128]u8 = undefined;
        const role = stringAttr(child, "AXRole", &rb) orelse continue;
        if (std.mem.eql(u8, role, "AXWindow")) return retained(child);
    }
    return null;
}

/// Declared explicitly rather than inferred: on non-macOS the comptime guard
/// below eliminates the body, which would narrow an inferred set to just
/// `MacOsOnly` and break callers that handle the richer macOS failures.
pub const DumpError = std.mem.Allocator.Error || error{
    MacOsOnly,
    AccessibilityNotTrusted,
    AccessibilityTreeEmpty,
    SimulatorNotRunning,
    SimulatorHasNoWindow,
    PipeCreateFailed,
    ForkFailed,
    XcodeNotFound,
    CommandFailed,
    InvalidCharacter,
    BadRect,
    NoSpaceLeft,
    NameTooLong,
    OpenFailed,
    ShortRead,
    NotPng,
    NoIhdr,
};

/// Dump the running iOS app's accessibility tree as unified elements.
/// Bounds are device pixels, matching `ios screenshot` and `ios tap`.
pub fn dumpElements(
    gpa: std.mem.Allocator,
    udid: []const u8,
) DumpError![]uitree.Element {
    if (builtin.os.tag != .macos) return error.MacOsOnly;
    if (!AXIsProcessTrusted()) return error.AccessibilityNotTrusted;

    try enableAppAccessibility(gpa, udid);

    const pid = (try simulatorPid(gpa)) orelse return error.SimulatorNotRunning;
    const app = AXUIElementCreateApplication(pid);
    if (app == null) return error.AccessibilityNotTrusted;
    defer CFRelease(app);

    // Distinct from "not running": booting a device with `simctl boot` does
    // not make Simulator.app open a window for it, so the app can be alive
    // with nothing on screen. Reporting that as "Simulator.app is not
    // running" sends the user to restart an app that is already up.
    const window = firstWindow(app) orelse return error.SimulatorHasNoWindow;
    defer CFRelease(window);
    const group = deviceScreenGroup(window) orelse return error.AccessibilityTreeEmpty;
    defer CFRelease(group);

    const win = try sim_window.frontWindowRect(gpa);
    const px = try sim_window.devicePixelSize(gpa, udid);

    var list: std.ArrayList(uitree.Element) = .empty;
    errdefer {
        for (list.items) |e| {
            gpa.free(e.class);
            gpa.free(e.text);
            gpa.free(e.id);
            gpa.free(e.desc);
        }
        list.deinit(gpa);
    }

    var ctx: Ctx = .{ .gpa = gpa, .list = &list, .win = win, .px = px };
    try collect(&ctx, group, 0);
    return try list.toOwnedSlice(gpa);
}

test "isInteractive covers the common iOS control roles" {
    try std.testing.expect(isInteractive("AXButton"));
    try std.testing.expect(isInteractive("AXTextField"));
    try std.testing.expect(!isInteractive("AXGroup"));
    try std.testing.expect(!isInteractive("AXStaticText"));
}
