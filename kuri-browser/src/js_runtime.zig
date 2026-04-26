const std = @import("std");
const quickjs = @import("quickjs");
const dom = @import("dom.zig");
const fetch = @import("fetch.zig");
const model = @import("model.zig");
const jsengine = @import("jsengine");

const script_accept = "text/javascript,application/javascript,application/ecmascript,text/ecmascript,text/plain,*/*";
const max_pending_jobs = 256;

pub const Options = struct {
    enabled: bool = false,
    eval_expression: ?[]const u8 = null,
    wait_selector: ?[]const u8 = null,
    wait_expression: ?[]const u8 = null,
    wait_iterations: usize = 16,

    pub fn active(self: Options) bool {
        return self.enabled or
            self.eval_expression != null or
            self.wait_selector != null or
            self.wait_expression != null;
    }
};

const BridgeState = struct {
    allocator: std.mem.Allocator,
    session: *fetch.Session,
    page_url: []const u8,
    report: *model.JsExecution,
};

const RequestPayload = struct {
    kind: ?[]const u8 = null,
    url: []const u8,
    method: ?[]const u8 = null,
    body: ?[]const u8 = null,
    contentType: ?[]const u8 = null,
    accept: ?[]const u8 = null,
    referer: ?[]const u8 = null,
};

const ResponsePayload = struct {
    ok: bool,
    url: []const u8,
    status: u16,
    contentType: []const u8,
    body: []const u8,
    redirected: bool,
    @"error": []const u8 = "",
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

    var bridge = BridgeState{
        .allocator = allocator,
        .session = session,
        .page_url = page_url,
        .report = &report,
    };
    installBridge(allocator, &engine, &bridge, &report) catch {
        if (report.error_message.len == 0) {
            report.error_message = try allocator.dupe(u8, "JsBridgeInitFailed");
        }
        return report;
    };
    defer engine.ctx.setOpaque(BridgeState, null);

    try executeScriptsRecursive(allocator, session, &engine, document, document.root(), page_url, resources, &report);
    try drainPendingJobs(allocator, &engine, &report);

    if (try waitExpressionForOptions(allocator, options)) |wait_expression| {
        report.wait_expression = wait_expression;
        const wait_result = try waitForCondition(allocator, &engine, wait_expression, options.wait_iterations, &report);
        report.wait_satisfied = wait_result.satisfied;
        report.wait_polls = wait_result.polls;
    }

    report.output = jsengine.outputAlloc(&engine, allocator) orelse "";
    report.document_title = engine.evalAlloc(allocator, "document.title") orelse "";

    if (options.eval_expression) |expression| {
        const eval_ok = try evaluateExpression(allocator, &engine, expression, &report);
        if (!eval_ok and report.error_message.len == 0) {
            report.error_message = try allocator.dupe(u8, "JsEvalFailed");
        }
    }

    return report;
}

const WaitResult = struct {
    satisfied: bool,
    polls: usize,
};

fn waitExpressionForOptions(allocator: std.mem.Allocator, options: Options) !?[]const u8 {
    if (options.wait_expression) |expression| return @as(?[]const u8, try allocator.dupe(u8, expression));
    if (options.wait_selector) |selector| {
        const quoted = try jsonStringLiteral(allocator, selector);
        defer allocator.free(quoted);
        return @as(?[]const u8, try std.fmt.allocPrint(allocator, "!!document.querySelector({s})", .{quoted}));
    }
    return null;
}

fn waitForCondition(
    allocator: std.mem.Allocator,
    engine: *jsengine.JsEngine,
    expression: []const u8,
    max_iterations: usize,
    report: *model.JsExecution,
) !WaitResult {
    const limit = if (max_iterations == 0) 1 else max_iterations;
    var polls: usize = 0;
    while (polls < limit) : (polls += 1) {
        try drainPendingJobs(allocator, engine, report);
        if (try evaluateBooleanExpression(allocator, engine, expression, report)) {
            return .{ .satisfied = true, .polls = polls + 1 };
        }
    }
    return .{ .satisfied = false, .polls = polls };
}

fn evaluateBooleanExpression(
    allocator: std.mem.Allocator,
    engine: *jsengine.JsEngine,
    expression: []const u8,
    report: *model.JsExecution,
) !bool {
    clearPendingException(engine.ctx);
    const wrapped = try std.fmt.allocPrint(allocator, "!!({s})", .{expression});
    defer allocator.free(wrapped);

    const result = engine.ctx.eval(wrapped, "<kuri-wait>", .{});
    defer result.deinit(engine.ctx);
    if (result.isException()) {
        try rememberCurrentException(allocator, engine.ctx, report);
        return false;
    }
    return result.toBool(engine.ctx) catch false;
}

