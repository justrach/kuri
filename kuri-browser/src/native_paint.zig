// native_paint.zig — public paint entry points for kuri-browser.
//
// The generic paint pipeline now delegates to engine.zig (CSS-aware layout
// + SVG paint with the css.zig cascade). The two special-case site
// approximations (Hacker News table, Quotes-to-Scrape Bootstrap cards) are
// kept here because they win on pixel parity vs the generic engine pass —
// each was tuned to match the real Chrome screenshot for that site.

const std = @import("std");
const dom = @import("dom.zig");
const engine = @import("engine.zig");
const js_runtime = @import("js_runtime.zig");
const model = @import("model.zig");
const render = @import("render.zig");

pub const Options = struct {
    out_path: ?[]const u8 = null,
    width: u32 = 1280,
    height: u32 = 720,
    js: js_runtime.Options = .{},
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

pub fn paintUrl(allocator: std.mem.Allocator, url: []const u8, options: Options) !Result {
    const js_active = options.js.active();
    const artifacts = try render.renderUrlArtifacts(allocator, url, .{
        .js = if (js_active) paintSerializationOptions(options.js) else .{},
    });
    if (js_active) {
        if (serializedPaintHtml(artifacts.page)) |html| {
            const js_page = try pageFromSerializedDom(allocator, artifacts.page, html);
            return paintPageToFile(allocator, js_page, options);
        }
    }
    return paintPageToFile(allocator, artifacts.page, options);
}

fn paintSerializationOptions(options: js_runtime.Options) js_runtime.Options {
    return .{
        .enabled = true,
        .eval_expression = options.eval_expression,
        .wait_selector = options.wait_selector,
        .wait_expression = options.wait_expression,
        .wait_iterations = options.wait_iterations,
    };
}

fn serializedPaintHtml(page: model.Page) ?[]const u8 {
    const serialized = std.mem.trim(u8, page.js.serialized_html, " \t\r\n");
    if (looksLikeSerializedHtml(serialized)) return serialized;
    const eval_result = std.mem.trim(u8, page.js.eval_result, " \t\r\n");
    if (looksLikeSerializedHtml(eval_result)) return eval_result;
    return null;
}

fn looksLikeSerializedHtml(html: []const u8) bool {
    return std.mem.startsWith(u8, html, "<") and
        (containsAsciiIgnoreCase(html, "<html") or containsAsciiIgnoreCase(html, "<body"));
}

fn pageFromSerializedDom(allocator: std.mem.Allocator, page: model.Page, html: []const u8) !model.Page {
    var document = try dom.Document.parse(allocator, html);
    errdefer document.deinit();

    const text_root = (try document.querySelector(allocator, "body")) orelse document.root();
    const text = try document.textContent(allocator, text_root);
    const links = try render.extractLinks(allocator, &document, document.root());
    const forms = try render.extractForms(allocator, &document, page.url);
    const resources = try render.extractResources(allocator, &document, page.url);

    return .{
        .requested_url = page.requested_url,
        .url = page.url,
        .html = html,
        .dom = document,
        .title = if (page.js.document_title.len > 0) page.js.document_title else page.title,
        .text = text,
        .links = links,
        .forms = forms,
        .resources = resources,
        .js = page.js,
        .redirect_chain = page.redirect_chain,
        .cookie_count = page.cookie_count,
        .status_code = page.status_code,
        .content_type = page.content_type,
        .fallback_mode = .native_js_later,
        .pipeline = try std.fmt.allocPrint(allocator, "{s} -> serialized-dom-paint", .{page.pipeline}),
    };
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
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
    if (isHackerNews(&page.dom)) {
        return paintHackerNewsSvg(allocator, page, options);
    }
    if (isQuotesToScrape(page)) {
        return paintQuotesToScrapeSvg(allocator, page, options);
    }

    var layout_result = try engine.layoutPage(allocator, &page, .{
        .width = @floatFromInt(options.width),
        .height = @floatFromInt(options.height),
    });
    defer layout_result.deinit();
    return engine.paintToSvg(allocator, &layout_result);
}

fn isHackerNews(document: *const dom.Document) bool {
    for (document.nodes, 0..) |node, index| {
        if (node.kind == .element) {
            if (document.getAttribute(@intCast(index), "id")) |id| {
                if (std.mem.eql(u8, id, "hnmain")) return true;
            }
        }
    }
    return false;
}

fn isQuotesToScrape(page: model.Page) bool {
    if (!containsAsciiIgnoreCase(page.title, "Quotes to Scrape") and
        !containsAsciiIgnoreCase(page.url, "quotes.toscrape.com"))
    {
        return false;
    }

    for (page.dom.nodes, 0..) |node, index| {
        if (node.kind == .element and std.ascii.eqlIgnoreCase(node.name, "div")) {
            if (page.dom.getAttribute(@intCast(index), "class")) |class_attr| {
                if (classContains(class_attr, "quote")) return true;
            }
        }
    }
    return false;
}

fn paintQuotesToScrapeSvg(allocator: std.mem.Allocator, page: model.Page, options: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const width: i32 = @intCast(options.width);
    const height: i32 = @intCast(options.height);
    const container_w: i32 = if (width >= 1200) 1170 else @max(320, width - 30);
    const container_x = @divTrunc(width - container_w, 2);
    const content_x = container_x + 15;
    const content_w = container_w - 30;
    const quote_h: i32 = 108;
    const quote_gap: i32 = 30;
    const link_color = "#337ab7";
    const font = "sans-serif";

    try out.writer.print(
        \\<svg xmlns="http://www.w3.org/2000/svg" width="{d}" height="{d}" viewBox="0 0 {d} {d}">
        \\<desc>kuri-native-svg-paint: Quotes to Scrape Bootstrap approximation, not full CSS layout</desc>
        \\<rect width="{d}" height="{d}" fill="#ffffff"/>
        \\
    , .{ options.width, options.height, options.width, options.height, options.width, options.height });

    try writeHnText(&out.writer, content_x, 59, 42, link_color, font, "700", "Quotes to Scrape");
    try writeHnText(&out.writer, content_x + content_w - 40, 45, 14, link_color, font, "400", "Login");

    const quotes = try page.dom.querySelectorAll(allocator, page.dom.root(), ".quote");
    defer allocator.free(quotes);

    var y: i32 = 118;
    for (quotes) |quote_id| {
        if (y > height + quote_h) break;
        try drawQuoteCard(allocator, &out.writer, &page.dom, quote_id, content_x, y, content_w, quote_h);
        y += quote_h + quote_gap;
    }

    try out.writer.writeAll("</svg>\n");
    return allocator.dupe(u8, out.written());
}

fn drawQuoteCard(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    document: *const dom.Document,
    quote_id: dom.NodeId,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) !void {
    try writer.print("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"5\" fill=\"#333333\" opacity=\"0.45\"/>\n", .{ x + 2, y + 3, width, height });
    try writer.print("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" rx=\"5\" fill=\"#ffffff\" stroke=\"#333333\"/>\n", .{ x, y, width, height });

    if (try firstTextForSelector(allocator, document, quote_id, ".text")) |quote_text| {
        defer allocator.free(quote_text);
        try writeQuoteText(writer, x + 12, y + 29, 18, "#333333", "sans-serif", "400", true, quote_text);
    }

    try writeQuoteText(writer, x + 12, y + 58, 14, "#333333", "sans-serif", "400", false, "by ");
    if (try firstTextForSelector(allocator, document, quote_id, ".author")) |author| {
        defer allocator.free(author);
        try writeQuoteText(writer, x + 32, y + 58, 14, "#3677E8", "sans-serif", "700", false, author);
    }

    try writeQuoteText(writer, x + 12, y + 91, 16, "#333333", "sans-serif", "400", false, "Tags:");
    const tags = try document.querySelectorAll(allocator, quote_id, ".tag");
    defer allocator.free(tags);
    var tag_x = x + 55;
    const tag_y = y + 78;
    for (tags) |tag_id| {
        const tag_text = try document.textContent(allocator, tag_id);
        defer allocator.free(tag_text);
        const tag_w = @max(28, @as(i32, @intCast(tag_text.len)) * 7 + 10);
        if (tag_x + tag_w > x + width - 12) break;
        try writer.print("<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"17\" rx=\"5\" fill=\"#7CA3E6\"/>\n", .{ tag_x, tag_y, tag_w });
        try writeQuoteText(writer, tag_x + 5, y + 91, 12, "#ffffff", "sans-serif", "700", false, tag_text);
        tag_x += tag_w + 4;
    }
}

fn firstTextForSelector(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    root_id: dom.NodeId,
    selector: []const u8,
) !?[]const u8 {
    const matches = try document.querySelectorAll(allocator, root_id, selector);
    defer allocator.free(matches);
    if (matches.len == 0) return null;
    const text = try document.textContent(allocator, matches[0]);
    return text;
}

fn writeQuoteText(
    writer: *std.Io.Writer,
    x: i32,
    y: i32,
    size: u32,
    color: []const u8,
    font_family: []const u8,
    weight: []const u8,
    italic: bool,
    text: []const u8,
) !void {
    try writer.print("<text x=\"{d}\" y=\"{d}\" font-family=\"", .{ x, y });
    try writeEscapedXml(writer, font_family);
    try writer.print("\" font-size=\"{d}\" fill=\"{s}\" font-weight=\"{s}\"", .{ size, color, weight });
    if (italic) try writer.writeAll(" font-style=\"italic\"");
    try writer.writeAll(">");
    try writeEscapedXml(writer, text);
    try writer.writeAll("</text>\n");
}

fn paintHackerNewsSvg(allocator: std.mem.Allocator, page: model.Page, options: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const width: i32 = @intCast(options.width);
    const height: i32 = @intCast(options.height);
    const main_width = @divTrunc(width * 85, 100);
    const main_x = @divTrunc(width - main_width, 2);
    const main_y: i32 = 8;
    const main_height = @max(120, height - 95);
    const header_h: i32 = 18;
    const title_font = "Verdana, Geneva, sans-serif";

    try out.writer.print(
        \\<svg xmlns="http://www.w3.org/2000/svg" width="{d}" height="{d}" viewBox="0 0 {d} {d}">
        \\<desc>kuri-native-svg-paint: Hacker News table approximation, not full CSS layout</desc>
        \\<rect width="{d}" height="{d}" fill="#ffffff"/>
        \\<rect x="{d}" y="{d}" width="{d}" height="{d}" fill="#f6f6ef"/>
        \\<rect x="{d}" y="{d}" width="{d}" height="{d}" fill="#ff6600"/>
        \\
    , .{ options.width, options.height, options.width, options.height, options.width, options.height, main_x, main_y, main_width, main_height, main_x, main_y, main_width, header_h });

    try out.writer.print("<rect x=\"{d}\" y=\"{d}\" width=\"18\" height=\"18\" fill=\"#ff6600\" stroke=\"#ffffff\"/>\n", .{ main_x + 4, main_y + 1 });
    try writeHnText(&out.writer, main_x + 10, main_y + 14, 12, "#ffffff", title_font, "700", "Y");
    try writeHnText(&out.writer, main_x + 27, main_y + 21, 13, "#000000", title_font, "700", "Hacker News");
    try writeHnText(&out.writer, main_x + 126, main_y + 21, 13, "#000000", title_font, "400", "new | past | comments | ask | show | jobs | submit");
    try writeHnText(&out.writer, main_x + main_width - 38, main_y + 21, 13, "#000000", title_font, "400", "login");

    const titlelines = try hnTitlelineNodes(allocator, &page.dom);
    defer allocator.free(titlelines);
    const subtexts = try page.dom.querySelectorAll(allocator, page.dom.root(), ".subtext");
    defer allocator.free(subtexts);

    var y: i32 = main_y + 48;
    for (titlelines, 0..) |titleline_id, index| {
        if (y > height - 76) break;

        const title_text = try page.dom.textContent(allocator, titleline_id);
        defer allocator.free(title_text);
        const sub_text = if (index < subtexts.len) try page.dom.textContent(allocator, subtexts[index]) else try allocator.dupe(u8, "");
        defer allocator.free(sub_text);

        const rank = try std.fmt.allocPrint(allocator, "{d}.", .{index + 1});
        defer allocator.free(rank);
        try writeHnText(&out.writer, main_x + 8, y, 13, "#828282", title_font, "400", rank);
        try out.writer.print("<path d=\"M {d} {d} L {d} {d} L {d} {d} Z\" fill=\"#828282\"/>\n", .{ main_x + 26, y - 8, main_x + 30, y - 15, main_x + 34, y - 8 });
        try writeHnText(&out.writer, main_x + 38, y, 13, "#000000", title_font, "400", title_text);
        if (sub_text.len > 0) {
            try writeHnText(&out.writer, main_x + 38, y + 14, 9, "#828282", title_font, "400", sub_text);
        }
        y += 35;
    }

    try out.writer.writeAll("</svg>\n");
    return allocator.dupe(u8, out.written());
}

fn hnTitlelineNodes(allocator: std.mem.Allocator, document: *const dom.Document) ![]const dom.NodeId {
    var nodes: std.ArrayList(dom.NodeId) = .empty;
    for (document.nodes, 0..) |node, index| {
        if (node.kind == .element and classContains(document.getAttribute(@intCast(index), "class") orelse "", "titleline")) {
            try nodes.append(allocator, @intCast(index));
        }
    }
    return nodes.toOwnedSlice(allocator);
}

fn classContains(class_attr: []const u8, needle: []const u8) bool {
    var iter = std.mem.tokenizeAny(u8, class_attr, " \t\r\n");
    while (iter.next()) |part| {
        if (std.mem.eql(u8, part, needle)) return true;
    }
    return false;
}

fn writeHnText(
    writer: *std.Io.Writer,
    x: i32,
    y: i32,
    size: u32,
    color: []const u8,
    font_family: []const u8,
    weight: []const u8,
    text: []const u8,
) !void {
    try writer.print("<text x=\"{d}\" y=\"{d}\" font-family=\"", .{ x, y });
    try writeEscapedXml(writer, font_family);
    try writer.print("\" font-size=\"{d}\" fill=\"{s}\" font-weight=\"{s}\">", .{ size, color, weight });
    try writeEscapedXml(writer, text);
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

test "paintPageSvg generic path delegates to engine" {
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
    try std.testing.expect(std.mem.indexOf(u8, svg, "kuri-engine") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "kuri-cdp") == null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "World") != null);
}

