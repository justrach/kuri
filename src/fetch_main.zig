const std = @import("std");
const validator = @import("crawler/validator.zig");
const markdown = @import("crawler/markdown.zig");
const js_engine = @import("js_engine.zig");

pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var dump_mode: DumpMode = .markdown;
    var url: ?[]const u8 = null;
    var run_js = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dump") or std.mem.eql(u8, args[i], "-d")) {
            i += 1;
            if (i >= args.len) fatal("--dump requires a value: markdown|html|links|text");
            dump_mode = parseDumpMode(args[i]) orelse fatal("invalid --dump value: use markdown|html|links|text");
        } else if (std.mem.eql(u8, args[i], "--js") or std.mem.eql(u8, args[i], "-j")) {
            run_js = true;
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printUsage();
            return;
        } else if (args[i].len > 0 and args[i][0] != '-') {
            url = args[i];
        } else {
            fatal("unknown flag");
        }
    }

    const target_url = url orelse {
        printUsage();
        std.process.exit(1);
    };

    // SSRF defense via existing validator
    validator.validateUrl(target_url) catch |err| {
        std.debug.print("URL validation failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var html = fetchHttp(arena, target_url) catch |err| {
        std.debug.print("fetch failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // Optional: run inline <script> tags through QuickJS
    if (run_js) {
        if (js_engine.evalHtmlScripts(html, arena)) |maybe_output| {
            if (maybe_output) |js_output| {
                if (js_output.len > 0) {
                    const combined = std.fmt.allocPrint(arena, "{s}\n<!-- browdie-js-output -->\n{s}", .{ html, js_output }) catch html;
                    html = combined;
                }
            }
        } else |_| {}
    }

    const stdout = std.fs.File.stdout();

    switch (dump_mode) {
        .html => stdout.writeAll(html) catch return,
        .markdown => {
            const md = try markdown.htmlToMarkdown(html, arena);
            stdout.writeAll(md) catch return;
        },
        .links => {
            const links = try extractLinks(html, arena);
            for (links) |link| {
                stdout.writeAll(link) catch return;
                stdout.writeAll("\n") catch return;
            }
        },
        .text => {
            const text = try extractText(html, arena);
            stdout.writeAll(text) catch return;
        },
    }
}

const DumpMode = enum { markdown, html, links, text };

fn parseDumpMode(s: []const u8) ?DumpMode {
    if (std.mem.eql(u8, s, "markdown") or std.mem.eql(u8, s, "md")) return .markdown;
    if (std.mem.eql(u8, s, "html")) return .html;
    if (std.mem.eql(u8, s, "links")) return .links;
    if (std.mem.eql(u8, s, "text")) return .text;
    return null;
}

fn fatal(msg: []const u8) noreturn {
    std.debug.print("error: {s}\n", .{msg});
    std.process.exit(1);
}

fn printUsage() void {
    std.debug.print(
        \\browdie-fetch — standalone HTTP fetcher (no Chrome needed)
        \\
        \\Usage: browdie-fetch [--dump markdown|html|links|text] [--js] URL
        \\
        \\Options:
        \\  --dump, -d   Output format (default: markdown)
        \\               markdown  Convert HTML to Markdown
        \\               html      Raw HTML
        \\               links     Extract all <a href> links
        \\               text      Plain text (tags stripped)
        \\  --js, -j     Execute inline <script> tags via QuickJS
        \\  --help, -h   Show this help
        \\
    , .{});
}

/// Fetch a URL using std.http.Client and return the response body.
pub fn fetchHttp(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var req = try client.request(.GET, uri, .{
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = "browdie-fetch/0.1" },
            .{ .name = "Accept", .value = "text/html,application/xhtml+xml,*/*" },
            .{ .name = "Accept-Encoding", .value = "gzip, deflate" },
        },
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    if (response.head.status != .ok) {
        std.debug.print("HTTP {d}\n", .{@intFromEnum(response.head.status)});
        return error.HttpError;
    }

    var body: std.ArrayList(u8) = .empty;
    var transfer_buf: [8192]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);
    try reader.appendRemainingUnlimited(allocator, &body);

    return body.items;
}

/// Extract all href values from <a> tags in HTML.
pub fn extractLinks(html: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    var links: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;

    while (i < html.len) {
        // Find next <a
        const tag_start = std.mem.indexOfPos(u8, html, i, "<a ") orelse
            std.mem.indexOfPos(u8, html, i, "<a\t") orelse
            std.mem.indexOfPos(u8, html, i, "<A ") orelse
            std.mem.indexOfPos(u8, html, i, "<A\t") orelse break;

        const tag_end = std.mem.indexOfScalarPos(u8, html, tag_start, '>') orelse break;
        const tag = html[tag_start..tag_end];

        if (findAttrValue(tag, "href")) |href| {
            if (href.len > 0) {
                try links.append(allocator, href);
            }
        }
        i = tag_end + 1;
    }

    return links.toOwnedSlice(allocator);
}

/// Find an attribute value in a tag string, handling both single and double quotes.
fn findAttrValue(tag: []const u8, attr: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < tag.len) {
        const attr_pos = std.mem.indexOfPos(u8, tag, pos, attr) orelse return null;
        const eq_pos = attr_pos + attr.len;
        if (eq_pos >= tag.len) return null;

        // Skip whitespace around =
        var j = eq_pos;
        while (j < tag.len and tag[j] == ' ') : (j += 1) {}
        if (j >= tag.len or tag[j] != '=') {
            pos = attr_pos + 1;
            continue;
        }
        j += 1;
        while (j < tag.len and tag[j] == ' ') : (j += 1) {}
        if (j >= tag.len) return null;

        const quote = tag[j];
        if (quote == '"' or quote == '\'') {
            const start = j + 1;
            const end = std.mem.indexOfScalarPos(u8, tag, start, quote) orelse return null;
            return tag[start..end];
        } else {
            // Unquoted value — runs until space or >
            const start = j;
            var end = start;
            while (end < tag.len and tag[end] != ' ' and tag[end] != '>' and tag[end] != '\t') : (end += 1) {}
            return tag[start..end];
        }
    }
    return null;
}