fn installBridge(
    allocator: std.mem.Allocator,
    engine: *jsengine.JsEngine,
    bridge: *BridgeState,
    report: *model.JsExecution,
) !void {
    engine.ctx.setOpaque(BridgeState, bridge);

    const global = engine.ctx.getGlobalObject();
    defer global.deinit(engine.ctx);

    const request_fn = quickjs.Value.initCFunction(engine.ctx, &jsBridgeRequest, "__kuri_request", 1);
    defer request_fn.deinit(engine.ctx);
    try global.setPropertyStr(engine.ctx, "__kuri_request", request_fn.dup(engine.ctx));

    const cookie_get_fn = quickjs.Value.initCFunction(engine.ctx, &jsBridgeCookieGet, "__kuri_cookie_get", 0);
    defer cookie_get_fn.deinit(engine.ctx);
    try global.setPropertyStr(engine.ctx, "__kuri_cookie_get", cookie_get_fn.dup(engine.ctx));

    const cookie_set_fn = quickjs.Value.initCFunction(engine.ctx, &jsBridgeCookieSet, "__kuri_cookie_set", 1);
    defer cookie_set_fn.deinit(engine.ctx);
    try global.setPropertyStr(engine.ctx, "__kuri_cookie_set", cookie_set_fn.dup(engine.ctx));

    const install_result = engine.ctx.eval(browser_bridge_js, "<kuri-browser-bridge>", .{});
    defer install_result.deinit(engine.ctx);
    if (install_result.isException()) {
        try rememberCurrentException(allocator, engine.ctx, report);
        return error.JsBridgeInstallFailed;
    }
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
        defer allocator.free(script_url);

        if (scriptBodyForUrl(resources, script_url)) |script_body| {
            try executeScriptSource(allocator, engine, script_body, script_url, .global_eval, report);
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

        try executeScriptSource(allocator, engine, trimmed, script_url, .global_eval, report);
        return;
    }

    const inline_source = try inlineScriptSource(allocator, document, node_id);
    defer allocator.free(inline_source);

    const trimmed = std.mem.trim(u8, inline_source, " \t\r\n");
    if (trimmed.len == 0) return;

    report.inline_scripts += 1;
    try executeScriptSource(allocator, engine, trimmed, "<inline>", .global_eval, report);
}

const ScriptExecMode = enum {
    direct,
    global_eval,
};

fn executeScriptSource(
    allocator: std.mem.Allocator,
    engine: *jsengine.JsEngine,
    source: []const u8,
    label: []const u8,
    mode: ScriptExecMode,
    report: *model.JsExecution,
) !void {
    const ok = switch (mode) {
        .direct => engine.exec(source),
        .global_eval => try executeViaGlobalEval(engine, source),
    };

    if (ok) {
        report.executed_scripts += 1;
    } else {
        report.failed_scripts += 1;
        const had_error = report.error_message.len != 0;
        try rememberCurrentException(allocator, engine.ctx, report);
        if (!had_error and report.error_message.len > 0) {
            const combined = try annotateScriptError(allocator, label, report.error_message, source);
            allocator.free(report.error_message);
            report.error_message = combined;
        }
    }
    try drainPendingJobs(allocator, engine, report);
}

const EvalLocation = struct {
    line: usize,
    column: usize,
};

fn annotateScriptError(
    allocator: std.mem.Allocator,
    label: []const u8,
    message: []const u8,
    source: []const u8,
) ![]u8 {
    const preview_len = @min(source.len, 80);
    const preview = std.mem.trim(u8, source[0..preview_len], " \t\r\n");
    const suffix_start = if (source.len > 80) source.len - 80 else 0;
    const suffix = try sanitizeBytesForMessage(allocator, std.mem.trim(u8, source[suffix_start..], " \t\r\n"));
    defer allocator.free(suffix);
    if (extractEvalLocation(message)) |location| {
        const excerpt = try sourceLineExcerpt(allocator, source, location.line);
        defer allocator.free(excerpt);
        return std.fmt.allocPrint(
            allocator,
            "{s}: {s} [line {d}:{d}={s}] [prefix={s}] [suffix={s}]",
            .{ label, message, location.line, location.column, excerpt, preview, suffix },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}: {s} [prefix={s}] [suffix={s}]",
        .{ label, message, preview, suffix },
    );
}

fn extractEvalLocation(message: []const u8) ?EvalLocation {
    var i: usize = 0;
    while (i < message.len) : (i += 1) {
        if (message[i] != ':') continue;
        var j = i + 1;
        var line: usize = 0;
        var saw_line_digit = false;
        while (j < message.len and std.ascii.isDigit(message[j])) : (j += 1) {
            saw_line_digit = true;
            line = (line * 10) + (message[j] - '0');
        }
        if (!saw_line_digit or j >= message.len or message[j] != ':') continue;
        j += 1;
        var column: usize = 0;
        var saw_col_digit = false;
        while (j < message.len and std.ascii.isDigit(message[j])) : (j += 1) {
            saw_col_digit = true;
            column = (column * 10) + (message[j] - '0');
        }
        if (saw_col_digit) return .{ .line = line, .column = column };
    }
    return null;
}

fn sourceLineExcerpt(allocator: std.mem.Allocator, source: []const u8, target_line: usize) ![]u8 {
    if (target_line == 0) return allocator.dupe(u8, "");

    var current_line: usize = 1;
    var start: usize = 0;
    var index: usize = 0;
    while (index < source.len and current_line < target_line) : (index += 1) {
        if (source[index] == '\n') {
            current_line += 1;
            start = index + 1;
        }
    }

    var end = start;
    while (end < source.len and source[end] != '\n' and source[end] != '\r') : (end += 1) {}
    return sanitizeBytesForMessage(allocator, source[start..end]);
}

