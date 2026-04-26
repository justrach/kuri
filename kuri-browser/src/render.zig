const std = @import("std");
const dom = @import("dom.zig");
const fetch = @import("fetch.zig");
const js_runtime = @import("js_runtime.zig");
const model = @import("model.zig");

const default_pipeline = "fetch -> cookies -> redirects -> parsed-dom -> subresources -> text/forms";
const submit_pipeline = "fetch -> cookies -> redirects -> submit -> parsed-dom -> subresources -> text/forms";
const max_loaded_resources = 24;

pub const PageArtifacts = struct {
    page: model.Page,
    har_json: ?[]const u8 = null,
};

pub const RenderOptions = struct {
    capture_har: bool = false,
    js: js_runtime.Options = .{},
};

pub const Submission = struct {
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
};

pub fn renderUrl(allocator: std.mem.Allocator, url: []const u8) !model.Page {
    return (try renderUrlArtifacts(allocator, url, .{})).page;
}

pub fn renderUrlArtifacts(allocator: std.mem.Allocator, url: []const u8, options: RenderOptions) !PageArtifacts {
    var session = fetch.Session.init(allocator, "kuri-browser/0.0.0");
    defer session.deinit();
    const result = try session.navigate(url);
    return .{
        .page = try pageFromFetchResultWithPipeline(allocator, &session, result, default_pipeline, options.js),
        .har_json = if (options.capture_har) try session.harJson() else null,
    };
}

pub fn submitFormUrl(
    allocator: std.mem.Allocator,
    url: []const u8,
    form_index: usize,
    overrides: []const model.FieldInput,
) !model.Page {
    return (try submitFormArtifacts(allocator, url, form_index, overrides, .{})).page;
}