/// Extract plain text from HTML — strips all tags and decodes entities.
pub fn extractText(html: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const writer = buf.writer(allocator);

    var i: usize = 0;
    var in_script = false;
    var in_style = false;

    while (i < html.len) {
        if (html[i] == '<') {
            const tag_end = std.mem.indexOfScalarPos(u8, html, i + 1, '>') orelse {
                i += 1;
                continue;
            };
            const tag_content = html[i + 1 .. tag_end];
            const is_close = tag_content.len > 0 and tag_content[0] == '/';
            const raw_name = if (is_close) tag_content[1..] else tag_content;

            // Extract just the tag name (before space//)
            var name_end: usize = 0;
            while (name_end < raw_name.len and raw_name[name_end] != ' ' and raw_name[name_end] != '/' and raw_name[name_end] != '>') : (name_end += 1) {}
            const tag_name = raw_name[0..name_end];

            // Check script/style boundaries
            if (eqlIgnoreCase(tag_name, "script")) {
                in_script = !is_close;
            } else if (eqlIgnoreCase(tag_name, "style")) {
                in_style = !is_close;
            }

            // Add whitespace for block elements
            if (is_close and isBlockElement(tag_name)) {
                try writer.writeByte('\n');
            }

            i = tag_end + 1;
        } else if (in_script or in_style) {
            i += 1;
        } else if (html[i] == '&') {
            if (std.mem.startsWith(u8, html[i..], "&amp;")) {
                try writer.writeByte('&');
                i += 5;
            } else if (std.mem.startsWith(u8, html[i..], "&lt;")) {
                try writer.writeByte('<');
                i += 4;
            } else if (std.mem.startsWith(u8, html[i..], "&gt;")) {
                try writer.writeByte('>');
                i += 4;
            } else if (std.mem.startsWith(u8, html[i..], "&quot;")) {
                try writer.writeByte('"');
                i += 6;
            } else if (std.mem.startsWith(u8, html[i..], "&nbsp;")) {
                try writer.writeByte(' ');
                i += 6;
            } else if (std.mem.startsWith(u8, html[i..], "&#39;") or std.mem.startsWith(u8, html[i..], "&#x27;")) {
                try writer.writeByte('\'');
                i += if (std.mem.startsWith(u8, html[i..], "&#39;")) @as(usize, 5) else 6;
            } else {
                try writer.writeByte(html[i]);
                i += 1;
            }
        } else {
            try writer.writeByte(html[i]);
            i += 1;
        }
    }

    return buf.toOwnedSlice(allocator);
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

fn isBlockElement(tag: []const u8) bool {
    const blocks = [_][]const u8{ "p", "div", "br", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "blockquote", "pre", "hr", "section", "article", "header", "footer", "nav", "main" };
    for (blocks) |b| {
        if (eqlIgnoreCase(tag, b)) return true;
    }
    return false;
}

// --- Tests ---

test "parseDumpMode" {
    try std.testing.expectEqual(DumpMode.markdown, parseDumpMode("markdown").?);
    try std.testing.expectEqual(DumpMode.markdown, parseDumpMode("md").?);
    try std.testing.expectEqual(DumpMode.html, parseDumpMode("html").?);
    try std.testing.expectEqual(DumpMode.links, parseDumpMode("links").?);
    try std.testing.expectEqual(DumpMode.text, parseDumpMode("text").?);
    try std.testing.expect(parseDumpMode("invalid") == null);
}

test "extractLinks finds href attributes" {
    const html = "<html><a href=\"https://example.com\">Ex</a> text <a href='https://other.com'>Ot</a></html>";
    const links = try extractLinks(html, std.testing.allocator);
    defer std.testing.allocator.free(links);
    try std.testing.expectEqual(@as(usize, 2), links.len);
    try std.testing.expectEqualStrings("https://example.com", links[0]);
    try std.testing.expectEqualStrings("https://other.com", links[1]);
}

test "extractLinks with no links" {
    const links = try extractLinks("<p>no links here</p>", std.testing.allocator);
    defer std.testing.allocator.free(links);
    try std.testing.expectEqual(@as(usize, 0), links.len);
}

test "extractLinks skips empty href" {
    const html = "<a href=\"\">empty</a><a href=\"https://ok.com\">ok</a>";
    const links = try extractLinks(html, std.testing.allocator);
    defer std.testing.allocator.free(links);
    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expectEqualStrings("https://ok.com", links[0]);
}

test "extractText strips tags" {
    const html = "<h1>Title</h1><p>Hello <b>world</b></p>";
    const text = try extractText(html, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<") == null);
}

test "extractText strips script and style" {
    const html = "before<script>alert(1)</script>middle<style>.x{color:red}</style>after";
    const text = try extractText(html, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "alert") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "color") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "after") != null);
}

test "extractText decodes entities" {
    const html = "Tom &amp; Jerry &lt;3";
    const text = try extractText(html, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Tom & Jerry <3", text);
}

test "findAttrValue double quotes" {
    try std.testing.expectEqualStrings("https://x.com", findAttrValue("a href=\"https://x.com\" class=\"y\"", "href").?);
}

test "findAttrValue single quotes" {
    try std.testing.expectEqualStrings("https://x.com", findAttrValue("a href='https://x.com'", "href").?);
}

test "findAttrValue not found" {
    try std.testing.expect(findAttrValue("a class=\"x\"", "href") == null);
}

test {
    _ = @import("crawler/validator.zig");
    _ = @import("crawler/markdown.zig");
    _ = @import("js_engine.zig");
}