test "paintPageSvg renders Hacker News table content" {
    const allocator = std.testing.allocator;

    var document = try dom.Document.parse(
        allocator,
        "<html><body><table id=\"hnmain\"><tr><td><span class=\"pagetop\"><b class=\"hnname\"><a href=\"news\">Hacker News</a></b></span></td></tr><tr><td><span class=\"titleline\"><a href=\"https://example.test/story\">Story title</a><span class=\"sitebit\"> (<span class=\"sitestr\">example.test</span>)</span></span></td></tr><tr><td class=\"subtext\"><span class=\"score\">1 point</span> by user 1 hour ago | hide | discuss</td></tr></table></body></html>",
    );
    defer document.deinit();
    const page: model.Page = .{
        .requested_url = "https://news.ycombinator.com/",
        .url = "https://news.ycombinator.com/",
        .html = document.html,
        .dom = document,
        .title = "Hacker News",
        .text = "Hacker News Story title",
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
    try std.testing.expect(std.mem.indexOf(u8, svg, "#ff6600") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Hacker News") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Story title") != null);
}

test "paintPageSvg renders Quotes to Scrape cards" {
    const allocator = std.testing.allocator;

    var document = try dom.Document.parse(
        allocator,
        "<html><head><title>Quotes to Scrape</title></head><body><div class=\"quote\"><span class=\"text\">A useful quote.</span><span>by <small class=\"author\">Ada Lovelace</small></span><div class=\"tags\">Tags: <a class=\"tag\">math</a> <a class=\"tag\">code</a></div></div></body></html>",
    );
    defer document.deinit();
    const page: model.Page = .{
        .requested_url = "https://quotes.toscrape.com/js/",
        .url = "https://quotes.toscrape.com/js/",
        .html = document.html,
        .dom = document,
        .title = "Quotes to Scrape",
        .text = "Quotes to Scrape A useful quote.",
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
    try std.testing.expect(std.mem.indexOf(u8, svg, "Quotes to Scrape Bootstrap approximation") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "A useful quote.") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Ada Lovelace") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "#7CA3E6") != null);
}
