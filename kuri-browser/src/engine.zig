// engine.zig — small CSS-aware layout + paint engine for kuri-browser.
//
// Pipeline:
//   1. Compute styles for every element via css.zig.
//   2. Build a LayoutBox tree (block + inline + text runs).
//   3. Optionally paint to SVG.
//
// This is intentionally small: block flow, inline text wrapping at word
// boundaries, and a few basic CSS properties. It is a real layout engine,
// not just an SVG dump — every box has an x/y/width/height that other code
// (e.g. DOM.getBoxModel) can read.

const std = @import("std");
const css = @import("css.zig");
const dom = @import("dom.zig");
const model = @import("model.zig");

pub const Viewport = struct {
    width: f64 = 1280,
    height: f64 = 720,
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: f32 = 1.0,

    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255 };
    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
};

pub const BoxEdge = struct {
    top: f64 = 0,
    right: f64 = 0,
    bottom: f64 = 0,
    left: f64 = 0,
};

pub const Display = enum {
    block,
    inline_,
    inline_block,
    list_item,
    table,
    none,
};

pub const TextAlign = enum {
    start,
    center,
    end,
    justify,
};

pub const ComputedStyle = struct {
    display: Display = .inline_,
    background_color: ?Color = null,
    color: Color = Color.black,
    font_family: []const u8 = "sans-serif",
    font_size: f64 = 16,
    font_weight: u16 = 400,
    line_height: f64 = 1.2,
    text_align: TextAlign = .start,
    padding: BoxEdge = .{},
    margin: BoxEdge = .{},
    border_width: BoxEdge = .{},
    border_color: Color = Color.black,
    width: ?f64 = null,
    height: ?f64 = null,
    text_decoration_underline: bool = false,
    italic: bool = false,
};

pub const TextRun = struct {
    text: []const u8,
    x: f64,
    y: f64, // baseline
    font_family: []const u8,
    font_size: f64,
    font_weight: u16,
    color: Color,
    underline: bool,
    italic: bool,
};

pub const LayoutBox = struct {
    node_id: ?dom.NodeId = null,
    style: ComputedStyle = .{},
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,
    children: []*LayoutBox = &.{},
    text_runs: []TextRun = &.{},
};

pub const LayoutResult = struct {
    arena: std.heap.ArenaAllocator,
    root: *LayoutBox,
    viewport: Viewport,

    pub fn deinit(self: *LayoutResult) void {
        self.arena.deinit();
    }
};

pub fn layoutPage(
    parent_allocator: std.mem.Allocator,
    page: *const model.Page,
    viewport: Viewport,
) !LayoutResult {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var ua = try css.loadUserAgentSheet(allocator);
    const author_text = try css.extractAllStyleText(allocator, &page.dom);
    var author = try css.Stylesheet.fromText(allocator, author_text, .author);
    _ = &ua;
    _ = &author;
    const sheets: []const *const css.Stylesheet = &.{ &ua, &author };

    var ctx = LayoutCtx{
        .allocator = allocator,
        .sheets = sheets,
        .doc = &page.dom,
        .viewport = viewport,
    };

    const html_body = findHtmlBody(&page.dom);
    const root_node = html_body orelse page.dom.root_id;
    const root_box = try layoutBlock(&ctx, root_node, 0, 0, viewport.width, .{
        .font_size = 16,
        .color = Color.black,
    });

    return .{
        .arena = arena,
        .root = root_box,
        .viewport = viewport,
    };
}

const LayoutCtx = struct {
    allocator: std.mem.Allocator,
    sheets: []const *const css.Stylesheet,
    doc: *const dom.Document,
    viewport: Viewport,
};

const Inheritable = struct {
    font_size: f64,
    color: Color,
    font_family: []const u8 = "sans-serif",
    font_weight: u16 = 400,
    line_height: f64 = 1.2,
    text_align: TextAlign = .start,
    italic: bool = false,
    underline: bool = false,
};

fn findHtmlBody(doc: *const dom.Document) ?dom.NodeId {
    var i: dom.NodeId = 0;
    while (i < doc.nodes.len) : (i += 1) {
        const node = &doc.nodes[i];
        if (node.kind == .element and std.ascii.eqlIgnoreCase(node.name, "body")) {
            return i;
        }
    }
    return null;
}

