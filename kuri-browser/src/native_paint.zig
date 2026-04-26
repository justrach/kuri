const std = @import("std");
const dom = @import("dom.zig");
const model = @import("model.zig");
const render = @import("render.zig");

pub const Options = struct {
    out_path: ?[]const u8 = null,
    width: u32 = 1280,
    height: u32 = 720,
};

pub const Result = struct {
    path: []const u8,
    bytes: usize,
    width: u32,
    height: u32,
    node_count: usize,
    text_bytes: usize,
    backend: []const u8 = "kuri-native-svg-paint",
};

const max_blocks = 96;
const max_text_per_block = 280;
const line_height: i32 = 24;

const BlockKind = enum {
    heading,
    paragraph,
    link,
    control,
    image,
    code,
};

const Block = struct {
    kind: BlockKind,
    text: []const u8,
};

const PageStyle = struct {
    background: []const u8 = "#ffffff",
    body_x: i32 = 8,
    body_y: i32 = 8,
    body_width: i32 = 1264,
    font_family: []const u8 = "system-ui, sans-serif",
    text_color: []const u8 = "#000000",
    link_color: []const u8 = "#0000ee",
    div_opacity: []const u8 = "1",
    h1_font_size: u32 = 32,
    paragraph_font_size: u32 = 16,
};

pub fn paintUrl(allocator: std.mem.Allocator, url: []const u8, options: Options) !Result {
    const artifacts = try render.renderUrlArtifacts(allocator, url, .{});
    return paintPageToFile(allocator, artifacts.page, options);
}

pub fn paintPageToFile(allocator: std.mem.Allocator, page: model.Page, options: Options) !Result {
    const svg = try paintPageSvg(allocator, page, options);
    const path = try outputPath(allocator, options.out_path);
    try std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{
        .sub_path = path,
        .data = svg,
    });
    return .{
        .path = path,
        .bytes = svg.len,
        .width = options.width,
        .height = options.height,
        .node_count = page.dom.nodeCount(),
        .text_bytes = page.text.len,
    };
}

pub fn paintPageSvg(allocator: std.mem.Allocator, page: model.Page, options: Options) ![]const u8 {
    const style = resolvePageStyle(&page.dom, options);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.print(
        \\<svg xmlns="http://www.w3.org/2000/svg" width="{d}" height="{d}" viewBox="0 0 {d} {d}">
        \\<desc>kuri-native-svg-paint: browser-flow approximation, not full CSS layout</desc>
        \\<rect width="{d}" height="{d}" fill="{s}"/>
        \\
    , .{ options.width, options.height, options.width, options.height, options.width, options.height, style.background });

    const body = bodyNode(&page.dom) orelse page.dom.root();
    var y = style.body_y;
    try drawFlowChildren(allocator, &out.writer, &page.dom, body, style, style.body_x, &y, style.div_opacity);

    try out.writer.writeAll("</svg>\n");
    return allocator.dupe(u8, out.written());
}

fn bodyNode(document: *const dom.Document) ?dom.NodeId {
    for (document.nodes, 0..) |node, index| {
        if (node.kind == .element and std.ascii.eqlIgnoreCase(node.name, "body")) return @intCast(index);
    }
    return null;
}

fn resolvePageStyle(document: *const dom.Document, options: Options) PageStyle {
    var style = PageStyle{
        .body_width = @max(1, @as(i32, @intCast(options.width)) - 16),
    };
    const css = firstStyleText(document) orelse return style;

    if (cssRule(css, "body")) |body| {
        if (cssProperty(body, "background")) |value| style.background = value;
        if (cssProperty(body, "font-family")) |value| style.font_family = value;
        if (cssProperty(body, "width")) |value| {
            style.body_width = parseCssLength(value, options.width, options.height, style.paragraph_font_size) orelse style.body_width;
        }
        if (cssProperty(body, "margin")) |value| {
            applyBodyMargin(&style, value, options.width, options.height);
        }
    }
    if (cssRule(css, "h1")) |h1| {
        if (cssProperty(h1, "font-size")) |value| {
            const parsed = parseCssLength(value, options.width, options.height, style.paragraph_font_size) orelse @as(i32, @intCast(style.h1_font_size));
            style.h1_font_size = @intCast(@max(1, parsed));
        }
    }
    if (cssRule(css, "div")) |div| {
        if (cssProperty(div, "opacity")) |value| style.div_opacity = value;
    }
    if (cssRule(css, "a:link,a:visited") orelse cssRule(css, "a")) |anchor| {
        if (cssProperty(anchor, "color")) |value| style.link_color = value;
    }
    return style;
}

