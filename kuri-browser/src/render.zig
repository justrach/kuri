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

pub fn extractForms(allocator: std.mem.Allocator, document: *const dom.Document, page_url: []const u8) ![]model.Form {
    const form_nodes = try document.querySelectorAll(allocator, document.root(), "form");
    if (form_nodes.len == 0) return allocator.dupe(model.Form, &.{});

    var forms: std.ArrayList(model.Form) = .empty;
    for (form_nodes) |form_id| {
        try forms.append(allocator, .{
            .method = try extractFormMethod(allocator, document, form_id),
            .action = try extractFormAction(allocator, document, form_id, page_url),
            .enctype = try allocator.dupe(u8, document.getAttribute(form_id, "enctype") orelse "application/x-www-form-urlencoded"),
            .id = try allocator.dupe(u8, document.getAttribute(form_id, "id") orelse ""),
            .class_name = try allocator.dupe(u8, document.getAttribute(form_id, "class") orelse ""),
            .fields = try extractFormFields(allocator, document, form_id),
        });
    }
    return try forms.toOwnedSlice(allocator);
}

fn pageFromFetchResult(allocator: std.mem.Allocator, result: fetch.FetchResult) !model.Page {
    const html = result.body;
    const document = try dom.Document.parse(allocator, html);
    const title = try extractTitle(allocator, &document);

    const text_root = (try document.querySelector(allocator, "body")) orelse document.root();
    const text = try document.textContent(allocator, text_root);
    const links = try extractLinks(allocator, &document, document.root());
    const forms = try extractForms(allocator, &document, result.url);

    return .{
        .requested_url = result.requested_url,
        .url = result.url,
        .html = html,
        .dom = document,
        .title = title,
        .text = text,
        .links = links,
        .forms = forms,
        .redirect_chain = result.redirect_chain,
        .cookie_count = result.cookie_count,
        .status_code = result.status_code,
        .content_type = result.content_type,
        .fallback_mode = .native_static,
        .pipeline = "fetch -> cookies -> redirects -> parsed-dom -> text/forms",
    };
}

fn extractTitle(allocator: std.mem.Allocator, document: *const dom.Document) ![]const u8 {
    const title_id = try document.querySelector(allocator, "title") orelse return allocator.dupe(u8, "(untitled)");
    const title = try document.textContent(allocator, title_id);
    if (title.len == 0) return allocator.dupe(u8, "(untitled)");
    return title;
}

fn extractFormMethod(allocator: std.mem.Allocator, document: *const dom.Document, form_id: dom.NodeId) ![]const u8 {
    return lowerDuped(allocator, document.getAttribute(form_id, "method") orelse "get");
}

fn extractFormAction(allocator: std.mem.Allocator, document: *const dom.Document, form_id: dom.NodeId, page_url: []const u8) ![]const u8 {
    const raw_action = document.getAttribute(form_id, "action") orelse "";
    if (raw_action.len == 0) return allocator.dupe(u8, page_url);
    return resolveUrl(allocator, page_url, raw_action);
}

