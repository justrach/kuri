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

pub const WhiteSpace = enum {
    normal,
    pre,
    pre_wrap,
    nowrap,
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
    white_space: WhiteSpace = .normal,
    text_indent: f64 = 0,
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
    white_space: WhiteSpace = .normal,
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
        .white_space = parent.white_space,
        .italic = parent.italic,
        .text_decoration_underline = parent.underline,
        .display = defaultDisplayForTag(ctx.doc.getNode(node_id).name),
    };

    // <pre> defaults to white-space: pre
    const tag_name = ctx.doc.getNode(node_id).name;
    if (std.ascii.eqlIgnoreCase(tag_name, "pre")) {
        style.white_space = .pre;
    }

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
    if (computed.get("white-space")) |v| style.white_space = parseWhiteSpace(v, style.white_space);
    if (computed.get("text-indent")) |v| {
        if (parseLength(v, style.font_size, ctx.viewport, style.font_size)) |px| {
            style.text_indent = px;
        }
    }
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

fn parseWhiteSpace(value: []const u8, fallback: WhiteSpace) WhiteSpace {
    const t = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(t, "normal")) return .normal;
    if (std.ascii.eqlIgnoreCase(t, "pre")) return .pre;
    if (std.ascii.eqlIgnoreCase(t, "pre-wrap")) return .pre_wrap;
    if (std.ascii.eqlIgnoreCase(t, "pre-line")) return .normal; // simplified
    if (std.ascii.eqlIgnoreCase(t, "nowrap")) return .nowrap;
    return fallback;
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
        .white_space = style.white_space,
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
        // <br> as a direct child of this block: emit a line break into the inline buffer.
        if (std.ascii.eqlIgnoreCase(child_node.name, "br")) {
            try inline_buffer.append(ctx.allocator, .{
                .kind = .line_break,
                .text = "",
                .style = inheritable,
            });
            continue;
        }
        const child_style = try computeStyle(ctx, cid, inheritable);
        if (child_style.display == .none) continue;
        if (child_style.display == .inline_) {
            try collectInline(ctx, cid, child_style, &inline_buffer);
            continue;
        }
        // Flush any inline buffer as an anonymous box first.
        if (inline_buffer.items.len > 0) {
            const inline_box = try buildInlineBox(ctx, content_x, current_y, content_width, inheritable, inline_buffer.items, style.text_indent);
            current_y += inline_box.height;
            try children.append(ctx.allocator, inline_box);
            inline_buffer.clearRetainingCapacity();
        }
        const child_box = try layoutBlock(ctx, cid, content_x, current_y, content_width, inheritable);
        current_y += child_box.height + child_box.style.margin.top + child_box.style.margin.bottom;
        try children.append(ctx.allocator, child_box);
    }

    if (inline_buffer.items.len > 0) {
        const inline_box = try buildInlineBox(ctx, content_x, current_y, content_width, inheritable, inline_buffer.items, style.text_indent);
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
    const box = try buildInlineBox(ctx, parent_x, parent_y, available_width, parent, items.items, 0);
    return box;
}