fn sanitizeBytesForMessage(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (input) |byte| {
        switch (byte) {
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (byte >= 0x20 and byte < 0x7f) {
                    try out.append(allocator, byte);
                } else {
                    try out.appendSlice(allocator, "\\x");
                    try out.append(allocator, hex[byte >> 4]);
                    try out.append(allocator, hex[byte & 0x0f]);
                }
            },
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn executeViaGlobalEval(engine: *jsengine.JsEngine, source: []const u8) !bool {
    const result = try callViaGlobalEval(engine, source);
    defer result.deinit(engine.ctx);
    return !result.isException();
}

fn callViaGlobalEval(engine: *jsengine.JsEngine, source: []const u8) !quickjs.Value {
    const global = engine.ctx.getGlobalObject();
    defer global.deinit(engine.ctx);

    const eval_fn = global.getPropertyStr(engine.ctx, "eval");
    defer eval_fn.deinit(engine.ctx);
    if (eval_fn.isException()) return quickjs.Value.exception;

    const script = quickjs.Value.initStringLen(engine.ctx, source);
    defer script.deinit(engine.ctx);

    return eval_fn.call(engine.ctx, quickjs.Value.undefined, &.{script.dup(engine.ctx)});
}

fn evaluateExpression(
    allocator: std.mem.Allocator,
    engine: *jsengine.JsEngine,
    expression: []const u8,
    report: *model.JsExecution,
) !bool {
    clearPendingException(engine.ctx);

    const wrapped = try wrapEvalExpression(allocator, expression);
    defer allocator.free(wrapped);

    const result = engine.ctx.eval(wrapped, "<kuri-eval>", .{});
    defer result.deinit(engine.ctx);
    if (result.isException()) {
        clearPendingException(engine.ctx);

        const fallback = try callViaGlobalEval(engine, wrapped);
        defer fallback.deinit(engine.ctx);
        if (!fallback.isException()) {
            if (!isThenable(engine.ctx, fallback)) {
                report.eval_result = try valueToOwnedString(allocator, engine.ctx, fallback);
                return true;
            }
        }
        try rememberCurrentException(allocator, engine.ctx, report);
        return false;
    }

    if (!isThenable(engine.ctx, result)) {
        report.eval_result = try valueToOwnedString(allocator, engine.ctx, result);
        return true;
    }

    if (!engine.exec(eval_helper_js)) {
        try rememberCurrentException(allocator, engine.ctx, report);
        return false;
    }

    const global = engine.ctx.getGlobalObject();
    defer global.deinit(engine.ctx);

    const runner = global.getPropertyStr(engine.ctx, "__kuri_run_eval");
    defer runner.deinit(engine.ctx);
    if (runner.isException()) {
        try rememberCurrentException(allocator, engine.ctx, report);
        return false;
    }

    const script = quickjs.Value.initStringLen(engine.ctx, wrapped);
    defer script.deinit(engine.ctx);

    const async_result = runner.call(engine.ctx, quickjs.Value.undefined, &.{script.dup(engine.ctx)});
    defer async_result.deinit(engine.ctx);
    if (async_result.isException()) {
        try rememberCurrentException(allocator, engine.ctx, report);
        return false;
    }

    try drainPendingJobs(allocator, engine, report);

    const eval_error = try globalStringPropertyAlloc(allocator, engine.ctx, "__kuri_eval_error");
    if (eval_error.len != 0) {
        if (report.error_message.len == 0) report.error_message = eval_error else allocator.free(eval_error);
        return false;
    }
    allocator.free(eval_error);

    report.eval_result = try globalStringPropertyAlloc(allocator, engine.ctx, "__kuri_eval_result");
    return true;
}

fn clearPendingException(ctx: *quickjs.Context) void {
    if (!ctx.hasException()) return;
    const exc = ctx.getException();
    defer exc.deinit(ctx);
}

fn globalStringPropertyAlloc(
    allocator: std.mem.Allocator,
    ctx: *quickjs.Context,
    name: [:0]const u8,
) ![]const u8 {
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const value = global.getPropertyStr(ctx, name);
    defer value.deinit(ctx);
    if (value.isException()) return allocator.dupe(u8, "");

    const cstr = value.toCString(ctx) orelse return allocator.dupe(u8, "");
    defer ctx.freeCString(cstr);
    return allocator.dupe(u8, std.mem.span(cstr));
}

fn valueToOwnedString(
    allocator: std.mem.Allocator,
    ctx: *quickjs.Context,
    value: quickjs.Value,
) ![]const u8 {
    const cstr = value.toCString(ctx) orelse return allocator.dupe(u8, "");
    defer ctx.freeCString(cstr);
    return allocator.dupe(u8, std.mem.span(cstr));
}

fn isThenable(ctx: *quickjs.Context, value: quickjs.Value) bool {
    if (!value.isObject()) return false;
    const then = value.getPropertyStr(ctx, "then");
    defer then.deinit(ctx);
    if (then.isException()) return false;
    return then.isFunction(ctx);
}

const eval_helper_js =
    \\globalThis.__kuri_run_eval = function(source) {
    \\  globalThis.__kuri_eval_result = "";
    \\  globalThis.__kuri_eval_error = "";
    \\  try {
    \\    var value = globalThis.eval(String(source));
    \\    Promise.resolve(value).then(function(resolved) {
    \\      globalThis.__kuri_eval_result = resolved == null ? "" : String(resolved);
    \\    }, function(err) {
    \\      globalThis.__kuri_eval_error = String((err && err.stack) || (err && err.message) || err);
    \\    });
    \\  } catch (e) {
    \\    globalThis.__kuri_eval_error = String((e && e.stack) || (e && e.message) || e);
    \\  }
    \\};
;

fn wrapEvalExpression(allocator: std.mem.Allocator, expression: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, expression, " \t\r\n");
    const cleaned = std.mem.trimEnd(u8, trimmed, " \t\r\n;");
    if (cleaned.len == 0) return allocator.dupe(u8, "\"\"");

    if (startsLikeStatement(cleaned)) {
        return std.fmt.allocPrint(allocator, "(function(){{ {s} }})()", .{cleaned});
    }
    return allocator.dupe(u8, cleaned);
}

fn startsLikeStatement(expression: []const u8) bool {
    const statement_prefixes = [_][]const u8{
        "var ",
        "let ",
        "const ",
        "if ",
        "for ",
        "while ",
        "return ",
        "switch ",
        "try ",
        "{",
    };
    for (statement_prefixes) |prefix| {
        if (std.mem.startsWith(u8, expression, prefix)) return true;
    }
    return false;
}

fn drainPendingJobs(
    allocator: std.mem.Allocator,
    engine: *jsengine.JsEngine,
    report: *model.JsExecution,
) !void {
    var jobs_drained: usize = 0;
    while (engine.rt.isJobPending()) : (jobs_drained += 1) {
        if (jobs_drained >= max_pending_jobs) {
            try rememberError(allocator, report, "PendingJobLimitExceeded");
            return;
        }
        _ = engine.rt.executePendingJob() catch {
            try rememberCurrentException(allocator, engine.ctx, report);
            return;
        };
    }
}

fn inlineScriptSource(allocator: std.mem.Allocator, document: *const dom.Document, node_id: dom.NodeId) ![]const u8 {
    const node = document.getNode(node_id);
    if (node.kind == .element and std.ascii.eqlIgnoreCase(node.name, "script")) {
        const outer = document.html[node.source_start..node.source_end];
        const open_end = std.mem.indexOfScalar(u8, outer, '>') orelse return allocator.dupe(u8, "");
        const close_start = std.mem.lastIndexOf(u8, outer, "</") orelse outer.len;
        if (close_start <= open_end) return allocator.dupe(u8, "");
        return allocator.dupe(u8, outer[open_end + 1 .. close_start]);
    }

    var out: std.ArrayList(u8) = .empty;
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

fn jsBridgeRequest(
    ctx_opt: ?*quickjs.Context,
    _: quickjs.Value,
    args: []const quickjs.c.JSValue,
) quickjs.Value {
    const ctx = ctx_opt orelse return quickjs.Value.exception;
    const bridge = ctx.getOpaque(BridgeState) orelse return quickjs.Value.initString(ctx, "MissingBridge").throw(ctx);
    if (args.len == 0) return quickjs.Value.initString(ctx, "MissingRequestPayload").throw(ctx);

    const input = quickjs.Value.fromCVal(args[0]);
    const raw = input.toCString(ctx) orelse return quickjs.Value.initString(ctx, "InvalidRequestPayload").throw(ctx);
    defer ctx.freeCString(raw);

    return handleBridgeRequest(ctx, bridge, std.mem.span(raw)) catch |err| {
        return quickjs.Value.initStringLen(ctx, @errorName(err)).throw(ctx);
    };
}

fn handleBridgeRequest(
    ctx: *quickjs.Context,
    bridge: *BridgeState,
    input: []const u8,
) !quickjs.Value {
    var arena_impl = std.heap.ArenaAllocator.init(bridge.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var parsed = try std.json.parseFromSlice(RequestPayload, arena, input, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const payload = parsed.value;

    const resolved_url = resolveUrl(arena, bridge.page_url, payload.url) catch payload.url;
    const method = parseHttpMethod(payload.method orelse "GET") catch {
        const response_json = try buildResponseJson(arena, .{
            .ok = false,
            .url = resolved_url,
            .status = 0,
            .contentType = "",
            .body = "",
            .redirected = false,
            .@"error" = "UnsupportedMethod",
        });
        return quickjs.Value.initStringLen(ctx, response_json);
    };

    const request_kind = payload.kind orelse "fetch";
    if (std.mem.eql(u8, request_kind, "xhr")) {
        bridge.report.xhr_requests += 1;
    } else {
        bridge.report.fetch_requests += 1;
    }

    var result = bridge.session.request(resolved_url, .{
        .method = method,
        .body = payload.body,
        .content_type = optionalNonEmpty(payload.contentType),
        .accept = payload.accept orelse "*/*",
        .referer = optionalNonEmpty(payload.referer) orelse bridge.page_url,
    }) catch |err| {
        const response_json = try buildResponseJson(arena, .{
            .ok = false,
            .url = resolved_url,
            .status = 0,
            .contentType = "",
            .body = "",
            .redirected = false,
            .@"error" = @errorName(err),
        });
        return quickjs.Value.initStringLen(ctx, response_json);
    };
    defer result.deinit(bridge.allocator);

    const response = ResponsePayload{
        .ok = true,
        .url = result.url,
        .status = result.status_code,
        .contentType = result.content_type,
        .body = result.body,
        .redirected = result.redirect_chain.len > 0,
    };
    const response_json = try buildResponseJson(arena, response);
    return quickjs.Value.initStringLen(ctx, response_json);
}

fn jsBridgeCookieGet(
    ctx_opt: ?*quickjs.Context,
    _: quickjs.Value,
    _: []const quickjs.c.JSValue,
) quickjs.Value {
    const ctx = ctx_opt orelse return quickjs.Value.exception;
    const bridge = ctx.getOpaque(BridgeState) orelse return quickjs.Value.initString(ctx, "MissingBridge").throw(ctx);
    const header = bridge.session.jar.cookieHeader(bridge.allocator, bridge.page_url) catch null;
    defer if (header) |value| bridge.allocator.free(value);
    return quickjs.Value.initStringLen(ctx, header orelse "");
}

fn jsBridgeCookieSet(
    ctx_opt: ?*quickjs.Context,
    _: quickjs.Value,
    args: []const quickjs.c.JSValue,
) quickjs.Value {
    const ctx = ctx_opt orelse return quickjs.Value.exception;
    const bridge = ctx.getOpaque(BridgeState) orelse return quickjs.Value.initString(ctx, "MissingBridge").throw(ctx);
    if (args.len == 0) return quickjs.Value.undefined;

    const cookie_input = quickjs.Value.fromCVal(args[0]);
    const raw = cookie_input.toCString(ctx) orelse return quickjs.Value.undefined;
    defer ctx.freeCString(raw);

    bridge.session.jar.absorbSetCookie(bridge.page_url, std.mem.span(raw)) catch {};
    return quickjs.Value.undefined;
}

fn buildResponseJson(arena: std.mem.Allocator, payload: ResponsePayload) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try std.json.Stringify.value(payload, .{}, &out.writer);
    return arena.dupe(u8, out.written());
}

fn jsonStringLiteral(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

fn optionalNonEmpty(value: ?[]const u8) ?[]const u8 {
    const slice = value orelse return null;
    if (slice.len == 0) return null;
    return slice;
}

fn parseHttpMethod(value: []const u8) !std.http.Method {
    if (std.ascii.eqlIgnoreCase(value, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(value, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(value, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(value, "PATCH")) return .PATCH;
    if (std.ascii.eqlIgnoreCase(value, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(value, "HEAD")) return .HEAD;
    if (std.ascii.eqlIgnoreCase(value, "OPTIONS")) return .OPTIONS;
    return error.UnsupportedMethod;
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

fn rememberCurrentException(
    allocator: std.mem.Allocator,
    ctx: *quickjs.Context,
    report: *model.JsExecution,
) !void {
    if (!ctx.hasException()) {
        try rememberError(allocator, report, "ScriptException");
        return;
    }

    const exc = ctx.getException();
    defer exc.deinit(ctx);

    var message_span: ?[]const u8 = null;
    const stack = exc.getPropertyStr(ctx, "stack");
    defer stack.deinit(ctx);
    const message = exc.getPropertyStr(ctx, "message");
    defer message.deinit(ctx);
    if (!message.isException()) {
        if (message.toCString(ctx)) |value| {
            defer ctx.freeCString(value);
            message_span = std.mem.span(value);
        }
    }

    if (!stack.isException()) {
        if (stack.toCString(ctx)) |value| {
            defer ctx.freeCString(value);
            const stack_span = std.mem.span(value);
            if (message_span) |msg| {
                const combined = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ msg, stack_span });
                if (report.error_message.len == 0) report.error_message = combined else allocator.free(combined);
                return;
            }
            try rememberError(allocator, report, stack_span);
            return;
        }
    }

    if (message_span) |msg| {
        try rememberError(allocator, report, msg);
        return;
    }

    if (exc.toCString(ctx)) |value| {
        defer ctx.freeCString(value);
        try rememberError(allocator, report, std.mem.span(value));
        return;
    }

    try rememberError(allocator, report, "ScriptException");
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

const browser_bridge_js =
    \\(function() {
    \\  function normalizeHeaderName(name) {
    \\    return String(name || '').toLowerCase();
    \\  }
    \\
    \\  class Headers {
    \\    constructor(init) {
    \\      this._map = Object.create(null);
    \\      if (!init) return;
    \\      if (init instanceof Headers) {
    \\        init.forEach((value, key) => this.set(key, value));
    \\        return;
    \\      }
    \\      if (Array.isArray(init)) {
    \\        for (var i = 0; i < init.length; i += 1) {
    \\          var pair = init[i];
    \\          if (pair && pair.length >= 2) this.set(pair[0], pair[1]);
    \\        }
    \\        return;
    \\      }
    \\      var keys = Object.keys(init);
    \\      for (var j = 0; j < keys.length; j += 1) {
    \\        var key = keys[j];
    \\        this.set(key, init[key]);
    \\      }
    \\    }
    \\    set(name, value) {
    \\      this._map[normalizeHeaderName(name)] = String(value);
    \\    }
    \\    append(name, value) {
    \\      var key = normalizeHeaderName(name);
    \\      if (this._map[key]) {
    \\        this._map[key] += ', ' + String(value);
    \\      } else {
    \\        this._map[key] = String(value);
    \\      }
    \\    }
    \\    get(name) {
    \\      var key = normalizeHeaderName(name);
    \\      return Object.prototype.hasOwnProperty.call(this._map, key) ? this._map[key] : null;
    \\    }
    \\    has(name) {
    \\      return this.get(name) !== null;
    \\    }
    \\    delete(name) {
    \\      delete this._map[normalizeHeaderName(name)];
    \\    }
    \\    forEach(callback, thisArg) {
    \\      var keys = Object.keys(this._map);
    \\      for (var i = 0; i < keys.length; i += 1) {
    \\        var key = keys[i];
    \\        callback.call(thisArg, this._map[key], key, this);
    \\      }
    \\    }
    \\    entries() {
    \\      var keys = Object.keys(this._map);
    \\      var out = [];
    \\      for (var i = 0; i < keys.length; i += 1) {
    \\        out.push([keys[i], this._map[keys[i]]]);
    \\      }
    \\      return out;
    \\    }
    \\    keys() {
    \\      return Object.keys(this._map);
    \\    }
    \\    values() {
    \\      var keys = Object.keys(this._map);
    \\      var out = [];
    \\      for (var i = 0; i < keys.length; i += 1) {
    \\        out.push(this._map[keys[i]]);
    \\      }
    \\      return out;
    \\    }
    \\    [Symbol.iterator]() {
    \\      return this.entries()[Symbol.iterator]();
    \\    }
    \\  }
    \\
    \\  class Request {
    \\    constructor(input, init) {
    \\      var normalized = normalizeRequest(input, init, 'fetch');
    \\      this.url = normalized.url;
    \\      this.method = normalized.method;
    \\      this.headers = normalized.headers;
    \\      this._body = normalized.body;
    \\    }
    \\    clone() {
    \\      return new Request(this.url, {
    \\        method: this.method,
    \\        headers: this.headers,
    \\        body: this._body,
    \\      });
    \\    }
    \\    text() {
    \\      return Promise.resolve(this._body == null ? '' : String(this._body));
    \\    }
    \\  }
    \\
    \\  class Response {
    \\    constructor(payload) {
    \\      this._payload = payload || {};
    \\      this.status = payload && payload.status ? payload.status : 0;
    \\      this.statusText = payload && payload.error ? String(payload.error) : '';
    \\      this.ok = !!(payload && payload.ok);
    \\      this.url = payload && payload.url ? payload.url : '';
    \\      this.redirected = !!(payload && payload.redirected);
    \\      this.headers = new Headers({
    \\        'content-type': payload && payload.contentType ? payload.contentType : '',
    \\      });
    \\    }
    \\    clone() {
    \\      return new Response(this._payload);
    \\    }
    \\    text() {
    \\      return Promise.resolve(this._payload && this._payload.body ? this._payload.body : '');
    \\    }
    \\    json() {
    \\      return this.text().then(function(body) { return JSON.parse(body || 'null'); });
    \\    }
    \\    arrayBuffer() {
    \\      return this.text().then(function(body) {
    \\        var len = body.length;
    \\        var bytes = new Uint8Array(len);
    \\        for (var i = 0; i < len; i += 1) bytes[i] = body.charCodeAt(i) & 0xff;
    \\        return bytes.buffer;
    \\      });
    \\    }
    \\  }
    \\
    \\  function normalizeBody(body) {
    \\    if (body == null) return null;
    \\    if (typeof body === 'string') return body;
    \\    if (typeof body === 'object') {
    \\      if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) {
    \\        return body.toString();
    \\      }
    \\      if (typeof body.toString === 'function') return body.toString();
    \\    }
    \\    return String(body);
    \\  }
    \\
    \\  function normalizeHeaders(init, base) {
    \\    var headers = new Headers(base);
    \\    if (!init) return headers;
    \\    if (init instanceof Headers) {
    \\      init.forEach(function(value, key) { headers.set(key, value); });
    \\      return headers;
    \\    }
    \\    if (Array.isArray(init)) {
    \\      for (var i = 0; i < init.length; i += 1) {
    \\        var pair = init[i];
    \\        if (pair && pair.length >= 2) headers.set(pair[0], pair[1]);
    \\      }
    \\      return headers;
    \\    }
    \\    var keys = Object.keys(init);
    \\    for (var j = 0; j < keys.length; j += 1) {
    \\      var key = keys[j];
    \\      headers.set(key, init[key]);
    \\    }
    \\    return headers;
    \\  }
    \\
    \\  function normalizeRequest(input, init, kind) {
    \\    var url = '';
    \\    var method = 'GET';
    \\    var headers = new Headers();
    \\    var body = null;
    \\
    \\    if (input instanceof Request) {
    \\      url = input.url;
    \\      method = input.method || method;
    \\      headers = normalizeHeaders(input.headers, headers);
    \\      body = input._body;
    \\    } else if (input && typeof input === 'object' && input.url) {
    \\      url = String(input.url);
    \\      if (input.method) method = String(input.method);
    \\      if (input.headers) headers = normalizeHeaders(input.headers, headers);
    \\      if ('body' in input) body = input.body;
    \\    } else {
    \\      url = String(input);
    \\    }
    \\
    \\    if (init) {
    \\      if (init.method) method = String(init.method);
    \\      if (init.headers) headers = normalizeHeaders(init.headers, headers);
    \\      if ('body' in init) body = init.body;
    \\    }
    \\
    \\    body = normalizeBody(body);
    \\
    \\    return {
    \\      kind: kind,
    \\      url: url,
    \\      method: method,
    \\      headers: headers,
    \\      body: body,
    \\      contentType: headers.get('content-type') || '',
    \\      accept: headers.get('accept') || '*/*',
    \\      referer: headers.get('referer') || ((globalThis.location && globalThis.location.href) || ''),
    \\    };
    \\  }
    \\
    \\  function performBridgeRequest(normalized) {
    \\    var raw = __kuri_request(JSON.stringify({
    \\      kind: normalized.kind,
    \\      url: normalized.url,
    \\      method: normalized.method,
    \\      body: normalized.body,
    \\      contentType: normalized.contentType,
    \\      accept: normalized.accept,
    \\      referer: normalized.referer,
    \\    }));
    \\    return JSON.parse(raw);
    \\  }
    \\
    \\  function fetch(input, init) {
    \\    var normalized = normalizeRequest(input, init, 'fetch');
    \\    return Promise.resolve().then(function() {
    \\      var payload = performBridgeRequest(normalized);
    \\      if (payload && payload.error) throw new Error(payload.error);
    \\      return new Response(payload);
    \\    });
    \\  }
    \\
    \\  class XMLHttpRequest {
    \\    constructor() {
    \\      this.readyState = 0;
    \\      this.status = 0;
    \\      this.statusText = '';
    \\      this.responseText = '';
    \\      this.response = '';
    \\      this.responseURL = '';
    \\      this.onreadystatechange = null;
    \\      this.onload = null;
    \\      this.onerror = null;
    \\      this._method = 'GET';
    \\      this._url = '';
    \\      this._async = true;
    \\      this._headers = new Headers();
    \\    }
    \\    open(method, url, async) {
    \\      this._method = String(method || 'GET');
    \\      this._url = String(url || '');
    \\      this._async = async !== false;
    \\      this.readyState = 1;
    \\      this._notifyReadyState();
    \\    }
    \\    setRequestHeader(name, value) {
    \\      this._headers.set(name, value);
    \\    }
    \\    getResponseHeader(name) {
    \\      if (!this._responseHeaders) return null;
    \\      return this._responseHeaders.get(name);
    \\    }
    \\    getAllResponseHeaders() {
    \\      if (!this._responseHeaders) return '';
    \\      var lines = [];
    \\      this._responseHeaders.forEach(function(value, key) {
    \\        lines.push(key + ': ' + value);
    \\      });
    \\      return lines.join('\r\n');
    \\    }
    \\    send(body) {
    \\      var self = this;
    \\      var normalized = normalizeRequest({
    \\        url: self._url,
    \\        method: self._method,
    \\        headers: self._headers,
    \\        body: body,
    \\      }, null, 'xhr');
    \\      var perform = function() {
    \\        try {
    \\          var payload = performBridgeRequest(normalized);
    \\          if (payload && payload.error) throw new Error(payload.error);
    \\          self.status = payload.status || 0;
    \\          self.statusText = '';
    \\          self.responseURL = payload.url || '';
    \\          self.responseText = payload.body || '';
    \\          self.response = self.responseText;
    \\          self._responseHeaders = new Headers({
    \\            'content-type': payload.contentType || '',
    \\          });
    \\          self.readyState = 4;
    \\          self._notifyReadyState();
    \\          if (typeof self.onload === 'function') self.onload();
    \\        } catch (err) {
    \\          self.status = 0;
    \\          self.statusText = String((err && err.message) || err);
    \\          self.readyState = 4;
    \\          self._notifyReadyState();
    \\          if (typeof self.onerror === 'function') self.onerror(err);
    \\        }
    \\      };
    \\
    \\      if (this._async) {
    \\        Promise.resolve().then(perform);
    \\      } else {
    \\        perform();
    \\      }
    \\    }
    \\    abort() {
    \\      this.readyState = 0;
    \\    }
    \\    _notifyReadyState() {
    \\      if (typeof this.onreadystatechange === 'function') this.onreadystatechange();
    \\    }
    \\  }
    \\
    \\  XMLHttpRequest.UNSENT = 0;
    \\  XMLHttpRequest.OPENED = 1;
    \\  XMLHttpRequest.HEADERS_RECEIVED = 2;
    \\  XMLHttpRequest.LOADING = 3;
    \\  XMLHttpRequest.DONE = 4;
    \\
    \\  var __kuriTimerNextId = 1;
    \\  var __kuriTimers = Object.create(null);
    \\
    \\  function __kuriClearTimer(id) {
    \\    if (!Object.prototype.hasOwnProperty.call(__kuriTimers, id)) return;
    \\    __kuriTimers[id].cancelled = true;
    \\    delete __kuriTimers[id];
    \\  }
    \\
    \\  function __kuriScheduleTimer(callback, args, useAnimationFrame) {
    \\    var id = __kuriTimerNextId++;
    \\    var fn = callback;
    \\    if (typeof fn !== 'function') {
    \\      var source = String(callback || '');
    \\      fn = function() {
    \\        return globalThis.eval(source);
    \\      };
    \\    }
    \\    var state = { cancelled: false };
    \\    __kuriTimers[id] = state;
    \\    Promise.resolve().then(function() {
    \\      if (state.cancelled) return;
    \\      try {
    \\        if (useAnimationFrame) {
    \\          fn.apply(globalThis, [Date.now()].concat(args));
    \\        } else {
    \\          fn.apply(globalThis, args);
    \\        }
    \\      } finally {
    \\        delete __kuriTimers[id];
    \\      }
    \\    });
    \\    return id;
    \\  }
    \\
    \\  function queueMicrotask(callback) {
    \\    Promise.resolve().then(callback);
    \\  }
    \\
    \\  function setTimeout(callback, delay) {
    \\    var args = Array.prototype.slice.call(arguments, 2);
    \\    return __kuriScheduleTimer(callback, args, false);
    \\  }
    \\
    \\  function clearTimeout(id) {
    \\    __kuriClearTimer(id);
    \\  }
    \\
    \\  function setInterval(callback, delay) {
    \\    var args = Array.prototype.slice.call(arguments, 2);
    \\    return __kuriScheduleTimer(callback, args, false);
    \\  }
    \\
    \\  function clearInterval(id) {
    \\    __kuriClearTimer(id);
    \\  }
    \\
    \\  function requestAnimationFrame(callback) {
    \\    return __kuriScheduleTimer(callback, [], true);
    \\  }
    \\
    \\  function cancelAnimationFrame(id) {
    \\    __kuriClearTimer(id);
    \\  }
    \\
    \\  if (!globalThis.performance) {
    \\    globalThis.performance = {
    \\      now: function() { return Date.now(); }
    \\    };
    \\  } else if (typeof globalThis.performance.now !== 'function') {
    \\    globalThis.performance.now = function() { return Date.now(); };
    \\  }
    \\
    \\  globalThis.Headers = globalThis.Headers || Headers;
    \\  globalThis.Request = globalThis.Request || Request;
    \\  globalThis.Response = globalThis.Response || Response;
    \\  globalThis.fetch = fetch;
    \\  globalThis.XMLHttpRequest = XMLHttpRequest;
    \\  globalThis.queueMicrotask = queueMicrotask;
    \\  globalThis.setTimeout = setTimeout;
    \\  globalThis.clearTimeout = clearTimeout;
    \\  globalThis.setInterval = setInterval;
    \\  globalThis.clearInterval = clearInterval;
    \\  globalThis.requestAnimationFrame = requestAnimationFrame;
    \\  globalThis.cancelAnimationFrame = cancelAnimationFrame;
    \\  if (globalThis.window) {
    \\    globalThis.window.Headers = globalThis.Headers;
    \\    globalThis.window.Request = globalThis.Request;
    \\    globalThis.window.Response = globalThis.Response;
    \\    globalThis.window.fetch = fetch;
    \\    globalThis.window.XMLHttpRequest = XMLHttpRequest;
    \\    globalThis.window.queueMicrotask = queueMicrotask;
    \\    globalThis.window.setTimeout = setTimeout;
    \\    globalThis.window.clearTimeout = clearTimeout;
    \\    globalThis.window.setInterval = setInterval;
    \\    globalThis.window.clearInterval = clearInterval;
    \\    globalThis.window.requestAnimationFrame = requestAnimationFrame;
    \\    globalThis.window.cancelAnimationFrame = cancelAnimationFrame;
    \\  }
    \\
    \\  if (globalThis.document) {
    \\    Object.defineProperty(globalThis.document, 'cookie', {
    \\      configurable: true,
    \\      enumerable: true,
    \\      get: function() {
    \\        return __kuri_cookie_get();
    \\      },
    \\      set: function(value) {
    \\        __kuri_cookie_set(String(value));
    \\      },
    \\    });
    \\  }
    \\})();
;

test "options active when js or eval requested" {
    try std.testing.expect(!(Options{}).active());
    try std.testing.expect((Options{ .enabled = true }).active());
    try std.testing.expect((Options{ .eval_expression = "document.title" }).active());
    try std.testing.expect((Options{ .wait_selector = "#ready" }).active());
    try std.testing.expect((Options{ .wait_expression = "window.done" }).active());
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

test "inlineScriptSource supports quotes-style HTML strings" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const html =
        "<script>" ++
        "var data = [{ tags: ['life'], author: { name: 'Author' }, text: 'Quote' }];" ++
        "for (var i in data) {" ++
        "  var d = data[i];" ++
        "  var tags = $.map(d['tags'], function(t) { return \"<a class='tag'>\" + t + \"</a>\"; }).join(\" \");" ++
        "  document.write(\"<div class='quote'><span class='text'>\" + d['text'] + \"</span><span>by <small class='author'>\" + d['author']['name'] + \"</small></span><div class='tags'>Tags: \" + tags + \"</div></div>\");" ++
        "}" ++
        "</script>";
    const document = try dom.Document.parse(arena, html);
    const script_id = (try document.querySelector(arena, "script")).?;
    const source = try inlineScriptSource(arena, &document, script_id);

    var engine = try jsengine.JsEngine.init();
    defer engine.deinit();

    try std.testing.expect(engine.exec(
        \\globalThis.$ = {
        \\  map: function(items, fn) {
        \\    var out = [];
        \\    for (var i = 0; i < items.length; i += 1) out.push(fn(items[i], i));
        \\    return out;
        \\  }
        \\};
        \\globalThis.document = { write: function() {} };
    ));
    try std.testing.expect(engine.exec(source));
}

test "wrapEvalExpression trims trailing semicolons" {
    const wrapped = try wrapEvalExpression(std.testing.allocator, "document.title;");
    defer std.testing.allocator.free(wrapped);
    try std.testing.expectEqualStrings("document.title", wrapped);
}

test "wrapEvalExpression lifts statement bodies" {
    const wrapped = try wrapEvalExpression(std.testing.allocator, "const x = 2; return x * 3;");
    defer std.testing.allocator.free(wrapped);
    try std.testing.expect(std.mem.startsWith(u8, wrapped, "(function(){ const x = 2; return x * 3"));
}

test "bridge shim installs fetch and xhr names" {
    try std.testing.expect(std.mem.indexOf(u8, browser_bridge_js, "globalThis.fetch = fetch;") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser_bridge_js, "globalThis.XMLHttpRequest = XMLHttpRequest;") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser_bridge_js, "globalThis.setTimeout = setTimeout;") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser_bridge_js, "globalThis.requestAnimationFrame = requestAnimationFrame;") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser_bridge_js, "document, 'cookie'") != null);
}

test "evaluatePage drains timer and microtask shims" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var session = fetch.Session.init(arena, "kuri-browser-test");
    defer session.deinit();

    const html =
        "<html><head><title>start</title></head><body>" ++
        "<script>" ++
        "window.__timeout = 0;" ++
        "window.__micro = 0;" ++
        "window.__raf = 0;" ++
        "setTimeout(function() { window.__timeout = 1; document.title = 'timeout'; }, 0);" ++
        "queueMicrotask(function() { window.__micro = 1; });" ++
        "requestAnimationFrame(function() { window.__raf = 1; });" ++
        "</script>" ++
        "</body></html>";
    var document = try dom.Document.parse(arena, html);
    defer document.deinit();

    const result = try evaluatePage(
        arena,
        &session,
        &document,
        html,
        "https://example.com",
        &[_]model.Resource{},
        .{
            .enabled = true,
            .eval_expression = "[window.__timeout, window.__micro, window.__raf, document.title].join('|')",
        },
    );

    try std.testing.expectEqualStrings("1|1|1|timeout", result.eval_result);
    try std.testing.expectEqualStrings("timeout", result.document_title);
}

test "evaluatePage reports wait selector satisfaction" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var session = fetch.Session.init(arena, "kuri-browser-test");
    defer session.deinit();

    const html =
        "<html><body>" ++
        "<script>" ++
        "setTimeout(function() {" ++
        "  var node = document.createElement('div');" ++
        "  node.id = 'ready';" ++
        "  document.body.appendChild(node);" ++
        "}, 0);" ++
        "</script>" ++
        "</body></html>";
    var document = try dom.Document.parse(arena, html);
    defer document.deinit();

    const result = try evaluatePage(
        arena,
        &session,
        &document,
        html,
        "https://example.com",
        &[_]model.Resource{},
        .{
            .wait_selector = "#ready",
            .eval_expression = "String(!!document.querySelector('#ready'))",
        },
    );

    try std.testing.expect(result.wait_satisfied);
    try std.testing.expect(result.wait_polls > 0);
    try std.testing.expectEqualStrings("true", result.eval_result);
}