fn firstStyleText(document: *const dom.Document) ?[]const u8 {
    for (document.nodes) |node| {
        if (node.kind == .element and std.ascii.eqlIgnoreCase(node.name, "style")) {
            var child = node.first_child;
            while (child) |child_id| : (child = document.getNode(child_id).next_sibling) {
                const child_node = document.getNode(child_id);
                if (child_node.kind == .text) return std.mem.trim(u8, child_node.text, " \t\r\n");
            }
        }
    }
    return null;
}

fn cssRule(css: []const u8, selector: []const u8) ?[]const u8 {
    const selector_pos = std.mem.indexOf(u8, css, selector) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, css, selector_pos + selector.len, '{') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, css, open + 1, '}') orelse return null;
    return css[open + 1 .. close];
}

fn cssProperty(rule: []const u8, property: []const u8) ?[]const u8 {
    const property_pos = std.mem.indexOf(u8, rule, property) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, rule, property_pos + property.len, ':') orelse return null;
    const semicolon = std.mem.indexOfScalarPos(u8, rule, colon + 1, ';') orelse rule.len;
    return std.mem.trim(u8, rule[colon + 1 .. semicolon], " \t\r\n");
}

fn parseCssLength(value: []const u8, viewport_width: u32, viewport_height: u32, font_size: u32) ?i32 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const number_end = leadingNumberLen(trimmed);
    if (number_end == 0) return null;
    const number = std.fmt.parseFloat(f64, trimmed[0..number_end]) catch return null;
    const unit = std.mem.trim(u8, trimmed[number_end..], " \t\r\n");
    const pixels = if (std.mem.startsWith(u8, unit, "vw"))
        number * @as(f64, @floatFromInt(viewport_width)) / 100.0
    else if (std.mem.startsWith(u8, unit, "vh"))
        number * @as(f64, @floatFromInt(viewport_height)) / 100.0
    else if (std.mem.startsWith(u8, unit, "em"))
        number * @as(f64, @floatFromInt(font_size))
    else
        number;
    return @intFromFloat(@round(pixels));
}

fn leadingNumberLen(value: []const u8) usize {
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const c = value[i];
        if (!(std.ascii.isDigit(c) or c == '.' or c == '+' or c == '-')) break;
    }
    return i;
}

fn applyBodyMargin(style: *PageStyle, value: []const u8, viewport_width: u32, viewport_height: u32) void {
    const first = firstCssToken(value) orelse return;
    const y = parseCssLength(first, viewport_width, viewport_height, style.paragraph_font_size) orelse return;
    style.body_y = y;
    if (std.mem.indexOf(u8, value, "auto") != null) {
        style.body_x = @divTrunc(@as(i32, @intCast(viewport_width)) - style.body_width, 2);
    } else if (secondCssToken(value)) |second| {
        style.body_x = parseCssLength(second, viewport_width, viewport_height, style.paragraph_font_size) orelse style.body_x;
    } else {
        style.body_x = y;
    }
}

fn firstCssToken(value: []const u8) ?[]const u8 {
    var iter = std.mem.tokenizeAny(u8, value, " \t\r\n");
    return iter.next();
}

fn secondCssToken(value: []const u8) ?[]const u8 {
    var iter = std.mem.tokenizeAny(u8, value, " \t\r\n");
    _ = iter.next() orelse return null;
    return iter.next();
}

fn drawFlowChildren(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    document: *const dom.Document,
    node_id: dom.NodeId,
    style: PageStyle,
    x: i32,
    y: *i32,
    opacity: []const u8,
) anyerror!void {
    var child = document.getNode(node_id).first_child;
    while (child) |child_id| : (child = document.getNode(child_id).next_sibling) {
        try drawFlowNode(allocator, writer, document, child_id, style, x, y, opacity);
    }
}

