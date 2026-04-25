const std = @import("std");
const dom = @import("dom.zig");
const fetch = @import("fetch.zig");
const model = @import("model.zig");
const jsengine = @import("jsengine");

const script_accept = "text/javascript,application/javascript,application/ecmascript,text/ecmascript,text/plain,*/*";

pub const Options = struct {
    enabled: bool = false,
    eval_expression: ?[]const u8 = null,

    pub fn active(self: Options) bool {
        return self.enabled or self.eval_expression != null;
    }
};

pub fn evaluatePage(
    allocator: std.mem.Allocator,
    session: *fetch.Session,
    document: *const dom.Document,
    html: []const u8,
    page_url: []const u8,
    resources: []const model.Resource,
    options: Options,
) !model.JsExecution {
    if (!options.active()) return .{};

    var report: model.JsExecution = .{ .enabled = true };
    var engine = jsengine.JsEngine.init() catch {
        report.error_message = try allocator.dupe(u8, "JsInitFailed");
        return report;
    };
    defer engine.deinit();

    jsengine.prepareDomEngine(&engine, html, page_url, allocator);
    try executeScriptsRecursive(allocator, session, &engine, document, document.root(), page_url, resources, &report);

    report.output = jsengine.outputAlloc(&engine, allocator) orelse "";
    report.document_title = engine.evalAlloc(allocator, "document.title") orelse "";
    if (options.eval_expression) |expression| {
        report.eval_result = engine.evalAlloc(allocator, expression) orelse "";
        if (report.eval_result.len == 0 and report.error_message.len == 0) {
            report.error_message = try allocator.dupe(u8, "JsEvalFailed");
        }
    }

    return report;
}

fn executeScriptsRecursive(
    allocator: std.mem.Allocator,
    session: *fetch.Session,
    engine: *jsengine.JsEngine,
    document: *const dom.Document,
    node_id: dom.NodeId,
    page_url: []const u8,
    resources: []const model.Resource,
    report: *model.JsExecution,
) !void {
    const node = document.getNode(node_id);
    if (node.kind == .element and std.ascii.eqlIgnoreCase(node.name, "script")) {
        try maybeExecuteScript(allocator, session, engine, document, node_id, page_url, resources, report);
    }

    var child = node.first_child;
    while (child) |child_id| : (child = document.getNode(child_id).next_sibling) {
        try executeScriptsRecursive(allocator, session, engine, document, child_id, page_url, resources, report);
    }
}

fn maybeExecuteScript(
    allocator: std.mem.Allocator,
    session: *fetch.Session,
    engine: *jsengine.JsEngine,
    document: *const dom.Document,
    node_id: dom.NodeId,
    page_url: []const u8,
    resources: []const model.Resource,
    report: *model.JsExecution,
) !void {
    const script_type = std.mem.trim(u8, document.getAttribute(node_id, "type") orelse "", " \t\r\n");
    if (!isExecutableScriptType(script_type)) return;

    if (document.getAttribute(node_id, "src")) |raw_src| {
        report.external_scripts += 1;
        const script_url = resolveUrl(allocator, page_url, raw_src) catch |err| {
            try rememberError(allocator, report, @errorName(err));
            report.failed_scripts += 1;
            return;
        };

        if (scriptBodyForUrl(resources, script_url)) |script_body| {
            if (engine.exec(script_body)) {
                report.executed_scripts += 1;
            } else {
                report.failed_scripts += 1;
                try rememberError(allocator, report, "ScriptException");
            }
            return;
        }

        var result = session.request(script_url, .{
            .accept = script_accept,
            .referer = page_url,
        }) catch |err| {
            try rememberError(allocator, report, @errorName(err));
            report.failed_scripts += 1;
            return;
        };
        defer result.deinit(allocator);

        const trimmed = std.mem.trim(u8, result.body, " \t\r\n");
        if (trimmed.len == 0) return;

        if (engine.exec(trimmed)) {
            report.executed_scripts += 1;
        } else {
            report.failed_scripts += 1;
            try rememberError(allocator, report, "ScriptException");
        }
        return;
    }

    const inline_source = try inlineScriptSource(allocator, document, node_id);
    defer allocator.free(inline_source);

    const trimmed = std.mem.trim(u8, inline_source, " \t\r\n");
    if (trimmed.len == 0) return;

    report.inline_scripts += 1;
    if (engine.exec(trimmed)) {
        report.executed_scripts += 1;
    } else {
        report.failed_scripts += 1;
        try rememberError(allocator, report, "ScriptException");
    }
}

