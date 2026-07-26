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
    // uiautomator reports these on every node and they carry information no
    // other field does: whether a switch is on, whether a field masks its
    // input, whether a container can be scrolled. Without them an agent has to
    // infer state from a label, and an unlabelled control is invisible.
    long_clickable: bool = false,
    checkable: bool = false,
    checked: bool = false,
    scrollable: bool = false,
    focusable: bool = false,
    focused: bool = false,
    selected: bool = false,
    password: bool = false,
    /// True when this node can be acted on — see `isInteractive`. Plain
    /// `clickable` misses a scrollable list, a checkable switch, or a bare
    /// `EditText`, all of which an agent must be able to reach.
    interactive: bool = false,
};

/// Widget classes that are interactive regardless of the boolean attributes,
/// because some apps ship them without setting `clickable`. Same list as
/// CursorTouch/Android-MCP's `INTERACTIVE_CLASSES`, kept deliberately narrow —
/// anything broader starts sweeping in layout containers.
const interactive_classes = [_][]const u8{
    "android.widget.Button",
    "android.widget.ImageButton",
    "android.widget.EditText",
    "android.widget.CheckBox",
    "android.widget.Switch",
    "android.widget.RadioButton",
    "android.widget.Spinner",
    "android.widget.SeekBar",
};

fn isInteractiveClass(class: []const u8) bool {
    for (interactive_classes) |c| {
        if (std.mem.eql(u8, class, c)) return true;
    }
    return false;
}

/// A disabled control is not actionable, so it is not interactive however many
/// of the other flags it sets.
pub fn isInteractive(e: Element) bool {
    if (!e.enabled) return false;
    return e.clickable or e.long_clickable or e.checkable or e.scrollable or
        e.focusable or e.selected or e.password or isInteractiveClass(e.class);
}

/// `com.example.app:id/btn_login` → `btn_login`. The package prefix is the
/// same for every element of an app, so it is pure noise in a listing; the
/// full id is still what `find` matches against.
pub fn shortId(id: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, id, '/')) |slash| return id[slash + 1 ..];
    return id;
}

/// Parse Android `uiautomator dump` XML into a flat list of meaningful
/// elements. Caller frees the returned slice with `freeElements`.
///
/// This is a deliberately small, dependency-free XML walker — it does not
/// validate the document, it only extracts attributes from `<node ...>`
/// tags. uiautomator's output is shallow and well-formed enough to make
/// this safe in practice.
/// One `<node>` from the dump, kept as a slice into the source XML so the
/// hierarchy pass costs no allocation. `subtree_end` is exclusive: the
/// descendants of node `i` are exactly `nodes[i + 1 .. nodes[i].subtree_end]`,
/// which turns "walk this node's children" into a bounded linear scan.
const RawNode = struct {
    attrs: []const u8,
    subtree_end: u32,
};

/// `<node` / `</node` and not `<nodefoo`. The boundary check matters because
/// the tag name is compared by prefix.
fn isNodeTag(xml: []const u8, lt: usize, comptime closing: bool) bool {
    const off = lt + if (closing) @as(usize, 2) else @as(usize, 1);
    if (off + 4 > xml.len) return false;
    if (!std.mem.eql(u8, xml[off .. off + 4], "node")) return false;
    if (off + 4 == xml.len) return true;
    return switch (xml[off + 4]) {
        ' ', '\t', '\n', '\r', '/', '>' => true,
        else => false,
    };
}