pub fn submitFormArtifacts(
    allocator: std.mem.Allocator,
    url: []const u8,
    form_index: usize,
    overrides: []const model.FieldInput,
    options: RenderOptions,
) !PageArtifacts {
    var session = fetch.Session.init(allocator, "kuri-browser/0.0.0");
    defer session.deinit();
    return .{
        .page = try submitFormWithSession(allocator, &session, url, form_index, overrides, options.js),
        .har_json = if (options.capture_har) try session.harJson() else null,
    };
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

pub fn extractForm(allocator: std.mem.Allocator, document: *const dom.Document, form_id: dom.NodeId, page_url: []const u8) !model.Form {
    return .{
        .method = try extractFormMethod(allocator, document, form_id),
        .action = try extractFormAction(allocator, document, form_id, page_url),
        .enctype = try allocator.dupe(u8, document.getAttribute(form_id, "enctype") orelse "application/x-www-form-urlencoded"),
        .id = try allocator.dupe(u8, document.getAttribute(form_id, "id") orelse ""),
        .class_name = try allocator.dupe(u8, document.getAttribute(form_id, "class") orelse ""),
        .fields = try extractFormFields(allocator, document, form_id),
    };
}

pub fn extractResources(allocator: std.mem.Allocator, document: *const dom.Document, page_url: []const u8) ![]model.Resource {
    var resources: std.ArrayList(model.Resource) = .empty;
    try collectResources(allocator, document, document.root(), page_url, &resources);
    return try resources.toOwnedSlice(allocator);
}

pub fn pageFromFetchResult(
    allocator: std.mem.Allocator,
    session: *fetch.Session,
    result: fetch.FetchResult,
    pipeline: []const u8,
    js_options: js_runtime.Options,
) !model.Page {
    return pageFromFetchResultWithPipeline(allocator, session, result, pipeline, js_options);
}

fn pageFromFetchResultWithPipeline(
    allocator: std.mem.Allocator,
    session: *fetch.Session,
    result: fetch.FetchResult,
    pipeline: []const u8,
    js_options: js_runtime.Options,
) !model.Page {
    const html = result.body;
    const document = try dom.Document.parse(allocator, html);
    var title = try extractTitle(allocator, &document);

    const text_root = (try document.querySelector(allocator, "body")) orelse document.root();
    const text = try document.textContent(allocator, text_root);
    const links = try extractLinks(allocator, &document, document.root());
    const forms = try extractForms(allocator, &document, result.url);
    const resources = try extractResources(allocator, &document, result.url);
    try loadResources(allocator, session, resources, result.url);
    const js = try js_runtime.evaluatePage(allocator, session, &document, html, result.url, resources, js_options);

    if (js.document_title.len > 0 and !std.mem.eql(u8, js.document_title, title)) {
        title = js.document_title;
    }

    return .{
        .requested_url = result.requested_url,
        .url = result.url,
        .html = html,
        .dom = document,
        .title = title,
        .text = text,
        .links = links,
        .forms = forms,
        .resources = resources,
        .js = js,
        .redirect_chain = result.redirect_chain,
        .cookie_count = result.cookie_count,
        .status_code = result.status_code,
        .content_type = result.content_type,
        .fallback_mode = .native_static,
        .pipeline = if (js_options.active()) try std.fmt.allocPrint(allocator, "{s} -> quickjs", .{pipeline}) else pipeline,
    };
}

fn submitFormWithSession(
    allocator: std.mem.Allocator,
    session: *fetch.Session,
    url: []const u8,
    form_index: usize,
    overrides: []const model.FieldInput,
    js_options: js_runtime.Options,
) !model.Page {
    const initial_result = try session.navigate(url);
    const initial_page = try pageFromFetchResultWithPipeline(allocator, session, initial_result, default_pipeline, .{});

    if (form_index == 0 or form_index > initial_page.forms.len) return error.FormNotFound;
    const form = initial_page.forms[form_index - 1];
    const submission = try buildFormSubmission(allocator, form, overrides);

    const submit_result = try session.request(submission.url, .{
        .method = submission.method,
        .body = submission.body,
        .content_type = submission.content_type,
        .referer = initial_page.url,
    });
    return pageFromFetchResultWithPipeline(allocator, session, submit_result, submit_pipeline, js_options);
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

pub fn buildFormSubmission(allocator: std.mem.Allocator, form: model.Form, overrides: []const model.FieldInput) !Submission {
    const method = try parseFormMethod(form.method);
    if (method == .POST and !std.ascii.eqlIgnoreCase(form.enctype, "application/x-www-form-urlencoded")) {
        return error.UnsupportedFormEncoding;
    }

    var pairs: std.ArrayList(model.FieldInput) = .empty;
    for (form.fields) |field| {
        if (shouldSkipField(field)) continue;
        const value = if (findOverride(overrides, field.name)) |override| override.value else field.value;
        try pairs.append(allocator, .{
            .name = field.name,
            .value = value,
        });
    }
    for (overrides) |override| {
        if (!formHasField(form, override.name)) {
            try pairs.append(allocator, override);
        }
    }

    const encoded = try encodeFormFields(allocator, pairs.items);
    switch (method) {
        .GET => {
            const submitted_url = try appendQueryString(allocator, form.action, encoded);
            return .{
                .method = .GET,
                .url = submitted_url,
            };
        },
        .POST => return .{
            .method = .POST,
            .url = try allocator.dupe(u8, form.action),
            .body = encoded,
            .content_type = "application/x-www-form-urlencoded",
        },
        else => return error.UnsupportedFormMethod,
    }
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

fn collectResources(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    node_id: dom.NodeId,
    page_url: []const u8,
    resources: *std.ArrayList(model.Resource),
) !void {
    const node = document.getNode(node_id);
    if (node.kind == .element) {
        try maybeAppendResource(allocator, document, node_id, page_url, resources);
    }

    var child = node.first_child;
    while (child) |child_id| : (child = document.getNode(child_id).next_sibling) {
        try collectResources(allocator, document, child_id, page_url, resources);
    }
}

fn maybeAppendResource(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    node_id: dom.NodeId,
    page_url: []const u8,
    resources: *std.ArrayList(model.Resource),
) !void {
    const node = document.getNode(node_id);
    if (std.ascii.eqlIgnoreCase(node.name, "script")) {
        if (document.getAttribute(node_id, "src")) |raw_url| {
            try appendResource(allocator, resources, "script", page_url, raw_url);
        }
        return;
    }

    if (std.ascii.eqlIgnoreCase(node.name, "img")) {
        if (document.getAttribute(node_id, "src")) |raw_url| {
            try appendResource(allocator, resources, "image", page_url, raw_url);
            return;
        }
        if (document.getAttribute(node_id, "srcset")) |raw_srcset| {
            if (firstSrcsetUrl(raw_srcset)) |raw_url| {
                try appendResource(allocator, resources, "image", page_url, raw_url);
            }
        }
        return;
    }

    if (std.ascii.eqlIgnoreCase(node.name, "source")) {
        if (document.getAttribute(node_id, "src")) |raw_url| {
            try appendResource(allocator, resources, "source", page_url, raw_url);
            return;
        }
        if (document.getAttribute(node_id, "srcset")) |raw_srcset| {
            if (firstSrcsetUrl(raw_srcset)) |raw_url| {
                try appendResource(allocator, resources, "source", page_url, raw_url);
            }
        }
        return;
    }

    if (std.ascii.eqlIgnoreCase(node.name, "iframe")) {
        if (document.getAttribute(node_id, "src")) |raw_url| {
            try appendResource(allocator, resources, "frame", page_url, raw_url);
        }
        return;
    }

    if (std.ascii.eqlIgnoreCase(node.name, "link")) {
        const rel = document.getAttribute(node_id, "rel") orelse "";
        const kind = classifyLinkResource(rel) orelse return;
        if (document.getAttribute(node_id, "href")) |raw_url| {
            try appendResource(allocator, resources, kind, page_url, raw_url);
        }
    }
}

fn appendResource(
    allocator: std.mem.Allocator,
    resources: *std.ArrayList(model.Resource),
    kind: []const u8,
    page_url: []const u8,
    raw_url: []const u8,
) !void {
    const normalized = std.mem.trim(u8, raw_url, " \t\r\n");
    if (normalized.len == 0 or shouldIgnoreResourceUrl(normalized)) return;

    const resolved_url = try resolveUrl(allocator, page_url, normalized);
    if (resourceExists(resources.items, resolved_url)) return;

    try resources.append(allocator, .{
        .kind = kind,
        .url = resolved_url,
    });
}

fn loadResources(
    allocator: std.mem.Allocator,
    session: *fetch.Session,
    resources: []model.Resource,
    page_url: []const u8,
) !void {
    for (resources, 0..) |*resource, index| {
        if (index >= max_loaded_resources) {
            resource.error_message = try allocator.dupe(u8, "skipped: resource fetch cap");
            continue;
        }

        var result = session.request(resource.url, .{
            .accept = "*/*",
            .referer = page_url,
        }) catch |err| {
            resource.error_message = try allocator.dupe(u8, @errorName(err));
            continue;
        };
        defer result.deinit(allocator);

        resource.loaded = true;
        resource.status_code = result.status_code;
        resource.content_type = try allocator.dupe(u8, result.content_type);
        resource.body_size = result.body.len;
        if (std.mem.eql(u8, resource.kind, "script") and isTextualResource(result.content_type) and result.body.len > 0) {
            resource.body_text = try allocator.dupe(u8, result.body);
        }
    }
}

fn isTextualResource(content_type: []const u8) bool {
    return std.mem.startsWith(u8, content_type, "text/") or
        std.mem.indexOf(u8, content_type, "javascript") != null or
        std.mem.indexOf(u8, content_type, "json") != null or
        std.mem.indexOf(u8, content_type, "xml") != null;
}

fn classifyLinkResource(rel_value: []const u8) ?[]const u8 {
    if (relContains(rel_value, "stylesheet")) return "stylesheet";
    if (relContains(rel_value, "icon")) return "icon";
    if (relContains(rel_value, "preload") or relContains(rel_value, "modulepreload")) return "preload";
    if (relContains(rel_value, "manifest")) return "manifest";
    return null;
}

fn relContains(rel_value: []const u8, needle: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, rel_value, " \t\r\n");
    while (it.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, needle)) return true;
    }
    return false;
}