fn extractFormFields(allocator: std.mem.Allocator, document: *const dom.Document, form_id: dom.NodeId) ![]model.FormField {
    var fields: std.ArrayList(model.FormField) = .empty;
    try collectFormFields(allocator, document, form_id, &fields);
    return try fields.toOwnedSlice(allocator);
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

fn collectFormFields(allocator: std.mem.Allocator, document: *const dom.Document, node_id: dom.NodeId, fields: *std.ArrayList(model.FormField)) !void {
    const node = document.getNode(node_id);
    if (node.kind == .element) {
        if (std.ascii.eqlIgnoreCase(node.name, "input") or
            std.ascii.eqlIgnoreCase(node.name, "textarea") or
            std.ascii.eqlIgnoreCase(node.name, "select"))
        {
            try fields.append(allocator, try formFieldFromNode(allocator, document, node_id));
        }
    }

    var child = node.first_child;
    while (child) |child_id| : (child = document.getNode(child_id).next_sibling) {
        try collectFormFields(allocator, document, child_id, fields);
    }
}

fn formFieldFromNode(allocator: std.mem.Allocator, document: *const dom.Document, node_id: dom.NodeId) !model.FormField {
    const node = document.getNode(node_id);
    const name = try allocator.dupe(u8, document.getAttribute(node_id, "name") orelse "");
    const kind = try fieldKind(allocator, document, node_id);

    if (std.ascii.eqlIgnoreCase(node.name, "input")) {
        if (document.getAttribute(node_id, "type")) |input_type| {
            if ((std.ascii.eqlIgnoreCase(input_type, "checkbox") or std.ascii.eqlIgnoreCase(input_type, "radio")) and
                document.getAttribute(node_id, "checked") == null)
            {
                return .{
                    .name = name,
                    .kind = kind,
                    .value = try allocator.dupe(u8, "(unchecked)"),
                };
            }
        }
    }

    return .{
        .name = name,
        .kind = kind,
        .value = try fieldValue(allocator, document, node_id),
    };
}

fn fieldKind(allocator: std.mem.Allocator, document: *const dom.Document, node_id: dom.NodeId) ![]const u8 {
    const node = document.getNode(node_id);
    if (std.ascii.eqlIgnoreCase(node.name, "input")) {
        return allocator.dupe(u8, document.getAttribute(node_id, "type") orelse "text");
    }
    return allocator.dupe(u8, node.name);
}

fn fieldValue(allocator: std.mem.Allocator, document: *const dom.Document, node_id: dom.NodeId) ![]const u8 {
    const node = document.getNode(node_id);
    if (std.ascii.eqlIgnoreCase(node.name, "textarea")) {
        return document.textContent(allocator, node_id);
    }

    if (std.ascii.eqlIgnoreCase(node.name, "select")) {
        if (try selectedOptionText(allocator, document, node_id)) |selected| {
            return selected;
        }
        return allocator.dupe(u8, "");
    }

    return allocator.dupe(u8, document.getAttribute(node_id, "value") orelse "");
}

fn selectedOptionText(allocator: std.mem.Allocator, document: *const dom.Document, select_id: dom.NodeId) !?[]const u8 {
    const select_node = document.getNode(select_id);
    var child = select_node.first_child;
    var fallback_option: ?dom.NodeId = null;
    while (child) |child_id| : (child = document.getNode(child_id).next_sibling) {
        const child_node = document.getNode(child_id);
        if (child_node.kind == .element and std.ascii.eqlIgnoreCase(child_node.name, "option")) {
            if (fallback_option == null) fallback_option = child_id;
            if (document.getAttribute(child_id, "selected") != null) {
                return try document.textContent(allocator, child_id);
            }
        }
    }

    if (fallback_option) |option_id| {
        return try document.textContent(allocator, option_id);
    }
    return null;
}

fn resolveUrl(allocator: std.mem.Allocator, base_url: []const u8, raw_url: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, raw_url, "http://") or std.mem.startsWith(u8, raw_url, "https://")) {
        return allocator.dupe(u8, raw_url);
    }

    const base_uri = try std.Uri.parse(base_url);
    var aux_buf: [8192]u8 = undefined;
    if (raw_url.len > aux_buf.len) return error.UrlTooLong;

    @memcpy(aux_buf[0..raw_url.len], raw_url);
    var remaining_aux: []u8 = aux_buf[0..];
    const resolved_uri = base_uri.resolveInPlace(raw_url.len, &remaining_aux) catch return error.InvalidUrl;
    return std.fmt.allocPrint(allocator, "{f}", .{resolved_uri});
}

fn lowerDuped(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, input.len);
    for (input, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
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

test "extractForms captures form metadata and fields" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const html =
        "<form action=\"/login\" method=\"post\">" ++
        "<input type=\"hidden\" name=\"csrf\" value=\"abc\">" ++
        "<input type=\"text\" name=\"username\">" ++
        "<textarea name=\"note\">hello</textarea>" ++
        "<select name=\"role\"><option>guest</option><option selected>admin</option></select>" ++
        "</form>";
    const document = try dom.Document.parse(arena, html);
    const forms = try extractForms(arena, &document, "https://example.com/start");
    try std.testing.expectEqual(@as(usize, 1), forms.len);
    try std.testing.expectEqualStrings("post", forms[0].method);
    try std.testing.expectEqualStrings("https://example.com/login", forms[0].action);
    try std.testing.expectEqual(@as(usize, 4), forms[0].fields.len);
    try std.testing.expectEqualStrings("csrf", forms[0].fields[0].name);
    try std.testing.expectEqualStrings("hidden", forms[0].fields[0].kind);
    try std.testing.expectEqualStrings("abc", forms[0].fields[0].value);
    try std.testing.expectEqualStrings("note", forms[0].fields[2].name);
    try std.testing.expectEqualStrings("hello", forms[0].fields[2].value);
    try std.testing.expectEqualStrings("admin", forms[0].fields[3].value);
}