fn computeStyle(
    ctx: *LayoutCtx,
    node_id: dom.NodeId,
    parent: Inheritable,
) !ComputedStyle {
    const inline_attr = ctx.doc.getAttribute(node_id, "style") orelse "";
    const computed = try css.computeStyleForNode(ctx.allocator, ctx.sheets, ctx.doc, node_id, inline_attr);

    var style: ComputedStyle = .{
        .color = parent.color,
        .font_family = parent.font_family,
        .font_size = parent.font_size,
        .font_weight = parent.font_weight,
        .line_height = parent.line_height,
        .text_align = parent.text_align,
        .italic = parent.italic,
        .text_decoration_underline = parent.underline,
        .display = defaultDisplayForTag(ctx.doc.getNode(node_id).name),
    };

    if (computed.get("display")) |v| style.display = parseDisplay(v);
    if (computed.get("color")) |v| {
        if (parseColor(v)) |c| style.color = c;
    }
    if (computed.get("background-color") orelse computed.get("background")) |v| {
        style.background_color = parseColor(v);
    }
    if (computed.get("font-family")) |v| {
        style.font_family = trimFontFamily(v);
    }
    if (computed.get("font-size")) |v| {
        if (parseLength(v, parent.font_size, ctx.viewport, parent.font_size)) |px| {
            style.font_size = px;
        }
    }
    if (computed.get("font-weight")) |v| {
        style.font_weight = parseFontWeight(v, parent.font_weight);
    }
    if (computed.get("font-style")) |v| {
        style.italic = std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " "), "italic") or
            std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " "), "oblique");
    }
    if (computed.get("line-height")) |v| {
        if (parseLength(v, parent.font_size, ctx.viewport, parent.font_size)) |px| {
            style.line_height = px / style.font_size;
        } else {
            const trimmed = std.mem.trim(u8, v, " \t");
            style.line_height = std.fmt.parseFloat(f64, trimmed) catch parent.line_height;
        }
    }
    if (computed.get("text-align")) |v| style.text_align = parseTextAlign(v);
    if (computed.get("text-decoration") orelse computed.get("text-decoration-line")) |v| {
        style.text_decoration_underline = std.mem.indexOf(u8, v, "underline") != null;
    }
    if (computed.get("padding")) |v| style.padding = parseEdgeShorthand(v, style.font_size, ctx.viewport);
    if (computed.get("margin")) |v| style.margin = parseEdgeShorthand(v, style.font_size, ctx.viewport);
    if (computed.get("padding-top")) |v| {
        if (parseLength(v, style.font_size, ctx.viewport, style.font_size)) |px| style.padding.top = px;
    }
    if (computed.get("padding-bottom")) |v| {
        if (parseLength(v, style.font_size, ctx.viewport, style.font_size)) |px| style.padding.bottom = px;
    }
    if (computed.get("padding-left")) |v| {
        if (parseLength(v, style.font_size, ctx.viewport, style.font_size)) |px| style.padding.left = px;
    }
    if (computed.get("padding-right")) |v| {
        if (parseLength(v, style.font_size, ctx.viewport, style.font_size)) |px| style.padding.right = px;
    }
    if (computed.get("margin-top")) |v| {
        if (parseLength(v, style.font_size, ctx.viewport, style.font_size)) |px| style.margin.top = px;
    }
    if (computed.get("margin-bottom")) |v| {
        if (parseLength(v, style.font_size, ctx.viewport, style.font_size)) |px| style.margin.bottom = px;
    }
    if (computed.get("margin-left")) |v| {
        const trimmed = std.mem.trim(u8, v, " \t");
        if (std.mem.eql(u8, trimmed, "auto")) {
            style.margin.left = -1; // sentinel: auto
        } else if (parseLength(v, style.font_size, ctx.viewport, style.font_size)) |px| {
            style.margin.left = px;
        }
    }
    if (computed.get("margin-right")) |v| {
        const trimmed = std.mem.trim(u8, v, " \t");
        if (std.mem.eql(u8, trimmed, "auto")) {
            style.margin.right = -1;
        } else if (parseLength(v, style.font_size, ctx.viewport, style.font_size)) |px| {
            style.margin.right = px;
        }
    }
    if (computed.get("width")) |v| {
        style.width = parseLength(v, style.font_size, ctx.viewport, style.font_size);
    }
    if (computed.get("height")) |v| {
        style.height = parseLength(v, style.font_size, ctx.viewport, style.font_size);
    }
    if (computed.get("border-width")) |v| {
        const w = parseLength(v, style.font_size, ctx.viewport, style.font_size) orelse 0;
        style.border_width = .{ .top = w, .right = w, .bottom = w, .left = w };
    }
    if (computed.get("border-color")) |v| {
        if (parseColor(v)) |c| style.border_color = c;
    }
    return style;
}