fn drawFlowNode(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    document: *const dom.Document,
    node_id: dom.NodeId,
    style: PageStyle,
    x: i32,
    y: *i32,
    opacity: []const u8,
) anyerror!void {
    const node = document.getNode(node_id);
    if (node.kind != .element) return;
    if (std.ascii.eqlIgnoreCase(node.name, "script") or
        std.ascii.eqlIgnoreCase(node.name, "style") or
        std.ascii.eqlIgnoreCase(node.name, "head") or
        std.ascii.eqlIgnoreCase(node.name, "title") or
        std.ascii.eqlIgnoreCase(node.name, "meta"))
    {
        return;
    }

    if (std.ascii.eqlIgnoreCase(node.name, "html") or
        std.ascii.eqlIgnoreCase(node.name, "body") or
        std.ascii.eqlIgnoreCase(node.name, "div") or
        std.ascii.eqlIgnoreCase(node.name, "main") or
        std.ascii.eqlIgnoreCase(node.name, "section") or
        std.ascii.eqlIgnoreCase(node.name, "article"))
    {
        const child_opacity = if (std.ascii.eqlIgnoreCase(node.name, "div")) style.div_opacity else opacity;
        try drawFlowChildren(allocator, writer, document, node_id, style, x, y, child_opacity);
        return;
    }

    if (std.ascii.eqlIgnoreCase(node.name, "h1")) {
        const text = try document.textContent(allocator, node_id);
        defer allocator.free(text);
        if (text.len == 0) return;
        if (y.* == style.body_y) y.* += @as(i32, @intCast(@divTrunc(style.h1_font_size, 2))) - 1;
        try writeFlowText(writer, x, y.*, style.h1_font_size, style.text_color, style.font_family, "700", null, opacity, text, @intCast(style.body_width));
        y.* += @as(i32, @intCast(style.h1_font_size)) + 10;
        return;
    }

    if (std.ascii.eqlIgnoreCase(node.name, "p")) {
        if (firstDirectElement(document, node_id, "a")) |anchor_id| {
            const text = try document.textContent(allocator, anchor_id);
            defer allocator.free(text);
            if (text.len == 0) return;
            try writeFlowText(writer, x, y.*, style.paragraph_font_size, style.link_color, style.font_family, "400", "underline", opacity, text, @intCast(style.body_width));
        } else {
            const text = try document.textContent(allocator, node_id);
            defer allocator.free(text);
            if (text.len == 0) return;
            try writeFlowText(writer, x, y.*, style.paragraph_font_size, style.text_color, style.font_family, "400", null, opacity, text, @intCast(style.body_width));
        }
        y.* += @as(i32, @intCast(style.paragraph_font_size)) + 18;
        return;
    }

    if (shouldPaintElement(node.name)) {
        const text = try paintTextForElement(allocator, document, node_id);
        defer allocator.free(text);
        if (text.len == 0) return;
        const color = if (std.ascii.eqlIgnoreCase(node.name, "a")) style.link_color else style.text_color;
        const decoration: ?[]const u8 = if (std.ascii.eqlIgnoreCase(node.name, "a")) "underline" else null;
        try writeFlowText(writer, x, y.*, style.paragraph_font_size, color, style.font_family, "400", decoration, opacity, text, @intCast(style.body_width));
        y.* += @as(i32, @intCast(style.paragraph_font_size)) + 18;
    }
}

fn firstDirectElement(document: *const dom.Document, node_id: dom.NodeId, name: []const u8) ?dom.NodeId {
    var child = document.getNode(node_id).first_child;
    while (child) |child_id| : (child = document.getNode(child_id).next_sibling) {
        const child_node = document.getNode(child_id);
        if (child_node.kind == .element and std.ascii.eqlIgnoreCase(child_node.name, name)) return child_id;
    }
    return null;
}

fn writeFlowText(
    writer: *std.Io.Writer,
    x: i32,
    y: i32,
    size: u32,
    color: []const u8,
    font_family: []const u8,
    weight: []const u8,
    decoration: ?[]const u8,
    opacity: []const u8,
    text: []const u8,
    width: usize,
) !void {
    _ = width;
    try writer.print("<text x=\"{d}\" y=\"{d}\" font-family=\"", .{ x, y });
    try writeEscapedXml(writer, font_family);
    try writer.print("\" font-size=\"{d}\" fill=\"{s}\" font-weight=\"{s}\" opacity=\"{s}\"", .{ size, color, weight, opacity });
    if (decoration) |value| try writer.print(" text-decoration=\"{s}\"", .{value});
    try writer.writeAll(">");
    try writeEscapedXml(writer, text);
    try writer.writeAll("</text>\n");
}

fn collectPaintBlocks(allocator: std.mem.Allocator, document: *const dom.Document, blocks: *std.ArrayList(Block)) !void {
    const body = (try document.querySelector(allocator, "body")) orelse document.root();
    try collectPaintBlocksRecursive(allocator, document, body, blocks);
}

