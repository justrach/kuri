const std = @import("std");
const core = @import("core.zig");
const css = @import("css.zig");
const dom = @import("dom.zig");
const engine = @import("engine.zig");
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
const debugger_id = "kuri-debugger-1";
const isolate_id = "kuri-isolate-1";
const window_id: i32 = 1;
const max_ws_message: usize = 65536;

const Cookie = struct {
    name: []const u8,
    value: []const u8 = "",
    domain: []const u8 = "",
    path: []const u8 = "/",
    secure: bool = false,
    http_only: bool = false,
    same_site: []const u8 = "",
    expires: f64 = -1,
    url: []const u8 = "",
};

const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

const NewDocScript = struct {
    id: []const u8,
    source: []const u8,
    world_name: []const u8 = "",
};

const ObjectHandleKind = enum { expression, dom_node };

const ObjectHandle = struct {
    id: u64,
    kind: ObjectHandleKind,
    expression: []const u8 = "",
    dom_node_id: dom.NodeId = 0,
};

const CompiledScript = struct {
    id: []const u8,
    source: []const u8,
};


const InputOverride = struct {
    node_id: dom.NodeId,
    value: []const u8,
};
const CdpState = struct {
    allocator: std.mem.Allocator,
    runtime: core.BrowserRuntime,
    current_url: []const u8 = "about:blank",
    title: []const u8 = "Kuri Browser",
    page: ?model.Page = null,

    page_enabled: bool = false,
    runtime_enabled: bool = false,
    network_enabled: bool = false,
    dom_enabled: bool = false,
    css_enabled: bool = false,
    log_enabled: bool = false,
    inspector_enabled: bool = false,
    security_enabled: bool = false,
    fetch_enabled: bool = false,
    debugger_enabled: bool = false,
    lifecycle_events_enabled: bool = false,

    user_agent_override: ?[]const u8 = null,
    accept_language_override: ?[]const u8 = null,
    platform_override: ?[]const u8 = null,
    locale_override: ?[]const u8 = null,
    timezone_override: ?[]const u8 = null,
    emulated_media: ?[]const u8 = null,
    viewport_width: u32 = 1280,
    viewport_height: u32 = 720,
    device_scale_factor: f64 = 1.0,
    mobile: bool = false,
    bypass_csp: bool = false,
    cache_disabled: bool = false,
    script_execution_disabled: bool = false,
    request_interception_enabled: bool = false,
    download_behavior: []const u8 = "default",
    download_path: []const u8 = "",

    window_left: i32 = 0,
    window_top: i32 = 0,
    window_width: u32 = 1280,
    window_height: u32 = 720,
    window_state: []const u8 = "normal",

    new_doc_scripts: std.ArrayList(NewDocScript) = .empty,
    new_doc_script_seq: u64 = 0,

    cookies: std.ArrayList(Cookie) = .empty,
    extra_headers: std.ArrayList(HeaderEntry) = .empty,

    next_object_id: u64 = 1,
    object_handles: std.ArrayList(ObjectHandle) = .empty,

    next_script_id: u64 = 1,
    compiled_scripts: std.ArrayList(CompiledScript) = .empty,

    focused_node: ?dom.NodeId = null,
    input_overrides: std.ArrayList(InputOverride) = .empty,

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

    fn allocObjectIdForExpr(self: *CdpState, expression: []const u8) !u64 {
        const id = self.next_object_id;
        self.next_object_id += 1;
        try self.object_handles.append(self.allocator, .{
            .id = id,
            .kind = .expression,
            .expression = expression,
        });
        return id;
    }

    fn allocObjectIdForNode(self: *CdpState, node_id: dom.NodeId) !u64 {
        const id = self.next_object_id;
        self.next_object_id += 1;
        try self.object_handles.append(self.allocator, .{
            .id = id,
            .kind = .dom_node,
            .dom_node_id = node_id,
        });
        return id;
    }

    fn findObjectHandle(self: *const CdpState, id: u64) ?ObjectHandle {
        for (self.object_handles.items) |handle| {
            if (handle.id == id) return handle;
        }
        return null;
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

    var read_buf: [16384]u8 = undefined;
    var net_reader = net.Stream.Reader.init(stream, io, &read_buf);
    var write_buf: [16384]u8 = undefined;
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
    if (std.mem.startsWith(u8, clean_path, "/json/activate/") or
        std.mem.startsWith(u8, clean_path, "/json/close/"))
    {
        sendJson(request, "{\"success\":true}", 200);
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

pub fn dispatchCdpMessageForTestWithState(allocator: std.mem.Allocator, state: *CdpState, raw: []const u8) ![]const u8 {
    return (try dispatchCdpMessage(allocator, state, raw)).response;
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
    const m = req.method;

    // ---------------- Schema ----------------
    if (eql(m, "Schema.getDomains")) {
        return ok(allocator, req, schemaDomainsResult);
    }

    // ---------------- Browser ----------------
    if (eql(m, "Browser.getVersion")) {
        return ok(allocator, req, browser_version_result);
    }
    if (eql(m, "Browser.close")) return okEmpty(allocator, req);
    if (eql(m, "Browser.crash") or eql(m, "Browser.crashGpuProcess")) return okEmpty(allocator, req);
    if (eql(m, "Browser.getWindowForTarget")) {
        const result = try windowBoundsJson(allocator, state, true);
        return ok(allocator, req, result);
    }
    if (eql(m, "Browser.getWindowBounds")) {
        const result = try windowBoundsJson(allocator, state, false);
        return ok(allocator, req, result);
    }
    if (eql(m, "Browser.setWindowBounds")) {
        if (paramObject(req.params, "bounds")) |bounds| applyWindowBounds(state, bounds);
        return okEmpty(allocator, req);
    }
    if (eql(m, "Browser.setDownloadBehavior")) {
        if (paramString(req.params, "behavior")) |b| state.download_behavior = b;
        if (paramString(req.params, "downloadPath")) |p| state.download_path = p;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Browser.setPermission") or eql(m, "Browser.grantPermissions") or eql(m, "Browser.resetPermissions")) {
        return okEmpty(allocator, req);
    }
    if (eql(m, "Browser.getHistograms") or eql(m, "Browser.getHistogram")) {
        return ok(allocator, req, "{\"histograms\":[]}");
    }
    if (eql(m, "Browser.getBrowserCommandLine")) {
        return ok(allocator, req, "{\"arguments\":[\"kuri-browser\"]}");
    }
    if (eql(m, "Browser.executeBrowserCommand")) return okEmpty(allocator, req);
    if (eql(m, "Browser.cancelDownload")) return okEmpty(allocator, req);

    // ---------------- Target ----------------
    if (eql(m, "Target.getBrowserContexts")) {
        return ok(allocator, req, "{\"browserContextIds\":[\"" ++ browser_context_id ++ "\"]}");
    }
    if (eql(m, "Target.getTargets")) {
        const info = try targetInfoJson(allocator, state);
        const result = try std.fmt.allocPrint(allocator, "{{\"targetInfos\":[{s}]}}", .{info});
        return ok(allocator, req, result);
    }
    if (eql(m, "Target.getTargetInfo")) {
        const info = try targetInfoJson(allocator, state);
        const result = try std.fmt.allocPrint(allocator, "{{\"targetInfo\":{s}}}", .{info});
        return ok(allocator, req, result);
    }
    if (eql(m, "Target.createTarget")) {
        const url = paramString(req.params, "url") orelse "about:blank";
        state.current_url = url;
        state.title = "Kuri Browser";
        state.page = null;
        return .{
            .response = try successResponse(allocator, req.id, req.session_id, "{\"targetId\":\"" ++ page_id ++ "\"}"),
            .session_id = req.session_id,
            .target_created = true,
        };
    }
    if (eql(m, "Target.attachToTarget") or eql(m, "Target.attachToBrowserTarget")) {
        return ok(allocator, req, "{\"sessionId\":\"" ++ session_id ++ "\"}");
    }
    if (eql(m, "Target.detachFromTarget")) return okEmpty(allocator, req);
    if (eql(m, "Target.setDiscoverTargets") or eql(m, "Target.setAutoAttach") or
        eql(m, "Target.setRemoteLocations") or eql(m, "Target.activateTarget") or
        eql(m, "Target.exposeDevToolsProtocol") or eql(m, "Target.sendMessageToTarget"))
    {
        return okEmpty(allocator, req);
    }
    if (eql(m, "Target.closeTarget")) {
        return ok(allocator, req, "{\"success\":true}");
    }
    if (eql(m, "Target.createBrowserContext")) {
        return ok(allocator, req, "{\"browserContextId\":\"" ++ browser_context_id ++ "\"}");
    }
    if (eql(m, "Target.disposeBrowserContext")) return okEmpty(allocator, req);

    // ---------------- Inspector ----------------
    if (eql(m, "Inspector.enable")) {
        state.inspector_enabled = true;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Inspector.disable")) {
        state.inspector_enabled = false;
        return okEmpty(allocator, req);
    }

    // ---------------- Security ----------------
    if (eql(m, "Security.enable")) {
        state.security_enabled = true;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Security.disable")) {
        state.security_enabled = false;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Security.setIgnoreCertificateErrors") or
        eql(m, "Security.handleCertificateError") or
        eql(m, "Security.setOverrideCertificateErrors"))
    {
        return okEmpty(allocator, req);
    }

    // ---------------- Runtime ----------------
    if (eql(m, "Runtime.enable")) {
        state.runtime_enabled = true;
        return .{
            .response = try successResponse(allocator, req.id, req.session_id, "{}"),
            .session_id = req.session_id,
            .runtime_enabled = true,
        };
    }
    if (eql(m, "Runtime.disable")) {
        state.runtime_enabled = false;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Runtime.evaluate")) {
        const expression = paramString(req.params, "expression") orelse "undefined";
        const eval = if (state.page) |*page|
            try js_runtime.evaluateExpressionOnPage(allocator, page, expression)
        else
            try js_runtime.evaluateExpressionInHtml(allocator, "<html><head><title>Kuri Browser</title></head><body></body></html>", state.current_url, expression);
        const remote = try remoteObjectJson(allocator, eval.eval_result, eval.error_message);
        const result = try std.fmt.allocPrint(allocator, "{{\"result\":{s}}}", .{remote});
        return ok(allocator, req, result);
    }
    if (eql(m, "Runtime.callFunctionOn")) {
        const declaration = paramString(req.params, "functionDeclaration") orelse "function(){}";
        const args_text = try buildCallArgs(allocator, req.params, state);
        const wrapped = try std.fmt.allocPrint(allocator, "(({s}).apply(this,{s}))", .{ declaration, args_text });
        const eval = if (state.page) |*page|
            try js_runtime.evaluateExpressionOnPage(allocator, page, wrapped)
        else
            try js_runtime.evaluateExpressionInHtml(allocator, "<html><head><title>Kuri Browser</title></head><body></body></html>", state.current_url, wrapped);
        const remote = try remoteObjectJson(allocator, eval.eval_result, eval.error_message);
        const result = try std.fmt.allocPrint(allocator, "{{\"result\":{s}}}", .{remote});
        return ok(allocator, req, result);
    }
    if (eql(m, "Runtime.getProperties")) {
        const handle_id = paramU64(req.params, "objectId") orelse 0;
        if (state.findObjectHandle(handle_id)) |handle| {
            return ok(allocator, req, try propertiesForHandle(allocator, state, handle));
        }
        return ok(allocator, req, "{\"result\":[],\"internalProperties\":[]}");
    }
    if (eql(m, "Runtime.releaseObject") or eql(m, "Runtime.releaseObjectGroup")) {
        return okEmpty(allocator, req);
    }
    if (eql(m, "Runtime.compileScript")) {
        const source = paramString(req.params, "expression") orelse "";
        const id = state.next_script_id;
        state.next_script_id += 1;
        const id_str = try std.fmt.allocPrint(allocator, "kuri-script-{d}", .{id});
        try state.compiled_scripts.append(allocator, .{ .id = id_str, .source = source });
        const result = try std.fmt.allocPrint(allocator, "{{\"scriptId\":\"{s}\"}}", .{id_str});
        return ok(allocator, req, result);
    }
    if (eql(m, "Runtime.runScript")) {
        const script_id = paramString(req.params, "scriptId") orelse "";
        const source = blk: {
            for (state.compiled_scripts.items) |script| {
                if (std.mem.eql(u8, script.id, script_id)) break :blk script.source;
            }
            break :blk "";
        };
        const eval = if (state.page) |*page|
            try js_runtime.evaluateExpressionOnPage(allocator, page, source)
        else
            try js_runtime.evaluateExpressionInHtml(allocator, "<html><head><title>Kuri Browser</title></head><body></body></html>", state.current_url, source);
        const remote = try remoteObjectJson(allocator, eval.eval_result, eval.error_message);
        const result = try std.fmt.allocPrint(allocator, "{{\"result\":{s}}}", .{remote});
        return ok(allocator, req, result);
    }
    if (eql(m, "Runtime.awaitPromise")) {
        return ok(allocator, req, "{\"result\":{\"type\":\"undefined\",\"description\":\"undefined\"}}");
    }
    if (eql(m, "Runtime.getIsolateId")) {
        return ok(allocator, req, "{\"id\":\"" ++ isolate_id ++ "\"}");
    }
    if (eql(m, "Runtime.getHeapUsage")) {
        return ok(allocator, req, "{\"usedSize\":0,\"totalSize\":0}");
    }
    if (eql(m, "Runtime.discardConsoleEntries") or
        eql(m, "Runtime.runIfWaitingForDebugger") or
        eql(m, "Runtime.terminateExecution") or
        eql(m, "Runtime.setAsyncCallStackDepth") or
        eql(m, "Runtime.setCustomObjectFormatterEnabled") or
        eql(m, "Runtime.setMaxCallStackSizeToCapture") or
        eql(m, "Runtime.addBinding") or
        eql(m, "Runtime.removeBinding"))
    {
        return okEmpty(allocator, req);
    }
    if (eql(m, "Runtime.queryObjects")) {
        return ok(allocator, req, "{\"objects\":{\"type\":\"object\",\"subtype\":\"array\",\"description\":\"Array(0)\"}}");
    }
    if (eql(m, "Runtime.globalLexicalScopeNames")) {
        return ok(allocator, req, "{\"names\":[]}");
    }

    // ---------------- Debugger ----------------
    if (eql(m, "Debugger.enable")) {
        state.debugger_enabled = true;
        return ok(allocator, req, "{\"debuggerId\":\"" ++ debugger_id ++ "\"}");
    }
    if (eql(m, "Debugger.disable")) {
        state.debugger_enabled = false;
        return okEmpty(allocator, req);
    }
    if (std.mem.startsWith(u8, m, "Debugger.")) return okEmpty(allocator, req);

    // ---------------- HeapProfiler / Profiler ----------------
    if (std.mem.startsWith(u8, m, "HeapProfiler.")) return okEmpty(allocator, req);
    if (std.mem.startsWith(u8, m, "Profiler.")) return okEmpty(allocator, req);

    // ---------------- Page ----------------
    if (eql(m, "Page.enable")) {
        state.page_enabled = true;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Page.disable")) {
        state.page_enabled = false;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Page.getFrameTree")) {
        const result = try frameTreeJson(allocator, state);
        return ok(allocator, req, result);
    }
    if (eql(m, "Page.navigate")) {
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
    if (eql(m, "Page.reload")) {
        const url_copy = state.current_url;
        state.navigate(url_copy) catch |err| return .{
            .response = try errorResponse(allocator, req.id, req.session_id, -32000, @errorName(err)),
        };
        return .{
            .response = try successResponse(allocator, req.id, req.session_id, "{}"),
            .session_id = req.session_id,
            .navigated = true,
        };
    }
    if (eql(m, "Page.stopLoading") or eql(m, "Page.bringToFront") or eql(m, "Page.crash")) {
        return okEmpty(allocator, req);
    }
    if (eql(m, "Page.handleJavaScriptDialog")) return okEmpty(allocator, req);
    if (eql(m, "Page.setBypassCSP")) {
        state.bypass_csp = paramBool(req.params, "enabled") orelse false;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Page.setLifecycleEventsEnabled")) {
        state.lifecycle_events_enabled = paramBool(req.params, "enabled") orelse false;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Page.addScriptToEvaluateOnNewDocument")) {
        const source = paramString(req.params, "source") orelse "";
        const world = paramString(req.params, "worldName") orelse "";
        state.new_doc_script_seq += 1;
        const id_str = try std.fmt.allocPrint(allocator, "{d}", .{state.new_doc_script_seq});
        try state.new_doc_scripts.append(allocator, .{
            .id = id_str,
            .source = source,
            .world_name = world,
        });
        const result = try std.fmt.allocPrint(allocator, "{{\"identifier\":\"{s}\"}}", .{id_str});
        return ok(allocator, req, result);
    }
    if (eql(m, "Page.removeScriptToEvaluateOnNewDocument")) {
        const id = paramString(req.params, "identifier") orelse return okEmpty(allocator, req);
        var idx: usize = 0;
        while (idx < state.new_doc_scripts.items.len) : (idx += 1) {
            if (std.mem.eql(u8, state.new_doc_scripts.items[idx].id, id)) {
                _ = state.new_doc_scripts.orderedRemove(idx);
                break;
            }
        }
        return okEmpty(allocator, req);
    }
    if (eql(m, "Page.setDownloadBehavior")) {
        if (paramString(req.params, "behavior")) |b| state.download_behavior = b;
        if (paramString(req.params, "downloadPath")) |p| state.download_path = p;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Page.setInterceptFileChooserDialog") or
        eql(m, "Page.setWebLifecycleState") or
        eql(m, "Page.setAdBlockingEnabled") or
        eql(m, "Page.setFontFamilies") or
        eql(m, "Page.setFontSizes") or
        eql(m, "Page.setProduceCompilationCache") or
        eql(m, "Page.setRPHRegistrationMode") or
        eql(m, "Page.setSPCTransactionMode") or
        eql(m, "Page.setDocumentContent"))
    {
        return okEmpty(allocator, req);
    }
    if (eql(m, "Page.getNavigationHistory")) {
        const result = try navigationHistoryJson(allocator, state);
        return ok(allocator, req, result);
    }
    if (eql(m, "Page.resetNavigationHistory")) return okEmpty(allocator, req);
    if (eql(m, "Page.navigateToHistoryEntry")) return okEmpty(allocator, req);
    if (eql(m, "Page.captureScreenshot")) {
        return .{ .response = try errorResponse(allocator, req.id, req.session_id, -32000, "native screenshot is not implemented; use kuri-browser screenshot --compress fallback") };
    }
    if (eql(m, "Page.printToPDF")) {
        return .{ .response = try errorResponse(allocator, req.id, req.session_id, -32000, "PDF rendering is not implemented") };
    }
    if (eql(m, "Page.captureSnapshot")) {
        const url = try jsonStringLiteral(allocator, state.current_url);
        const data = if (state.page) |*page| blk: {
            var layout_result = engine.layoutPage(allocator, page, .{
                .width = @floatFromInt(state.viewport_width),
                .height = @floatFromInt(state.viewport_height),
            }) catch |err| {
                std.log.debug("engine.layoutPage failed: {s}", .{@errorName(err)});
                break :blk try std.fmt.allocPrint(allocator, "From: <Saved by Kuri Browser>\\nSnapshot-URL: {s}\\n", .{state.current_url});
            };
            defer layout_result.deinit();
            const svg = engine.paintToSvg(allocator, &layout_result) catch |err| {
                std.log.debug("engine.paintToSvg failed: {s}", .{@errorName(err)});
                break :blk try std.fmt.allocPrint(allocator, "From: <Saved by Kuri Browser>\\nSnapshot-URL: {s}\\n", .{state.current_url});
            };
            break :blk svg;
        } else try std.fmt.allocPrint(allocator, "From: <Saved by Kuri Browser>\\nSnapshot-URL: {s}\\n", .{state.current_url});
        const data_quoted = try jsonStringLiteral(allocator, data);
        const result = try std.fmt.allocPrint(allocator, "{{\"data\":{s},\"url\":{s}}}", .{ data_quoted, url });
        return ok(allocator, req, result);
    }
    if (eql(m, "Page.getResourceTree")) {
        const result = try resourceTreeJson(allocator, state);
        return ok(allocator, req, result);
    }
    if (eql(m, "Page.getResourceContent")) {
        return .{ .response = try errorResponse(allocator, req.id, req.session_id, -32000, "resource content is not cached natively yet") };
    }
    if (eql(m, "Page.searchInResource")) {
        return ok(allocator, req, "{\"result\":[]}");
    }
    if (eql(m, "Page.getAppManifest")) {
        const url = try jsonStringLiteral(allocator, state.current_url);
        const result = try std.fmt.allocPrint(allocator, "{{\"url\":{s},\"errors\":[],\"data\":\"\"}}", .{url});
        return ok(allocator, req, result);
    }
    if (eql(m, "Page.getInstallabilityErrors")) {
        return ok(allocator, req, "{\"installabilityErrors\":[]}");
    }
    if (eql(m, "Page.getLayoutMetrics")) {
        const result = try layoutMetricsJson(allocator, state);
        return ok(allocator, req, result);
    }
    if (eql(m, "Page.close")) return okEmpty(allocator, req);

    // ---------------- Network ----------------
    if (eql(m, "Network.enable")) {
        state.network_enabled = true;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Network.disable")) {
        state.network_enabled = false;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Network.setUserAgentOverride")) {
        if (paramString(req.params, "userAgent")) |ua| state.user_agent_override = ua;
        if (paramString(req.params, "acceptLanguage")) |al| state.accept_language_override = al;
        if (paramString(req.params, "platform")) |p| state.platform_override = p;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Network.setExtraHTTPHeaders")) {
        if (paramObject(req.params, "headers")) |obj| {
            state.extra_headers.clearRetainingCapacity();
            var it = obj.iterator();
            while (it.next()) |entry| {
                const value = switch (entry.value_ptr.*) {
                    .string => |s| s,
                    else => continue,
                };
                try state.extra_headers.append(allocator, .{ .name = entry.key_ptr.*, .value = value });
            }
        }
        return okEmpty(allocator, req);
    }
    if (eql(m, "Network.setCacheDisabled")) {
        state.cache_disabled = paramBool(req.params, "cacheDisabled") orelse false;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Network.clearBrowserCache")) return okEmpty(allocator, req);
    if (eql(m, "Network.clearBrowserCookies")) {
        state.cookies.clearRetainingCapacity();
        return okEmpty(allocator, req);
    }
    if (eql(m, "Network.getAllCookies") or eql(m, "Network.getCookies")) {
        const result = try cookiesResultJson(allocator, state);
        return ok(allocator, req, result);
    }
    if (eql(m, "Network.setCookies")) {
        if (paramArray(req.params, "cookies")) |arr| {
            for (arr) |entry| try appendCookieFromValue(state, allocator, entry);
        }
        return okEmpty(allocator, req);
    }
    if (eql(m, "Network.setCookie")) {
        if (req.params) |p| try appendCookieFromValue(state, allocator, p);
        return ok(allocator, req, "{\"success\":true}");
    }
    if (eql(m, "Network.deleteCookies")) {
        const name = paramString(req.params, "name") orelse "";
        const url = paramString(req.params, "url") orelse "";
        const domain_filter = paramString(req.params, "domain") orelse "";
        const path_filter = paramString(req.params, "path") orelse "";
        var idx: usize = 0;
        while (idx < state.cookies.items.len) {
            const c = state.cookies.items[idx];
            const name_match = name.len == 0 or std.mem.eql(u8, c.name, name);
            const url_match = url.len == 0 or std.mem.eql(u8, c.url, url);
            const domain_match = domain_filter.len == 0 or std.mem.eql(u8, c.domain, domain_filter);
            const path_match = path_filter.len == 0 or std.mem.eql(u8, c.path, path_filter);
            if (name_match and url_match and domain_match and path_match) {
                _ = state.cookies.orderedRemove(idx);
                continue;
            }
            idx += 1;
        }
        return okEmpty(allocator, req);
    }
    if (eql(m, "Network.emulateNetworkConditions") or
        eql(m, "Network.setBypassServiceWorker") or
        eql(m, "Network.setDataSizeLimitsForTest") or
        eql(m, "Network.replayXHR") or
        eql(m, "Network.setAttachDebugStack") or
        eql(m, "Network.setBlockedURLs") or
        eql(m, "Network.takeResponseBodyForInterceptionAsStream") or
        eql(m, "Network.continueInterceptedRequest"))
    {
        return okEmpty(allocator, req);
    }
    if (eql(m, "Network.setRequestInterception")) {
        const patterns = paramArray(req.params, "patterns") orelse &[_]std.json.Value{};
        state.request_interception_enabled = patterns.len > 0;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Network.getRequestPostData") or eql(m, "Network.getResponseBody") or
        eql(m, "Network.getResponseBodyForInterception"))
    {
        return .{ .response = try errorResponse(allocator, req.id, req.session_id, -32000, "no captured network bodies in standalone CDP yet") };
    }
    if (eql(m, "Network.canEmulateNetworkConditions") or
        eql(m, "Network.canClearBrowserCache") or
        eql(m, "Network.canClearBrowserCookies"))
    {
        return ok(allocator, req, "{\"result\":true}");
    }
    if (eql(m, "Network.getCertificate")) {
        return ok(allocator, req, "{\"tableNames\":[]}");
    }

    // ---------------- Storage ----------------
    if (eql(m, "Storage.getCookies")) {
        const result = try cookiesResultJson(allocator, state);
        return ok(allocator, req, result);
    }
    if (eql(m, "Storage.setCookies")) {
        if (paramArray(req.params, "cookies")) |arr| {
            for (arr) |entry| try appendCookieFromValue(state, allocator, entry);
        }
        return okEmpty(allocator, req);
    }
    if (eql(m, "Storage.clearCookies")) {
        state.cookies.clearRetainingCapacity();
        return okEmpty(allocator, req);
    }
    if (eql(m, "Storage.clearDataForOrigin") or
        eql(m, "Storage.clearDataForStorageKey") or
        eql(m, "Storage.trackCacheStorageForOrigin") or
        eql(m, "Storage.trackIndexedDBForOrigin") or
        eql(m, "Storage.untrackCacheStorageForOrigin") or
        eql(m, "Storage.untrackIndexedDBForOrigin") or
        eql(m, "Storage.overrideQuotaForOrigin"))
    {
        return okEmpty(allocator, req);
    }
    if (eql(m, "Storage.getUsageAndQuota")) {
        return ok(allocator, req, "{\"usage\":0,\"quota\":0,\"overrideActive\":false,\"usageBreakdown\":[]}");
    }
    if (eql(m, "Storage.getStorageKeyForFrame")) {
        const url = try jsonStringLiteral(allocator, state.current_url);
        const result = try std.fmt.allocPrint(allocator, "{{\"storageKey\":{s}}}", .{url});
        return ok(allocator, req, result);
    }
    if (std.mem.startsWith(u8, m, "Storage.")) return okEmpty(allocator, req);

    // ---------------- Emulation ----------------
    if (eql(m, "Emulation.setDeviceMetricsOverride")) {
        if (paramU32(req.params, "width")) |w| state.viewport_width = w;
        if (paramU32(req.params, "height")) |h| state.viewport_height = h;
        if (paramFloat(req.params, "deviceScaleFactor")) |s| state.device_scale_factor = s;
        if (paramBool(req.params, "mobile")) |b| state.mobile = b;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Emulation.clearDeviceMetricsOverride")) {
        state.viewport_width = 1280;
        state.viewport_height = 720;
        state.device_scale_factor = 1.0;
        state.mobile = false;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Emulation.setUserAgentOverride")) {
        if (paramString(req.params, "userAgent")) |ua| state.user_agent_override = ua;
        if (paramString(req.params, "acceptLanguage")) |al| state.accept_language_override = al;
        if (paramString(req.params, "platform")) |p| state.platform_override = p;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Emulation.setLocaleOverride")) {
        state.locale_override = paramString(req.params, "locale");
        return okEmpty(allocator, req);
    }
    if (eql(m, "Emulation.setTimezoneOverride")) {
        state.timezone_override = paramString(req.params, "timezoneId");
        return okEmpty(allocator, req);
    }
    if (eql(m, "Emulation.setEmulatedMedia")) {
        state.emulated_media = paramString(req.params, "media");
        return okEmpty(allocator, req);
    }
    if (eql(m, "Emulation.setScriptExecutionDisabled")) {
        state.script_execution_disabled = paramBool(req.params, "value") orelse false;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Emulation.setGeolocationOverride") or
        eql(m, "Emulation.clearGeolocationOverride") or
        eql(m, "Emulation.setFocusEmulationEnabled") or
        eql(m, "Emulation.setTouchEmulationEnabled") or
        eql(m, "Emulation.setEmitTouchEventsForMouse") or
        eql(m, "Emulation.setVisibleSize") or
        eql(m, "Emulation.setDefaultBackgroundColorOverride") or
        eql(m, "Emulation.setDocumentCookieDisabled") or
        eql(m, "Emulation.setIdleOverride") or
        eql(m, "Emulation.clearIdleOverride") or
        eql(m, "Emulation.setMediaText") or
        eql(m, "Emulation.setNavigatorOverrides") or
        eql(m, "Emulation.setHardwareConcurrencyOverride") or
        eql(m, "Emulation.setEmulatedVisionDeficiency") or
        eql(m, "Emulation.setAutomationOverride") or
        eql(m, "Emulation.resetPageScaleFactor") or
        eql(m, "Emulation.setPageScaleFactor") or
        eql(m, "Emulation.setCPUThrottlingRate"))
    {
        return okEmpty(allocator, req);
    }
    if (eql(m, "Emulation.canEmulate")) {
        return ok(allocator, req, "{\"result\":true}");
    }
    if (std.mem.startsWith(u8, m, "Emulation.")) return okEmpty(allocator, req);

    // ---------------- DOM ----------------
    if (eql(m, "DOM.enable")) {
        state.dom_enabled = true;
        return okEmpty(allocator, req);
    }
    if (eql(m, "DOM.disable")) {
        state.dom_enabled = false;
        return okEmpty(allocator, req);
    }
    if (eql(m, "DOM.getDocument")) {
        const depth = paramI32(req.params, "depth") orelse 1;
        const pierce = paramBool(req.params, "pierce") orelse false;
        const tree = try renderDomTree(allocator, state, depth, pierce);
        const result = try std.fmt.allocPrint(allocator, "{{\"root\":{s}}}", .{tree});
        return ok(allocator, req, result);
    }
    if (eql(m, "DOM.getFlattenedDocument")) {
        const depth = paramI32(req.params, "depth") orelse -1;
        const tree = try renderDomTreeFlattened(allocator, state, depth);
        const result = try std.fmt.allocPrint(allocator, "{{\"nodes\":[{s}]}}", .{tree});
        return ok(allocator, req, result);
    }
    if (eql(m, "DOM.querySelector")) {
        const selector = paramString(req.params, "selector") orelse "";
        const node_id = (try resolveQuerySelector(allocator, state, selector)) orelse 0;
        const result = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{d}}}", .{node_id});
        return ok(allocator, req, result);
    }
    if (eql(m, "DOM.querySelectorAll")) {
        const selector = paramString(req.params, "selector") orelse "";
        const ids = try resolveQuerySelectorAll(allocator, state, selector);
        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        try buf.writer.writeAll("{\"nodeIds\":[");
        for (ids, 0..) |id, idx| {
            if (idx > 0) try buf.writer.writeByte(',');
            try buf.writer.print("{d}", .{id});
        }
        try buf.writer.writeAll("]}");
        return ok(allocator, req, try allocator.dupe(u8, buf.written()));
    }
    if (eql(m, "DOM.getOuterHTML")) {
        const html = (try outerHtmlForRequest(allocator, state, req.params)) orelse "";
        const html_quoted = try jsonStringLiteral(allocator, html);
        const result = try std.fmt.allocPrint(allocator, "{{\"outerHTML\":{s}}}", .{html_quoted});
        return ok(allocator, req, result);
    }
    if (eql(m, "DOM.focus")) {
        const node_id = paramU64(req.params, "nodeId") orelse 0;
        if (cdpToInternal(node_id)) |internal| state.focused_node = internal;
        return okEmpty(allocator, req);
    }
    if (eql(m, "DOM.setOuterHTML") or eql(m, "DOM.setNodeName") or
        eql(m, "DOM.setNodeValue") or eql(m, "DOM.removeNode") or
        eql(m, "DOM.removeAttribute") or eql(m, "DOM.setAttributeValue") or
        eql(m, "DOM.setAttributesAsText") or eql(m, "DOM.moveTo") or
        eql(m, "DOM.copyTo") or eql(m, "DOM.scrollIntoViewIfNeeded") or
        eql(m, "DOM.markUndoableState") or
        eql(m, "DOM.undo") or eql(m, "DOM.redo") or
        eql(m, "DOM.discardSearchResults") or eql(m, "DOM.requestChildNodes") or
        eql(m, "DOM.collectClassNamesFromSubtree"))
    {
        return okEmpty(allocator, req);
    }
    if (eql(m, "DOM.getAttributes")) {
        const node_id = paramU64(req.params, "nodeId") orelse 0;
        const attrs = try attributesArrayJson(allocator, state, node_id);
        const result = try std.fmt.allocPrint(allocator, "{{\"attributes\":{s}}}", .{attrs});
        return ok(allocator, req, result);
    }
    if (eql(m, "DOM.describeNode")) {
        const node_id = paramU64(req.params, "nodeId") orelse 0;
        const node_json = try describedNodeJson(allocator, state, node_id);
        const result = try std.fmt.allocPrint(allocator, "{{\"node\":{s}}}", .{node_json});
        return ok(allocator, req, result);
    }
    if (eql(m, "DOM.resolveNode")) {
        const node_id = paramU64(req.params, "nodeId") orelse 0;
        const handle_id = try state.allocObjectIdForNode(@intCast(if (node_id == 0) 0 else node_id - 1));
        const description = try nodeDescription(allocator, state, node_id);
        const description_q = try jsonStringLiteral(allocator, description);
        const result = try std.fmt.allocPrint(allocator,
            "{{\"object\":{{\"type\":\"object\",\"subtype\":\"node\",\"className\":\"HTMLElement\",\"description\":{s},\"objectId\":\"{d}\"}}}}",
            .{ description_q, handle_id });
        return ok(allocator, req, result);
    }
    if (eql(m, "DOM.requestNode")) {
        return ok(allocator, req, "{\"nodeId\":1}");
    }
    if (eql(m, "DOM.getNodeForLocation")) {
        return ok(allocator, req, "{\"backendNodeId\":1,\"frameId\":\"" ++ frame_id ++ "\",\"nodeId\":1}");
    }
    if (eql(m, "DOM.getBoxModel")) {
        const result = try std.fmt.allocPrint(allocator,
            "{{\"model\":{{\"content\":[0,0,{d},0,{d},{d},0,{d}],\"padding\":[0,0,{d},0,{d},{d},0,{d}],\"border\":[0,0,{d},0,{d},{d},0,{d}],\"margin\":[0,0,{d},0,{d},{d},0,{d}],\"width\":{d},\"height\":{d},\"shapeOutside\":null}}}}",
            .{
                state.viewport_width, state.viewport_width, state.viewport_height, state.viewport_height,
                state.viewport_width, state.viewport_width, state.viewport_height, state.viewport_height,
                state.viewport_width, state.viewport_width, state.viewport_height, state.viewport_height,
                state.viewport_width, state.viewport_width, state.viewport_height, state.viewport_height,
                state.viewport_width, state.viewport_height,
            });
        return ok(allocator, req, result);
    }
    if (eql(m, "DOM.getContentQuads")) {
        const result = try std.fmt.allocPrint(allocator,
            "{{\"quads\":[[0,0,{d},0,{d},{d},0,{d}]]}}",
            .{ state.viewport_width, state.viewport_width, state.viewport_height, state.viewport_height });
        return ok(allocator, req, result);
    }
    if (eql(m, "DOM.performSearch")) {
        const selector = paramString(req.params, "query") orelse "";
        const ids = try resolveQuerySelectorAll(allocator, state, selector);
        const id_str = try std.fmt.allocPrint(allocator, "kuri-search-{d}", .{state.next_script_id});
        state.next_script_id += 1;
        const result = try std.fmt.allocPrint(allocator, "{{\"searchId\":\"{s}\",\"resultCount\":{d}}}", .{ id_str, ids.len });
        return ok(allocator, req, result);
    }
    if (eql(m, "DOM.getSearchResults")) {
        return ok(allocator, req, "{\"nodeIds\":[]}");
    }

    // ---------------- CSS ----------------
    if (eql(m, "CSS.enable")) {
        state.css_enabled = true;
        return ok(allocator, req, "{\"id\":\"kuri-stylesheet-1\"}");
    }
    if (eql(m, "CSS.disable")) {
        state.css_enabled = false;
        return okEmpty(allocator, req);
    }
    if (eql(m, "CSS.getComputedStyleForNode")) {
        const node_id = paramU64(req.params, "nodeId") orelse 0;
        const result = try cssComputedStyleJson(allocator, state, node_id);
        return ok(allocator, req, result);
    }
    if (eql(m, "CSS.getMatchedStylesForNode")) {
        const node_id = paramU64(req.params, "nodeId") orelse 0;
        const result = try cssMatchedStylesJson(allocator, state, node_id);
        return ok(allocator, req, result);
    }
    if (eql(m, "CSS.getInlineStylesForNode")) {
        const node_id = paramU64(req.params, "nodeId") orelse 0;
        const result = try cssInlineStylesJson(allocator, state, node_id);
        return ok(allocator, req, result);
    }
    if (eql(m, "CSS.getBackgroundColors")) {
        const node_id = paramU64(req.params, "nodeId") orelse 0;
        const result = try cssBackgroundColorsJson(allocator, state, node_id);
        return ok(allocator, req, result);
    }
    if (eql(m, "CSS.getMediaQueries")) {
        return ok(allocator, req, "{\"medias\":[]}");
    }
    if (eql(m, "CSS.getStyleSheetText")) {
        const result = try cssStyleSheetTextJson(allocator, state);
        return ok(allocator, req, result);
    }
    if (eql(m, "CSS.collectClassNames")) {
        const result = try cssCollectClassNamesJson(allocator, state);
        return ok(allocator, req, result);
    }
    if (std.mem.startsWith(u8, m, "CSS.")) return okEmpty(allocator, req);

    // ---------------- Input ----------------
    if (eql(m, "Input.insertText")) {
        const text = paramString(req.params, "text") orelse "";
        try appendToFocused(state, text);
        return okEmpty(allocator, req);
    }
    if (eql(m, "Input.dispatchKeyEvent")) {
        const event_type = paramString(req.params, "type") orelse "";
        if (std.mem.eql(u8, event_type, "char") or std.mem.eql(u8, event_type, "keyDown")) {
            if (paramString(req.params, "text")) |text| {
                if (text.len > 0) try appendToFocused(state, text);
            } else if (paramString(req.params, "key")) |key| {
                if (std.mem.eql(u8, key, "Backspace")) {
                    eraseLastFromFocused(state);
                } else if (key.len == 1) {
                    try appendToFocused(state, key);
                }
            }
        }
        return okEmpty(allocator, req);
    }
    if (std.mem.startsWith(u8, m, "Input.")) return okEmpty(allocator, req);

    // ---------------- IO ----------------
    if (eql(m, "IO.read")) {
        return ok(allocator, req, "{\"data\":\"\",\"eof\":true,\"base64Encoded\":false}");
    }
    if (eql(m, "IO.close") or eql(m, "IO.resolveBlob")) return okEmpty(allocator, req);

    // ---------------- Log ----------------
    if (eql(m, "Log.enable")) {
        state.log_enabled = true;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Log.disable")) {
        state.log_enabled = false;
        return okEmpty(allocator, req);
    }
    if (std.mem.startsWith(u8, m, "Log.")) return okEmpty(allocator, req);

    // ---------------- Performance ----------------
    if (eql(m, "Performance.enable") or eql(m, "Performance.disable")) return okEmpty(allocator, req);
    if (eql(m, "Performance.getMetrics")) return ok(allocator, req, "{\"metrics\":[]}");
    if (eql(m, "Performance.setTimeDomain")) return okEmpty(allocator, req);

    // ---------------- PerformanceTimeline ----------------
    if (std.mem.startsWith(u8, m, "PerformanceTimeline.")) return okEmpty(allocator, req);

    // ---------------- Tracing ----------------
    if (std.mem.startsWith(u8, m, "Tracing.")) return okEmpty(allocator, req);

    // ---------------- Animation ----------------
    if (std.mem.startsWith(u8, m, "Animation.")) return okEmpty(allocator, req);

    // ---------------- Memory ----------------
    if (eql(m, "Memory.getDOMCounters")) {
        return ok(allocator, req, "{\"documents\":1,\"nodes\":1,\"jsEventListeners\":0}");
    }
    if (std.mem.startsWith(u8, m, "Memory.")) return okEmpty(allocator, req);

    // ---------------- Fetch ----------------
    if (eql(m, "Fetch.enable")) {
        state.fetch_enabled = true;
        return okEmpty(allocator, req);
    }
    if (eql(m, "Fetch.disable")) {
        state.fetch_enabled = false;
        return okEmpty(allocator, req);
    }
    if (std.mem.startsWith(u8, m, "Fetch.")) return okEmpty(allocator, req);

    // ---------------- ServiceWorker / IndexedDB / CacheStorage / DOMStorage ----------------
    if (std.mem.startsWith(u8, m, "ServiceWorker.")) return okEmpty(allocator, req);
    if (std.mem.startsWith(u8, m, "IndexedDB.")) return okEmpty(allocator, req);
    if (std.mem.startsWith(u8, m, "CacheStorage.")) return okEmpty(allocator, req);
    if (std.mem.startsWith(u8, m, "DOMStorage.")) return okEmpty(allocator, req);
    if (std.mem.startsWith(u8, m, "ApplicationCache.")) return okEmpty(allocator, req);
    if (std.mem.startsWith(u8, m, "Database.")) return okEmpty(allocator, req);

    // ---------------- HeadlessExperimental ----------------
    if (eql(m, "HeadlessExperimental.beginFrame")) {
        return ok(allocator, req, "{\"hasDamage\":false}");
    }
    if (std.mem.startsWith(u8, m, "HeadlessExperimental.")) return okEmpty(allocator, req);

    // ---------------- LayerTree / Overlay / Audits / BackgroundService ----------------
    if (std.mem.startsWith(u8, m, "LayerTree.")) return okEmpty(allocator, req);
    if (std.mem.startsWith(u8, m, "Overlay.")) return okEmpty(allocator, req);
    if (std.mem.startsWith(u8, m, "Audits.")) return okEmpty(allocator, req);
    if (std.mem.startsWith(u8, m, "BackgroundService.")) return okEmpty(allocator, req);
    if (std.mem.startsWith(u8, m, "DeviceOrientation.")) return okEmpty(allocator, req);
    if (std.mem.startsWith(u8, m, "Console.")) return okEmpty(allocator, req);
    if (std.mem.startsWith(u8, m, "WebAudio.")) return okEmpty(allocator, req);
    if (std.mem.startsWith(u8, m, "WebAuthn.")) return okEmpty(allocator, req);
    if (std.mem.startsWith(u8, m, "Media.")) return okEmpty(allocator, req);
    if (std.mem.startsWith(u8, m, "Cast.")) return okEmpty(allocator, req);
    if (std.mem.startsWith(u8, m, "Accessibility.")) return okEmpty(allocator, req);

    // Generic .enable/.disable safety net
    if (std.mem.endsWith(u8, m, ".enable") or std.mem.endsWith(u8, m, ".disable")) {
        return okEmpty(allocator, req);
    }

    return .{ .response = try errorResponse(allocator, req.id, req.session_id, -32601, "method not found") };
}

// ----------------------------- Helpers -----------------------------

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn ok(allocator: std.mem.Allocator, req: CdpRequest, result: []const u8) !DispatchResult {
    return .{ .response = try successResponse(allocator, req.id, req.session_id, result) };
}

fn okEmpty(allocator: std.mem.Allocator, req: CdpRequest) !DispatchResult {
    return ok(allocator, req, "{}");
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

fn paramObject(params: ?std.json.Value, key: []const u8) ?std.json.ObjectMap {
    const value = paramValue(params, key) orelse return null;
    return switch (value) {
        .object => |o| o,
        else => null,
    };
}

fn paramArray(params: ?std.json.Value, key: []const u8) ?[]std.json.Value {
    const value = paramValue(params, key) orelse return null;
    return switch (value) {
        .array => |arr| arr.items,
        else => null,
    };
}

fn paramBool(params: ?std.json.Value, key: []const u8) ?bool {
    const value = paramValue(params, key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn paramI32(params: ?std.json.Value, key: []const u8) ?i32 {
    const value = paramValue(params, key) orelse return null;
    return switch (value) {
        .integer => |n| @intCast(n),
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn paramU32(params: ?std.json.Value, key: []const u8) ?u32 {
    const value = paramValue(params, key) orelse return null;
    return switch (value) {
        .integer => |n| if (n < 0) null else @intCast(n),
        .float => |f| if (f < 0) null else @intFromFloat(f),
        else => null,
    };
}

fn paramU64(params: ?std.json.Value, key: []const u8) ?u64 {
    const value = paramValue(params, key) orelse return null;
    return switch (value) {
        .integer => |n| if (n < 0) null else @intCast(n),
        .float => |f| if (f < 0) null else @intFromFloat(f),
        .string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

fn paramFloat(params: ?std.json.Value, key: []const u8) ?f64 {
    const value = paramValue(params, key) orelse return null;
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => null,
    };
}

fn applyWindowBounds(state: *CdpState, bounds: std.json.ObjectMap) void {
    if (bounds.get("left")) |v| switch (v) {
        .integer => |n| state.window_left = @intCast(n),
        .float => |f| state.window_left = @intFromFloat(f),
        else => {},
    };
    if (bounds.get("top")) |v| switch (v) {
        .integer => |n| state.window_top = @intCast(n),
        .float => |f| state.window_top = @intFromFloat(f),
        else => {},
    };
    if (bounds.get("width")) |v| switch (v) {
        .integer => |n| {
            if (n >= 0) state.window_width = @intCast(n);
        },
        .float => |f| {
            if (f >= 0) state.window_width = @intFromFloat(f);
        },
        else => {},
    };
    if (bounds.get("height")) |v| switch (v) {
        .integer => |n| {
            if (n >= 0) state.window_height = @intCast(n);
        },
        .float => |f| {
            if (f >= 0) state.window_height = @intFromFloat(f);
        },
        else => {},
    };
    if (bounds.get("windowState")) |v| switch (v) {
        .string => |s| state.window_state = s,
        else => {},
    };
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

fn buildCallArgs(allocator: std.mem.Allocator, params: ?std.json.Value, state: *CdpState) ![]const u8 {
    const arr = paramArray(params, "arguments") orelse return allocator.dupe(u8, "[]");
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.writeByte('[');
    for (arr, 0..) |entry, idx| {
        if (idx > 0) try buf.writer.writeByte(',');
        try writeCallArg(&buf, entry, state);
    }
    try buf.writer.writeByte(']');
    return allocator.dupe(u8, buf.written());
}

fn writeCallArg(buf: *std.Io.Writer.Allocating, entry: std.json.Value, state: *CdpState) !void {
    switch (entry) {
        .object => |obj| {
            if (obj.get("unserializableValue")) |val| switch (val) {
                .string => |s| {
                    try buf.writer.writeAll(s);
                    return;
                },
                else => {},
            };
            if (obj.get("value")) |val| {
                try std.json.Stringify.value(val, .{}, &buf.writer);
                return;
            }
            if (obj.get("objectId")) |val| switch (val) {
                .string => |sid| {
                    const id = std.fmt.parseInt(u64, sid, 10) catch 0;
                    if (state.findObjectHandle(id)) |handle| switch (handle.kind) {
                        .expression => {
                            try buf.writer.writeAll("(");
                            try buf.writer.writeAll(handle.expression);
                            try buf.writer.writeAll(")");
                            return;
                        },
                        .dom_node => {
                            try buf.writer.writeAll("undefined");
                            return;
                        },
                    };
                    try buf.writer.writeAll("undefined");
                    return;
                },
                else => {},
            };
            try buf.writer.writeAll("undefined");
        },
        else => {
            try std.json.Stringify.value(entry, .{}, &buf.writer);
        },
    }
}

fn propertiesForHandle(allocator: std.mem.Allocator, state: *const CdpState, handle: ObjectHandle) ![]const u8 {
    switch (handle.kind) {
        .dom_node => return propertiesForDomNode(allocator, state, handle.dom_node_id),
        .expression => return propertiesForExpression(allocator, state, handle.expression),
    }
}

fn propertiesForDomNode(allocator: std.mem.Allocator, state: *const CdpState, internal_id: dom.NodeId) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.writeAll("{\"result\":[");
    if (state.page) |page| {
        if (internal_id < page.dom.nodes.len) {
            const node = page.dom.getNode(internal_id);
            var first = true;
            try writeStringProperty(&buf, &first, "nodeName", switch (node.kind) {
                .document => "#document",
                .text => "#text",
                .element => node.name,
            });
            try writeNumberProperty(&buf, &first, "nodeType", switch (node.kind) {
                .document => @as(i64, 9),
                .element => 1,
                .text => 3,
            });
            if (node.kind == .element) {
                try writeStringProperty(&buf, &first, "tagName", node.name);
                if (page.dom.getAttribute(internal_id, "id")) |id| {
                    try writeStringProperty(&buf, &first, "id", id);
                }
                if (page.dom.getAttribute(internal_id, "class")) |cls| {
                    try writeStringProperty(&buf, &first, "className", cls);
                }
                const outer = page.dom.outerHtml(internal_id);
                try writeStringProperty(&buf, &first, "outerHTML", outer);
            } else if (node.kind == .text) {
                try writeStringProperty(&buf, &first, "nodeValue", node.text);
                try writeStringProperty(&buf, &first, "data", node.text);
            }
            var child_count: usize = 0;
            var c = node.first_child;
            while (c) |cid| : (c = page.dom.nodes[cid].next_sibling) child_count += 1;
            try writeNumberProperty(&buf, &first, "childElementCount", @intCast(child_count));
        }
    }
    try buf.writer.writeAll("],\"internalProperties\":[]}");
    return allocator.dupe(u8, buf.written());
}

fn propertiesForExpression(allocator: std.mem.Allocator, state: *const CdpState, expression: []const u8) ![]const u8 {
    // Evaluate `Object.keys(expr)` to enumerate properties.
    const wrapped = try std.fmt.allocPrint(allocator, "Object.keys({s}).join(',')", .{expression});
    defer allocator.free(wrapped);
    const eval = if (state.page) |*page|
        try js_runtime.evaluateExpressionOnPage(allocator, page, wrapped)
    else
        return allocator.dupe(u8, "{\"result\":[],\"internalProperties\":[]}");
    if (eval.error_message.len != 0) {
        return allocator.dupe(u8, "{\"result\":[],\"internalProperties\":[]}");
    }
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.writeAll("{\"result\":[");
    var iter = std.mem.splitScalar(u8, eval.eval_result, ',');
    var first = true;
    while (iter.next()) |key| {
        if (key.len == 0) continue;
        const value_expr = try std.fmt.allocPrint(allocator, "String(({s})[{s}])", .{ expression, try jsonStringLiteral(allocator, key) });
        defer allocator.free(value_expr);
        const value_eval = if (state.page) |*page|
            try js_runtime.evaluateExpressionOnPage(allocator, page, value_expr)
        else
            continue;
        try writeStringProperty(&buf, &first, key, value_eval.eval_result);
    }
    try buf.writer.writeAll("],\"internalProperties\":[]}");
    return allocator.dupe(u8, buf.written());
}

fn writeStringProperty(buf: *std.Io.Writer.Allocating, first: *bool, name: []const u8, value: []const u8) !void {
    if (!first.*) try buf.writer.writeByte(',');
    first.* = false;
    const writer = buf.writer;
    _ = writer;
    try buf.writer.writeAll("{\"name\":");
    try std.json.Stringify.value(name, .{}, &buf.writer);
    try buf.writer.writeAll(",\"value\":{\"type\":\"string\",\"value\":");
    try std.json.Stringify.value(value, .{}, &buf.writer);
    try buf.writer.writeAll(",\"description\":");
    try std.json.Stringify.value(value, .{}, &buf.writer);
    try buf.writer.writeAll("},\"writable\":false,\"enumerable\":true,\"configurable\":false,\"isOwn\":true}");
}

fn writeNumberProperty(buf: *std.Io.Writer.Allocating, first: *bool, name: []const u8, value: i64) !void {
    if (!first.*) try buf.writer.writeByte(',');
    first.* = false;
    try buf.writer.writeAll("{\"name\":");
    try std.json.Stringify.value(name, .{}, &buf.writer);
    try buf.writer.print(",\"value\":{{\"type\":\"number\",\"value\":{d},\"description\":\"{d}\"}},\"writable\":false,\"enumerable\":true,\"configurable\":false,\"isOwn\":true}}", .{ value, value });
}

fn appendCookieFromValue(state: *CdpState, allocator: std.mem.Allocator, value: std.json.Value) !void {
    const obj = switch (value) {
        .object => |o| o,
        else => return,
    };
    const name = if (obj.get("name")) |v| switch (v) { .string => |s| s, else => return } else return;
    var c: Cookie = .{ .name = name };
    if (obj.get("value")) |v| switch (v) { .string => |s| c.value = s, else => {} };
    if (obj.get("url")) |v| switch (v) { .string => |s| c.url = s, else => {} };
    if (obj.get("domain")) |v| switch (v) { .string => |s| c.domain = s, else => {} };
    if (obj.get("path")) |v| switch (v) { .string => |s| c.path = s, else => {} };
    if (obj.get("secure")) |v| switch (v) { .bool => |b| c.secure = b, else => {} };
    if (obj.get("httpOnly")) |v| switch (v) { .bool => |b| c.http_only = b, else => {} };
    if (obj.get("sameSite")) |v| switch (v) { .string => |s| c.same_site = s, else => {} };
    if (obj.get("expires")) |v| switch (v) {
        .integer => |n| c.expires = @floatFromInt(n),
        .float => |f| c.expires = f,
        else => {},
    };
    try state.cookies.append(allocator, c);
}

fn cookiesResultJson(allocator: std.mem.Allocator, state: *const CdpState) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.writeAll("{\"cookies\":[");
    for (state.cookies.items, 0..) |c, idx| {
        if (idx > 0) try buf.writer.writeByte(',');
        const name = try jsonStringLiteral(allocator, c.name);
        const value = try jsonStringLiteral(allocator, c.value);
        const domain = try jsonStringLiteral(allocator, c.domain);
        const path = try jsonStringLiteral(allocator, c.path);
        const same_site = try jsonStringLiteral(allocator, c.same_site);
        try buf.writer.print(
            "{{\"name\":{s},\"value\":{s},\"domain\":{s},\"path\":{s},\"expires\":{d},\"size\":{d},\"httpOnly\":{s},\"secure\":{s},\"session\":{s},\"sameSite\":{s},\"priority\":\"Medium\"}}",
            .{
                name, value, domain, path,
                c.expires,
                c.name.len + c.value.len,
                if (c.http_only) "true" else "false",
                if (c.secure) "true" else "false",
                if (c.expires < 0) "true" else "false",
                same_site,
            });
    }
    try buf.writer.writeAll("]}");
    return allocator.dupe(u8, buf.written());
}

fn navigationHistoryJson(allocator: std.mem.Allocator, state: *const CdpState) ![]const u8 {
    const url = try jsonStringLiteral(allocator, state.current_url);
    const title = try jsonStringLiteral(allocator, state.title);
    return std.fmt.allocPrint(
        allocator,
        "{{\"currentIndex\":0,\"entries\":[{{\"id\":1,\"url\":{s},\"userTypedURL\":{s},\"title\":{s},\"transitionType\":\"link\"}}]}}",
        .{ url, url, title },
    );
}

fn windowBoundsJson(allocator: std.mem.Allocator, state: *const CdpState, include_window_id: bool) ![]const u8 {
    const state_str = try jsonStringLiteral(allocator, state.window_state);
    if (include_window_id) {
        return std.fmt.allocPrint(
            allocator,
            "{{\"windowId\":{d},\"bounds\":{{\"left\":{d},\"top\":{d},\"width\":{d},\"height\":{d},\"windowState\":{s}}}}}",
            .{ window_id, state.window_left, state.window_top, state.window_width, state.window_height, state_str },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{{\"bounds\":{{\"left\":{d},\"top\":{d},\"width\":{d},\"height\":{d},\"windowState\":{s}}}}}",
        .{ state.window_left, state.window_top, state.window_width, state.window_height, state_str },
    );
}

fn layoutMetricsJson(allocator: std.mem.Allocator, state: *const CdpState) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"layoutViewport\":{{\"pageX\":0,\"pageY\":0,\"clientWidth\":{d},\"clientHeight\":{d}}},\"visualViewport\":{{\"offsetX\":0,\"offsetY\":0,\"pageX\":0,\"pageY\":0,\"clientWidth\":{d},\"clientHeight\":{d},\"scale\":1,\"zoom\":1}},\"contentSize\":{{\"x\":0,\"y\":0,\"width\":{d},\"height\":{d}}},\"cssLayoutViewport\":{{\"pageX\":0,\"pageY\":0,\"clientWidth\":{d},\"clientHeight\":{d}}},\"cssVisualViewport\":{{\"offsetX\":0,\"offsetY\":0,\"pageX\":0,\"pageY\":0,\"clientWidth\":{d},\"clientHeight\":{d},\"scale\":1,\"zoom\":1}},\"cssContentSize\":{{\"x\":0,\"y\":0,\"width\":{d},\"height\":{d}}}}}",
        .{
            state.viewport_width, state.viewport_height,
            state.viewport_width, state.viewport_height,
            state.viewport_width, state.viewport_height,
            state.viewport_width, state.viewport_height,
            state.viewport_width, state.viewport_height,
            state.viewport_width, state.viewport_height,
        });
}

fn resourceTreeJson(allocator: std.mem.Allocator, state: *const CdpState) ![]const u8 {
    const url = try jsonStringLiteral(allocator, state.current_url);
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.print(
        "{{\"frameTree\":{{\"frame\":{{\"id\":\"{s}\",\"loaderId\":\"{s}\",\"url\":{s},\"securityOrigin\":{s},\"mimeType\":\"text/html\"}},\"resources\":[",
        .{ frame_id, loader_id, url, url });
    if (state.page) |page| {
        for (page.resources, 0..) |res, idx| {
            if (idx > 0) try buf.writer.writeByte(',');
            const r_url = try jsonStringLiteral(allocator, res.url);
            const r_type = try jsonStringLiteral(allocator, res.kind);
            const r_mime = try jsonStringLiteral(allocator, res.content_type);
            try buf.writer.print("{{\"url\":{s},\"type\":{s},\"mimeType\":{s}}}", .{ r_url, r_type, r_mime });
        }
    }
    try buf.writer.writeAll("]}}");
    return allocator.dupe(u8, buf.written());
}

fn cdpToInternal(node_id: u64) ?dom.NodeId {
    if (node_id == 0) return null;
    return @intCast(node_id - 1);
}

fn internalToCdp(node_id: dom.NodeId) u64 {
    return @as(u64, node_id) + 1;
}

fn renderDomTree(allocator: std.mem.Allocator, state: *const CdpState, depth: i32, pierce: bool) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    if (state.page) |page| {
        try appendNodeJson(allocator, &page.dom, page.dom.root_id, depth, pierce, &buf);
    } else {
        const url = try jsonStringLiteral(allocator, state.current_url);
        try buf.writer.print(
            "{{\"nodeId\":1,\"backendNodeId\":1,\"nodeType\":9,\"nodeName\":\"#document\",\"localName\":\"\",\"nodeValue\":\"\",\"documentURL\":{s},\"baseURL\":{s},\"childNodeCount\":0,\"children\":[]}}",
            .{ url, url });
    }
    return allocator.dupe(u8, buf.written());
}

fn renderDomTreeFlattened(allocator: std.mem.Allocator, state: *const CdpState, depth: i32) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    if (state.page) |page| {
        var first = true;
        try appendFlatNodeJson(allocator, &page.dom, page.dom.root_id, depth, &buf, &first);
    }
    return allocator.dupe(u8, buf.written());
}

fn appendFlatNodeJson(
    allocator: std.mem.Allocator,
    doc: *const dom.Document,
    node_id: dom.NodeId,
    depth: i32,
    buf: *std.Io.Writer.Allocating,
    first: *bool,
) !void {
    if (!first.*) try buf.writer.writeByte(',');
    first.* = false;
    try appendShallowNodeJson(allocator, doc, node_id, buf);
    if (depth == 0) return;
    const node = doc.getNode(node_id);
    var child = node.first_child;
    while (child) |child_id| : (child = doc.nodes[child_id].next_sibling) {
        try appendFlatNodeJson(allocator, doc, child_id, depth - 1, buf, first);
    }
}

fn appendNodeJson(
    allocator: std.mem.Allocator,
    doc: *const dom.Document,
    node_id: dom.NodeId,
    depth: i32,
    pierce: bool,
    buf: *std.Io.Writer.Allocating,
) !void {
    _ = pierce;
    const node = doc.getNode(node_id);
    const cdp_id = internalToCdp(node_id);
    const node_type: u32 = switch (node.kind) {
        .document => 9,
        .element => 1,
        .text => 3,
    };
    const display_name: []const u8 = switch (node.kind) {
        .document => "#document",
        .text => "#text",
        .element => node.name,
    };
    const name_q = try jsonStringLiteral(allocator, display_name);
    const local_q = try jsonStringLiteral(allocator, if (node.kind == .element) node.name else "");
    const value_q = try jsonStringLiteral(allocator, if (node.kind == .text) node.text else "");

    try buf.writer.print(
        "{{\"nodeId\":{d},\"backendNodeId\":{d},\"nodeType\":{d},\"nodeName\":{s},\"localName\":{s},\"nodeValue\":{s}",
        .{ cdp_id, cdp_id, node_type, name_q, local_q, value_q });

    if (node.kind == .document) {
        try buf.writer.writeAll(",\"documentURL\":\"\",\"baseURL\":\"\",\"xmlVersion\":\"\"");
    }

    if (node.kind == .element and node.attrs.len > 0) {
        try buf.writer.writeAll(",\"attributes\":[");
        for (node.attrs, 0..) |attr, idx| {
            if (idx > 0) try buf.writer.writeByte(',');
            const aname = try jsonStringLiteral(allocator, attr.name);
            const avalue = try jsonStringLiteral(allocator, attr.value);
            try buf.writer.print("{s},{s}", .{ aname, avalue });
        }
        try buf.writer.writeByte(']');
    }

    var child_count: usize = 0;
    var child = node.first_child;
    while (child) |child_id| : (child = doc.nodes[child_id].next_sibling) child_count += 1;
    try buf.writer.print(",\"childNodeCount\":{d}", .{child_count});

    if (depth != 0 and child_count > 0) {
        try buf.writer.writeAll(",\"children\":[");
        var child_iter = node.first_child;
        var first_child = true;
        while (child_iter) |child_id| : (child_iter = doc.nodes[child_id].next_sibling) {
            if (!first_child) try buf.writer.writeByte(',');
            first_child = false;
            try appendNodeJson(allocator, doc, child_id, depth - 1, false, buf);
        }
        try buf.writer.writeByte(']');
    }

    try buf.writer.writeByte('}');
}
fn appendShallowNodeJson(
    allocator: std.mem.Allocator,
    doc: *const dom.Document,
    node_id: dom.NodeId,
    buf: *std.Io.Writer.Allocating,
) !void {
    const node = doc.getNode(node_id);
    const cdp_id = internalToCdp(node_id);
    const node_type: u32 = switch (node.kind) {
        .document => 9,
        .element => 1,
        .text => 3,
    };
    const display_name: []const u8 = switch (node.kind) {
        .document => "#document",
        .text => "#text",
        .element => node.name,
    };
    const name_q = try jsonStringLiteral(allocator, display_name);
    const local_q = try jsonStringLiteral(allocator, if (node.kind == .element) node.name else "");
    const value_q = try jsonStringLiteral(allocator, if (node.kind == .text) node.text else "");
    try buf.writer.print(
        "{{\"nodeId\":{d},\"backendNodeId\":{d},\"nodeType\":{d},\"nodeName\":{s},\"localName\":{s},\"nodeValue\":{s}",
        .{ cdp_id, cdp_id, node_type, name_q, local_q, value_q });
    if (node.kind == .element and node.attrs.len > 0) {
        try buf.writer.writeAll(",\"attributes\":[");
        for (node.attrs, 0..) |attr, idx| {
            if (idx > 0) try buf.writer.writeByte(',');
            const aname = try jsonStringLiteral(allocator, attr.name);
            const avalue = try jsonStringLiteral(allocator, attr.value);
            try buf.writer.print("{s},{s}", .{ aname, avalue });
        }
        try buf.writer.writeByte(']');
    }
    try buf.writer.writeByte('}');
}


fn appendToFocused(state: *CdpState, text: []const u8) !void {
    const node = state.focused_node orelse return;
    const current = currentInputValue(state, node);
    const buf = try state.allocator.alloc(u8, current.len + text.len);
    std.mem.copyForwards(u8, buf[0..current.len], current);
    std.mem.copyForwards(u8, buf[current.len..], text);
    try setInputOverride(state, node, buf);
}

fn eraseLastFromFocused(state: *CdpState) void {
    const node = state.focused_node orelse return;
    const current = currentInputValue(state, node);
    if (current.len == 0) return;
    var new_len: usize = current.len - 1;
    while (new_len > 0 and (current[new_len] & 0xC0) == 0x80) : (new_len -= 1) {}
    setInputOverrideUnchecked(state, node, current[0..new_len]);
}

fn currentInputValue(state: *const CdpState, node_id: dom.NodeId) []const u8 {
    for (state.input_overrides.items) |override| {
        if (override.node_id == node_id) return override.value;
    }
    if (state.page) |page| {
        if (node_id < page.dom.nodes.len) {
            if (page.dom.getAttribute(node_id, "value")) |v| return v;
        }
    }
    return "";
}

fn setInputOverride(state: *CdpState, node_id: dom.NodeId, value: []const u8) !void {
    for (state.input_overrides.items) |*override| {
        if (override.node_id == node_id) {
            override.value = value;
            return;
        }
    }
    try state.input_overrides.append(state.allocator, .{ .node_id = node_id, .value = value });
}

fn setInputOverrideUnchecked(state: *CdpState, node_id: dom.NodeId, value: []const u8) void {
    for (state.input_overrides.items) |*override| {
        if (override.node_id == node_id) {
            override.value = value;
            return;
        }
    }
    state.input_overrides.append(state.allocator, .{ .node_id = node_id, .value = value }) catch {};
}

fn resolveQuerySelector(allocator: std.mem.Allocator, state: *CdpState, selector: []const u8) !?u64 {
    const page = state.page orelse return null;
    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const internal_id = (try page.dom.querySelector(arena_impl.allocator(), selector)) orelse return null;
    return internalToCdp(internal_id);
}

fn resolveQuerySelectorAll(allocator: std.mem.Allocator, state: *CdpState, selector: []const u8) ![]u64 {
    const page = state.page orelse return allocator.alloc(u64, 0);
    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const internal = try page.dom.querySelectorAll(arena_impl.allocator(), page.dom.root_id, selector);
    const out = try allocator.alloc(u64, internal.len);
    for (internal, 0..) |id, idx| out[idx] = internalToCdp(id);
    return out;
}

fn outerHtmlForRequest(allocator: std.mem.Allocator, state: *CdpState, params: ?std.json.Value) !?[]const u8 {
    const page = state.page orelse return null;
    const node_id = paramU64(params, "nodeId") orelse 0;
    const internal = cdpToInternal(node_id) orelse return null;
    if (internal >= page.dom.nodes.len) return null;
    return try allocator.dupe(u8, page.dom.outerHtml(internal));
}

fn attributesArrayJson(allocator: std.mem.Allocator, state: *CdpState, node_id: u64) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.writeByte('[');
    if (state.page) |page| {
        const internal = cdpToInternal(node_id) orelse {
            try buf.writer.writeByte(']');
            return allocator.dupe(u8, buf.written());
        };
        if (internal < page.dom.nodes.len) {
            const node = page.dom.getNode(internal);
            if (node.kind == .element) {
                for (node.attrs, 0..) |attr, idx| {
                    if (idx > 0) try buf.writer.writeByte(',');
                    const n = try jsonStringLiteral(allocator, attr.name);
                    const v = try jsonStringLiteral(allocator, attr.value);
                    try buf.writer.print("{s},{s}", .{ n, v });
                }
            }
        }
    }
    try buf.writer.writeByte(']');
    return allocator.dupe(u8, buf.written());
}

fn describedNodeJson(allocator: std.mem.Allocator, state: *CdpState, node_id: u64) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    if (state.page) |page| {
        const internal = cdpToInternal(node_id) orelse {
            try appendShallowNodeJson(allocator, &page.dom, page.dom.root_id, &buf);
            return allocator.dupe(u8, buf.written());
        };
        if (internal < page.dom.nodes.len) {
            try appendShallowNodeJson(allocator, &page.dom, internal, &buf);
            return allocator.dupe(u8, buf.written());
        }
    }
    try buf.writer.writeAll("{\"nodeId\":1,\"backendNodeId\":1,\"nodeType\":9,\"nodeName\":\"#document\",\"localName\":\"\",\"nodeValue\":\"\"}");
    return allocator.dupe(u8, buf.written());
}

fn nodeDescription(allocator: std.mem.Allocator, state: *CdpState, node_id: u64) ![]const u8 {
    if (state.page) |page| {
        const internal = cdpToInternal(node_id) orelse return allocator.dupe(u8, "#document");
        if (internal < page.dom.nodes.len) {
            const node = page.dom.getNode(internal);
            return switch (node.kind) {
                .document => allocator.dupe(u8, "#document"),
                .text => allocator.dupe(u8, "#text"),
                .element => std.fmt.allocPrint(allocator, "{s}", .{node.name}),
            };
        }
    }
    return allocator.dupe(u8, "#document");
}


// ---------------- CSS helpers ----------------

fn pageStylesheetText(allocator: std.mem.Allocator, state: *const CdpState) ![]const u8 {
    if (state.page) |page| {
        return css.extractAllStyleText(allocator, &page.dom);
    }
    return allocator.dupe(u8, "");
}

fn cssStyleSheetTextJson(allocator: std.mem.Allocator, state: *const CdpState) ![]const u8 {
    const text = try pageStylesheetText(allocator, state);
    const quoted = try jsonStringLiteral(allocator, text);
    return std.fmt.allocPrint(allocator, "{{\"text\":{s}}}", .{quoted});
}

fn cssCollectClassNamesJson(allocator: std.mem.Allocator, state: *const CdpState) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.writeAll("{\"classNames\":[");
    if (state.page) |page| {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(allocator);
        var first = true;
        for (page.dom.nodes) |node| {
            if (node.kind != .element) continue;
            for (node.attrs) |attr| {
                if (!std.ascii.eqlIgnoreCase(attr.name, "class")) continue;
                var iter = std.mem.tokenizeAny(u8, attr.value, " \t\r\n");
                while (iter.next()) |token| {
                    if (token.len == 0) continue;
                    if (seen.contains(token)) continue;
                    try seen.put(allocator, token, {});
                    if (!first) try buf.writer.writeByte(',');
                    first = false;
                    const quoted = try jsonStringLiteral(allocator, token);
                    try buf.writer.writeAll(quoted);
                }
            }
        }
    }
    try buf.writer.writeAll("]}");
    return allocator.dupe(u8, buf.written());
}

fn parseStateSheets(allocator: std.mem.Allocator, state: *const CdpState) !struct {
    ua: css.Stylesheet,
    author: css.Stylesheet,
} {
    const ua = try css.loadUserAgentSheet(allocator);
    errdefer {
        var ua_copy = ua;
        ua_copy.deinit();
    }
    const text = try pageStylesheetText(allocator, state);
    const author = try css.Stylesheet.fromText(allocator, text, .author);
    return .{ .ua = ua, .author = author };
}

fn nodeInlineStyleAttr(state: *const CdpState, node_id: u64) []const u8 {
    const page = state.page orelse return "";
    const internal = cdpToInternal(node_id) orelse return "";
    if (internal >= page.dom.nodes.len) return "";
    return page.dom.getAttribute(internal, "style") orelse "";
}

fn cssComputedStyleJson(allocator: std.mem.Allocator, state: *CdpState, node_id: u64) ![]const u8 {
    const page = state.page orelse return allocator.dupe(u8, "{\"computedStyle\":[]}");
    const internal = cdpToInternal(node_id) orelse return allocator.dupe(u8, "{\"computedStyle\":[]}");
    if (internal >= page.dom.nodes.len) return allocator.dupe(u8, "{\"computedStyle\":[]}");

    var sheets = try parseStateSheets(allocator, state);
    defer sheets.ua.deinit();
    defer sheets.author.deinit();

    const inline_attr = nodeInlineStyleAttr(state, node_id);
    const sheet_list: []const *const css.Stylesheet = &.{ &sheets.ua, &sheets.author };
    const computed = try css.computeStyleForNode(allocator, sheet_list, &page.dom, internal, inline_attr);
    defer if (computed.properties.len > 0) allocator.free(computed.properties);

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.writeAll("{\"computedStyle\":[");
    for (computed.properties, 0..) |prop, idx| {
        if (idx > 0) try buf.writer.writeByte(',');
        const name_q = try jsonStringLiteral(allocator, prop.name);
        const value_q = try jsonStringLiteral(allocator, prop.value);
        try buf.writer.print("{{\"name\":{s},\"value\":{s}}}", .{ name_q, value_q });
    }
    try buf.writer.writeAll("]}");
    return allocator.dupe(u8, buf.written());
}

fn cssMatchedStylesJson(allocator: std.mem.Allocator, state: *CdpState, node_id: u64) ![]const u8 {
    const page = state.page orelse return allocator.dupe(u8, "{\"matchedCSSRules\":[],\"pseudoElements\":[],\"inherited\":[],\"cssKeyframesRules\":[]}");
    const internal = cdpToInternal(node_id) orelse return allocator.dupe(u8, "{\"matchedCSSRules\":[],\"pseudoElements\":[],\"inherited\":[],\"cssKeyframesRules\":[]}");
    if (internal >= page.dom.nodes.len) return allocator.dupe(u8, "{\"matchedCSSRules\":[],\"pseudoElements\":[],\"inherited\":[],\"cssKeyframesRules\":[]}");

    var sheets = try parseStateSheets(allocator, state);
    defer sheets.ua.deinit();
    defer sheets.author.deinit();

    const sheet_list: []const *const css.Stylesheet = &.{ &sheets.ua, &sheets.author };
    const matched = try css.matchedRulesForNode(allocator, sheet_list, &page.dom, internal);
    defer allocator.free(matched);

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const inline_attr = nodeInlineStyleAttr(state, node_id);
    try buf.writer.writeAll("{");
    if (inline_attr.len > 0) {
        try buf.writer.writeAll("\"inlineStyle\":");
        try writeCssStyleObject(allocator, &buf, inline_attr, "kuri-stylesheet-inline");
        try buf.writer.writeByte(',');
    }
    try buf.writer.writeAll("\"matchedCSSRules\":[");
    for (matched, 0..) |rule, idx| {
        if (idx > 0) try buf.writer.writeByte(',');
        try writeMatchedRule(allocator, &buf, rule);
    }
    try buf.writer.writeAll("],\"pseudoElements\":[],\"inherited\":[],\"cssKeyframesRules\":[]}");
    return allocator.dupe(u8, buf.written());
}

fn cssInlineStylesJson(allocator: std.mem.Allocator, state: *CdpState, node_id: u64) ![]const u8 {
    const inline_attr = nodeInlineStyleAttr(state, node_id);
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.writeAll("{\"inlineStyle\":");
    if (inline_attr.len == 0) {
        try buf.writer.writeAll("null");
    } else {
        try writeCssStyleObject(allocator, &buf, inline_attr, "kuri-stylesheet-inline");
    }
    try buf.writer.writeAll(",\"attributesStyle\":null}");
    return allocator.dupe(u8, buf.written());
}

fn cssBackgroundColorsJson(allocator: std.mem.Allocator, state: *CdpState, node_id: u64) ![]const u8 {
    const page = state.page orelse return allocator.dupe(u8, "{\"backgroundColors\":[],\"computedFontSize\":\"16px\",\"computedFontWeight\":\"400\"}");
    const internal = cdpToInternal(node_id) orelse return allocator.dupe(u8, "{\"backgroundColors\":[],\"computedFontSize\":\"16px\",\"computedFontWeight\":\"400\"}");
    if (internal >= page.dom.nodes.len) return allocator.dupe(u8, "{\"backgroundColors\":[],\"computedFontSize\":\"16px\",\"computedFontWeight\":\"400\"}");

    var sheets = try parseStateSheets(allocator, state);
    defer sheets.ua.deinit();
    defer sheets.author.deinit();
    const inline_attr = nodeInlineStyleAttr(state, node_id);
    const sheet_list: []const *const css.Stylesheet = &.{ &sheets.ua, &sheets.author };
    const computed = try css.computeStyleForNode(allocator, sheet_list, &page.dom, internal, inline_attr);
    defer if (computed.properties.len > 0) allocator.free(computed.properties);

    const bg = computed.get("background-color") orelse computed.get("background") orelse "rgba(0,0,0,0)";
    const font_size = computed.get("font-size") orelse "16px";
    const font_weight = computed.get("font-weight") orelse "400";
    const bg_q = try jsonStringLiteral(allocator, bg);
    const fs_q = try jsonStringLiteral(allocator, font_size);
    const fw_q = try jsonStringLiteral(allocator, font_weight);
    return std.fmt.allocPrint(
        allocator,
        "{{\"backgroundColors\":[{s}],\"computedFontSize\":{s},\"computedFontWeight\":{s}}}",
        .{ bg_q, fs_q, fw_q });
}

fn writeCssStyleObject(
    allocator: std.mem.Allocator,
    buf: *std.Io.Writer.Allocating,
    declarations_text: []const u8,
    style_id: []const u8,
) !void {
    const decls = try css.parseDeclarations(allocator, declarations_text);
    defer allocator.free(decls);
    const id_q = try jsonStringLiteral(allocator, style_id);
    const text_q = try jsonStringLiteral(allocator, declarations_text);
    try buf.writer.print("{{\"styleSheetId\":{s},\"cssText\":{s},\"cssProperties\":[", .{ id_q, text_q });
    for (decls, 0..) |decl, idx| {
        if (idx > 0) try buf.writer.writeByte(',');
        const name_q = try jsonStringLiteral(allocator, decl.name);
        const value_q = try jsonStringLiteral(allocator, decl.value);
        try buf.writer.print("{{\"name\":{s},\"value\":{s},\"important\":{s},\"implicit\":false,\"disabled\":false}}", .{
            name_q,
            value_q,
            if (decl.important) "true" else "false",
        });
    }
    try buf.writer.writeAll("],\"shorthandEntries\":[]}");
}

fn writeMatchedRule(
    allocator: std.mem.Allocator,
    buf: *std.Io.Writer.Allocating,
    matched: css.MatchedRule,
) !void {
    const sel_text_q = try jsonStringLiteral(allocator, matched.selector.text);
    const origin_text = switch (matched.origin) {
        .user_agent => "user-agent",
        .author => "regular",
        .inline_style => "inline",
    };
    try buf.writer.print(
        "{{\"rule\":{{\"selectorList\":{{\"selectors\":[{{\"text\":{s},\"specificity\":{{\"a\":{d},\"b\":{d},\"c\":{d}}}}}],\"text\":{s}}},\"origin\":\"{s}\",\"style\":",
        .{
            sel_text_q,
            (matched.selector.specificity >> 16) & 0xFF,
            (matched.selector.specificity >> 8) & 0xFF,
            matched.selector.specificity & 0xFF,
            sel_text_q,
            origin_text,
        });
    try writeDeclarationsAsStyle(allocator, buf, matched.declarations);
    try buf.writer.writeAll("}, \"matchingSelectors\":[0]}");
}

fn writeDeclarationsAsStyle(
    allocator: std.mem.Allocator,
    buf: *std.Io.Writer.Allocating,
    declarations: []const css.Declaration,
) !void {
    try buf.writer.writeAll("{\"styleSheetId\":\"kuri-stylesheet-1\",\"cssText\":\"\",\"cssProperties\":[");
    for (declarations, 0..) |decl, idx| {
        if (idx > 0) try buf.writer.writeByte(',');
        const name_q = try jsonStringLiteral(allocator, decl.name);
        const value_q = try jsonStringLiteral(allocator, decl.value);
        try buf.writer.print("{{\"name\":{s},\"value\":{s},\"important\":{s},\"implicit\":false,\"disabled\":false}}", .{
            name_q,
            value_q,
            if (decl.important) "true" else "false",
        });
    }
    try buf.writer.writeAll("],\"shorthandEntries\":[]}");
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
    const start_lifecycle = try std.fmt.allocPrint(allocator, "{{\"frameId\":\"{s}\",\"loaderId\":\"{s}\",\"name\":\"init\",\"timestamp\":0}}", .{ frame_id, loader_id });
    const dom_lifecycle = try std.fmt.allocPrint(allocator, "{{\"frameId\":\"{s}\",\"loaderId\":\"{s}\",\"name\":\"DOMContentLoaded\",\"timestamp\":0}}", .{ frame_id, loader_id });
    const load_lifecycle = try std.fmt.allocPrint(allocator, "{{\"frameId\":\"{s}\",\"loaderId\":\"{s}\",\"name\":\"load\",\"timestamp\":0}}", .{ frame_id, loader_id });
    const network_idle = try std.fmt.allocPrint(allocator, "{{\"frameId\":\"{s}\",\"loaderId\":\"{s}\",\"name\":\"networkIdle\",\"timestamp\":0}}", .{ frame_id, loader_id });
    const title_params = try std.fmt.allocPrint(allocator, "{{\"title\":{s}}}", .{title});
    try sendEvent(ws, allocator, sid, "Page.frameStartedLoading", try std.fmt.allocPrint(allocator, "{{\"frameId\":\"{s}\"}}", .{frame_id}));
    try sendEvent(ws, allocator, sid, "Page.frameNavigated", frame);
    if (state.lifecycle_events_enabled) {
        try sendEvent(ws, allocator, sid, "Page.lifecycleEvent", start_lifecycle);
        try sendEvent(ws, allocator, sid, "Page.lifecycleEvent", dom_lifecycle);
    }
    try sendEvent(ws, allocator, sid, "Page.domContentEventFired", "{\"timestamp\":0}");
    try sendEvent(ws, allocator, sid, "Page.loadEventFired", "{\"timestamp\":0}");
    if (state.lifecycle_events_enabled) {
        try sendEvent(ws, allocator, sid, "Page.lifecycleEvent", load_lifecycle);
        try sendEvent(ws, allocator, sid, "Page.lifecycleEvent", network_idle);
    }
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

const browser_version_result =
    \\{"protocolVersion":"1.3","product":"KuriBrowser/0.0.0","revision":"kuri-browser","userAgent":"kuri-browser/0.0.0","jsVersion":"QuickJS with V8-shaped CDP Runtime objects"}
;

const schemaDomainsResult =
    \\{"domains":[{"name":"Browser","version":"1.3"},{"name":"Target","version":"1.3"},{"name":"Page","version":"1.3"},{"name":"Runtime","version":"1.3"},{"name":"Network","version":"1.3"},{"name":"DOM","version":"1.3"},{"name":"Input","version":"1.3"},{"name":"Emulation","version":"1.3"},{"name":"Storage","version":"1.3"},{"name":"Security","version":"1.3"},{"name":"Inspector","version":"1.3"},{"name":"Log","version":"1.3"},{"name":"Performance","version":"1.3"},{"name":"Schema","version":"1.3"},{"name":"Fetch","version":"1.3"},{"name":"IO","version":"1.3"},{"name":"CSS","version":"1.3"},{"name":"Debugger","version":"1.3"},{"name":"HeapProfiler","version":"1.3"},{"name":"Profiler","version":"1.3"},{"name":"Tracing","version":"1.3"},{"name":"Memory","version":"1.3"},{"name":"HeadlessExperimental","version":"1.3"},{"name":"Animation","version":"1.3"},{"name":"Audits","version":"1.3"},{"name":"Overlay","version":"1.3"},{"name":"LayerTree","version":"1.3"},{"name":"ServiceWorker","version":"1.3"},{"name":"IndexedDB","version":"1.3"},{"name":"CacheStorage","version":"1.3"},{"name":"DOMStorage","version":"1.3"},{"name":"Console","version":"1.3"},{"name":"Accessibility","version":"1.3"}]}
;

fn protocolJson() []const u8 {
    return
        \\{"version":{"major":"1","minor":"3"},"domains":[
        \\{"domain":"Browser","experimental":false,"deprecated":false,"commands":[{"name":"getVersion"},{"name":"close"},{"name":"getWindowForTarget"},{"name":"getWindowBounds"},{"name":"setWindowBounds"},{"name":"setDownloadBehavior"},{"name":"setPermission"},{"name":"resetPermissions"},{"name":"grantPermissions"},{"name":"getHistograms"}],"events":[]},
        \\{"domain":"Target","experimental":false,"deprecated":false,"commands":[{"name":"getTargets"},{"name":"createTarget"},{"name":"attachToTarget"},{"name":"detachFromTarget"},{"name":"setDiscoverTargets"},{"name":"setAutoAttach"},{"name":"closeTarget"},{"name":"createBrowserContext"},{"name":"disposeBrowserContext"},{"name":"getBrowserContexts"}],"events":[{"name":"targetCreated"},{"name":"targetDestroyed"},{"name":"targetInfoChanged"}]},
        \\{"domain":"Page","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"},{"name":"navigate"},{"name":"reload"},{"name":"stopLoading"},{"name":"getFrameTree"},{"name":"getResourceTree"},{"name":"getLayoutMetrics"},{"name":"getNavigationHistory"},{"name":"resetNavigationHistory"},{"name":"setLifecycleEventsEnabled"},{"name":"setBypassCSP"},{"name":"addScriptToEvaluateOnNewDocument"},{"name":"removeScriptToEvaluateOnNewDocument"},{"name":"bringToFront"},{"name":"handleJavaScriptDialog"},{"name":"setDownloadBehavior"},{"name":"captureScreenshot"},{"name":"printToPDF"},{"name":"captureSnapshot"},{"name":"getAppManifest"},{"name":"getInstallabilityErrors"}],"events":[{"name":"frameStartedLoading"},{"name":"frameNavigated"},{"name":"frameStoppedLoading"},{"name":"loadEventFired"},{"name":"domContentEventFired"},{"name":"lifecycleEvent"},{"name":"titleChanged"}]},
        \\{"domain":"Runtime","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"},{"name":"evaluate"},{"name":"callFunctionOn"},{"name":"getProperties"},{"name":"releaseObject"},{"name":"compileScript"},{"name":"runScript"},{"name":"awaitPromise"},{"name":"getIsolateId"},{"name":"getHeapUsage"}],"events":[{"name":"executionContextCreated"},{"name":"executionContextDestroyed"},{"name":"consoleAPICalled"},{"name":"exceptionThrown"}]},
        \\{"domain":"Network","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"},{"name":"setUserAgentOverride"},{"name":"setExtraHTTPHeaders"},{"name":"setCacheDisabled"},{"name":"clearBrowserCache"},{"name":"clearBrowserCookies"},{"name":"getAllCookies"},{"name":"getCookies"},{"name":"setCookies"},{"name":"setCookie"},{"name":"deleteCookies"},{"name":"emulateNetworkConditions"},{"name":"setRequestInterception"},{"name":"setBypassServiceWorker"}],"events":[{"name":"requestWillBeSent"},{"name":"responseReceived"},{"name":"loadingFinished"}]},
        \\{"domain":"DOM","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"},{"name":"getDocument"},{"name":"getFlattenedDocument"},{"name":"querySelector"},{"name":"querySelectorAll"},{"name":"getOuterHTML"},{"name":"getAttributes"},{"name":"describeNode"},{"name":"resolveNode"},{"name":"requestNode"},{"name":"focus"},{"name":"scrollIntoViewIfNeeded"},{"name":"getBoxModel"},{"name":"getContentQuads"},{"name":"performSearch"},{"name":"getNodeForLocation"},{"name":"requestChildNodes"}],"events":[{"name":"documentUpdated"},{"name":"setChildNodes"},{"name":"attributeModified"}]},
        \\{"domain":"Input","experimental":false,"deprecated":false,"commands":[{"name":"dispatchKeyEvent"},{"name":"dispatchMouseEvent"},{"name":"dispatchTouchEvent"},{"name":"insertText"}],"events":[]},
        \\{"domain":"Emulation","experimental":false,"deprecated":false,"commands":[{"name":"setDeviceMetricsOverride"},{"name":"clearDeviceMetricsOverride"},{"name":"setUserAgentOverride"},{"name":"setLocaleOverride"},{"name":"setTimezoneOverride"},{"name":"setEmulatedMedia"},{"name":"setScriptExecutionDisabled"},{"name":"setGeolocationOverride"},{"name":"setFocusEmulationEnabled"},{"name":"setTouchEmulationEnabled"},{"name":"canEmulate"}],"events":[]},
        \\{"domain":"Storage","experimental":false,"deprecated":false,"commands":[{"name":"getCookies"},{"name":"setCookies"},{"name":"clearCookies"},{"name":"clearDataForOrigin"},{"name":"getUsageAndQuota"}],"events":[]},
        \\{"domain":"Security","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"},{"name":"setIgnoreCertificateErrors"}],"events":[]},
        \\{"domain":"Inspector","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"}],"events":[{"name":"detached"}]},
        \\{"domain":"Log","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"},{"name":"clear"}],"events":[{"name":"entryAdded"}]},
        \\{"domain":"Performance","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"},{"name":"getMetrics"}],"events":[]},
        \\{"domain":"Schema","experimental":false,"deprecated":false,"commands":[{"name":"getDomains"}],"events":[]},
        \\{"domain":"Fetch","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"},{"name":"continueRequest"},{"name":"failRequest"},{"name":"fulfillRequest"}],"events":[{"name":"requestPaused"}]},
        \\{"domain":"IO","experimental":false,"deprecated":false,"commands":[{"name":"read"},{"name":"close"},{"name":"resolveBlob"}],"events":[]},
        \\{"domain":"CSS","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"},{"name":"getComputedStyleForNode"},{"name":"getMatchedStylesForNode"},{"name":"getInlineStylesForNode"},{"name":"getMediaQueries"}],"events":[]},
        \\{"domain":"Debugger","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"}],"events":[]},
        \\{"domain":"HeapProfiler","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"}],"events":[]},
        \\{"domain":"Profiler","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"},{"name":"start"},{"name":"stop"}],"events":[]},
        \\{"domain":"Tracing","experimental":false,"deprecated":false,"commands":[{"name":"start"},{"name":"end"},{"name":"getCategories"}],"events":[]},
        \\{"domain":"Memory","experimental":false,"deprecated":false,"commands":[{"name":"getDOMCounters"},{"name":"getAllTimeSamplingProfile"}],"events":[]},
        \\{"domain":"HeadlessExperimental","experimental":true,"deprecated":false,"commands":[{"name":"beginFrame"}],"events":[]},
        \\{"domain":"Animation","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"}],"events":[]},
        \\{"domain":"Audits","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"}],"events":[]},
        \\{"domain":"Overlay","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"}],"events":[]},
        \\{"domain":"LayerTree","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"}],"events":[]},
        \\{"domain":"ServiceWorker","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"}],"events":[]},
        \\{"domain":"IndexedDB","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"}],"events":[]},
        \\{"domain":"CacheStorage","experimental":false,"deprecated":false,"commands":[],"events":[]},
        \\{"domain":"DOMStorage","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"}],"events":[]},
        \\{"domain":"Console","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"},{"name":"clearMessages"}],"events":[]},
        \\{"domain":"Accessibility","experimental":false,"deprecated":false,"commands":[{"name":"enable"},{"name":"disable"}],"events":[]}
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