fn defaultDisplayForTag(tag: []const u8) Display {
    if (tag.len == 0) return .block;
    const block_tags = [_][]const u8{
        "html",   "body",   "div",    "p",     "header", "footer", "section",
        "article","nav",    "main",   "aside", "h1",     "h2",     "h3",
        "h4",     "h5",     "h6",     "ul",    "ol",     "li",     "dl",
        "dt",     "dd",     "blockquote","pre","figure","figcaption","form",
        "fieldset","table", "thead",  "tbody", "tfoot",  "tr",     "td",
        "th",     "address","center", "hr",
    };
    for (block_tags) |bt| if (std.ascii.eqlIgnoreCase(tag, bt)) return .block;
    if (std.ascii.eqlIgnoreCase(tag, "head") or std.ascii.eqlIgnoreCase(tag, "script") or
        std.ascii.eqlIgnoreCase(tag, "style") or std.ascii.eqlIgnoreCase(tag, "meta") or
        std.ascii.eqlIgnoreCase(tag, "link") or std.ascii.eqlIgnoreCase(tag, "title"))
    {
        return .none;
    }
    return .inline_;
}

fn parseDisplay(v: []const u8) Display {
    const t = std.mem.trim(u8, v, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(t, "block")) return .block;
    if (std.ascii.eqlIgnoreCase(t, "inline")) return .inline_;
    if (std.ascii.eqlIgnoreCase(t, "inline-block")) return .inline_block;
    if (std.ascii.eqlIgnoreCase(t, "list-item")) return .list_item;
    if (std.ascii.eqlIgnoreCase(t, "table")) return .table;
    if (std.ascii.eqlIgnoreCase(t, "none")) return .none;
    return .inline_;
}

fn parseTextAlign(v: []const u8) TextAlign {
    const t = std.mem.trim(u8, v, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(t, "center")) return .center;
    if (std.ascii.eqlIgnoreCase(t, "right") or std.ascii.eqlIgnoreCase(t, "end")) return .end;
    if (std.ascii.eqlIgnoreCase(t, "justify")) return .justify;
    return .start;
}

fn trimFontFamily(value: []const u8) []const u8 {
    var v = std.mem.trim(u8, value, " \t\r\n");
    if (std.mem.indexOfScalar(u8, v, ',')) |idx| {
        v = std.mem.trim(u8, v[0..idx], " \t\r\n\"'");
    } else {
        v = std.mem.trim(u8, v, " \t\r\n\"'");
    }
    if (v.len == 0) return "sans-serif";
    return v;
}

fn parseFontWeight(value: []const u8, parent: u16) u16 {
    const t = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(t, "bold")) return 700;
    if (std.ascii.eqlIgnoreCase(t, "bolder")) return @min(900, parent + 200);
    if (std.ascii.eqlIgnoreCase(t, "lighter")) return @max(100, parent -| 200);
    if (std.ascii.eqlIgnoreCase(t, "normal")) return 400;
    if (std.fmt.parseInt(u16, t, 10) catch null) |n| return std.math.clamp(n, 100, 900);
    return parent;
}

fn parseLength(value: []const u8, font_size: f64, viewport: Viewport, root_font_size: f64) ?f64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.eql(u8, trimmed, "0")) return 0;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (!(std.ascii.isDigit(c) or c == '.' or c == '+' or c == '-')) break;
    }
    if (i == 0) return null;
    const number = std.fmt.parseFloat(f64, trimmed[0..i]) catch return null;
    const unit = std.mem.trim(u8, trimmed[i..], " \t\r\n");
    if (unit.len == 0 or std.mem.eql(u8, unit, "px")) return number;
    if (std.mem.eql(u8, unit, "em")) return number * font_size;
    if (std.mem.eql(u8, unit, "rem")) return number * root_font_size;
    if (std.mem.eql(u8, unit, "vw")) return number * viewport.width / 100.0;
    if (std.mem.eql(u8, unit, "vh")) return number * viewport.height / 100.0;
    if (std.mem.eql(u8, unit, "%")) return number; // caller may interpret
    if (std.mem.eql(u8, unit, "pt")) return number * 96.0 / 72.0;
    if (std.mem.eql(u8, unit, "pc")) return number * 16.0;
    if (std.mem.eql(u8, unit, "in")) return number * 96.0;
    if (std.mem.eql(u8, unit, "cm")) return number * 96.0 / 2.54;
    if (std.mem.eql(u8, unit, "mm")) return number * 96.0 / 25.4;
    return number;
}

