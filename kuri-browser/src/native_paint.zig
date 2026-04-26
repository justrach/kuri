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
    var blocks: std.ArrayList(Block) = .empty;
    defer {
        for (blocks.items) |block| allocator.free(block.text);
        blocks.deinit(allocator);
    }
    try collectPaintBlocks(allocator, &page.dom, &blocks);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.print(
        \\<svg xmlns="http://www.w3.org/2000/svg" width="{d}" height="{d}" viewBox="0 0 {d} {d}">
        \\<rect width="100%" height="100%" fill="#f7f2e8"/>
        \\<rect x="0" y="0" width="{d}" height="56" fill="#1f2a24"/>
        \\<rect x="24" y="16" width="{d}" height="24" rx="12" fill="#eef4dc" opacity="0.96"/>
        \\
    , .{ options.width, options.height, options.width, options.height, options.width, options.width - 48 });

    try writeSvgText(&out.writer, 44, 33, 13, "#1f2a24", page.url, 120, false);
    try writeSvgText(&out.writer, 48, 92, 34, "#26352c", page.title, 72, true);

    var y: i32 = 132;
    for (blocks.items) |block| {
        if (y > @as(i32, @intCast(options.height)) - 32) break;
        y = try drawBlock(&out.writer, block, y, @intCast(options.width));
    }

    try out.writer.print(
        "<text x=\"48\" y=\"{d}\" font-family=\"ui-monospace, SFMono-Regular, Menlo, monospace\" font-size=\"12\" fill=\"#68746a\">native SVG paint: text/DOM approximation, not full CSS layout</text>\n",
        .{@max(@as(i32, 120), @as(i32, @intCast(options.height)) - 30)},
    );
    try out.writer.writeAll("</svg>\n");
    return allocator.dupe(u8, out.written());
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
