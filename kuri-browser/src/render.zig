const std = @import("std");
const fetch = @import("fetch.zig");
const model = @import("model.zig");

pub fn renderUrl(allocator: std.mem.Allocator, url: []const u8) !model.Page {
    const result = try fetch.fetchHtml(allocator, url, "kuri-browser/0.0.0");
    return pageFromFetchResult(allocator, result);
}

fn pageFromFetchResult(allocator: std.mem.Allocator, result: fetch.FetchResult) !model.Page {
    const html = result.body;
    const title = try extractTitle(allocator, html);
    const text = try extractReadableText(allocator, html);
    const links = try extractLinks(allocator, html);
    return .{
        .url = result.url,
        .title = title,
        .text = text,
        .links = links,
        .status_code = result.status_code,
        .content_type = result.content_type,
        .fallback_mode = .native_static,
        .pipeline = "fetch -> static-html -> text",
    };
}

fn extractTitle(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    const open_idx = std.mem.indexOf(u8, html, "<title") orelse return allocator.dupe(u8, "(untitled)");
    const open_end = std.mem.indexOfScalarPos(u8, html, open_idx, '>') orelse return allocator.dupe(u8, "(untitled)");
    const close_idx = std.mem.indexOfPos(u8, html, open_end + 1, "</title>") orelse return allocator.dupe(u8, "(untitled)");
    const raw = html[open_end + 1 .. close_idx];
    const decoded = try decodeEntities(allocator, raw);
    return trimAndCollapseWhitespace(allocator, decoded);
}

fn extractReadableText(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_script = false;
    var in_style = false;

    while (i < html.len) {
        if (html[i] == '<') {
            const tag_end = std.mem.indexOfScalarPos(u8, html, i + 1, '>') orelse break;
            const tag_full = html[i + 1 .. tag_end];
            const is_close = tag_full.len > 0 and tag_full[0] == '/';
            const tag_name = extractTagName(if (is_close) tag_full[1..] else tag_full);

            if (std.ascii.eqlIgnoreCase(tag_name, "script")) {
                in_script = !is_close;
            } else if (std.ascii.eqlIgnoreCase(tag_name, "style")) {
                in_style = !is_close;
            } else if (!in_script and !in_style and isBlockTag(tag_name)) {
                try appendNewlineIfNeeded(allocator, &out);
            }

            i = tag_end + 1;
            continue;
        }

        if (!in_script and !in_style) {
            try out.append(allocator, html[i]);
        }
        i += 1;
    }

    const decoded = try decodeEntities(allocator, out.items);
    return trimAndCollapseWhitespace(allocator, decoded);
}

fn extractLinks(allocator: std.mem.Allocator, html: []const u8) ![]model.Link {
    var links: std.ArrayList(model.Link) = .empty;
    var i: usize = 0;

    while (i < html.len) {
        const open_idx = std.mem.indexOfPos(u8, html, i, "<a") orelse break;
        const open_end = std.mem.indexOfScalarPos(u8, html, open_idx, '>') orelse break;
        const tag = html[open_idx + 1 .. open_end];
        const href = extractAttr(tag, "href") orelse {
            i = open_end + 1;
            continue;
        };
        const close_idx = std.mem.indexOfPos(u8, html, open_end + 1, "</a>") orelse {
            i = open_end + 1;
            continue;
        };

        const raw_text = html[open_end + 1 .. close_idx];
        const decoded_href = try decodeEntities(allocator, href);
        const text_fragment = try stripTags(allocator, raw_text);
        const decoded_text = try decodeEntities(allocator, text_fragment);
        const clean_text = try trimAndCollapseWhitespace(allocator, decoded_text);
        const clean_href = try trimAndCollapseWhitespace(allocator, decoded_href);

        if (clean_href.len > 0) {
            try links.append(allocator, .{
                .text = clean_text,
                .href = clean_href,
            });
        }

        i = close_idx + 4;
    }

    return try links.toOwnedSlice(allocator);
}