fn collectPaintBlocksRecursive(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    node_id: dom.NodeId,
    blocks: *std.ArrayList(Block),
) !void {
    if (blocks.items.len >= max_blocks) return;
    const node = document.getNode(node_id);
    if (node.kind == .element and shouldPaintElement(node.name)) {
        const text = try paintTextForElement(allocator, document, node_id);
        defer allocator.free(text);
        if (text.len > 0) {
            try blocks.append(allocator, .{
                .kind = blockKind(node.name),
                .text = try truncateText(allocator, text, max_text_per_block),
            });
        }
        if (std.ascii.eqlIgnoreCase(node.name, "a") or
            std.ascii.eqlIgnoreCase(node.name, "button") or
            std.ascii.eqlIgnoreCase(node.name, "input") or
            std.ascii.eqlIgnoreCase(node.name, "img"))
        {
            return;
        }
    }

    var child = node.first_child;
    while (child) |child_id| : (child = document.getNode(child_id).next_sibling) {
        try collectPaintBlocksRecursive(allocator, document, child_id, blocks);
    }
}

fn shouldPaintElement(name: []const u8) bool {
    const tags = [_][]const u8{
        "h1",     "h2",    "h3",         "h4",  "p",    "li",  "a", "button", "input", "textarea",
        "select", "label", "blockquote", "pre", "code", "img",
    };
    for (tags) |tag| {
        if (std.ascii.eqlIgnoreCase(name, tag)) return true;
    }
    return false;
}

fn blockKind(name: []const u8) BlockKind {
    if (std.ascii.eqlIgnoreCase(name, "h1") or
        std.ascii.eqlIgnoreCase(name, "h2") or
        std.ascii.eqlIgnoreCase(name, "h3") or
        std.ascii.eqlIgnoreCase(name, "h4")) return .heading;
    if (std.ascii.eqlIgnoreCase(name, "a")) return .link;
    if (std.ascii.eqlIgnoreCase(name, "button") or
        std.ascii.eqlIgnoreCase(name, "input") or
        std.ascii.eqlIgnoreCase(name, "textarea") or
        std.ascii.eqlIgnoreCase(name, "select")) return .control;
    if (std.ascii.eqlIgnoreCase(name, "img")) return .image;
    if (std.ascii.eqlIgnoreCase(name, "pre") or std.ascii.eqlIgnoreCase(name, "code")) return .code;
    return .paragraph;
}

fn paintTextForElement(allocator: std.mem.Allocator, document: *const dom.Document, node_id: dom.NodeId) ![]const u8 {
    const node = document.getNode(node_id);
    if (std.ascii.eqlIgnoreCase(node.name, "input")) {
        if (document.getAttribute(node_id, "value")) |value| return dom.normalizeText(allocator, value);
        if (document.getAttribute(node_id, "placeholder")) |value| return dom.normalizeText(allocator, value);
        if (document.getAttribute(node_id, "type")) |value| return std.fmt.allocPrint(allocator, "input:{s}", .{value});
        return allocator.dupe(u8, "input");
    }
    if (std.ascii.eqlIgnoreCase(node.name, "img")) {
        if (document.getAttribute(node_id, "alt")) |alt| {
            if (alt.len > 0) return dom.normalizeText(allocator, alt);
        }
        if (document.getAttribute(node_id, "src")) |src| return std.fmt.allocPrint(allocator, "image: {s}", .{src});
        return allocator.dupe(u8, "image");
    }
    return document.textContent(allocator, node_id);
}

fn truncateText(allocator: std.mem.Allocator, text: []const u8, max_len: usize) ![]const u8 {
    if (text.len <= max_len) return allocator.dupe(u8, text);
    return std.fmt.allocPrint(allocator, "{s}...", .{text[0..max_len]});
}