fn firstSrcsetUrl(srcset: []const u8) ?[]const u8 {
    var candidates = std.mem.splitScalar(u8, srcset, ',');
    const first_candidate = std.mem.trim(u8, candidates.first(), " \t\r\n");
    if (first_candidate.len == 0) return null;

    var parts = std.mem.tokenizeAny(u8, first_candidate, " \t\r\n");
    return parts.next();
}

fn shouldIgnoreResourceUrl(raw_url: []const u8) bool {
    return std.mem.startsWith(u8, raw_url, "#") or
        std.ascii.startsWithIgnoreCase(raw_url, "data:") or
        std.ascii.startsWithIgnoreCase(raw_url, "javascript:") or
        std.ascii.startsWithIgnoreCase(raw_url, "mailto:") or
        std.ascii.startsWithIgnoreCase(raw_url, "tel:") or
        std.ascii.startsWithIgnoreCase(raw_url, "about:") or
        std.ascii.startsWithIgnoreCase(raw_url, "blob:");
}

fn resourceExists(resources: []const model.Resource, url: []const u8) bool {
    for (resources) |resource| {
        if (std.mem.eql(u8, resource.url, url)) return true;
    }
    return false;
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

    if (std.ascii.eqlIgnoreCase(node.name, "input")) {
        if (document.getAttribute(node_id, "type")) |input_type| {
            if ((std.ascii.eqlIgnoreCase(input_type, "checkbox") or std.ascii.eqlIgnoreCase(input_type, "radio")) and
                document.getAttribute(node_id, "checked") != null and
                document.getAttribute(node_id, "value") == null)
            {
                return allocator.dupe(u8, "on");
            }
        }
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

pub fn resolveUrl(allocator: std.mem.Allocator, base_url: []const u8, raw_url: []const u8) ![]const u8 {
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

fn parseFormMethod(method: []const u8) !std.http.Method {
    if (std.ascii.eqlIgnoreCase(method, "get")) return .GET;
    if (std.ascii.eqlIgnoreCase(method, "post")) return .POST;
    return error.UnsupportedFormMethod;
}

fn shouldSkipField(field: model.FormField) bool {
    if (field.name.len == 0) return true;
    if (std.mem.eql(u8, field.value, "(unchecked)")) return true;
    return std.ascii.eqlIgnoreCase(field.kind, "submit") or
        std.ascii.eqlIgnoreCase(field.kind, "button") or
        std.ascii.eqlIgnoreCase(field.kind, "reset");
}

fn formHasField(form: model.Form, name: []const u8) bool {
    for (form.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }
    return false;
}

fn findOverride(overrides: []const model.FieldInput, name: []const u8) ?model.FieldInput {
    for (overrides) |override| {
        if (std.mem.eql(u8, override.name, name)) return override;
    }
    return null;
}

fn encodeFormFields(allocator: std.mem.Allocator, fields: []const model.FieldInput) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (fields, 0..) |field, index| {
        if (index > 0) try out.append(allocator, '&');
        try appendFormEncodedComponent(allocator, &out, field.name);
        try out.append(allocator, '=');
        try appendFormEncodedComponent(allocator, &out, field.value);
    }
    return try out.toOwnedSlice(allocator);
}

fn appendFormEncodedComponent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), input: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (input) |c| {
        if (isUnreserved(c)) {
            try out.append(allocator, c);
        } else if (c == ' ') {
            try out.append(allocator, '+');
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0x0F]);
        }
    }
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '*';
}