pub fn parseAndroidXml(gpa: std.mem.Allocator, xml: []const u8) ![]Element {
    // Pass 1: record every node and where its subtree ends. The previous
    // version treated the dump as a flat tag stream, which is why a node's
    // children were unreachable and a label-bearing child could not be used to
    // name its clickable parent.
    var raw: std.ArrayList(RawNode) = .empty;
    defer raw.deinit(gpa);
    var open: std.ArrayList(u32) = .empty;
    defer open.deinit(gpa);

    var i: usize = 0;
    while (i < xml.len) {
        const lt = std.mem.indexOfScalarPos(u8, xml, i, '<') orelse break;
        const gt = std.mem.indexOfScalarPos(u8, xml, lt, '>') orelse break;

        if (lt + 1 < xml.len and xml[lt + 1] == '/') {
            if (isNodeTag(xml, lt, true) and open.items.len != 0) {
                const top = open.items[open.items.len - 1];
                open.items.len -= 1;
                raw.items[top].subtree_end = @intCast(raw.items.len);
            }
            i = gt + 1;
            continue;
        }

        if (isNodeTag(xml, lt, false)) {
            const tag = xml[lt + 1 .. gt];
            const self_closing = tag.len != 0 and tag[tag.len - 1] == '/';
            const attrs = tag[4 .. tag.len - @as(usize, if (self_closing) 1 else 0)];
            const idx: u32 = @intCast(raw.items.len);
            try raw.append(gpa, .{ .attrs = attrs, .subtree_end = idx + 1 });
            if (!self_closing) try open.append(gpa, idx);
            i = gt + 1;
            continue;
        }

        i = lt + 1;
    }
    // A truncated dump leaves nodes open. Let them own the remainder rather
    // than silently orphaning every descendant that did arrive.
    while (open.items.len != 0) {
        const top = open.items[open.items.len - 1];
        open.items.len -= 1;
        raw.items[top].subtree_end = @intCast(raw.items.len);
    }

    // Pass 2: materialise the elements worth reporting.
    var list: std.ArrayList(Element) = .empty;
    errdefer freeElementsArrayList(gpa, &list);

    var ref: u32 = 0;
    for (raw.items, 0..) |n, ni| {
        var elem = try buildAndroidElement(gpa, ref, n.attrs);
        elem.interactive = isInteractive(elem);
        // A clickable row whose label lives in a child TextView is the most
        // common Android list layout there is. Without this it lists as
        // nameless, so an agent cannot address it by label at all.
        if (elem.interactive and elem.text.len == 0 and elem.desc.len == 0) {
            if (try synthesizeName(gpa, raw.items, @intCast(ni))) |name| {
                gpa.free(elem.text);
                elem.text = name;
            }
        }
        if (isMeaningful(elem)) {
            try list.append(gpa, elem);
            ref += 1;
        } else {
            gpa.free(elem.class);
            gpa.free(elem.text);
            gpa.free(elem.id);
            gpa.free(elem.desc);
        }
    }
    return try list.toOwnedSlice(gpa);
}

fn isMeaningful(e: Element) bool {
    // `interactive` first: a scrollable container or an unlabelled switch has
    // no text, id or content-desc, and used to be dropped entirely.
    if (e.interactive) return true;
    if (e.clickable) return true;
    if (e.text.len != 0) return true;
    if (e.desc.len != 0) return true;
    if (e.id.len != 0) return true;
    return false;
}

/// Name an interactive node that carries none of its own, from the text of its
/// descendants. Recursion stops at descendants that are themselves actionable,
/// because their text belongs to them and is listed against them; those supply
/// only a fallback for when nothing else turns up.
fn synthesizeName(gpa: std.mem.Allocator, nodes: []const RawNode, root: u32) !?[]const u8 {
    var primary: std.ArrayList(u8) = .empty;
    defer primary.deinit(gpa);
    var fallback: std.ArrayList(u8) = .empty;
    defer fallback.deinit(gpa);

    const end = nodes[root].subtree_end;
    var j: u32 = root + 1;
    while (j < end) {
        const attrs = nodes[j].attrs;
        const val = nonEmptyAttr(attrs, "text") orelse
            nonEmptyAttr(attrs, "content-desc") orelse
            nonEmptyAttr(attrs, "hint");
        if (isActionable(attrs)) {
            if (val) |v| try appendWord(gpa, &fallback, v);
            j = nodes[j].subtree_end;
            continue;
        }
        if (val) |v| try appendWord(gpa, &primary, v);
        j += 1;
    }

    const chosen = if (primary.items.len != 0) &primary else &fallback;
    if (chosen.items.len == 0) return null;
    return try gpa.dupe(u8, chosen.items);
}

fn isActionable(attrs: []const u8) bool {
    return boolAttr(attrs, "clickable", false) or
        boolAttr(attrs, "long-clickable", false) or
        boolAttr(attrs, "checkable", false) or
        boolAttr(attrs, "scrollable", false);
}

fn nonEmptyAttr(attrs: []const u8, name: []const u8) ?[]const u8 {
    const v = findAttr(attrs, name) orelse return null;
    return if (v.len == 0) null else v;
}