fn decodeEntities(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '&') {
            if (std.mem.startsWith(u8, input[i..], "&amp;")) {
                try out.append(allocator, '&');
                i += 5;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&lt;")) {
                try out.append(allocator, '<');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&gt;")) {
                try out.append(allocator, '>');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&quot;")) {
                try out.append(allocator, '"');
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&nbsp;")) {
                try out.append(allocator, ' ');
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&#")) {
                if (try appendNumericEntity(allocator, &out, input[i..])) |consumed| {
                    i += consumed;
                    continue;
                }
            }
        }

        try out.append(allocator, input[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn appendNumericEntity(allocator: std.mem.Allocator, out: *std.ArrayList(u8), input: []const u8) !?usize {
    const semi = std.mem.indexOfScalar(u8, input, ';') orelse return null;
    if (semi < 4) return null;

    const body = input[2..semi];
    const is_hex = body.len > 1 and (body[0] == 'x' or body[0] == 'X');
    const digits = if (is_hex) body[1..] else body;
    if (digits.len == 0) return null;

    const base: u8 = if (is_hex) 16 else 10;
    const value = std.fmt.parseInt(u21, digits, base) catch return null;

    var buf: [4]u8 = undefined;
    const encoded = try std.unicode.utf8Encode(value, &buf);
    try out.appendSlice(allocator, buf[0..encoded]);
    return semi + 1;
}

fn trimAndCollapseWhitespace(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var previous_was_space = false;
    var previous_was_newline = false;

    for (input) |c| {
        if (c == '\n' or c == '\r') {
            if (!previous_was_newline and out.items.len > 0) {
                try out.append(allocator, '\n');
            }
            previous_was_space = false;
            previous_was_newline = true;
            continue;
        }

        if (std.ascii.isWhitespace(c)) {
            if (!previous_was_space and !previous_was_newline and out.items.len > 0) {
                try out.append(allocator, ' ');
            }
            previous_was_space = true;
            continue;
        }

        try out.append(allocator, c);
        previous_was_space = false;
        previous_was_newline = false;
    }

    return std.mem.trim(u8, out.items, " \n\t\r");
}

fn extractTagName(tag: []const u8) []const u8 {
    var end: usize = 0;
    while (end < tag.len and !std.ascii.isWhitespace(tag[end]) and tag[end] != '/' and tag[end] != '>') : (end += 1) {}
    return tag[0..end];
}

fn extractAttr(tag: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < tag.len) {
        const match_idx = std.mem.indexOfPos(u8, tag, pos, name) orelse return null;
        const eq_idx = match_idx + name.len;
        if (eq_idx >= tag.len or tag[eq_idx] != '=') {
            pos = match_idx + 1;
            continue;
        }

        if (eq_idx + 1 >= tag.len) return null;
        const quote = tag[eq_idx + 1];
        if (quote != '"' and quote != '\'') {
            pos = match_idx + 1;
            continue;
        }

        const value_start = eq_idx + 2;
        const value_end = std.mem.indexOfScalarPos(u8, tag, value_start, quote) orelse return null;
        return tag[value_start..value_end];
    }
    return null;
}

fn isBlockTag(tag_name: []const u8) bool {
    const tags = [_][]const u8{
        "p", "div", "section", "article", "header", "footer", "main",
        "aside", "nav", "ul", "ol", "li", "br", "tr", "table",
        "h1", "h2", "h3", "h4", "h5", "h6",
    };
    for (tags) |tag| {
        if (std.ascii.eqlIgnoreCase(tag_name, tag)) return true;
    }
    return false;
}

fn appendNewlineIfNeeded(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    if (out.items.len == 0) return;
    if (out.items[out.items.len - 1] != '\n') {
        try out.append(allocator, '\n');
    }
}

fn stripTags(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '<') {
            const close_idx = std.mem.indexOfScalarPos(u8, input, i + 1, '>') orelse break;
            i = close_idx + 1;
            continue;
        }
        try out.append(allocator, input[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

test "extractTitle finds title text" {
    const title = try extractTitle(std.testing.allocator, "<html><head><title>Hello World</title></head></html>");
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("Hello World", title);
}

test "extractLinks captures href and text" {
    const links = try extractLinks(std.testing.allocator, "<a href=\"https://example.com\">Example</a>");
    defer std.testing.allocator.free(links);
    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expectEqualStrings("Example", links[0].text);
    try std.testing.expectEqualStrings("https://example.com", links[0].href);
}

test "extractLinks strips nested tags and decodes numeric entities" {
    const links = try extractLinks(std.testing.allocator, "<a href=\"/item?id=1\"><span>main &#x2F; child</span></a>");
    defer std.testing.allocator.free(links);
    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expectEqualStrings("main / child", links[0].text);
    try std.testing.expectEqualStrings("/item?id=1", links[0].href);
}