fn appendQueryString(allocator: std.mem.Allocator, url: []const u8, encoded: []const u8) ![]const u8 {
    if (encoded.len == 0) return allocator.dupe(u8, url);
    const separator: []const u8 = if (std.mem.indexOfScalar(u8, url, '?') != null) "&" else "?";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ url, separator, encoded });
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

test "extractResources captures common static assets" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const html =
        "<html><head>" ++
        "<link rel=\"stylesheet\" href=\"/app.css\">" ++
        "<link rel=\"icon\" href=\"/favicon.ico\">" ++
        "<script src=\"/app.js\"></script>" ++
        "</head><body>" ++
        "<img src=\"/hero.png\">" ++
        "<iframe src=\"/frame\"></iframe>" ++
        "<img src=\"data:image/png;base64,abc\">" ++
        "</body></html>";

    const document = try dom.Document.parse(arena, html);
    const resources = try extractResources(arena, &document, "https://example.com/start");
    try std.testing.expectEqual(@as(usize, 5), resources.len);
    try std.testing.expectEqualStrings("stylesheet", resources[0].kind);
    try std.testing.expectEqualStrings("https://example.com/app.css", resources[0].url);
    try std.testing.expectEqualStrings("icon", resources[1].kind);
    try std.testing.expectEqualStrings("script", resources[2].kind);
    try std.testing.expectEqualStrings("image", resources[3].kind);
    try std.testing.expectEqualStrings("frame", resources[4].kind);
}

test "buildFormSubmission merges overrides and encodes post bodies" {
    var fields = [_]model.FormField{
        .{ .name = "csrf", .kind = "hidden", .value = "abc123" },
        .{ .name = "username", .kind = "text", .value = "" },
        .{ .name = "remember", .kind = "checkbox", .value = "(unchecked)" },
        .{ .name = "", .kind = "submit", .value = "Login" },
    };
    const form: model.Form = .{
        .method = "post",
        .action = "https://example.com/login",
        .enctype = "application/x-www-form-urlencoded",
        .id = "",
        .class_name = "",
        .fields = &fields,
    };
    const submission = try buildFormSubmission(std.testing.allocator, form, &.{
        .{ .name = "username", .value = "admin" },
        .{ .name = "password", .value = "admin" },
    });
    defer std.testing.allocator.free(submission.url);
    defer std.testing.allocator.free(submission.body.?);

    try std.testing.expectEqual(std.http.Method.POST, submission.method);
    try std.testing.expectEqualStrings("https://example.com/login", submission.url);
    try std.testing.expectEqualStrings("application/x-www-form-urlencoded", submission.content_type.?);
    try std.testing.expect(std.mem.indexOf(u8, submission.body.?, "csrf=abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, submission.body.?, "username=admin") != null);
    try std.testing.expect(std.mem.indexOf(u8, submission.body.?, "password=admin") != null);
    try std.testing.expect(std.mem.indexOf(u8, submission.body.?, "remember") == null);
}