fn drawBlock(writer: *std.Io.Writer, block: Block, y: i32, width: i32) !i32 {
    const x = 48;
    const content_width = @max(240, width - 96);
    return switch (block.kind) {
        .heading => drawTextBlock(writer, block.text, x, y, 24, "#26352c", 68, true, 32),
        .paragraph => drawTextBlock(writer, block.text, x, y, 17, "#33463a", 96, false, 26),
        .link => blk: {
            try writer.print("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"30\" rx=\"10\" fill=\"#e5eed6\" stroke=\"#9bb474\"/>\n", .{ x - 10, y - 20, @min(content_width, 900) });
            break :blk try drawTextBlock(writer, block.text, x, y, 16, "#1b5e38", 94, false, 34);
        },
        .control => blk: {
            try writer.print("<rect x=\"{d}\" y=\"{d}\" width=\"420\" height=\"38\" rx=\"8\" fill=\"#fffaf0\" stroke=\"#829078\"/>\n", .{ x - 10, y - 24 });
            break :blk try drawTextBlock(writer, block.text, x, y, 15, "#26352c", 46, false, 44);
        },
        .image => blk: {
            try writer.print("<rect x=\"{d}\" y=\"{d}\" width=\"260\" height=\"110\" rx=\"12\" fill=\"#d8e2c8\" stroke=\"#829078\"/>\n", .{ x - 10, y - 24 });
            try writer.print("<path d=\"M {d} {d} L {d} {d} L {d} {d}\" fill=\"none\" stroke=\"#829078\" stroke-width=\"3\"/>\n", .{ x + 18, y + 56, x + 88, y + 4, x + 200, y + 76 });
            _ = try drawTextBlock(writer, block.text, x, y + 92, 13, "#566255", 34, false, 0);
            break :blk y + 126;
        },
        .code => blk: {
            try writer.print("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"34\" rx=\"8\" fill=\"#223027\"/>\n", .{ x - 10, y - 22, @min(content_width, 900) });
            break :blk try drawTextBlock(writer, block.text, x, y, 14, "#e9f2df", 86, false, 40);
        },
    };
}

fn drawTextBlock(
    writer: *std.Io.Writer,
    text: []const u8,
    x: i32,
    y: i32,
    size: u32,
    color: []const u8,
    wrap_at: usize,
    bold: bool,
    min_advance: i32,
) !i32 {
    var line_start: usize = 0;
    var line_count: i32 = 0;
    while (line_start < text.len and line_count < 4) : (line_count += 1) {
        const remaining = text[line_start..];
        const take = wrappedLineLen(remaining, wrap_at);
        try writeSvgText(writer, x, y + line_count * line_height, size, color, remaining[0..take], wrap_at, bold);
        line_start += take;
        while (line_start < text.len and std.ascii.isWhitespace(text[line_start])) : (line_start += 1) {}
    }
    return y + @max(min_advance, (line_count + 1) * line_height);
}

fn wrappedLineLen(text: []const u8, wrap_at: usize) usize {
    if (text.len <= wrap_at) return text.len;
    var split = wrap_at;
    while (split > 16) : (split -= 1) {
        if (std.ascii.isWhitespace(text[split])) return split;
    }
    return wrap_at;
}

fn writeSvgText(
    writer: *std.Io.Writer,
    x: i32,
    y: i32,
    size: u32,
    color: []const u8,
    text: []const u8,
    max_chars: usize,
    bold: bool,
) !void {
    try writer.print("<text x=\"{d}\" y=\"{d}\" font-family=\"ui-sans-serif, system-ui, sans-serif\" font-size=\"{d}\" fill=\"{s}\"", .{ x, y, size, color });
    if (bold) try writer.writeAll(" font-weight=\"700\"");
    try writer.writeAll(">");
    try writeEscapedXml(writer, if (text.len > max_chars) text[0..max_chars] else text);
    try writer.writeAll("</text>\n");
}

fn writeEscapedXml(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&apos;"),
            else => try writer.writeByte(c),
        }
    }
}

fn outputPath(allocator: std.mem.Allocator, requested_path: ?[]const u8) ![]const u8 {
    if (requested_path) |path| return allocator.dupe(u8, path);
    return std.fmt.allocPrint(allocator, "kuri-browser-native-paint-{d}.svg", .{milliTimestamp()});
}

fn milliTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

test "paintPageSvg emits SVG without CDP fallback" {
    const allocator = std.testing.allocator;

    var document = try dom.Document.parse(
        allocator,
        "<html><head><title>Native Paint</title></head><body><h1>Hello</h1><p>World</p><a href=\"/x\">Go</a></body></html>",
    );
    defer document.deinit();
    const page: model.Page = .{
        .requested_url = "https://example.test/",
        .url = "https://example.test/",
        .html = document.html,
        .dom = document,
        .title = "Native Paint",
        .text = "Hello World Go",
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
    const svg = try paintPageSvg(allocator, page, .{});
    defer allocator.free(svg);
    try std.testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try std.testing.expect(std.mem.indexOf(u8, svg, "native SVG paint") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "kuri-cdp") == null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Hello") != null);
}