fn inlineScriptSource(allocator: std.mem.Allocator, document: *const dom.Document, node_id: dom.NodeId) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const node = document.getNode(node_id);
    var child = node.first_child;
    while (child) |child_id| : (child = document.getNode(child_id).next_sibling) {
        const child_node = document.getNode(child_id);
        switch (child_node.kind) {
            .text => try out.appendSlice(allocator, child_node.text),
            .element => {
                const nested = try inlineScriptSource(allocator, document, child_id);
                defer allocator.free(nested);
                try out.appendSlice(allocator, nested);
            },
            else => {},
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn isExecutableScriptType(script_type: []const u8) bool {
    if (script_type.len == 0) return true;
    return std.ascii.eqlIgnoreCase(script_type, "text/javascript") or
        std.ascii.eqlIgnoreCase(script_type, "application/javascript") or
        std.ascii.eqlIgnoreCase(script_type, "application/ecmascript") or
        std.ascii.eqlIgnoreCase(script_type, "text/ecmascript") or
        std.ascii.eqlIgnoreCase(script_type, "module");
}

fn rememberError(allocator: std.mem.Allocator, report: *model.JsExecution, message: []const u8) !void {
    if (report.error_message.len == 0) {
        report.error_message = try allocator.dupe(u8, message);
    }
}

fn resolveUrl(allocator: std.mem.Allocator, base_url: []const u8, raw_url: []const u8) ![]const u8 {
    const normalized = std.mem.trim(u8, raw_url, " \t\r\n");
    if (std.mem.startsWith(u8, normalized, "http://") or std.mem.startsWith(u8, normalized, "https://")) {
        return allocator.dupe(u8, normalized);
    }

    const base_uri = try std.Uri.parse(base_url);
    var aux_buf: [8192]u8 = undefined;
    if (normalized.len > aux_buf.len) return error.UrlTooLong;

    @memcpy(aux_buf[0..normalized.len], normalized);
    var remaining_aux: []u8 = aux_buf[0..];
    const resolved_uri = base_uri.resolveInPlace(normalized.len, &remaining_aux) catch return error.InvalidUrl;
    return std.fmt.allocPrint(allocator, "{f}", .{resolved_uri});
}

fn scriptBodyForUrl(resources: []const model.Resource, url: []const u8) ?[]const u8 {
    for (resources) |resource| {
        if (std.mem.eql(u8, resource.kind, "script") and
            std.mem.eql(u8, resource.url, url) and
            resource.body_text.len > 0)
        {
            return resource.body_text;
        }
    }
    return null;
}

test "options active when js or eval requested" {
    try std.testing.expect(!(Options{}).active());
    try std.testing.expect((Options{ .enabled = true }).active());
    try std.testing.expect((Options{ .eval_expression = "document.title" }).active());
}

test "script type filter skips non-executable types" {
    try std.testing.expect(isExecutableScriptType(""));
    try std.testing.expect(isExecutableScriptType("text/javascript"));
    try std.testing.expect(isExecutableScriptType("module"));
    try std.testing.expect(!isExecutableScriptType("application/ld+json"));
    try std.testing.expect(!isExecutableScriptType("importmap"));
}

test "inlineScriptSource preserves raw script content" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const document = try dom.Document.parse(arena, "<script>const x = 1;\nconst y = 2;</script>");
    const script_id = (try document.querySelector(arena, "script")).?;
    const source = try inlineScriptSource(arena, &document, script_id);
    try std.testing.expect(std.mem.indexOf(u8, source, "const x = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "const y = 2;") != null);
}