test "Schema.getDomains lists Page" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const response = try dispatchCdpMessageForTest(arena_impl.allocator(), "{\"id\":4,\"method\":\"Schema.getDomains\"}");
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"Page\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"Emulation\"") != null);
}

test "Browser.getWindowForTarget returns bounds" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const response = try dispatchCdpMessageForTest(arena_impl.allocator(), "{\"id\":5,\"method\":\"Browser.getWindowForTarget\"}");
    try std.testing.expect(std.mem.indexOf(u8, response, "\"windowId\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"width\":1280") != null);
}

test "Network.setCookies and getAllCookies round-trip" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    var state = CdpState.init(arena_impl.allocator());
    _ = try dispatchCdpMessageForTestWithState(arena_impl.allocator(), &state, "{\"id\":1,\"method\":\"Network.setCookies\",\"params\":{\"cookies\":[{\"name\":\"sid\",\"value\":\"abc\",\"domain\":\".example.com\",\"path\":\"/\"}]}}");
    const response = try dispatchCdpMessageForTestWithState(arena_impl.allocator(), &state, "{\"id\":2,\"method\":\"Network.getAllCookies\"}");
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"sid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"value\":\"abc\"") != null);
}

test "Page.addScriptToEvaluateOnNewDocument returns identifier" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const response = try dispatchCdpMessageForTest(arena_impl.allocator(), "{\"id\":6,\"method\":\"Page.addScriptToEvaluateOnNewDocument\",\"params\":{\"source\":\"window.x=1\"}}");
    try std.testing.expect(std.mem.indexOf(u8, response, "\"identifier\":") != null);
}