fn parseEdgeShorthand(value: []const u8, font_size: f64, viewport: Viewport) BoxEdge {
    var iter = std.mem.tokenizeAny(u8, value, " \t\r\n");
    var tokens: [4][]const u8 = .{ "", "", "", "" };
    var n: usize = 0;
    while (iter.next()) |t| : (n += 1) {
        if (n >= 4) break;
        tokens[n] = t;
    }
    if (n == 0) return .{};
    const t0 = parseLength(tokens[0], font_size, viewport, font_size) orelse 0;
    if (n == 1) return .{ .top = t0, .right = t0, .bottom = t0, .left = t0 };
    const t1 = parseLength(tokens[1], font_size, viewport, font_size) orelse 0;
    if (n == 2) return .{ .top = t0, .right = t1, .bottom = t0, .left = t1 };
    const t2 = parseLength(tokens[2], font_size, viewport, font_size) orelse 0;
    if (n == 3) return .{ .top = t0, .right = t1, .bottom = t2, .left = t1 };
    const t3 = parseLength(tokens[3], font_size, viewport, font_size) orelse 0;
    return .{ .top = t0, .right = t1, .bottom = t2, .left = t3 };
}

fn parseColor(value: []const u8) ?Color {
    const t = std.mem.trim(u8, value, " \t\r\n");
    if (t.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(t, "transparent")) return Color.transparent;
    if (std.mem.startsWith(u8, t, "#")) return parseHexColor(t[1..]);
    if (std.mem.startsWith(u8, t, "rgb(")) return parseRgb(t[4..]);
    if (std.mem.startsWith(u8, t, "rgba(")) return parseRgb(t[5..]);
    return parseNamedColor(t);
}

fn parseHexColor(text: []const u8) ?Color {
    const hex = std.mem.trim(u8, text, " )\t");
    if (hex.len == 3) {
        const r = (std.fmt.parseInt(u8, hex[0..1], 16) catch return null) * 17;
        const g = (std.fmt.parseInt(u8, hex[1..2], 16) catch return null) * 17;
        const b = (std.fmt.parseInt(u8, hex[2..3], 16) catch return null) * 17;
        return .{ .r = r, .g = g, .b = b };
    }
    if (hex.len == 6) {
        const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
        const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
        const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
        return .{ .r = r, .g = g, .b = b };
    }
    if (hex.len == 8) {
        const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
        const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
        const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
        const a = std.fmt.parseInt(u8, hex[6..8], 16) catch return null;
        return .{ .r = r, .g = g, .b = b, .a = @as(f32, @floatFromInt(a)) / 255.0 };
    }
    return null;
}

fn parseRgb(text: []const u8) ?Color {
    const close = std.mem.indexOfScalar(u8, text, ')') orelse text.len;
    const inner = text[0..close];
    var iter = std.mem.tokenizeAny(u8, inner, ", \t");
    const r_str = iter.next() orelse return null;
    const g_str = iter.next() orelse return null;
    const b_str = iter.next() orelse return null;
    const r = std.fmt.parseInt(i32, r_str, 10) catch return null;
    const g = std.fmt.parseInt(i32, g_str, 10) catch return null;
    const b = std.fmt.parseInt(i32, b_str, 10) catch return null;
    var a: f32 = 1.0;
    if (iter.next()) |a_str| {
        a = std.fmt.parseFloat(f32, a_str) catch 1.0;
    }
    return .{
        .r = @intCast(std.math.clamp(r, 0, 255)),
        .g = @intCast(std.math.clamp(g, 0, 255)),
        .b = @intCast(std.math.clamp(b, 0, 255)),
        .a = std.math.clamp(a, 0.0, 1.0),
    };
}