const InlineItemKind = enum { text, line_break };

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
        .white_space = self_style.white_space,
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
            // <br> emits a forced line break sentinel.
            if (std.ascii.eqlIgnoreCase(child_node.name, "br")) {
                try out.append(ctx.allocator, .{
                    .kind = .line_break,
                    .text = "",
                    .style = inheritable,
                });
                continue;
            }
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
    text_indent: f64,
) !*LayoutBox {
    var runs: std.ArrayList(TextRun) = .empty;
    var current_x: f64 = x + text_indent;
    var current_y: f64 = y;
    var line_height: f64 = parent.font_size * parent.line_height;
    var total_height: f64 = 0;
    var first_line: bool = true;

    // pending_space: a collapsible space carried over from a previous run
    // that we should emit *before* the next non-space content (unless we're
    // at the start of a line, in which case it's suppressed).
    var pending_space: bool = false;
    // line_has_content: have we placed any glyph on the current line yet?
    var line_has_content: bool = false;

    const lineStart = struct {
        fn call(cur_x: *f64, base_x: f64, indent: f64, is_first: bool) void {
            cur_x.* = base_x + (if (is_first) indent else 0);
        }
    }.call;

    for (items) |item| {
        const font_size = item.style.font_size;
        const lh = font_size * item.style.line_height;
        if (lh > line_height) line_height = lh;

        if (item.kind == .line_break) {
            // Forced line break: commit a line and reset.
            total_height += line_height;
            current_y += line_height;
            first_line = false;
            lineStart(&current_x, x, text_indent, first_line);
            pending_space = false;
            line_has_content = false;
            continue;
        }

        if (item.kind != .text) continue;
        const text = item.text;
        if (text.len == 0) continue;

        const ws = item.style.white_space;
        const space_w = textWidth(" ", item.style.font_family, font_size, item.style.font_weight, item.style.italic);

        if (ws == .pre or ws == .pre_wrap) {
            // Preserve whitespace and newlines.
            // Walk the text emitting runs split by newlines and (for pre_wrap) wrap on whitespace.
            var i: usize = 0;
            // For pre/pre_wrap we don't carry pending_space across — the run text itself contains literal spaces.
            pending_space = false;
            while (i < text.len) {
                // Find next newline.
                var j = i;
                while (j < text.len and text[j] != '\n') : (j += 1) {}
                const segment = text[i..j];
                if (segment.len > 0) {
                    if (ws == .pre) {
                        // No wrapping. Emit the segment as a single run.
                        const seg_w = textWidth(segment, item.style.font_family, font_size, item.style.font_weight, item.style.italic);
                        const baseline = current_y + font_size * 0.85;
                        try runs.append(ctx.allocator, .{
                            .text = segment,
                            .x = current_x,
                            .y = baseline,
                            .font_family = item.style.font_family,
                            .font_size = font_size,
                            .font_weight = item.style.font_weight,
                            .color = item.style.color,
                            .underline = item.style.underline,
                            .italic = item.style.italic,
                        });
                        current_x += seg_w;
                        line_has_content = true;
                    } else {
                        // pre_wrap: split on whitespace boundaries but preserve them.
                        var k: usize = 0;
                        while (k < segment.len) {
                            // Group of whitespace
                            var ws_end = k;
                            while (ws_end < segment.len and isAsciiSpace(segment[ws_end]) and segment[ws_end] != '\n') : (ws_end += 1) {}
                            if (ws_end > k) {
                                const ws_chunk = segment[k..ws_end];
                                const ws_chunk_w = textWidth(ws_chunk, item.style.font_family, font_size, item.style.font_weight, item.style.italic);
                                // Wrap before whitespace if the whitespace plus a soft break would cross? Standard pre-wrap wraps after the whitespace if the next word doesn't fit.
                                // Simpler: emit whitespace inline, then check word fit before emitting word.
                                const baseline = current_y + font_size * 0.85;
                                try runs.append(ctx.allocator, .{
                                    .text = ws_chunk,
                                    .x = current_x,
                                    .y = baseline,
                                    .font_family = item.style.font_family,
                                    .font_size = font_size,
                                    .font_weight = item.style.font_weight,
                                    .color = item.style.color,
                                    .underline = item.style.underline,
                                    .italic = item.style.italic,
                                });
                                current_x += ws_chunk_w;
                                line_has_content = true;
                                k = ws_end;
                                continue;
                            }
                            // Word
                            var word_end = k;
                            while (word_end < segment.len and !isAsciiSpace(segment[word_end])) : (word_end += 1) {}
                            const word = segment[k..word_end];
                            const word_w = textWidth(word, item.style.font_family, font_size, item.style.font_weight, item.style.italic);
                            // Wrap if needed
                            if (line_has_content and current_x + word_w > x + width) {
                                total_height += line_height;
                                current_y += line_height;
                                first_line = false;
                                lineStart(&current_x, x, text_indent, first_line);
                                line_has_content = false;
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
                            current_x += word_w;
                            line_has_content = true;
                            k = word_end;
                        }
                    }
                }
                if (j < text.len) {
                    // newline -> forced break
                    total_height += line_height;
                    current_y += line_height;
                    first_line = false;
                    lineStart(&current_x, x, text_indent, first_line);
                    line_has_content = false;
                    i = j + 1;
                } else {
                    i = j;
                }
            }
            continue;
        }

        // white-space: normal or nowrap. Collapse runs of whitespace to a
        // single space; suppress leading whitespace at line start.
        const starts_with_ws = isAsciiSpace(text[0]);
        const ends_with_ws = isAsciiSpace(text[text.len - 1]);

        if (starts_with_ws) {
            // The boundary between previous run and this run already collapses to
            // at most one space. If a previous run ended with whitespace, we don't
            // also accept whitespace from this run — pending_space suffices.
            if (line_has_content) pending_space = true;
        }

        var word_iter = std.mem.tokenizeAny(u8, text, " \t\n\r\x0c\x0b");
        while (word_iter.next()) |word| {
            const word_w = textWidth(word, item.style.font_family, font_size, item.style.font_weight, item.style.italic);
            // Decide if we need to emit pending_space.
            var prefix_space_w: f64 = 0;
            if (pending_space and line_has_content) {
                prefix_space_w = space_w;
            }
            // Wrap before word if it doesn't fit (only if not the first content on the line).
            if (ws != .nowrap and line_has_content and current_x + prefix_space_w + word_w > x + width) {
                // wrap: drop the pending space, move to next line.
                total_height += line_height;
                current_y += line_height;
                first_line = false;
                lineStart(&current_x, x, text_indent, first_line);
                line_has_content = false;
                pending_space = false;
                prefix_space_w = 0;
            }
            if (prefix_space_w > 0) {
                current_x += prefix_space_w;
                pending_space = false;
            } else if (pending_space and !line_has_content) {
                // Suppress leading whitespace at line start.
                pending_space = false;
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
            current_x += word_w;
            line_has_content = true;
            // After each word, mark a pending space — collapsed multiple spaces
            // and the gap between subsequent words/items both resolve to one space.
            pending_space = true;
        }
        // The pending_space carried beyond the loop is correct only if the text
        // ends in whitespace; otherwise drop it so adjacent runs without a real
        // boundary don't gain a phantom space.
        if (!ends_with_ws) pending_space = false;
        if (ends_with_ws and line_has_content) pending_space = true;
    }
    if (line_has_content or runs.items.len > 0) total_height += line_height;

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
            .white_space = parent.white_space,
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

fn isAsciiSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c or c == 0x0b;
}

// Per-character glyph width tables tuned to Chrome's macOS UA fonts.
// Widths are in units of font_size. Bold adds ~6%. Italic does not widen
// (real italic fonts have the same advance widths as upright).
//
// Three families:
//   - sans-serif (Helvetica/Arial-style proportions, default)
//   - serif      (Times-style, slightly narrower lowercase, wider some uppercase)
//   - monospace  (every char same width, ~0.60)

const FONT_SANS: [128]f64 = blk: {
    var t: [128]f64 = undefined;
    var i: usize = 0;
    while (i < 128) : (i += 1) t[i] = 0.55;
    // Control / non-printable
    i = 0;
    while (i < 0x20) : (i += 1) t[i] = 0;
    t[0x7F] = 0;
    // Punctuation / spacing
    t[' '] = 0.28;
    t['!'] = 0.28;
    t['"'] = 0.36;
    t['#'] = 0.56;
    t['$'] = 0.56;
    t['%'] = 0.89;
    t['&'] = 0.67;
    t['\''] = 0.19;
    t['('] = 0.33;
    t[')'] = 0.33;
    t['*'] = 0.39;
    t['+'] = 0.58;
    t[','] = 0.28;
    t['-'] = 0.33;
    t['.'] = 0.28;
    t['/'] = 0.28;
    // Digits ~0.55
    t['0'] = 0.56;
    t['1'] = 0.56;
    t['2'] = 0.56;
    t['3'] = 0.56;
    t['4'] = 0.56;
    t['5'] = 0.56;
    t['6'] = 0.56;
    t['7'] = 0.56;
    t['8'] = 0.56;
    t['9'] = 0.56;
    t[':'] = 0.28;
    t[';'] = 0.28;
    t['<'] = 0.58;
    t['='] = 0.58;
    t['>'] = 0.58;
    t['?'] = 0.56;
    t['@'] = 1.02;
    // Uppercase
    t['A'] = 0.67;
    t['B'] = 0.67;
    t['C'] = 0.72;
    t['D'] = 0.72;
    t['E'] = 0.67;
    t['F'] = 0.61;
    t['G'] = 0.78;
    t['H'] = 0.72;
    t['I'] = 0.28;
    t['J'] = 0.50;
    t['K'] = 0.67;
    t['L'] = 0.56;
    t['M'] = 0.83;
    t['N'] = 0.72;
    t['O'] = 0.78;
    t['P'] = 0.67;
    t['Q'] = 0.78;
    t['R'] = 0.72;
    t['S'] = 0.67;
    t['T'] = 0.61;
    t['U'] = 0.72;
    t['V'] = 0.67;
    t['W'] = 0.94;
    t['X'] = 0.67;
    t['Y'] = 0.67;
    t['Z'] = 0.61;
    t['['] = 0.28;
    t['\\'] = 0.28;
    t[']'] = 0.28;
    t['^'] = 0.47;
    t['_'] = 0.56;
    t['`'] = 0.33;
    // Lowercase
    t['a'] = 0.56;
    t['b'] = 0.56;
    t['c'] = 0.50;
    t['d'] = 0.56;
    t['e'] = 0.56;
    t['f'] = 0.28;
    t['g'] = 0.56;
    t['h'] = 0.56;
    t['i'] = 0.22;
    t['j'] = 0.22;
    t['k'] = 0.50;
    t['l'] = 0.22;
    t['m'] = 0.83;
    t['n'] = 0.56;
    t['o'] = 0.56;
    t['p'] = 0.56;
    t['q'] = 0.56;
    t['r'] = 0.33;
    t['s'] = 0.50;
    t['t'] = 0.28;
    t['u'] = 0.56;
    t['v'] = 0.50;
    t['w'] = 0.72;
    t['x'] = 0.50;
    t['y'] = 0.50;
    t['z'] = 0.50;
    t['{'] = 0.33;
    t['|'] = 0.26;
    t['}'] = 0.33;
    t['~'] = 0.58;
    break :blk t;
};

const FONT_SERIF: [128]f64 = blk: {
    var t: [128]f64 = undefined;
    var i: usize = 0;
    while (i < 128) : (i += 1) t[i] = 0.50;
    i = 0;
    while (i < 0x20) : (i += 1) t[i] = 0;
    t[0x7F] = 0;
    t[' '] = 0.25;
    t['!'] = 0.33;
    t['"'] = 0.41;
    t['#'] = 0.50;
    t['$'] = 0.50;
    t['%'] = 0.83;
    t['&'] = 0.78;
    t['\''] = 0.33;
    t['('] = 0.33;
    t[')'] = 0.33;
    t['*'] = 0.50;
    t['+'] = 0.56;
    t[','] = 0.25;
    t['-'] = 0.33;
    t['.'] = 0.25;
    t['/'] = 0.28;
    t['0'] = 0.50;
    t['1'] = 0.50;
    t['2'] = 0.50;
    t['3'] = 0.50;
    t['4'] = 0.50;
    t['5'] = 0.50;
    t['6'] = 0.50;
    t['7'] = 0.50;
    t['8'] = 0.50;
    t['9'] = 0.50;
    t[':'] = 0.28;
    t[';'] = 0.28;
    t['<'] = 0.56;
    t['='] = 0.56;
    t['>'] = 0.56;
    t['?'] = 0.44;
    t['@'] = 0.92;
    t['A'] = 0.72;
    t['B'] = 0.67;
    t['C'] = 0.67;
    t['D'] = 0.72;
    t['E'] = 0.61;
    t['F'] = 0.56;
    t['G'] = 0.72;
    t['H'] = 0.72;
    t['I'] = 0.33;
    t['J'] = 0.39;
    t['K'] = 0.72;
    t['L'] = 0.61;
    t['M'] = 0.89;
    t['N'] = 0.72;
    t['O'] = 0.72;
    t['P'] = 0.56;
    t['Q'] = 0.72;
    t['R'] = 0.67;
    t['S'] = 0.56;
    t['T'] = 0.61;
    t['U'] = 0.72;
    t['V'] = 0.72;
    t['W'] = 0.94;
    t['X'] = 0.72;
    t['Y'] = 0.72;
    t['Z'] = 0.61;
    t['['] = 0.33;
    t['\\'] = 0.28;
    t[']'] = 0.33;
    t['^'] = 0.47;
    t['_'] = 0.50;
    t['`'] = 0.33;
    t['a'] = 0.44;
    t['b'] = 0.50;
    t['c'] = 0.44;
    t['d'] = 0.50;
    t['e'] = 0.44;
    t['f'] = 0.33;
    t['g'] = 0.50;
    t['h'] = 0.50;
    t['i'] = 0.28;
    t['j'] = 0.28;
    t['k'] = 0.50;
    t['l'] = 0.28;
    t['m'] = 0.78;
    t['n'] = 0.50;
    t['o'] = 0.50;
    t['p'] = 0.50;
    t['q'] = 0.50;
    t['r'] = 0.33;
    t['s'] = 0.39;
    t['t'] = 0.28;
    t['u'] = 0.50;
    t['v'] = 0.50;
    t['w'] = 0.72;
    t['x'] = 0.50;
    t['y'] = 0.50;
    t['z'] = 0.44;
    t['{'] = 0.48;
    t['|'] = 0.20;
    t['}'] = 0.48;
    t['~'] = 0.54;
    break :blk t;
};

const FontKind = enum { sans, serif, mono };

fn detectFontKind(family: []const u8) FontKind {
    // Case-insensitive substring matching.
    if (asciiContainsIgnoreCase(family, "mono") or
        asciiContainsIgnoreCase(family, "courier") or
        asciiContainsIgnoreCase(family, "consolas") or
        asciiContainsIgnoreCase(family, "menlo"))
    {
        return .mono;
    }
    if (asciiContainsIgnoreCase(family, "serif") and !asciiContainsIgnoreCase(family, "sans")) {
        return .serif;
    }
    // Common serif fonts that don't have "serif" in the name.
    if (asciiContainsIgnoreCase(family, "times") or
        asciiContainsIgnoreCase(family, "georgia") or
        asciiContainsIgnoreCase(family, "garamond") or
        asciiContainsIgnoreCase(family, "palatino") or
        asciiContainsIgnoreCase(family, "cambria"))
    {
        return .serif;
    }
    return .sans;
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn glyphWidthRatio(c: u8, kind: FontKind) f64 {
    return switch (kind) {
        .mono => if (c == 0 or c == 0x7F or (c < 0x20)) 0.0 else 0.60,
        .sans => if (c < 128) FONT_SANS[c] else 0.55,
        .serif => if (c < 128) FONT_SERIF[c] else 0.50,
    };
}

fn textWidth(
    text: []const u8,
    font_family: []const u8,
    font_size: f64,
    font_weight: u16,
    italic: bool,
) f64 {
    _ = italic; // italic uses the same advance widths as upright in real fonts
    const kind = detectFontKind(font_family);
    var sum: f64 = 0;
    for (text) |c| sum += glyphWidthRatio(c, kind);
    var w = sum * font_size;
    if (font_weight >= 600) w *= 1.06; // bold ~6% wider
    return w;
}

// Backwards-compatible thin wrapper used by older callers / tests.
fn approxTextWidth(text: []const u8, font_size: f64) f64 {
    return textWidth(text, "sans-serif", font_size, 400, false);
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

// ---------------- Tests for text width / whitespace / br / text-indent ----------------

fn collectAllTextRuns(box: *const LayoutBox, out: *std.ArrayList(TextRun), allocator: std.mem.Allocator) !void {
    for (box.text_runs) |r| try out.append(allocator, r);
    for (box.children) |c| try collectAllTextRuns(c, out, allocator);
}

test "text width table differs by char" {
    const fs: f64 = 16;
    const w_i = textWidth("i", "sans-serif", fs, 400, false);
    const w_M = textWidth("M", "sans-serif", fs, 400, false);
    try std.testing.expect(w_i < w_M);
    // Mono font: every char is the same width.
    const w_mi = textWidth("i", "Courier", fs, 400, false);
    const w_mM = textWidth("M", "Courier", fs, 400, false);
    try std.testing.expectEqual(w_mi, w_mM);
    // Bold widens.
    const w_bold = textWidth("hello", "sans-serif", fs, 700, false);
    const w_norm = textWidth("hello", "sans-serif", fs, 400, false);
    try std.testing.expect(w_bold > w_norm);
    // Italic does not change advance width.
    const w_italic = textWidth("hello", "sans-serif", fs, 400, true);
    try std.testing.expectEqual(w_norm, w_italic);
    // Serif vs sans differ.
    const w_serif = textWidth("M", "Times", fs, 400, false);
    try std.testing.expect(w_serif != w_M);
}

test "whitespace collapses to single space" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try dom.Document.parse(a, "<html><body><p>  hello   world  </p></body></html>");
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

    var runs: std.ArrayList(TextRun) = .empty;
    defer runs.deinit(std.testing.allocator);
    try collectAllTextRuns(result.root, &runs, std.testing.allocator);

    // Expect exactly two runs: "hello" and "world".
    try std.testing.expectEqual(@as(usize, 2), runs.items.len);
    try std.testing.expectEqualStrings("hello", runs.items[0].text);
    try std.testing.expectEqualStrings("world", runs.items[1].text);

    // Verify the gap between the two runs is exactly one space wide.
    const fs = runs.items[0].font_size;
    const family = runs.items[0].font_family;
    const w_hello = textWidth("hello", family, fs, runs.items[0].font_weight, runs.items[0].italic);
    const w_space = textWidth(" ", family, fs, runs.items[0].font_weight, runs.items[0].italic);
    const expected_world_x = runs.items[0].x + w_hello + w_space;
    try std.testing.expectApproxEqAbs(expected_world_x, runs.items[1].x, 0.001);

    // Both runs share the same y (single line).
    try std.testing.expectEqual(runs.items[0].y, runs.items[1].y);
}

test "br forces line break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try dom.Document.parse(a, "<html><body><p>First<br>Second</p></body></html>");
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

    var runs: std.ArrayList(TextRun) = .empty;
    defer runs.deinit(std.testing.allocator);
    try collectAllTextRuns(result.root, &runs, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), runs.items.len);
    try std.testing.expectEqualStrings("First", runs.items[0].text);
    try std.testing.expectEqualStrings("Second", runs.items[1].text);
    // Different y positions — line break moved second run to the next line.
    try std.testing.expect(runs.items[1].y > runs.items[0].y);
}

test "text-indent shifts first run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try dom.Document.parse(a, "<html><body><p style=\"text-indent:20px\">Hello world</p></body></html>");
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

    // Locate the inline (anonymous) box that holds the runs to verify x = box.x + 20.
    var runs: std.ArrayList(TextRun) = .empty;
    defer runs.deinit(std.testing.allocator);
    try collectAllTextRuns(result.root, &runs, std.testing.allocator);
    try std.testing.expect(runs.items.len >= 1);

    // Find the box whose first run is "Hello".
    const InlineBoxFinder = struct {
        fn find(b: *const LayoutBox) ?*const LayoutBox {
            if (b.text_runs.len > 0 and std.mem.eql(u8, b.text_runs[0].text, "Hello")) return b;
            for (b.children) |c| if (find(c)) |hit| return hit;
            return null;
        }
    };
    const inline_box = InlineBoxFinder.find(result.root) orelse return error.TestUnexpectedResult;
    const first_run = inline_box.text_runs[0];
    try std.testing.expectApproxEqAbs(inline_box.x + 20.0, first_run.x, 0.001);
}