test "unknown method returns -32601" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const response = try dispatchCdpMessageForTest(arena_impl.allocator(), "{\"id\":7,\"method\":\"NoSuch.method\"}");
    try std.testing.expect(std.mem.indexOf(u8, response, "-32601") != null);
}

test "DOM.querySelector on no page returns 0" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const response = try dispatchCdpMessageForTest(arena_impl.allocator(), "{\"id\":8,\"method\":\"DOM.querySelector\",\"params\":{\"nodeId\":1,\"selector\":\"div\"}}");
    try std.testing.expect(std.mem.indexOf(u8, response, "\"nodeId\":0") != null);
}

test "Emulation.setDeviceMetricsOverride is acked" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const response = try dispatchCdpMessageForTest(arena_impl.allocator(), "{\"id\":9,\"method\":\"Emulation.setDeviceMetricsOverride\",\"params\":{\"width\":375,\"height\":667,\"deviceScaleFactor\":2,\"mobile\":true}}");
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"error\"") == null);
}

test "CSS.getComputedStyleForNode resolves cascade against page styles" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var state = CdpState.init(a);
    state.current_url = "about:test";
    state.title = "test";
    var doc = try dom.Document.parse(a, "<html><body><style>p { color: red; } #hi { color: blue; }</style><p id=\"hi\" style=\"font-size: 20px\">hello</p></body></html>");
    state.page = .{
        .requested_url = "about:test",
        .url = "about:test",
        .html = "",
        .dom = doc,
        .title = "test",
        .text = "",
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
    const p_id = (try doc.querySelector(a, "p")).?;
    const cdp_node = internalToCdp(p_id);
    const request = try std.fmt.allocPrint(a, "{{\"id\":1,\"method\":\"CSS.getComputedStyleForNode\",\"params\":{{\"nodeId\":{d}}}}}", .{cdp_node});
    const response = try dispatchCdpMessageForTestWithState(a, &state, request);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"color\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"value\":\"blue\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"value\":\"20px\"") != null);
}