const NamedColorEntry = struct { name: []const u8, color: Color };

const named_colors = [_]NamedColorEntry{
    .{ .name = "black", .color = .{ .r = 0, .g = 0, .b = 0 } },
    .{ .name = "white", .color = .{ .r = 255, .g = 255, .b = 255 } },
    .{ .name = "red", .color = .{ .r = 255, .g = 0, .b = 0 } },
    .{ .name = "green", .color = .{ .r = 0, .g = 128, .b = 0 } },
    .{ .name = "blue", .color = .{ .r = 0, .g = 0, .b = 255 } },
    .{ .name = "yellow", .color = .{ .r = 255, .g = 255, .b = 0 } },
    .{ .name = "orange", .color = .{ .r = 255, .g = 165, .b = 0 } },
    .{ .name = "purple", .color = .{ .r = 128, .g = 0, .b = 128 } },
    .{ .name = "gray", .color = .{ .r = 128, .g = 128, .b = 128 } },
    .{ .name = "grey", .color = .{ .r = 128, .g = 128, .b = 128 } },
    .{ .name = "silver", .color = .{ .r = 192, .g = 192, .b = 192 } },
    .{ .name = "lightgray", .color = .{ .r = 211, .g = 211, .b = 211 } },
    .{ .name = "darkgray", .color = .{ .r = 169, .g = 169, .b = 169 } },
    .{ .name = "navy", .color = .{ .r = 0, .g = 0, .b = 128 } },
    .{ .name = "teal", .color = .{ .r = 0, .g = 128, .b = 128 } },
    .{ .name = "aqua", .color = .{ .r = 0, .g = 255, .b = 255 } },
    .{ .name = "cyan", .color = .{ .r = 0, .g = 255, .b = 255 } },
    .{ .name = "lime", .color = .{ .r = 0, .g = 255, .b = 0 } },
    .{ .name = "fuchsia", .color = .{ .r = 255, .g = 0, .b = 255 } },
    .{ .name = "magenta", .color = .{ .r = 255, .g = 0, .b = 255 } },
    .{ .name = "maroon", .color = .{ .r = 128, .g = 0, .b = 0 } },
    .{ .name = "olive", .color = .{ .r = 128, .g = 128, .b = 0 } },
};

fn parseNamedColor(name: []const u8) ?Color {
    for (named_colors) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.color;
    }
    return null;
}

// ---------------- Layout ----------------

