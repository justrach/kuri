//! Unified flat element list, normalized from platform-native UI dumps.
//!
//! Matches the shape of `mobile-device-mcp`'s `uitree` tool output:
//! one entry per visible/interactive element, each with bounds + text +
//! identifying attributes. We intentionally skip attribute-less wrapper
//! nodes that exist only for layout (no text, no resource-id, no
//! content-desc, not clickable).

const std = @import("std");

pub const Bounds = struct { x1: i32, y1: i32, x2: i32, y2: i32 };

pub const Element = struct {
    /// Hierarchical index assigned during traversal. Stable across a single
    /// dump. Used as a `@ref` for tap-by-ref convenience.
    ref: u32,
    /// Class name (Android: e.g. "android.widget.Button"; iOS: e.g.
    /// "XCUIElementTypeButton").
    class: []const u8 = "",
    /// Visible text or label.
    text: []const u8 = "",
    /// Resource ID (Android) or accessibility identifier (iOS).
    id: []const u8 = "",
    /// Content description / accessibility label.
    desc: []const u8 = "",
    bounds: ?Bounds = null,
    clickable: bool = false,
    enabled: bool = true,
};

/// Parse Android `uiautomator dump` XML into a flat list of meaningful
/// elements. Caller frees the returned slice with `freeElements`.
///
/// This is a deliberately small, dependency-free XML walker — it does not
/// validate the document, it only extracts attributes from `<node ...>`
/// tags. uiautomator's output is shallow and well-formed enough to make
/// this safe in practice.
pub fn parseAndroidXml(gpa: std.mem.Allocator, xml: []const u8) ![]Element {
    var list: std.ArrayList(Element) = .empty;
    errdefer freeElementsArrayList(gpa, &list);

    var ref: u32 = 0;
    var i: usize = 0;
    while (i < xml.len) {
        const lt = std.mem.indexOfScalarPos(u8, xml, i, '<') orelse break;
        if (lt + 5 < xml.len and std.mem.eql(u8, xml[lt + 1 .. lt + 5], "node")) {
            const gt = std.mem.indexOfScalarPos(u8, xml, lt, '>') orelse break;
            const tag = xml[lt + 1 .. gt];
            // skip "node" itself
            const attrs = tag[4..];
            const elem = try buildAndroidElement(gpa, ref, attrs);
            if (isMeaningful(elem)) {
                try list.append(gpa, elem);
                ref += 1;
            } else {
                gpa.free(elem.class);
                gpa.free(elem.text);
                gpa.free(elem.id);
                gpa.free(elem.desc);
            }
            i = gt + 1;
        } else {
            i = lt + 1;
        }
    }
    return try list.toOwnedSlice(gpa);
}

fn isMeaningful(e: Element) bool {
    if (e.clickable) return true;
    if (e.text.len != 0) return true;
    if (e.desc.len != 0) return true;
    if (e.id.len != 0) return true;
    return false;
}

fn buildAndroidElement(gpa: std.mem.Allocator, ref: u32, attrs: []const u8) !Element {
    var e: Element = .{ .ref = ref };
    e.class = try dupeAttr(gpa, attrs, "class");
    e.text = try dupeAttr(gpa, attrs, "text");
    e.id = try dupeAttr(gpa, attrs, "resource-id");
    e.desc = try dupeAttr(gpa, attrs, "content-desc");
    if (findAttr(attrs, "clickable")) |v| e.clickable = std.mem.eql(u8, v, "true");
    if (findAttr(attrs, "enabled")) |v| e.enabled = std.mem.eql(u8, v, "true");
    if (findAttr(attrs, "bounds")) |v| e.bounds = parseBounds(v);
    return e;
}

fn dupeAttr(gpa: std.mem.Allocator, attrs: []const u8, name: []const u8) ![]const u8 {
    if (findAttr(attrs, name)) |v| return try gpa.dupe(u8, v);
    return try gpa.dupe(u8, "");
}

fn findAttr(attrs: []const u8, name: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, " {s}=\"", .{name}) catch return null;
    const start = std.mem.indexOf(u8, attrs, needle) orelse return null;
    const value_start = start + needle.len;
    const end = std.mem.indexOfScalarPos(u8, attrs, value_start, '"') orelse return null;
    return attrs[value_start..end];
}

