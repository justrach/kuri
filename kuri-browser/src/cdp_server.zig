const std = @import("std");
const core = @import("core.zig");
const js_runtime = @import("js_runtime.zig");
const model = @import("model.zig");
const net = std.Io.net;

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9333,
};

const browser_id = "kuri-browser";
const page_id = "kuri-page-1";
const frame_id = "kuri-frame-1";
const loader_id = "kuri-loader-1";
const session_id = "kuri-session-1";
const browser_context_id = "kuri-context-1";
const max_ws_message = 8192;

const CdpState = struct {
    allocator: std.mem.Allocator,
    runtime: core.BrowserRuntime,
    current_url: []const u8 = "about:blank",
    title: []const u8 = "Kuri Browser",
    page: ?model.Page = null,

    fn init(allocator: std.mem.Allocator) CdpState {
        return .{
            .allocator = allocator,
            .runtime = core.BrowserRuntime.init(allocator),
        };
    }

    fn navigate(self: *CdpState, url: []const u8) !void {
        if (std.mem.eql(u8, url, "about:blank")) {
            self.current_url = "about:blank";
            self.title = "Kuri Browser";
            self.page = null;
            return;
        }
        const page = try self.runtime.loadPageWithOptions(url, .{ .enabled = true });
        self.current_url = page.url;
        self.title = page.title;
        self.page = page;
    }
};

const CdpRequest = struct {
    id: i64,
    method: []const u8,
    params: ?std.json.Value = null,
    session_id: ?[]const u8 = null,
};

const DispatchResult = struct {
    response: []const u8,
    session_id: ?[]const u8 = null,
    navigated: bool = false,
    runtime_enabled: bool = false,
    target_created: bool = false,
};