fn layoutBlock(
    ctx: *LayoutCtx,
    node_id: dom.NodeId,
    parent_x: f64,
    parent_y: f64,
    available_width: f64,
    parent: Inheritable,
) !*LayoutBox {
    const node = ctx.doc.getNode(node_id);
    if (node.kind == .text) {
        return try makeTextOnlyBlock(ctx, node, parent_x, parent_y, available_width, parent);
    }

    var style = try computeStyle(ctx, node_id, parent);
    if (style.display == .none) {
        return makeEmptyBox(ctx, node_id, style, parent_x, parent_y);
    }

    // Resolve auto-margin centering.
    if (style.margin.left < 0 and style.margin.right < 0) {
        if (style.width) |w| {
            const remaining = @max(0, available_width - w);
            const half = remaining / 2.0;
            style.margin.left = half;
            style.margin.right = half;
        } else {
            style.margin.left = 0;
            style.margin.right = 0;
        }
    } else {
        if (style.margin.left < 0) style.margin.left = 0;
        if (style.margin.right < 0) style.margin.right = 0;
    }

    const outer_width = if (style.width) |w| w + style.padding.left + style.padding.right + style.border_width.left + style.border_width.right else available_width - style.margin.left - style.margin.right;
    const content_x = parent_x + style.margin.left + style.border_width.left + style.padding.left;
    const content_y = parent_y + style.margin.top + style.border_width.top + style.padding.top;
    const content_width = @max(0, outer_width - style.padding.left - style.padding.right - style.border_width.left - style.border_width.right);

    const inheritable: Inheritable = .{
        .font_size = style.font_size,
        .color = style.color,
        .font_family = style.font_family,
        .font_weight = style.font_weight,
        .line_height = style.line_height,
        .text_align = style.text_align,
        .italic = style.italic,
        .underline = style.text_decoration_underline,
    };

    var children: std.ArrayList(*LayoutBox) = .empty;
    var inline_buffer: std.ArrayList(InlineItem) = .empty;
    var current_y = content_y;

    var child = node.first_child;
    while (child) |cid| : (child = ctx.doc.nodes[cid].next_sibling) {
        const child_node = ctx.doc.getNode(cid);
        if (child_node.kind == .text) {
            try inline_buffer.append(ctx.allocator, .{
                .kind = .text,
                .text = child_node.text,
                .style = inheritable,
            });
            continue;
        }
        if (child_node.kind != .element) continue;
        const child_style = try computeStyle(ctx, cid, inheritable);
        if (child_style.display == .none) continue;
        if (child_style.display == .inline_) {
            try collectInline(ctx, cid, child_style, &inline_buffer);
            continue;
        }
        // Flush any inline buffer as an anonymous box first.
        if (inline_buffer.items.len > 0) {
            const inline_box = try buildInlineBox(ctx, content_x, current_y, content_width, inheritable, inline_buffer.items);
            current_y += inline_box.height;
            try children.append(ctx.allocator, inline_box);
            inline_buffer.clearRetainingCapacity();
        }
        const child_box = try layoutBlock(ctx, cid, content_x, current_y, content_width, inheritable);
        current_y += child_box.height + child_box.style.margin.top + child_box.style.margin.bottom;
        try children.append(ctx.allocator, child_box);
    }

    if (inline_buffer.items.len > 0) {
        const inline_box = try buildInlineBox(ctx, content_x, current_y, content_width, inheritable, inline_buffer.items);
        current_y += inline_box.height;
        try children.append(ctx.allocator, inline_box);
    }

    const content_height = current_y - content_y;
    const explicit_height = style.height orelse content_height;

    const box = try ctx.allocator.create(LayoutBox);
    box.* = .{
        .node_id = node_id,
        .style = style,
        .x = parent_x + style.margin.left,
        .y = parent_y + style.margin.top,
        .width = outer_width,
        .height = explicit_height + style.padding.top + style.padding.bottom + style.border_width.top + style.border_width.bottom,
        .children = try children.toOwnedSlice(ctx.allocator),
        .text_runs = &.{},
    };
    return box;
}

fn makeEmptyBox(ctx: *LayoutCtx, node_id: dom.NodeId, style: ComputedStyle, x: f64, y: f64) !*LayoutBox {
    const box = try ctx.allocator.create(LayoutBox);
    box.* = .{
        .node_id = node_id,
        .style = style,
        .x = x,
        .y = y,
        .width = 0,
        .height = 0,
    };
    return box;
}

fn makeTextOnlyBlock(
    ctx: *LayoutCtx,
    node: *const dom.Node,
    parent_x: f64,
    parent_y: f64,
    available_width: f64,
    parent: Inheritable,
) !*LayoutBox {
    var items: std.ArrayList(InlineItem) = .empty;
    try items.append(ctx.allocator, .{ .kind = .text, .text = node.text, .style = parent });
    const box = try buildInlineBox(ctx, parent_x, parent_y, available_width, parent, items.items);
    return box;
}

const InlineItemKind = enum { text };

const InlineItem = struct {
    kind: InlineItemKind,
    text: []const u8,
    style: Inheritable,
};

fn collectInline(
    ctx: *LayoutCtx,
    node_id: dom.NodeId,
    self_style: ComputedStyle,
    out: *std.ArrayList(InlineItem),
) !void {
    const inheritable: Inheritable = .{
        .font_size = self_style.font_size,
        .color = self_style.color,
        .font_family = self_style.font_family,
        .font_weight = self_style.font_weight,
        .line_height = self_style.line_height,
        .text_align = self_style.text_align,
        .italic = self_style.italic,
        .underline = self_style.text_decoration_underline,
    };
    const node = ctx.doc.getNode(node_id);
    var child = node.first_child;
    while (child) |cid| : (child = ctx.doc.nodes[cid].next_sibling) {
        const child_node = ctx.doc.getNode(cid);
        if (child_node.kind == .text) {
            try out.append(ctx.allocator, .{
                .kind = .text,
                .text = child_node.text,
                .style = inheritable,
            });
        } else if (child_node.kind == .element) {
            const child_style = try computeStyle(ctx, cid, inheritable);
            if (child_style.display == .none) continue;
            if (child_style.display == .inline_ or child_style.display == .inline_block) {
                try collectInline(ctx, cid, child_style, out);
            }
            // Block children inside inline parents: ignore for the inline pass.
        }
    }
}