/// Parse "[x1,y1][x2,y2]" → Bounds.
fn parseBounds(s: []const u8) ?Bounds {
    if (s.len < 9) return null;
    const lb1 = std.mem.indexOfScalar(u8, s, '[') orelse return null;
    const rb1 = std.mem.indexOfScalarPos(u8, s, lb1, ']') orelse return null;
    const lb2 = std.mem.indexOfScalarPos(u8, s, rb1, '[') orelse return null;
    const rb2 = std.mem.indexOfScalarPos(u8, s, lb2, ']') orelse return null;
    const a = s[lb1 + 1 .. rb1];
    const b = s[lb2 + 1 .. rb2];
    const comma_a = std.mem.indexOfScalar(u8, a, ',') orelse return null;
    const comma_b = std.mem.indexOfScalar(u8, b, ',') orelse return null;
    const x1 = std.fmt.parseInt(i32, a[0..comma_a], 10) catch return null;
    const y1 = std.fmt.parseInt(i32, a[comma_a + 1 ..], 10) catch return null;
    const x2 = std.fmt.parseInt(i32, b[0..comma_b], 10) catch return null;
    const y2 = std.fmt.parseInt(i32, b[comma_b + 1 ..], 10) catch return null;
    return .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2 };
}

pub fn freeElements(gpa: std.mem.Allocator, els: []Element) void {
    for (els) |e| {
        gpa.free(e.class);
        gpa.free(e.text);
        gpa.free(e.id);
        gpa.free(e.desc);
    }
    gpa.free(els);
}

fn freeElementsArrayList(gpa: std.mem.Allocator, list: *std.ArrayList(Element)) void {
    for (list.items) |e| {
        gpa.free(e.class);
        gpa.free(e.text);
        gpa.free(e.id);
        gpa.free(e.desc);
    }
    list.deinit(gpa);
}

/// Compute the centroid of the element bounds for tap-by-ref.
pub fn centroid(e: Element) ?[2]i32 {
    const b = e.bounds orelse return null;
    return .{ @divTrunc(b.x1 + b.x2, 2), @divTrunc(b.y1 + b.y2, 2) };
}

/// Render a flat element list to a stable, human-readable text format
/// (matches the spirit of upstream's `uitree` text output).
pub fn renderText(gpa: std.mem.Allocator, els: []const Element) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (els) |e| {
        try appendFmt(&buf, gpa, "@e{d} ", .{e.ref});
        if (e.class.len != 0) try appendFmt(&buf, gpa, "{s} ", .{shortClass(e.class)});
        if (e.id.len != 0) try appendFmt(&buf, gpa, "#{s} ", .{e.id});
        if (e.text.len != 0) try appendFmt(&buf, gpa, "\"{s}\" ", .{e.text});
        if (e.desc.len != 0) try appendFmt(&buf, gpa, "[{s}] ", .{e.desc});
        if (e.bounds) |b| try appendFmt(&buf, gpa, "@{d},{d}-{d},{d}", .{ b.x1, b.y1, b.x2, b.y2 });
        if (e.clickable) try buf.appendSlice(gpa, " *clickable");
        if (!e.enabled) try buf.appendSlice(gpa, " *disabled");
        try buf.append(gpa, '\n');
    }
    return try buf.toOwnedSlice(gpa);
}

fn appendFmt(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try buf.appendSlice(gpa, s);
}

fn shortClass(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '.')) |dot| return s[dot + 1 ..];
    return s;
}

// ---------------------------------------------------------------- tests

test "parseBounds standard format" {
    const b = parseBounds("[0,0][1080,2400]").?;
    try std.testing.expectEqual(@as(i32, 0), b.x1);
    try std.testing.expectEqual(@as(i32, 1080), b.x2);
    try std.testing.expectEqual(@as(i32, 2400), b.y2);
}

test "parseAndroidXml extracts meaningful nodes" {
    const xml =
        \\<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
        \\<hierarchy rotation="0">
        \\<node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.x" content-desc="" checkable="false" checked="false" clickable="false" enabled="true" focusable="false" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[0,0][1080,2400]">
        \\  <node index="1" text="Sign in" resource-id="com.x:id/btn_sign_in" class="android.widget.Button" package="com.x" content-desc="Sign in button" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[100,200][980,300]"/>
        \\</node>
        \\</hierarchy>
    ;
    const els = try parseAndroidXml(std.testing.allocator, xml);
    defer freeElements(std.testing.allocator, els);
    try std.testing.expectEqual(@as(usize, 1), els.len);
    try std.testing.expectEqualStrings("Sign in", els[0].text);
    try std.testing.expectEqualStrings("com.x:id/btn_sign_in", els[0].id);
    try std.testing.expect(els[0].clickable);
    const c = centroid(els[0]).?;
    try std.testing.expectEqual(@as(i32, 540), c[0]);
    try std.testing.expectEqual(@as(i32, 250), c[1]);
}
