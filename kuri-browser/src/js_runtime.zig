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

    pub fn active(self: Options) bool {
        return self.enabled or self.eval_expression != null;
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

    report.output = jsengine.outputAlloc(&engine, allocator) orelse "";
    report.document_title = engine.evalAlloc(allocator, "document.title") orelse "";

    if (options.eval_expression) |expression| {
        const eval_ok = try evaluateExpression(allocator, &engine, expression, &report);
        if (!eval_ok and report.error_message.len == 0) {
            report.error_message = try allocator.dupe(u8, "JsEvalFailed");
        }
        report.eval_result = engine.evalAlloc(allocator, "globalThis.__kuri_eval_result || ''") orelse "";
    }

    return report;
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
            try executeScriptSource(allocator, engine, script_body, report);
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

        try executeScriptSource(allocator, engine, trimmed, report);
        return;
    }

    const inline_source = try inlineScriptSource(allocator, document, node_id);
    defer allocator.free(inline_source);

    const trimmed = std.mem.trim(u8, inline_source, " \t\r\n");
    if (trimmed.len == 0) return;

    report.inline_scripts += 1;
    try executeScriptSource(allocator, engine, trimmed, report);
}

fn executeScriptSource(
    allocator: std.mem.Allocator,
    engine: *jsengine.JsEngine,
    source: []const u8,
    report: *model.JsExecution,
) !void {
    if (engine.exec(source)) {
        report.executed_scripts += 1;
    } else {
        report.failed_scripts += 1;
        try rememberCurrentException(allocator, engine.ctx, report);
    }
    try drainPendingJobs(allocator, engine, report);
}

fn evaluateExpression(
    allocator: std.mem.Allocator,
    engine: *jsengine.JsEngine,
    expression: []const u8,
    report: *model.JsExecution,
) !bool {
    const wrapped = try wrapEvalExpression(allocator, expression);
    defer allocator.free(wrapped);

    const script = try std.fmt.allocPrint(
        allocator,
        \\globalThis.__kuri_eval_result = "";
        \\globalThis.__kuri_eval_error = "";
        \\Promise.resolve((function() {{
        \\  try {{
        \\    return {s};
        \\  }} catch (e) {{
        \\    globalThis.__kuri_eval_error = String((e && e.stack) || (e && e.message) || e);
        \\    return "";
        \\  }}
        \\}})()).then(function(value) {{
        \\  globalThis.__kuri_eval_result = value == null ? "" : String(value);
        \\}}, function(err) {{
        \\  globalThis.__kuri_eval_error = String((err && err.stack) || (err && err.message) || err);
        \\}});
    , .{wrapped});
    defer allocator.free(script);

    if (!engine.exec(script)) {
        try rememberCurrentException(allocator, engine.ctx, report);
        return false;
    }

    try drainPendingJobs(allocator, engine, report);

    const eval_error = engine.evalAlloc(allocator, "globalThis.__kuri_eval_error || ''") orelse return true;
    if (eval_error.len == 0) {
        allocator.free(eval_error);
        return true;
    }
    if (report.error_message.len == 0) {
        report.error_message = eval_error;
    } else {
        allocator.free(eval_error);
    }
    return false;
}

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

    const stack = exc.getPropertyStr(ctx, "stack");
    defer stack.deinit(ctx);
    if (!stack.isException()) {
        if (stack.toCString(ctx)) |value| {
            defer ctx.freeCString(value);
            try rememberError(allocator, report, std.mem.span(value));
            return;
        }
    }

    const message = exc.getPropertyStr(ctx, "message");
    defer message.deinit(ctx);
    if (!message.isException()) {
        if (message.toCString(ctx)) |value| {
            defer ctx.freeCString(value);
            try rememberError(allocator, report, std.mem.span(value));
            return;
        }
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
    \\  globalThis.Headers = globalThis.Headers || Headers;
    \\  globalThis.Request = globalThis.Request || Request;
    \\  globalThis.Response = globalThis.Response || Response;
    \\  globalThis.fetch = fetch;
    \\  globalThis.XMLHttpRequest = XMLHttpRequest;
    \\  if (globalThis.window) {
    \\    globalThis.window.Headers = globalThis.Headers;
    \\    globalThis.window.Request = globalThis.Request;
    \\    globalThis.window.Response = globalThis.Response;
    \\    globalThis.window.fetch = fetch;
    \\    globalThis.window.XMLHttpRequest = XMLHttpRequest;
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
    try std.testing.expect(std.mem.indexOf(u8, browser_bridge_js, "document, 'cookie'") != null);
}