fn buildInlineBox(
    ctx: *LayoutCtx,
    x: f64,
    y: f64,
    width: f64,
    parent: Inheritable,
    items: []const InlineItem,
) !*LayoutBox {
    var runs: std.ArrayList(TextRun) = .empty;
    var current_x: f64 = x;
    var current_y: f64 = y;
    var line_height: f64 = parent.font_size * parent.line_height;
    var total_height: f64 = 0;

    for (items) |item| {
        if (item.kind != .text) continue;
        const trimmed = item.text;
        if (trimmed.len == 0) continue;
        const font_size = item.style.font_size;
        const lh = font_size * item.style.line_height;
        if (lh > line_height) line_height = lh;

        var word_iter = std.mem.tokenizeAny(u8, trimmed, " \t\n\r");
        while (word_iter.next()) |word| {
            const word_w = approxTextWidth(word, font_size);
            if (current_x > x and current_x + word_w > x + width) {
                current_x = x;
                current_y += line_height;
                total_height += line_height;
            }
            const baseline = current_y + font_size * 0.85;
            try runs.append(ctx.allocator, .{
                .text = word,
                .x = current_x,
                .y = baseline,
                .font_family = item.style.font_family,
                .font_size = font_size,
                .font_weight = item.style.font_weight,
                .color = item.style.color,
                .underline = item.style.underline,
                .italic = item.style.italic,
            });
            current_x += word_w + approxTextWidth(" ", font_size);
        }
    }
    if (runs.items.len > 0) total_height += line_height;

    const box = try ctx.allocator.create(LayoutBox);
    box.* = .{
        .node_id = null,
        .style = .{
            .display = .block,
            .color = parent.color,
            .font_family = parent.font_family,
            .font_size = parent.font_size,
            .font_weight = parent.font_weight,
            .line_height = parent.line_height,
            .text_align = parent.text_align,
        },
        .x = x,
        .y = y,
        .width = width,
        .height = total_height,
        .children = &.{},
        .text_runs = try runs.toOwnedSlice(ctx.allocator),
    };
    return box;
}

fn approxTextWidth(text: []const u8, font_size: f64) f64 {
    // Quick approximation for sans-serif: average glyph ~ 0.55 of font size.
    var visible: usize = 0;
    for (text) |c| {
        if (c >= 0x20 and c != 0x7F) visible += 1;
    }
    return @as(f64, @floatFromInt(visible)) * font_size * 0.55;
}

// ---------------- SVG Paint ----------------

pub fn paintToSvg(
    allocator: std.mem.Allocator,
    result: *const LayoutResult,
) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try buf.writer.print(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\">",
        .{ result.viewport.width, result.viewport.height, result.viewport.width, result.viewport.height });
    try buf.writer.writeAll("<desc>kuri-engine: CSS-aware layout + paint, not full CSS layout</desc>");
    try buf.writer.writeAll("<rect width=\"100%\" height=\"100%\" fill=\"white\"/>");
    try paintBox(allocator, &buf, result.root);
    try buf.writer.writeAll("</svg>");
    return allocator.dupe(u8, buf.written());
}

fn paintBox(allocator: std.mem.Allocator, buf: *std.Io.Writer.Allocating, box: *const LayoutBox) !void {
    if (box.style.background_color) |bg| {
        if (bg.a > 0.001) {
            try buf.writer.print(
                "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"{s}\" fill-opacity=\"{d:.3}\"/>",
                .{ box.x, box.y, box.width, box.height, try colorToHex(allocator, bg), bg.a });
        }
    }
    if (box.style.border_width.top + box.style.border_width.right + box.style.border_width.bottom + box.style.border_width.left > 0) {
        try buf.writer.print(
            "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"none\" stroke=\"{s}\" stroke-width=\"{d:.2}\"/>",
            .{ box.x, box.y, box.width, box.height, try colorToHex(allocator, box.style.border_color), box.style.border_width.top });
    }
    for (box.text_runs) |run| {
        const escaped = try escapeXml(allocator, run.text);
        defer allocator.free(escaped);
        const font_style = if (run.italic) "italic" else "normal";
        try buf.writer.print(
            "<text x=\"{d:.2}\" y=\"{d:.2}\" font-family=\"{s}\" font-size=\"{d:.2}\" font-weight=\"{d}\" font-style=\"{s}\" fill=\"{s}\"",
            .{ run.x, run.y, run.font_family, run.font_size, run.font_weight, font_style, try colorToHex(allocator, run.color) });
        if (run.underline) try buf.writer.writeAll(" text-decoration=\"underline\"");
        try buf.writer.writeAll(">");
        try buf.writer.writeAll(escaped);
        try buf.writer.writeAll("</text>");
    }
    for (box.children) |child| try paintBox(allocator, buf, child);
}