pub fn serve(gpa: std.mem.Allocator, options: Options) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const address = try net.IpAddress.parseIp4(options.host, options.port);
    var tcp_server = try net.IpAddress.listen(&address, io, .{
        .reuse_address = true,
    });
    defer tcp_server.deinit(io);

    std.debug.print("kuri-browser CDP server listening on http://{s}:{d}\n", .{ options.host, options.port });
    std.debug.print("discovery: http://{s}:{d}/json/version\n", .{ options.host, options.port });

    while (true) {
        const stream = tcp_server.accept(io) catch |err| {
            std.log.err("accept error: {s}", .{@errorName(err)});
            continue;
        };

        const thread = std.Thread.spawn(.{}, handleConnection, .{ gpa, options, stream }) catch |err| {
            std.log.err("thread spawn error: {s}", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(gpa: std.mem.Allocator, options: Options, stream: net.Stream) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    defer stream.close(io);

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var read_buf: [8192]u8 = undefined;
    var net_reader = net.Stream.Reader.init(stream, io, &read_buf);
    var write_buf: [8192]u8 = undefined;
    var net_writer = net.Stream.Writer.init(stream, io, &write_buf);

    var http_server = std.http.Server.init(&net_reader.interface, &net_writer.interface);
    while (true) {
        var request = http_server.receiveHead() catch |err| {
            if (err == error.EndOfStream) return;
            std.log.debug("receiveHead error: {s}", .{@errorName(err)});
            return;
        };

        const connection_taken = route(&request, arena, options);
        if (connection_taken or !request.head.keep_alive) return;
        _ = arena_impl.reset(.retain_capacity);
    }
}

fn route(request: *std.http.Server.Request, arena: std.mem.Allocator, options: Options) bool {
    const target = request.head.target;
    const clean_path = if (std.mem.indexOfScalar(u8, target, '?')) |idx| target[0..idx] else target;

    if (!std.mem.eql(u8, @tagName(request.head.method), "GET") and
        !std.mem.eql(u8, @tagName(request.head.method), "PUT"))
    {
        sendJson(request, "{\"error\":\"method not allowed\"}", 405);
        return false;
    }

    if (std.mem.eql(u8, clean_path, "/health")) {
        sendJson(request, "{\"status\":\"ok\",\"service\":\"kuri-browser-cdp\"}", 200);
        return false;
    }
    if (std.mem.eql(u8, clean_path, "/json/version")) {
        const body = versionJson(arena, options) catch {
            sendJson(request, "{\"error\":\"internal server error\"}", 500);
            return false;
        };
        sendJson(request, body, 200);
        return false;
    }
    if (std.mem.eql(u8, clean_path, "/json") or std.mem.eql(u8, clean_path, "/json/list")) {
        const body = listJson(arena, options, "about:blank") catch {
            sendJson(request, "{\"error\":\"internal server error\"}", 500);
            return false;
        };
        sendJson(request, body, 200);
        return false;
    }
    if (std.mem.eql(u8, clean_path, "/json/new")) {
        const url = targetUrlFromQuery(target);
        const body = targetJson(arena, options, url) catch {
            sendJson(request, "{\"error\":\"internal server error\"}", 500);
            return false;
        };
        sendJson(request, body, 200);
        return false;
    }
    if (std.mem.eql(u8, clean_path, "/json/protocol")) {
        sendJson(request, protocolJson(), 200);
        return false;
    }
    if (std.mem.startsWith(u8, clean_path, "/devtools/")) {
        return upgradeAndServeCdp(request, arena);
    }

    sendJson(request, "{\"error\":\"not found\"}", 404);
    return false;
}

fn upgradeAndServeCdp(request: *std.http.Server.Request, arena: std.mem.Allocator) bool {
    const key = switch (request.upgradeRequested()) {
        .websocket => |maybe_key| maybe_key orelse {
            sendJson(request, "{\"error\":\"missing websocket key\"}", 400);
            return false;
        },
        .other, .none => {
            sendJson(request, "{\"error\":\"websocket upgrade required\"}", 426);
            return false;
        },
    };

    var ws = request.respondWebSocket(.{
        .key = key,
        .extra_headers = &.{
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
    }) catch |err| {
        std.log.err("websocket upgrade failed: {s}", .{@errorName(err)});
        return true;
    };
    ws.flush() catch return true;

    runCdpWebSocket(arena, &ws) catch |err| {
        if (err != error.ConnectionClose and err != error.EndOfStream) {
            std.log.debug("cdp websocket closed: {s}", .{@errorName(err)});
        }
    };
    return true;
}

fn runCdpWebSocket(allocator: std.mem.Allocator, ws: *std.http.Server.WebSocket) !void {
    var state = CdpState.init(allocator);
    while (true) {
        const message = try ws.readSmallMessage();
        switch (message.opcode) {
            .ping => {
                try ws.writeMessage(message.data, .pong);
                continue;
            },
            .text, .binary => {},
            .connection_close => return error.ConnectionClose,
            else => continue,
        }
        if (message.data.len > max_ws_message) return error.MessageOversize;

        const dispatch = dispatchCdpMessage(allocator, &state, message.data) catch |err| blk: {
            break :blk DispatchResult{
                .response = try errorResponse(allocator, 0, null, -32700, @errorName(err)),
            };
        };
        try ws.writeMessage(dispatch.response, .text);

        if (dispatch.runtime_enabled) {
            try sendRuntimeContextEvent(ws, allocator, dispatch.session_id, &state);
        }
        if (dispatch.target_created) {
            try sendTargetCreatedEvent(ws, allocator, dispatch.session_id, &state);
        }
        if (dispatch.navigated) {
            try sendNavigationEvents(ws, allocator, dispatch.session_id, &state);
        }
    }
}

fn dispatchCdpMessage(allocator: std.mem.Allocator, state: *CdpState, raw: []const u8) !DispatchResult {
    const req = try parseCdpRequest(allocator, raw);
    const response = try handleCdpRequest(allocator, state, req);
    return response;
}

pub fn dispatchCdpMessageForTest(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var state = CdpState.init(allocator);
    return (try dispatchCdpMessage(allocator, &state, raw)).response;
}

fn parseCdpRequest(allocator: std.mem.Allocator, raw: []const u8) !CdpRequest {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, raw, .{});
    const root = switch (parsed) {
        .object => |obj| obj,
        else => return error.InvalidCdpRequest,
    };
    const method_value = root.get("method") orelse return error.InvalidCdpRequest;
    const method = switch (method_value) {
        .string => |value| value,
        else => return error.InvalidCdpRequest,
    };
    const id_value = root.get("id") orelse return error.InvalidCdpRequest;
    const id = switch (id_value) {
        .integer => |value| value,
        .float => |value| @as(i64, @intFromFloat(value)),
        else => return error.InvalidCdpRequest,
    };
    const sid = if (root.get("sessionId")) |value| switch (value) {
        .string => |s| s,
        else => null,
    } else null;
    return .{
        .id = id,
        .method = method,
        .params = root.get("params"),
        .session_id = sid,
    };
}

fn handleCdpRequest(allocator: std.mem.Allocator, state: *CdpState, req: CdpRequest) !DispatchResult {
    if (std.mem.eql(u8, req.method, "Browser.getVersion")) {
        return .{ .response = try successResponse(allocator, req.id, req.session_id,
            \\{"protocolVersion":"1.3","product":"KuriBrowser/0.0.0","revision":"kuri-browser","userAgent":"kuri-browser/0.0.0","jsVersion":"QuickJS with V8-shaped CDP Runtime objects"}
        ) };
    }
    if (std.mem.eql(u8, req.method, "Browser.close")) {
        return .{ .response = try successResponse(allocator, req.id, req.session_id, "{}") };
    }

    if (std.mem.eql(u8, req.method, "Target.getBrowserContexts")) {
        return .{ .response = try successResponse(allocator, req.id, req.session_id,
            \\{"browserContextIds":["kuri-context-1"]}
        ) };
    }
    if (std.mem.eql(u8, req.method, "Target.getTargets")) {
        const info = try targetInfoJson(allocator, state);
        const result = try std.fmt.allocPrint(allocator, "{{\"targetInfos\":[{s}]}}", .{info});
        return .{ .response = try successResponse(allocator, req.id, req.session_id, result) };
    }
    if (std.mem.eql(u8, req.method, "Target.createTarget")) {
        const url = paramString(req.params, "url") orelse "about:blank";
        state.current_url = url;
        state.title = "Kuri Browser";
        state.page = null;
        return .{
            .response = try successResponse(allocator, req.id, req.session_id,
                \\{"targetId":"kuri-page-1"}
            ),
            .session_id = req.session_id,
            .target_created = true,
        };
    }
    if (std.mem.eql(u8, req.method, "Target.attachToTarget") or
        std.mem.eql(u8, req.method, "Target.attachToBrowserTarget"))
    {
        return .{ .response = try successResponse(allocator, req.id, req.session_id,
            \\{"sessionId":"kuri-session-1"}
        ) };
    }
    if (std.mem.eql(u8, req.method, "Target.setDiscoverTargets") or
        std.mem.eql(u8, req.method, "Target.setAutoAttach") or
        std.mem.eql(u8, req.method, "Target.activateTarget"))
    {
        return .{ .response = try successResponse(allocator, req.id, req.session_id, "{}") };
    }
    if (std.mem.eql(u8, req.method, "Target.closeTarget")) {
        return .{ .response = try successResponse(allocator, req.id, req.session_id,
            \\{"success":true}
        ) };
    }

    if (std.mem.eql(u8, req.method, "Runtime.enable")) {
        return .{
            .response = try successResponse(allocator, req.id, req.session_id, "{}"),
            .session_id = req.session_id,
            .runtime_enabled = true,
        };
    }
    if (std.mem.eql(u8, req.method, "Runtime.evaluate")) {
        const expression = paramString(req.params, "expression") orelse "undefined";
        const eval = if (state.page) |*page|
            try js_runtime.evaluateExpressionOnPage(allocator, page, expression)
        else
            try js_runtime.evaluateExpressionInHtml(allocator, "<html><head><title>Kuri Browser</title></head><body></body></html>", state.current_url, expression);
        const remote = try remoteObjectJson(allocator, eval.eval_result, eval.error_message);
        const result = try std.fmt.allocPrint(allocator, "{{\"result\":{s}}}", .{remote});
        return .{ .response = try successResponse(allocator, req.id, req.session_id, result) };
    }
    if (std.mem.eql(u8, req.method, "Runtime.callFunctionOn")) {
        return .{ .response = try successResponse(allocator, req.id, req.session_id,
            \\{"result":{"type":"undefined","description":"undefined"}}
        ) };
    }
    if (std.mem.eql(u8, req.method, "Runtime.getProperties")) {
        return .{ .response = try successResponse(allocator, req.id, req.session_id,
            \\{"result":[],"internalProperties":[]}
        ) };
    }
    if (std.mem.eql(u8, req.method, "Runtime.releaseObject") or
        std.mem.eql(u8, req.method, "Runtime.releaseObjectGroup"))
    {
        return .{ .response = try successResponse(allocator, req.id, req.session_id, "{}") };
    }

    if (std.mem.eql(u8, req.method, "Page.enable") or
        std.mem.eql(u8, req.method, "Network.enable") or
        std.mem.eql(u8, req.method, "DOM.enable") or
        std.mem.eql(u8, req.method, "Log.enable") or
        std.mem.eql(u8, req.method, "Performance.enable"))
    {
        return .{ .response = try successResponse(allocator, req.id, req.session_id, "{}") };
    }
    if (std.mem.eql(u8, req.method, "Page.getFrameTree")) {
        const result = try frameTreeJson(allocator, state);
        return .{ .response = try successResponse(allocator, req.id, req.session_id, result) };
    }
    if (std.mem.eql(u8, req.method, "Page.navigate")) {
        const url = paramString(req.params, "url") orelse return .{
            .response = try errorResponse(allocator, req.id, req.session_id, -32602, "Page.navigate requires params.url"),
        };
        state.navigate(url) catch |err| return .{
            .response = try errorResponse(allocator, req.id, req.session_id, -32000, @errorName(err)),
        };
        const result = try std.fmt.allocPrint(allocator, "{{\"frameId\":\"{s}\",\"loaderId\":\"{s}\"}}", .{ frame_id, loader_id });
        return .{
            .response = try successResponse(allocator, req.id, req.session_id, result),
            .session_id = req.session_id,
            .navigated = true,
        };
    }
    if (std.mem.eql(u8, req.method, "Page.captureScreenshot")) {
        return .{ .response = try errorResponse(allocator, req.id, req.session_id, -32000, "native screenshot is not implemented; use kuri-browser screenshot --compress fallback") };
    }

    if (std.mem.eql(u8, req.method, "DOM.getDocument")) {
        const result = try documentNodeJson(allocator, state);
        return .{ .response = try successResponse(allocator, req.id, req.session_id, result) };
    }
    if (std.mem.eql(u8, req.method, "DOM.querySelector")) {
        return .{ .response = try successResponse(allocator, req.id, req.session_id,
            \\{"nodeId":0}
        ) };
    }
    if (std.mem.eql(u8, req.method, "DOM.resolveNode")) {
        return .{ .response = try successResponse(allocator, req.id, req.session_id,
            \\{"object":{"type":"undefined","description":"undefined"}}
        ) };
    }

    if (std.mem.startsWith(u8, req.method, "Input.")) {
        return .{ .response = try successResponse(allocator, req.id, req.session_id, "{}") };
    }

    return .{ .response = try errorResponse(allocator, req.id, req.session_id, -32601, "method not found") };
}

fn paramString(params: ?std.json.Value, key: []const u8) ?[]const u8 {
    const value = paramValue(params, key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn paramValue(params: ?std.json.Value, key: []const u8) ?std.json.Value {
    const params_value = params orelse return null;
    const obj = switch (params_value) {
        .object => |o| o,
        else => return null,
    };
    return obj.get(key);
}

fn successResponse(allocator: std.mem.Allocator, id: i64, sid: ?[]const u8, result: []const u8) ![]const u8 {
    if (sid) |session| {
        const session_json = try jsonStringLiteral(allocator, session);
        return std.fmt.allocPrint(allocator, "{{\"id\":{d},\"sessionId\":{s},\"result\":{s}}}", .{ id, session_json, result });
    }
    return std.fmt.allocPrint(allocator, "{{\"id\":{d},\"result\":{s}}}", .{ id, result });
}

fn errorResponse(allocator: std.mem.Allocator, id: i64, sid: ?[]const u8, code: i32, message: []const u8) ![]const u8 {
    const msg = try jsonStringLiteral(allocator, message);
    if (sid) |session| {
        const session_json = try jsonStringLiteral(allocator, session);
        return std.fmt.allocPrint(allocator, "{{\"id\":{d},\"sessionId\":{s},\"error\":{{\"code\":{d},\"message\":{s}}}}}", .{ id, session_json, code, msg });
    }
    return std.fmt.allocPrint(allocator, "{{\"id\":{d},\"error\":{{\"code\":{d},\"message\":{s}}}}}", .{ id, code, msg });
}

fn remoteObjectJson(allocator: std.mem.Allocator, value: []const u8, error_message: []const u8) ![]const u8 {
    if (error_message.len != 0) {
        const description = try jsonStringLiteral(allocator, error_message);
        return std.fmt.allocPrint(allocator, "{{\"type\":\"object\",\"subtype\":\"error\",\"description\":{s}}}", .{description});
    }
    if (std.mem.eql(u8, value, "undefined")) return allocator.dupe(u8, "{\"type\":\"undefined\",\"description\":\"undefined\"}");
    if (std.mem.eql(u8, value, "null")) return allocator.dupe(u8, "{\"type\":\"object\",\"subtype\":\"null\",\"value\":null,\"description\":\"null\"}");
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) {
        return std.fmt.allocPrint(allocator, "{{\"type\":\"boolean\",\"value\":{s},\"description\":\"{s}\"}}", .{ value, value });
    }
    if (isUnserializableNumber(value)) {
        const quoted = try jsonStringLiteral(allocator, value);
        return std.fmt.allocPrint(allocator, "{{\"type\":\"number\",\"unserializableValue\":{s},\"description\":{s}}}", .{ quoted, quoted });
    }
    if (looksNumeric(value)) {
        return std.fmt.allocPrint(allocator, "{{\"type\":\"number\",\"value\":{s},\"description\":\"{s}\"}}", .{ value, value });
    }
    const quoted = try jsonStringLiteral(allocator, value);
    return std.fmt.allocPrint(allocator, "{{\"type\":\"string\",\"value\":{s},\"description\":{s}}}", .{ quoted, quoted });
}

fn isUnserializableNumber(value: []const u8) bool {
    return std.mem.eql(u8, value, "NaN") or
        std.mem.eql(u8, value, "Infinity") or
        std.mem.eql(u8, value, "-Infinity") or
        std.mem.eql(u8, value, "-0");
}

fn looksNumeric(value: []const u8) bool {
    if (value.len == 0) return false;
    const number = std.fmt.parseFloat(f64, value) catch return false;
    if (!std.math.isFinite(number)) return false;
    return true;
}

fn targetInfoJson(allocator: std.mem.Allocator, state: *const CdpState) ![]const u8 {
    const title = try jsonStringLiteral(allocator, state.title);
    const url = try jsonStringLiteral(allocator, state.current_url);
    return std.fmt.allocPrint(
        allocator,
        "{{\"targetId\":\"{s}\",\"type\":\"page\",\"title\":{s},\"url\":{s},\"attached\":false,\"canAccessOpener\":false,\"browserContextId\":\"{s}\"}}",
        .{ page_id, title, url, browser_context_id },
    );
}

fn frameTreeJson(allocator: std.mem.Allocator, state: *const CdpState) ![]const u8 {
    const url = try jsonStringLiteral(allocator, state.current_url);
    return std.fmt.allocPrint(
        allocator,
        "{{\"frameTree\":{{\"frame\":{{\"id\":\"{s}\",\"loaderId\":\"{s}\",\"url\":{s},\"securityOrigin\":{s},\"mimeType\":\"text/html\"}}}}}}",
        .{ frame_id, loader_id, url, url },
    );
}

fn documentNodeJson(allocator: std.mem.Allocator, state: *const CdpState) ![]const u8 {
    const url = try jsonStringLiteral(allocator, state.current_url);
    return std.fmt.allocPrint(
        allocator,
        "{{\"root\":{{\"nodeId\":1,\"backendNodeId\":1,\"nodeType\":9,\"nodeName\":\"#document\",\"localName\":\"\",\"nodeValue\":\"\",\"documentURL\":{s},\"children\":[]}}}}",
        .{url},
    );
}

fn sendRuntimeContextEvent(
    ws: *std.http.Server.WebSocket,
    allocator: std.mem.Allocator,
    sid: ?[]const u8,
    state: *const CdpState,
) !void {
    const origin = try jsonStringLiteral(allocator, state.current_url);
    const params = try std.fmt.allocPrint(
        allocator,
        "{{\"context\":{{\"id\":1,\"origin\":{s},\"name\":\"\",\"uniqueId\":\"kuri-runtime-1\",\"auxData\":{{\"isDefault\":true,\"type\":\"default\",\"frameId\":\"{s}\"}}}}}}",
        .{ origin, frame_id },
    );
    try sendEvent(ws, allocator, sid, "Runtime.executionContextCreated", params);
}

fn sendTargetCreatedEvent(
    ws: *std.http.Server.WebSocket,
    allocator: std.mem.Allocator,
    sid: ?[]const u8,
    state: *const CdpState,
) !void {
    const info = try targetInfoJson(allocator, state);
    const params = try std.fmt.allocPrint(allocator, "{{\"targetInfo\":{s}}}", .{info});
    try sendEvent(ws, allocator, sid, "Target.targetCreated", params);
}

fn sendNavigationEvents(
    ws: *std.http.Server.WebSocket,
    allocator: std.mem.Allocator,
    sid: ?[]const u8,
    state: *const CdpState,
) !void {
    const url = try jsonStringLiteral(allocator, state.current_url);
    const title = try jsonStringLiteral(allocator, state.title);
    const frame = try std.fmt.allocPrint(
        allocator,
        "{{\"frame\":{{\"id\":\"{s}\",\"loaderId\":\"{s}\",\"url\":{s},\"securityOrigin\":{s},\"mimeType\":\"text/html\",\"name\":\"\",\"unreachableUrl\":\"\"}}}}",
        .{ frame_id, loader_id, url, url },
    );
    const lifecycle = try std.fmt.allocPrint(allocator, "{{\"frameId\":\"{s}\",\"loaderId\":\"{s}\",\"name\":\"load\",\"timestamp\":0}}", .{ frame_id, loader_id });
    const title_params = try std.fmt.allocPrint(allocator, "{{\"title\":{s}}}", .{title});
    try sendEvent(ws, allocator, sid, "Page.frameStartedLoading", try std.fmt.allocPrint(allocator, "{{\"frameId\":\"{s}\"}}", .{frame_id}));
    try sendEvent(ws, allocator, sid, "Page.frameNavigated", frame);
    try sendEvent(ws, allocator, sid, "Page.lifecycleEvent", lifecycle);
    try sendEvent(ws, allocator, sid, "Page.domContentEventFired", "{\"timestamp\":0}");
    try sendEvent(ws, allocator, sid, "Page.loadEventFired", "{\"timestamp\":0}");
    try sendEvent(ws, allocator, sid, "Page.frameStoppedLoading", try std.fmt.allocPrint(allocator, "{{\"frameId\":\"{s}\"}}", .{frame_id}));
    try sendEvent(ws, allocator, sid, "Page.titleChanged", title_params);
}

fn sendEvent(
    ws: *std.http.Server.WebSocket,
    allocator: std.mem.Allocator,
    sid: ?[]const u8,
    method: []const u8,
    params: []const u8,
) !void {
    const method_json = try jsonStringLiteral(allocator, method);
    const body = if (sid) |session| blk: {
        const session_json = try jsonStringLiteral(allocator, session);
        break :blk try std.fmt.allocPrint(allocator, "{{\"sessionId\":{s},\"method\":{s},\"params\":{s}}}", .{ session_json, method_json, params });
    } else try std.fmt.allocPrint(allocator, "{{\"method\":{s},\"params\":{s}}}", .{ method_json, params });
    try ws.writeMessage(body, .text);
}

pub fn versionJson(allocator: std.mem.Allocator, options: Options) ![]const u8 {
    const ws = try browserWsUrl(allocator, options);
    return jsonObject(allocator, &.{
        .{ .key = "Browser", .value = "KuriBrowser/0.0.0" },
        .{ .key = "Protocol-Version", .value = "1.3" },
        .{ .key = "User-Agent", .value = "kuri-browser/0.0.0" },
        .{ .key = "V8-Version", .value = "QuickJS with V8-shaped CDP Runtime objects" },
        .{ .key = "WebKit-Version", .value = "kuri-native" },
        .{ .key = "webSocketDebuggerUrl", .value = ws },
    });
}

pub fn listJson(allocator: std.mem.Allocator, options: Options, url: []const u8) ![]const u8 {
    const target = try targetJson(allocator, options, url);
    return std.fmt.allocPrint(allocator, "[{s}]", .{target});
}

pub fn targetJson(allocator: std.mem.Allocator, options: Options, url: []const u8) ![]const u8 {
    const ws = try pageWsUrl(allocator, options);
    return jsonObject(allocator, &.{
        .{ .key = "id", .value = page_id },
        .{ .key = "type", .value = "page" },
        .{ .key = "title", .value = "Kuri Browser" },
        .{ .key = "url", .value = if (url.len == 0) "about:blank" else url },
        .{ .key = "webSocketDebuggerUrl", .value = ws },
    });
}

fn browserWsUrl(allocator: std.mem.Allocator, options: Options) ![]const u8 {
    return std.fmt.allocPrint(allocator, "ws://{s}:{d}/devtools/browser/{s}", .{ options.host, options.port, browser_id });
}

fn pageWsUrl(allocator: std.mem.Allocator, options: Options) ![]const u8 {
    return std.fmt.allocPrint(allocator, "ws://{s}:{d}/devtools/page/{s}", .{ options.host, options.port, page_id });
}

const JsonPair = struct {
    key: []const u8,
    value: []const u8,
};

fn jsonObject(allocator: std.mem.Allocator, pairs: []const JsonPair) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeByte('{');
    for (pairs, 0..) |pair, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(pair.key, .{}, &out.writer);
        try out.writer.writeByte(':');
        try std.json.Stringify.value(pair.value, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    return allocator.dupe(u8, out.written());
}

fn jsonStringLiteral(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

fn protocolJson() []const u8 {
    return
    \\{"version":{"major":"1","minor":"3"},"domains":[
    \\{"domain":"Browser","experimental":false,"deprecated":false,"commands":[{"name":"getVersion"},{"name":"close"}],"events":[]},
    \\{"domain":"Target","experimental":false,"deprecated":false,"commands":[{"name":"getTargets"},{"name":"createTarget"},{"name":"attachToTarget"},{"name":"setDiscoverTargets"},{"name":"setAutoAttach"}],"events":[{"name":"targetCreated"}]},
    \\{"domain":"Page","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"navigate"},{"name":"getFrameTree"}],"events":[{"name":"frameNavigated"},{"name":"loadEventFired"}]},
    \\{"domain":"Runtime","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"evaluate"},{"name":"callFunctionOn"},{"name":"getProperties"},{"name":"releaseObject"}],"events":[{"name":"executionContextCreated"}]},
    \\{"domain":"Network","experimental":false,"deprecated":false,"commands":[{"name":"enable"}],"events":[]},
    \\{"domain":"DOM","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"getDocument"},{"name":"querySelector"},{"name":"resolveNode"}],"events":[]},
    \\{"domain":"Input","experimental":false,"deprecated":false,"commands":[{"name":"dispatchMouseEvent"},{"name":"dispatchKeyEvent"}],"events":[]}
    \\]}
    ;
}

fn targetUrlFromQuery(target: []const u8) []const u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return "about:blank";
    const query = target[query_start + 1 ..];
    if (query.len == 0) return "about:blank";
    if (std.mem.startsWith(u8, query, "url=")) return query["url=".len..];
    return query;
}

fn sendJson(request: *std.http.Server.Request, body: []const u8, status_code: u10) void {
    const status: std.http.Status = @enumFromInt(status_code);
    request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
    }) catch |err| {
        std.log.err("failed to respond: {s}", .{@errorName(err)});
    };
}

test "dispatch handles Browser.getVersion" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const response = try dispatchCdpMessageForTest(arena_impl.allocator(), "{\"id\":1,\"method\":\"Browser.getVersion\"}");
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "V8-shaped") != null);
}

test "dispatch handles Runtime.evaluate with V8-shaped remote object" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const response = try dispatchCdpMessageForTest(arena_impl.allocator(), "{\"id\":2,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"1 + 2\"}}");
    try std.testing.expect(std.mem.indexOf(u8, response, "\"type\":\"number\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"value\":3") != null);
}

test "remote object handles V8-style unserializable numbers" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const response = try dispatchCdpMessageForTest(arena_impl.allocator(), "{\"id\":3,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"NaN\"}}");
    try std.testing.expect(std.mem.indexOf(u8, response, "\"type\":\"number\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"unserializableValue\":\"NaN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"value\":NaN") == null);
}