fn appendWord(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), word: []const u8) !void {
    if (buf.items.len != 0) try buf.append(gpa, ' ');
    try appendDecoded(gpa, buf, word);
}

fn buildAndroidElement(gpa: std.mem.Allocator, ref: u32, attrs: []const u8) !Element {
    var e: Element = .{ .ref = ref };
    e.class = try dupeAttr(gpa, attrs, "class");
    e.text = try dupeAttr(gpa, attrs, "text");
    e.id = try dupeAttr(gpa, attrs, "resource-id");
    e.desc = try dupeAttr(gpa, attrs, "content-desc");
    if (findAttr(attrs, "bounds")) |v| e.bounds = parseBounds(v);
    e.clickable = boolAttr(attrs, "clickable", false);
    e.enabled = boolAttr(attrs, "enabled", true);
    e.long_clickable = boolAttr(attrs, "long-clickable", false);
    e.checkable = boolAttr(attrs, "checkable", false);
    e.checked = boolAttr(attrs, "checked", false);
    e.scrollable = boolAttr(attrs, "scrollable", false);
    e.focusable = boolAttr(attrs, "focusable", false);
    e.focused = boolAttr(attrs, "focused", false);
    e.selected = boolAttr(attrs, "selected", false);
    e.password = boolAttr(attrs, "password", false);
    return e;
}

/// `findAttr`'s needle carries a leading space, which is what keeps
/// `clickable` from matching inside `long-clickable`.
fn boolAttr(attrs: []const u8, name: []const u8, default: bool) bool {
    const v = findAttr(attrs, name) orelse return default;
    return std.mem.eql(u8, v, "true");
}

fn dupeAttr(gpa: std.mem.Allocator, attrs: []const u8, name: []const u8) ![]const u8 {
    if (findAttr(attrs, name)) |v| return try decodeEntities(gpa, v);
    return try gpa.dupe(u8, "");
}

/// uiautomator XML-escapes attribute values, so a row labelled
/// "Network & internet" arrives as `Network &amp; internet`. Leaving it encoded
/// means the text reported differs from the text on screen, and a `--label`
/// match on what the user can actually read fails.
///
/// Unrecognised entities are passed through as a literal `&` rather than
/// dropped: a bare ampersand in a label is not our text to lose.
fn decodeEntities(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return try gpa.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendDecoded(gpa, &out, s);
    return try out.toOwnedSlice(gpa);
}

/// Decode into an existing buffer. Names synthesized from descendant text go
/// through here too — they are raw attribute slices, and decoding only the
/// node's own attributes left every synthesized label still XML-escaped.
fn appendDecoded(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '&') {
            try out.append(gpa, s[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, s, i, ';') orelse {
            try out.append(gpa, '&');
            i += 1;
            continue;
        };
        const name = s[i + 1 .. semi];
        const named: ?[]const u8 = if (std.mem.eql(u8, name, "amp"))
            "&"
        else if (std.mem.eql(u8, name, "lt"))
            "<"
        else if (std.mem.eql(u8, name, "gt"))
            ">"
        else if (std.mem.eql(u8, name, "quot"))
            "\""
        else if (std.mem.eql(u8, name, "apos"))
            "'"
        else
            null;
        if (named) |rep| {
            try out.appendSlice(gpa, rep);
            i = semi + 1;
            continue;
        }
        if (name.len > 1 and name[0] == '#') {
            if (parseCharRef(name[1..])) |cp| {
                var buf: [4]u8 = undefined;
                if (std.unicode.utf8Encode(cp, &buf)) |n| {
                    try out.appendSlice(gpa, buf[0..n]);
                    i = semi + 1;
                    continue;
                } else |_| {}
            }
        }
        try out.append(gpa, '&');
        i += 1;
    }
}