test "CSS.getStyleSheetText returns concatenated style blocks" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var state = CdpState.init(a);
    const doc = try dom.Document.parse(a, "<style>body { color: red; }</style><style>p { font-size: 14px; }</style>");
    state.page = .{
        .requested_url = "",
        .url = "",
        .html = "",
        .dom = doc,
        .title = "",
        .text = "",
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
    const response = try dispatchCdpMessageForTestWithState(a, &state, "{\"id\":1,\"method\":\"CSS.getStyleSheetText\"}");
    try std.testing.expect(std.mem.indexOf(u8, response, "color: red") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "font-size: 14px") != null);
}

test "CSS.getInlineStylesForNode parses style attribute" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var state = CdpState.init(a);
    var doc = try dom.Document.parse(a, "<div style=\"color: orange; padding: 4px !important\">x</div>");
    state.page = .{
        .requested_url = "",
        .url = "",
        .html = "",
        .dom = doc,
        .title = "",
        .text = "",
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
    const div_id = (try doc.querySelector(a, "div")).?;
    const cdp_node = internalToCdp(div_id);
    const request = try std.fmt.allocPrint(a, "{{\"id\":1,\"method\":\"CSS.getInlineStylesForNode\",\"params\":{{\"nodeId\":{d}}}}}", .{cdp_node});
    const response = try dispatchCdpMessageForTestWithState(a, &state, request);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"name\":\"color\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"value\":\"orange\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"important\":true") != null);
}

test "engine layoutPage produces a layout tree and SVG" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    const doc = try dom.Document.parse(a, "<html><body><h1 style=\"color: blue\">Hi</h1><p>world</p></body></html>");
    var page: model.Page = .{
        .requested_url = "",
        .url = "",
        .html = "",
        .dom = doc,
        .title = "",
        .text = "",
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
    var result = try engine.layoutPage(std.testing.allocator, &page, .{ .width = 800, .height = 600 });
    defer result.deinit();
    try std.testing.expect(result.root.children.len > 0);
    const svg = try engine.paintToSvg(std.testing.allocator, &result);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "<svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "Hi") != null);
}
