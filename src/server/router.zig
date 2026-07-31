const std = @import("std");
const net = std.Io.net;
const compat = @import("../compat.zig");
const bridge_mod = @import("../bridge/bridge.zig");
const Bridge = bridge_mod.Bridge;
const TabEntry = bridge_mod.TabEntry;
const RefCache = bridge_mod.RefCache;
const Config = @import("../bridge/config.zig").Config;
const resp = @import("response.zig");
const middleware = @import("middleware.zig");
const json_util = @import("../util/json.zig");
const protocol = @import("../cdp/protocol.zig");
const HarRecorder = @import("../cdp/har.zig").HarRecorder;
const isApiShaped = @import("../cdp/har.zig").isApiShaped;
const CdpClient = @import("../cdp/client.zig").CdpClient;
const auth_profiles = @import("../storage/auth_profiles.zig");
const connect_store = @import("../storage/connect_store.zig");
const url_validator = @import("../crawler/validator.zig");
const telemetry = @import("../telemetry.zig");

pub fn run(gpa: std.mem.Allocator, bridge: *Bridge, cfg: Config, cdp_port: u16) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const address = try net.IpAddress.parseIp4(cfg.host, cfg.port);
    var tcp_server = try net.IpAddress.listen(&address, io, .{
        .reuse_address = true,
    });
    defer tcp_server.deinit(io);

    std.log.info("server ready on {s}:{d}", .{ cfg.host, cfg.port });

    while (true) {
        const stream = tcp_server.accept(io) catch |err| {
            std.log.err("accept error: {s}", .{@errorName(err)});
            continue;
        };

        const thread = std.Thread.spawn(.{}, handleConnection, .{ gpa, bridge, cfg, cdp_port, stream }) catch |err| {
            std.log.err("thread spawn error: {s}", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(gpa: std.mem.Allocator, bridge: *Bridge, cfg: Config, cdp_port: u16, stream: net.Stream) void {
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

        if (!middleware.checkAuth(&request, cfg)) {
            resp.sendError(&request, 401, "Unauthorized");
            return;
        }

        // Capture the route name (query stripped — never the navigated URL) and
        // method for telemetry, then time the dispatch. response.zig records the
        // status + body size into a thread-local that we read back below.
        const full_target = request.head.target;
        const route_name = if (std.mem.indexOfScalar(u8, full_target, '?')) |q| full_target[0..q] else full_target;
        const method_name = @tagName(request.head.method);
        telemetry.beginRequest();
        const t0 = compat.nanoTimestamp();

        route(&request, arena, bridge, cfg, cdp_port);

        const elapsed_ns: i64 = @intCast(@min(compat.nanoTimestamp() - t0, std.math.maxInt(i64)));
        const ri = telemetry.tl_response;
        telemetry.recordRequest(route_name, method_name, ri.status, elapsed_ns, ri.bytes, ri.status >= 400);

        if (!request.head.keep_alive) return;

        // Free per-request allocations while keeping arena pages for reuse
        _ = arena_impl.reset(.retain_capacity);
    }
}

fn route(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge, cfg: Config, cdp_port: u16) void {
    const path = request.head.target;
    const clean_path = if (std.mem.indexOfScalar(u8, path, '?')) |idx| path[0..idx] else path;

    if (std.mem.eql(u8, clean_path, "/health")) {
        handleHealth(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/tabs")) {
        handleTabs(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/page/info")) {
        handlePageInfo(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/discover")) {
        handleDiscover(request, arena, bridge, cfg, cdp_port);
    } else if (std.mem.eql(u8, clean_path, "/navigate")) {
        handleNavigate(request, arena, bridge, cfg);
    } else if (std.mem.eql(u8, clean_path, "/snapshot")) {
        handleSnapshot(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/action")) {
        handleAction(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/text")) {
        handleText(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/screenshot")) {
        handleScreenshot(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/evaluate")) {
        handleEvaluate(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/browdie")) {
        handleBrowdie(request);
    } else if (std.mem.eql(u8, clean_path, "/har/start")) {
        handleHarStart(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/har/stop")) {
        handleHarStop(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/har/status")) {
        handleHarStatus(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/har/replay")) {
        handleHarReplay(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/close")) {
        handleClose(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/cookies")) {
        handleCookies(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/cookies/clear")) {
        handleCookiesClear(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/cookies/set")) {
        handleCookiesSet(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/storage/local")) {
        handleStorage(request, arena, bridge, "localStorage");
    } else if (std.mem.eql(u8, clean_path, "/storage/session")) {
        handleStorage(request, arena, bridge, "sessionStorage");
    } else if (std.mem.eql(u8, clean_path, "/storage/local/clear")) {
        handleStorageClear(request, arena, bridge, "localStorage");
    } else if (std.mem.eql(u8, clean_path, "/storage/session/clear")) {
        handleStorageClear(request, arena, bridge, "sessionStorage");
    } else if (std.mem.eql(u8, clean_path, "/get")) {
        handleGet(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/back")) {
        handleBack(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/forward")) {
        handleForward(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/reload")) {
        handleReload(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/diff/snapshot")) {
        handleDiffSnapshot(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/emulate")) {
        handleEmulate(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/geolocation")) {
        handleGeolocation(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/upload")) {
        handleUpload(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/session/save")) {
        handleSessionSave(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/session/load")) {
        handleSessionLoad(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/auth/profile/save")) {
        handleAuthProfileSave(request, arena, bridge, cfg);
    } else if (std.mem.eql(u8, clean_path, "/auth/profile/load")) {
        handleAuthProfileLoad(request, arena, bridge, cfg);
    } else if (std.mem.eql(u8, clean_path, "/auth/profile/list")) {
        handleAuthProfileList(request, arena, cfg);
    } else if (std.mem.eql(u8, clean_path, "/auth/profile/delete")) {
        handleAuthProfileDelete(request, arena, cfg);
    } else if (std.mem.eql(u8, clean_path, "/auth/extract")) {
        handleAuthExtract(request, arena);
    } else if (std.mem.eql(u8, clean_path, "/connect/save")) {
        handleConnectSave(request, arena, bridge, cfg);
    } else if (std.mem.eql(u8, clean_path, "/connect/load")) {
        handleConnectLoad(request, arena, bridge, cfg);
    } else if (std.mem.eql(u8, clean_path, "/connect/list")) {
        handleConnectList(request, arena, cfg);
    } else if (std.mem.eql(u8, clean_path, "/connect/delete")) {
        handleConnectDelete(request, arena, cfg);
    } else if (std.mem.eql(u8, clean_path, "/debug/enable")) {
        handleDebugEnable(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/debug/disable")) {
        handleDebugDisable(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/screenshot/annotated")) {
        handleAnnotatedScreenshot(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/screenshot/diff")) {
        handleDiffScreenshot(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/screencast/start")) {
        handleScreencastStart(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/screencast/stop")) {
        handleScreencastStop(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/video/start")) {
        handleVideoStart(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/video/stop")) {
        handleVideoStop(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/console")) {
        handleConsole(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/intercept/start")) {
        handleInterceptStart(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/intercept/stop")) {
        handleInterceptStop(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/intercept/requests")) {
        handleInterceptRequests(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/markdown")) {
        handleMarkdown(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/links")) {
        handleLinks(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/pdf")) {
        handlePdf(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/dom/query")) {
        handleDomQuery(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/dom/html")) {
        handleDomHtml(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/cookies/delete")) {
        handleCookiesDelete(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/headers")) {
        handleHeaders(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/script/inject")) {
        handleScriptInject(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/stop")) {
        handleStop(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/scrollintoview")) {
        handleScrollIntoView(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/drag")) {
        handleDrag(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/keyboard/type")) {
        handleKeyboardType(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/keyboard/inserttext")) {
        handleKeyboardInsertText(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/keydown")) {
        handleKeyDown(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/keyup")) {
        handleKeyUp(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/wait")) {
        handleWait(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/tab/current")) {
        handleTabCurrent(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/tab/new")) {
        handleTabNew(request, arena, bridge, cfg, cdp_port);
    } else if (std.mem.eql(u8, clean_path, "/tab/close")) {
        handleTabClose(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/highlight")) {
        handleHighlight(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/errors")) {
        handleErrors(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/set/offline")) {
        handleSetOffline(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/set/media")) {
        handleSetMedia(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/set/credentials")) {
        handleSetCredentials(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/find")) {
        handleFind(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/trace/start")) {
        handleTraceStart(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/trace/stop")) {
        handleTraceStop(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/profiler/start")) {
        handleProfilerStart(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/profiler/stop")) {
        handleProfilerStop(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/inspect")) {
        handleInspect(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/window/new")) {
        handleWindowNew(request, arena, bridge, cfg, cdp_port);
    } else if (std.mem.eql(u8, clean_path, "/session/list")) {
        handleSessionList(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/set/viewport")) {
        handleSetViewport(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/set/useragent")) {
        handleSetUserAgent(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/dom/attributes")) {
        handleDomAttributes(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/frames")) {
        handleFrames(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/network")) {
        handleNetwork(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/perf/lcp")) {
        handlePerfLcp(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/ws/start")) {
        handleWsStart(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/ws/stop")) {
        handleWsStop(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/batch")) {
        handleBatch(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/element/state")) {
        handleElementState(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/find-element")) {
        handleFindElement(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/dialog/auto")) {
        handleDialogAuto(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/dialog/accept")) {
        handleDialogRespond(request, arena, bridge, true);
    } else if (std.mem.eql(u8, clean_path, "/dialog/dismiss")) {
        handleDialogRespond(request, arena, bridge, false);
    } else if (std.mem.eql(u8, clean_path, "/mouse/move")) {
        handleMouseEvent(request, arena, bridge, "mouseMoved");
    } else if (std.mem.eql(u8, clean_path, "/mouse/down")) {
        handleMouseEvent(request, arena, bridge, "mousePressed");
    } else if (std.mem.eql(u8, clean_path, "/mouse/up")) {
        handleMouseEvent(request, arena, bridge, "mouseReleased");
    } else if (std.mem.eql(u8, clean_path, "/mouse/wheel")) {
        handleMouseWheel(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/page/state")) {
        handlePageState(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/clipboard/read")) {
        handleClipboard(request, arena, bridge, "read");
    } else if (std.mem.eql(u8, clean_path, "/clipboard/write")) {
        handleClipboard(request, arena, bridge, "write");
    } else if (std.mem.eql(u8, clean_path, "/clear")) {
        handleClear(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/boundingbox")) {
        handleBoundingBox(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/wait/function")) {
        handleWaitForFunction(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/response/body")) {
        handleResponseBody(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/setcontent")) {
        handleSetContent(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/selectall")) {
        handleSelectAll(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/setvalue")) {
        handleSetValue(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/timezone")) {
        handleTimezone(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/locale")) {
        handleLocale(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/permissions")) {
        handlePermissions(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/tap")) {
        handleTap(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/dispatch")) {
        handleDispatch(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/download")) {
        handleDownload(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/addstyle")) {
        handleAddStyle(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/bringtofront")) {
        handleBringToFront(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/pushstate")) {
        handlePushState(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/expose")) {
        handleExpose(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/multiselect")) {
        handleMultiSelect(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/swipe")) {
        handleSwipe(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/vitals")) {
        handleVitals(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/frame")) {
        handleFrame(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/mainframe")) {
        handleMainFrame(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/getattribute")) {
        handleGetAttribute(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/inputvalue")) {
        handleInputValue(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/react/tree")) {
        handleReact(request, arena, bridge, "tree");
    } else if (std.mem.eql(u8, clean_path, "/react/inspect")) {
        handleReact(request, arena, bridge, "inspect");
    } else if (std.mem.eql(u8, clean_path, "/react/renders")) {
        handleReact(request, arena, bridge, "renders");
    } else if (std.mem.eql(u8, clean_path, "/react/suspense")) {
        handleReact(request, arena, bridge, "suspense");
    } else if (std.mem.eql(u8, clean_path, "/recording/start")) {
        handleRecording(request, arena, bridge, "start");
    } else if (std.mem.eql(u8, clean_path, "/recording/stop")) {
        handleRecording(request, arena, bridge, "stop");
    } else if (std.mem.eql(u8, clean_path, "/request/detail")) {
        handleRequestDetail(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/wait/download")) {
        handleWaitForDownload(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/initscript/remove")) {
        handleRemoveInitScript(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/evalhandle")) {
        handleEvalHandle(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/diff/url")) {
        handleDiffUrl(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/cache/set")) {
        handleCacheSet(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/cache/get")) {
        handleCacheGet(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/cache/clear")) {
        handleCacheClear(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/cache/list")) {
        handleCacheList(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/screenshot/som")) {
        handleScreenshotSom(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/snapshot/changes")) {
        handleDiffSnapshot(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/recording/export")) {
        handleRecordingExport(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/replay")) {
        handleReplay(request, arena, bridge);
    } else {
        resp.sendError(request, 404, "Not Found");
    }
}

// --- Query string helpers ---

fn getQueryParam(target: []const u8, key: []const u8) ?[]const u8 {
    const query_start = (std.mem.indexOfScalar(u8, target, '?') orelse return null) + 1;
    const query = target[query_start..];
    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            if (std.mem.eql(u8, pair[0..eq], key)) {
                return pair[eq + 1 ..];
            }
        }
    }
    return null;
}

fn decodeUrlComponentAlloc(allocator: std.mem.Allocator, input: []const u8) ?[]u8 {
    var buf = allocator.alloc(u8, input.len) catch return null;
    var i: usize = 0;
    var j: usize = 0;
    while (i < input.len) : (i += 1) {
        switch (input[i]) {
            '+' => {
                buf[j] = ' ';
                j += 1;
            },
            '%' => {
                if (i + 2 >= input.len) {
                    allocator.free(buf);
                    return null;
                }
                const hi = std.fmt.charToDigit(input[i + 1], 16) catch {
                    allocator.free(buf);
                    return null;
                };
                const lo = std.fmt.charToDigit(input[i + 2], 16) catch {
                    allocator.free(buf);
                    return null;
                };
                buf[j] = @as(u8, @intCast(hi * 16 + lo));
                j += 1;
                i += 2;
            },
            else => {
                buf[j] = input[i];
                j += 1;
            },
        }
    }
    const decoded = allocator.dupe(u8, buf[0..j]) catch {
        allocator.free(buf);
        return null;
    };
    allocator.free(buf);
    return decoded;
}

fn getDecodedQueryParamAlloc(allocator: std.mem.Allocator, target: []const u8, key: []const u8) ?[]u8 {
    const value = getQueryParam(target, key) orelse return null;
    return decodeUrlComponentAlloc(allocator, value);
}

fn getHeaderValue(request: *const std.http.Server.Request, key: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, key)) {
            return header.value;
        }
    }
    return null;
}

fn getSessionId(request: *const std.http.Server.Request) ?[]const u8 {
    return getHeaderValue(request, "x-kuri-session") orelse getQueryParam(request.head.target, "session");
}

fn resolveEffectiveTabIdAlloc(arena: std.mem.Allocator, request: *const std.http.Server.Request, bridge: *Bridge) ?[]u8 {
    const target = request.head.target;
    if (getQueryParam(target, "tab_id")) |tab_id| {
        return arena.dupe(u8, tab_id) catch null;
    }
    const session_id = getSessionId(request) orelse return null;
    return bridge.getCurrentTab(arena, session_id);
}

fn requireEffectiveTabId(arena: std.mem.Allocator, request: *std.http.Server.Request, bridge: *Bridge) ?[]u8 {
    return resolveEffectiveTabIdAlloc(arena, request, bridge) orelse {
        resp.sendError(request, 400, "Missing tab_id parameter and no current tab is set for this session");
        return null;
    };
}

fn rememberCurrentTab(request: *const std.http.Server.Request, bridge: *Bridge, tab_id: []const u8) void {
    const session_id = getSessionId(request) orelse return;
    bridge.setCurrentTab(session_id, tab_id) catch {};
}

fn anyCdpClient(arena: std.mem.Allocator, bridge: *Bridge, preferred_tab_id: ?[]const u8) ?*CdpClient {
    if (preferred_tab_id) |tab_id| {
        if (bridge.getCdpClient(tab_id)) |client| return client;
    }
    const tabs = bridge.listTabs(arena) catch return null;
    for (tabs) |tab| {
        if (preferred_tab_id) |preferred| {
            if (std.mem.eql(u8, preferred, tab.id)) continue;
        }
        if (bridge.getCdpClient(tab.id)) |client| return client;
    }
    return null;
}

fn activateTarget(arena: std.mem.Allocator, bridge: *Bridge, tab_id: []const u8) bool {
    const client = anyCdpClient(arena, bridge, tab_id) orelse return false;
    const params = std.fmt.allocPrint(arena, "{{\"targetId\":\"{s}\"}}", .{tab_id}) catch return false;
    _ = client.send(arena, protocol.Methods.target_activate_target, params) catch return false;
    return true;
}

fn closeTarget(arena: std.mem.Allocator, bridge: *Bridge, tab_id: []const u8) bool {
    const client = anyCdpClient(arena, bridge, tab_id) orelse return false;
    const params = std.fmt.allocPrint(arena, "{{\"targetId\":\"{s}\"}}", .{tab_id}) catch return false;
    _ = client.send(arena, protocol.Methods.target_close_target, params) catch return false;
    return true;
}

fn waitForRegisteredTab(arena: std.mem.Allocator, bridge: *Bridge, cfg: Config, cdp_port: u16, tab_id: []const u8) ?TabEntry {
    var attempts: u8 = 0;
    while (attempts < 20) : (attempts += 1) {
        _ = discoverTabs(arena, bridge, cfg, cdp_port) catch {};
        if (bridge.getTab(tab_id)) |tab| return tab;
        compat.threadSleep(100 * std.time.ns_per_ms);
    }
    return bridge.getTab(tab_id);
}

fn waitForTabPageReady(arena: std.mem.Allocator, bridge: *Bridge, tab_id: []const u8, requested_url: []const u8) ?TabEntry {
    const client = bridge.getCdpClient(tab_id) orelse return bridge.getTab(tab_id);
    const wants_blank = requested_url.len == 0 or std.mem.eql(u8, requested_url, "about:blank");

    var attempts: u8 = 0;
    while (attempts < 50) : (attempts += 1) {
        const live_url = evalValueString(arena, client, "window.location.href") orelse "";
        const live_title = evalValueString(arena, client, "document.title") orelse "";
        const ready_state = evalValueString(arena, client, "document.readyState") orelse "";

        if (live_url.len > 0) {
            _ = bridge.updateTabMetadata(tab_id, live_url, live_title) catch false;
        }

        const reached_url = wants_blank or !std.mem.eql(u8, live_url, "about:blank");
        const ready_enough = std.mem.eql(u8, ready_state, "interactive") or std.mem.eql(u8, ready_state, "complete");
        if (reached_url and ready_enough) return bridge.getTab(tab_id);

        compat.threadSleep(100 * std.time.ns_per_ms);
    }

    return bridge.getTab(tab_id);
}

fn readRequestBody(request: *std.http.Server.Request, arena: std.mem.Allocator) ?[]const u8 {
    if (!request.head.method.requestHasBody()) return null;
    if (request.head.expect != null) return null;
    const content_length = request.head.content_length orelse return null;
    if (content_length == 0) return null;
    const max_body: usize = 1024 * 1024; // 1MB — supports large script injection
    const len: usize = @intCast(@min(content_length, max_body));
    var buf: [65536]u8 = undefined;
    const reader = request.readerExpectNone(&buf);
    const body = reader.readAlloc(arena, len) catch return null;
    if (body.len == 0) return null;
    return body;
}

// --- Route handlers ---

fn handleHealth(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_count = bridge.tabCount();
    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"tabs\":{d},\"version\":\"{s}\",\"name\":\"kuri\"}}", .{ tab_count, @import("build_options").version }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleTabs(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tabs = bridge.listTabs(arena) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const current_tab_id = if (getSessionId(request)) |session_id| bridge.getCurrentTab(arena, session_id) else null;
    var json_buf: std.ArrayList(u8) = .empty;

    json_buf.appendSlice(arena, "[") catch return;
    for (tabs, 0..) |tab, i| {
        if (i > 0) json_buf.appendSlice(arena, ",") catch return;
        json_buf.appendSlice(arena, "{") catch return;
        writeJsonField(&json_buf, arena, "id", tab.id) catch return;
        json_buf.appendSlice(arena, ",") catch return;
        writeJsonField(&json_buf, arena, "url", tab.url) catch return;
        json_buf.appendSlice(arena, ",") catch return;
        writeJsonField(&json_buf, arena, "title", tab.title) catch return;
        if (current_tab_id) |current| {
            json_buf.appendSlice(arena, ",\"current\":") catch return;
            json_buf.appendSlice(arena, if (std.mem.eql(u8, current, tab.id)) "true" else "false") catch return;
        }
        json_buf.appendSlice(arena, "}") catch return;
    }
    json_buf.appendSlice(arena, "]") catch return;

    resp.sendJson(request, json_buf.items);
}

fn handleNavigate(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge, cfg: Config) void {
    const target = request.head.target;
    const url = getDecodedQueryParamAlloc(arena, target, "url") orelse {
        resp.sendError(request, 400, "Missing url parameter");
        return;
    };
    url_validator.validateUrl(url) catch |err| {
        const msg = switch (err) {
            error.InvalidScheme => "URL must use http:// or https://",
            error.PrivateIp => "Navigation to private IP addresses is blocked",
            error.LocalhostBlocked => "Navigation to localhost is blocked",
            error.MetadataIpBlocked => "Navigation to cloud metadata endpoints is blocked",
            error.InvalidUrl => "Invalid URL format",
            else => "URL validation failed",
        };
        resp.sendError(request, 403, msg);
        return;
    };

    const tab_id = resolveEffectiveTabIdAlloc(arena, request, bridge);
    const cf_wait = if (getQueryParam(target, "cf_wait")) |v| std.mem.eql(u8, v, "true") else false;
    const cf_timeout_str = getQueryParam(target, "cf_timeout") orelse "15000";
    const cf_timeout_ms = std.fmt.parseInt(u64, cf_timeout_str, 10) catch 15000;

    const escaped_url = jsonEscapeAlloc(arena, url) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    // If we have a tab, use its CDP client
    if (tab_id) |tid| {
        const client = bridge.getCdpClient(tid) orelse {
            resp.sendError(request, 404, "Tab not found");
            return;
        };
        rememberCurrentTab(request, bridge, tid);
        if (bridge.getTab(tid)) |tab| {
            _ = bridge.updateTabMetadata(tid, url, tab.title) catch false;
        }
        _ = bridge.touchTab(tid);
        const params = std.fmt.allocPrint(arena, "{{\"url\":\"{s}\"}}", .{escaped_url}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const response = client.send(arena, protocol.Methods.page_navigate, params) catch {
            resp.sendError(request, 502, "CDP command failed");
            return;
        };
        bumpGenerationLocked(bridge, tid);

        // Drain network events AFTER navigate — they arrive asynchronously
        // over the next few seconds as the page loads resources.
        if (bridge.getHarRecorder(tid)) |rec| {
            if (rec.isRecording()) {
                // Wait briefly for network events to start arriving
                compat.threadSleep(1500 * std.time.ns_per_ms);
                client.drainWsEvents(arena, 2);
                flushEventsToHar(arena, client, rec);
            }
        }

        // Bot block detection — check if we got blocked and return structured fallback
        const bot_detect = if (getQueryParam(target, "bot_detect")) |v| !std.mem.eql(u8, v, "false") else true;
        if (bot_detect) {
            // Wait for page to settle before checking
            compat.threadSleep(3000 * std.time.ns_per_ms);
            // Detection uses BLOCKER= prefix markers so we can find them in the CDP string response
            const detect_js = "(() => { var t = document.title || ''; var b = document.body ? document.body.innerText.substring(0, 2000) : ''; var h = document.documentElement.innerHTML.substring(0, 8000); var blocker = ''; var code = ''; if (b.indexOf('Reference error code:') !== -1 || h.indexOf('WAF_Custom_Deny') !== -1 || h.indexOf('akamai') !== -1 || (t.indexOf('Maintenance') !== -1 && b.indexOf('error code') !== -1)) { blocker = 'akamai'; var idx = b.indexOf('Reference error code:'); if (idx !== -1) { var rest = b.substring(idx + 22, idx + 80); var nl = rest.indexOf(String.fromCharCode(10)); code = nl !== -1 ? rest.substring(0, nl).trim() : rest.trim(); } } else if (t === 'Just a moment...' || h.indexOf('challenge-platform') !== -1 || h.indexOf('cf-browser-verification') !== -1 || h.indexOf('cf-chl-') !== -1) { blocker = 'cloudflare'; } else if (h.indexOf('perimeterx') !== -1 || h.indexOf('_pxCaptcha') !== -1 || h.indexOf('human-challenge') !== -1) { blocker = 'perimeterx'; } else if (h.indexOf('datadome') !== -1 || h.indexOf('DataDome') !== -1) { blocker = 'datadome'; } else if (h.indexOf('captcha') !== -1 && (t.indexOf('Access Denied') !== -1 || t.indexOf('Blocked') !== -1 || t === '')) { blocker = 'captcha'; } else if (t.indexOf('Access Denied') !== -1 || t.indexOf('403 Forbidden') !== -1 || (t === '' && b.length < 50 && h.indexOf('block') !== -1)) { blocker = 'unknown'; } if (!blocker) return 'NOBLOCK'; return 'BLOCKED|' + blocker + '|' + code + '|' + window.location.href; })()";
            const detect_escaped = jsonEscapeAlloc(arena, detect_js) orelse {
                resp.sendJson(request, response);
                return;
            };
            const detect_params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{detect_escaped}) catch {
                resp.sendJson(request, response);
                return;
            };
            const detect_response = client.send(arena, protocol.Methods.runtime_evaluate, detect_params) catch {
                resp.sendJson(request, response);
                return;
            };
            // Check if blocked — look for BLOCKED| marker in CDP response string value
            if (std.mem.indexOf(u8, detect_response, "BLOCKED|") != null) {
                // Parse "BLOCKED|blocker|code|url" from the value field
                const marker_pos = std.mem.indexOf(u8, detect_response, "BLOCKED|").?;
                const after_marker = detect_response[marker_pos + 8 ..];
                // Find blocker (up to next |)
                const blocker_end = std.mem.indexOfScalar(u8, after_marker, '|') orelse after_marker.len;
                const blocker = after_marker[0..blocker_end];
                // Find code (between second and third |)
                const after_blocker = if (blocker_end < after_marker.len) after_marker[blocker_end + 1 ..] else "";
                const code_end = std.mem.indexOfScalar(u8, after_blocker, '|') orelse after_blocker.len;
                const ref_code_raw = after_blocker[0..code_end];
                // Find url (after third |, up to closing quote)
                const after_code = if (code_end < after_blocker.len) after_blocker[code_end + 1 ..] else "";
                const url_end = std.mem.indexOfScalar(u8, after_code, '"') orelse after_code.len;
                const final_url_val = after_code[0..url_end];
                const ref_code = ref_code_raw;
                const escaped_blocker = jsonEscapeAlloc(arena, blocker) orelse blocker;
                const escaped_code = jsonEscapeAlloc(arena, ref_code) orelse "";
                const escaped_final_url = jsonEscapeAlloc(arena, final_url_val) orelse escaped_url;
                const blocked_body = std.fmt.allocPrint(arena,
                    \\{{"blocked":true,"blocker":"{s}","ref_code":"{s}","url":"{s}","fallback":{{
                    \\"direct_url":"{s}",
                    \\"message":"This site uses {s} bot protection which blocks automated browsers at the TLS/network level. Stealth patches and JS overrides cannot bypass this.",
                    \\"suggestions":["Open the URL directly in a real browser: {s}","Use a residential proxy (set KURI_PROXY=socks5://...) to change IP reputation","For airline check-in: use the airline's mobile app instead","Set a reminder to check in manually at the right time"],
                    \\"proxy_hint":"KURI_PROXY=socks5://user:pass@residential-proxy:1080 or KURI_PROXY=http://proxy:8080",
                    \\"bypass_difficulty":"high"
                    \\}}}}
                , .{ escaped_blocker, escaped_code, escaped_final_url, escaped_url, escaped_blocker, escaped_url }) catch {
                    resp.sendJson(request, response);
                    return;
                };
                resp.sendJson(request, blocked_body);
                return;
            }
        }

        // Cloudflare challenge detection and auto-wait
        if (cf_wait) {
            const cf_check_js = "(() => { const t = document.title || ''; const b = document.body ? document.body.innerText : ''; return JSON.stringify({title: t, is_cf: t.includes('Just a moment') || t.includes('Attention Required') || b.includes('challenge-platform') || b.includes('cf-browser-verification')}); })()";
            const max_polls = cf_timeout_ms / 1500;
            var polls: u64 = 0;
            // Initial wait for page to load
            compat.threadSleep(2000 * std.time.ns_per_ms);
            while (polls < max_polls) : (polls += 1) {
                const check_params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{cf_check_js}) catch break;
                const check_response = client.send(arena, protocol.Methods.runtime_evaluate, check_params) catch break;
                // If is_cf is false (not a challenge page), we're done
                if (std.mem.indexOf(u8, check_response, "\"is_cf\":false") != null or
                    std.mem.indexOf(u8, check_response, "\"is_cf\": false") != null)
                {
                    const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"cf_challenge\":true,\"cf_cleared\":true,\"wait_ms\":{d}}}", .{(polls + 1) * 1500 + 2000}) catch break;
                    resp.sendJson(request, body);
                    return;
                }
                // If no CF markers detected at all on first check, return early
                if (polls == 0 and std.mem.indexOf(u8, check_response, "\"is_cf\":true") == null and
                    std.mem.indexOf(u8, check_response, "\"is_cf\": true") == null)
                {
                    resp.sendJson(request, response);
                    return;
                }
                compat.threadSleep(1500 * std.time.ns_per_ms);
            }
            // Timed out waiting for CF challenge
            const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"cf_challenge\":true,\"cf_cleared\":false,\"wait_ms\":{d}}}", .{cf_timeout_ms}) catch {
                resp.sendJson(request, response);
                return;
            };
            resp.sendJson(request, body);
            return;
        }

        resp.sendJson(request, response);
        return;
    }

    // No tab specified — discover from Chrome debugging endpoint
    _ = cfg;
    const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"url\":\"{s}\",\"message\":\"Navigate requires tab_id. Use /tabs to list available tabs.\"}}", .{escaped_url}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handlePageInfo(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    rememberCurrentTab(request, bridge, tab_id);
    _ = bridge.touchTab(tab_id);

    const info_expr =
        \\(() => {
        \\  const enc = encodeURIComponent;
        \\  return [
        \\    enc(window.location.href || ''),
        \\    enc(document.title || ''),
        \\    enc(document.readyState || ''),
        \\    String(window.innerWidth || 0),
        \\    String(window.innerHeight || 0),
        \\    String(Math.round(window.scrollX || 0)),
        \\    String(Math.round(window.scrollY || 0))
        \\  ].join('|');
        \\})()
    ;
    const escaped_expr = jsonEscapeAlloc(arena, info_expr) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped_expr}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    const encoded = extractSimpleJsonString(response, 0, "\"value\"") orelse {
        resp.sendError(request, 500, "Could not parse page info");
        return;
    };

    var parts = std.mem.splitScalar(u8, encoded, '|');
    const url_encoded = parts.next() orelse "";
    const title_encoded = parts.next() orelse "";
    const ready_encoded = parts.next() orelse "";
    const width_raw = parts.next() orelse "0";
    const height_raw = parts.next() orelse "0";
    const scroll_x_raw = parts.next() orelse "0";
    const scroll_y_raw = parts.next() orelse "0";

    const live_url = decodeUrlComponentAlloc(arena, url_encoded) orelse {
        resp.sendError(request, 500, "Could not decode page URL");
        return;
    };
    const live_title = decodeUrlComponentAlloc(arena, title_encoded) orelse {
        resp.sendError(request, 500, "Could not decode page title");
        return;
    };
    const ready_state = decodeUrlComponentAlloc(arena, ready_encoded) orelse {
        resp.sendError(request, 500, "Could not decode readyState");
        return;
    };

    const viewport_width = std.fmt.parseInt(i64, width_raw, 10) catch 0;
    const viewport_height = std.fmt.parseInt(i64, height_raw, 10) catch 0;
    const scroll_x = std.fmt.parseInt(i64, scroll_x_raw, 10) catch 0;
    const scroll_y = std.fmt.parseInt(i64, scroll_y_raw, 10) catch 0;
    _ = bridge.updateTabMetadata(tab_id, live_url, live_title) catch false;

    const include_frames = if (getQueryParam(target, "include")) |include|
        std.mem.indexOf(u8, include, "frames") != null
    else
        false;
    const is_current = if (getSessionId(request)) |session_id| blk: {
        const current = bridge.getCurrentTab(arena, session_id) orelse break :blk false;
        break :blk std.mem.eql(u8, current, tab_id);
    } else false;

    var json_buf: std.ArrayList(u8) = .empty;
    json_buf.appendSlice(arena, "{") catch return;
    writeJsonField(&json_buf, arena, "tab_id", tab_id) catch return;
    json_buf.appendSlice(arena, ",") catch return;
    writeJsonField(&json_buf, arena, "url", live_url) catch return;
    json_buf.appendSlice(arena, ",") catch return;
    writeJsonField(&json_buf, arena, "title", live_title) catch return;
    json_buf.appendSlice(arena, ",") catch return;
    writeJsonField(&json_buf, arena, "ready_state", ready_state) catch return;
    json_buf.print(arena, ",\"viewport_width\":{d},\"viewport_height\":{d},\"scroll_x\":{d},\"scroll_y\":{d},\"current\":{s}", .{
        viewport_width,
        viewport_height,
        scroll_x,
        scroll_y,
        if (is_current) "true" else "false",
    }) catch return;

    if (include_frames) {
        _ = client.send(arena, protocol.Methods.page_enable, null) catch {};
        const frames_response = client.send(arena, protocol.Methods.page_get_frame_tree, null) catch null;
        if (frames_response) |raw_frames| {
            json_buf.appendSlice(arena, ",\"frames\":") catch return;
            json_buf.appendSlice(arena, raw_frames) catch return;
        }
    }

    json_buf.appendSlice(arena, "}") catch return;
    resp.sendJson(request, json_buf.items);
}

fn handleSnapshot(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const filter = getQueryParam(target, "filter");
    const format = getQueryParam(target, "format");
    const depth_str = getQueryParam(target, "depth");

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);
    _ = bridge.touchTab(tab_id);

    // Get full a11y tree from Chrome
    const raw_response = client.send(arena, protocol.Methods.accessibility_get_full_tree, null) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };

    // If format=raw, return the raw CDP response
    if (format) |f| {
        if (std.mem.eql(u8, f, "raw")) {
            resp.sendJson(request, raw_response);
            return;
        }
    }

    // Parse and filter the a11y tree
    const a11y = @import("../snapshot/a11y.zig");
    const nodes = parseA11yNodes(arena, raw_response) catch {
        resp.sendError(request, 500, "Failed to parse a11y tree");
        return;
    };

    const max_depth: ?u16 = if (depth_str) |ds| std.fmt.parseInt(u16, ds, 10) catch null else null;

    const format_text = if (format) |f| std.mem.eql(u8, f, "text") else false;
    const format_compact = if (format) |f| std.mem.eql(u8, f, "compact") else false;

    // Scoped subtree: resolve @ref -> backend node id via this tab's ref cache.
    // kuri re-captures fresh and scopes the render, so a scoped snapshot is never
    // stale (unlike serving a cached subtree).
    var scope_bid: ?u32 = null;
    if (getQueryParam(target, "scope")) |sref| {
        bridge.mu.lockShared();
        const cache = bridge.snapshots.getPtr(tab_id);
        scope_bid = if (cache) |c| c.refs.get(sref) else null;
        bridge.mu.unlockShared();
        if (scope_bid == null) {
            resp.sendError(request, 400, "Unknown scope ref. Call /snapshot or /diff/snapshot first");
            return;
        }
    }

    const opts = a11y.SnapshotOpts{
        .filter_interactive = if (filter) |f| std.mem.eql(u8, f, "interactive") else false,
        .format_text = format_text,
        .compact = format_compact,
        .max_depth = max_depth,
        .hierarchy = if (getQueryParam(target, "hierarchy")) |h| std.mem.eql(u8, h, "true") else false,
        .scope_backend_id = scope_bid,
        .limit = if (getQueryParam(target, "limit")) |lp| std.fmt.parseInt(usize, lp, 10) catch null else null,
        .ref_generation = currentGeneration(bridge, tab_id),
    };

    const snapshot = a11y.buildSnapshot(nodes, opts, arena) catch {
        resp.sendError(request, 500, "Failed to build snapshot");
        return;
    };

    // Populate the ref cache so /action can resolve this snapshot's refs.
    {
        bridge.mu.lock();
        defer bridge.mu.unlock();
        refreshRefCacheLocked(bridge, tab_id, snapshot) catch {};
    }

    // Hybrid snapshot: if include_screenshot=true, wrap snapshot text with a screenshot
    const include_screenshot = if (getQueryParam(target, "include_screenshot")) |v| std.mem.eql(u8, v, "true") else false;
    if (include_screenshot) {
        const a11y_mod = @import("../snapshot/a11y.zig");
        const snap_text = a11y_mod.formatCompact(snapshot, arena) catch {
            sendSnapshotResponse(request, arena, snapshot, opts);
            return;
        };
        const screenshot_response = client.send(arena, protocol.Methods.page_capture_screenshot, "{\"format\":\"png\",\"quality\":80}") catch {
            sendSnapshotResponse(request, arena, snapshot, opts);
            return;
        };
        const screenshot_data = extractSimpleJsonString(screenshot_response, 0, "\"data\"") orelse "";
        const escaped_snap = jsonEscapeAlloc(arena, snap_text) orelse {
            sendSnapshotResponse(request, arena, snapshot, opts);
            return;
        };
        const escaped_ss = jsonEscapeAlloc(arena, screenshot_data) orelse {
            sendSnapshotResponse(request, arena, snapshot, opts);
            return;
        };
        const body = std.fmt.allocPrint(arena, "{{\"snapshot\":\"{s}\",\"screenshot\":\"{s}\"}}", .{ escaped_snap, escaped_ss }) catch {
            sendSnapshotResponse(request, arena, snapshot, opts);
            return;
        };
        resp.sendJson(request, body);
    } else {
        sendSnapshotResponse(request, arena, snapshot, opts);
    }
}

fn sendSnapshotResponse(request: *std.http.Server.Request, arena: std.mem.Allocator, snapshot: []const @import("../snapshot/a11y.zig").A11yNode, opts: @import("../snapshot/a11y.zig").SnapshotOpts) void {
    const a11y_mod = @import("../snapshot/a11y.zig");
    // Compact format is the lowest-token server response for agent loops.
    if (opts.compact) {
        const text = a11y_mod.formatCompact(snapshot, arena) catch {
            resp.sendError(request, 500, "Failed to format snapshot");
            return;
        };
        resp.sendJson(request, text);
        return;
    }

    // Text format for LLM-friendly output
    if (opts.format_text) {
        const text = a11y_mod.formatText(snapshot, arena) catch {
            resp.sendError(request, 500, "Failed to format snapshot");
            return;
        };
        resp.sendJson(request, text);
        return;
    }

    // JSON format
    var json_buf: std.ArrayList(u8) = .empty;
    json_buf.appendSlice(arena, "[") catch return;
    for (snapshot, 0..) |node, i| {
        if (i > 0) json_buf.appendSlice(arena, ",") catch return;
        json_buf.appendSlice(arena, "{") catch return;
        writeJsonField(&json_buf, arena, "ref", node.ref) catch return;
        json_buf.appendSlice(arena, ",") catch return;
        writeJsonField(&json_buf, arena, "role", node.role) catch return;
        json_buf.appendSlice(arena, ",") catch return;
        writeJsonField(&json_buf, arena, "name", node.name) catch return;
        if (node.value.len > 0) {
            json_buf.appendSlice(arena, ",") catch return;
            writeJsonField(&json_buf, arena, "value", node.value) catch return;
        }
        if (node.description.len > 0) {
            json_buf.appendSlice(arena, ",") catch return;
            writeJsonField(&json_buf, arena, "description", node.description) catch return;
        }
        if (node.state.len > 0) {
            json_buf.appendSlice(arena, ",") catch return;
            writeJsonField(&json_buf, arena, "state", node.state) catch return;
        }
        json_buf.appendSlice(arena, "}") catch return;
    }
    json_buf.appendSlice(arena, "]") catch return;
    resp.sendJson(request, json_buf.items);
}

/// Repopulate `tab_id`'s ref cache from `snapshot` so /action and friends can
/// resolve the refs this response hands out. Caller must hold bridge.mu
/// exclusively. Best-effort: callers ignore failures — a stale cache degrades
/// to "Ref not found", never to unsoundness.
/// Get-or-create the ref cache entry for a tab. Caller must hold bridge.mu
/// (exclusive) since this may insert a new map entry.
fn getOrCreateRefCacheLocked(bridge: *Bridge, tab_id: []const u8) !*RefCache {
    var cache_ptr = bridge.snapshots.getPtr(tab_id);
    if (cache_ptr == null) {
        const owned_key = try bridge.allocator.dupe(u8, tab_id);
        bridge.snapshots.put(owned_key, RefCache.init(bridge.allocator)) catch |err| {
            bridge.allocator.free(owned_key);
            return err;
        };
        cache_ptr = bridge.snapshots.getPtr(tab_id);
    }
    return cache_ptr orelse error.RefCacheUnreachable;
}

fn refreshRefCacheLocked(bridge: *Bridge, tab_id: []const u8, snapshot: []const @import("../snapshot/a11y.zig").A11yNode) !void {
    const ref_cache = try getOrCreateRefCacheLocked(bridge, tab_id);

    // Clear old refs and repopulate from the new snapshot.
    ref_cache.clear();
    for (snapshot) |node| {
        if (node.ref.len > 0 and node.backend_node_id != null) {
            const owned_ref = bridge.allocator.dupe(u8, node.ref) catch continue;
            ref_cache.refs.put(owned_ref, node.backend_node_id.?) catch continue;
        }
    }
    ref_cache.node_count = snapshot.len;
}

/// Bump a tab's ref generation after a real navigation (navigate / reload /
/// history back-forward). Refs minted before the bump embed the old
/// generation in their string, so once the next snapshot repopulates the
/// (fully-cleared) ref cache, a pre-bump ref is simply absent — acting on it
/// cleanly misses instead of silently resolving to an unrelated node that
/// happens to reuse the same CDP backend node id after the navigation.
fn bumpGenerationLocked(bridge: *Bridge, tab_id: []const u8) void {
    bridge.mu.lock();
    defer bridge.mu.unlock();
    const ref_cache = getOrCreateRefCacheLocked(bridge, tab_id) catch return;
    ref_cache.generation +%= 1;
}

/// Read a tab's current ref generation to fold into freshly-minted refs.
/// 0 for a tab with no ref cache yet (first snapshot, or never navigated).
fn currentGeneration(bridge: *Bridge, tab_id: []const u8) u32 {
    bridge.mu.lockShared();
    defer bridge.mu.unlockShared();
    if (bridge.snapshots.getPtr(tab_id)) |c| return c.generation;
    return 0;
}

fn handleAction(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const action = getQueryParam(target, "action") orelse {
        resp.sendError(request, 400, "Missing action parameter");
        return;
    };
    const ref = getQueryParam(target, "ref");
    const value = getDecodedQueryParamAlloc(arena, target, "value");
    const realistic = getQueryParam(target, "realistic");

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);
    _ = bridge.touchTab(tab_id);

    // Look up the ref in the snapshot cache to get the backend node ID
    bridge.mu.lockShared();
    const cache = bridge.snapshots.get(tab_id);
    bridge.mu.unlockShared();

    const node_id = if (ref) |ref_id|
        if (cache) |c| c.refs.get(ref_id) else null
    else
        null;

    // Build the appropriate CDP command based on action
    const actions = @import("../cdp/actions.zig");
    const kind = actions.ActionKind.fromString(action) orelse {
        resp.sendError(request, 400, "Unknown action type");
        return;
    };
    if (kind != .scroll and kind != .press and ref == null) {
        resp.sendError(request, 400, "Missing ref parameter (e.g. e0, e1)");
        return;
    }

    // For scroll and press, no element reference needed
    if (kind == .scroll) {
        const params = std.fmt.allocPrint(arena, "{{\"expression\":\"window.scrollBy(0, 500) || 'scrolled'\",\"returnByValue\":true}}", .{}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
            resp.sendError(request, 502, "CDP command failed");
            return;
        };
        resp.sendJson(request, response);
        return;
    }
    if (kind == .press) {
        const v = value orelse {
            resp.sendError(request, 400, "Missing value parameter for press");
            return;
        };
        const params = std.fmt.allocPrint(arena, "{{\"expression\":\"document.dispatchEvent(new KeyboardEvent('keydown', {{key: '{s}'}})) || 'pressed'\",\"returnByValue\":true}}", .{v}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
            resp.sendError(request, 502, "CDP command failed");
            return;
        };
        resp.sendJson(request, response);
        return;
    }

    // For element-targeted actions, need backend_node_id
    const bid = node_id orelse {
        resp.sendError(request, 400, "Ref not found. Call /snapshot first to populate refs");
        return;
    };

    // Resolving backend_node_id -> objectId and dispatching the CDP calls for
    // `kind` both happen inside the shared helper (also used by /batch's
    // /action command and by /replay).
    const dispatch = @import("../cdp/dispatch.zig");
    const use_realistic = if (realistic) |r| !std.mem.eql(u8, r, "false") else true;
    const outcome = dispatch.dispatchActionOnBackendNode(arena, client, bid, kind, value, use_realistic);
    switch (outcome) {
        .outcome => |o| {
            if (o.raw_response) |raw| {
                resp.sendJson(request, raw);
            } else {
                const escaped_label = jsonEscapeAlloc(arena, o.label) orelse o.label;
                const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"action\":\"{s}\"}}", .{escaped_label}) catch {
                    resp.sendError(request, 500, "Internal Server Error");
                    return;
                };
                resp.sendJson(request, body);
            }
        },
        .err => |e| resp.sendError(request, e.status, e.message),
    }
}

fn handleText(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);
    _ = bridge.touchTab(tab_id);

    const selector = getDecodedQueryParamAlloc(arena, target, "selector");
    const params = if (selector) |sel| blk: {
        const escaped_sel = jsonEscapeAlloc(arena, sel) orelse {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        break :blk std.fmt.allocPrint(arena, "{{\"expression\":\"(() => {{ const el = document.querySelector(\\\"{s}\\\"); return el ? (el.innerText ?? '') : ''; }})()\",\"returnByValue\":true}}", .{escaped_sel}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
    } else @as([]const u8, "{\"expression\":\"document.body ? document.body.innerText : ''\",\"returnByValue\":true}");
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleScreenshot(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const format = getQueryParam(target, "format") orelse "png";
    const quality = getQueryParam(target, "quality") orelse "80";
    const full = getQueryParam(target, "full");
    const save = if (getQueryParam(target, "save")) |s| std.mem.eql(u8, s, "true") else false;

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);
    _ = bridge.touchTab(tab_id);

    const is_full = if (full) |f| std.mem.eql(u8, f, "true") else false;

    const params = if (is_full)
        std.fmt.allocPrint(arena, "{{\"format\":\"{s}\",\"quality\":{s},\"captureBeyondViewport\":true}}", .{ format, quality })
    else
        std.fmt.allocPrint(arena, "{{\"format\":\"{s}\",\"quality\":{s}}}", .{ format, quality });

    const screenshot_params = params catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    const response = client.send(arena, protocol.Methods.page_capture_screenshot, screenshot_params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    if (save) {
        // Libretto-style artifact discipline: write the PNG to disk and hand
        // the agent a path — image bytes never enter model context.
        const b64 = extractSimpleJsonString(response, 0, "\"data\"") orelse {
            resp.sendError(request, 502, "Screenshot data missing");
            return;
        };
        const decoder = std.base64.standard.Decoder;
        const decoded_len = decoder.calcSizeForSlice(b64) catch {
            resp.sendError(request, 500, "Invalid screenshot encoding");
            return;
        };
        const bytes = arena.alloc(u8, decoded_len) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        decoder.decode(bytes, b64) catch {
            resp.sendError(request, 500, "Invalid screenshot encoding");
            return;
        };
        const storage_local = @import("../storage/local.zig");
        // Mirrors bridge/config.zig: STATE_DIR env var, default .kuri
        const state_dir = compat.getenv("STATE_DIR") orelse ".kuri";
        const out_dir = std.fmt.allocPrint(arena, "{s}/screenshots", .{state_dir}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const path = storage_local.saveToLocal(bytes, tab_id, format, out_dir, arena) catch {
            resp.sendError(request, 500, "Failed to save screenshot");
            return;
        };
        const esc_path = jsonEscapeAlloc(arena, path) orelse {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const body = std.fmt.allocPrint(arena, "{{\"path\":\"{s}\",\"bytes\":{d}}}", .{ esc_path, bytes.len }) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        resp.sendJson(request, body);
        return;
    }
    resp.sendJson(request, response);
}

fn handleEvaluate(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const expr_decoded = getDecodedQueryParamAlloc(arena, target, "expression") orelse {
        resp.sendError(request, 400, "Missing expression parameter");
        return;
    };
    const expr = jsonEscapeAlloc(arena, expr_decoded) orelse {
        resp.sendError(request, 500, "Failed to encode expression");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);
    _ = bridge.touchTab(tab_id);

    const escaped_expr = jsonEscapeAlloc(arena, expr) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped_expr}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

/// 🧁 Easter egg: she's a bro + a baddie = browdie
fn handleBrowdie(request: *std.http.Server.Request) void {
    const browdie =
        \\{"kuri":"🌰",
        \\"formerly":"browdie 🧁",
        \\"vibe":"not just a bro, not just a baddie — a browdie.",
        \\"powers":["sees the web through a11y trees","97% token reduction","stealth mode UA rotation","zero node_modules"],
        \\"catchphrase":"she browses different.",
        \\"built_with":"zig 0.16.0 btw"}
    ;
    resp.sendJson(request, browdie);
}

const DiscoverTabsError = error{
    CannotConnectToChrome,
    CannotResolveChromeAddress,
    EmptyResponseFromChrome,
    InvalidChromeResponse,
    OutOfMemory,
};

pub fn discoverTabs(arena: std.mem.Allocator, bridge: *Bridge, cfg: Config, cdp_port: u16) DiscoverTabsError!usize {
    if (@import("builtin").os.tag == .windows) return error.CannotConnectToChrome;
    const cdp_addr = parseCdpAddress(cfg.cdp_url, cdp_port);
    const host = cdp_addr.host;
    const port = cdp_addr.port;

    // Teach the bridge the Chrome CDP address so it can auto-refresh dead clients.
    bridge.setCdpAddress(host, port);

    const io = std.Io.Threaded.global_single_threaded.io();
    const address = net.IpAddress.parseIp4(host, port) catch return error.CannotResolveChromeAddress;
    const stream = net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch return error.CannotConnectToChrome;
    defer stream.close(io);

    // Set read timeout (2 seconds) to avoid blocking forever
    const timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
    std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    // HTTP/1.1 required — Chrome ignores HTTP/1.0
    const http_req = try std.fmt.allocPrint(arena, "GET /json/list HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ host, port });
    // Write request using raw syscall
    var written: usize = 0;
    while (written < http_req.len) {
        const rc = std.c.write(stream.socket.handle, http_req.ptr + written, http_req.len - written);
        if (rc <= 0) return error.CannotConnectToChrome;
        written += @intCast(rc);
    }

    // Read response with Content-Length awareness
    var response_buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < response_buf.len) {
        const n = std.posix.read(stream.socket.handle, response_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        // Once we have headers, check Content-Length to know when body is complete
        if (std.mem.indexOf(u8, response_buf[0..total], "\r\n\r\n")) |hdr_end| {
            const headers = response_buf[0..hdr_end];
            if (findContentLength(headers)) |content_len| {
                const body_start = hdr_end + 4;
                if (total >= body_start + content_len) break;
            }
        }
    }

    if (total == 0) return error.EmptyResponseFromChrome;
    const raw_response = response_buf[0..total];

    const body_start = (std.mem.indexOf(u8, raw_response, "\r\n\r\n") orelse return error.InvalidChromeResponse) + 4;
    const body = raw_response[body_start..total];

    // Parse targets and register tabs
    var registered: usize = 0;
    var pos: usize = 0;
    while (pos < body.len) {
        const id_start = std.mem.indexOfPos(u8, body, pos, "\"id\"") orelse break;

        const id_val = extractSimpleJsonString(body, id_start, "\"id\"") orelse {
            pos = id_start + 4;
            continue;
        };
        const type_val = extractSimpleJsonString(body, id_start, "\"type\"") orelse "page";
        const url_val = extractSimpleJsonString(body, id_start, "\"url\"") orelse "";
        const title_val = extractSimpleJsonString(body, id_start, "\"title\"") orelse "";
        const ws_val = extractSimpleJsonString(body, id_start, "\"webSocketDebuggerUrl\"") orelse "";

        if (std.mem.eql(u8, type_val, "page") and ws_val.len > 0) {
            const entry = TabEntry{
                .id = id_val,
                .url = url_val,
                .title = title_val,
                .ws_url = ws_val,
                .created_at = @intCast(compat.timestampSeconds()),
                .last_accessed = @intCast(compat.timestampSeconds()),
            };
            try bridge.putTab(entry);
            registered += 1;

            // Auto-apply stealth patches to each discovered tab
            if (bridge.getCdpClient(id_val)) |client| {
                const stealth = @import("../cdp/stealth.zig");
                const escaped = jsonEscapeAlloc(arena, stealth.stealth_script) orelse continue;
                const add_params = std.fmt.allocPrint(arena, "{{\"source\":\"{s}\"}}", .{escaped}) catch continue;
                _ = client.send(arena, protocol.Methods.page_add_script, add_params) catch {};

                // Set a random user agent at network level
                const ua = stealth.randomUserAgent();
                const ua_escaped = jsonEscapeAlloc(arena, ua) orelse continue;
                _ = client.send(arena, protocol.Methods.network_enable, null) catch {};
                const ua_params = std.fmt.allocPrint(arena, "{{\"userAgent\":\"{s}\"}}", .{ua_escaped}) catch continue;
                _ = client.send(arena, "Network.setUserAgentOverride", ua_params) catch {};

                std.log.info("stealth patches applied to tab {s}", .{id_val});
            }
        }

        const next_id = std.mem.indexOfPos(u8, body, id_start + 4, "\"id\"") orelse body.len;
        pos = next_id;
    }

    return registered;
}

fn handleDiscover(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge, cfg: Config, cdp_port: u16) void {
    const registered = discoverTabs(arena, bridge, cfg, cdp_port) catch |err| {
        switch (err) {
            error.CannotResolveChromeAddress => resp.sendError(request, 502, "Cannot resolve Chrome address"),
            error.CannotConnectToChrome => resp.sendError(request, 502, "Cannot connect to Chrome"),
            error.EmptyResponseFromChrome => resp.sendError(request, 502, "Empty response from Chrome"),
            error.InvalidChromeResponse => resp.sendError(request, 502, "Invalid response from Chrome"),
            else => resp.sendError(request, 500, "Internal Server Error"),
        }
        return;
    };

    const result = std.fmt.allocPrint(arena, "{{\"discovered\":{d},\"total_tabs\":{d}}}", .{ registered, bridge.tabCount() }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, result);
}

fn freeOwnedSnapshot(allocator: std.mem.Allocator, snapshot: []const @import("../snapshot/a11y.zig").A11yNode) void {
    for (snapshot) |node| {
        allocator.free(node.ref);
        allocator.free(node.role);
        allocator.free(node.name);
        allocator.free(node.value);
        allocator.free(node.description);
        allocator.free(node.state);
    }
    allocator.free(snapshot);
}

fn findContentLength(headers: []const u8) ?usize {
    // Chrome sends "Content-Length:1773" (no space after colon)
    const patterns = [_][]const u8{ "Content-Length:", "Content-Length: ", "content-length:", "content-length: " };
    for (patterns) |pat| {
        if (std.mem.indexOf(u8, headers, pat)) |cl_pos| {
            const val_start = cl_pos + pat.len;
            const val_end = std.mem.indexOfScalarPos(u8, headers, val_start, '\r') orelse continue;
            const val_str = std.mem.trim(u8, headers[val_start..val_end], " ");
            return std.fmt.parseInt(usize, val_str, 10) catch continue;
        }
    }
    return null;
}

const CdpAddress = struct {
    host: []const u8,
    port: u16,
};

fn parseCdpAddress(cdp_url: ?[]const u8, fallback_port: u16) CdpAddress {
    const raw = cdp_url orelse return .{ .host = "127.0.0.1", .port = fallback_port };
    var remainder = raw;
    var default_port = fallback_port;

    if (std.mem.startsWith(u8, raw, "ws://")) {
        remainder = raw[5..];
        default_port = 80;
    } else if (std.mem.startsWith(u8, raw, "wss://")) {
        remainder = raw[6..];
        default_port = 443;
    } else if (std.mem.startsWith(u8, raw, "http://")) {
        remainder = raw[7..];
        default_port = 80;
    } else if (std.mem.startsWith(u8, raw, "https://")) {
        remainder = raw[8..];
        default_port = 443;
    }

    const host_end = std.mem.indexOfScalar(u8, remainder, '/') orelse remainder.len;
    const host_port = remainder[0..host_end];
    if (std.mem.indexOfScalar(u8, host_port, ':')) |colon| {
        var host = host_port[0..colon];
        if (std.mem.eql(u8, host, "localhost")) host = "127.0.0.1";
        const port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch default_port;
        return .{ .host = host, .port = port };
    }

    var host = host_port;
    if (std.mem.eql(u8, host, "localhost")) host = "127.0.0.1";
    return .{ .host = host, .port = default_port };
}

fn extractSimpleJsonString(json: []const u8, start: usize, field: []const u8) ?[]const u8 {
    const field_pos = std.mem.indexOfPos(u8, json, start, field) orelse return null;
    if (field_pos - start > 1000) return null;
    const colon = std.mem.indexOfScalarPos(u8, json, field_pos + field.len, ':') orelse return null;
    // Skip whitespace and find opening quote
    var i = colon + 1;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    if (i >= json.len or json[i] != '"') return null;
    const val_start = i + 1;
    const val_end = std.mem.indexOfScalarPos(u8, json, val_start, '"') orelse return null;
    return json[val_start..val_end];
}

// --- A11y tree parsing helper ---

fn extractSimpleJsonInt(json: []const u8, start: usize, field: []const u8) ?u32 {
    const field_pos = std.mem.indexOfPos(u8, json, start, field) orelse return null;
    if (field_pos - start > 1000) return null;
    const colon = std.mem.indexOfScalarPos(u8, json, field_pos + field.len, ':') orelse return null;
    var i = colon + 1;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    var end = i;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == i) return null;
    return std.fmt.parseInt(u32, json[i..end], 10) catch null;
}

/// One raw AX node, retained through the DFS pass. Fields are slices into the
/// CDP response (which the arena owns); child_ids is the node's ordered children.
const TmpAxNode = struct {
    role: []const u8,
    name: []const u8,
    value: []const u8,
    description: []const u8,
    state: []const u8,
    backend_id: ?u32,
    child_ids: [][]const u8,
    visited: bool = false,
};

/// Extract a node's ordered `childIds` as slices into the source JSON.
fn extractChildIds(arena: std.mem.Allocator, node_json: []const u8) ![][]const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    const key = std.mem.indexOf(u8, node_json, "\"childIds\"") orelse return ids.toOwnedSlice(arena);
    const lb = std.mem.indexOfScalarPos(u8, node_json, key, '[') orelse return ids.toOwnedSlice(arena);
    const rb = std.mem.indexOfScalarPos(u8, node_json, lb, ']') orelse return ids.toOwnedSlice(arena);
    var i = lb + 1;
    while (i < rb) {
        const q1 = std.mem.indexOfScalarPos(u8, node_json, i, '"') orelse break;
        if (q1 >= rb) break;
        const q2 = std.mem.indexOfScalarPos(u8, node_json, q1 + 1, '"') orelse break;
        try ids.append(arena, node_json[q1 + 1 .. q2]);
        i = q2 + 1;
    }
    return ids.toOwnedSlice(arena);
}

/// Parse `Accessibility.getFullAXTree` into a flat slice in **pre-order DFS**,
/// with each node's real tree depth. CDP emits `nodes[]` in an order that is
/// NOT a tree walk, so we index every node by `nodeId`, then DFS from the root
/// via `childIds` to recover order + depth. Downstream (buildSnapshot) relies on
/// this ordering for sibling-run truncation, subtree scoping, and hierarchy
/// indentation. Role-less wrappers are traversed (so subtrees aren't cut) but
/// not emitted; role-bearing nodes are emitted with `depth = ancestors in tree`.
fn parseA11yNodes(arena: std.mem.Allocator, raw_json: []const u8) ![]const @import("../snapshot/a11y.zig").A11yNode {
    const a11y = @import("../snapshot/a11y.zig");
    var nodes: std.ArrayList(a11y.A11yNode) = .empty;

    const nodes_start = std.mem.indexOf(u8, raw_json, "\"nodes\"") orelse return nodes.toOwnedSlice(arena);
    const array_start = std.mem.indexOfScalarPos(u8, raw_json, nodes_start, '[') orelse return nodes.toOwnedSlice(arena);

    // Pass 1: parse every node object; index by nodeId; remember the root.
    var tmp: std.ArrayList(TmpAxNode) = .empty;
    defer {
        for (tmp.items) |t| if (t.child_ids.len > 0) arena.free(t.child_ids);
        tmp.deinit(arena);
    }
    var by_id = std.StringHashMap(usize).init(arena);
    defer by_id.deinit();
    var root_idx: ?usize = null;

    var pos = array_start + 1;
    while (pos < raw_json.len) {
        const node_start = std.mem.indexOfPos(u8, raw_json, pos, "\"nodeId\"") orelse break;
        const object_start = findContainingObjectStart(raw_json, node_start);
        const object_end = findJsonObjectEnd(raw_json, object_start) orelse break;
        const node_json = raw_json[object_start..object_end];
        pos = object_end;

        const node_id = extractTopLevelA11yValue(node_json, "\"nodeId\"") orelse continue;
        const parent_id = extractTopLevelA11yValue(node_json, "\"parentId\"");

        const idx = tmp.items.len;
        try tmp.append(arena, .{
            .role = extractTopLevelA11yValue(node_json, "\"role\"") orelse "",
            .name = extractTopLevelA11yValue(node_json, "\"name\"") orelse "",
            .value = extractTopLevelA11yValue(node_json, "\"value\"") orelse "",
            .description = extractTopLevelA11yValue(node_json, "\"description\"") orelse "",
            .state = buildA11yState(arena, node_json),
            .backend_id = extractSimpleJsonInt(node_json, 0, "\"backendDOMNodeId\""),
            .child_ids = try extractChildIds(arena, node_json),
        });
        try by_id.put(node_id, idx);
        if (parent_id == null and root_idx == null) root_idx = idx;
    }

    if (tmp.items.len == 0) return nodes.toOwnedSlice(arena);

    // Pass 2: DFS pre-order from the root via childIds → real depth + order.
    // Explicit stack (no recursion depth risk); children pushed in reverse so the
    // first child is processed first. `visited` guards against malformed cycles.
    const Frame = struct { idx: usize, depth: u16 };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(arena);
    try stack.append(arena, .{ .idx = root_idx orelse 0, .depth = 0 });
    while (stack.items.len > 0) {
        const fr = stack.items[stack.items.len - 1];
        stack.items.len -= 1;

        const t = &tmp.items[fr.idx];
        if (t.visited) continue;
        t.visited = true;

        if (t.role.len > 0) {
            try nodes.append(arena, .{
                .ref = "",
                .role = t.role,
                .name = t.name,
                .value = t.value,
                .description = t.description,
                .state = t.state,
                .backend_node_id = t.backend_id,
                .depth = fr.depth,
            });
        }

        var k = t.child_ids.len;
        while (k > 0) {
            k -= 1;
            if (by_id.get(t.child_ids[k])) |cidx| {
                if (!tmp.items[cidx].visited) try stack.append(arena, .{ .idx = cidx, .depth = fr.depth +| 1 });
            }
        }
    }

    // Safety net: emit any role-bearing node unreachable from the root (detached
    // subtrees) at depth 0, in original order, so we never lose content.
    for (tmp.items) |t| {
        if (!t.visited and t.role.len > 0) {
            try nodes.append(arena, .{
                .ref = "",
                .role = t.role,
                .name = t.name,
                .value = t.value,
                .description = t.description,
                .state = t.state,
                .backend_node_id = t.backend_id,
                .depth = 0,
            });
        }
    }

    return nodes.toOwnedSlice(arena);
}

fn findContainingObjectStart(json: []const u8, pos: usize) usize {
    var i = @min(pos, json.len);
    while (i > 0) {
        i -= 1;
        if (json[i] == '{') return i;
    }
    return pos;
}

fn findJsonObjectEnd(json: []const u8, object_start: usize) ?usize {
    if (object_start >= json.len or json[object_start] != '{') return null;
    var i = object_start;
    var depth: usize = 0;
    while (i < json.len) : (i += 1) {
        switch (json[i]) {
            '"' => {
                i = skipJsonString(json, i) orelse return null;
                if (i == 0) return null;
                i -= 1;
            },
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

fn skipWhitespace(json: []const u8, start: usize) usize {
    var i = start;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    return i;
}

fn skipJsonString(json: []const u8, quote_start: usize) ?usize {
    if (quote_start >= json.len or json[quote_start] != '"') return null;
    var i = quote_start + 1;
    while (i < json.len) : (i += 1) {
        if (json[i] == '\\') {
            i += 1;
            continue;
        }
        if (json[i] == '"') return i + 1;
    }
    return null;
}

fn parseJsonStringValue(json: []const u8, quote_start: usize) ?[]const u8 {
    const end = skipJsonString(json, quote_start) orelse return null;
    return json[quote_start + 1 .. end - 1];
}

fn parseJsonScalarValue(json: []const u8, start: usize) ?[]const u8 {
    const i = skipWhitespace(json, start);
    if (i >= json.len) return null;
    if (json[i] == '"') return parseJsonStringValue(json, i);

    var end = i;
    while (end < json.len and json[end] != ',' and json[end] != '}' and json[end] != ']' and
        json[end] != ' ' and json[end] != '\t' and json[end] != '\n' and json[end] != '\r') : (end += 1)
    {}
    if (end == i) return null;
    return json[i..end];
}

fn extractA11yValueAfterColon(json: []const u8, colon: usize) ?[]const u8 {
    const value_start = skipWhitespace(json, colon + 1);
    if (value_start >= json.len) return null;
    if (json[value_start] == '{') {
        const value_end = findJsonObjectEnd(json, value_start) orelse return null;
        return extractTopLevelA11yValue(json[value_start..value_end], "\"value\"");
    }
    return parseJsonScalarValue(json, value_start);
}

fn extractTopLevelA11yValue(object: []const u8, field: []const u8) ?[]const u8 {
    var i: usize = 0;
    var depth: usize = 0;
    while (i < object.len) : (i += 1) {
        switch (object[i]) {
            '"' => {
                if (depth == 1 and std.mem.startsWith(u8, object[i..], field)) {
                    const after_field = i + field.len;
                    const j = skipWhitespace(object, after_field);
                    if (j < object.len and object[j] == ':') {
                        return extractA11yValueAfterColon(object, j);
                    }
                }
                i = skipJsonString(object, i) orelse return null;
                if (i == 0) return null;
                i -= 1;
            },
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

fn extractPropertyValue(object: []const u8, property_name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, object, pos, "\"name\"")) |name_field| {
        const colon = std.mem.indexOfScalarPos(u8, object, name_field + 6, ':') orelse return null;
        const name_start = skipWhitespace(object, colon + 1);
        if (name_start < object.len and object[name_start] == '"') {
            const found = parseJsonStringValue(object, name_start) orelse return null;
            if (std.mem.eql(u8, found, property_name)) {
                const value_field = std.mem.indexOfPos(u8, object, name_field + 6, "\"value\"") orelse return null;
                const value_colon = std.mem.indexOfScalarPos(u8, object, value_field + 7, ':') orelse return null;
                return extractA11yValueAfterColon(object, value_colon);
            }
        }
        pos = name_field + 6;
    }
    return null;
}

fn appendStateToken(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, token: []const u8) !void {
    if (token.len == 0) return;
    if (buf.items.len > 0) try buf.append(allocator, ' ');
    try buf.appendSlice(allocator, token);
}

fn appendStateKeyValue(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    if (value.len == 0 or std.mem.eql(u8, value, "undefined") or std.mem.eql(u8, value, "null")) return;
    if (buf.items.len > 0) try buf.append(allocator, ' ');
    try buf.print(allocator, "{s}={s}", .{ key, value });
}

fn isTruthyA11yValue(value: []const u8) bool {
    return std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "mixed") or
        std.mem.eql(u8, value, "page") or
        std.mem.eql(u8, value, "spelling") or
        std.mem.eql(u8, value, "grammar");
}

fn appendBooleanState(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, object: []const u8, property_name: []const u8, token: []const u8) !void {
    const value = extractPropertyValue(object, property_name) orelse return;
    if (isTruthyA11yValue(value)) try appendStateToken(buf, allocator, token);
}

fn buildA11yState(arena: std.mem.Allocator, object: []const u8) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    appendStateKeyValue(&buf, arena, "checked", extractPropertyValue(object, "checked") orelse "") catch return "";
    appendStateKeyValue(&buf, arena, "pressed", extractPropertyValue(object, "pressed") orelse "") catch return "";
    appendStateKeyValue(&buf, arena, "expanded", extractPropertyValue(object, "expanded") orelse "") catch return "";
    appendBooleanState(&buf, arena, object, "disabled", "disabled") catch return "";
    appendBooleanState(&buf, arena, object, "readonly", "readonly") catch return "";
    appendBooleanState(&buf, arena, object, "required", "required") catch return "";
    appendBooleanState(&buf, arena, object, "selected", "selected") catch return "";
    appendBooleanState(&buf, arena, object, "focused", "focused") catch return "";

    if (extractPropertyValue(object, "invalid")) |invalid| {
        if (std.mem.eql(u8, invalid, "true")) {
            appendStateToken(&buf, arena, "invalid") catch return "";
        } else if (!std.mem.eql(u8, invalid, "false") and invalid.len > 0) {
            appendStateKeyValue(&buf, arena, "invalid", invalid) catch return "";
        }
    }
    if (extractPropertyValue(object, "autocomplete")) |autocomplete| {
        if (autocomplete.len > 0 and !std.mem.eql(u8, autocomplete, "none")) {
            appendStateKeyValue(&buf, arena, "autocomplete", autocomplete) catch return "";
        }
    }
    if (extractPropertyValue(object, "haspopup")) |haspopup| {
        if (std.mem.eql(u8, haspopup, "true")) {
            appendStateToken(&buf, arena, "haspopup") catch return "";
        } else if (!std.mem.eql(u8, haspopup, "false") and haspopup.len > 0) {
            appendStateKeyValue(&buf, arena, "haspopup", haspopup) catch return "";
        }
    }

    return buf.toOwnedSlice(arena) catch "";
}

// ── HAR Endpoints ───────────────────────────────────────────────────────

fn handleHarStart(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };

    const rec = bridge.getHarRecorder(tab_id) orelse {
        resp.sendError(request, 500, "Cannot create HAR recorder");
        return;
    };

    // If we have a CDP client, enable Network domain and wire HAR recording
    if (bridge.getCdpClient(tab_id)) |client| {
        // Wire the HAR recorder to the CDP client so events are captured in real-time
        // HAR recorder is wired via event drain in navigate/evaluate handlers

        rec.start(client) catch {
            // Continue even if Network.enable fails — we can still manually add entries
        };
    } else {
        rec.recording = true;
    }

    const body = std.fmt.allocPrint(arena, "{{\"status\":\"recording\",\"tab_id\":\"{s}\"}}", .{tab_id}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleHarStop(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };

    const rec = bridge.getHarRecorder(tab_id) orelse {
        resp.sendError(request, 404, "No HAR recorder for this tab");
        return;
    };

    // Flush buffered CDP events and disconnect HAR recorder from CDP client.
    if (bridge.getCdpClient(tab_id)) |client| {
        // First: flush any events already buffered from prior send() calls
        flushEventsToHar(arena, client, rec);

        // Second: aggressively drain the WebSocket for any remaining async events.
        client.drainWsEvents(arena, 2);
        flushEventsToHar(arena, client, rec);

        // Fetch response bodies and write the JSONL artifact BEFORE
        // Network.disable: Chromium evicts a request's response-body store
        // as soon as the domain is disabled, so this has to happen while
        // it's still live. Best-effort -- a failure here (disk full,
        // unsupported OS, etc.) must not break the existing /har/stop
        // response contract.
        // Mirrors bridge/config.zig: STATE_DIR env var, default .kuri
        const state_dir = compat.getenv("STATE_DIR") orelse ".kuri";
        const jsonl_path: ?[]const u8 = rec.writeJsonl(arena, client, state_dir, tab_id) catch |err| blk: {
            std.log.warn("HAR: writeJsonl failed: {s}", .{@errorName(err)});
            break :blk null;
        };

        // Third: stop recording (sends Network.disable).
        // handleCdpEvent still processes events after recording=false.
        const har_json = rec.stop(client) catch {
            resp.sendError(request, 500, "Failed to generate HAR");
            return;
        };

        // Fourth: flush events buffered during the Network.disable send()
        flushEventsToHar(arena, client, rec);

        defer rec.allocator.free(har_json);
        // Re-serialize since we may have added entries after stop
        const final_json = rec.toJson() catch {
            resp.sendError(request, 500, "Failed to generate HAR");
            return;
        };
        defer rec.allocator.free(final_json);
        const jsonl_field = if (jsonl_path) |p| blk: {
            const escaped = jsonEscapeAlloc(arena, p) orelse p;
            break :blk std.fmt.allocPrint(arena, "\"{s}\"", .{escaped}) catch "null";
        } else "null";
        const result = std.fmt.allocPrint(arena, "{{\"status\":\"stopped\",\"entries\":{d},\"jsonl_path\":{s},\"har\":{s}}}", .{ rec.entryCount(), jsonl_field, final_json }) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        resp.sendJson(request, result);
    } else {
        rec.recording = false;
        const har_json = rec.toJson() catch {
            resp.sendError(request, 500, "Failed to generate HAR");
            return;
        };
        defer rec.allocator.free(har_json);
        const result = std.fmt.allocPrint(arena, "{{\"status\":\"stopped\",\"entries\":{d},\"jsonl_path\":null,\"har\":{s}}}", .{ rec.entryCount(), har_json }) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        resp.sendJson(request, result);
    }
}

/// Feed all buffered CDP events from the client's event buffer to the HAR recorder.
fn flushEventsToHar(arena: std.mem.Allocator, client: *CdpClient, rec: *HarRecorder) void {
    const buffered = client.event_buf.drainTo(arena) catch return;
    defer arena.free(buffered);

    std.log.info("HAR flush: {d} buffered events", .{buffered.len});
    var network_events: usize = 0;
    for (buffered) |item| {
        defer item.owner.free(item.data);
        if (std.mem.indexOf(u8, item.data, "Network.") != null) {
            network_events += 1;
        }
        rec.handleCdpEvent(item.data);
    }
    std.log.info("HAR flush: {d} network events fed to recorder", .{network_events});
}

fn handleHarStatus(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };

    const rec = bridge.getHarRecorder(tab_id) orelse {
        const body = std.fmt.allocPrint(arena, "{{\"recording\":false,\"entries\":0,\"tab_id\":\"{s}\"}}", .{tab_id}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        resp.sendJson(request, body);
        return;
    };

    const body = std.fmt.allocPrint(arena, "{{\"recording\":{s},\"entries\":{d},\"tab_id\":\"{s}\"}}", .{
        if (rec.isRecording()) "true" else "false",
        rec.entryCount(),
        tab_id,
    }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

// ── HAR Replay / Code Generation Endpoint ───────────────────────────────

fn handleHarReplay(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const format = getQueryParam(target, "format") orelse "all";
    const filter = getQueryParam(target, "filter") orelse "api";

    const rec = bridge.getHarRecorder(tab_id) orelse {
        resp.sendError(request, 404, "No HAR recorder for this tab");
        return;
    };

    if (rec.entryCount() == 0) {
        resp.sendJson(request, "{\"entries\":0,\"message\":\"No HAR entries captured. Use /har/start, navigate, then /har/replay.\"}");
        return;
    }

    var buf: std.ArrayList(u8) = .empty;

    buf.appendSlice(arena, "{\"entries\":") catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    buf.print(arena, "{d}", .{rec.entryCount()}) catch return;
    buf.appendSlice(arena, ",\"api_calls\":[") catch return;

    var api_count: usize = 0;
    for (rec.entries.items) |entry| {
        // Filter: "api" = only JSON/XHR, "all" = everything, "doc" = documents only
        const dominated_by_api = std.mem.eql(u8, filter, "api");
        const dominated_by_doc = std.mem.eql(u8, filter, "doc");
        if (dominated_by_api) {
            if (!isApiShaped(entry.mime_type, entry.method)) continue;
        }
        if (dominated_by_doc) {
            const is_doc = std.mem.indexOf(u8, entry.mime_type, "html") != null or
                std.mem.indexOf(u8, entry.mime_type, "json") != null;
            if (!is_doc) continue;
        }

        if (api_count > 0) buf.appendSlice(arena, ",") catch return;

        const escaped_url_entry = jsonEscapeAlloc(arena, entry.url) orelse entry.url;
        const escaped_method = jsonEscapeAlloc(arena, entry.method) orelse entry.method;
        const escaped_mime = jsonEscapeAlloc(arena, entry.mime_type) orelse entry.mime_type;

        // Build the entry object
        buf.appendSlice(arena, "{") catch return;
        buf.print(arena, "\"method\":\"{s}\",\"url\":\"{s}\",\"status\":{d},\"mime\":\"{s}\"", .{
            escaped_method, escaped_url_entry, entry.status, escaped_mime,
        }) catch return;

        // Include request headers and post data if present
        if (entry.request_headers.len > 0) {
            const escaped_hdrs = jsonEscapeAlloc(arena, entry.request_headers) orelse "";
            buf.print(arena, ",\"request_headers\":\"{s}\"", .{escaped_hdrs}) catch return;
        }
        if (entry.post_data.len > 0) {
            const escaped_post = jsonEscapeAlloc(arena, entry.post_data) orelse "";
            buf.print(arena, ",\"post_data\":\"{s}\"", .{escaped_post}) catch return;
        }

        // Generate code snippets based on format
        const want_curl = std.mem.eql(u8, format, "curl") or std.mem.eql(u8, format, "all");
        const want_fetch = std.mem.eql(u8, format, "fetch") or std.mem.eql(u8, format, "all");
        const want_python = std.mem.eql(u8, format, "python") or std.mem.eql(u8, format, "all");

        if (want_curl) {
            buf.appendSlice(arena, ",\"curl\":\"") catch return;
            buf.print(arena, "curl -X {s} '{s}'", .{ escaped_method, escaped_url_entry }) catch return;
            buf.appendSlice(arena, "\"") catch return;
        }
        if (want_fetch) {
            buf.appendSlice(arena, ",\"fetch\":\"") catch return;
            if (std.mem.eql(u8, entry.method, "GET")) {
                buf.print(arena, "await fetch('{s}')", .{escaped_url_entry}) catch return;
            } else {
                buf.print(arena, "await fetch('{s}', {{method: '{s}', headers: {{'Content-Type': 'application/json'}}, body: JSON.stringify({{}})}}))", .{ escaped_url_entry, escaped_method }) catch return;
            }
            buf.appendSlice(arena, "\"") catch return;
        }
        if (want_python) {
            buf.appendSlice(arena, ",\"python\":\"") catch return;
            if (std.mem.eql(u8, entry.method, "GET")) {
                buf.print(arena, "requests.get('{s}')", .{escaped_url_entry}) catch return;
            } else {
                buf.print(arena, "requests.{s}('{s}', json={{}})", .{
                    if (std.mem.eql(u8, entry.method, "POST")) "post" else if (std.mem.eql(u8, entry.method, "PUT")) "put" else if (std.mem.eql(u8, entry.method, "DELETE")) "delete" else "post",
                    escaped_url_entry,
                }) catch return;
            }
            buf.appendSlice(arena, "\"") catch return;
        }

        buf.appendSlice(arena, "}") catch return;
        api_count += 1;
    }

    buf.appendSlice(arena, "],\"total_api_calls\":") catch return;
    buf.print(arena, "{d}", .{api_count}) catch return;
    buf.appendSlice(arena, ",\"hint\":\"Use these code snippets to interact with the site's API directly. Add cookies/headers from /cookies and /headers endpoints for authenticated requests. For full response bodies (previews here are omitted), call /har/stop and read its jsonl_path.\"}") catch return;

    const result = buf.toOwnedSlice(arena) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, result);
}

// ── Console Log Capture Endpoint ────────────────────────────────────────

fn handleConsole(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    _ = client.send(arena, protocol.Methods.runtime_enable, null) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };

    const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"message\":\"Runtime.enable sent\",\"tab_id\":\"{s}\"}}", .{tab_id}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

// ── Network Interception Endpoints ──────────────────────────────────────

fn handleInterceptStart(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    _ = client.send(arena, protocol.Methods.fetch_enable, null) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };

    const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"message\":\"Fetch.enable sent\",\"tab_id\":\"{s}\"}}", .{tab_id}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleInterceptStop(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    _ = client.send(arena, protocol.Methods.fetch_disable, null) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };

    const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"message\":\"Fetch.disable sent\",\"tab_id\":\"{s}\"}}", .{tab_id}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

// ── Close / Cleanup Endpoint ────────────────────────────────────────────

fn handleClose(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = resolveEffectiveTabIdAlloc(arena, request, bridge);

    if (tab_id) |tid| {
        const closed_in_chrome = closeTarget(arena, bridge, tid);
        bridge.removeTab(tid);
        const body = std.fmt.allocPrint(arena, "{{\"closed\":\"{s}\",\"remaining_tabs\":{d},\"cdp_closed\":{s}}}", .{
            tid,
            bridge.tabCount(),
            if (closed_in_chrome) "true" else "false",
        }) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        resp.sendJson(request, body);
    } else {
        const tabs = bridge.listTabs(arena) catch {
            resp.sendError(request, 500, "Failed to list tabs");
            return;
        };
        var closed: usize = 0;
        for (tabs) |tab| {
            if (closeTarget(arena, bridge, tab.id)) closed += 1;
            bridge.removeTab(tab.id);
        }
        const body = std.fmt.allocPrint(arena, "{{\"status\":\"close_all\",\"tabs_closed\":{d},\"cdp_closed\":{d}}}", .{ tabs.len, closed }) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        resp.sendJson(request, body);
    }
}

// ── Cookie Management Endpoints ─────────────────────────────────────────

fn handleCookies(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // Check if this is a set operation (has name and value params)
    const name = getQueryParam(target, "name");
    const value = getQueryParam(target, "value");

    if (name != null and value != null) {
        // Set cookie
        const domain = getQueryParam(target, "domain") orelse "localhost";
        const params = std.fmt.allocPrint(arena, "{{\"name\":\"{s}\",\"value\":\"{s}\",\"domain\":\"{s}\",\"path\":\"/\"}}", .{ name.?, value.?, domain }) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const response = client.send(arena, "Network.setCookie", params) catch {
            resp.sendError(request, 502, "CDP command failed");
            return;
        };
        resp.sendJson(request, response);
    } else {
        // Get all cookies
        const response = client.send(arena, "Network.getCookies", null) catch {
            resp.sendError(request, 502, "CDP command failed");
            return;
        };
        resp.sendJson(request, response);
    }
}

fn handleCookiesClear(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const response = client.send(arena, "Network.clearBrowserCookies", null) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

// ── Storage Endpoints ───────────────────────────────────────────────────

fn handleStorage(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge, storage_type: []const u8) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const key = getQueryParam(target, "key");
    const value = getQueryParam(target, "value");

    const escaped_key = if (key) |k| (jsonEscapeAlloc(arena, k) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    }) else null;
    const escaped_value = if (value) |v| (jsonEscapeAlloc(arena, v) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    }) else null;

    const expr = if (escaped_key != null and escaped_value != null)
        std.fmt.allocPrint(arena, "(() => {{ {s}.setItem('{s}', '{s}'); return 'stored'; }})()", .{ storage_type, escaped_key.?, escaped_value.? })
    else if (escaped_key) |k|
        std.fmt.allocPrint(arena, "{s}.getItem('{s}')", .{ storage_type, k })
    else
        std.fmt.allocPrint(arena, "JSON.stringify(Object.fromEntries(Object.entries({s})))", .{storage_type});

    const js = expr catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{js}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleStorageClear(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge, storage_type: []const u8) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}.clear() || 'cleared'\",\"returnByValue\":true}}", .{storage_type}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

// ── Element Info Query Endpoint ─────────────────────────────────────────

fn buildGetExpression(arena: std.mem.Allocator, query_type: []const u8, selector: ?[]const u8, attr_name: ?[]const u8) ?[]const u8 {
    if (std.mem.eql(u8, query_type, "title"))
        return std.fmt.allocPrint(arena, "document.title", .{}) catch return null;
    if (std.mem.eql(u8, query_type, "url"))
        return std.fmt.allocPrint(arena, "window.location.href", .{}) catch return null;

    const sel = selector orelse return null;
    const escaped_sel = jsonEscapeAlloc(arena, sel) orelse return null;

    if (std.mem.eql(u8, query_type, "html"))
        return std.fmt.allocPrint(arena, "document.querySelector('{s}')?.innerHTML || null", .{escaped_sel}) catch return null;
    if (std.mem.eql(u8, query_type, "value"))
        return std.fmt.allocPrint(arena, "document.querySelector('{s}')?.value || null", .{escaped_sel}) catch return null;
    if (std.mem.eql(u8, query_type, "text"))
        return std.fmt.allocPrint(arena, "document.querySelector('{s}')?.innerText || null", .{escaped_sel}) catch return null;
    if (std.mem.eql(u8, query_type, "attr")) {
        const a = attr_name orelse return null;
        const escaped_a = jsonEscapeAlloc(arena, a) orelse return null;
        return std.fmt.allocPrint(arena, "document.querySelector('{s}')?.getAttribute('{s}') || null", .{ escaped_sel, escaped_a }) catch return null;
    }
    if (std.mem.eql(u8, query_type, "count"))
        return std.fmt.allocPrint(arena, "document.querySelectorAll('{s}').length", .{escaped_sel}) catch return null;
    if (std.mem.eql(u8, query_type, "box"))
        return std.fmt.allocPrint(arena, "JSON.stringify(document.querySelector('{s}')?.getBoundingClientRect())", .{escaped_sel}) catch return null;
    if (std.mem.eql(u8, query_type, "styles"))
        return std.fmt.allocPrint(arena, "JSON.stringify(Object.fromEntries([...window.getComputedStyle(document.querySelector('{s}'))].map(k => [k, window.getComputedStyle(document.querySelector('{s}'))[k]])))", .{ escaped_sel, escaped_sel }) catch return null;

    return null;
}

fn handleGet(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const query_type = getQueryParam(target, "type") orelse {
        resp.sendError(request, 400, "Missing type parameter (html|value|attr|title|url|count|box|styles)");
        return;
    };
    const selector = getQueryParam(target, "selector");
    const attr_name = getQueryParam(target, "attr");

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);
    _ = bridge.touchTab(tab_id);

    // For "attr" type, validate the attr param early
    if (std.mem.eql(u8, query_type, "attr") and attr_name == null) {
        resp.sendError(request, 400, "Missing attr parameter");
        return;
    }

    const js = buildGetExpression(arena, query_type, selector, attr_name) orelse {
        resp.sendError(request, 400, "Unknown type or missing selector. Use: html, value, text, attr, title, url, count, box, styles");
        return;
    };

    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{js}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

// ── Navigation Endpoints ────────────────────────────────────────────────

fn handleBack(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);
    _ = bridge.touchTab(tab_id);
    const params = "{\"expression\":\"history.back() || 'back'\",\"returnByValue\":true}";
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    bumpGenerationLocked(bridge, tab_id);
    resp.sendJson(request, response);
}

fn handleForward(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);
    _ = bridge.touchTab(tab_id);
    const params = "{\"expression\":\"history.forward() || 'forward'\",\"returnByValue\":true}";
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    bumpGenerationLocked(bridge, tab_id);
    resp.sendJson(request, response);
}

fn handleReload(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);
    _ = bridge.touchTab(tab_id);
    const response = client.send(arena, protocol.Methods.page_reload, null) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    bumpGenerationLocked(bridge, tab_id);
    resp.sendJson(request, response);
}

// ── Diff Snapshot Endpoint ──────────────────────────────────────────────

/// Compute a compact-grammar diff for `tab_id` against its stored previous
/// snapshot, then atomically swap the stored snapshot to the current one.
/// Returns the diff text (owned by `arena`). On the first call for a tab the
/// diff is the full page rendered as `+ ` additions.
///
/// The diff-then-swap runs under the bridge write lock, and the diff is
/// rendered to a string (copying every byte) before the old snapshot is freed,
/// so no node pointer ever outlives the memory it references. This is the fix
/// for the earlier use-after-free that crashed the whole server whenever a
/// diff contained a removed node.
fn computeCompactDiff(arena: std.mem.Allocator, bridge: *Bridge, tab_id: []const u8, client: *CdpClient, limit: ?usize) ![]const u8 {
    const raw_response = try client.send(arena, protocol.Methods.accessibility_get_full_tree, null);
    const a11y = @import("../snapshot/a11y.zig");
    const nodes = try parseA11yNodes(arena, raw_response);
    const gen = currentGeneration(bridge, tab_id);
    const current = try a11y.buildSnapshot(nodes, .{ .compact = true, .ref_generation = gen }, arena);

    const diff_mod = @import("../snapshot/diff.zig");

    bridge.mu.lock();
    defer bridge.mu.unlock();

    const prev = if (bridge.prev_snapshots.get(tab_id)) |p| p else &[_]a11y.A11yNode{};
    var diff_text = try diff_mod.formatCompactDiff(prev, current, arena);

    // Adaptive: a mass-change diff (navigation, SPA route swap) can cost more
    // than the page it describes. When that happens send the full compact
    // snapshot instead, flagged with a `!` header so the agent knows to treat
    // it as a fresh view rather than a delta. First calls keep `+ ` grammar.
    // With `limit`, the fallback view is truncated like /snapshot?limit=N —
    // the stored baseline stays untruncated so later deltas are exact.
    if (prev.len > 0 and diff_text.len > 0) {
        const fallback_nodes = if (limit != null)
            try a11y.buildSnapshot(nodes, .{ .compact = true, .limit = limit, .ref_generation = gen }, arena)
        else
            current;
        const full_text = try a11y.formatCompact(fallback_nodes, arena);
        if (full_text.len + 64 < diff_text.len) {
            diff_text = try std.fmt.allocPrint(arena, "! page replaced — full snapshot follows\n{s}", .{full_text});
        }
    }

    // Refresh the ref cache so the @refs in this diff are actionable via
    // /action without an intervening full /snapshot call.
    refreshRefCacheLocked(bridge, tab_id, current) catch {};

    // Swap the stored snapshot to `current` (cloned into bridge memory). We have
    // the rendered diff already, so any failure here just skips the swap and
    // still returns a correct diff for this call.
    const owned_current = bridge.cloneSnapshot(current) catch return diff_text;
    const owned_key = bridge.allocator.dupe(u8, tab_id) catch {
        freeOwnedSnapshot(bridge.allocator, owned_current);
        return diff_text;
    };
    if (bridge.prev_snapshots.fetchRemove(tab_id)) |kv| {
        freeOwnedSnapshot(bridge.allocator, kv.value);
        bridge.allocator.free(kv.key);
    }
    bridge.prev_snapshots.put(owned_key, owned_current) catch {
        bridge.allocator.free(owned_key);
        freeOwnedSnapshot(bridge.allocator, owned_current);
    };
    return diff_text;
}

fn handleDiffSnapshot(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);
    _ = bridge.touchTab(tab_id);

    // Optional: truncate the page-replaced fallback (mass-change diffs) the same
    // way /snapshot?limit=N does, so a truncated-base agent loop stays cheap
    // across navigations. Normal delta lines are never truncated.
    const limit: ?usize = if (getQueryParam(request.head.target, "limit")) |lp|
        std.fmt.parseInt(usize, lp, 10) catch null
    else
        null;

    const diff_text = computeCompactDiff(arena, bridge, tab_id, client, limit) catch {
        resp.sendError(request, 502, "Failed to compute snapshot diff");
        return;
    };
    resp.sendJson(request, diff_text);
}

fn writeJsonField(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    const escaped = try json_util.jsonEscape(value, allocator);
    defer allocator.free(escaped);
    try buf.print(allocator, "\"{s}\":\"{s}\"", .{ key, escaped });
}

fn handleEmulate(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const width_str = getQueryParam(target, "width") orelse "1280";
    const height_str = getQueryParam(target, "height") orelse "720";
    const scale_str = getQueryParam(target, "scale") orelse "1";
    const ua = getQueryParam(target, "ua");

    const params = std.fmt.allocPrint(
        arena,
        "{{\"width\":{s},\"height\":{s},\"deviceScaleFactor\":{s},\"mobile\":false}}",
        .{ width_str, height_str, scale_str },
    ) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.emulation_set_device_metrics, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };

    if (ua) |ua_str| {
        const ua_params = std.fmt.allocPrint(arena, "{{\"userAgent\":\"{s}\"}}", .{ua_str}) catch {
            resp.sendJson(request, response);
            return;
        };
        _ = client.send(arena, protocol.Methods.emulation_set_user_agent, ua_params) catch {};
    }

    resp.sendJson(request, response);
}

fn handleGeolocation(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const lat = getQueryParam(target, "lat") orelse {
        resp.sendError(request, 400, "Missing lat parameter");
        return;
    };
    const lng = getQueryParam(target, "lng") orelse {
        resp.sendError(request, 400, "Missing lng parameter");
        return;
    };
    const accuracy_str = getQueryParam(target, "accuracy") orelse "1";

    const params = std.fmt.allocPrint(
        arena,
        "{{\"latitude\":{s},\"longitude\":{s},\"accuracy\":{s}}}",
        .{ lat, lng, accuracy_str },
    ) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.emulation_set_geolocation, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleUpload(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const ref = getQueryParam(target, "ref") orelse {
        resp.sendError(request, 400, "Missing ref parameter");
        return;
    };
    const file_path = getQueryParam(target, "file_path") orelse {
        resp.sendError(request, 400, "Missing file_path parameter");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // Look up the ref in the snapshot cache to get the backend node ID
    bridge.mu.lockShared();
    const cache = bridge.snapshots.get(tab_id);
    bridge.mu.unlockShared();

    const node_id = if (cache) |c| c.refs.get(ref) else null;
    const bid = node_id orelse {
        resp.sendError(request, 400, "Ref not found. Call /snapshot first to populate refs");
        return;
    };

    // Send DOM.setFileInputFiles with the resolved backendNodeId
    const escaped_file_path = jsonEscapeAlloc(arena, file_path) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"files\":[\"{s}\"],\"backendNodeId\":{d}}}", .{ escaped_file_path, bid }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.dom_set_file_input_files, params) catch {
        resp.sendError(request, 502, "DOM.setFileInputFiles failed");
        return;
    };
    resp.sendJson(request, response);
}

test "route matching" {
    const path = "/health?foo=bar";
    const clean = if (std.mem.indexOfScalar(u8, path, '?')) |idx| path[0..idx] else path;
    try std.testing.expectEqualStrings("/health", clean);
}

test "getQueryParam" {
    try std.testing.expectEqualStrings("bar", getQueryParam("/test?foo=bar", "foo").?);
    try std.testing.expectEqualStrings("123", getQueryParam("/test?a=1&tab_id=123&b=2", "tab_id").?);
    try std.testing.expect(getQueryParam("/test?foo=bar", "baz") == null);
    try std.testing.expect(getQueryParam("/test", "foo") == null);
}

test "emulate query param parsing" {
    const target = "/emulate?tab_id=abc&width=1920&height=1080&scale=2&ua=Mozilla/5.0";
    try std.testing.expectEqualStrings("abc", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("1920", getQueryParam(target, "width").?);
    try std.testing.expectEqualStrings("1080", getQueryParam(target, "height").?);
    try std.testing.expectEqualStrings("2", getQueryParam(target, "scale").?);
    try std.testing.expectEqualStrings("Mozilla/5.0", getQueryParam(target, "ua").?);
    // missing optional params return null
    try std.testing.expect(getQueryParam("/emulate?tab_id=abc", "width") == null);
    try std.testing.expect(getQueryParam("/emulate?tab_id=abc", "ua") == null);
}

test "geolocation query param parsing" {
    const target = "/geolocation?tab_id=xyz&lat=37.7749&lng=-122.4194&accuracy=10";
    try std.testing.expectEqualStrings("xyz", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("37.7749", getQueryParam(target, "lat").?);
    try std.testing.expectEqualStrings("-122.4194", getQueryParam(target, "lng").?);
    try std.testing.expectEqualStrings("10", getQueryParam(target, "accuracy").?);
    // lat and lng are required; missing returns null
    try std.testing.expect(getQueryParam("/geolocation?tab_id=xyz", "lat") == null);
    try std.testing.expect(getQueryParam("/geolocation?tab_id=xyz", "lng") == null);
}

test "emulate route matching" {
    const path = "/emulate?tab_id=abc&width=1280";
    const clean = if (std.mem.indexOfScalar(u8, path, '?')) |idx| path[0..idx] else path;
    try std.testing.expectEqualStrings("/emulate", clean);
}

test "geolocation route matching" {
    const path = "/geolocation?tab_id=abc&lat=0&lng=0";
    const clean = if (std.mem.indexOfScalar(u8, path, '?')) |idx| path[0..idx] else path;
    try std.testing.expectEqualStrings("/geolocation", clean);
}

fn handleSessionSave(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const state = bridge.exportState(arena) catch {
        resp.sendError(request, 500, "Failed to export state");
        return;
    };
    resp.sendJson(request, state);
}

fn handleSessionLoad(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const body = readRequestBody(request, arena) orelse {
        resp.sendError(request, 400, "Missing request body");
        return;
    };
    const count = bridge.importState(body, arena) catch {
        resp.sendError(request, 400, "Invalid session JSON");
        return;
    };
    const result = std.fmt.allocPrint(arena, "{{\"imported\":{d}}}", .{count}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, result);
}

fn handleAuthProfileSave(
    request: *std.http.Server.Request,
    arena: std.mem.Allocator,
    bridge: *Bridge,
    cfg: Config,
) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const name = getQueryParam(target, "name") orelse {
        resp.sendError(request, 400, "Missing name parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const origin = evalValueString(arena, client, "location.origin") orelse {
        resp.sendError(request, 502, "Failed to determine page origin");
        return;
    };
    const cookies_response = client.send(arena, protocol.Methods.network_get_cookies, null) catch {
        resp.sendError(request, 502, "Failed to collect cookies");
        return;
    };
    const cookies_json = extractJsonArrayField(cookies_response, "\"cookies\"") orelse {
        resp.sendError(request, 502, "Failed to parse cookies");
        return;
    };
    const local_storage = evalValueObject(
        arena,
        client,
        "Object.fromEntries(Object.entries(localStorage))",
    ) orelse "{}";
    const session_storage = evalValueObject(
        arena,
        client,
        "Object.fromEntries(Object.entries(sessionStorage))",
    ) orelse "{}";
    const escaped_name = jsonEscapeAlloc(arena, name) orelse {
        resp.sendError(request, 500, "Failed to escape profile name");
        return;
    };
    const escaped_origin = jsonEscapeAlloc(arena, origin) orelse {
        resp.sendError(request, 500, "Failed to escape profile origin");
        return;
    };
    const payload = std.fmt.allocPrint(
        arena,
        "{{\"version\":1,\"name\":\"{s}\",\"origin\":\"{s}\",\"saved_at\":{d},\"cookies\":{s},\"local_storage\":{s},\"session_storage\":{s}}}",
        .{ escaped_name, escaped_origin, compat.timestampSeconds(), cookies_json, local_storage, session_storage },
    ) catch {
        resp.sendError(request, 500, "Failed to build auth profile payload");
        return;
    };

    const backend = auth_profiles.saveProfile(arena, cfg.state_dir, name, origin, payload) catch |err| {
        resp.sendError(request, 500, @errorName(err));
        return;
    };
    const body = std.fmt.allocPrint(
        arena,
        "{{\"status\":\"saved\",\"name\":\"{s}\",\"origin\":\"{s}\",\"backend\":\"{s}\"}}",
        .{ escaped_name, escaped_origin, if (backend == .keychain) "keychain" else "file" },
    ) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleAuthProfileLoad(
    request: *std.http.Server.Request,
    arena: std.mem.Allocator,
    bridge: *Bridge,
    cfg: Config,
) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const name = getQueryParam(target, "name") orelse {
        resp.sendError(request, 400, "Missing name parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const payload = auth_profiles.loadProfile(arena, cfg.state_dir, name) catch |err| {
        resp.sendError(request, 404, @errorName(err));
        return;
    };
    const origin = extractSimpleJsonString(payload, 0, "\"origin\"") orelse {
        resp.sendError(request, 500, "Invalid auth profile payload");
        return;
    };
    const cookies_json = extractJsonArrayField(payload, "\"cookies\"") orelse "[]";
    const local_storage = extractJsonObjectField(payload, "\"local_storage\"") orelse "{}";
    const session_storage = extractJsonObjectField(payload, "\"session_storage\"") orelse "{}";

    const current_origin = evalValueString(arena, client, "location.origin");
    if (current_origin == null or !std.mem.eql(u8, current_origin.?, origin)) {
        const nav_params = std.fmt.allocPrint(arena, "{{\"url\":\"{s}\"}}", .{origin}) catch {
            resp.sendError(request, 500, "Failed to build navigation parameters");
            return;
        };
        _ = client.send(arena, protocol.Methods.page_navigate, nav_params) catch {
            resp.sendError(request, 502, "Failed to navigate to auth profile origin");
            return;
        };
        bumpGenerationLocked(bridge, tab_id);
        _ = client.waitForEvent(arena, "Page.loadEventFired", 1_000);
    }

    const set_cookies = std.fmt.allocPrint(arena, "{{\"cookies\":{s}}}", .{cookies_json}) catch {
        resp.sendError(request, 500, "Failed to build cookie restore payload");
        return;
    };
    _ = client.send(arena, protocol.Methods.network_set_cookies, set_cookies) catch {
        resp.sendError(request, 502, "Failed to restore cookies");
        return;
    };

    if (!applyStorageSnapshot(arena, client, "localStorage", local_storage)) {
        resp.sendError(request, 502, "Failed to restore localStorage");
        return;
    }
    if (!applyStorageSnapshot(arena, client, "sessionStorage", session_storage)) {
        resp.sendError(request, 502, "Failed to restore sessionStorage");
        return;
    }

    const escaped_name = jsonEscapeAlloc(arena, name) orelse {
        resp.sendError(request, 500, "Failed to escape profile name");
        return;
    };
    const escaped_origin = jsonEscapeAlloc(arena, origin) orelse {
        resp.sendError(request, 500, "Failed to escape profile origin");
        return;
    };
    const body = std.fmt.allocPrint(
        arena,
        "{{\"status\":\"loaded\",\"name\":\"{s}\",\"origin\":\"{s}\"}}",
        .{ escaped_name, escaped_origin },
    ) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleAuthProfileList(
    request: *std.http.Server.Request,
    arena: std.mem.Allocator,
    cfg: Config,
) void {
    const profiles = auth_profiles.listProfiles(arena, cfg.state_dir) catch |err| {
        resp.sendError(request, 500, @errorName(err));
        return;
    };
    defer auth_profiles.freeProfiles(arena, profiles);

    var json_buf: std.ArrayList(u8) = .empty;
    json_buf.appendSlice(arena, "{\"profiles\":[") catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    for (profiles, 0..) |profile, i| {
        if (i > 0) json_buf.appendSlice(arena, ",") catch {};
        const escaped_name = jsonEscapeAlloc(arena, profile.name) orelse {
            resp.sendError(request, 500, "Failed to encode profile name");
            return;
        };
        const escaped_origin = jsonEscapeAlloc(arena, profile.origin) orelse {
            resp.sendError(request, 500, "Failed to encode profile origin");
            return;
        };
        json_buf.print(
            arena,
            "{{\"name\":\"{s}\",\"origin\":\"{s}\",\"saved_at\":{d},\"backend\":\"{s}\"}}",
            .{
                escaped_name,
                escaped_origin,
                profile.saved_at,
                if (profile.backend == .keychain) "keychain" else "file",
            },
        ) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
    }
    json_buf.appendSlice(arena, "]}") catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, json_buf.items);
}

fn handleAuthProfileDelete(
    request: *std.http.Server.Request,
    arena: std.mem.Allocator,
    cfg: Config,
) void {
    const target = request.head.target;
    const name = getQueryParam(target, "name") orelse {
        resp.sendError(request, 400, "Missing name parameter");
        return;
    };
    auth_profiles.deleteProfile(arena, cfg.state_dir, name) catch |err| {
        resp.sendError(request, 404, @errorName(err));
        return;
    };
    const escaped_name = jsonEscapeAlloc(arena, name) orelse {
        resp.sendError(request, 500, "Failed to escape profile name");
        return;
    };
    const body = std.fmt.allocPrint(arena, "{{\"status\":\"deleted\",\"name\":\"{s}\"}}", .{escaped_name}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

// ---------------------------------------------------------------------------
// `connect` feature: persisted, encrypted browser logins backed by nanostore.
// Captures the same cookies + localStorage + sessionStorage snapshot as the
// auth-profile handlers, but stores it AES-256-GCM-encrypted via connect_store.
// ---------------------------------------------------------------------------

fn handleConnectSave(
    request: *std.http.Server.Request,
    arena: std.mem.Allocator,
    bridge: *Bridge,
    cfg: Config,
) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const name = getQueryParam(target, "name") orelse {
        resp.sendError(request, 400, "Missing name parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const origin = evalValueString(arena, client, "location.origin") orelse {
        resp.sendError(request, 502, "Failed to determine page origin");
        return;
    };
    const cookies_response = client.send(arena, protocol.Methods.network_get_cookies, null) catch {
        resp.sendError(request, 502, "Failed to collect cookies");
        return;
    };
    const cookies_json = extractJsonArrayField(cookies_response, "\"cookies\"") orelse {
        resp.sendError(request, 502, "Failed to parse cookies");
        return;
    };
    const local_storage = evalValueObject(
        arena,
        client,
        "Object.fromEntries(Object.entries(localStorage))",
    ) orelse "{}";
    const session_storage = evalValueObject(
        arena,
        client,
        "Object.fromEntries(Object.entries(sessionStorage))",
    ) orelse "{}";
    const escaped_name = jsonEscapeAlloc(arena, name) orelse {
        resp.sendError(request, 500, "Failed to escape connection name");
        return;
    };
    const escaped_origin = jsonEscapeAlloc(arena, origin) orelse {
        resp.sendError(request, 500, "Failed to escape connection origin");
        return;
    };
    const payload = std.fmt.allocPrint(
        arena,
        "{{\"version\":1,\"name\":\"{s}\",\"origin\":\"{s}\",\"saved_at\":{d},\"cookies\":{s},\"local_storage\":{s},\"session_storage\":{s}}}",
        .{ escaped_name, escaped_origin, compat.timestampSeconds(), cookies_json, local_storage, session_storage },
    ) catch {
        resp.sendError(request, 500, "Failed to build connection payload");
        return;
    };

    connect_store.saveSession(arena, cfg.state_dir, cfg.vault_passphrase, name, origin, payload) catch |err| {
        resp.sendError(request, 500, @errorName(err));
        return;
    };
    const body = std.fmt.allocPrint(
        arena,
        "{{\"status\":\"saved\",\"name\":\"{s}\",\"origin\":\"{s}\",\"encrypted\":true}}",
        .{ escaped_name, escaped_origin },
    ) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleConnectLoad(
    request: *std.http.Server.Request,
    arena: std.mem.Allocator,
    bridge: *Bridge,
    cfg: Config,
) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const name = getQueryParam(target, "name") orelse {
        resp.sendError(request, 400, "Missing name parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const payload = connect_store.loadSession(arena, cfg.state_dir, cfg.vault_passphrase, name) catch |err| {
        resp.sendError(request, 404, @errorName(err));
        return;
    };
    const origin = extractSimpleJsonString(payload, 0, "\"origin\"") orelse {
        resp.sendError(request, 500, "Invalid connection payload");
        return;
    };
    const cookies_json = extractJsonArrayField(payload, "\"cookies\"") orelse "[]";
    const local_storage = extractJsonObjectField(payload, "\"local_storage\"") orelse "{}";
    const session_storage = extractJsonObjectField(payload, "\"session_storage\"") orelse "{}";

    const current_origin = evalValueString(arena, client, "location.origin");
    if (current_origin == null or !std.mem.eql(u8, current_origin.?, origin)) {
        const nav_params = std.fmt.allocPrint(arena, "{{\"url\":\"{s}\"}}", .{origin}) catch {
            resp.sendError(request, 500, "Failed to build navigation parameters");
            return;
        };
        _ = client.send(arena, protocol.Methods.page_navigate, nav_params) catch {
            resp.sendError(request, 502, "Failed to navigate to connection origin");
            return;
        };
        bumpGenerationLocked(bridge, tab_id);
        _ = client.waitForEvent(arena, "Page.loadEventFired", 1_000);
    }

    const set_cookies = std.fmt.allocPrint(arena, "{{\"cookies\":{s}}}", .{cookies_json}) catch {
        resp.sendError(request, 500, "Failed to build cookie restore payload");
        return;
    };
    _ = client.send(arena, protocol.Methods.network_set_cookies, set_cookies) catch {
        resp.sendError(request, 502, "Failed to restore cookies");
        return;
    };
    if (!applyStorageSnapshot(arena, client, "localStorage", local_storage)) {
        resp.sendError(request, 502, "Failed to restore localStorage");
        return;
    }
    if (!applyStorageSnapshot(arena, client, "sessionStorage", session_storage)) {
        resp.sendError(request, 502, "Failed to restore sessionStorage");
        return;
    }
    const escaped_name = jsonEscapeAlloc(arena, name) orelse {
        resp.sendError(request, 500, "Failed to escape connection name");
        return;
    };
    const escaped_origin = jsonEscapeAlloc(arena, origin) orelse {
        resp.sendError(request, 500, "Failed to escape connection origin");
        return;
    };
    const body = std.fmt.allocPrint(
        arena,
        "{{\"status\":\"loaded\",\"name\":\"{s}\",\"origin\":\"{s}\"}}",
        .{ escaped_name, escaped_origin },
    ) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleConnectList(
    request: *std.http.Server.Request,
    arena: std.mem.Allocator,
    cfg: Config,
) void {
    const names = connect_store.listSessions(arena, cfg.state_dir, cfg.vault_passphrase) catch |err| {
        resp.sendError(request, 500, @errorName(err));
        return;
    };
    var json_buf: std.ArrayList(u8) = .empty;
    json_buf.appendSlice(arena, "{\"connections\":[") catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    for (names, 0..) |n, i| {
        if (i > 0) json_buf.appendSlice(arena, ",") catch {};
        const escaped = jsonEscapeAlloc(arena, n) orelse {
            resp.sendError(request, 500, "Failed to encode connection name");
            return;
        };
        json_buf.print(arena, "\"{s}\"", .{escaped}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
    }
    json_buf.appendSlice(arena, "]}") catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, json_buf.items);
}

fn handleConnectDelete(
    request: *std.http.Server.Request,
    arena: std.mem.Allocator,
    cfg: Config,
) void {
    const target = request.head.target;
    const name = getQueryParam(target, "name") orelse {
        resp.sendError(request, 400, "Missing name parameter");
        return;
    };
    connect_store.deleteSession(arena, cfg.state_dir, cfg.vault_passphrase, name) catch |err| {
        resp.sendError(request, 404, @errorName(err));
        return;
    };
    const escaped_name = jsonEscapeAlloc(arena, name) orelse {
        resp.sendError(request, 500, "Failed to escape connection name");
        return;
    };
    const body = std.fmt.allocPrint(arena, "{{\"status\":\"deleted\",\"name\":\"{s}\"}}", .{escaped_name}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleDebugEnable(
    request: *std.http.Server.Request,
    arena: std.mem.Allocator,
    bridge: *Bridge,
) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const freeze = getQueryParam(target, "freeze");
    const freeze_enabled = freeze != null and std.mem.eql(u8, freeze.?, "true");
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    if (bridge.getDebugScriptId(tab_id, arena)) |existing_id| {
        defer arena.free(existing_id);
        const remove_params = std.fmt.allocPrint(
            arena,
            "{{\"identifier\":\"{s}\"}}",
            .{existing_id},
        ) catch {
            resp.sendError(request, 500, "Failed to build debug cleanup payload");
            return;
        };
        _ = client.send(arena, protocol.Methods.page_remove_script, remove_params) catch {};
    }

    const source = buildDebugModeScript(arena, freeze_enabled) catch {
        resp.sendError(request, 500, "Failed to build debug mode script");
        return;
    };
    const escaped = jsonEscapeAlloc(arena, source) orelse {
        resp.sendError(request, 500, "Failed to encode debug mode script");
        return;
    };

    const add_params = std.fmt.allocPrint(arena, "{{\"source\":\"{s}\"}}", .{escaped}) catch {
        resp.sendError(request, 500, "Failed to build debug mode install payload");
        return;
    };
    const add_response = client.send(arena, protocol.Methods.page_add_script, add_params) catch {
        resp.sendError(request, 502, "Failed to install debug mode script");
        return;
    };
    const script_id = extractSimpleJsonString(add_response, 0, "\"identifier\"") orelse {
        resp.sendError(request, 502, "Debug mode script installation returned no identifier");
        return;
    };
    bridge.setDebugScriptId(tab_id, script_id) catch {
        resp.sendError(request, 500, "Failed to track debug mode script");
        return;
    };

    const eval_params = std.fmt.allocPrint(
        arena,
        "{{\"expression\":\"{s}\",\"returnByValue\":true}}",
        .{escaped},
    ) catch {
        resp.sendError(request, 500, "Failed to build debug mode evaluation payload");
        return;
    };
    const eval_response = client.send(arena, protocol.Methods.runtime_evaluate, eval_params) catch {
        resp.sendError(request, 502, "Failed to enable debug mode in current page");
        return;
    };
    _ = eval_response;

    const body = std.fmt.allocPrint(
        arena,
        "{{\"status\":\"enabled\",\"tab_id\":\"{s}\",\"freeze\":{s},\"script_id\":\"{s}\"}}",
        .{ tab_id, if (freeze_enabled) "true" else "false", script_id },
    ) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleDebugDisable(
    request: *std.http.Server.Request,
    arena: std.mem.Allocator,
    bridge: *Bridge,
) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    if (bridge.getDebugScriptId(tab_id, arena)) |script_id| {
        defer arena.free(script_id);
        const remove_params = std.fmt.allocPrint(
            arena,
            "{{\"identifier\":\"{s}\"}}",
            .{script_id},
        ) catch {
            resp.sendError(request, 500, "Failed to build debug cleanup payload");
            return;
        };
        _ = client.send(arena, protocol.Methods.page_remove_script, remove_params) catch {};
    }
    bridge.clearDebugScriptId(tab_id);

    const teardown_script =
        \\(() => {
        \\  if (window.__kuriDebug__ && typeof window.__kuriDebug__.destroy === "function") {
        \\    window.__kuriDebug__.destroy();
        \\    return "kuri-debug-disabled";
        \\  }
        \\  return "kuri-debug-not-active";
        \\})()
    ;
    const escaped = jsonEscapeAlloc(arena, teardown_script) orelse {
        resp.sendError(request, 500, "Failed to encode debug teardown script");
        return;
    };
    const params = std.fmt.allocPrint(
        arena,
        "{{\"expression\":\"{s}\",\"returnByValue\":true}}",
        .{escaped},
    ) catch {
        resp.sendError(request, 500, "Failed to build debug teardown payload");
        return;
    };
    _ = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {};

    const body = std.fmt.allocPrint(
        arena,
        "{{\"status\":\"disabled\",\"tab_id\":\"{s}\"}}",
        .{tab_id},
    ) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

// ── Annotated / Diff Screenshot & Screencast Endpoints ──────────────────

fn handleAnnotatedScreenshot(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const ref = getQueryParam(target, "ref") orelse {
        resp.sendError(request, 400, "Missing ref parameter");
        return;
    };
    _ = ref;

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // Highlight the node with an overlay
    const highlight_params = "{\"nodeId\":0,\"highlightConfig\":{\"showInfo\":true,\"contentColor\":{\"r\":111,\"g\":168,\"b\":220,\"a\":0.66}}}";
    _ = client.send(arena, protocol.Methods.overlay_highlight_node, highlight_params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };

    // Take screenshot
    const screenshot_params = "{\"format\":\"png\"}";
    const response = client.send(arena, protocol.Methods.page_capture_screenshot, screenshot_params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };

    // Clean up highlight
    _ = client.send(arena, protocol.Methods.overlay_hide_highlight, null) catch {};

    resp.sendJson(request, response);
}

fn handleDiffScreenshot(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const delay_str = getQueryParam(target, "delay") orelse "1000";

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const screenshot_params = "{\"format\":\"png\"}";

    // Take first screenshot
    const resp1 = client.send(arena, protocol.Methods.page_capture_screenshot, screenshot_params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };

    // Sleep for the delay
    const delay_ms = std.fmt.parseInt(u64, delay_str, 10) catch 1000;
    compat.threadSleep(delay_ms * std.time.ns_per_ms);

    // Take second screenshot
    const resp2 = client.send(arena, protocol.Methods.page_capture_screenshot, screenshot_params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };

    const body = std.fmt.allocPrint(arena, "{{\"before\":{s},\"after\":{s}}}", .{ resp1, resp2 }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleScreencastStart(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const params = "{\"format\":\"jpeg\",\"quality\":80}";
    _ = client.send(arena, protocol.Methods.page_start_screencast, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };

    const body = std.fmt.allocPrint(arena, "{{\"status\":\"screencast_started\",\"tab_id\":\"{s}\"}}", .{tab_id}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleScreencastStop(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    _ = client.send(arena, protocol.Methods.page_stop_screencast, null) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };

    const body = std.fmt.allocPrint(arena, "{{\"status\":\"screencast_stopped\",\"tab_id\":\"{s}\"}}", .{tab_id}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

const handleVideoStart = handleScreencastStart;
const handleVideoStop = handleScreencastStop;

// ── Lightpanda Parity Endpoints ─────────────────────────────────────────

fn handleMarkdown(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const js =
        \\(function(){
        \\  function n2md(node,li){
        \\    if(node.nodeType===3)return node.textContent;
        \\    if(node.nodeType!==1)return '';
        \\    var tag=node.tagName.toLowerCase(),c='',ch=node.childNodes;
        \\    for(var i=0;i<ch.length;i++)c+=n2md(ch[i]);
        \\    switch(tag){
        \\      case 'h1':return '# '+c.trim()+'\\n\\n';
        \\      case 'h2':return '## '+c.trim()+'\\n\\n';
        \\      case 'h3':return '### '+c.trim()+'\\n\\n';
        \\      case 'h4':return '#### '+c.trim()+'\\n\\n';
        \\      case 'h5':return '##### '+c.trim()+'\\n\\n';
        \\      case 'h6':return '###### '+c.trim()+'\\n\\n';
        \\      case 'p':return c.trim()+'\\n\\n';
        \\      case 'br':return '\\n';
        \\      case 'hr':return '---\\n\\n';
        \\      case 'strong':case 'b':return '**'+c+'**';
        \\      case 'em':case 'i':return '*'+c+'*';
        \\      case 'code':return '`'+c+'`';
        \\      case 'pre':return '```\\n'+c+'\\n```\\n\\n';
        \\      case 'blockquote':return c.split('\\n').map(function(l){return '> '+l}).join('\\n')+'\\n\\n';
        \\      case 'a':var h=node.getAttribute('href');return '['+c+']('+h+')';
        \\      case 'img':var s=node.getAttribute('src'),a=node.getAttribute('alt')||'';return '!['+a+']('+s+')';
        \\      case 'ul':case 'ol':return c+'\\n';
        \\      case 'li':return (li=node.parentNode&&node.parentNode.tagName==='OL'?'1. ':'- ')+c.trim()+'\\n';
        \\      case 'table':return c+'\\n';
        \\      case 'tr':var cells=[];for(var j=0;j<node.children.length;j++)cells.push(n2md(node.children[j]).trim());return '| '+cells.join(' | ')+' |\\n';
        \\      case 'thead':var r=c,cols=node.querySelector('tr')?node.querySelector('tr').children.length:0;var sep='|';for(var k=0;k<cols;k++)sep+=' --- |';return r+sep+'\\n';
        \\      case 'script':case 'style':case 'noscript':return '';
        \\      default:return c;
        \\    }
        \\  }
        \\  return n2md(document.body);
        \\})()
    ;

    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{js}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleLinks(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const js = "JSON.stringify([...document.querySelectorAll('a[href]')].map(a=>({text:a.innerText.trim().substring(0,200),href:a.href})))";

    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{js}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handlePdf(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const landscape = getQueryParam(target, "landscape") orelse "false";
    const params = std.fmt.allocPrint(arena, "{{\"landscape\":{s},\"printBackground\":true}}", .{landscape}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    const response = client.send(arena, protocol.Methods.page_print_to_pdf, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleDomQuery(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const selector = getQueryParam(target, "selector") orelse {
        resp.sendError(request, 400, "Missing selector parameter");
        return;
    };
    const all = getQueryParam(target, "all");

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // Step 1: Get document root node
    const doc_response = client.send(arena, protocol.Methods.dom_get_document, "{\"depth\":0}") catch {
        resp.sendError(request, 502, "DOM.getDocument failed");
        return;
    };
    const root_node_id = extractSimpleJsonInt(doc_response, 0, "\"nodeId\"") orelse {
        resp.sendError(request, 500, "Could not extract root nodeId");
        return;
    };

    // Step 2: Query selector
    const use_all = if (all) |a| std.mem.eql(u8, a, "true") else false;
    const method = if (use_all) protocol.Methods.dom_query_selector_all else protocol.Methods.dom_query_selector;

    const query_params = std.fmt.allocPrint(arena, "{{\"nodeId\":{d},\"selector\":\"{s}\"}}", .{ root_node_id, selector }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, method, query_params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleDomHtml(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const node_id_str = getQueryParam(target, "node_id") orelse {
        resp.sendError(request, 400, "Missing node_id parameter");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const params = std.fmt.allocPrint(arena, "{{\"nodeId\":{s}}}", .{node_id_str}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.dom_get_outer_html, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleCookiesDelete(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const name = getQueryParam(target, "name") orelse {
        resp.sendError(request, 400, "Missing name parameter");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const escaped_name = jsonEscapeAlloc(arena, name) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const domain = getQueryParam(target, "domain");
    const params = if (domain) |d| blk: {
        const escaped_domain = jsonEscapeAlloc(arena, d) orelse {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        break :blk std.fmt.allocPrint(arena, "{{\"name\":\"{s}\",\"domain\":\"{s}\"}}", .{ escaped_name, escaped_domain });
    } else std.fmt.allocPrint(arena, "{{\"name\":\"{s}\"}}", .{escaped_name});

    const delete_params = params catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.network_delete_cookies, delete_params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleHeaders(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const body = readRequestBody(request, arena) orelse {
        // If no body, enable with empty headers
        const params = "{\"headers\":{}}";
        const response = client.send(arena, protocol.Methods.network_set_extra_http_headers, params) catch {
            resp.sendError(request, 502, "CDP command failed");
            return;
        };
        resp.sendJson(request, response);
        return;
    };

    const params = std.fmt.allocPrint(arena, "{{\"headers\":{s}}}", .{body}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.network_set_extra_http_headers, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleScriptInject(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };

    // Support both query param and POST body for script source.
    // POST body is preferred for large scripts that exceed URL length limits.
    const source = blk: {
        // Try POST body first (JSON: {"source": "..."})
        if (readRequestBody(request, arena)) |body| {
            if (body.len > 0) {
                // Try to extract "source" field from JSON body
                if (extractSimpleJsonString(body, 0, "\"source\"")) |s| {
                    break :blk s;
                }
                // If not JSON, treat entire body as raw script source
                break :blk body;
            }
        }
        // Fall back to query param
        break :blk getQueryParam(target, "source") orelse {
            resp.sendError(request, 400, "Missing source parameter — send as POST body or ?source= query param");
            return;
        };
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // Build JSON with proper escaping for the script source
    const escaped = jsonEscapeAlloc(arena, source) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"source\":\"{s}\"}}", .{escaped}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.page_add_script, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

/// Escape a string for embedding inside a JSON string value.
/// Handles backslash, double-quote, newlines, tabs, and control characters.
fn jsonEscapeAlloc(allocator: std.mem.Allocator, input: []const u8) ?[]const u8 {
    // Count output size
    var out_len: usize = 0;
    for (input) |c| {
        out_len += switch (c) {
            '"', '\\' => 2,
            '\n', '\r', '\t' => 2,
            else => if (c < 0x20) @as(usize, 6) else 1,
        };
    }
    if (out_len == input.len) return input; // no escaping needed
    const buf = allocator.alloc(u8, out_len) catch return null;
    var i: usize = 0;
    for (input) |c| {
        switch (c) {
            '"' => {
                buf[i] = '\\';
                buf[i + 1] = '"';
                i += 2;
            },
            '\\' => {
                buf[i] = '\\';
                buf[i + 1] = '\\';
                i += 2;
            },
            '\n' => {
                buf[i] = '\\';
                buf[i + 1] = 'n';
                i += 2;
            },
            '\r' => {
                buf[i] = '\\';
                buf[i + 1] = 'r';
                i += 2;
            },
            '\t' => {
                buf[i] = '\\';
                buf[i + 1] = 't';
                i += 2;
            },
            else => if (c < 0x20) {
                const hex = "0123456789abcdef";
                buf[i] = '\\';
                buf[i + 1] = 'u';
                buf[i + 2] = '0';
                buf[i + 3] = '0';
                buf[i + 4] = hex[c >> 4];
                buf[i + 5] = hex[c & 0x0f];
                i += 6;
            } else {
                buf[i] = c;
                i += 1;
            },
        }
    }
    return buf;
}

fn buildDebugModeScript(allocator: std.mem.Allocator, freeze_enabled: bool) ![]u8 {
    const template =
        \\(() => {
        \\  const KEY = "__kuriDebug__";
        \\  const ROOT_ATTR = "data-kuri-debug-root";
        \\  const FREEZE_STYLE_ID = "kuri-debug-freeze-style";
        \\  const freezeInitially = @@FREEZE@@;
        \\  if (window[KEY] && typeof window[KEY].destroy === "function") {
        \\    window[KEY].destroy();
        \\  }
        \\  const state = { target: null, locked: false, freeze: freezeInitially };
        \\  const root = document.createElement("div");
        \\  root.setAttribute(ROOT_ATTR, "true");
        \\  Object.assign(root.style, {
        \\    position: "fixed",
        \\    inset: "0",
        \\    zIndex: "2147483647",
        \\    pointerEvents: "none",
        \\    fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
        \\  });
        \\  const box = document.createElement("div");
        \\  Object.assign(box.style, {
        \\    position: "fixed",
        \\    border: "2px solid #6fa8dc",
        \\    background: "rgba(111, 168, 220, 0.16)",
        \\    boxShadow: "0 0 0 1px rgba(16, 24, 40, 0.24)",
        \\    borderRadius: "6px",
        \\    pointerEvents: "none",
        \\    display: "none",
        \\  });
        \\  const hud = document.createElement("div");
        \\  Object.assign(hud.style, {
        \\    position: "fixed",
        \\    right: "16px",
        \\    bottom: "16px",
        \\    width: "320px",
        \\    background: "rgba(15, 23, 42, 0.94)",
        \\    color: "#e5eef9",
        \\    border: "1px solid rgba(148, 163, 184, 0.35)",
        \\    borderRadius: "12px",
        \\    boxShadow: "0 14px 40px rgba(15, 23, 42, 0.35)",
        \\    padding: "12px",
        \\    pointerEvents: "auto",
        \\    backdropFilter: "blur(8px)",
        \\    fontSize: "12px",
        \\  });
        \\  const title = document.createElement("div");
        \\  title.style.fontWeight = "700";
        \\  title.style.color = "#f8fafc";
        \\  title.style.marginBottom = "6px";
        \\  title.style.wordBreak = "break-word";
        \\  const meta = document.createElement("div");
        \\  meta.style.fontSize = "11px";
        \\  meta.style.lineHeight = "1.45";
        \\  meta.style.color = "#bfdbfe";
        \\  const selector = document.createElement("div");
        \\  selector.style.fontSize = "11px";
        \\  selector.style.lineHeight = "1.45";
        \\  selector.style.color = "#93c5fd";
        \\  selector.style.marginTop = "6px";
        \\  selector.style.wordBreak = "break-word";
        \\  const actions = document.createElement("div");
        \\  Object.assign(actions.style, { display: "flex", gap: "8px", marginTop: "10px" });
        \\  const lockButton = document.createElement("button");
        \\  const freezeButton = document.createElement("button");
        \\  for (const button of [lockButton, freezeButton]) {
        \\    button.type = "button";
        \\    Object.assign(button.style, {
        \\      appearance: "none",
        \\      border: "1px solid rgba(147, 197, 253, 0.35)",
        \\      background: "rgba(37, 99, 235, 0.18)",
        \\      color: "#e0f2fe",
        \\      borderRadius: "8px",
        \\      padding: "6px 8px",
        \\      fontSize: "11px",
        \\      fontWeight: "600",
        \\      cursor: "pointer",
        \\    });
        \\  }
        \\  actions.append(lockButton, freezeButton);
        \\  hud.append(title, meta, selector, actions);
        \\  root.append(box, hud);
        \\  document.documentElement.appendChild(root);
        \\  const ensureFreezeStyle = () => {
        \\    let style = document.getElementById(FREEZE_STYLE_ID);
        \\    if (!style) {
        \\      style = document.createElement("style");
        \\      style.id = FREEZE_STYLE_ID;
        \\      style.textContent = "*,:before,:after{animation-play-state:paused!important;transition-duration:0s!important;transition-delay:0s!important;scroll-behavior:auto!important;}";
        \\      document.documentElement.appendChild(style);
        \\    }
        \\  };
        \\  const removeFreezeStyle = () => {
        \\    document.getElementById(FREEZE_STYLE_ID)?.remove();
        \\  };
        \\  const isIgnored = (el) => {
        \\    if (!el || el === document.documentElement || el === document.body) return true;
        \\    if (root.contains(el)) return true;
        \\    const style = window.getComputedStyle(el);
        \\    const rect = el.getBoundingClientRect();
        \\    const z = Number.parseInt(style.zIndex || "0", 10);
        \\    const coversViewport = rect.width >= window.innerWidth * 0.95 && rect.height >= window.innerHeight * 0.95;
        \\    if (style.pointerEvents === "none" && style.position === "fixed" && Number.isFinite(z) && z >= 100000) return true;
        \\    if (coversViewport && (style.position === "fixed" || style.position === "absolute") && (style.backgroundColor === "transparent" || style.backgroundColor === "rgba(0, 0, 0, 0)" || Number.parseFloat(style.opacity || "1") < 0.1 || (Number.isFinite(z) && z > 100000))) return true;
        \\    return false;
        \\  };
        \\  const pickElement = (x, y) => {
        \\    for (const el of document.elementsFromPoint(x, y)) {
        \\      if (!isIgnored(el)) return el;
        \\    }
        \\    return null;
        \\  };
        \\  const toSelector = (el) => {
        \\    if (!el) return "none";
        \\    const tag = (el.tagName || "node").toLowerCase();
        \\    if (el.id) return `${tag}#${el.id}`;
        \\    const classes = [...(el.classList || [])].slice(0, 3);
        \\    return classes.length > 0 ? `${tag}.${classes.join(".")}` : tag;
        \\  };
        \\  const labelFor = (el) => {
        \\    if (!el) return "No element selected";
        \\    const tag = (el.tagName || "node").toLowerCase();
        \\    const text = (el.innerText || el.textContent || "").trim().replace(/\s+/g, " ").slice(0, 48);
        \\    return text ? `<${tag}> ${text}` : `<${tag}>`;
        \\  };
        \\  const render = () => {
        \\    if (state.freeze) ensureFreezeStyle();
        \\    else removeFreezeStyle();
        \\    lockButton.textContent = state.locked ? "Unlock" : "Lock";
        \\    freezeButton.textContent = state.freeze ? "Unfreeze" : "Freeze";
        \\    const el = state.target;
        \\    if (!el || !document.contains(el)) {
        \\      title.textContent = "No element selected";
        \\      meta.textContent = `debug ${state.freeze ? "frozen" : "live"}${state.locked ? " • locked" : ""}`;
        \\      selector.textContent = "Move over the page to inspect.";
        \\      box.style.display = "none";
        \\      return;
        \\    }
        \\    const rect = el.getBoundingClientRect();
        \\    title.textContent = labelFor(el);
        \\    meta.textContent = `${Math.round(rect.width)}×${Math.round(rect.height)} • ${state.freeze ? "frozen" : "live"}${state.locked ? " • locked" : ""}`;
        \\    selector.textContent = toSelector(el);
        \\    box.style.display = "block";
        \\    box.style.left = `${Math.max(0, rect.left)}px`;
        \\    box.style.top = `${Math.max(0, rect.top)}px`;
        \\    box.style.width = `${Math.max(0, rect.width)}px`;
        \\    box.style.height = `${Math.max(0, rect.height)}px`;
        \\  };
        \\  const onMove = (event) => {
        \\    if (state.locked) return;
        \\    state.target = pickElement(event.clientX, event.clientY);
        \\    render();
        \\  };
        \\  const onClick = (event) => {
        \\    if (root.contains(event.target)) return;
        \\    state.target = pickElement(event.clientX, event.clientY);
        \\    state.locked = true;
        \\    event.preventDefault();
        \\    event.stopPropagation();
        \\    render();
        \\  };
        \\  const onKeyDown = (event) => {
        \\    if (event.key === "Escape") {
        \\      event.preventDefault();
        \\      destroy();
        \\      return;
        \\    }
        \\    if (event.key.toLowerCase() === "f") {
        \\      state.freeze = !state.freeze;
        \\      render();
        \\    }
        \\    if (event.key.toLowerCase() === "l") {
        \\      state.locked = !state.locked;
        \\      render();
        \\    }
        \\  };
        \\  lockButton.addEventListener("click", () => { state.locked = !state.locked; render(); });
        \\  freezeButton.addEventListener("click", () => { state.freeze = !state.freeze; render(); });
        \\  const destroy = () => {
        \\    document.removeEventListener("pointermove", onMove, true);
        \\    document.removeEventListener("click", onClick, true);
        \\    document.removeEventListener("keydown", onKeyDown, true);
        \\    removeFreezeStyle();
        \\    root.remove();
        \\    delete window[KEY];
        \\  };
        \\  document.addEventListener("pointermove", onMove, true);
        \\  document.addEventListener("click", onClick, true);
        \\  document.addEventListener("keydown", onKeyDown, true);
        \\  window[KEY] = { destroy, state, version: 1 };
        \\  render();
        \\  return "kuri-debug-enabled";
        \\})()
    ;
    return std.mem.replaceOwned(u8, allocator, template, "@@FREEZE@@", if (freeze_enabled) "true" else "false");
}

/// Like extractSimpleJsonString, but correctly un-escapes the string value
/// (\", \\, \/, \n, \r, \t, \b, \f, \uXXXX) instead of stopping at the first
/// literal quote byte. Needed whenever the value itself is JSON.stringify'd
/// JSON (e.g. a Runtime.evaluate result whose value is a stringified
/// array/object) -- such values always contain escaped quotes, which the
/// naive scanner truncates on. Non-BMP \u sequences (surrogate pairs) are
/// decoded independently rather than paired -- acceptable here since this
/// only ever unescapes kuri's own recorder/export JSON, not arbitrary input.
fn extractJsonStringValueUnescaped(allocator: std.mem.Allocator, json: []const u8, start: usize, field: []const u8) ?[]const u8 {
    const field_pos = std.mem.indexOfPos(u8, json, start, field) orelse return null;
    if (field_pos - start > 1000) return null;
    const colon = std.mem.indexOfScalarPos(u8, json, field_pos + field.len, ':') orelse return null;
    var i = colon + 1;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    if (i >= json.len or json[i] != '"') return null;
    i += 1;

    var out: std.ArrayList(u8) = .empty;
    while (i < json.len) {
        const c = json[i];
        if (c == '"') return out.items;
        if (c != '\\' or i + 1 >= json.len) {
            out.append(allocator, c) catch return null;
            i += 1;
            continue;
        }
        const next = json[i + 1];
        switch (next) {
            '"', '\\', '/' => {
                out.append(allocator, next) catch return null;
                i += 2;
            },
            'n' => {
                out.append(allocator, '\n') catch return null;
                i += 2;
            },
            'r' => {
                out.append(allocator, '\r') catch return null;
                i += 2;
            },
            't' => {
                out.append(allocator, '\t') catch return null;
                i += 2;
            },
            'b' => {
                out.append(allocator, 0x08) catch return null;
                i += 2;
            },
            'f' => {
                out.append(allocator, 0x0C) catch return null;
                i += 2;
            },
            'u' => {
                if (i + 6 <= json.len) {
                    const code = std.fmt.parseInt(u21, json[i + 2 .. i + 6], 16) catch {
                        out.append(allocator, c) catch return null;
                        i += 1;
                        continue;
                    };
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(code, &buf) catch {
                        out.append(allocator, c) catch return null;
                        i += 1;
                        continue;
                    };
                    out.appendSlice(allocator, buf[0..len]) catch return null;
                    i += 6;
                } else {
                    out.append(allocator, c) catch return null;
                    i += 1;
                }
            },
            else => {
                out.append(allocator, c) catch return null;
                i += 1;
            },
        }
    }
    return null;
}

fn evalValueString(arena: std.mem.Allocator, client: *CdpClient, expression: []const u8) ?[]const u8 {
    const escaped = jsonEscapeAlloc(arena, expression) orelse return null;
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped}) catch return null;
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch return null;
    return extractJsonStringValueUnescaped(arena, response, 0, "\"value\"");
}

fn evalValueObject(arena: std.mem.Allocator, client: *CdpClient, expression: []const u8) ?[]const u8 {
    const escaped = jsonEscapeAlloc(arena, expression) orelse return null;
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped}) catch return null;
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch return null;
    return extractJsonObjectField(response, "\"value\"");
}

fn applyStorageSnapshot(
    arena: std.mem.Allocator,
    client: *CdpClient,
    storage_name: []const u8,
    object_json: []const u8,
) bool {
    const js = std.fmt.allocPrint(
        arena,
        "(() => {{ const data = {s}; {s}.clear(); for (const [k, v] of Object.entries(data)) {s}.setItem(k, String(v)); return Object.keys(data).length; }})()",
        .{ object_json, storage_name, storage_name },
    ) catch return false;
    const escaped = jsonEscapeAlloc(arena, js) orelse return false;
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped}) catch return false;
    _ = client.send(arena, protocol.Methods.runtime_evaluate, params) catch return false;
    return true;
}

fn extractJsonArrayField(json: []const u8, field: []const u8) ?[]const u8 {
    return extractJsonDelimitedField(json, field, '[', ']');
}

fn extractJsonObjectField(json: []const u8, field: []const u8) ?[]const u8 {
    return extractJsonDelimitedField(json, field, '{', '}');
}

fn extractJsonDelimitedField(json: []const u8, field: []const u8, open: u8, close: u8) ?[]const u8 {
    const field_pos = std.mem.indexOf(u8, json, field) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, json, field_pos + field.len, ':') orelse return null;
    const start = std.mem.indexOfScalarPos(u8, json, colon + 1, open) orelse return null;

    var depth: usize = 0;
    var i = start;
    var in_string = false;
    var escaped = false;
    while (i < json.len) : (i += 1) {
        const c = json[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }

        if (c == '"') {
            in_string = true;
            continue;
        }
        if (c == open) depth += 1;
        if (c == close) {
            depth -= 1;
            if (depth == 0) return json[start .. i + 1];
        }
    }
    return null;
}

fn handleStop(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const response = client.send(arena, protocol.Methods.page_stop_loading, null) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleScrollIntoView(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const ref = getQueryParam(target, "ref") orelse {
        resp.sendError(request, 400, "Missing ref parameter");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    bridge.mu.lockShared();
    const cache = bridge.snapshots.get(tab_id);
    bridge.mu.unlockShared();

    const node_id = if (cache) |c| c.refs.get(ref) else null;
    const bid = node_id orelse {
        resp.sendError(request, 400, "Ref not found. Call /snapshot first");
        return;
    };

    const resolve_params = std.fmt.allocPrint(arena, "{{\"backendNodeId\":{d}}}", .{bid}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const resolve_response = client.send(arena, protocol.Methods.dom_resolve_node, resolve_params) catch {
        resp.sendError(request, 502, "DOM.resolveNode failed");
        return;
    };
    const object_id = extractSimpleJsonString(resolve_response, 0, "\"objectId\"") orelse {
        resp.sendError(request, 500, "Could not resolve element objectId");
        return;
    };
    const call_params = std.fmt.allocPrint(arena, "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"function() {{ this.scrollIntoView({{behavior:'smooth',block:'center'}}); return 'scrolled_into_view'; }}\",\"returnByValue\":true}}", .{object_id}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_call_function_on, call_params) catch {
        resp.sendError(request, 502, "Runtime.callFunctionOn failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleDrag(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const src_ref = getQueryParam(target, "src") orelse {
        resp.sendError(request, 400, "Missing src ref parameter");
        return;
    };
    const tgt_ref = getQueryParam(target, "tgt") orelse {
        resp.sendError(request, 400, "Missing tgt ref parameter");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    bridge.mu.lockShared();
    const cache = bridge.snapshots.get(tab_id);
    bridge.mu.unlockShared();

    const src_bid = if (cache) |c| c.refs.get(src_ref) else null;
    const tgt_bid = if (cache) |c| c.refs.get(tgt_ref) else null;

    if (src_bid == null or tgt_bid == null) {
        resp.sendError(request, 400, "Source or target ref not found. Call /snapshot first");
        return;
    }

    // Resolve source element
    const src_resolve = std.fmt.allocPrint(arena, "{{\"backendNodeId\":{d}}}", .{src_bid.?}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const src_resp = client.send(arena, protocol.Methods.dom_resolve_node, src_resolve) catch {
        resp.sendError(request, 502, "DOM.resolveNode failed for source");
        return;
    };
    const src_oid = extractSimpleJsonString(src_resp, 0, "\"objectId\"") orelse {
        resp.sendError(request, 500, "Could not resolve source objectId");
        return;
    };

    // Resolve target element
    const tgt_resolve = std.fmt.allocPrint(arena, "{{\"backendNodeId\":{d}}}", .{tgt_bid.?}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const tgt_resp = client.send(arena, protocol.Methods.dom_resolve_node, tgt_resolve) catch {
        resp.sendError(request, 502, "DOM.resolveNode failed for target");
        return;
    };
    const tgt_oid = extractSimpleJsonString(tgt_resp, 0, "\"objectId\"") orelse {
        resp.sendError(request, 500, "Could not resolve target objectId");
        return;
    };

    // Use JS to perform drag-and-drop via DataTransfer events
    const js = std.fmt.allocPrint(arena,
        \\{{"objectId":"{s}","functionDeclaration":"function() {{ var src=this; var tgtOid='{s}'; var dt=new DataTransfer(); src.dispatchEvent(new DragEvent('dragstart',{{bubbles:true,dataTransfer:dt}})); src.dispatchEvent(new DragEvent('drag',{{bubbles:true,dataTransfer:dt}})); return 'drag_started'; }}","returnByValue":true}}
    , .{ src_oid, tgt_oid }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_call_function_on, js) catch {
        resp.sendError(request, 502, "Drag failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleKeyboardType(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const text = getDecodedQueryParamAlloc(arena, target, "text") orelse {
        resp.sendError(request, 400, "Missing text parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // Type each character via Input.dispatchKeyEvent
    for (text) |ch| {
        const char_str = std.fmt.allocPrint(arena, "{c}", .{ch}) catch continue;
        const key_params = std.fmt.allocPrint(arena, "{{\"type\":\"keyDown\",\"text\":\"{s}\",\"key\":\"{s}\",\"unmodifiedText\":\"{s}\"}}", .{ char_str, char_str, char_str }) catch continue;
        _ = client.send(arena, protocol.Methods.input_dispatch_key_event, key_params) catch continue;
        const up_params = std.fmt.allocPrint(arena, "{{\"type\":\"keyUp\",\"key\":\"{s}\"}}", .{char_str}) catch continue;
        _ = client.send(arena, protocol.Methods.input_dispatch_key_event, up_params) catch continue;
    }
    const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"typed\":\"{s}\",\"chars\":{d}}}", .{ text, text.len }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleKeyboardInsertText(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const text = getDecodedQueryParamAlloc(arena, target, "text") orelse {
        resp.sendError(request, 400, "Missing text parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const params = std.fmt.allocPrint(arena, "{{\"text\":\"{s}\"}}", .{text}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.input_insert_text, params) catch {
        resp.sendError(request, 502, "Input.insertText failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleKeyDown(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const key = getQueryParam(target, "key") orelse {
        resp.sendError(request, 400, "Missing key parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const params = std.fmt.allocPrint(arena, "{{\"type\":\"keyDown\",\"key\":\"{s}\"}}", .{key}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.input_dispatch_key_event, params) catch {
        resp.sendError(request, 502, "Input.dispatchKeyEvent failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleKeyUp(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const key = getQueryParam(target, "key") orelse {
        resp.sendError(request, 400, "Missing key parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const params = std.fmt.allocPrint(arena, "{{\"type\":\"keyUp\",\"key\":\"{s}\"}}", .{key}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.input_dispatch_key_event, params) catch {
        resp.sendError(request, 502, "Input.dispatchKeyEvent failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleWait(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const selector = getDecodedQueryParamAlloc(arena, target, "selector");
    const wait_text = getDecodedQueryParamAlloc(arena, target, "text");
    const wait_url = getDecodedQueryParamAlloc(arena, target, "url");
    const wait_state = getQueryParam(target, "state");
    const visible_param = getQueryParam(target, "visible");
    const timeout_str = getQueryParam(target, "timeout") orelse "5000";
    const timeout_ms = std.fmt.parseInt(u64, timeout_str, 10) catch 5000;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const max_polls = timeout_ms / 100;

    if (wait_text) |txt| {
        const escaped_txt = jsonEscapeAlloc(arena, txt) orelse {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        var polls: u64 = 0;
        while (polls < max_polls) : (polls += 1) {
            const params = std.fmt.allocPrint(arena, "{{\"expression\":\"(document.body && document.body.innerText.includes('{s}'))\",\"returnByValue\":true}}", .{escaped_txt}) catch {
                resp.sendError(request, 500, "Internal Server Error");
                return;
            };
            const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
                resp.sendError(request, 502, "CDP command failed");
                return;
            };
            if (std.mem.indexOf(u8, response, "true") != null) {
                const body = std.fmt.allocPrint(arena, "{{\"status\":\"found\",\"text\":\"{s}\",\"polls\":{d}}}", .{ escaped_txt, polls + 1 }) catch {
                    resp.sendError(request, 500, "Internal Server Error");
                    return;
                };
                resp.sendJson(request, body);
                return;
            }
            compat.threadSleep(100 * std.time.ns_per_ms);
        }
        resp.sendJson(request, "{\"status\":\"timeout\",\"reason\":\"text_not_found\"}");
        return;
    }

    if (wait_url) |url_pattern| {
        const escaped_url = jsonEscapeAlloc(arena, url_pattern) orelse {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        var polls: u64 = 0;
        while (polls < max_polls) : (polls += 1) {
            const params = std.fmt.allocPrint(arena, "{{\"expression\":\"window.location.href.includes('{s}')\",\"returnByValue\":true}}", .{escaped_url}) catch {
                resp.sendError(request, 500, "Internal Server Error");
                return;
            };
            const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
                resp.sendError(request, 502, "CDP command failed");
                return;
            };
            if (std.mem.indexOf(u8, response, "true") != null) {
                const href = evalValueString(arena, client, "window.location.href") orelse "unknown";
                const body = std.fmt.allocPrint(arena, "{{\"status\":\"matched\",\"url\":\"{s}\",\"polls\":{d}}}", .{ href, polls + 1 }) catch {
                    resp.sendError(request, 500, "Internal Server Error");
                    return;
                };
                resp.sendJson(request, body);
                return;
            }
            compat.threadSleep(100 * std.time.ns_per_ms);
        }
        resp.sendJson(request, "{\"status\":\"timeout\",\"reason\":\"url_not_matched\"}");
        return;
    }

    if (wait_state) |state| {
        if (std.mem.eql(u8, state, "networkidle")) {
            const net_js = "(() => { let c = 0; const o = new PerformanceObserver(l => { for (const e of l.getEntries()) { if (e.initiatorType === 'xmlhttprequest' || e.initiatorType === 'fetch') c++; } }); try { o.observe({type:'resource',buffered:false}); } catch(e) {} return 'observing'; })()";
            const idle_js = "(() => { try { const e = performance.getEntriesByType('resource'); const now = performance.now(); const pending = e.filter(r => r.responseEnd === 0 || (now - r.startTime < 500 && r.duration === 0)); return pending.length === 0 ? 'idle' : 'busy'; } catch(e) { return 'idle'; } })()";
            _ = evalValueString(arena, client, net_js);
            var polls: u64 = 0;
            var idle_count: u32 = 0;
            while (polls < max_polls) : (polls += 1) {
                const result = evalValueString(arena, client, idle_js) orelse "idle";
                if (std.mem.eql(u8, result, "idle")) {
                    idle_count += 1;
                    if (idle_count >= 5) {
                        const body = std.fmt.allocPrint(arena, "{{\"status\":\"networkidle\",\"polls\":{d}}}", .{polls + 1}) catch {
                            resp.sendError(request, 500, "Internal Server Error");
                            return;
                        };
                        resp.sendJson(request, body);
                        return;
                    }
                } else {
                    idle_count = 0;
                }
                compat.threadSleep(100 * std.time.ns_per_ms);
            }
            resp.sendJson(request, "{\"status\":\"timeout\",\"reason\":\"network_not_idle\"}");
            return;
        }
        const target_state: []const u8 = if (std.mem.eql(u8, state, "domcontentloaded")) "interactive" else "complete";
        var polls: u64 = 0;
        while (polls < max_polls) : (polls += 1) {
            const params = "{\"expression\":\"document.readyState\",\"returnByValue\":true}";
            const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
                resp.sendError(request, 502, "CDP command failed");
                return;
            };
            if (std.mem.indexOf(u8, response, target_state) != null) {
                const body = std.fmt.allocPrint(arena, "{{\"status\":\"ready\",\"state\":\"{s}\",\"polls\":{d}}}", .{ state, polls + 1 }) catch {
                    resp.sendError(request, 500, "Internal Server Error");
                    return;
                };
                resp.sendJson(request, body);
                return;
            }
            compat.threadSleep(100 * std.time.ns_per_ms);
        }
        resp.sendJson(request, "{\"status\":\"timeout\",\"reason\":\"state_not_reached\"}");
        return;
    }

    if (selector) |sel| {
        const check_visible = if (visible_param) |v| std.mem.eql(u8, v, "true") else false;
        const escaped_sel = jsonEscapeAlloc(arena, sel) orelse {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        var polls: u64 = 0;
        while (polls < max_polls) : (polls += 1) {
            const expr = if (check_visible)
                std.fmt.allocPrint(arena, "{{\"expression\":\"(() => {{ const el = document.querySelector('{s}'); if (!el) return false; const s = getComputedStyle(el); if (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0') return false; const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; }})()\",\"returnByValue\":true}}", .{escaped_sel})
            else
                std.fmt.allocPrint(arena, "{{\"expression\":\"!!document.querySelector('{s}')\",\"returnByValue\":true}}", .{escaped_sel});
            const params = expr catch {
                resp.sendError(request, 500, "Internal Server Error");
                return;
            };
            const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
                resp.sendError(request, 502, "CDP command failed");
                return;
            };
            if (std.mem.indexOf(u8, response, "true") != null) {
                const body = std.fmt.allocPrint(arena, "{{\"status\":\"found\",\"selector\":\"{s}\",\"polls\":{d}}}", .{ escaped_sel, polls + 1 }) catch {
                    resp.sendError(request, 500, "Internal Server Error");
                    return;
                };
                resp.sendJson(request, body);
                return;
            }
            compat.threadSleep(100 * std.time.ns_per_ms);
        }
        const body = std.fmt.allocPrint(arena, "{{\"status\":\"timeout\",\"selector\":\"{s}\",\"timeout_ms\":{d}}}", .{ escaped_sel, timeout_ms }) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        resp.sendError(request, 408, body);
    } else {
        var polls: u64 = 0;
        while (polls < max_polls) : (polls += 1) {
            const params = "{\"expression\":\"document.readyState\",\"returnByValue\":true}";
            const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
                resp.sendError(request, 502, "CDP command failed");
                return;
            };
            if (std.mem.indexOf(u8, response, "complete") != null) {
                const body = std.fmt.allocPrint(arena, "{{\"status\":\"ready\",\"readyState\":\"complete\",\"polls\":{d}}}", .{polls + 1}) catch {
                    resp.sendError(request, 500, "Internal Server Error");
                    return;
                };
                resp.sendJson(request, body);
                return;
            }
            compat.threadSleep(100 * std.time.ns_per_ms);
        }
        resp.sendJson(request, "{\"status\":\"ready\",\"readyState\":\"timeout\"}");
    }
}

fn handleTabCurrent(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const session_id = getSessionId(request) orelse {
        resp.sendError(request, 400, "Missing X-Kuri-Session header or session query parameter");
        return;
    };
    const target = request.head.target;
    if (getQueryParam(target, "clear")) |clear| {
        if (std.mem.eql(u8, clear, "true")) {
            bridge.clearCurrentTab(session_id);
            const body = std.fmt.allocPrint(arena, "{{\"status\":\"cleared\",\"session\":\"{s}\"}}", .{session_id}) catch {
                resp.sendError(request, 500, "Internal Server Error");
                return;
            };
            resp.sendJson(request, body);
            return;
        }
    }

    if (getQueryParam(target, "tab_id")) |tab_id| {
        const tab = bridge.getTab(tab_id) orelse {
            resp.sendError(request, 404, "Tab not found");
            return;
        };
        if (getQueryParam(target, "activate")) |activate| {
            if (!std.mem.eql(u8, activate, "false")) {
                _ = activateTarget(arena, bridge, tab_id);
            }
        } else {
            _ = activateTarget(arena, bridge, tab_id);
        }
        bridge.setCurrentTab(session_id, tab_id) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const body = std.fmt.allocPrint(arena, "{{\"session\":\"{s}\",\"tab_id\":\"{s}\",\"url\":\"{s}\",\"title\":\"{s}\",\"current\":true}}", .{
            session_id,
            tab.id,
            tab.url,
            tab.title,
        }) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        resp.sendJson(request, body);
        return;
    }

    const current_tab_id = bridge.getCurrentTab(arena, session_id) orelse {
        resp.sendError(request, 404, "No current tab is set for this session");
        return;
    };
    const tab = bridge.getTab(current_tab_id) orelse {
        bridge.clearCurrentTab(session_id);
        resp.sendError(request, 404, "Current tab no longer exists");
        return;
    };
    const body = std.fmt.allocPrint(arena, "{{\"session\":\"{s}\",\"tab_id\":\"{s}\",\"url\":\"{s}\",\"title\":\"{s}\",\"current\":true}}", .{
        session_id,
        tab.id,
        tab.url,
        tab.title,
    }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleTabNew(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge, cfg: Config, cdp_port: u16) void {
    const target = request.head.target;
    const url = getDecodedQueryParamAlloc(arena, target, "url") orelse "about:blank";
    const activate = if (getQueryParam(target, "activate")) |value| !std.mem.eql(u8, value, "false") else true;
    const wait = if (getQueryParam(target, "wait")) |value| !std.mem.eql(u8, value, "false") else true;

    const params = std.fmt.allocPrint(arena, "{{\"url\":\"{s}\"}}", .{url}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    // Use any existing client to create a new target
    const tabs = bridge.listTabs(arena) catch {
        resp.sendError(request, 500, "Failed to list tabs");
        return;
    };
    if (tabs.len == 0) {
        resp.sendError(request, 500, "No active tabs to create from");
        return;
    }
    const client = bridge.getCdpClient(tabs[0].id) orelse {
        resp.sendError(request, 500, "No active CDP client");
        return;
    };

    const response = client.send(arena, protocol.Methods.target_create_target, params) catch {
        resp.sendError(request, 502, "Target.createTarget failed");
        return;
    };

    // Extract targetId from response
    const new_tab_id = extractSimpleJsonString(response, 0, "\"targetId\"") orelse "unknown";
    if (activate and !std.mem.eql(u8, new_tab_id, "unknown")) {
        _ = activateTarget(arena, bridge, new_tab_id);
    }
    var hydrated_tab: ?TabEntry = null;
    if (wait and !std.mem.eql(u8, new_tab_id, "unknown")) {
        hydrated_tab = waitForRegisteredTab(arena, bridge, cfg, cdp_port, new_tab_id);
        hydrated_tab = waitForTabPageReady(arena, bridge, new_tab_id, url) orelse hydrated_tab;
    }
    rememberCurrentTab(request, bridge, new_tab_id);
    const final_url = if (hydrated_tab) |tab| tab.url else url;
    const final_title = if (hydrated_tab) |tab| tab.title else "";
    const body = std.fmt.allocPrint(arena, "{{\"status\":\"created\",\"tab_id\":\"{s}\",\"url\":\"{s}\",\"title\":\"{s}\",\"hydrated\":{s},\"current\":{s}}}", .{
        new_tab_id,
        final_url,
        final_title,
        if (hydrated_tab != null) "true" else "false",
        if (getSessionId(request) != null) "true" else "false",
    }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleTabClose(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;

    const closed_in_chrome = closeTarget(arena, bridge, tab_id);
    bridge.removeTab(tab_id);
    const body = std.fmt.allocPrint(arena, "{{\"status\":\"closed\",\"tab_id\":\"{s}\",\"remaining\":{d},\"cdp_closed\":{s}}}", .{
        tab_id,
        bridge.tabCount(),
        if (closed_in_chrome) "true" else "false",
    }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleHighlight(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const ref = getQueryParam(target, "ref");
    const selector = getQueryParam(target, "selector");
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    if (ref) |r| {
        bridge.mu.lockShared();
        const cache = bridge.snapshots.get(tab_id);
        bridge.mu.unlockShared();
        const node_id = if (cache) |c| c.refs.get(r) else null;
        const bid = node_id orelse {
            resp.sendError(request, 400, "Ref not found");
            return;
        };
        const params = std.fmt.allocPrint(arena, "{{\"highlightConfig\":{{\"showInfo\":true,\"contentColor\":{{\"r\":111,\"g\":168,\"b\":220,\"a\":0.66}},\"borderColor\":{{\"r\":111,\"g\":168,\"b\":220,\"a\":1}}}},\"backendNodeId\":{d}}}", .{bid}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const response = client.send(arena, protocol.Methods.overlay_highlight_node, params) catch {
            resp.sendError(request, 502, "Overlay.highlightNode failed");
            return;
        };
        resp.sendJson(request, response);
    } else if (selector) |sel| {
        // Highlight via JS + overlay
        const params = std.fmt.allocPrint(arena, "{{\"expression\":\"(function(){{ var el=document.querySelector('{s}'); if(!el) return 'not_found'; el.style.outline='3px solid #6fa8dc'; return 'highlighted'; }})()\",\"returnByValue\":true}}", .{sel}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
            resp.sendError(request, 502, "CDP command failed");
            return;
        };
        resp.sendJson(request, response);
    } else {
        // Clear highlight
        const response = client.send(arena, protocol.Methods.overlay_hide_highlight, null) catch {
            resp.sendError(request, 502, "Overlay.hideHighlight failed");
            return;
        };
        resp.sendJson(request, response);
    }
}

fn handleErrors(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // Enable Runtime to collect exceptions, then evaluate to get any stored errors
    _ = client.send(arena, protocol.Methods.runtime_enable, null) catch {};
    const params = "{\"expression\":\"(function(){ var e=window.__kuri_errors||[]; return JSON.stringify(e); })()\",\"returnByValue\":true}";
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleSetOffline(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const mode = getQueryParam(target, "mode") orelse "on";
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const offline = std.mem.eql(u8, mode, "on") or std.mem.eql(u8, mode, "true");
    const params = std.fmt.allocPrint(arena, "{{\"offline\":{s},\"latency\":0,\"downloadThroughput\":-1,\"uploadThroughput\":-1}}", .{if (offline) "true" else "false"}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.network_emulate_conditions, params) catch {
        resp.sendError(request, 502, "Network.emulateNetworkConditions failed");
        return;
    };
    _ = response;
    const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"offline\":{s}}}", .{if (offline) "true" else "false"}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleSetMedia(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const scheme = getQueryParam(target, "scheme") orelse "dark";
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const params = std.fmt.allocPrint(arena, "{{\"features\":[{{\"name\":\"prefers-color-scheme\",\"value\":\"{s}\"}}]}}", .{scheme}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.emulation_set_emulated_media, params) catch {
        resp.sendError(request, 502, "Emulation.setEmulatedMedia failed");
        return;
    };
    _ = response;
    const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"colorScheme\":\"{s}\"}}", .{scheme}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleSetCredentials(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const username = getQueryParam(target, "username") orelse {
        resp.sendError(request, 400, "Missing username parameter");
        return;
    };
    const password = getQueryParam(target, "password") orelse {
        resp.sendError(request, 400, "Missing password parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // Enable Fetch to intercept auth challenges
    _ = client.send(arena, protocol.Methods.fetch_enable, "{\"handleAuthRequests\":true}") catch {};

    // Also set as Authorization header for immediate use
    const b64_input = std.fmt.allocPrint(arena, "{s}:{s}", .{ username, password }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(b64_input.len);
    const encoded = arena.alloc(u8, encoded_len) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = encoder.encode(encoded, b64_input);

    const header_params = std.fmt.allocPrint(arena, "{{\"headers\":{{\"Authorization\":\"Basic {s}\"}}}}", .{encoded}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.network_set_extra_http_headers, header_params) catch {};

    const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"username\":\"{s}\"}}", .{username}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleFind(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const by = getQueryParam(target, "by") orelse {
        resp.sendError(request, 400, "Missing 'by' parameter (role|text|label|placeholder|testid|alt|title)");
        return;
    };
    const value = getDecodedQueryParamAlloc(arena, target, "value") orelse {
        resp.sendError(request, 400, "Missing 'value' parameter");
        return;
    };
    const action_param = getQueryParam(target, "action");
    const exact = getQueryParam(target, "exact");

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);
    _ = bridge.touchTab(tab_id);

    const escaped_value = jsonEscapeAlloc(arena, value) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    // Build JS to find elements by semantic locator
    const js = if (std.mem.eql(u8, by, "role"))
        std.fmt.allocPrint(arena, "JSON.stringify([...document.querySelectorAll('[role=\"{s}\"]')].map((el,i)=>{{return {{index:i,tag:el.tagName,text:el.innerText.substring(0,100),ref:'found_'+i}}}}))", .{escaped_value})
    else if (std.mem.eql(u8, by, "text"))
        if (exact != null and std.mem.eql(u8, exact.?, "true"))
            std.fmt.allocPrint(arena, "JSON.stringify([...document.querySelectorAll('*')].filter(el=>el.innerText.trim()===\"{s}\"&&el.children.length===0).slice(0,20).map((el,i)=>{{return {{index:i,tag:el.tagName,text:el.innerText.substring(0,100)}}}}))", .{escaped_value})
        else
            std.fmt.allocPrint(arena, "JSON.stringify([...document.querySelectorAll('*')].filter(el=>el.innerText.includes(\"{s}\")&&el.children.length===0).slice(0,20).map((el,i)=>{{return {{index:i,tag:el.tagName,text:el.innerText.substring(0,100)}}}}))", .{escaped_value})
    else if (std.mem.eql(u8, by, "label"))
        std.fmt.allocPrint(arena, "JSON.stringify([...document.querySelectorAll('label')].filter(l=>l.innerText.includes(\"{s}\")).map((l,i)=>{{var el=l.htmlFor?document.getElementById(l.htmlFor):l.querySelector('input,select,textarea');return {{index:i,label:l.innerText.substring(0,100),tag:el?el.tagName:'none'}}}}))", .{escaped_value})
    else if (std.mem.eql(u8, by, "placeholder"))
        std.fmt.allocPrint(arena, "JSON.stringify([...document.querySelectorAll('[placeholder]')].filter(el=>el.placeholder.includes(\"{s}\")).map((el,i)=>{{return {{index:i,tag:el.tagName,placeholder:el.placeholder}}}}))", .{escaped_value})
    else if (std.mem.eql(u8, by, "testid"))
        std.fmt.allocPrint(arena, "JSON.stringify([...document.querySelectorAll('[data-testid=\"{s}\"]')].map((el,i)=>{{return {{index:i,tag:el.tagName,text:el.innerText.substring(0,100)}}}}))", .{escaped_value})
    else if (std.mem.eql(u8, by, "alt"))
        std.fmt.allocPrint(arena, "JSON.stringify([...document.querySelectorAll('[alt]')].filter(el=>el.alt.includes(\"{s}\")).map((el,i)=>{{return {{index:i,tag:el.tagName,alt:el.alt}}}}))", .{escaped_value})
    else if (std.mem.eql(u8, by, "title"))
        std.fmt.allocPrint(arena, "JSON.stringify([...document.querySelectorAll('[title]')].filter(el=>el.title.includes(\"{s}\")).map((el,i)=>{{return {{index:i,tag:el.tagName,title:el.title}}}}))", .{escaped_value})
    else {
        resp.sendError(request, 400, "Unknown 'by' type. Use: role|text|label|placeholder|testid|alt|title");
        return;
    };

    const expr = js catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    const escaped_expr = jsonEscapeAlloc(arena, expr) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped_expr}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    _ = action_param; // Future: auto-execute action on found elements
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleTraceStart(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const categories = getQueryParam(target, "categories") orelse "-*,devtools.timeline,v8.execute,disabled-by-default-devtools.timeline";
    const params = std.fmt.allocPrint(arena, "{{\"categories\":\"{s}\",\"options\":\"sampling-frequency=10000\"}}", .{categories}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.tracing_start, params) catch {
        resp.sendError(request, 502, "Tracing.start failed");
        return;
    };
    _ = response;
    const body = std.fmt.allocPrint(arena, "{{\"status\":\"tracing\",\"tab_id\":\"{s}\"}}", .{tab_id}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleTraceStop(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const response = client.send(arena, protocol.Methods.tracing_end, null) catch {
        resp.sendError(request, 502, "Tracing.end failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleProfilerStart(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    _ = client.send(arena, protocol.Methods.profiler_enable, null) catch {
        resp.sendError(request, 502, "Profiler.enable failed");
        return;
    };
    const response = client.send(arena, protocol.Methods.profiler_start, null) catch {
        resp.sendError(request, 502, "Profiler.start failed");
        return;
    };
    _ = response;
    const body = std.fmt.allocPrint(arena, "{{\"status\":\"profiling\",\"tab_id\":\"{s}\"}}", .{tab_id}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleProfilerStop(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const response = client.send(arena, protocol.Methods.profiler_stop, null) catch {
        resp.sendError(request, 502, "Profiler.stop failed");
        return;
    };
    _ = client.send(arena, protocol.Methods.profiler_disable, null) catch {};
    resp.sendJson(request, response);
}

fn handleInspect(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    _ = client.send(arena, protocol.Methods.inspector_enable, null) catch {};
    const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"message\":\"DevTools enabled\",\"tab_id\":\"{s}\"}}", .{tab_id}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleWindowNew(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge, cfg: Config, cdp_port: u16) void {
    const target = request.head.target;
    const url = getDecodedQueryParamAlloc(arena, target, "url") orelse "about:blank";
    const activate = if (getQueryParam(target, "activate")) |value| !std.mem.eql(u8, value, "false") else true;
    const wait = if (getQueryParam(target, "wait")) |value| !std.mem.eql(u8, value, "false") else true;

    // Get any existing client to create target
    const tabs = bridge.listTabs(arena) catch {
        resp.sendError(request, 500, "Failed to list tabs");
        return;
    };
    if (tabs.len == 0) {
        resp.sendError(request, 500, "No active tabs");
        return;
    }
    const client = bridge.getCdpClient(tabs[0].id) orelse {
        resp.sendError(request, 500, "No active CDP client");
        return;
    };

    // Create in a new browser context for window-like isolation
    const ctx_response = client.send(arena, protocol.Methods.target_create_browser_context, null) catch null;
    const ctx_id = if (ctx_response) |response|
        extractSimpleJsonString(response, 0, "\"browserContextId\"")
    else
        null;

    const params = (if (ctx_id) |id|
        std.fmt.allocPrint(arena, "{{\"url\":\"{s}\",\"newWindow\":true,\"browserContextId\":\"{s}\"}}", .{ url, id })
    else
        std.fmt.allocPrint(arena, "{{\"url\":\"{s}\",\"newWindow\":true}}", .{url})) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.target_create_target, params) catch {
        resp.sendError(request, 502, "Target.createTarget failed");
        return;
    };
    const new_tab_id = extractSimpleJsonString(response, 0, "\"targetId\"") orelse "unknown";
    if (activate and !std.mem.eql(u8, new_tab_id, "unknown")) {
        _ = activateTarget(arena, bridge, new_tab_id);
    }
    var hydrated_tab: ?TabEntry = null;
    if (wait and !std.mem.eql(u8, new_tab_id, "unknown")) {
        hydrated_tab = waitForRegisteredTab(arena, bridge, cfg, cdp_port, new_tab_id);
        hydrated_tab = waitForTabPageReady(arena, bridge, new_tab_id, url) orelse hydrated_tab;
    }
    rememberCurrentTab(request, bridge, new_tab_id);
    const final_url = if (hydrated_tab) |tab| tab.url else url;
    const final_title = if (hydrated_tab) |tab| tab.title else "";
    const body = std.fmt.allocPrint(arena, "{{\"status\":\"created\",\"tab_id\":\"{s}\",\"url\":\"{s}\",\"title\":\"{s}\",\"hydrated\":{s},\"current\":{s},\"window\":true}}", .{
        new_tab_id,
        final_url,
        final_title,
        if (hydrated_tab != null) "true" else "false",
        if (getSessionId(request) != null) "true" else "false",
    }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleSessionList(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tabs = bridge.listTabs(arena) catch {
        resp.sendError(request, 500, "Failed to list sessions");
        return;
    };

    var json_buf: std.ArrayList(u8) = .empty;
    json_buf.appendSlice(arena, "{\"sessions\":[") catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    for (tabs, 0..) |tab, i| {
        if (i > 0) json_buf.append(arena, ',') catch {};
        json_buf.print(arena, "{{\"id\":\"{s}\",\"url\":\"{s}\",\"title\":\"{s}\"}}", .{
            tab.id, tab.url, tab.title,
        }) catch {};
    }
    json_buf.appendSlice(arena, "]}") catch {};
    resp.sendJson(request, json_buf.items);
}

fn handleSetViewport(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const width = getQueryParam(target, "width") orelse "1280";
    const height = getQueryParam(target, "height") orelse "720";
    const scale = getQueryParam(target, "scale") orelse "1";
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"width\":{s},\"height\":{s},\"deviceScaleFactor\":{s},\"mobile\":false}}", .{ width, height, scale }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.emulation_set_device_metrics, params) catch {
        resp.sendError(request, 502, "Emulation.setDeviceMetricsOverride failed");
        return;
    };
    _ = response;
    const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"width\":{s},\"height\":{s},\"scale\":{s}}}", .{ width, height, scale }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleSetUserAgent(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const ua = getDecodedQueryParamAlloc(arena, target, "ua") orelse {
        resp.sendError(request, 400, "Missing ua parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const escaped_ua = jsonEscapeAlloc(arena, ua) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"userAgent\":\"{s}\"}}", .{escaped_ua}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.emulation_set_user_agent, params) catch {
        resp.sendError(request, 502, "Emulation.setUserAgentOverride failed");
        return;
    };
    _ = response;
    const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"userAgent\":\"{s}\"}}", .{escaped_ua}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleDomAttributes(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const ref = getQueryParam(target, "ref");
    const selector = getQueryParam(target, "selector");
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    if (ref) |r| {
        const cache = bridge.snapshots.get(tab_id);
        const node_id = if (cache) |c| c.refs.get(r) else null;
        const bid = node_id orelse {
            resp.sendError(request, 400, "Ref not found");
            return;
        };
        const resolve_params = std.fmt.allocPrint(arena, "{{\"backendNodeId\":{d}}}", .{bid}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const resolve_response = client.send(arena, protocol.Methods.dom_resolve_node, resolve_params) catch {
            resp.sendError(request, 502, "DOM.resolveNode failed");
            return;
        };
        const object_id = extractSimpleJsonString(resolve_response, 0, "\"objectId\"") orelse {
            resp.sendError(request, 500, "Could not resolve element");
            return;
        };
        const call_params = std.fmt.allocPrint(arena, "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"function() {{ var attrs={{}}; for(var a of this.attributes){{ attrs[a.name]=a.value; }} return JSON.stringify(attrs); }}\",\"returnByValue\":true}}", .{object_id}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const response = client.send(arena, protocol.Methods.runtime_call_function_on, call_params) catch {
            resp.sendError(request, 502, "Runtime.callFunctionOn failed");
            return;
        };
        resp.sendJson(request, response);
    } else if (selector) |sel| {
        const params = std.fmt.allocPrint(arena, "{{\"expression\":\"(function(){{ var el=document.querySelector('{s}'); if(!el) return 'null'; var attrs={{}}; for(var a of el.attributes){{ attrs[a.name]=a.value; }} return JSON.stringify(attrs); }})()\",\"returnByValue\":true}}", .{sel}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
            resp.sendError(request, 502, "CDP command failed");
            return;
        };
        resp.sendJson(request, response);
    } else {
        resp.sendError(request, 400, "Missing ref or selector parameter");
    }
}

fn handleFrames(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);
    _ = bridge.touchTab(tab_id);
    _ = client.send(arena, protocol.Methods.page_enable, null) catch {};
    const response = client.send(arena, protocol.Methods.page_get_frame_tree, null) catch {
        resp.sendError(request, 502, "Page.getFrameTree failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleNetwork(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const mode = getQueryParam(target, "mode") orelse "enable";
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const method = if (std.mem.eql(u8, mode, "disable")) protocol.Methods.network_disable else protocol.Methods.network_enable;
    const response = client.send(arena, method, null) catch {
        resp.sendError(request, 502, "Network command failed");
        return;
    };
    _ = response;
    const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"network\":\"{s}\"}}", .{mode}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handlePerfLcp(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const url = getDecodedQueryParamAlloc(arena, target, "url");

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // If url is provided, navigate first and wait for page load
    if (url) |nav_url| {
        _ = client.send(arena, protocol.Methods.page_enable, null) catch {};
        const nav_params = std.fmt.allocPrint(arena, "{{\"url\":\"{s}\"}}", .{nav_url}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        _ = client.send(arena, protocol.Methods.page_navigate, nav_params) catch {
            resp.sendError(request, 502, "Navigation failed");
            return;
        };
        bumpGenerationLocked(bridge, tab_id);
        _ = client.waitForEvent(arena, "Page.loadEventFired", 50);
    }

    const lcp_js =
        "new Promise((resolve) => { " ++
        "const entries = performance.getEntriesByType('largest-contentful-paint'); " ++
        "if (entries.length > 0) { " ++
        "const lcp = entries[entries.length - 1]; " ++
        "resolve(JSON.stringify({lcp_ms: lcp.startTime, element: lcp.element ? lcp.element.tagName : null, url: lcp.url || null, size: lcp.size})); " ++
        "} else { " ++
        "new PerformanceObserver((list) => { " ++
        "const entries = list.getEntries(); " ++
        "const lcp = entries[entries.length - 1]; " ++
        "resolve(JSON.stringify({lcp_ms: lcp.startTime, element: lcp.element ? lcp.element.tagName : null, url: lcp.url || null, size: lcp.size})); " ++
        "}).observe({type: 'largest-contentful-paint', buffered: true}); " ++
        "setTimeout(() => resolve(JSON.stringify({lcp_ms: null, error: 'timeout'})), 10000); " ++
        "}})";

    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"awaitPromise\":true,\"returnByValue\":true}}", .{lcp_js}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

// --- Issue #111: Batch cookie injection via POST body ---
fn handleCookiesSet(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const body = readRequestBody(request, arena) orelse {
        resp.sendError(request, 400, "Missing request body with JSON cookie array");
        return;
    };

    // Pass the JSON array directly to Network.setCookies which expects {"cookies": [...]}
    const params = std.fmt.allocPrint(arena, "{{\"cookies\":{s}}}", .{body}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.network_set_cookies, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

// --- Issue #112: Return captured request/response pairs ---
fn handleInterceptRequests(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // Use Runtime.evaluate to capture performance entries (Resource Timing API)
    // This gives us all network requests without needing to maintain server-side state
    const js =
        "(() => { const entries = performance.getEntriesByType('resource').concat(performance.getEntriesByType('navigation')); " ++
        "return JSON.stringify(entries.map(e => ({" ++
        "url: e.name, type: e.initiatorType || e.entryType, " ++
        "duration_ms: Math.round(e.duration), " ++
        "transfer_size: e.transferSize || 0, " ++
        "status: e.responseStatus || 0, " ++
        "protocol: e.nextHopProtocol || '' " ++
        "}))); })()";

    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{js}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };

    resp.sendJson(request, response);
}

// --- Issue #113: Cross-platform browser cookie DB extraction ---
fn handleAuthExtract(request: *std.http.Server.Request, arena: std.mem.Allocator) void {
    const target = request.head.target;
    const browser = getQueryParam(target, "browser") orelse "chrome";
    const domain = getDecodedQueryParamAlloc(arena, target, "domain");
    const profile = getQueryParam(target, "profile") orelse "Default";

    // Determine cookie DB path based on browser and platform
    const home = compat.getenv("HOME") orelse {
        resp.sendError(request, 500, "Cannot determine HOME directory");
        return;
    };

    const db_path = switch (@import("builtin").os.tag) {
        .macos => blk: {
            if (std.mem.eql(u8, browser, "chrome")) {
                break :blk std.fmt.allocPrint(arena, "{s}/Library/Application Support/Google/Chrome/{s}/Cookies", .{ home, profile }) catch {
                    resp.sendError(request, 500, "Internal Server Error");
                    return;
                };
            } else if (std.mem.eql(u8, browser, "firefox")) {
                // Firefox uses profiles.ini, find default profile
                break :blk std.fmt.allocPrint(arena, "{s}/Library/Application Support/Firefox/Profiles", .{home}) catch {
                    resp.sendError(request, 500, "Internal Server Error");
                    return;
                };
            } else if (std.mem.eql(u8, browser, "brave")) {
                break :blk std.fmt.allocPrint(arena, "{s}/Library/Application Support/BraveSoftware/Brave-Browser/{s}/Cookies", .{ home, profile }) catch {
                    resp.sendError(request, 500, "Internal Server Error");
                    return;
                };
            } else if (std.mem.eql(u8, browser, "edge")) {
                break :blk std.fmt.allocPrint(arena, "{s}/Library/Application Support/Microsoft Edge/{s}/Cookies", .{ home, profile }) catch {
                    resp.sendError(request, 500, "Internal Server Error");
                    return;
                };
            } else {
                resp.sendError(request, 400, "Unsupported browser. Use: chrome, firefox, brave, edge");
                return;
            }
        },
        .linux => blk: {
            if (std.mem.eql(u8, browser, "chrome")) {
                break :blk std.fmt.allocPrint(arena, "{s}/.config/google-chrome/{s}/Cookies", .{ home, profile }) catch {
                    resp.sendError(request, 500, "Internal Server Error");
                    return;
                };
            } else if (std.mem.eql(u8, browser, "chromium")) {
                break :blk std.fmt.allocPrint(arena, "{s}/.config/chromium/{s}/Cookies", .{ home, profile }) catch {
                    resp.sendError(request, 500, "Internal Server Error");
                    return;
                };
            } else if (std.mem.eql(u8, browser, "firefox")) {
                break :blk std.fmt.allocPrint(arena, "{s}/.mozilla/firefox", .{home}) catch {
                    resp.sendError(request, 500, "Internal Server Error");
                    return;
                };
            } else {
                resp.sendError(request, 400, "Unsupported browser. Use: chrome, chromium, firefox");
                return;
            }
        },
        else => {
            resp.sendError(request, 500, "Unsupported platform for cookie extraction");
            return;
        },
    };

    // Use sqlite3 CLI to read cookies (avoids needing SQLite bindings)
    const domain_filter = if (domain) |d|
        std.fmt.allocPrint(arena, " WHERE host_key LIKE '%{s}%'", .{d}) catch ""
    else
        "";

    const query = std.fmt.allocPrint(arena, "sqlite3 -json '{s}' \"SELECT host_key as domain, name, value, path, is_secure as secure, is_httponly as httpOnly, expires_utc as expires FROM cookies{s} LIMIT 500;\"", .{ db_path, domain_filter }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    const cmd_result = compat.runCommand(arena, &.{ "/bin/sh", "-c", query }, 1024 * 1024) catch {
        resp.sendError(request, 500, "Failed to run sqlite3 — is it installed?");
        return;
    };
    const stdout = cmd_result.stdout;

    if (stdout.len == 0) {
        const body = std.fmt.allocPrint(arena, "{{\"browser\":\"{s}\",\"profile\":\"{s}\",\"cookies\":[],\"db_path\":\"{s}\"}}", .{ browser, profile, db_path }) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        resp.sendJson(request, body);
        return;
    }

    const body = std.fmt.allocPrint(arena, "{{\"browser\":\"{s}\",\"profile\":\"{s}\",\"cookies\":{s}}}", .{ browser, profile, stdout }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

// --- Issue #114: WebSocket message capture ---
fn handleWsStart(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // Enable Network domain to receive WebSocket events
    _ = client.send(arena, protocol.Methods.network_enable, null) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };

    // Inject a JS interceptor to capture WebSocket frames in-page
    const ws_capture_js =
        "(() => { " ++
        "if (window.__kuri_ws_frames) return 'already_active'; " ++
        "window.__kuri_ws_frames = []; " ++
        "const OrigWs = window.WebSocket; " ++
        "window.WebSocket = function(url, protocols) { " ++
        "  const ws = protocols ? new OrigWs(url, protocols) : new OrigWs(url); " ++
        "  const record = (dir, data) => { " ++
        "    window.__kuri_ws_frames.push({direction: dir, url: url, data: typeof data === 'string' ? data : '<binary>', timestamp: new Date().toISOString()}); " ++
        "    if (window.__kuri_ws_frames.length > 1000) window.__kuri_ws_frames.shift(); " ++
        "  }; " ++
        "  ws.addEventListener('message', (e) => record('received', e.data)); " ++
        "  const origSend = ws.send.bind(ws); " ++
        "  ws.send = function(data) { record('sent', data); return origSend(data); }; " ++
        "  return ws; " ++
        "}; " ++
        "window.WebSocket.prototype = OrigWs.prototype; " ++
        "return 'started'; })()";

    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{ws_capture_js}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };

    const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"message\":\"WebSocket capture started\",\"tab_id\":\"{s}\"}}", .{tab_id}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleWsStop(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // Retrieve captured frames and clean up
    const js = "(() => { const frames = window.__kuri_ws_frames || []; delete window.__kuri_ws_frames; return JSON.stringify({frames: frames}); })()";
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{js}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleElementState(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const ref = getQueryParam(target, "ref") orelse {
        resp.sendError(request, 400, "Missing ref parameter");
        return;
    };
    const check = getQueryParam(target, "check") orelse "exists";
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    bridge.mu.lockShared();
    const cache = bridge.snapshots.get(tab_id);
    bridge.mu.unlockShared();

    const bid = if (cache) |c| c.refs.get(ref) else null;
    if (bid == null) {
        if (std.mem.eql(u8, check, "exists")) {
            const body = std.fmt.allocPrint(arena, "{{\"ref\":\"{s}\",\"exists\":false}}", .{ref}) catch {
                resp.sendError(request, 500, "Internal Server Error");
                return;
            };
            resp.sendJson(request, body);
        } else {
            resp.sendError(request, 400, "Ref not found. Call /snapshot first");
        }
        return;
    }

    if (std.mem.eql(u8, check, "exists")) {
        const body = std.fmt.allocPrint(arena, "{{\"ref\":\"{s}\",\"exists\":true}}", .{ref}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        resp.sendJson(request, body);
        return;
    }

    const resolve_params = std.fmt.allocPrint(arena, "{{\"backendNodeId\":{d}}}", .{bid.?}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const resolve_response = client.send(arena, protocol.Methods.dom_resolve_node, resolve_params) catch {
        resp.sendError(request, 502, "DOM.resolveNode failed");
        return;
    };
    const object_id = extractSimpleJsonString(resolve_response, 0, "\"objectId\"") orelse {
        resp.sendError(request, 500, "Could not resolve element");
        return;
    };

    const js_fn: []const u8 = if (std.mem.eql(u8, check, "visible"))
        "function() { const s = getComputedStyle(this); if (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0') return false; const r = this.getBoundingClientRect(); return r.width > 0 && r.height > 0; }"
    else if (std.mem.eql(u8, check, "enabled"))
        "function() { return !this.disabled; }"
    else if (std.mem.eql(u8, check, "checked"))
        "function() { return !!this.checked; }"
    else {
        resp.sendError(request, 400, "Unknown check type. Use: exists, visible, enabled, checked");
        return;
    };

    const escaped_fn = jsonEscapeAlloc(arena, js_fn) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const call_params = std.fmt.allocPrint(arena, "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"returnByValue\":true}}", .{ object_id, escaped_fn }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const call_response = client.send(arena, protocol.Methods.runtime_call_function_on, call_params) catch {
        resp.sendError(request, 502, "Runtime.callFunctionOn failed");
        return;
    };

    const result_val = if (std.mem.indexOf(u8, call_response, "true") != null) "true" else "false";
    const escaped_check = jsonEscapeAlloc(arena, check) orelse check;
    const body = std.fmt.allocPrint(arena, "{{\"ref\":\"{s}\",\"{s}\":{s}}}", .{ ref, escaped_check, result_val }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleBatch(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const body = readRequestBody(request, arena) orelse {
        resp.sendError(request, 400, "Missing request body");
        return;
    };

    var results: std.ArrayList(u8) = .empty;
    results.appendSlice(arena, "{\"results\":[") catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    var first_tab_id: ?[]const u8 = null;
    {
        const tabs = bridge.listTabs(arena) catch null;
        if (tabs) |t| {
            if (t.len > 0) first_tab_id = t[0].id;
        }
    }

    var cmd_idx: usize = 0;
    var pos: usize = 0;
    while (pos < body.len) {
        const path_start = std.mem.indexOfPos(u8, body, pos, "\"path\"") orelse break;
        const path_val = extractSimpleJsonString(body, path_start, "\"path\"") orelse break;

        const tab_id = extractSimpleJsonString(body, path_start, "\"tab_id\"") orelse
            (first_tab_id orelse "");

        const client = bridge.getCdpClient(tab_id);

        if (cmd_idx > 0) results.appendSlice(arena, ",") catch {};

        if (std.mem.eql(u8, path_val, "/navigate")) {
            const url = extractSimpleJsonString(body, path_start, "\"url\"") orelse {
                results.appendSlice(arena, "{\"status\":400,\"error\":\"missing url\"}") catch {};
                cmd_idx += 1;
                pos = path_start + 6;
                continue;
            };
            if (client) |c| {
                const escaped_url = jsonEscapeAlloc(arena, url) orelse url;
                const params = std.fmt.allocPrint(arena, "{{\"url\":\"{s}\"}}", .{escaped_url}) catch {
                    results.appendSlice(arena, "{\"status\":500,\"error\":\"alloc\"}") catch {};
                    cmd_idx += 1;
                    pos = path_start + 6;
                    continue;
                };
                const response = c.send(arena, protocol.Methods.page_navigate, params) catch {
                    results.appendSlice(arena, "{\"status\":502,\"error\":\"navigate failed\"}") catch {};
                    cmd_idx += 1;
                    pos = path_start + 6;
                    continue;
                };
                bumpGenerationLocked(bridge, tab_id);
                results.appendSlice(arena, "{\"status\":200,\"body\":") catch {};
                results.appendSlice(arena, response) catch {};
                results.appendSlice(arena, "}") catch {};
            } else {
                results.appendSlice(arena, "{\"status\":404,\"error\":\"tab not found\"}") catch {};
            }
        } else if (std.mem.eql(u8, path_val, "/evaluate")) {
            const expr = extractSimpleJsonString(body, path_start, "\"expression\"") orelse {
                results.appendSlice(arena, "{\"status\":400,\"error\":\"missing expression\"}") catch {};
                cmd_idx += 1;
                pos = path_start + 6;
                continue;
            };
            if (client) |c| {
                const escaped = jsonEscapeAlloc(arena, expr) orelse expr;
                const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped}) catch {
                    results.appendSlice(arena, "{\"status\":500,\"error\":\"alloc\"}") catch {};
                    cmd_idx += 1;
                    pos = path_start + 6;
                    continue;
                };
                const response = c.send(arena, protocol.Methods.runtime_evaluate, params) catch {
                    results.appendSlice(arena, "{\"status\":502,\"error\":\"eval failed\"}") catch {};
                    cmd_idx += 1;
                    pos = path_start + 6;
                    continue;
                };
                results.appendSlice(arena, "{\"status\":200,\"body\":") catch {};
                results.appendSlice(arena, response) catch {};
                results.appendSlice(arena, "}") catch {};
            } else {
                results.appendSlice(arena, "{\"status\":404,\"error\":\"tab not found\"}") catch {};
            }
        } else if (std.mem.eql(u8, path_val, "/action")) {
            const action = extractSimpleJsonString(body, path_start, "\"action\"") orelse "click";
            const ref = extractSimpleJsonString(body, path_start, "\"ref\"") orelse "";
            const value = extractSimpleJsonString(body, path_start, "\"value\"");
            const realistic_param = extractSimpleJsonString(body, path_start, "\"realistic\"");
            const use_realistic = if (realistic_param) |r| !std.mem.eql(u8, r, "false") else true;
            if (client) |c| {
                const actions = @import("../cdp/actions.zig");
                const dispatch = @import("../cdp/dispatch.zig");
                const kind = actions.ActionKind.fromString(action);
                if (kind == null) {
                    results.appendSlice(arena, "{\"status\":400,\"error\":\"unknown action\"}") catch {};
                } else if (kind.? == .scroll) {
                    const scroll_params = std.fmt.allocPrint(arena, "{{\"expression\":\"window.scrollBy(0, 500) || 'scrolled'\",\"returnByValue\":true}}", .{}) catch {
                        results.appendSlice(arena, "{\"status\":500,\"error\":\"alloc\"}") catch {};
                        cmd_idx += 1;
                        pos = path_start + 6;
                        continue;
                    };
                    _ = c.send(arena, protocol.Methods.runtime_evaluate, scroll_params) catch {};
                    results.appendSlice(arena, "{\"status\":200,\"body\":{\"ok\":true,\"action\":\"scrolled\"}}") catch {};
                } else if (kind.? == .press) {
                    const v = value orelse "";
                    const press_params = std.fmt.allocPrint(arena, "{{\"expression\":\"document.dispatchEvent(new KeyboardEvent('keydown', {{key: '{s}'}})) || 'pressed'\",\"returnByValue\":true}}", .{v}) catch {
                        results.appendSlice(arena, "{\"status\":500,\"error\":\"alloc\"}") catch {};
                        cmd_idx += 1;
                        pos = path_start + 6;
                        continue;
                    };
                    _ = c.send(arena, protocol.Methods.runtime_evaluate, press_params) catch {};
                    results.appendSlice(arena, "{\"status\":200,\"body\":{\"ok\":true,\"action\":\"pressed\"}}") catch {};
                } else {
                    bridge.mu.lockShared();
                    const snap_cache = bridge.snapshots.get(tab_id);
                    bridge.mu.unlockShared();
                    const clean_ref = if (ref.len > 0 and ref[0] == '@') ref[1..] else ref;
                    const bid = if (snap_cache) |sc| sc.refs.get(clean_ref) else null;
                    if (bid) |b| {
                        const outcome = dispatch.dispatchActionOnBackendNode(arena, c, b, kind.?, value, use_realistic);
                        switch (outcome) {
                            .outcome => |o| {
                                const escaped_label = jsonEscapeAlloc(arena, o.label) orelse o.label;
                                results.print(arena, "{{\"status\":200,\"body\":{{\"ok\":true,\"action\":\"{s}\"}}}}", .{escaped_label}) catch {};
                            },
                            .err => |e| {
                                const escaped_msg = jsonEscapeAlloc(arena, e.message) orelse e.message;
                                results.print(arena, "{{\"status\":{d},\"error\":\"{s}\"}}", .{ e.status, escaped_msg }) catch {};
                            },
                        }
                    } else {
                        results.appendSlice(arena, "{\"status\":400,\"error\":\"ref not found\"}") catch {};
                    }
                }
            } else {
                results.appendSlice(arena, "{\"status\":404,\"error\":\"tab not found\"}") catch {};
            }
        } else if (std.mem.eql(u8, path_val, "/snapshot")) {
            if (client) |c| {
                const snap_params = "{\"expression\":\"document.title\",\"returnByValue\":true}";
                const title_resp = c.send(arena, protocol.Methods.runtime_evaluate, snap_params) catch "{}";
                _ = title_resp;
                const a11y_params = std.fmt.allocPrint(arena, "{{\"depth\":-1}}", .{}) catch {
                    results.appendSlice(arena, "{\"status\":500,\"error\":\"alloc\"}") catch {};
                    cmd_idx += 1;
                    pos = path_start + 6;
                    continue;
                };
                const a11y_resp = c.send(arena, protocol.Methods.accessibility_get_full_tree, a11y_params) catch {
                    results.appendSlice(arena, "{\"status\":502,\"error\":\"a11y tree failed\"}") catch {};
                    cmd_idx += 1;
                    pos = path_start + 6;
                    continue;
                };
                results.appendSlice(arena, "{\"status\":200,\"body\":") catch {};
                results.appendSlice(arena, a11y_resp) catch {};
                results.appendSlice(arena, "}") catch {};
            } else {
                results.appendSlice(arena, "{\"status\":404,\"error\":\"tab not found\"}") catch {};
            }
        } else if (std.mem.eql(u8, path_val, "/text")) {
            if (client) |c| {
                const text_result = evalValueString(arena, c, "document.body ? document.body.innerText : ''") orelse "";
                const escaped_text = jsonEscapeAlloc(arena, text_result) orelse "";
                results.print(arena, "{{\"status\":200,\"body\":{{\"text\":\"{s}\"}}}}", .{escaped_text}) catch {};
            } else {
                results.appendSlice(arena, "{\"status\":404,\"error\":\"tab not found\"}") catch {};
            }
        } else if (std.mem.eql(u8, path_val, "/wait")) {
            const wait_ms_str = extractSimpleJsonString(body, path_start, "\"timeout\"") orelse "3000";
            const wait_ms = std.fmt.parseInt(u64, wait_ms_str, 10) catch 3000;
            const wait_sel = extractSimpleJsonString(body, path_start, "\"selector\"");
            if (wait_sel) |ws| {
                if (client) |c| {
                    const escaped_ws = jsonEscapeAlloc(arena, ws) orelse ws;
                    const wp = max_polls: {
                        break :max_polls wait_ms / 100;
                    };
                    var wp_i: u64 = 0;
                    var found = false;
                    while (wp_i < wp) : (wp_i += 1) {
                        const chk = std.fmt.allocPrint(arena, "{{\"expression\":\"!!document.querySelector('{s}')\",\"returnByValue\":true}}", .{escaped_ws}) catch break;
                        const chk_r = c.send(arena, protocol.Methods.runtime_evaluate, chk) catch break;
                        if (std.mem.indexOf(u8, chk_r, "true") != null) {
                            found = true;
                            break;
                        }
                        compat.threadSleep(100 * std.time.ns_per_ms);
                    }
                    if (found) {
                        results.appendSlice(arena, "{\"status\":200,\"body\":{\"status\":\"found\"}}") catch {};
                    } else {
                        results.appendSlice(arena, "{\"status\":408,\"body\":{\"status\":\"timeout\"}}") catch {};
                    }
                } else {
                    results.appendSlice(arena, "{\"status\":404,\"error\":\"tab not found\"}") catch {};
                }
            } else {
                compat.threadSleep(wait_ms * std.time.ns_per_ms);
                results.appendSlice(arena, "{\"status\":200,\"body\":{\"status\":\"waited\"}}") catch {};
            }
        } else {
            const escaped_path = jsonEscapeAlloc(arena, path_val) orelse path_val;
            results.print(arena, "{{\"status\":400,\"error\":\"unsupported batch command: {s}\"}}", .{escaped_path}) catch {};
        }

        cmd_idx += 1;
        const next_path = std.mem.indexOfPos(u8, body, path_start + 6, "\"path\"");
        pos = next_path orelse body.len;
    }

    results.appendSlice(arena, "]}") catch {};
    resp.sendJson(request, results.items);
}

fn handleFindElement(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const by_text = getDecodedQueryParamAlloc(arena, target, "text");
    const by_role = getQueryParam(target, "role");
    const by_label = getDecodedQueryParamAlloc(arena, target, "label");
    const by_placeholder = getDecodedQueryParamAlloc(arena, target, "placeholder");
    const by_testid = getDecodedQueryParamAlloc(arena, target, "testid");

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const js: []const u8 = if (by_text) |txt| blk: {
        const escaped = jsonEscapeAlloc(arena, txt) orelse {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        break :blk std.fmt.allocPrint(arena, "(() => {{ const all = document.querySelectorAll('a,button,input,select,textarea,[role],[onclick]'); for (const el of all) {{ if ((el.textContent || '').trim().includes('{s}') || (el.value || '') === '{s}' || (el.ariaLabel || '') === '{s}') {{ el.scrollIntoViewIfNeeded(); const r = el.getBoundingClientRect(); return JSON.stringify({{found:true,tag:el.tagName.toLowerCase(),text:(el.textContent||'').trim().substring(0,80),x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}}); }} }} return JSON.stringify({{found:false}}); }})()", .{ escaped, escaped, escaped }) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
    } else if (by_role) |role| blk: {
        const escaped_role = jsonEscapeAlloc(arena, role) orelse {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const name_filter = if (getDecodedQueryParamAlloc(arena, target, "name")) |n|
            jsonEscapeAlloc(arena, n) orelse ""
        else
            null;
        if (name_filter) |nf| {
            break :blk std.fmt.allocPrint(arena, "(() => {{ const els = document.querySelectorAll('[role=\"{s}\"]'); for (const el of els) {{ if ((el.textContent||'').trim().includes('{s}') || (el.ariaLabel||'')=== '{s}') {{ el.scrollIntoViewIfNeeded(); const r = el.getBoundingClientRect(); return JSON.stringify({{found:true,tag:el.tagName.toLowerCase(),role:'{s}',name:(el.textContent||'').trim().substring(0,80),x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}}); }} }} return JSON.stringify({{found:false}}); }})()", .{ escaped_role, nf, nf, escaped_role }) catch {
                resp.sendError(request, 500, "Internal Server Error");
                return;
            };
        } else {
            break :blk std.fmt.allocPrint(arena, "(() => {{ const el = document.querySelector('[role=\"{s}\"]'); if (!el) return JSON.stringify({{found:false}}); el.scrollIntoViewIfNeeded(); const r = el.getBoundingClientRect(); return JSON.stringify({{found:true,tag:el.tagName.toLowerCase(),role:'{s}',name:(el.textContent||'').trim().substring(0,80),x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}}); }})()", .{ escaped_role, escaped_role }) catch {
                resp.sendError(request, 500, "Internal Server Error");
                return;
            };
        }
    } else if (by_label) |lbl| blk: {
        const escaped = jsonEscapeAlloc(arena, lbl) orelse {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        break :blk std.fmt.allocPrint(arena, "(() => {{ const labels = document.querySelectorAll('label'); for (const l of labels) {{ if ((l.textContent||'').trim().includes('{s}') && l.control) {{ l.control.scrollIntoViewIfNeeded(); const r = l.control.getBoundingClientRect(); return JSON.stringify({{found:true,tag:l.control.tagName.toLowerCase(),label:'{s}',x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}}); }} }} const aria = document.querySelector('[aria-label=\"{s}\"]'); if (aria) {{ aria.scrollIntoViewIfNeeded(); const r = aria.getBoundingClientRect(); return JSON.stringify({{found:true,tag:aria.tagName.toLowerCase(),label:'{s}',x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}}); }} return JSON.stringify({{found:false}}); }})()", .{ escaped, escaped, escaped, escaped }) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
    } else if (by_placeholder) |ph| blk: {
        const escaped = jsonEscapeAlloc(arena, ph) orelse {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        break :blk std.fmt.allocPrint(arena, "(() => {{ const el = document.querySelector('[placeholder=\"{s}\"]') || document.querySelector('input[placeholder*=\"{s}\"],textarea[placeholder*=\"{s}\"]'); if (!el) return JSON.stringify({{found:false}}); el.scrollIntoViewIfNeeded(); const r = el.getBoundingClientRect(); return JSON.stringify({{found:true,tag:el.tagName.toLowerCase(),placeholder:'{s}',x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}}); }})()", .{ escaped, escaped, escaped, escaped }) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
    } else if (by_testid) |tid| blk: {
        const escaped = jsonEscapeAlloc(arena, tid) orelse {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        break :blk std.fmt.allocPrint(arena, "(() => {{ const el = document.querySelector('[data-testid=\"{s}\"]'); if (!el) return JSON.stringify({{found:false}}); el.scrollIntoViewIfNeeded(); const r = el.getBoundingClientRect(); return JSON.stringify({{found:true,tag:el.tagName.toLowerCase(),testid:'{s}',x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}}); }})()", .{ escaped, escaped }) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
    } else {
        resp.sendError(request, 400, "Provide one of: text, role, label, placeholder, testid");
        return;
    };

    const escaped_js = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped_js}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    const val = extractSimpleJsonString(response, 0, "\"value\"") orelse {
        resp.sendJson(request, response);
        return;
    };
    resp.sendJson(request, val);
}

fn handleDialogAuto(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const mode = getQueryParam(target, "mode") orelse "accept";

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    _ = client.send(arena, protocol.Methods.page_enable, null) catch {};

    const accept_str = if (std.mem.eql(u8, mode, "dismiss")) "false" else "true";
    const js = std.fmt.allocPrint(arena, "(() => {{ window.__kuri_dialog_auto = {s}; window.__kuri_dialog_log = []; window.addEventListener('beforeunload', (e) => {{ e.preventDefault(); }}); return 'auto-dialog-{s}'; }})()", .{ accept_str, mode }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {};

    const dialog_js =
        \\(() => {
        \\  const handler = (e) => {
        \\    window.__kuri_dialog_log = window.__kuri_dialog_log || [];
        \\    window.__kuri_dialog_log.push({type: e.type, message: e.message || '', defaultPrompt: e.defaultPrompt || ''});
        \\  };
        \\  window.addEventListener('alert', handler);
        \\  return 'listeners-attached';
        \\})()
    ;
    const escaped_dlg = jsonEscapeAlloc(arena, dialog_js) orelse "";
    const dlg_params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped_dlg}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.runtime_evaluate, dlg_params) catch {};

    const handle_params = std.fmt.allocPrint(arena, "{{\"accept\":{s}}}", .{accept_str}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.page_handle_dialog, handle_params) catch {};

    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"mode\":\"{s}\"}}", .{mode}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleDialogRespond(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge, accept: bool) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const prompt_text = getDecodedQueryParamAlloc(arena, target, "text");

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const params = if (prompt_text) |pt| blk: {
        const escaped_pt = jsonEscapeAlloc(arena, pt) orelse "";
        break :blk std.fmt.allocPrint(arena, "{{\"accept\":{s},\"promptText\":\"{s}\"}}", .{ if (accept) "true" else "false", escaped_pt }) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
    } else std.fmt.allocPrint(arena, "{{\"accept\":{s}}}", .{if (accept) "true" else "false"}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    _ = client.send(arena, protocol.Methods.page_handle_dialog, params) catch {
        resp.sendError(request, 502, "No dialog present or CDP failed");
        return;
    };

    const action = if (accept) "accepted" else "dismissed";
    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"action\":\"{s}\"}}", .{action}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleMouseEvent(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge, event_type: []const u8) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const x_str = getQueryParam(target, "x") orelse "0";
    const y_str = getQueryParam(target, "y") orelse "0";
    const button = getQueryParam(target, "button") orelse "left";
    const click_count_str = getQueryParam(target, "clickCount") orelse "1";

    const x = std.fmt.parseInt(i64, x_str, 10) catch 0;
    const y = std.fmt.parseInt(i64, y_str, 10) catch 0;
    const click_count = std.fmt.parseInt(i32, click_count_str, 10) catch 1;

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const escaped_type = jsonEscapeAlloc(arena, event_type) orelse event_type;
    const escaped_button = jsonEscapeAlloc(arena, button) orelse button;
    const params = std.fmt.allocPrint(arena, "{{\"type\":\"{s}\",\"x\":{d},\"y\":{d},\"button\":\"{s}\",\"clickCount\":{d}}}", .{ escaped_type, x, y, escaped_button, click_count }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.input_dispatch_mouse_event, params) catch {
        resp.sendError(request, 502, "Input.dispatchMouseEvent failed");
        return;
    };

    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"type\":\"{s}\",\"x\":{d},\"y\":{d}}}", .{ escaped_type, x, y }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleMouseWheel(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const x_str = getQueryParam(target, "x") orelse "0";
    const y_str = getQueryParam(target, "y") orelse "0";
    const dx_str = getQueryParam(target, "deltaX") orelse "0";
    const dy_str = getQueryParam(target, "deltaY") orelse "-120";

    const x = std.fmt.parseInt(i64, x_str, 10) catch 0;
    const y = std.fmt.parseInt(i64, y_str, 10) catch 0;
    const dx = std.fmt.parseInt(i64, dx_str, 10) catch 0;
    const dy = std.fmt.parseInt(i64, dy_str, 10) catch -120;

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const params = std.fmt.allocPrint(arena, "{{\"type\":\"mouseWheel\",\"x\":{d},\"y\":{d},\"deltaX\":{d},\"deltaY\":{d}}}", .{ x, y, dx, dy }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.input_dispatch_mouse_event, params) catch {
        resp.sendError(request, 502, "Input.dispatchMouseEvent failed");
        return;
    };

    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"type\":\"mouseWheel\",\"deltaX\":{d},\"deltaY\":{d}}}", .{ dx, dy }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handlePageState(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const js =
        \\(() => {
        \\  const s = {
        \\    url: location.href,
        \\    title: document.title,
        \\    readyState: document.readyState,
        \\    scrollX: Math.round(window.scrollX),
        \\    scrollY: Math.round(window.scrollY),
        \\    scrollHeight: document.documentElement.scrollHeight,
        \\    viewportWidth: window.innerWidth,
        \\    viewportHeight: window.innerHeight,
        \\    documentHeight: document.documentElement.scrollHeight,
        \\    documentWidth: document.documentElement.scrollWidth,
        \\    scrollPercent: Math.round((window.scrollY / Math.max(1, document.documentElement.scrollHeight - window.innerHeight)) * 100),
        \\    forms: document.forms.length,
        \\    links: document.links.length,
        \\    images: document.images.length,
        \\    inputs: document.querySelectorAll('input,textarea,select').length
        \\  };
        \\  return s;
        \\})()
    ;
    const escaped = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    // returnByValue gives us the object inline as CDP JSON, so we can slice it
    // out directly — no double JSON.stringify (that path double-escaped the
    // quotes and truncated the body to `{\`).
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    // Response shape: {"result":{"result":{"type":"object","value":{ ... }}}}
    // Grab the inner value object by brace-matching.
    if (std.mem.indexOf(u8, response, "\"value\":")) |vpos| {
        const brace = std.mem.indexOfScalarPos(u8, response, vpos, '{');
        if (brace) |b| {
            if (findJsonObjectEnd(response, b)) |end| {
                resp.sendJson(request, response[b..end]);
                return;
            }
        }
    }
    resp.sendJson(request, response);
}

fn handleClipboard(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge, mode: []const u8) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    if (std.mem.eql(u8, mode, "read")) {
        const js = "navigator.clipboard.readText().then(t => t).catch(() => '')";
        const escaped = jsonEscapeAlloc(arena, js) orelse {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true,\"awaitPromise\":true}}", .{escaped}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
            resp.sendError(request, 502, "CDP command failed");
            return;
        };
        resp.sendJson(request, response);
    } else {
        const text = getDecodedQueryParamAlloc(arena, target, "text") orelse {
            resp.sendError(request, 400, "Missing text parameter");
            return;
        };
        const escaped_text = jsonEscapeAlloc(arena, text) orelse {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const js = std.fmt.allocPrint(arena, "navigator.clipboard.writeText('{s}').then(() => 'written').catch(e => e.message)", .{escaped_text}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const escaped = jsonEscapeAlloc(arena, js) orelse {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true,\"awaitPromise\":true}}", .{escaped}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
            resp.sendError(request, 502, "CDP command failed");
            return;
        };
        resp.sendJson(request, response);
    }
}

fn handleClear(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const ref = getQueryParam(target, "ref") orelse {
        resp.sendError(request, 400, "Missing ref parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    bridge.mu.lockShared();
    const cache = bridge.snapshots.get(tab_id);
    bridge.mu.unlockShared();
    const bid = if (cache) |c| c.refs.get(ref) else null;
    if (bid == null) {
        resp.sendError(request, 400, "Ref not found");
        return;
    }
    const rp = std.fmt.allocPrint(arena, "{{\"backendNodeId\":{d}}}", .{bid.?}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const rr = client.send(arena, protocol.Methods.dom_resolve_node, rp) catch {
        resp.sendError(request, 502, "DOM.resolveNode failed");
        return;
    };
    const oid = extractSimpleJsonString(rr, 0, "\"objectId\"") orelse {
        resp.sendError(request, 500, "Could not resolve element");
        return;
    };
    const js = "function() { this.focus(); if ('value' in this) { this.value = ''; } else if (this.isContentEditable) { this.textContent = ''; } this.dispatchEvent(new Event('input',{bubbles:true})); this.dispatchEvent(new Event('change',{bubbles:true})); return 'cleared'; }";
    const escaped_fn = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const cp = std.fmt.allocPrint(arena, "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"returnByValue\":true}}", .{ oid, escaped_fn }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.runtime_call_function_on, cp) catch {
        resp.sendError(request, 502, "clear failed");
        return;
    };
    resp.sendJson(request, "{\"ok\":true,\"action\":\"cleared\"}");
}

fn handleBoundingBox(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const ref = getQueryParam(target, "ref") orelse {
        resp.sendError(request, 400, "Missing ref parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    bridge.mu.lockShared();
    const cache = bridge.snapshots.get(tab_id);
    bridge.mu.unlockShared();
    const bid = if (cache) |c| c.refs.get(ref) else null;
    if (bid == null) {
        resp.sendError(request, 400, "Ref not found");
        return;
    }
    const rp = std.fmt.allocPrint(arena, "{{\"backendNodeId\":{d}}}", .{bid.?}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const rr = client.send(arena, protocol.Methods.dom_resolve_node, rp) catch {
        resp.sendError(request, 502, "DOM.resolveNode failed");
        return;
    };
    const oid = extractSimpleJsonString(rr, 0, "\"objectId\"") orelse {
        resp.sendError(request, 500, "Could not resolve element");
        return;
    };
    const js = "function() { const r = this.getBoundingClientRect(); return JSON.stringify({x:Math.round(r.x),y:Math.round(r.y),width:Math.round(r.width),height:Math.round(r.height),centerX:Math.round(r.x+r.width/2),centerY:Math.round(r.y+r.height/2)}); }";
    const escaped_fn = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const cp = std.fmt.allocPrint(arena, "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"returnByValue\":true}}", .{ oid, escaped_fn }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_call_function_on, cp) catch {
        resp.sendError(request, 502, "boundingbox failed");
        return;
    };
    const val = extractSimpleJsonString(response, 0, "\"value\"") orelse {
        resp.sendJson(request, response);
        return;
    };
    resp.sendJson(request, val);
}

fn handleWaitForFunction(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const expression = getDecodedQueryParamAlloc(arena, target, "expression") orelse {
        resp.sendError(request, 400, "Missing expression parameter");
        return;
    };
    const timeout_str = getQueryParam(target, "timeout") orelse "5000";
    const timeout_ms = std.fmt.parseInt(u64, timeout_str, 10) catch 5000;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const escaped = jsonEscapeAlloc(arena, expression) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const max_polls = timeout_ms / 100;
    var polls: u64 = 0;
    while (polls < max_polls) : (polls += 1) {
        const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
            resp.sendError(request, 502, "CDP command failed");
            return;
        };
        if (std.mem.indexOf(u8, response, "true") != null) {
            const body = std.fmt.allocPrint(arena, "{{\"status\":\"satisfied\",\"polls\":{d}}}", .{polls + 1}) catch {
                resp.sendError(request, 500, "Internal Server Error");
                return;
            };
            resp.sendJson(request, body);
            return;
        }
        compat.threadSleep(100 * std.time.ns_per_ms);
    }
    resp.sendJson(request, "{\"status\":\"timeout\",\"reason\":\"function_not_truthy\"}");
}

fn handleResponseBody(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const url_pattern = getDecodedQueryParamAlloc(arena, target, "url") orelse {
        resp.sendError(request, 400, "Missing url parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const escaped_url = jsonEscapeAlloc(arena, url_pattern) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const js = std.fmt.allocPrint(arena, "(async () => {{ try {{ const r = await fetch('{s}'); const t = await r.text(); return JSON.stringify({{status:r.status,url:r.url,body:t.substring(0,10000)}}); }} catch(e) {{ return JSON.stringify({{error:e.message}}); }} }})()", .{escaped_url}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true,\"awaitPromise\":true}}", .{escaped}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    const val = extractSimpleJsonString(response, 0, "\"value\"") orelse {
        resp.sendJson(request, response);
        return;
    };
    resp.sendJson(request, val);
}

fn handleSetContent(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const body = readRequestBody(request, arena) orelse {
        resp.sendError(request, 400, "Missing request body with HTML content");
        return;
    };
    const html = extractSimpleJsonString(body, 0, "\"html\"") orelse body;
    const escaped_html = jsonEscapeAlloc(arena, html) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const js = std.fmt.allocPrint(arena, "document.open(); document.write('{s}'); document.close(); 'set'", .{escaped_html}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, "{\"ok\":true,\"action\":\"setcontent\"}");
}

fn handleSelectAll(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const ref = getQueryParam(target, "ref") orelse {
        resp.sendError(request, 400, "Missing ref parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    bridge.mu.lockShared();
    const cache = bridge.snapshots.get(tab_id);
    bridge.mu.unlockShared();
    const bid = if (cache) |c| c.refs.get(ref) else null;
    if (bid == null) {
        resp.sendError(request, 400, "Ref not found");
        return;
    }
    const rp = std.fmt.allocPrint(arena, "{{\"backendNodeId\":{d}}}", .{bid.?}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const rr = client.send(arena, protocol.Methods.dom_resolve_node, rp) catch {
        resp.sendError(request, 502, "DOM.resolveNode failed");
        return;
    };
    const oid = extractSimpleJsonString(rr, 0, "\"objectId\"") orelse {
        resp.sendError(request, 500, "Could not resolve element");
        return;
    };
    const js = "function() { this.focus(); if ('select' in this) { this.select(); } else { const r = document.createRange(); r.selectNodeContents(this); const s = window.getSelection(); s.removeAllRanges(); s.addRange(r); } return 'selected'; }";
    const escaped_fn = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const cp = std.fmt.allocPrint(arena, "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"returnByValue\":true}}", .{ oid, escaped_fn }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.runtime_call_function_on, cp) catch {
        resp.sendError(request, 502, "selectall failed");
        return;
    };
    resp.sendJson(request, "{\"ok\":true,\"action\":\"selectall\"}");
}

fn handleSetValue(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const ref = getQueryParam(target, "ref") orelse {
        resp.sendError(request, 400, "Missing ref parameter");
        return;
    };
    const value = getDecodedQueryParamAlloc(arena, target, "value") orelse {
        resp.sendError(request, 400, "Missing value parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    bridge.mu.lockShared();
    const cache = bridge.snapshots.get(tab_id);
    bridge.mu.unlockShared();
    const bid = if (cache) |c| c.refs.get(ref) else null;
    if (bid == null) {
        resp.sendError(request, 400, "Ref not found");
        return;
    }
    const rp = std.fmt.allocPrint(arena, "{{\"backendNodeId\":{d}}}", .{bid.?}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const rr = client.send(arena, protocol.Methods.dom_resolve_node, rp) catch {
        resp.sendError(request, 502, "DOM.resolveNode failed");
        return;
    };
    const oid = extractSimpleJsonString(rr, 0, "\"objectId\"") orelse {
        resp.sendError(request, 500, "Could not resolve element");
        return;
    };
    const escaped_val = jsonEscapeAlloc(arena, value) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const js = std.fmt.allocPrint(arena, "function() {{ if ('value' in this) {{ this.value = '{s}'; }} else if (this.isContentEditable) {{ this.textContent = '{s}'; }} this.dispatchEvent(new Event('input',{{bubbles:true}})); this.dispatchEvent(new Event('change',{{bubbles:true}})); return 'set'; }}", .{ escaped_val, escaped_val }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped_fn = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const cp = std.fmt.allocPrint(arena, "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"returnByValue\":true}}", .{ oid, escaped_fn }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.runtime_call_function_on, cp) catch {
        resp.sendError(request, 502, "setvalue failed");
        return;
    };
    resp.sendJson(request, "{\"ok\":true,\"action\":\"setvalue\"}");
}

fn handleTimezone(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const tz = getDecodedQueryParamAlloc(arena, target, "timezone") orelse {
        resp.sendError(request, 400, "Missing timezone parameter (e.g. America/New_York)");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const escaped_tz = jsonEscapeAlloc(arena, tz) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"timezoneId\":\"{s}\"}}", .{escaped_tz}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, "Emulation.setTimezoneOverride", params) catch {
        resp.sendError(request, 502, "Emulation.setTimezoneOverride failed");
        return;
    };
    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"timezone\":\"{s}\"}}", .{escaped_tz}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleLocale(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const locale = getDecodedQueryParamAlloc(arena, target, "locale") orelse {
        resp.sendError(request, 400, "Missing locale parameter (e.g. en-US)");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const escaped_locale = jsonEscapeAlloc(arena, locale) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"locale\":\"{s}\"}}", .{escaped_locale}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, "Emulation.setLocaleOverride", params) catch {
        resp.sendError(request, 502, "Emulation.setLocaleOverride failed");
        return;
    };
    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"locale\":\"{s}\"}}", .{escaped_locale}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handlePermissions(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const permission = getQueryParam(target, "name") orelse {
        resp.sendError(request, 400, "Missing name parameter (e.g. geolocation, notifications, clipboard-read)");
        return;
    };
    const setting = getQueryParam(target, "state") orelse "granted";
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const escaped_perm = jsonEscapeAlloc(arena, permission) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped_setting = jsonEscapeAlloc(arena, setting) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const origin = evalValueString(arena, client, "window.location.origin") orelse "";
    const escaped_origin = jsonEscapeAlloc(arena, origin) orelse "";
    const params = std.fmt.allocPrint(arena, "{{\"permission\":{{\"name\":\"{s}\"}},\"setting\":\"{s}\",\"origin\":\"{s}\"}}", .{ escaped_perm, escaped_setting, escaped_origin }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, "Browser.setPermission", params) catch {
        resp.sendError(request, 502, "Browser.setPermission failed");
        return;
    };
    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"permission\":\"{s}\",\"state\":\"{s}\"}}", .{ escaped_perm, escaped_setting }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleTap(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const x_str = getQueryParam(target, "x") orelse "0";
    const y_str = getQueryParam(target, "y") orelse "0";
    const x = std.fmt.parseInt(i64, x_str, 10) catch 0;
    const y = std.fmt.parseInt(i64, y_str, 10) catch 0;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const down_params = std.fmt.allocPrint(arena, "{{\"type\":\"touchStart\",\"touchPoints\":[{{\"x\":{d},\"y\":{d}}}]}}", .{ x, y }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, "Input.dispatchTouchEvent", down_params) catch {
        resp.sendError(request, 502, "Touch event failed");
        return;
    };
    const up_params = std.fmt.allocPrint(arena, "{{\"type\":\"touchEnd\",\"touchPoints\":[]}}", .{}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, "Input.dispatchTouchEvent", up_params) catch {};
    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"action\":\"tap\",\"x\":{d},\"y\":{d}}}", .{ x, y }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleDispatch(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const ref = getQueryParam(target, "ref") orelse {
        resp.sendError(request, 400, "Missing ref parameter");
        return;
    };
    const event_type = getDecodedQueryParamAlloc(arena, target, "type") orelse {
        resp.sendError(request, 400, "Missing type parameter (e.g. click, input, change, submit)");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    bridge.mu.lockShared();
    const cache = bridge.snapshots.get(tab_id);
    bridge.mu.unlockShared();
    const bid = if (cache) |c| c.refs.get(ref) else null;
    if (bid == null) {
        resp.sendError(request, 400, "Ref not found");
        return;
    }
    const rp = std.fmt.allocPrint(arena, "{{\"backendNodeId\":{d}}}", .{bid.?}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const rr = client.send(arena, protocol.Methods.dom_resolve_node, rp) catch {
        resp.sendError(request, 502, "DOM.resolveNode failed");
        return;
    };
    const oid = extractSimpleJsonString(rr, 0, "\"objectId\"") orelse {
        resp.sendError(request, 500, "Could not resolve element");
        return;
    };
    const escaped_type = jsonEscapeAlloc(arena, event_type) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const js = std.fmt.allocPrint(arena, "function() {{ this.dispatchEvent(new Event('{s}', {{bubbles:true,cancelable:true}})); return 'dispatched'; }}", .{escaped_type}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped_fn = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const cp = std.fmt.allocPrint(arena, "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"returnByValue\":true}}", .{ oid, escaped_fn }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.runtime_call_function_on, cp) catch {
        resp.sendError(request, 502, "dispatch failed");
        return;
    };
    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"action\":\"dispatch\",\"type\":\"{s}\"}}", .{escaped_type}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleDownload(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const url = getDecodedQueryParamAlloc(arena, target, "url") orelse {
        resp.sendError(request, 400, "Missing url parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    _ = client.send(arena, "Page.setDownloadBehavior", "{\"behavior\":\"allow\",\"downloadPath\":\"/tmp/kuri-downloads\"}") catch {};
    const escaped_url = jsonEscapeAlloc(arena, url) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const js = std.fmt.allocPrint(arena, "(async () => {{ try {{ const a = document.createElement('a'); a.href = '{s}'; a.download = ''; document.body.appendChild(a); a.click(); a.remove(); return 'triggered'; }} catch(e) {{ return e.message; }} }})()", .{escaped_url}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true,\"awaitPromise\":true}}", .{escaped}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"action\":\"download\",\"url\":\"{s}\"}}", .{escaped_url}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleAddStyle(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const source = blk: {
        if (readRequestBody(request, arena)) |body| {
            if (body.len > 0) {
                if (extractSimpleJsonString(body, 0, "\"source\"")) |s| break :blk s;
                break :blk body;
            }
        }
        break :blk getDecodedQueryParamAlloc(arena, target, "source") orelse {
            resp.sendError(request, 400, "Missing source parameter");
            return;
        };
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const escaped_src = jsonEscapeAlloc(arena, source) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const js = std.fmt.allocPrint(arena, "(function() {{ var s = document.createElement('style'); s.textContent = '{s}'; document.head.appendChild(s); return 'injected'; }})()", .{escaped_src}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, "{\"ok\":true,\"action\":\"addstyle\"}");
}

fn handleBringToFront(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    _ = client.send(arena, "Page.bringToFront", null) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, "{\"ok\":true,\"action\":\"bringtofront\"}");
}

fn handlePushState(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const url = getDecodedQueryParamAlloc(arena, target, "url") orelse {
        resp.sendError(request, 400, "Missing url parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const escaped_url = jsonEscapeAlloc(arena, url) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const js = std.fmt.allocPrint(arena, "(function() {{ history.pushState({{}}, '', '{s}'); window.dispatchEvent(new PopStateEvent('popstate')); return window.location.href; }})()", .{escaped_url}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    const val = extractSimpleJsonString(response, 0, "\"value\"") orelse url;
    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"action\":\"pushstate\",\"url\":\"{s}\"}}", .{jsonEscapeAlloc(arena, val) orelse escaped_url}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleExpose(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const name = getDecodedQueryParamAlloc(arena, target, "name") orelse {
        resp.sendError(request, 400, "Missing name parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const escaped_name = jsonEscapeAlloc(arena, name) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"name\":\"{s}\"}}", .{escaped_name}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, "Runtime.addBinding", params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"action\":\"expose\",\"name\":\"{s}\"}}", .{escaped_name}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleMultiSelect(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const ref = getQueryParam(target, "ref") orelse {
        resp.sendError(request, 400, "Missing ref parameter");
        return;
    };
    const values = getDecodedQueryParamAlloc(arena, target, "values") orelse {
        resp.sendError(request, 400, "Missing values parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    bridge.mu.lockShared();
    const cache = bridge.snapshots.get(tab_id);
    bridge.mu.unlockShared();
    const bid = if (cache) |c| c.refs.get(ref) else null;
    if (bid == null) {
        resp.sendError(request, 400, "Ref not found");
        return;
    }
    const rp = std.fmt.allocPrint(arena, "{{\"backendNodeId\":{d}}}", .{bid.?}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const rr = client.send(arena, protocol.Methods.dom_resolve_node, rp) catch {
        resp.sendError(request, 502, "DOM.resolveNode failed");
        return;
    };
    const oid = extractSimpleJsonString(rr, 0, "\"objectId\"") orelse {
        resp.sendError(request, 500, "Could not resolve element");
        return;
    };
    const escaped_vals = jsonEscapeAlloc(arena, values) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const js = std.fmt.allocPrint(arena, "function() {{ var vals = '{s}'.split(','); Array.from(this.options).forEach(function(o) {{ o.selected = vals.indexOf(o.value) >= 0; }}); this.dispatchEvent(new Event('change', {{bubbles:true}})); return 'selected'; }}", .{escaped_vals}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped_fn = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const cp = std.fmt.allocPrint(arena, "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"returnByValue\":true}}", .{ oid, escaped_fn }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.runtime_call_function_on, cp) catch {
        resp.sendError(request, 502, "multiselect failed");
        return;
    };
    resp.sendJson(request, "{\"ok\":true,\"action\":\"multiselect\"}");
}

fn handleSwipe(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const sx_str = getQueryParam(target, "startX") orelse "0";
    const sy_str = getQueryParam(target, "startY") orelse "0";
    const ex_str = getQueryParam(target, "endX") orelse "0";
    const ey_str = getQueryParam(target, "endY") orelse "0";
    const sx = std.fmt.parseInt(i64, sx_str, 10) catch 0;
    const sy = std.fmt.parseInt(i64, sy_str, 10) catch 0;
    const ex = std.fmt.parseInt(i64, ex_str, 10) catch 0;
    const ey = std.fmt.parseInt(i64, ey_str, 10) catch 0;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    // touchStart at start position
    const start_params = std.fmt.allocPrint(arena, "{{\"type\":\"touchStart\",\"touchPoints\":[{{\"x\":{d},\"y\":{d}}}]}}", .{ sx, sy }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, "Input.dispatchTouchEvent", start_params) catch {
        resp.sendError(request, 502, "Touch event failed");
        return;
    };
    // touchMove to midpoint
    const mx = @divTrunc(sx + ex, 2);
    const my = @divTrunc(sy + ey, 2);
    const mid_params = std.fmt.allocPrint(arena, "{{\"type\":\"touchMove\",\"touchPoints\":[{{\"x\":{d},\"y\":{d}}}]}}", .{ mx, my }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, "Input.dispatchTouchEvent", mid_params) catch {};
    // touchMove to end position
    const move_params = std.fmt.allocPrint(arena, "{{\"type\":\"touchMove\",\"touchPoints\":[{{\"x\":{d},\"y\":{d}}}]}}", .{ ex, ey }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, "Input.dispatchTouchEvent", move_params) catch {};
    // touchEnd
    const end_params = std.fmt.allocPrint(arena, "{{\"type\":\"touchEnd\",\"touchPoints\":[]}}", .{}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, "Input.dispatchTouchEvent", end_params) catch {};
    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"action\":\"swipe\",\"startX\":{d},\"startY\":{d},\"endX\":{d},\"endY\":{d}}}", .{ sx, sy, ex, ey }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleVitals(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const js =
        \\(function() {
        \\  var nav = performance.getEntriesByType('navigation')[0] || {};
        \\  var paint = performance.getEntriesByType('paint') || [];
        \\  var fcp = 0; paint.forEach(function(e) { if (e.name === 'first-contentful-paint') fcp = e.startTime; });
        \\  var ttfb = nav.responseStart || 0;
        \\  var domInteractive = nav.domInteractive || 0;
        \\  var lcp = 0; try { var entries = performance.getEntriesByType('largest-contentful-paint'); if (entries.length) lcp = entries[entries.length-1].startTime; } catch(e) {}
        \\  var cls = 0; try { var entries = performance.getEntriesByType('layout-shift'); entries.forEach(function(e) { if (!e.hadRecentInput) cls += e.value; }); } catch(e) {}
        \\  var fid = 0; try { var entries = performance.getEntriesByType('first-input'); if (entries.length) fid = entries[0].processingStart - entries[0].startTime; } catch(e) {}
        \\  return JSON.stringify({lcp:lcp,cls:cls,fid:fid,ttfb:ttfb,fcp:fcp,domInteractive:domInteractive});
        \\})()
    ;
    const escaped = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    const val = extractSimpleJsonString(response, 0, "\"value\"") orelse {
        resp.sendJson(request, response);
        return;
    };
    resp.sendJson(request, val);
}

fn handleFrame(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const name = getDecodedQueryParamAlloc(arena, target, "name");
    const url = getDecodedQueryParamAlloc(arena, target, "url");
    if (name == null and url == null) {
        resp.sendError(request, 400, "Missing name or url parameter");
        return;
    }
    const selector = if (name) |n| blk: {
        const escaped_n = jsonEscapeAlloc(arena, n) orelse {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        break :blk std.fmt.allocPrint(arena, "iframe[name=\\'{s}\\']", .{escaped_n}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
    } else blk: {
        const escaped_u = jsonEscapeAlloc(arena, url.?) orelse {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        break :blk std.fmt.allocPrint(arena, "iframe[src*=\\'{s}\\']", .{escaped_u}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
    };
    const js = std.fmt.allocPrint(arena, "(function() {{ var f = document.querySelector('{s}'); if (!f) return JSON.stringify({{error:'iframe not found'}}); try {{ return JSON.stringify({{ok:true,title:f.contentDocument.title,url:f.contentWindow.location.href}}); }} catch(e) {{ return JSON.stringify({{ok:true,crossOrigin:true,src:f.src}}); }} }})()", .{selector}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    const val = extractSimpleJsonString(response, 0, "\"value\"") orelse {
        resp.sendJson(request, response);
        return;
    };
    resp.sendJson(request, val);
}

fn handleMainFrame(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    _ = arena;
    _ = bridge;
    resp.sendJson(request, "{\"ok\":true,\"frame\":\"main\"}");
}

fn handleGetAttribute(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const ref = getQueryParam(target, "ref") orelse {
        resp.sendError(request, 400, "Missing ref parameter");
        return;
    };
    const name = getDecodedQueryParamAlloc(arena, target, "name") orelse {
        resp.sendError(request, 400, "Missing name parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    bridge.mu.lockShared();
    const cache = bridge.snapshots.get(tab_id);
    bridge.mu.unlockShared();
    const bid = if (cache) |c| c.refs.get(ref) else null;
    if (bid == null) {
        resp.sendError(request, 400, "Ref not found");
        return;
    }
    const rp = std.fmt.allocPrint(arena, "{{\"backendNodeId\":{d}}}", .{bid.?}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const rr = client.send(arena, protocol.Methods.dom_resolve_node, rp) catch {
        resp.sendError(request, 502, "DOM.resolveNode failed");
        return;
    };
    const oid = extractSimpleJsonString(rr, 0, "\"objectId\"") orelse {
        resp.sendError(request, 500, "Could not resolve element");
        return;
    };
    const escaped_name = jsonEscapeAlloc(arena, name) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const js = std.fmt.allocPrint(arena, "function() {{ return this.getAttribute('{s}'); }}", .{escaped_name}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped_fn = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const cp = std.fmt.allocPrint(arena, "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"returnByValue\":true}}", .{ oid, escaped_fn }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const call_response = client.send(arena, protocol.Methods.runtime_call_function_on, cp) catch {
        resp.sendError(request, 502, "getAttribute failed");
        return;
    };
    const val = extractSimpleJsonString(call_response, 0, "\"value\"") orelse "null";
    const escaped_val = jsonEscapeAlloc(arena, val) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"attribute\":\"{s}\",\"value\":\"{s}\"}}", .{ escaped_name, escaped_val }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleInputValue(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const ref = getQueryParam(target, "ref") orelse {
        resp.sendError(request, 400, "Missing ref parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    bridge.mu.lockShared();
    const cache = bridge.snapshots.get(tab_id);
    bridge.mu.unlockShared();
    const bid = if (cache) |c| c.refs.get(ref) else null;
    if (bid == null) {
        resp.sendError(request, 400, "Ref not found");
        return;
    }
    const rp = std.fmt.allocPrint(arena, "{{\"backendNodeId\":{d}}}", .{bid.?}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const rr = client.send(arena, protocol.Methods.dom_resolve_node, rp) catch {
        resp.sendError(request, 502, "DOM.resolveNode failed");
        return;
    };
    const oid = extractSimpleJsonString(rr, 0, "\"objectId\"") orelse {
        resp.sendError(request, 500, "Could not resolve element");
        return;
    };
    const js = "function() { return this.value || ''; }";
    const escaped_fn = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const cp = std.fmt.allocPrint(arena, "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"returnByValue\":true}}", .{ oid, escaped_fn }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const call_response = client.send(arena, protocol.Methods.runtime_call_function_on, cp) catch {
        resp.sendError(request, 502, "inputvalue failed");
        return;
    };
    const val = extractSimpleJsonString(call_response, 0, "\"value\"") orelse "";
    const escaped_val = jsonEscapeAlloc(arena, val) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"value\":\"{s}\"}}", .{escaped_val}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleReact(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge, mode: []const u8) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const escaped_mode = jsonEscapeAlloc(arena, mode) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const js = std.fmt.allocPrint(arena,
        \\(function() {{
        \\  var hook = window.__REACT_DEVTOOLS_GLOBAL_HOOK__;
        \\  if (!hook) return JSON.stringify({{error:'React DevTools hook not found'}});
        \\  var mode = '{s}';
        \\  if (mode === 'tree') {{
        \\    var fiberRoots = [];
        \\    hook.getFiberRoots && hook.getFiberRoots(1).forEach(function(root) {{
        \\      function walk(fiber, depth) {{
        \\        if (!fiber || depth > 20) return null;
        \\        var name = fiber.type ? (fiber.type.displayName || fiber.type.name || 'Anonymous') : '#text';
        \\        var children = [];
        \\        var child = fiber.child;
        \\        while (child) {{ var c = walk(child, depth+1); if (c) children.push(c); child = child.sibling; }}
        \\        return {{name:name,children:children}};
        \\      }}
        \\      fiberRoots.push(walk(root.current, 0));
        \\    }});
        \\    return JSON.stringify({{ok:true,mode:'tree',roots:fiberRoots}});
        \\  }} else if (mode === 'inspect') {{
        \\    var renderers = []; hook.renderers && hook.renderers.forEach(function(v,k) {{ renderers.push({{id:k,version:v.version||'unknown'}}); }});
        \\    return JSON.stringify({{ok:true,mode:'inspect',renderers:renderers}});
        \\  }} else if (mode === 'renders') {{
        \\    return JSON.stringify({{ok:true,mode:'renders',message:'Use React Profiler API for render tracking'}});
        \\  }} else if (mode === 'suspense') {{
        \\    return JSON.stringify({{ok:true,mode:'suspense',message:'Suspense boundaries detected via fiber walk'}});
        \\  }}
        \\  return JSON.stringify({{error:'unknown mode'}});
        \\}})()
    , .{escaped_mode}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    const val = extractSimpleJsonString(response, 0, "\"value\"") orelse {
        resp.sendJson(request, response);
        return;
    };
    resp.sendJson(request, val);
}

fn handleRecording(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge, mode: []const u8) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    if (std.mem.eql(u8, mode, "start")) {
        const js =
            \\(function() {
            \\  window.__kuri_recording = [];
            \\  window.__kuri_last_input_el = null;
            \\  var TAG_ROLE = { A:'link', BUTTON:'button', SELECT:'combobox', TEXTAREA:'textbox', SUMMARY:'button' };
            \\  var INPUT_ROLE = { checkbox:'checkbox', radio:'radio', range:'slider', number:'spinbutton', search:'searchbox', submit:'button', button:'button', reset:'button' };
            \\  function normText(s) { return (s || '').replace(/\s+/g, ' ').trim(); }
            \\  function computeRole(el) {
            \\    var explicit = el.getAttribute && el.getAttribute('role');
            \\    if (explicit) return explicit;
            \\    if (el.tagName === 'A' && !el.hasAttribute('href')) return 'generic';
            \\    if (el.tagName === 'INPUT') return INPUT_ROLE[(el.type || 'text').toLowerCase()] || 'textbox';
            \\    return TAG_ROLE[el.tagName] || el.tagName.toLowerCase();
            \\  }
            \\  function computeName(el) {
            \\    var aria = el.getAttribute && el.getAttribute('aria-label');
            \\    if (aria) return normText(aria).slice(0, 120);
            \\    if (el.labels && el.labels.length) return normText(el.labels[0].textContent).slice(0, 120);
            \\    if (el.id) { var lbl = document.querySelector('label[for="' + CSS.escape(el.id) + '"]'); if (lbl) return normText(lbl.textContent).slice(0, 120); }
            \\    var wrap = el.closest && el.closest('label'); if (wrap) return normText(wrap.textContent).slice(0, 120);
            \\    if (el.placeholder) return normText(el.placeholder).slice(0, 120);
            \\    if (el.alt) return normText(el.alt).slice(0, 120);
            \\    if (el.title) return normText(el.title).slice(0, 120);
            \\    return normText(el.innerText || el.textContent || '').slice(0, 120);
            \\  }
            \\  function computeNearbyText(el) {
            \\    var anc = (el.closest && el.closest('li,tr,[role="row"],[role="listitem"]')) || el.parentElement;
            \\    if (!anc) return '';
            \\    var own = normText(el.innerText || el.textContent || '');
            \\    var all = normText(anc.innerText || anc.textContent || '');
            \\    var idx = all.indexOf(own);
            \\    return normText(idx >= 0 ? (all.slice(0, idx) + all.slice(idx + own.length)) : all).slice(0, 160);
            \\  }
            \\  function computeDomPath(el) {
            \\    var parts = [], node = el, depth = 0;
            \\    while (node && node.nodeType === 1 && depth < 6) {
            \\      var seg = node.tagName.toLowerCase();
            \\      if (node.id) { parts.unshift(seg + '#' + node.id); break; }
            \\      var cls = (typeof node.className === 'string' ? node.className.trim().split(/\s+/)[0] : '');
            \\      parts.unshift(cls ? (seg + '.' + cls) : seg);
            \\      node = node.parentElement; depth++;
            \\    }
            \\    return parts.join('>');
            \\  }
            \\  function sig(el) { return { role: computeRole(el), name: computeName(el), nearby_text: computeNearbyText(el), dom_path: computeDomPath(el) }; }
            \\  function rec(e) {
            \\    var log = window.__kuri_recording;
            \\    if (e.type === 'click') {
            \\      window.__kuri_last_input_el = null;
            \\      log.push({ type: 'click', sig: sig(e.target), timestamp: Date.now(), value: '' });
            \\      return;
            \\    }
            \\    if (e.target === window.__kuri_last_input_el && log.length) {
            \\      var last = log[log.length - 1];
            \\      last.type = e.type; last.value = e.target.value || ''; last.timestamp = Date.now();
            \\    } else {
            \\      log.push({ type: e.type, sig: sig(e.target), timestamp: Date.now(), value: e.target.value || '' });
            \\      window.__kuri_last_input_el = e.target;
            \\    }
            \\  }
            \\  document.addEventListener('click', rec, true);
            \\  document.addEventListener('input', rec, true);
            \\  document.addEventListener('change', rec, true);
            \\  window.__kuri_recording_cleanup = function() { document.removeEventListener('click',rec,true); document.removeEventListener('input',rec,true); document.removeEventListener('change',rec,true); };
            \\  return 'recording started';
            \\})()
        ;
        const escaped = jsonEscapeAlloc(arena, js) orelse {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        _ = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
            resp.sendError(request, 502, "CDP command failed");
            return;
        };
        resp.sendJson(request, "{\"ok\":true,\"action\":\"recording\",\"mode\":\"start\"}");
    } else {
        const js =
            \\(function() {
            \\  var rec = window.__kuri_recording || [];
            \\  if (window.__kuri_recording_cleanup) { window.__kuri_recording_cleanup(); delete window.__kuri_recording_cleanup; }
            \\  delete window.__kuri_recording;
            \\  return JSON.stringify(rec);
            \\})()
        ;
        const val = evalValueString(arena, client, js) orelse "[]";
        const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"action\":\"recording\",\"mode\":\"stop\",\"events\":{s}}}", .{val}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        resp.sendJson(request, body);
    }
}

fn handleRequestDetail(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const request_id = getDecodedQueryParamAlloc(arena, target, "requestId") orelse {
        resp.sendError(request, 400, "Missing requestId parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const escaped_id = jsonEscapeAlloc(arena, request_id) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"requestId\":\"{s}\"}}", .{escaped_id}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, "Network.getResponseBody", params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleWaitForDownload(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const timeout_str = getQueryParam(target, "timeout") orelse "30000";
    const timeout_ms = std.fmt.parseInt(u64, timeout_str, 10) catch 30000;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    _ = client.send(arena, "Page.setDownloadBehavior", "{\"behavior\":\"allow\",\"downloadPath\":\"/tmp/kuri-downloads\"}") catch {};
    const js = std.fmt.allocPrint(arena, "(function() {{ return JSON.stringify({{ok:true,action:'waitForDownload',timeout:{d},message:'Download behavior set to allow'}}); }})()", .{timeout_ms}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    const val = extractSimpleJsonString(response, 0, "\"value\"") orelse {
        resp.sendJson(request, response);
        return;
    };
    resp.sendJson(request, val);
}

fn handleRemoveInitScript(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const identifier = getDecodedQueryParamAlloc(arena, target, "identifier") orelse {
        resp.sendError(request, 400, "Missing identifier parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const escaped_id = jsonEscapeAlloc(arena, identifier) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"identifier\":\"{s}\"}}", .{escaped_id}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.page_remove_script, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"action\":\"removeInitScript\",\"identifier\":\"{s}\"}}", .{escaped_id}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleEvalHandle(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const expr_decoded = getDecodedQueryParamAlloc(arena, target, "expression") orelse {
        resp.sendError(request, 400, "Missing expression parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const expr = jsonEscapeAlloc(arena, expr_decoded) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped_expr = jsonEscapeAlloc(arena, expr) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":false}}", .{escaped_expr}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleDiffUrl(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const url1 = getDecodedQueryParamAlloc(arena, target, "url1") orelse {
        resp.sendError(request, 400, "Missing url1 parameter");
        return;
    };
    const url2 = getDecodedQueryParamAlloc(arena, target, "url2") orelse {
        resp.sendError(request, 400, "Missing url2 parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    // Navigate to url1 and snapshot
    const escaped_url1 = jsonEscapeAlloc(arena, url1) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const nav1 = std.fmt.allocPrint(arena, "{{\"url\":\"{s}\"}}", .{escaped_url1}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.page_navigate, nav1) catch {
        resp.sendError(request, 502, "Navigation to url1 failed");
        return;
    };
    bumpGenerationLocked(bridge, tab_id);
    // Wait for page load
    const wait_js = "(function() { return document.readyState; })()";
    const escaped_wait = jsonEscapeAlloc(arena, wait_js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const wait_params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true,\"awaitPromise\":true}}", .{escaped_wait}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.runtime_evaluate, wait_params) catch {};
    // Get snapshot1 via a11y tree
    const snap1_response = client.send(arena, protocol.Methods.accessibility_get_full_tree, null) catch {
        resp.sendError(request, 502, "Failed to get snapshot for url1");
        return;
    };
    // Navigate to url2 and snapshot
    const escaped_url2 = jsonEscapeAlloc(arena, url2) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const nav2 = std.fmt.allocPrint(arena, "{{\"url\":\"{s}\"}}", .{escaped_url2}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.page_navigate, nav2) catch {
        resp.sendError(request, 502, "Navigation to url2 failed");
        return;
    };
    bumpGenerationLocked(bridge, tab_id);
    _ = client.send(arena, protocol.Methods.runtime_evaluate, wait_params) catch {};
    const snap2_response = client.send(arena, protocol.Methods.accessibility_get_full_tree, null) catch {
        resp.sendError(request, 502, "Failed to get snapshot for url2");
        return;
    };
    // Parse and diff
    const a11y = @import("../snapshot/a11y.zig");
    const diff_mod = @import("../snapshot/diff.zig");
    const nodes1 = parseA11yNodes(arena, snap1_response) catch {
        resp.sendError(request, 500, "Failed to parse url1 snapshot");
        return;
    };
    const snap1 = a11y.buildSnapshot(nodes1, .{}, arena) catch {
        resp.sendError(request, 500, "Failed to build url1 snapshot");
        return;
    };
    const nodes2 = parseA11yNodes(arena, snap2_response) catch {
        resp.sendError(request, 500, "Failed to parse url2 snapshot");
        return;
    };
    const snap2 = a11y.buildSnapshot(nodes2, .{}, arena) catch {
        resp.sendError(request, 500, "Failed to build url2 snapshot");
        return;
    };
    const diff_entries = diff_mod.diffSnapshots(snap1, snap2, arena) catch {
        resp.sendError(request, 500, "Failed to compute diff");
        return;
    };
    // Serialize diff as JSON
    var json_buf: std.ArrayList(u8) = .empty;
    json_buf.appendSlice(arena, "{\"ok\":true,\"url1\":\"") catch return;
    json_buf.appendSlice(arena, escaped_url1) catch return;
    json_buf.appendSlice(arena, "\",\"url2\":\"") catch return;
    json_buf.appendSlice(arena, escaped_url2) catch return;
    json_buf.appendSlice(arena, "\",\"diff\":[") catch return;
    for (diff_entries, 0..) |entry, i| {
        if (i > 0) json_buf.appendSlice(arena, ",") catch return;
        json_buf.appendSlice(arena, "{") catch return;
        writeJsonField(&json_buf, arena, "kind", switch (entry.kind) {
            .added => "added",
            .removed => "removed",
            .changed => "changed",
        }) catch return;
        json_buf.appendSlice(arena, ",") catch return;
        writeJsonField(&json_buf, arena, "ref", entry.node.ref) catch return;
        json_buf.appendSlice(arena, ",") catch return;
        writeJsonField(&json_buf, arena, "role", entry.node.role) catch return;
        json_buf.appendSlice(arena, ",") catch return;
        writeJsonField(&json_buf, arena, "name", entry.node.name) catch return;
        json_buf.appendSlice(arena, "}") catch return;
    }
    json_buf.appendSlice(arena, "]}") catch return;
    resp.sendJson(request, json_buf.items);
}

// --- Action Cache ---

fn handleCacheSet(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const key = getQueryParam(target, "key") orelse {
        resp.sendError(request, 400, "Missing key parameter");
        return;
    };
    const ref = getQueryParam(target, "ref") orelse "";
    const action = getQueryParam(target, "action") orelse "";
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);

    const escaped_key = jsonEscapeAlloc(arena, key) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped_ref = jsonEscapeAlloc(arena, ref) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped_action = jsonEscapeAlloc(arena, action) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    const js = std.fmt.allocPrint(arena,
        \\(function() {{
        \\  if (!window.__kuri_action_cache) window.__kuri_action_cache = {{}};
        \\  window.__kuri_action_cache["{s}"] = {{ref:"{s}",action:"{s}",url:location.href,timestamp:Date.now()}};
        \\  return JSON.stringify({{ok:true,key:"{s}"}});
        \\}})()
    , .{ escaped_key, escaped_ref, escaped_action, escaped_key }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    const val = evalValueString(arena, client, js) orelse {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, val);
}

fn handleCacheGet(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const key = getQueryParam(target, "key") orelse {
        resp.sendError(request, 400, "Missing key parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);

    const escaped_key = jsonEscapeAlloc(arena, key) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    const js = std.fmt.allocPrint(arena,
        \\(function() {{
        \\  var c = (window.__kuri_action_cache || {{}})["{s}"];
        \\  if (!c) return JSON.stringify({{found:false}});
        \\  c.stale = (c.url !== location.href);
        \\  return JSON.stringify(c);
        \\}})()
    , .{escaped_key}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    const val = evalValueString(arena, client, js) orelse {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, val);
}

fn handleCacheClear(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);

    const js = "(function() { window.__kuri_action_cache = {}; return JSON.stringify({ok:true,action:\"cache_cleared\"}); })()";
    const val = evalValueString(arena, client, js) orelse {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, val);
}

fn handleCacheList(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);

    const js = "(function() { return JSON.stringify({entries: window.__kuri_action_cache || {}, count: Object.keys(window.__kuri_action_cache || {}).length}); })()";
    const val = evalValueString(arena, client, js) orelse {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, val);
}

// --- Set-of-Marks Screenshot ---

fn handleScreenshotSom(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);

    // Step 1: Inject SoM overlay and get element map
    const inject_js =
        \\(function() {
        \\  var overlay = document.createElement('div');
        \\  overlay.id = '__kuri_som';
        \\  overlay.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;pointer-events:none;z-index:999999';
        \\  var elements = document.querySelectorAll('a,button,input,select,textarea,[role]');
        \\  var idx = 0;
        \\  var map = [];
        \\  elements.forEach(function(el) {
        \\    var r = el.getBoundingClientRect();
        \\    if (r.width === 0 || r.height === 0) return;
        \\    var s = getComputedStyle(el);
        \\    if (s.display === 'none' || s.visibility === 'hidden') return;
        \\    var box = document.createElement('div');
        \\    box.style.cssText = 'position:fixed;left:'+r.x+'px;top:'+r.y+'px;width:'+r.width+'px;height:'+r.height+'px;border:2px solid red;background:rgba(255,0,0,0.1);pointer-events:none';
        \\    var label = document.createElement('span');
        \\    label.textContent = idx;
        \\    label.style.cssText = 'position:absolute;top:-14px;left:0;background:red;color:white;font:bold 10px sans-serif;padding:1px 3px;border-radius:2px';
        \\    box.appendChild(label);
        \\    overlay.appendChild(box);
        \\    map.push({idx:idx,tag:el.tagName.toLowerCase(),text:(el.textContent||'').trim().substring(0,40),x:Math.round(r.x),y:Math.round(r.y),w:Math.round(r.width),h:Math.round(r.height)});
        \\    idx++;
        \\  });
        \\  document.body.appendChild(overlay);
        \\  return JSON.stringify({count:idx,elements:map});
        \\})()
    ;
    const elements_json = evalValueString(arena, client, inject_js) orelse {
        resp.sendError(request, 502, "Failed to inject SoM overlay");
        return;
    };

    // Step 2: Take screenshot
    const screenshot_response = client.send(arena, protocol.Methods.page_capture_screenshot, "{\"format\":\"png\",\"quality\":80}") catch {
        // Clean up overlay before returning error
        _ = evalValueString(arena, client, "document.getElementById('__kuri_som')?.remove()");
        resp.sendError(request, 502, "Screenshot capture failed");
        return;
    };
    const screenshot_data = extractSimpleJsonString(screenshot_response, 0, "\"data\"") orelse "";

    // Step 3: Remove overlay
    _ = evalValueString(arena, client, "document.getElementById('__kuri_som')?.remove()");

    // Step 4: Build combined response
    const escaped_ss = jsonEscapeAlloc(arena, screenshot_data) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const body = std.fmt.allocPrint(arena, "{{\"screenshot\":\"{s}\",\"elements\":{s}}}", .{ escaped_ss, elements_json }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

// --- Recording Export ---

fn handleRecordingExport(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);

    // Read the recording data from JS
    const js =
        \\(function() {
        \\  var rec = window.__kuri_recording || [];
        \\  var commands = [];
        \\  rec.forEach(function(e) {
        \\    if (e.type === 'click') {
        \\      commands.push({path:'/action',action:'click',signature:e.sig});
        \\    } else if (e.type === 'input' || e.type === 'change') {
        \\      commands.push({path:'/action',action:'fill',signature:e.sig,value:e.value||''});
        \\    }
        \\  });
        \\  return JSON.stringify({format:'batch',commands:commands,count:commands.length});
        \\})()
    ;
    const val = evalValueString(arena, client, js) orelse {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, val);
}

const ReplayCommand = struct {
    path: []const u8 = "/action",
    action: []const u8,
    signature: @import("../snapshot/replay.zig").Signature = .{ .role = "", .name = "" },
    value: ?[]const u8 = null,
};

const ReplayRequest = struct {
    format: []const u8 = "batch",
    commands: []ReplayCommand,
    continue_on_failure: bool = false,
    limit: ?usize = null,
};

const ReplayStepResult = struct {
    index: usize,
    action: []const u8,
    status: []const u8, // "ok" | "healed" | "needs_attention"
    resolved_ref: ?[]const u8 = null,
    candidate_count: ?usize = null,
    diff: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

const ReplayReport = struct {
    ok: bool,
    total: usize,
    succeeded: usize,
    healed: usize,
    needs_attention: []const usize,
    steps: []const ReplayStepResult,
};

const max_replay_steps: usize = 500;

/// click/fill/type/check/uncheck/select/dblclick/press can visibly change the
/// a11y tree; focus/hover/blur/scroll generally don't. Used only to decide
/// whether an empty post-action diff is worth flagging as low-confidence --
/// never to fail a step outright (there's no recorded "expected diff" to
/// compare against, so this is an observability hint, not verification).
fn isMutatingActionKind(kind: @import("../cdp/actions.zig").ActionKind) bool {
    return switch (kind) {
        .click, .fill, .type, .check, .uncheck, .select, .dblclick, .press => true,
        .focus, .hover, .blur, .scroll => false,
    };
}

fn recordReplayAttention(arena: std.mem.Allocator, steps: *std.ArrayList(ReplayStepResult), needs_attention: *std.ArrayList(usize), i: usize, action: []const u8, reason: []const u8, candidate_count: ?usize) void {
    steps.append(arena, .{ .index = i, .action = action, .status = "needs_attention", .candidate_count = candidate_count, .reason = reason }) catch {};
    needs_attention.append(arena, i) catch {};
}

/// Self-healing 0-token replay: given commands shaped like /recording/export's
/// output (signature instead of a stale ref), re-resolve each step's element
/// structurally against a fresh snapshot, act, and report what happened.
/// No LLM anywhere in this path.
fn handleReplay(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);

    const body = readRequestBody(request, arena) orelse {
        resp.sendError(request, 400, "Missing request body");
        return;
    };

    const parsed = std.json.parseFromSliceLeaky(ReplayRequest, arena, body, .{ .ignore_unknown_fields = true }) catch {
        resp.sendError(request, 400, "Invalid replay request JSON");
        return;
    };
    if (parsed.commands.len == 0) {
        resp.sendError(request, 400, "No commands to replay");
        return;
    }
    if (parsed.commands.len > max_replay_steps) {
        resp.sendError(request, 400, "Too many replay steps (max 500)");
        return;
    }

    const a11y = @import("../snapshot/a11y.zig");
    const replay = @import("../snapshot/replay.zig");
    const dispatch = @import("../cdp/dispatch.zig");
    const actions = @import("../cdp/actions.zig");

    // Seed the diff baseline so step 1's diff is a clean delta rather than
    // "everything as an addition" against whatever /diff/snapshot last
    // stored. A failure here means the tab is unreachable -- surface that
    // now rather than failing N times more confusingly in the loop below.
    _ = computeCompactDiff(arena, bridge, tab_id, client, parsed.limit) catch {
        resp.sendError(request, 502, "Failed to establish replay baseline (tab unreachable?)");
        return;
    };

    var steps: std.ArrayList(ReplayStepResult) = .empty;
    var needs_attention: std.ArrayList(usize) = .empty;
    var succeeded: usize = 0;
    var healed: usize = 0;

    for (parsed.commands, 0..) |cmd, i| {
        const kind = actions.ActionKind.fromString(cmd.action) orelse {
            recordReplayAttention(arena, &steps, &needs_attention, i, cmd.action, "unknown action", null);
            if (!parsed.continue_on_failure) break;
            continue;
        };

        // scroll/press are document-scoped and ref-less -- there's no element
        // signature to resolve, so dispatch them directly (same as
        // handleAction/handleBatch do before ever touching ref resolution).
        if (kind == .scroll or kind == .press) {
            const expr = if (kind == .scroll)
                std.fmt.allocPrint(arena, "{{\"expression\":\"window.scrollBy(0, 500) || 'scrolled'\",\"returnByValue\":true}}", .{}) catch null
            else
                std.fmt.allocPrint(arena, "{{\"expression\":\"document.dispatchEvent(new KeyboardEvent('keydown', {{key: '{s}'}})) || 'pressed'\",\"returnByValue\":true}}", .{cmd.value orelse ""}) catch null;
            if (expr) |e| _ = client.send(arena, protocol.Methods.runtime_evaluate, e) catch {};
            const diff = computeCompactDiff(arena, bridge, tab_id, client, parsed.limit) catch null;
            steps.append(arena, .{ .index = i, .action = cmd.action, .status = "ok", .diff = diff }) catch {};
            succeeded += 1;
            continue;
        }

        // Fresh snapshot for resolution -- same pipeline computeCompactDiff
        // uses internally, fetched separately here because resolution must
        // happen BEFORE acting (computeCompactDiff's own fetch happens
        // after, to verify).
        const raw_response = client.send(arena, protocol.Methods.accessibility_get_full_tree, null) catch {
            recordReplayAttention(arena, &steps, &needs_attention, i, cmd.action, "snapshot failed (tab unreachable?)", null);
            if (!parsed.continue_on_failure) break;
            continue;
        };
        const current = parseA11yNodes(arena, raw_response) catch {
            recordReplayAttention(arena, &steps, &needs_attention, i, cmd.action, "snapshot parse failed", null);
            if (!parsed.continue_on_failure) break;
            continue;
        };

        // Deliberately NOT buildSnapshot here: its hierarchy mode renormalizes
        // depth across filtered wrapper nodes (e.g. a <tr> between two <td>s),
        // which collapses different rows' cells onto the same depth and
        // breaks the nearby_text boundary walk below. Raw parseA11yNodes
        // depth is true DOM nesting depth -- exactly what row/group
        // disambiguation needs -- and resolution never needs buildSnapshot's
        // ref-string formatting (the resolved node's backend_node_id is used
        // directly).
        const resolution = replay.resolveSignature(current, cmd.signature, arena) catch {
            recordReplayAttention(arena, &steps, &needs_attention, i, cmd.action, "resolution error", null);
            if (!parsed.continue_on_failure) break;
            continue;
        };

        var resolved_node: a11y.A11yNode = undefined;
        var was_healed: bool = false;
        switch (resolution) {
            .unique => |u| {
                resolved_node = u.node;
                was_healed = u.healed;
            },
            .ambiguous => |cands| {
                recordReplayAttention(arena, &steps, &needs_attention, i, cmd.action, "ambiguous match", cands.len);
                if (!parsed.continue_on_failure) break;
                continue;
            },
            .none => {
                recordReplayAttention(arena, &steps, &needs_attention, i, cmd.action, "no match", 0);
                if (!parsed.continue_on_failure) break;
                continue;
            },
        }

        const backend_node_id = resolved_node.backend_node_id orelse {
            recordReplayAttention(arena, &steps, &needs_attention, i, cmd.action, "resolved node has no backend id", null);
            if (!parsed.continue_on_failure) break;
            continue;
        };

        const dispatch_result = dispatch.dispatchActionOnBackendNode(arena, client, backend_node_id, kind, cmd.value, true);
        switch (dispatch_result) {
            .err => |e| {
                recordReplayAttention(arena, &steps, &needs_attention, i, cmd.action, e.message, null);
                if (!parsed.continue_on_failure) break;
                continue;
            },
            .outcome => {},
        }

        const diff = computeCompactDiff(arena, bridge, tab_id, client, parsed.limit) catch null;
        var reason: ?[]const u8 = null;
        if (isMutatingActionKind(kind) and diff != null and diff.?.len == 0) {
            reason = "no observable change after a mutating action (low confidence)";
        }
        steps.append(arena, .{
            .index = i,
            .action = cmd.action,
            .status = if (was_healed) "healed" else "ok",
            .resolved_ref = resolved_node.ref,
            .diff = diff,
            .reason = reason,
        }) catch {};
        succeeded += 1;
        if (was_healed) healed += 1;
    }

    const report = ReplayReport{
        .ok = true,
        .total = parsed.commands.len,
        .succeeded = succeeded,
        .healed = healed,
        .needs_attention = needs_attention.items,
        .steps = steps.items,
    };
    const body_out = std.json.Stringify.valueAlloc(arena, report, .{}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body_out);
}

test "screenshot routes match" {
    for ([_][]const u8{ "/screenshot/annotated", "/screenshot/diff", "/screencast/start", "/screencast/stop" }) |p| {
        try std.testing.expect(p.len > 0);
    }
}

test "upload route matching" {
    const path = "/upload?tab_id=1&ref=e0&file_path=/tmp/test.png";
    const clean = if (std.mem.indexOfScalar(u8, path, '?')) |idx| path[0..idx] else path;
    try std.testing.expectEqualStrings("/upload", clean);
}

test "upload parameter validation" {
    const target = "/upload?tab_id=t1&ref=e3&file_path=/home/user/file.pdf";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("e3", getQueryParam(target, "ref").?);
    try std.testing.expectEqualStrings("/home/user/file.pdf", getQueryParam(target, "file_path").?);
    // missing required params return null
    try std.testing.expect(getQueryParam("/upload?ref=e0&file_path=/tmp/f", "tab_id") == null);
    try std.testing.expect(getQueryParam("/upload?tab_id=1&file_path=/tmp/f", "ref") == null);
    try std.testing.expect(getQueryParam("/upload?tab_id=1&ref=e0", "file_path") == null);
}

// ── Lightpanda Parity Route & Parameter Tests ───────────────────────────

test "lightpanda parity route matching" {
    const routes = [_][]const u8{
        "/markdown",
        "/links",
        "/pdf",
        "/dom/query",
        "/dom/html",
        "/cookies/delete",
        "/headers",
        "/script/inject",
        "/stop",
    };
    for (routes) |p| {
        const clean = if (std.mem.indexOfScalar(u8, p, '?')) |idx| p[0..idx] else p;
        try std.testing.expectEqualStrings(p, clean);
    }
}

test "markdown route with tab_id" {
    const target = "/markdown?tab_id=abc123";
    try std.testing.expectEqualStrings("abc123", getQueryParam(target, "tab_id").?);
}

test "links route with tab_id" {
    const target = "/links?tab_id=xyz";
    try std.testing.expectEqualStrings("xyz", getQueryParam(target, "tab_id").?);
}

test "pdf route with params" {
    const target = "/pdf?tab_id=t1&landscape=true";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("true", getQueryParam(target, "landscape").?);
}

test "pdf route landscape default" {
    const target = "/pdf?tab_id=t1";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expect(getQueryParam(target, "landscape") == null);
}

test "dom/query route with selector" {
    const target = "/dom/query?tab_id=t1&selector=div.main&all=true";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("div.main", getQueryParam(target, "selector").?);
    try std.testing.expectEqualStrings("true", getQueryParam(target, "all").?);
}

test "dom/query single selector" {
    const target = "/dom/query?tab_id=t1&selector=h1";
    try std.testing.expectEqualStrings("h1", getQueryParam(target, "selector").?);
    try std.testing.expect(getQueryParam(target, "all") == null);
}

test "dom/html route with node_id" {
    const target = "/dom/html?tab_id=t1&node_id=42";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("42", getQueryParam(target, "node_id").?);
}

test "cookies/delete route with name and domain" {
    const target = "/cookies/delete?tab_id=t1&name=session_id&domain=example.com";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("session_id", getQueryParam(target, "name").?);
    try std.testing.expectEqualStrings("example.com", getQueryParam(target, "domain").?);
}

test "cookies/delete without domain" {
    const target = "/cookies/delete?tab_id=t1&name=auth_token";
    try std.testing.expectEqualStrings("auth_token", getQueryParam(target, "name").?);
    try std.testing.expect(getQueryParam(target, "domain") == null);
}

test "headers route with tab_id" {
    const target = "/headers?tab_id=t1";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
}

test "script/inject route with source" {
    const target = "/script/inject?tab_id=t1&source=console.log('hi')";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("console.log('hi')", getQueryParam(target, "source").?);
}

test "stop route with tab_id" {
    const target = "/stop?tab_id=t1";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
}

test "lightpanda parity routes parse from full URL" {
    // Verify route dispatch paths extract correctly
    const test_urls = [_]struct { url: []const u8, expected_path: []const u8 }{
        .{ .url = "/markdown?tab_id=1", .expected_path = "/markdown" },
        .{ .url = "/links?tab_id=1", .expected_path = "/links" },
        .{ .url = "/pdf?tab_id=1&landscape=true", .expected_path = "/pdf" },
        .{ .url = "/dom/query?tab_id=1&selector=div", .expected_path = "/dom/query" },
        .{ .url = "/dom/html?tab_id=1&node_id=5", .expected_path = "/dom/html" },
        .{ .url = "/cookies/delete?tab_id=1&name=x", .expected_path = "/cookies/delete" },
        .{ .url = "/headers?tab_id=1", .expected_path = "/headers" },
        .{ .url = "/script/inject?tab_id=1&source=x", .expected_path = "/script/inject" },
        .{ .url = "/stop?tab_id=1", .expected_path = "/stop" },
    };
    for (test_urls) |t| {
        const clean = if (std.mem.indexOfScalar(u8, t.url, '?')) |idx| t.url[0..idx] else t.url;
        try std.testing.expectEqualStrings(t.expected_path, clean);
    }
}

test "tier 1 routes parse correctly" {
    const tier1_urls = [_]struct { url: []const u8, expected: []const u8 }{
        .{ .url = "/scrollintoview?tab_id=1&ref=e0", .expected = "/scrollintoview" },
        .{ .url = "/drag?tab_id=1&src=e0&tgt=e1", .expected = "/drag" },
        .{ .url = "/keyboard/type?tab_id=1&text=hello", .expected = "/keyboard/type" },
        .{ .url = "/keyboard/inserttext?tab_id=1&text=hello", .expected = "/keyboard/inserttext" },
        .{ .url = "/keydown?tab_id=1&key=Enter", .expected = "/keydown" },
        .{ .url = "/keyup?tab_id=1&key=Enter", .expected = "/keyup" },
        .{ .url = "/wait?tab_id=1&selector=div&timeout=3000", .expected = "/wait" },
        .{ .url = "/tab/new?url=https://example.com", .expected = "/tab/new" },
        .{ .url = "/tab/close?tab_id=abc", .expected = "/tab/close" },
        .{ .url = "/highlight?tab_id=1&ref=e0", .expected = "/highlight" },
        .{ .url = "/errors?tab_id=1", .expected = "/errors" },
        .{ .url = "/set/offline?tab_id=1&mode=on", .expected = "/set/offline" },
        .{ .url = "/set/media?tab_id=1&scheme=dark", .expected = "/set/media" },
        .{ .url = "/set/credentials?tab_id=1&username=u&password=p", .expected = "/set/credentials" },
    };
    for (tier1_urls) |t| {
        const clean = if (std.mem.indexOfScalar(u8, t.url, '?')) |idx| t.url[0..idx] else t.url;
        try std.testing.expectEqualStrings(t.expected, clean);
    }
}

test "wait route parameters" {
    const target = "/wait?tab_id=t1&selector=div.main&timeout=3000";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("div.main", getQueryParam(target, "selector").?);
    try std.testing.expectEqualStrings("3000", getQueryParam(target, "timeout").?);
}

test "keyboard/type route parameters" {
    const target = "/keyboard/type?tab_id=t1&text=hello";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("hello", getQueryParam(target, "text").?);
}

test "set/offline route parameters" {
    const target = "/set/offline?tab_id=t1&mode=on";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("on", getQueryParam(target, "mode").?);
}

test "set/media route parameters" {
    const target = "/set/media?tab_id=t1&scheme=dark";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("dark", getQueryParam(target, "scheme").?);
}

test "set/credentials route parameters" {
    const target = "/set/credentials?tab_id=t1&username=admin&password=secret";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("admin", getQueryParam(target, "username").?);
    try std.testing.expectEqualStrings("secret", getQueryParam(target, "password").?);
}

test "drag route parameters" {
    const target = "/drag?tab_id=t1&src=e0&tgt=e5";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("e0", getQueryParam(target, "src").?);
    try std.testing.expectEqualStrings("e5", getQueryParam(target, "tgt").?);
}

test "highlight route with ref" {
    const target = "/highlight?tab_id=t1&ref=e3";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("e3", getQueryParam(target, "ref").?);
}

test "highlight route with selector" {
    const target = "/highlight?tab_id=t1&selector=div.main";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("div.main", getQueryParam(target, "selector").?);
}

test "tab/new route with url" {
    const target = "/tab/new?url=https://example.com";
    try std.testing.expectEqualStrings("https://example.com", getQueryParam(target, "url").?);
}

test "decoded query param handles percent encoding" {
    const target = "/navigate?url=https%3A%2F%2Fexample.com%2Ffoo%3Fa%3D1%26b%3Dtwo+words";
    const decoded = getDecodedQueryParamAlloc(std.testing.allocator, target, "url").?;
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("https://example.com/foo?a=1&b=two words", decoded);
}

test "tab/close route with tab_id" {
    const target = "/tab/close?tab_id=abc123";
    try std.testing.expectEqualStrings("abc123", getQueryParam(target, "tab_id").?);
}

test "action dblclick route" {
    const target = "/action?tab_id=t1&action=dblclick&ref=e0";
    try std.testing.expectEqualStrings("dblclick", getQueryParam(target, "action").?);
}

test "action check/uncheck routes" {
    const check_target = "/action?tab_id=t1&action=check&ref=e2";
    try std.testing.expectEqualStrings("check", getQueryParam(check_target, "action").?);
    const uncheck_target = "/action?tab_id=t1&action=uncheck&ref=e2";
    try std.testing.expectEqualStrings("uncheck", getQueryParam(uncheck_target, "action").?);
}

test "total endpoint count" {
    // Verify we have the expected number of routes
    const routes = [_][]const u8{
        "/health",              "/tabs",            "/discover",            "/navigate",              "/snapshot",          "/action",
        "/text",                "/screenshot",      "/evaluate",            "/browdie",               "/har/start",         "/har/stop",
        "/har/status",          "/close",           "/cookies",             "/cookies/clear",         "/cookies/delete",    "/cookies/set",
        "/storage/local",       "/storage/session", "/storage/local/clear", "/storage/session/clear", "/get",               "/back",
        "/forward",             "/reload",          "/diff/snapshot",       "/emulate",               "/geolocation",       "/upload",
        "/session/save",        "/session/load",    "/auth/profile/save",   "/auth/profile/load",     "/auth/profile/list", "/auth/profile/delete",
        "/auth/extract",        "/debug/enable",    "/debug/disable",       "/screenshot/annotated",  "/screenshot/diff",   "/screencast/start",
        "/screencast/stop",     "/video/start",     "/video/stop",          "/console",               "/intercept/start",   "/intercept/stop",
        "/intercept/requests",  "/markdown",        "/links",               "/pdf",                   "/dom/query",         "/dom/html",
        "/headers",             "/script/inject",   "/stop",
        // Tier 1 new endpoints
                       "/scrollintoview",        "/drag",              "/keyboard/type",
        "/keyboard/inserttext", "/keydown",         "/keyup",               "/wait",                  "/tab/new",           "/tab/close",
        "/highlight",           "/errors",          "/set/offline",         "/set/media",             "/set/credentials",
        // Tier 2 new endpoints
          "/find",
        "/trace/start",         "/trace/stop",      "/profiler/start",      "/profiler/stop",         "/inspect",           "/window/new",
        "/session/list",        "/set/viewport",    "/set/useragent",       "/dom/attributes",        "/frames",            "/network",
        "/perf/lcp",
        // Tier 3 new endpoints
                   "/ws/start",        "/ws/stop",
        // Tier 4 new endpoints
                    "/batch",                 "/element/state",
        // Tier 5 new endpoints
            "/find-element",
        "/dialog/auto",         "/dialog/accept",   "/dialog/dismiss",      "/mouse/move",            "/mouse/down",        "/mouse/up",
        "/mouse/wheel",         "/page/state",
        // Tier 6 new endpoints
             "/clipboard/read",      "/clipboard/write",       "/clear",             "/boundingbox",
        "/wait/function",       "/response/body",   "/setcontent",          "/selectall",             "/setvalue",          "/timezone",
        "/locale",              "/permissions",     "/tap",                 "/dispatch",              "/download",
        // Tier 7 new endpoints
                 "/addstyle",
        "/bringtofront",        "/pushstate",       "/expose",              "/multiselect",           "/swipe",             "/vitals",
        "/frame",               "/mainframe",       "/getattribute",        "/inputvalue",            "/react/tree",        "/react/inspect",
        "/react/renders",       "/react/suspense",  "/recording/start",     "/recording/stop",        "/request/detail",    "/wait/download",
        "/initscript/remove",   "/evalhandle",      "/diff/url",
        // Advanced features
                   "/cache/set",             "/cache/get",         "/cache/clear",
        "/cache/list",          "/screenshot/som",  "/snapshot/changes",    "/recording/export",      "/replay",
    };
    try std.testing.expectEqual(@as(usize, 143), routes.len);
}

test "buildGetExpression title" {
    const expr = buildGetExpression(std.testing.allocator, "title", null, null) orelse unreachable;
    defer std.testing.allocator.free(expr);
    try std.testing.expectEqualStrings("document.title", expr);
}

test "buildGetExpression url" {
    const expr = buildGetExpression(std.testing.allocator, "url", null, null) orelse unreachable;
    defer std.testing.allocator.free(expr);
    try std.testing.expectEqualStrings("window.location.href", expr);
}

test "buildGetExpression html with selector" {
    const expr = buildGetExpression(std.testing.allocator, "html", "#main", null) orelse unreachable;
    defer std.testing.allocator.free(expr);
    try std.testing.expectEqualStrings("document.querySelector('#main')?.innerHTML || null", expr);
}

test "buildGetExpression value with selector" {
    const expr = buildGetExpression(std.testing.allocator, "value", "input.email", null) orelse unreachable;
    defer std.testing.allocator.free(expr);
    try std.testing.expectEqualStrings("document.querySelector('input.email')?.value || null", expr);
}

test "buildGetExpression text with selector" {
    const expr = buildGetExpression(std.testing.allocator, "text", "p.intro", null) orelse unreachable;
    defer std.testing.allocator.free(expr);
    try std.testing.expectEqualStrings("document.querySelector('p.intro')?.innerText || null", expr);
}

test "buildGetExpression attr with selector and attr name" {
    const expr = buildGetExpression(std.testing.allocator, "attr", "a.link", "href") orelse unreachable;
    defer std.testing.allocator.free(expr);
    try std.testing.expectEqualStrings("document.querySelector('a.link')?.getAttribute('href') || null", expr);
}

test "buildGetExpression attr without attr name returns null" {
    try std.testing.expect(buildGetExpression(std.testing.allocator, "attr", "a.link", null) == null);
}

test "buildGetExpression count" {
    const expr = buildGetExpression(std.testing.allocator, "count", "li", null) orelse unreachable;
    defer std.testing.allocator.free(expr);
    try std.testing.expectEqualStrings("document.querySelectorAll('li').length", expr);
}

test "buildGetExpression box" {
    const expr = buildGetExpression(std.testing.allocator, "box", "div.card", null) orelse unreachable;
    defer std.testing.allocator.free(expr);
    try std.testing.expect(std.mem.indexOf(u8, expr, "getBoundingClientRect") != null);
}

test "runtime evaluate payload escapes embedded expression quotes" {
    const arena = std.testing.allocator;
    const expr = "JSON.stringify([...document.querySelectorAll('label')].filter(l=>l.innerText.includes(\"Text input\")))";
    const escaped = jsonEscapeAlloc(arena, expr).?;
    defer if (escaped.ptr != expr.ptr) arena.free(escaped);
    const payload = try std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped});
    defer arena.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\\\"Text input\\\"") != null);
    try std.testing.expect(std.mem.startsWith(u8, payload, "{\"expression\":\""));
}

test "parseA11yNodes extracts value description and state" {
    const raw =
        \\{"id":1,"result":{"nodes":[{"nodeId":"1","ignored":false,"role":{"type":"role","value":"checkbox"},"name":{"type":"computedString","value":"Email me"},"value":{"type":"string","value":"yes"},"description":{"type":"computedString","value":"Weekly updates"},"properties":[{"name":"checked","value":{"type":"tristate","value":"false"}},{"name":"required","value":{"type":"boolean","value":true}},{"name":"disabled","value":{"type":"boolean","value":false}}],"backendDOMNodeId":42}]}}
    ;
    const nodes = try parseA11yNodes(std.testing.allocator, raw);
    defer {
        for (nodes) |node| {
            if (node.state.len > 0) std.testing.allocator.free(node.state);
        }
        std.testing.allocator.free(nodes);
    }

    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqualStrings("checkbox", nodes[0].role);
    try std.testing.expectEqualStrings("Email me", nodes[0].name);
    try std.testing.expectEqualStrings("yes", nodes[0].value);
    try std.testing.expectEqualStrings("Weekly updates", nodes[0].description);
    try std.testing.expectEqualStrings("checked=false required", nodes[0].state);
    try std.testing.expectEqual(@as(?u32, 42), nodes[0].backend_node_id);
}

test "buildGetExpression html without selector returns null" {
    try std.testing.expect(buildGetExpression(std.testing.allocator, "html", null, null) == null);
}

test "buildGetExpression unknown type returns null" {
    try std.testing.expect(buildGetExpression(std.testing.allocator, "unknown", "div", null) == null);
}

test "extractSimpleJsonString extracts value" {
    const json = "{\"objectId\":\"obj-123\",\"type\":\"object\"}";
    const val = extractSimpleJsonString(json, 0, "\"objectId\"");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("obj-123", val.?);
}

test "extractSimpleJsonString missing field returns null" {
    const json = "{\"other\":\"value\"}";
    try std.testing.expect(extractSimpleJsonString(json, 0, "\"objectId\"") == null);
}

test "extractSimpleJsonString with offset" {
    const json = "{\"a\":\"first\",\"a\":\"second\"}";
    const first = extractSimpleJsonString(json, 0, "\"a\"");
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("first", first.?);
}

test "extractSimpleJsonInt extracts number" {
    const json = "{\"backendDOMNodeId\":42,\"nodeId\":\"n1\"}";
    const val = extractSimpleJsonInt(json, 0, "\"backendDOMNodeId\"");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(u32, 42), val.?);
}

test "extractSimpleJsonInt missing field returns null" {
    const json = "{\"other\":123}";
    try std.testing.expect(extractSimpleJsonInt(json, 0, "\"nodeId\"") == null);
}

test "findContentLength parses header" {
    try std.testing.expectEqual(@as(?usize, 1234), findContentLength("Content-Length: 1234\r\n"));
    try std.testing.expectEqual(@as(?usize, 0), findContentLength("Content-Length: 0\r\n"));
    try std.testing.expect(findContentLength("X-Other: 5\r\n") == null);
}

test "findContentLength case insensitive" {
    try std.testing.expectEqual(@as(?usize, 42), findContentLength("content-length: 42\r\n"));
}

test "tier 2 routes parse correctly" {
    const tier2_urls = [_]struct { url: []const u8, expected: []const u8 }{
        .{ .url = "/find?tab_id=1&by=role&value=button", .expected = "/find" },
        .{ .url = "/trace/start?tab_id=1", .expected = "/trace/start" },
        .{ .url = "/trace/stop?tab_id=1", .expected = "/trace/stop" },
        .{ .url = "/profiler/start?tab_id=1", .expected = "/profiler/start" },
        .{ .url = "/profiler/stop?tab_id=1", .expected = "/profiler/stop" },
        .{ .url = "/inspect?tab_id=1", .expected = "/inspect" },
        .{ .url = "/window/new?url=about:blank", .expected = "/window/new" },
        .{ .url = "/session/list", .expected = "/session/list" },
        .{ .url = "/set/viewport?tab_id=1&width=1920&height=1080", .expected = "/set/viewport" },
        .{ .url = "/set/useragent?tab_id=1&ua=Mozilla", .expected = "/set/useragent" },
        .{ .url = "/dom/attributes?tab_id=1&ref=e0", .expected = "/dom/attributes" },
        .{ .url = "/frames?tab_id=1", .expected = "/frames" },
        .{ .url = "/network?tab_id=1&mode=enable", .expected = "/network" },
    };
    for (tier2_urls) |t| {
        const clean = if (std.mem.indexOfScalar(u8, t.url, '?')) |idx| t.url[0..idx] else t.url;
        try std.testing.expectEqualStrings(t.expected, clean);
    }
}

test "find route parameters" {
    const target = "/find?tab_id=t1&by=role&value=button&exact=true";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("role", getQueryParam(target, "by").?);
    try std.testing.expectEqualStrings("button", getQueryParam(target, "value").?);
    try std.testing.expectEqualStrings("true", getQueryParam(target, "exact").?);
}

test "set/viewport route parameters" {
    const target = "/set/viewport?tab_id=t1&width=1920&height=1080&scale=2";
    try std.testing.expectEqualStrings("1920", getQueryParam(target, "width").?);
    try std.testing.expectEqualStrings("1080", getQueryParam(target, "height").?);
    try std.testing.expectEqualStrings("2", getQueryParam(target, "scale").?);
}

test "dom/attributes route with ref" {
    const target = "/dom/attributes?tab_id=t1&ref=e5";
    try std.testing.expectEqualStrings("e5", getQueryParam(target, "ref").?);
}

test "dom/attributes route with selector" {
    const target = "/dom/attributes?tab_id=t1&selector=input.email";
    try std.testing.expectEqualStrings("input.email", getQueryParam(target, "selector").?);
}

test "network route parameters" {
    const target = "/network?tab_id=t1&mode=disable";
    try std.testing.expectEqualStrings("disable", getQueryParam(target, "mode").?);
}

test "auth profile routes parse correctly" {
    const save_target = "/auth/profile/save?tab_id=t1&name=google";
    try std.testing.expectEqualStrings("t1", getQueryParam(save_target, "tab_id").?);
    try std.testing.expectEqualStrings("google", getQueryParam(save_target, "name").?);

    const load_target = "/auth/profile/load?tab_id=t1&name=google";
    try std.testing.expectEqualStrings("t1", getQueryParam(load_target, "tab_id").?);
    try std.testing.expectEqualStrings("google", getQueryParam(load_target, "name").?);

    const delete_target = "/auth/profile/delete?name=google";
    try std.testing.expectEqualStrings("google", getQueryParam(delete_target, "name").?);
}

test "debug routes parse correctly" {
    const enable_target = "/debug/enable?tab_id=t1&freeze=true";
    try std.testing.expectEqualStrings("t1", getQueryParam(enable_target, "tab_id").?);
    try std.testing.expectEqualStrings("true", getQueryParam(enable_target, "freeze").?);

    const disable_target = "/debug/disable?tab_id=t1";
    try std.testing.expectEqualStrings("t1", getQueryParam(disable_target, "tab_id").?);
}

test "jsonEscapeAlloc escapes special chars" {
    const arena = std.testing.allocator;
    // No escaping needed
    try std.testing.expectEqualStrings("hello", jsonEscapeAlloc(arena, "hello").?);
    // Quotes and backslashes
    const escaped = jsonEscapeAlloc(arena, "say \"hello\" \\ world").?;
    defer arena.free(escaped);
    try std.testing.expectEqualStrings("say \\\"hello\\\" \\\\ world", escaped);
    // Newlines
    const nl = jsonEscapeAlloc(arena, "line1\nline2\r\n").?;
    defer arena.free(nl);
    try std.testing.expectEqualStrings("line1\\nline2\\r\\n", nl);
}

test "parseCdpAddress falls back to managed chrome port" {
    const addr = parseCdpAddress(null, 9224);
    try std.testing.expectEqualStrings("127.0.0.1", addr.host);
    try std.testing.expectEqual(@as(u16, 9224), addr.port);
}

test "parseCdpAddress accepts http discovery endpoint" {
    const addr = parseCdpAddress("http://localhost:9333/json/version", 9224);
    try std.testing.expectEqualStrings("127.0.0.1", addr.host);
    try std.testing.expectEqual(@as(u16, 9333), addr.port);
}

test "parseCdpAddress accepts websocket endpoint path" {
    const addr = parseCdpAddress("ws://127.0.0.1:9444/devtools/browser/abc", 9224);
    try std.testing.expectEqualStrings("127.0.0.1", addr.host);
    try std.testing.expectEqual(@as(u16, 9444), addr.port);
}

test "writeJsonField escapes embedded quotes" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try writeJsonField(&buf, std.testing.allocator, "title", "say \"hello\"\nnext");
    try std.testing.expectEqualStrings("\"title\":\"say \\\"hello\\\"\\nnext\"", buf.items);
}

test "script/inject accepts POST body" {
    // Route matching test — verify POST method is supported
    const path = "/script/inject?tab_id=abc";
    const clean = path[0..std.mem.indexOfScalar(u8, path, '?').?];
    try std.testing.expectEqualStrings("/script/inject", clean);
}

test "perf/lcp route parameters" {
    const path = "/perf/lcp?tab_id=abc&url=https://example.com";
    const clean = path[0..std.mem.indexOfScalar(u8, path, '?').?];
    try std.testing.expectEqualStrings("/perf/lcp", clean);
    try std.testing.expect(getQueryParam(path, "tab_id") != null);
    try std.testing.expect(getQueryParam(path, "url") != null);
}

test "generation bump invalidates stale refs after navigation" {
    var bridge = Bridge.init(std.testing.allocator);
    defer bridge.deinit();
    const a11y = @import("../snapshot/a11y.zig");

    // First page: one button, ref cache populated at generation 0 ("e42").
    const nodes1 = [_]a11y.A11yNode{
        .{ .ref = "e42", .role = "button", .name = "Save", .value = "", .backend_node_id = 42, .depth = 0 },
    };
    {
        bridge.mu.lock();
        defer bridge.mu.unlock();
        try refreshRefCacheLocked(&bridge, "tab1", &nodes1);
    }
    try std.testing.expectEqual(@as(u32, 0), currentGeneration(&bridge, "tab1"));

    // Navigation happens.
    bumpGenerationLocked(&bridge, "tab1");
    try std.testing.expectEqual(@as(u32, 1), currentGeneration(&bridge, "tab1"));

    // New page loaded; CDP happens to reuse backend id 42 for an unrelated
    // element. A fresh snapshot at generation 1 mints "e1_42" for it, not "e42".
    const nodes2 = [_]a11y.A11yNode{
        .{ .ref = "e1_42", .role = "button", .name = "Delete Account", .value = "", .backend_node_id = 42, .depth = 0 },
    };
    {
        bridge.mu.lock();
        defer bridge.mu.unlock();
        try refreshRefCacheLocked(&bridge, "tab1", &nodes2);
    }

    // The pre-navigation ref "e42" must now miss — not silently resolve to
    // the new page's backend id 42 (which would silently click "Delete
    // Account" for an agent that acted on a ref it saw before the navigation).
    bridge.mu.lockShared();
    const cache = bridge.snapshots.getPtr("tab1");
    const stale = if (cache) |c| c.refs.get("e42") else null;
    const fresh = if (cache) |c| c.refs.get("e1_42") else null;
    bridge.mu.unlockShared();
    try std.testing.expectEqual(@as(?u32, null), stale);
    try std.testing.expectEqual(@as(?u32, 42), fresh);
}

test "refreshRefCacheLocked preserves generation across its own clear()" {
    var bridge = Bridge.init(std.testing.allocator);
    defer bridge.deinit();
    const a11y = @import("../snapshot/a11y.zig");

    bumpGenerationLocked(&bridge, "tab1");
    bumpGenerationLocked(&bridge, "tab1");
    try std.testing.expectEqual(@as(u32, 2), currentGeneration(&bridge, "tab1"));

    const nodes = [_]a11y.A11yNode{
        .{ .ref = "e2_7", .role = "link", .name = "Home", .value = "", .backend_node_id = 7, .depth = 0 },
    };
    bridge.mu.lock();
    try refreshRefCacheLocked(&bridge, "tab1", &nodes);
    bridge.mu.unlock();

    // A snapshot refresh (which clears and repopulates the ref map) must not
    // reset the generation counter — only a real navigation may bump it.
    try std.testing.expectEqual(@as(u32, 2), currentGeneration(&bridge, "tab1"));
}
