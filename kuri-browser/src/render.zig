const std = @import("std");
const dom = @import("dom.zig");
const fetch = @import("fetch.zig");
const model = @import("model.zig");

pub fn renderUrl(allocator: std.mem.Allocator, url: []const u8) !model.Page {
    const result = try fetch.fetchHtml(allocator, url, "kuri-browser/0.0.0");
    return pageFromFetchResult(allocator, result);
}

pub fn extractLinks(allocator: std.mem.Allocator, document: *const dom.Document, root_id: dom.NodeId) ![]model.Link {
    var links: std.ArrayList(model.Link) = .empty;
    try collectLinks(allocator, document, root_id, &links);
    return try links.toOwnedSlice(allocator);
}

fn pageFromFetchResult(allocator: std.mem.Allocator, result: fetch.FetchResult) !model.Page {
    const html = result.body;
    const document = try dom.Document.parse(allocator, html);
    const title = try extractTitle(allocator, &document);

    const text_root = (try document.querySelector(allocator, "body")) orelse document.root();
    const text = try document.textContent(allocator, text_root);
    const links = try extractLinks(allocator, &document, document.root());

    return .{
        .url = result.url,
        .html = html,
        .dom = document,
        .title = title,
        .text = text,
        .links = links,
        .status_code = result.status_code,
        .content_type = result.content_type,
        .fallback_mode = .native_static,
        .pipeline = "fetch -> parsed-dom -> text",
    };
}

fn extractTitle(allocator: std.mem.Allocator, document: *const dom.Document) ![]const u8 {
    const title_id = try document.querySelector(allocator, "title") orelse return allocator.dupe(u8, "(untitled)");
    const title = try document.textContent(allocator, title_id);
    if (title.len == 0) return allocator.dupe(u8, "(untitled)");
    return title;
}

fn collectLinks(allocator: std.mem.Allocator, document: *const dom.Document, node_id: dom.NodeId, links: *std.ArrayList(model.Link)) !void {
    const node = document.getNode(node_id);
    if (node.kind == .element and std.ascii.eqlIgnoreCase(node.name, "a")) {
        if (document.getAttribute(node_id, "href")) |href| {
            const clean_href = try dom.normalizeText(allocator, href);
            if (clean_href.len > 0) {
                const clean_text = try document.textContent(allocator, node_id);
                try links.append(allocator, .{
                    .text = clean_text,
                    .href = clean_href,
                });
            }
        }
    }

    var child = node.first_child;
    while (child) |child_id| : (child = document.getNode(child_id).next_sibling) {
        try collectLinks(allocator, document, child_id, links);
    }
}

test "extractTitle finds title text" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const document = try dom.Document.parse(arena, "<html><head><title>Hello World</title></head></html>");
    const title = try extractTitle(arena, &document);
    try std.testing.expectEqualStrings("Hello World", title);
}

test "extractLinks captures href and text" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const document = try dom.Document.parse(arena, "<a href=\"https://example.com\">Example</a>");
    const links = try extractLinks(arena, &document, document.root());
    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expectEqualStrings("Example", links[0].text);
    try std.testing.expectEqualStrings("https://example.com", links[0].href);
}

test "extractLinks strips nested tags and decodes numeric entities" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const document = try dom.Document.parse(arena, "<a href=\"/item?id=1\"><span>main &#x2F; child</span></a>");
    const links = try extractLinks(arena, &document, document.root());
    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expectEqualStrings("main / child", links[0].text);
    try std.testing.expectEqualStrings("/item?id=1", links[0].href);
}