fn parseCharRef(body: []const u8) ?u21 {
    if (body.len == 0) return null;
    const v = if (body[0] == 'x' or body[0] == 'X')
        std.fmt.parseInt(u21, body[1..], 16) catch return null
    else
        std.fmt.parseInt(u21, body, 10) catch return null;
    if (v > 0x10FFFF) return null;
    return v;
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
        if (e.long_clickable) try buf.appendSlice(gpa, " *long-clickable");
        if (e.scrollable) try buf.appendSlice(gpa, " *scrollable");
        // Report the position, not just the capability: "there is a switch
        // here" and "the switch is on" are different answers.
        if (e.checkable) try buf.appendSlice(gpa, if (e.checked) " *checked" else " *unchecked");
        if (e.password) try buf.appendSlice(gpa, " *password");
        if (e.focused) try buf.appendSlice(gpa, " *focused");
        if (e.selected) try buf.appendSlice(gpa, " *selected");
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

/// Look up a parsed element by resource-id, so the tests below do not depend
/// on how many sibling nodes happen to survive the filter.
fn findById(els: []const Element, id: []const u8) ?Element {
    for (els) |e| {
        if (std.mem.eql(u8, e.id, id)) return e;
    }
    return null;
}

test "a clickable row takes its name from descendant text" {
    const xml =
        \\<hierarchy rotation="0">
        \\<node class="android.widget.LinearLayout" resource-id="com.x:id/row" text="" content-desc="" clickable="true" enabled="true" bounds="[0,0][1080,200]">
        \\  <node class="android.widget.TextView" resource-id="" text="Wi-Fi" content-desc="" clickable="false" enabled="true" bounds="[20,20][400,80]"/>
        \\  <node class="android.widget.TextView" resource-id="" text="Connected" content-desc="" clickable="false" enabled="true" bounds="[20,90][400,150]"/>
        \\</node>
        \\</hierarchy>
    ;
    const els = try parseAndroidXml(std.testing.allocator, xml);
    defer freeElements(std.testing.allocator, els);
    const row = findById(els, "com.x:id/row").?;
    try std.testing.expectEqualStrings("Wi-Fi Connected", row.text);
    try std.testing.expect(row.interactive);
}

test "descendant naming stops at actionable children but falls back to them" {
    const xml =
        \\<hierarchy rotation="0">
        \\<node class="android.widget.LinearLayout" resource-id="com.x:id/labelled" text="" content-desc="" clickable="true" enabled="true" bounds="[0,0][1080,200]">
        \\  <node class="android.widget.TextView" resource-id="" text="Aeroplane mode" content-desc="" clickable="false" enabled="true" bounds="[20,20][400,80]"/>
        \\  <node class="android.widget.Switch" resource-id="" text="On" content-desc="" clickable="true" checkable="true" checked="true" enabled="true" bounds="[900,20][1060,80]"/>
        \\</node>
        \\<node class="android.widget.FrameLayout" resource-id="com.x:id/only_actionable" text="" content-desc="" clickable="true" enabled="true" bounds="[0,200][1080,400]">
        \\  <node class="android.widget.Button" resource-id="" text="Go" content-desc="" clickable="true" enabled="true" bounds="[20,220][400,280]"/>
        \\</node>
        \\</hierarchy>
    ;
    const els = try parseAndroidXml(std.testing.allocator, xml);
    defer freeElements(std.testing.allocator, els);
    // The Switch owns "On" and is listed in its own right, so it must not be
    // folded into the row's name.
    try std.testing.expectEqualStrings("Aeroplane mode", findById(els, "com.x:id/labelled").?.text);
    // With nothing but actionable children, their text is better than nothing.
    try std.testing.expectEqualStrings("Go", findById(els, "com.x:id/only_actionable").?.text);
}

test "an unlabelled scrollable container survives the filter" {
    const xml =
        \\<hierarchy rotation="0">
        \\<node class="androidx.recyclerview.widget.RecyclerView" resource-id="" text="" content-desc="" clickable="false" scrollable="true" enabled="true" bounds="[0,0][1080,2000]"/>
        \\</hierarchy>
    ;
    const els = try parseAndroidXml(std.testing.allocator, xml);
    defer freeElements(std.testing.allocator, els);
    // No text, no id, no content-desc, not clickable — the old filter dropped
    // this outright, leaving no way to discover the list could be scrolled.
    try std.testing.expectEqual(@as(usize, 1), els.len);
    try std.testing.expect(els[0].scrollable);
    try std.testing.expect(els[0].interactive);
}

test "interactivity honours class allowlist, checked state and disabled" {
    const xml =
        \\<hierarchy rotation="0">
        \\<node class="android.widget.EditText" resource-id="com.x:id/email" text="" content-desc="" clickable="false" enabled="true" password="false" bounds="[0,0][500,60]"/>
        \\<node class="android.widget.Switch" resource-id="com.x:id/sw" text="" content-desc="" checkable="true" checked="true" enabled="true" bounds="[0,60][500,120]"/>
        \\<node class="android.widget.Button" resource-id="com.x:id/dead" text="Submit" content-desc="" clickable="true" enabled="false" bounds="[0,120][500,180]"/>
        \\</hierarchy>
    ;
    const els = try parseAndroidXml(std.testing.allocator, xml);
    defer freeElements(std.testing.allocator, els);
    // An EditText with no attributes set at all is still a text field.
    try std.testing.expect(findById(els, "com.x:id/email").?.interactive);
    const sw = findById(els, "com.x:id/sw").?;
    try std.testing.expect(sw.checkable and sw.checked);
    // Still listed (it has text and an id) but not offered as actionable.
    try std.testing.expect(!findById(els, "com.x:id/dead").?.interactive);
}

test "clickable does not match inside long-clickable" {
    const xml =
        \\<hierarchy rotation="0">
        \\<node class="android.view.View" resource-id="com.x:id/lc" text="Hold me" content-desc="" clickable="false" long-clickable="true" enabled="true" bounds="[0,0][100,100]"/>
        \\</hierarchy>
    ;
    const els = try parseAndroidXml(std.testing.allocator, xml);
    defer freeElements(std.testing.allocator, els);
    const e = findById(els, "com.x:id/lc").?;
    try std.testing.expect(e.long_clickable);
    try std.testing.expect(!e.clickable);
}

test "attribute values are XML-decoded so labels match what is on screen" {
    const xml =
        \\<hierarchy rotation="0">
        \\<node class="android.widget.LinearLayout" resource-id="com.x:id/net" text="Network &amp; internet" content-desc="Wi&#8209;Fi &quot;home&quot;" clickable="true" enabled="true" bounds="[0,0][100,100]"/>
        \\</hierarchy>
    ;
    const els = try parseAndroidXml(std.testing.allocator, xml);
    defer freeElements(std.testing.allocator, els);
    const e = findById(els, "com.x:id/net").?;
    try std.testing.expectEqualStrings("Network & internet", e.text);
    // Numeric references too — Android really does ship a non-breaking hyphen
    // in "Wi‑Fi", and a caller searching for the literal string must find it.
    try std.testing.expectEqualStrings("Wi\u{2011}Fi \"home\"", e.desc);
}

test "synthesized names are decoded too, not just a node's own attributes" {
    // Decoding `dupeAttr` alone was not enough: this row's label is assembled
    // from child text read straight out of the XML, and on a real Settings
    // screen it came back as "Network &amp; internet &gt; Internet".
    const xml =
        \\<hierarchy rotation="0">
        \\<node class="android.widget.LinearLayout" resource-id="com.x:id/row" text="" content-desc="" clickable="true" enabled="true" bounds="[0,0][1080,200]">
        \\  <node class="android.widget.TextView" resource-id="" text="Network &amp; internet" content-desc="" clickable="false" enabled="true" bounds="[0,0][500,60]"/>
        \\  <node class="android.widget.TextView" resource-id="" text="&gt; Internet" content-desc="" clickable="false" enabled="true" bounds="[0,60][500,120]"/>
        \\</node>
        \\</hierarchy>
    ;
    const els = try parseAndroidXml(std.testing.allocator, xml);
    defer freeElements(std.testing.allocator, els);
    try std.testing.expectEqualStrings("Network & internet > Internet", findById(els, "com.x:id/row").?.text);
}

test "a bare ampersand is preserved rather than eaten" {
    const xml =
        \\<hierarchy rotation="0">
        \\<node class="android.widget.TextView" resource-id="com.x:id/bare" text="Tom &amp; Jerry; also R&amp;D" content-desc="" clickable="true" enabled="true" bounds="[0,0][10,10]"/>
        \\</hierarchy>
    ;
    const els = try parseAndroidXml(std.testing.allocator, xml);
    defer freeElements(std.testing.allocator, els);
    try std.testing.expectEqualStrings("Tom & Jerry; also R&D", findById(els, "com.x:id/bare").?.text);
}

test "shortId strips the package prefix and tolerates its absence" {
    try std.testing.expectEqualStrings("btn_login", shortId("com.example.app:id/btn_login"));
    try std.testing.expectEqualStrings("btn_login", shortId("btn_login"));
    try std.testing.expectEqualStrings("", shortId(""));
}