fn colorToHex(allocator: std.mem.Allocator, color: Color) ![]const u8 {
    return std.fmt.allocPrint(allocator, "#{X:0>2}{X:0>2}{X:0>2}", .{ color.r, color.g, color.b });
}

fn escapeXml(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| switch (c) {
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        '&' => try out.appendSlice(allocator, "&amp;"),
        '"' => try out.appendSlice(allocator, "&quot;"),
        '\'' => try out.appendSlice(allocator, "&apos;"),
        else => try out.append(allocator, c),
    };
    return out.toOwnedSlice(allocator);
}

// ---------------- Tests ----------------

test "layout simple page with body and h1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try dom.Document.parse(a, "<html><body><h1>Hi</h1><p>world</p></body></html>");
    var page: model.Page = .{
        .requested_url = "",
        .url = "",
        .html = "",
        .dom = doc,
        .title = "",
        .text = "",
        .links = &.{},
        .forms = &.{},
        .resources = &.{},
        .js = .{},
        .redirect_chain = &.{},
        .cookie_count = 0,
        .status_code = 200,
        .content_type = "text/html",
        .fallback_mode = .native_static,
        .pipeline = "test",
    };
    var result = try layoutPage(std.testing.allocator, &page, .{ .width = 800, .height = 600 });
    defer result.deinit();
    try std.testing.expect(result.root.children.len > 0);
}

test "paintToSvg emits svg with text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try dom.Document.parse(a, "<html><body><h1>Hi</h1></body></html>");
    var page: model.Page = .{
        .requested_url = "",
        .url = "",
        .html = "",
        .dom = doc,
        .title = "",
        .text = "",
        .links = &.{},
        .forms = &.{},
        .resources = &.{},
        .js = .{},
        .redirect_chain = &.{},
        .cookie_count = 0,
        .status_code = 200,
        .content_type = "text/html",
        .fallback_mode = .native_static,
        .pipeline = "test",
    };
    var result = try layoutPage(std.testing.allocator, &page, .{ .width = 800, .height = 600 });
    defer result.deinit();
    const svg = try paintToSvg(std.testing.allocator, &result);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Hi") != null);
}

test "parseColor handles hex and rgb" {
    const c1 = parseColor("#ff0000").?;
    try std.testing.expectEqual(@as(u8, 255), c1.r);
    const c2 = parseColor("rgb(0, 128, 64)").?;
    try std.testing.expectEqual(@as(u8, 128), c2.g);
    const c3 = parseColor("blue").?;
    try std.testing.expectEqual(@as(u8, 255), c3.b);
}

test "parseLength handles px em vw" {
    try std.testing.expectEqual(@as(f64, 16), parseLength("16px", 16, .{ .width = 1280, .height = 720 }, 16).?);
    try std.testing.expectEqual(@as(f64, 32), parseLength("2em", 16, .{ .width = 1280, .height = 720 }, 16).?);
    try std.testing.expectEqual(@as(f64, 128), parseLength("10vw", 16, .{ .width = 1280, .height = 720 }, 16).?);
}

test "parseEdgeShorthand 1/2/3/4 tokens" {
    const e1 = parseEdgeShorthand("10px", 16, .{});
    try std.testing.expectEqual(@as(f64, 10), e1.top);
    try std.testing.expectEqual(@as(f64, 10), e1.right);
    const e2 = parseEdgeShorthand("10px 20px", 16, .{});
    try std.testing.expectEqual(@as(f64, 20), e2.right);
    try std.testing.expectEqual(@as(f64, 20), e2.left);
    const e4 = parseEdgeShorthand("1px 2px 3px 4px", 16, .{});
    try std.testing.expectEqual(@as(f64, 4), e4.left);
}
