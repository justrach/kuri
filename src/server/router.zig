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
const InterceptRule = @import("../cdp/client.zig").InterceptRule;
const ScreencastFrameRecord = @import("../cdp/client.zig").ScreencastFrameRecord;
const BindingCallRecord = @import("../cdp/client.zig").BindingCallRecord;
const NetworkRecord = @import("../cdp/client.zig").NetworkRecord;
const jsonscan = @import("../cdp/jsonscan.zig");
const auth_profiles = @import("../storage/auth_profiles.zig");
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

/// Every routable path, one variant per distinct URL (not per handler --
/// several paths share a handler via a literal discriminator argument,
/// e.g. `/storage/local` and `/storage/session` both call `handleStorage`).
/// `route_table` below maps the path string to this enum in O(1)-ish time
/// (StaticStringMap buckets by length, then does a handful of `eql` calls);
/// `route()` then does an exhaustive `switch` so the compiler guarantees
/// every variant has a handler and every handler is reachable.
pub const Route = enum {
    health,
    tabs,
    page_info,
    discover,
    navigate,
    snapshot,
    action,
    text,
    screenshot,
    evaluate,
    browdie,
    har_start,
    har_stop,
    har_status,
    har_replay,
    replay,
    close,
    cookies,
    cookies_clear,
    cookies_set,
    storage_local,
    storage_session,
    storage_local_clear,
    storage_session_clear,
    get,
    back,
    forward,
    reload,
    diff_snapshot,
    emulate,
    geolocation,
    upload,
    session_save,
    session_load,
    auth_profile_save,
    auth_profile_load,
    auth_profile_list,
    auth_profile_delete,
    auth_extract,
    debug_enable,
    debug_disable,
    screenshot_annotated,
    screenshot_diff,
    screencast_start,
    screencast_stop,
    video_start,
    video_stop,
    console,
    intercept_start,
    intercept_stop,
    intercept_requests,
    intercept_rules,
    intercept_rules_clear,
    markdown,
    links,
    pdf,
    dom_query,
    dom_html,
    cookies_delete,
    headers,
    script_inject,
    stop,
    scrollintoview,
    drag,
    keyboard_type,
    keyboard_inserttext,
    keydown,
    keyup,
    wait,
    tab_current,
    tab_new,
    tab_close,
    highlight,
    errors,
    set_offline,
    set_media,
    set_credentials,
    find,
    trace_start,
    trace_stop,
    profiler_start,
    profiler_stop,
    inspect,
    window_new,
    session_list,
    set_viewport,
    set_useragent,
    dom_attributes,
    frames,
    network,
    perf_lcp,
    ws_start,
    ws_stop,
    batch,
    element_state,
    find_element,
    dialog_auto,
    dialog_accept,
    dialog_dismiss,
    mouse_move,
    mouse_down,
    mouse_up,
    mouse_wheel,
    page_state,
    clipboard_read,
    clipboard_write,
    clear,
    boundingbox,
    wait_function,
    response_body,
    setcontent,
    selectall,
    setvalue,
    timezone,
    locale,
    permissions,
    tap,
    dispatch,
    download,
    addstyle,
    bringtofront,
    pushstate,
    expose,
    expose_calls,
    multiselect,
    swipe,
    vitals,
    frame,
    mainframe,
    getattribute,
    inputvalue,
    react_tree,
    react_inspect,
    react_renders,
    react_suspense,
    recording_start,
    recording_stop,
    request_detail,
    wait_download,
    initscript_remove,
    evalhandle,
    diff_url,
    cache_set,
    cache_get,
    cache_clear,
    cache_list,
    screenshot_som,
    snapshot_changes,
    recording_export,
};

pub const route_table = std.StaticStringMap(Route).initComptime(.{
    .{ "/health", .health },
    .{ "/tabs", .tabs },
    .{ "/page/info", .page_info },
    .{ "/discover", .discover },
    .{ "/navigate", .navigate },
    .{ "/snapshot", .snapshot },
    .{ "/action", .action },
    .{ "/text", .text },
    .{ "/screenshot", .screenshot },
    .{ "/evaluate", .evaluate },
    .{ "/browdie", .browdie },
    .{ "/har/start", .har_start },
    .{ "/har/stop", .har_stop },
    .{ "/har/status", .har_status },
    .{ "/har/replay", .har_replay },
    .{ "/replay", .replay },
    .{ "/close", .close },
    .{ "/cookies", .cookies },
    .{ "/cookies/clear", .cookies_clear },
    .{ "/cookies/set", .cookies_set },
    .{ "/storage/local", .storage_local },
    .{ "/storage/session", .storage_session },
    .{ "/storage/local/clear", .storage_local_clear },
    .{ "/storage/session/clear", .storage_session_clear },
    .{ "/get", .get },
    .{ "/back", .back },
    .{ "/forward", .forward },
    .{ "/reload", .reload },
    .{ "/diff/snapshot", .diff_snapshot },
    .{ "/emulate", .emulate },
    .{ "/geolocation", .geolocation },
    .{ "/upload", .upload },
    .{ "/session/save", .session_save },
    .{ "/session/load", .session_load },
    .{ "/auth/profile/save", .auth_profile_save },
    .{ "/auth/profile/load", .auth_profile_load },
    .{ "/auth/profile/list", .auth_profile_list },
    .{ "/auth/profile/delete", .auth_profile_delete },
    .{ "/auth/extract", .auth_extract },
    .{ "/debug/enable", .debug_enable },
    .{ "/debug/disable", .debug_disable },
    .{ "/screenshot/annotated", .screenshot_annotated },
    .{ "/screenshot/diff", .screenshot_diff },
    .{ "/screencast/start", .screencast_start },
    .{ "/screencast/stop", .screencast_stop },
    .{ "/video/start", .video_start },
    .{ "/video/stop", .video_stop },
    .{ "/console", .console },
    .{ "/intercept/start", .intercept_start },
    .{ "/intercept/stop", .intercept_stop },
    .{ "/intercept/requests", .intercept_requests },
    .{ "/intercept/rules", .intercept_rules },
    .{ "/intercept/rules/clear", .intercept_rules_clear },
    .{ "/markdown", .markdown },
    .{ "/links", .links },
    .{ "/pdf", .pdf },
    .{ "/dom/query", .dom_query },
    .{ "/dom/html", .dom_html },
    .{ "/cookies/delete", .cookies_delete },
    .{ "/headers", .headers },
    .{ "/script/inject", .script_inject },
    .{ "/stop", .stop },
    .{ "/scrollintoview", .scrollintoview },
    .{ "/drag", .drag },
    .{ "/keyboard/type", .keyboard_type },
    .{ "/keyboard/inserttext", .keyboard_inserttext },
    .{ "/keydown", .keydown },
    .{ "/keyup", .keyup },
    .{ "/wait", .wait },
    .{ "/tab/current", .tab_current },
    .{ "/tab/new", .tab_new },
    .{ "/tab/close", .tab_close },
    .{ "/highlight", .highlight },
    .{ "/errors", .errors },
    .{ "/set/offline", .set_offline },
    .{ "/set/media", .set_media },
    .{ "/set/credentials", .set_credentials },
    .{ "/find", .find },
    .{ "/trace/start", .trace_start },
    .{ "/trace/stop", .trace_stop },
    .{ "/profiler/start", .profiler_start },
    .{ "/profiler/stop", .profiler_stop },
    .{ "/inspect", .inspect },
    .{ "/window/new", .window_new },
    .{ "/session/list", .session_list },
    .{ "/set/viewport", .set_viewport },
    .{ "/set/useragent", .set_useragent },
    .{ "/dom/attributes", .dom_attributes },
    .{ "/frames", .frames },
    .{ "/network", .network },
    .{ "/perf/lcp", .perf_lcp },
    .{ "/ws/start", .ws_start },
    .{ "/ws/stop", .ws_stop },
    .{ "/batch", .batch },
    .{ "/element/state", .element_state },
    .{ "/find-element", .find_element },
    .{ "/dialog/auto", .dialog_auto },
    .{ "/dialog/accept", .dialog_accept },
    .{ "/dialog/dismiss", .dialog_dismiss },
    .{ "/mouse/move", .mouse_move },
    .{ "/mouse/down", .mouse_down },
    .{ "/mouse/up", .mouse_up },
    .{ "/mouse/wheel", .mouse_wheel },
    .{ "/page/state", .page_state },
    .{ "/clipboard/read", .clipboard_read },
    .{ "/clipboard/write", .clipboard_write },
    .{ "/clear", .clear },
    .{ "/boundingbox", .boundingbox },
    .{ "/wait/function", .wait_function },
    .{ "/response/body", .response_body },
    .{ "/setcontent", .setcontent },
    .{ "/selectall", .selectall },
    .{ "/setvalue", .setvalue },
    .{ "/timezone", .timezone },
    .{ "/locale", .locale },
    .{ "/permissions", .permissions },
    .{ "/tap", .tap },
    .{ "/dispatch", .dispatch },
    .{ "/download", .download },
    .{ "/addstyle", .addstyle },
    .{ "/bringtofront", .bringtofront },
    .{ "/pushstate", .pushstate },
    .{ "/expose", .expose },
    .{ "/expose/calls", .expose_calls },
    .{ "/multiselect", .multiselect },
    .{ "/swipe", .swipe },
    .{ "/vitals", .vitals },
    .{ "/frame", .frame },
    .{ "/mainframe", .mainframe },
    .{ "/getattribute", .getattribute },
    .{ "/inputvalue", .inputvalue },
    .{ "/react/tree", .react_tree },
    .{ "/react/inspect", .react_inspect },
    .{ "/react/renders", .react_renders },
    .{ "/react/suspense", .react_suspense },
    .{ "/recording/start", .recording_start },
    .{ "/recording/stop", .recording_stop },
    .{ "/request/detail", .request_detail },
    .{ "/wait/download", .wait_download },
    .{ "/initscript/remove", .initscript_remove },
    .{ "/evalhandle", .evalhandle },
    .{ "/diff/url", .diff_url },
    .{ "/cache/set", .cache_set },
    .{ "/cache/get", .cache_get },
    .{ "/cache/clear", .cache_clear },
    .{ "/cache/list", .cache_list },
    .{ "/screenshot/som", .screenshot_som },
    .{ "/snapshot/changes", .snapshot_changes },
    .{ "/recording/export", .recording_export },
});

fn route(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge, cfg: Config, cdp_port: u16) void {
    const path = request.head.target;
    const clean_path = if (std.mem.indexOfScalar(u8, path, '?')) |idx| path[0..idx] else path;

    const r = route_table.get(clean_path) orelse {
        resp.sendError(request, 404, "Not Found");
        return;
    };

    switch (r) {
        .health => handleHealth(request, arena, bridge),
        .tabs => handleTabs(request, arena, bridge),
        .page_info => handlePageInfo(request, arena, bridge),
        .discover => handleDiscover(request, arena, bridge, cfg, cdp_port),
        .navigate => handleNavigate(request, arena, bridge, cfg),
        .snapshot => handleSnapshot(request, arena, bridge),
        .action => handleAction(request, arena, bridge),
        .text => handleText(request, arena, bridge),
        .screenshot => handleScreenshot(request, arena, bridge),
        .evaluate => handleEvaluate(request, arena, bridge),
        .browdie => handleBrowdie(request),
        .har_start => handleHarStart(request, arena, bridge),
        .har_stop => handleHarStop(request, arena, bridge),
        .har_status => handleHarStatus(request, arena, bridge),
        .har_replay => handleHarReplay(request, arena, bridge),
        .replay => handleReplay(request, arena, bridge),
        .close => handleClose(request, arena, bridge),
        .cookies => handleCookies(request, arena, bridge),
        .cookies_clear => handleCookiesClear(request, arena, bridge),
        .cookies_set => handleCookiesSet(request, arena, bridge),
        .storage_local => handleStorage(request, arena, bridge, "localStorage"),
        .storage_session => handleStorage(request, arena, bridge, "sessionStorage"),
        .storage_local_clear => handleStorageClear(request, arena, bridge, "localStorage"),
        .storage_session_clear => handleStorageClear(request, arena, bridge, "sessionStorage"),
        .get => handleGet(request, arena, bridge),
        .back => handleBack(request, arena, bridge),
        .forward => handleForward(request, arena, bridge),
        .reload => handleReload(request, arena, bridge),
        .diff_snapshot => handleDiffSnapshot(request, arena, bridge),
        .emulate => handleEmulate(request, arena, bridge),
        .geolocation => handleGeolocation(request, arena, bridge),
        .upload => handleUpload(request, arena, bridge),
        .session_save => handleSessionSave(request, arena, bridge),
        .session_load => handleSessionLoad(request, arena, bridge),
        .auth_profile_save => handleAuthProfileSave(request, arena, bridge, cfg),
        .auth_profile_load => handleAuthProfileLoad(request, arena, bridge, cfg),
        .auth_profile_list => handleAuthProfileList(request, arena, cfg),
        .auth_profile_delete => handleAuthProfileDelete(request, arena, cfg),
        .auth_extract => handleAuthExtract(request, arena),
        .debug_enable => handleDebugEnable(request, arena, bridge),
        .debug_disable => handleDebugDisable(request, arena, bridge),
        .screenshot_annotated => handleAnnotatedScreenshot(request, arena, bridge),
        .screenshot_diff => handleDiffScreenshot(request, arena, bridge),
        .screencast_start => handleScreencastStart(request, arena, bridge),
        .screencast_stop => handleScreencastStop(request, arena, bridge),
        .video_start => handleVideoStart(request, arena, bridge),
        .video_stop => handleVideoStop(request, arena, bridge),
        .console => handleConsole(request, arena, bridge),
        .intercept_start => handleInterceptStart(request, arena, bridge),
        .intercept_stop => handleInterceptStop(request, arena, bridge),
        .intercept_requests => handleInterceptRequests(request, arena, bridge),
        .intercept_rules => handleInterceptRules(request, arena, bridge),
        .intercept_rules_clear => handleInterceptRulesClear(request, arena, bridge),
        .markdown => handleMarkdown(request, arena, bridge),
        .links => handleLinks(request, arena, bridge),
        .pdf => handlePdf(request, arena, bridge),
        .dom_query => handleDomQuery(request, arena, bridge),
        .dom_html => handleDomHtml(request, arena, bridge),
        .cookies_delete => handleCookiesDelete(request, arena, bridge),
        .headers => handleHeaders(request, arena, bridge),
        .script_inject => handleScriptInject(request, arena, bridge),
        .stop => handleStop(request, arena, bridge),
        .scrollintoview => handleScrollIntoView(request, arena, bridge),
        .drag => handleDrag(request, arena, bridge),
        .keyboard_type => handleKeyboardType(request, arena, bridge),
        .keyboard_inserttext => handleKeyboardInsertText(request, arena, bridge),
        .keydown => handleKeyDown(request, arena, bridge),
        .keyup => handleKeyUp(request, arena, bridge),
        .wait => handleWait(request, arena, bridge),
        .tab_current => handleTabCurrent(request, arena, bridge),
        .tab_new => handleTabNew(request, arena, bridge, cfg, cdp_port),
        .tab_close => handleTabClose(request, arena, bridge),
        .highlight => handleHighlight(request, arena, bridge),
        .errors => handleErrors(request, arena, bridge),
        .set_offline => handleSetOffline(request, arena, bridge),
        .set_media => handleSetMedia(request, arena, bridge),
        .set_credentials => handleSetCredentials(request, arena, bridge),
        .find => handleFind(request, arena, bridge),
        .trace_start => handleTraceStart(request, arena, bridge),
        .trace_stop => handleTraceStop(request, arena, bridge),
        .profiler_start => handleProfilerStart(request, arena, bridge),
        .profiler_stop => handleProfilerStop(request, arena, bridge),
        .inspect => handleInspect(request, arena, bridge),
        .window_new => handleWindowNew(request, arena, bridge, cfg, cdp_port),
        .session_list => handleSessionList(request, arena, bridge),
        .set_viewport => handleSetViewport(request, arena, bridge),
        .set_useragent => handleSetUserAgent(request, arena, bridge),
        .dom_attributes => handleDomAttributes(request, arena, bridge),
        .frames => handleFrames(request, arena, bridge),
        .network => handleNetwork(request, arena, bridge),
        .perf_lcp => handlePerfLcp(request, arena, bridge),
        .ws_start => handleWsStart(request, arena, bridge),
        .ws_stop => handleWsStop(request, arena, bridge),
        .batch => handleBatch(request, arena, bridge),
        .element_state => handleElementState(request, arena, bridge),
        .find_element => handleFindElement(request, arena, bridge),
        .dialog_auto => handleDialogAuto(request, arena, bridge),
        .dialog_accept => handleDialogRespond(request, arena, bridge, true),
        .dialog_dismiss => handleDialogRespond(request, arena, bridge, false),
        .mouse_move => handleMouseEvent(request, arena, bridge, "mouseMoved"),
        .mouse_down => handleMouseEvent(request, arena, bridge, "mousePressed"),
        .mouse_up => handleMouseEvent(request, arena, bridge, "mouseReleased"),
        .mouse_wheel => handleMouseWheel(request, arena, bridge),
        .page_state => handlePageState(request, arena, bridge),
        .clipboard_read => handleClipboard(request, arena, bridge, "read"),
        .clipboard_write => handleClipboard(request, arena, bridge, "write"),
        .clear => handleClear(request, arena, bridge),
        .boundingbox => handleBoundingBox(request, arena, bridge),
        .wait_function => handleWaitForFunction(request, arena, bridge),
        .response_body => handleResponseBody(request, arena, bridge),
        .setcontent => handleSetContent(request, arena, bridge),
        .selectall => handleSelectAll(request, arena, bridge),
        .setvalue => handleSetValue(request, arena, bridge),
        .timezone => handleTimezone(request, arena, bridge),
        .locale => handleLocale(request, arena, bridge),
        .permissions => handlePermissions(request, arena, bridge),
        .tap => handleTap(request, arena, bridge),
        .dispatch => handleDispatch(request, arena, bridge),
        .download => handleDownload(request, arena, bridge),
        .addstyle => handleAddStyle(request, arena, bridge),
        .bringtofront => handleBringToFront(request, arena, bridge),
        .pushstate => handlePushState(request, arena, bridge),
        .expose => handleExpose(request, arena, bridge),
        .expose_calls => handleExposeCalls(request, arena, bridge),
        .multiselect => handleMultiSelect(request, arena, bridge),
        .swipe => handleSwipe(request, arena, bridge),
        .vitals => handleVitals(request, arena, bridge),
        .frame => handleFrame(request, arena, bridge),
        .mainframe => handleMainFrame(request, arena, bridge),
        .getattribute => handleGetAttribute(request, arena, bridge),
        .inputvalue => handleInputValue(request, arena, bridge),
        .react_tree => handleReact(request, arena, bridge, "tree"),
        .react_inspect => handleReact(request, arena, bridge, "inspect"),
        .react_renders => handleReact(request, arena, bridge, "renders"),
        .react_suspense => handleReact(request, arena, bridge, "suspense"),
        .recording_start => handleRecording(request, arena, bridge, "start"),
        .recording_stop => handleRecording(request, arena, bridge, "stop"),
        .request_detail => handleRequestDetail(request, arena, bridge),
        .wait_download => handleWaitForDownload(request, arena, bridge),
        .initscript_remove => handleRemoveInitScript(request, arena, bridge),
        .evalhandle => handleEvalHandle(request, arena, bridge),
        .diff_url => handleDiffUrl(request, arena, bridge),
        .cache_set => handleCacheSet(request, arena, bridge),
        .cache_get => handleCacheGet(request, arena, bridge),
        .cache_clear => handleCacheClear(request, arena, bridge),
        .cache_list => handleCacheList(request, arena, bridge),
        .screenshot_som => handleScreenshotSom(request, arena, bridge),
        .snapshot_changes => handleSnapshotChanges(request, arena, bridge),
        .recording_export => handleRecordingExport(request, arena, bridge),
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

fn handleSnapshotChanges(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    rememberCurrentTab(request, bridge, tab_id);

    // Step 1: Get previous snapshot text from JS-side storage
    const prev_text = evalValueString(arena, client, "(function() { return window.__kuri_prev_snapshot || ''; })()") orelse "";

    // Step 2: Take new snapshot via a11y tree
    const raw_response = client.send(arena, protocol.Methods.accessibility_get_full_tree, null) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    const a11y = @import("../snapshot/a11y.zig");
    const nodes = parseA11yNodes(arena, raw_response) catch {
        resp.sendError(request, 500, "Failed to parse a11y tree");
        return;
    };
    const snapshot = a11y.buildSnapshot(nodes, .{ .compact = true }, arena) catch {
        resp.sendError(request, 500, "Failed to build snapshot");
        return;
    };
    const new_text = a11y.formatCompact(snapshot, arena) catch {
        resp.sendError(request, 500, "Failed to format snapshot");
        return;
    };

    // Step 3: Store new snapshot as previous
    const store_escaped = jsonEscapeAlloc(arena, new_text) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const store_js = std.fmt.allocPrint(arena,
        \\(function() {{ window.__kuri_prev_snapshot = "{s}"; return "ok"; }})()
    , .{store_escaped}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = evalValueString(arena, client, store_js);

    // Step 4: Diff line by line using JS to avoid Zig ArrayList API issues
    // We do a simple JS-based diff since both texts are available
    const escaped_prev = jsonEscapeAlloc(arena, prev_text) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped_new = jsonEscapeAlloc(arena, new_text) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const diff_js = std.fmt.allocPrint(arena,
        \\(function() {{
        \\  var prev = "{s}".split("\n").filter(function(l) {{ return l.length > 0; }});
        \\  var curr = "{s}".split("\n").filter(function(l) {{ return l.length > 0; }});
        \\  var prevSet = new Set(prev);
        \\  var currSet = new Set(curr);
        \\  var added = curr.filter(function(l) {{ return !prevSet.has(l); }});
        \\  var removed = prev.filter(function(l) {{ return !currSet.has(l); }});
        \\  var unchanged = curr.filter(function(l) {{ return prevSet.has(l); }}).length;
        \\  return JSON.stringify({{added:added,removed:removed,unchanged_count:unchanged}});
        \\}})()
    , .{ escaped_prev, escaped_new }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const diff_result = evalValueString(arena, client, diff_js) orelse {
        resp.sendError(request, 502, "Diff computation failed");
        return;
    };
    resp.sendJson(request, diff_result);
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

    // `expr` is ALREADY JSON-escaped just above. Escaping it a second time was
    // a real bug: a newline became `\n`, then `\\n`, which JSON-decodes back to
    // a literal backslash+n in the JS source — so Chrome answered any multi-line
    // (or quote-containing) expression with "SyntaxError: Invalid or unexpected
    // token" instead of running it. Escape exactly once.
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{expr}) catch {
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
                // Page.enable MUST happen before any Page.addScriptToEvaluateOnNewDocument
                // call below, on this same CDP session -- verified directly against
                // Chrome: an init script registered without Page domain enabled first
                // only survives for the current document and is silently dropped on
                // the very next navigation (not re-fired at all), which is why
                // /console, /errors, and /react/tree all went empty on any page
                // reached via /navigate despite being registered here. Page.enable has
                // no matching Page.disable anywhere in this codebase, so this is a
                // one-time, idempotent enable for the life of the session.
                _ = client.send(arena, protocol.Methods.page_enable, null) catch {};

                const stealth = @import("../cdp/stealth.zig");
                const escaped = jsonEscapeAlloc(arena, stealth.stealth_script) orelse continue;
                const add_params = std.fmt.allocPrint(arena, "{{\"source\":\"{s}\"}}", .{escaped}) catch continue;
                _ = client.send(arena, protocol.Methods.page_add_script, add_params) catch {};

                // Inject the console/error collector: persist across future
                // navigations, and run once against the already-loaded page so
                // /console and /errors work without requiring a reload.
                if (jsonEscapeAlloc(arena, stealth.console_collector_script)) |collector_escaped| {
                    if (std.fmt.allocPrint(arena, "{{\"source\":\"{s}\"}}", .{collector_escaped})) |collector_add| {
                        _ = client.send(arena, protocol.Methods.page_add_script, collector_add) catch {};
                    } else |_| {}
                    if (std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{collector_escaped})) |collector_eval| {
                        _ = client.send(arena, protocol.Methods.runtime_evaluate, collector_eval) catch {};
                    } else |_| {}
                }

                // Inject the React fiber introspector: persist across future
                // navigations (this is the copy that actually matters for
                // version detection + commit tracking, since it must be
                // present before react-dom's own init runs), and run once
                // against the already-loaded page so /react/tree etc. work
                // without requiring a reload first.
                if (jsonEscapeAlloc(arena, stealth.react_fiber_script)) |react_escaped| {
                    if (std.fmt.allocPrint(arena, "{{\"source\":\"{s}\"}}", .{react_escaped})) |react_add| {
                        _ = client.send(arena, protocol.Methods.page_add_script, react_add) catch {};
                    } else |_| {}
                    if (std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{react_escaped})) |react_eval| {
                        _ = client.send(arena, protocol.Methods.runtime_evaluate, react_eval) catch {};
                    } else |_| {}
                }

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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;

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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;

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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;

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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = resolveEffectiveTabIdAlloc(arena, request, bridge) orelse {
        resp.sendError(request, 400, "Missing tab_id parameter (or set X-Kuri-Session)");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // Read and clear the collector's console buffer. Returns "[]" when the
    // collector has not been injected yet (e.g. the page never navigated).
    const params = "{\"expression\":\"(function(){var c=window.__kuri_console||[];window.__kuri_console=[];return JSON.stringify(c);})()\",\"returnByValue\":true}";
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

// ── Network Interception Endpoints ──────────────────────────────────────
// All endpoints below resolve tab_id the same way /console and /errors do:
// an explicit ?tab_id= wins, else X-Kuri-Session (or ?session=) is resolved
// to that session's current tab. See resolveEffectiveTabIdAlloc/getSessionId.

fn handleInterceptStart(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = resolveEffectiveTabIdAlloc(arena, request, bridge) orelse {
        resp.sendError(request, 400, "Missing tab_id parameter (or set X-Kuri-Session)");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // ?patterns=a,b,c — comma-separated URL patterns to pause on. Default
    // (and what an all-blank list falls back to) is "*", matching what
    // Fetch.enable does when given no patterns at all: pause everything.
    const patterns_param: []const u8 = getDecodedQueryParamAlloc(arena, target, "patterns") orelse "*";

    var patterns_json: std.ArrayList(u8) = .empty;
    var enabled_list: std.ArrayList(u8) = .empty;
    patterns_json.appendSlice(arena, "[") catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    enabled_list.appendSlice(arena, "[") catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    var iter = std.mem.splitScalar(u8, patterns_param, ',');
    var count: usize = 0;
    while (iter.next()) |raw| {
        const pattern = std.mem.trim(u8, raw, " \t");
        if (pattern.len == 0) continue;
        if (count > 0) {
            patterns_json.appendSlice(arena, ",") catch return;
            enabled_list.appendSlice(arena, ",") catch return;
        }
        patterns_json.appendSlice(arena, "{\"urlPattern\":") catch return;
        writeJsonStringValue(&patterns_json, arena, pattern) catch return;
        patterns_json.appendSlice(arena, "}") catch return;
        writeJsonStringValue(&enabled_list, arena, pattern) catch return;
        count += 1;
    }
    if (count == 0) {
        // Every entry was blank (e.g. ?patterns= or ?patterns=,,) — fall
        // back to "*" rather than sending Fetch.enable an empty patterns
        // array, which Chrome treats as "match nothing", the opposite of
        // what an empty param should mean here.
        patterns_json.appendSlice(arena, "{\"urlPattern\":\"*\"}") catch return;
        enabled_list.appendSlice(arena, "\"*\"") catch return;
    }
    patterns_json.appendSlice(arena, "]") catch return;
    enabled_list.appendSlice(arena, "]") catch return;

    const params = std.fmt.allocPrint(arena, "{{\"patterns\":{s}}}", .{patterns_json.items}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    _ = client.send(arena, protocol.Methods.fetch_enable, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    client.setInterceptActive(true);

    const body = std.fmt.allocPrint(
        arena,
        "{{\"status\":\"ok\",\"message\":\"Fetch.enable sent\",\"tab_id\":\"{s}\",\"patterns\":{s}}}",
        .{ tab_id, enabled_list.items },
    ) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleInterceptStop(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = resolveEffectiveTabIdAlloc(arena, request, bridge) orelse {
        resp.sendError(request, 400, "Missing tab_id parameter (or set X-Kuri-Session)");
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

    client.setInterceptActive(false);
    client.clearInterceptRules();
    client.clearPausedRequests();

    const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"message\":\"Fetch.disable sent, rules and records cleared\",\"tab_id\":\"{s}\"}}", .{tab_id}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

/// Parse a JSON rule body for POST /intercept/rules into an `InterceptRule`.
/// Accepts `url_pattern` (or `pattern`) as the URL substring to match — "*"
/// or an absent/empty value is a catch-all (matches every request, same as
/// an empty string passed straight to `InterceptState.findMatch`).
/// Returns null only when `action` is present but not one of
/// continue/abort/fulfill; every other field falls back to a sane default.
fn parseInterceptRuleBody(arena: std.mem.Allocator, body: []const u8) ?InterceptRule {
    const raw_pattern = extractSimpleJsonString(body, 0, "\"url_pattern\"") orelse
        extractSimpleJsonString(body, 0, "\"pattern\"") orelse "";
    const unescaped_pattern: []const u8 = json_util.jsonUnescape(arena, raw_pattern) catch raw_pattern;
    const url_substring = if (std.mem.eql(u8, unescaped_pattern, "*")) "" else unescaped_pattern;

    const action_str = extractSimpleJsonString(body, 0, "\"action\"") orelse "continue";
    const action: InterceptRule.Action = if (std.mem.eql(u8, action_str, "continue"))
        .@"continue"
    else if (std.mem.eql(u8, action_str, "abort"))
        .abort
    else if (std.mem.eql(u8, action_str, "fulfill"))
        .fulfill
    else
        return null;

    const status: u16 = @intCast(@min(extractSimpleJsonInt(body, 0, "\"status\"") orelse 200, 599));

    const raw_body_field = extractSimpleJsonString(body, 0, "\"body\"") orelse "";
    const response_body: []const u8 = json_util.jsonUnescape(arena, raw_body_field) catch raw_body_field;

    const raw_content_type = extractSimpleJsonString(body, 0, "\"content_type\"") orelse "application/json";
    const content_type: []const u8 = json_util.jsonUnescape(arena, raw_content_type) catch raw_content_type;

    const raw_error_reason = extractSimpleJsonString(body, 0, "\"error_reason\"") orelse "Failed";
    const error_reason: []const u8 = json_util.jsonUnescape(arena, raw_error_reason) catch raw_error_reason;

    return .{
        .url_substring = url_substring,
        .action = action,
        .status = status,
        .body = response_body,
        .content_type = content_type,
        .error_reason = error_reason,
    };
}

fn writeInterceptRuleJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, rule: InterceptRule) !void {
    try buf.appendSlice(allocator, "{");
    try writeJsonField(buf, allocator, "url_pattern", rule.url_substring);
    try buf.appendSlice(allocator, ",\"action\":\"");
    try buf.appendSlice(allocator, @tagName(rule.action));
    try buf.print(allocator, "\",\"status\":{d},", .{rule.status});
    try writeJsonField(buf, allocator, "content_type", rule.content_type);
    try buf.appendSlice(allocator, ",");
    try writeJsonField(buf, allocator, "body", rule.body);
    try buf.appendSlice(allocator, ",");
    try writeJsonField(buf, allocator, "error_reason", rule.error_reason);
    try buf.appendSlice(allocator, "}");
}

fn handleInterceptRuleAdd(request: *std.http.Server.Request, arena: std.mem.Allocator, client: *CdpClient) void {
    const raw_body = readRequestBody(request, arena) orelse {
        resp.sendError(request, 400, "Missing request body - expected JSON {\"url_pattern\":...,\"action\":\"continue|abort|fulfill\",...}");
        return;
    };

    const rule = parseInterceptRuleBody(arena, raw_body) orelse {
        resp.sendError(request, 400, "Invalid rule: action must be continue, abort, or fulfill");
        return;
    };

    client.addInterceptRule(rule) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(arena, "{\"status\":\"ok\",\"rule\":") catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    writeInterceptRuleJson(&buf, arena, rule) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    buf.appendSlice(arena, "}") catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    resp.sendJson(request, buf.items);
}

fn handleInterceptRules(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = resolveEffectiveTabIdAlloc(arena, request, bridge) orelse {
        resp.sendError(request, 400, "Missing tab_id parameter (or set X-Kuri-Session)");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    if (request.head.method == .POST) {
        handleInterceptRuleAdd(request, arena, client);
        return;
    }

    const rules = client.snapshotInterceptRules(arena) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(arena, "{\"rules\":[") catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    for (rules, 0..) |r, i| {
        if (i > 0) buf.appendSlice(arena, ",") catch return;
        writeInterceptRuleJson(&buf, arena, r) catch return;
    }
    buf.print(arena, "],\"count\":{d}}}", .{rules.len}) catch return;

    resp.sendJson(request, buf.items);
}

fn handleInterceptRulesClear(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = resolveEffectiveTabIdAlloc(arena, request, bridge) orelse {
        resp.sendError(request, 400, "Missing tab_id parameter (or set X-Kuri-Session)");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    client.clearInterceptRules();

    const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"message\":\"rules cleared\",\"tab_id\":\"{s}\"}}", .{tab_id}) catch {
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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

/// Write a single JSON-escaped string value (with surrounding quotes, no
/// key) — the bare-value counterpart to `writeJsonField`'s "key":"value".
fn writeJsonStringValue(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    const escaped = try json_util.jsonEscape(value, allocator);
    defer allocator.free(escaped);
    try buf.print(allocator, "\"{s}\"", .{escaped});
}

fn handleEmulate(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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

fn handleDebugEnable(
    request: *std.http.Server.Request,
    arena: std.mem.Allocator,
    bridge: *Bridge,
) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const ref = getQueryParam(target, "ref") orelse {
        resp.sendError(request, 400, "Missing ref parameter");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // Resolve the ref to a real backendNodeId the same way /upload does.
    bridge.mu.lockShared();
    const cache = bridge.snapshots.get(tab_id);
    bridge.mu.unlockShared();
    const bid = if (cache) |c| c.refs.get(ref) else null;
    const backend_node_id = bid orelse {
        resp.sendError(request, 400, "Ref not found. Call /snapshot first to populate refs");
        return;
    };

    // Overlay.highlightNode requires Overlay.enable to have been called on
    // this session first -- without it Chrome rejects the call outright
    // ({"error":{"code":-32600,"message":"Overlay must be enabled before a
    // tool can be shown"}}), which the old code never checked for (it just
    // discarded the response), so the highlight silently never appeared.
    _ = client.send(arena, protocol.Methods.overlay_enable, null) catch {
        resp.sendError(request, 502, "Overlay.enable failed");
        return;
    };

    // Highlight the node with an overlay
    const highlight_params = std.fmt.allocPrint(arena, "{{\"backendNodeId\":{d},\"highlightConfig\":{{\"showInfo\":true,\"contentColor\":{{\"r\":111,\"g\":168,\"b\":220,\"a\":0.66}}}}}}", .{backend_node_id}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const highlight_response = client.send(arena, protocol.Methods.overlay_highlight_node, highlight_params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    // client.send only errors on transport failure -- a CDP-level rejection
    // (bad backendNodeId, domain not enabled, etc.) still comes back as a
    // normal response with an embedded "error" field and must be checked
    // explicitly, same as the Network.getResponseBody handling above.
    if (jsonscan.extractObject(highlight_response, "error")) |err_obj| {
        const err_msg = jsonscan.extractField(err_obj, "message") orelse "Overlay.highlightNode returned an error";
        resp.sendError(request, 502, err_msg);
        return;
    }

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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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

fn writeScreencastFrameJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, frame: ScreencastFrameRecord) !void {
    try buf.appendSlice(allocator, "{");
    try writeJsonField(buf, allocator, "data_b64", frame.data_b64);
    try buf.appendSlice(allocator, ",");
    try buf.print(allocator, "\"timestamp\":{d},\"device_width\":{d},\"device_height\":{d},\"session_id\":{d}", .{
        frame.timestamp, frame.device_width, frame.device_height, frame.session_id,
    });
    try buf.appendSlice(allocator, "}");
}

/// Shared core for /screencast/start and /video/start -- CDP has exactly one
/// frame-streaming mechanism (Page.startScreencast); "video" is not a
/// separate capability, so both endpoints drive the same client.zig
/// ScreencastRing collector. `status_word` and `extra_note` are the only
/// things that differ between the two, so they're honest about which is
/// which rather than /video silently aliasing /screencast's response.
fn startScreencastCapture(
    request: *std.http.Server.Request,
    arena: std.mem.Allocator,
    bridge: *Bridge,
    status_word: []const u8,
    extra_note: ?[]const u8,
) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // Validate rather than interpolate raw query text into the outgoing CDP
    // command: format is one of two literals, quality is clamped to CDP's
    // valid 0-100 range.
    const format_param = getQueryParam(target, "format") orelse "jpeg";
    const format: []const u8 = if (std.mem.eql(u8, format_param, "png")) "png" else "jpeg";
    const quality: u8 = blk: {
        const q_str = getQueryParam(target, "quality") orelse "80";
        const q = std.fmt.parseInt(u16, q_str, 10) catch 80;
        break :blk @intCast(@min(q, 100));
    };
    const params = std.fmt.allocPrint(arena, "{{\"format\":\"{s}\",\"quality\":{d}}}", .{ format, quality }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    // Fresh session: don't hand back frames left over from a prior
    // start/stop pair that was never drained.
    client.clearScreencastFrames();

    _ = client.send(arena, protocol.Methods.page_start_screencast, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    buf.print(
        arena,
        "{{\"status\":\"{s}_started\",\"tab_id\":\"{s}\",\"format\":\"{s}\",\"quality\":{d}",
        .{ status_word, tab_id, format, quality },
    ) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    if (extra_note) |note| {
        buf.appendSlice(arena, ",") catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        writeJsonField(&buf, arena, "note", note) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
    }
    buf.appendSlice(arena, "}") catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, buf.items);
}

/// Shared core for /screencast/stop and /video/stop. See
/// `CdpClient.snapshotScreencastFrames`'s doc comment for the design-limit
/// context: frames only get pulled off the socket while some command is in
/// flight, so this drains explicitly (best-effort, no-op on Windows) both
/// before and after the stop command to catch frames Chrome sent right up
/// to (and just after) the stop ack.
///
/// `?frames=` controls response size, since a full session can legitimately
/// hold up to the ring's own 32 MiB / 30-frame cap:
///   - "latest" (default): just the single most recent frame -- the common
///     "give me a snapshot" case, kept small on purpose.
///   - "all": every held frame, inline. Safe to inline because the ring
///     upstream already bounds this to <=32 MiB; this is the "retrieval
///     path" opt-in for callers who actually want the whole capture.
///   - "none": counts only, no frame bytes at all.
fn stopScreencastCapture(
    request: *std.http.Server.Request,
    arena: std.mem.Allocator,
    bridge: *Bridge,
    status_word: []const u8,
    extra_note: ?[]const u8,
) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    client.drainWsEvents(arena, 1);

    _ = client.send(arena, protocol.Methods.page_stop_screencast, null) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };

    // Chrome can still deliver a frame or two that raced the stop ack.
    client.drainWsEvents(arena, 1);

    const frames_mode = getQueryParam(target, "frames") orelse "latest";
    const frames = client.snapshotScreencastFrames(arena) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const dropped = client.droppedScreencastFrameCount();
    const frame_count = frames.len;
    client.clearScreencastFrames();

    var buf: std.ArrayList(u8) = .empty;
    buf.print(
        arena,
        "{{\"status\":\"{s}_stopped\",\"tab_id\":\"{s}\",\"frame_count\":{d},\"dropped_oversize\":{d}",
        .{ status_word, tab_id, frame_count, dropped },
    ) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    if (std.mem.eql(u8, frames_mode, "all")) {
        buf.appendSlice(arena, ",\"frames\":[") catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        for (frames, 0..) |f, i| {
            if (i > 0) buf.appendSlice(arena, ",") catch return;
            writeScreencastFrameJson(&buf, arena, f) catch return;
        }
        buf.appendSlice(arena, "]") catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
    } else if (!std.mem.eql(u8, frames_mode, "none")) {
        buf.appendSlice(arena, ",\"latest_frame\":") catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        if (frame_count > 0) {
            writeScreencastFrameJson(&buf, arena, frames[frame_count - 1]) catch {
                resp.sendError(request, 500, "Internal Server Error");
                return;
            };
        } else {
            buf.appendSlice(arena, "null") catch {
                resp.sendError(request, 500, "Internal Server Error");
                return;
            };
        }
    }

    if (extra_note) |note| {
        buf.appendSlice(arena, ",") catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        writeJsonField(&buf, arena, "note", note) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
    }
    buf.appendSlice(arena, "}") catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, buf.items);
}

fn handleScreencastStart(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    startScreencastCapture(request, arena, bridge, "screencast", null);
}

fn handleScreencastStop(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    stopScreencastCapture(request, arena, bridge, "screencast", null);
}

// kuri has no video encoder (no ffmpeg/libav dependency) -- there is no
// second capability behind /video/*, so rather than a canned response that
// silently reused /screencast's wording, these are honest about reusing
// Page.startScreencast/stopScreencast and returning raw frames, not a
// .mp4/.webm file.
const video_note = "kuri does not encode video (no ffmpeg/libav dependency). This drives the same CDP Page.startScreencast/stopScreencast capture as /screencast/*, returning base64 frames with timestamps -- no video file is produced. Encode client-side if you need one.";

fn handleVideoStart(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    startScreencastCapture(request, arena, bridge, "video", video_note);
}

fn handleVideoStop(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    stopScreencastCapture(request, arena, bridge, "video", video_note);
}

// ── Lightpanda Parity Endpoints ─────────────────────────────────────────

fn handleMarkdown(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;

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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;

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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;

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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;

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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;

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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;

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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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

    // Perform a full drag-and-drop sequence via DataTransfer events. CDP's
    // Runtime.callFunctionOn only binds `this` to the object matching the
    // given objectId, so a single call cannot dispatch on both src and tgt —
    // this needs three separate calls sharing state through a page-global
    // (window.__kuri_dragDT), same idea as Playwright's dragTo internals.
    const start_js =
        \\{"objectId":"SRC_OID","functionDeclaration":"function() { var dt = new DataTransfer(); window.__kuri_dragDT = dt; this.dispatchEvent(new DragEvent('dragstart',{bubbles:true,cancelable:true,dataTransfer:dt})); this.dispatchEvent(new DragEvent('drag',{bubbles:true,cancelable:true,dataTransfer:dt})); return 'dragstart_ok'; }","returnByValue":true}
    ;
    const start_params = std.mem.replaceOwned(u8, arena, start_js, "SRC_OID", src_oid) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.runtime_call_function_on, start_params) catch {
        resp.sendError(request, 502, "dragstart failed");
        return;
    };

    const drop_js =
        \\{"objectId":"TGT_OID","functionDeclaration":"function() { var dt = window.__kuri_dragDT; this.dispatchEvent(new DragEvent('dragenter',{bubbles:true,cancelable:true,dataTransfer:dt})); this.dispatchEvent(new DragEvent('dragover',{bubbles:true,cancelable:true,dataTransfer:dt})); this.dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:dt})); return 'drop_ok'; }","returnByValue":true}
    ;
    const drop_params = std.mem.replaceOwned(u8, arena, drop_js, "TGT_OID", tgt_oid) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const drop_response = client.send(arena, protocol.Methods.runtime_call_function_on, drop_params) catch {
        resp.sendError(request, 502, "drop failed");
        return;
    };

    const end_js =
        \\{"objectId":"SRC_OID","functionDeclaration":"function() { var dt = window.__kuri_dragDT; this.dispatchEvent(new DragEvent('dragend',{bubbles:true,cancelable:true,dataTransfer:dt})); delete window.__kuri_dragDT; return 'dragend_ok'; }","returnByValue":true}
    ;
    const end_params = std.mem.replaceOwned(u8, arena, end_js, "SRC_OID", src_oid) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, protocol.Methods.runtime_call_function_on, end_params) catch {};

    resp.sendJson(request, drop_response);
}

fn handleKeyboardType(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const text = getDecodedQueryParamAlloc(arena, target, "text") orelse {
        resp.sendError(request, 400, "Missing text parameter");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // Type each Unicode codepoint via Input.dispatchKeyEvent. Iterating over
    // raw bytes (text: []const u8) would split any multi-byte UTF-8 character
    // (accents, emoji, CJK, ...) into individual invalid bytes.
    var utf8_iter: std.unicode.Utf8Iterator = .{ .bytes = text, .i = 0 };
    while (utf8_iter.nextCodepointSlice()) |cp_bytes| {
        const char_str = jsonEscapeAlloc(arena, cp_bytes) orelse continue;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = resolveEffectiveTabIdAlloc(arena, request, bridge) orelse {
        resp.sendError(request, 400, "Missing tab_id parameter (or set X-Kuri-Session)");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // Enable Runtime to collect exceptions, then evaluate to get any stored errors
    _ = client.send(arena, protocol.Methods.runtime_enable, null) catch {};
    const params = "{\"expression\":\"(function(){ var e=window.__kuri_errors||[]; window.__kuri_errors=[]; return JSON.stringify(e); })()\",\"returnByValue\":true}";
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleSetOffline(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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

    // NOTE: this deliberately does NOT call Fetch.enable({handleAuthRequests:true}).
    // Doing so makes Chrome pause on Fetch.authRequired for real 401/407 challenges,
    // and nothing in this codebase answers that event (no Fetch.continueWithAuth
    // anywhere) — the paused request would hang forever. Real interactive
    // auth-challenge handling needs the async background CDP event reader
    // described for /intercept; until that exists, rely solely on the
    // preemptive Authorization header below, which works for servers that
    // accept preemptive Basic auth (the common case).

    // Set as a preemptive Authorization header for immediate use
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const categories = getQueryParam(target, "categories") orelse "-*,devtools.timeline,v8.execute,disabled-by-default-devtools.timeline";
    // transferMode: ReturnAsStream is required for /trace/stop to be able to
    // read the trace back at all -- without it, Tracing.tracingComplete
    // carries no `stream` handle and the trace only exists as a series of
    // Tracing.dataCollected events this codebase does not accumulate.
    const params = std.fmt.allocPrint(
        arena,
        "{{\"categories\":\"{s}\",\"options\":\"sampling-frequency=10000\",\"transferMode\":\"ReturnAsStream\"}}",
        .{categories},
    ) catch {
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    _ = client.send(arena, protocol.Methods.tracing_end, null) catch {
        resp.sendError(request, 502, "Tracing.end failed");
        return;
    };

    // Tracing.end only *requests* a stop; the trace itself isn't ready
    // until Chrome emits Tracing.tracingComplete (carrying the IO stream
    // handle, since /trace/start requests transferMode: ReturnAsStream).
    // waitForEvent is what actually pumps the read loop so
    // collectTracingComplete (client.zig) gets a chance to observe and
    // store it -- see the "paused CDP events only make forward progress
    // while a command is in flight" design limit.
    if (!client.waitForEvent(arena, "Tracing.tracingComplete", 400)) {
        resp.sendError(request, 504, "Tracing.tracingComplete was not observed before timing out");
        return;
    }

    const stream_rec = (client.takeTraceStream(arena) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    }) orelse {
        // tracingComplete fired without a `stream` field (e.g. an empty
        // trace). Nothing to drain -- say so honestly rather than
        // fabricating trace content that was never produced.
        const body = std.fmt.allocPrint(
            arena,
            "{{\"ok\":true,\"status\":\"trace_complete_no_stream\",\"tab_id\":\"{s}\"}}",
            .{tab_id},
        ) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        resp.sendJson(request, body);
        return;
    };

    const home = compat.getenv("HOME") orelse {
        resp.sendError(request, 500, "Cannot determine HOME directory to write trace file");
        return;
    };
    const dir_path = std.fmt.allocPrint(arena, "{s}/.kuri/traces", .{home}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    compat.cwdMakePath(dir_path) catch {
        resp.sendError(request, 500, "Failed to create ~/.kuri/traces directory");
        return;
    };
    const file_path = std.fmt.allocPrint(
        arena,
        "{s}/trace-{s}-{d}.json",
        .{ dir_path, tab_id, compat.milliTimestamp() },
    ) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    const fd = compat.cwdCreateFile(file_path) catch {
        resp.sendError(request, 500, "Failed to create trace file (unsupported on this platform, or a disk error)");
        return;
    };
    var closed = false;
    defer if (!closed) compat.fdClose(fd);

    const escaped_handle = jsonEscapeAlloc(arena, stream_rec.stream_handle) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    // Trace files can legitimately be huge (real profiling sessions run
    // tens to hundreds of MB); stream to disk chunk-by-chunk via IO.read
    // rather than buffering the whole thing in memory, bounded by a hard
    // safety ceiling so a runaway stream can't grow the file unbounded.
    const max_trace_bytes: usize = 512 * 1024 * 1024;
    const chunk_size: usize = 1024 * 1024;
    var total_bytes: usize = 0;
    var eof = false;
    var read_error: ?[]const u8 = null;
    var iterations: usize = 0;

    while (!eof) {
        iterations += 1;
        if (iterations > 5000) {
            read_error = "IO.read did not reach eof within the iteration safety cap";
            break;
        }
        const io_params = std.fmt.allocPrint(arena, "{{\"handle\":\"{s}\",\"size\":{d}}}", .{ escaped_handle, chunk_size }) catch {
            read_error = "Internal Server Error";
            break;
        };
        const io_response = client.send(arena, protocol.Methods.io_read, io_params) catch {
            read_error = "IO.read failed";
            break;
        };
        const data = jsonscan.extractField(io_response, "data") orelse {
            read_error = "IO.read returned no data field";
            break;
        };
        const eof_str = jsonscan.extractField(io_response, "eof") orelse "false";
        eof = std.mem.eql(u8, eof_str, "true");
        const b64_str = jsonscan.extractField(io_response, "base64Encoded");
        const is_base64 = if (b64_str) |v| std.mem.eql(u8, v, "true") else false;

        var decoded: []const u8 = &.{};
        if (is_base64) {
            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data) catch {
                read_error = "Invalid base64 in IO.read response";
                break;
            };
            const out = arena.alloc(u8, decoded_len) catch {
                read_error = "Internal Server Error";
                break;
            };
            std.base64.standard.Decoder.decode(out, data) catch {
                read_error = "Invalid base64 in IO.read response";
                break;
            };
            decoded = out;
        } else {
            decoded = json_util.jsonUnescape(arena, data) catch {
                read_error = "Internal Server Error";
                break;
            };
        }

        if (total_bytes + decoded.len > max_trace_bytes) {
            read_error = "Trace exceeded the 512 MiB safety cap; aborted";
            break;
        }
        compat.fdWriteAll(fd, decoded) catch {
            read_error = "Failed to write trace file";
            break;
        };
        total_bytes += decoded.len;
    }

    compat.fdClose(fd);
    closed = true;

    // Always tell Chrome we're done with the stream, success or not.
    if (std.fmt.allocPrint(arena, "{{\"handle\":\"{s}\"}}", .{escaped_handle}) catch null) |close_params| {
        _ = client.send(arena, protocol.Methods.io_close, close_params) catch {};
    }

    if (read_error) |msg| {
        compat.cwdDeleteFile(file_path) catch {};
        resp.sendError(request, 502, msg);
        return;
    }

    const escaped_path = jsonEscapeAlloc(arena, file_path) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const escaped_format = jsonEscapeAlloc(arena, stream_rec.trace_format) orelse "";
    const body = std.fmt.allocPrint(
        arena,
        "{{\"ok\":true,\"status\":\"trace_complete\",\"tab_id\":\"{s}\",\"path\":\"{s}\",\"bytes\":{d},\"data_loss\":{s},\"trace_format\":\"{s}\"}}",
        .{ tab_id, escaped_path, total_bytes, if (stream_rec.data_loss) "true" else "false", escaped_format },
    ) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleProfilerStart(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    // Inspector.enable has no synchronous introspection counterpart in
    // CDP -- it only arms two future notifications (Inspector.targetCrashed,
    // Inspector.detached) that this codebase doesn't yet surface anywhere.
    // Report exactly that instead of a canned "DevTools enabled" message
    // implying a devtools session or queryable state now exists.
    _ = client.send(arena, protocol.Methods.inspector_enable, null) catch {
        resp.sendError(request, 502, "Inspector.enable failed");
        return;
    };
    const body = std.fmt.allocPrint(
        arena,
        "{{\"ok\":true,\"action\":\"inspector_enable\",\"tab_id\":\"{s}\",\"note\":\"Inspector.enable succeeded. CDP's Inspector domain has no synchronous introspection command -- it only arms Inspector.targetCrashed/Inspector.detached notifications, which kuri does not yet surface. There is no further state to retrieve from this endpoint.\"}}",
        .{tab_id},
    ) catch {
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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

fn writeNetworkRecordJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, rec: NetworkRecord) !void {
    try buf.appendSlice(allocator, "{");
    try writeJsonField(buf, allocator, "request_id", rec.request_id);
    try buf.appendSlice(allocator, ",");
    try writeJsonField(buf, allocator, "url", rec.url);
    try buf.appendSlice(allocator, ",");
    try writeJsonField(buf, allocator, "method", rec.method);
    try buf.appendSlice(allocator, ",");
    try writeJsonField(buf, allocator, "mime_type", rec.mime_type);
    try buf.print(allocator, ",\"url_truncated\":{s},\"timestamp\":{d}}}", .{ if (rec.url_truncated) "true" else "false", rec.timestamp });
}

/// `mode=enable|disable` (default `enable`) flip Network.enable/disable,
/// same as before. `mode=list` is new: a lightweight, read-only view over
/// the bounded 200-record ring client.zig's Network collector keeps
/// passively (url/method/mime_type/timestamp only) -- it never touches
/// enable/disable state. This deliberately does NOT duplicate /har/*:
/// /har/start + /har/stop gives full headers/timing/bodies via a dedicated
/// recorder; /network?mode=list is the cheap "what's happened recently"
/// check that doesn't require starting a HAR capture first.
fn handleNetwork(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const mode = getQueryParam(target, "mode") orelse "enable";
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    if (std.mem.eql(u8, mode, "list")) {
        client.drainWsEvents(arena, 1);
        const url_filter = getDecodedQueryParamAlloc(arena, target, "url");
        const records = client.snapshotNetworkRequests(arena) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        var buf: std.ArrayList(u8) = .empty;
        buf.appendSlice(arena, "{\"ok\":true,\"requests\":[") catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        var written: usize = 0;
        for (records) |rec| {
            if (url_filter) |wanted| {
                if (std.mem.indexOf(u8, rec.url, wanted) == null) continue;
            }
            if (written > 0) buf.appendSlice(arena, ",") catch return;
            writeNetworkRecordJson(&buf, arena, rec) catch return;
            written += 1;
        }
        buf.print(
            arena,
            "],\"count\":{d},\"tab_id\":\"{s}\",\"note\":\"lightweight view over a bounded 200-record ring (url/method/mime_type/timestamp only); for full headers/timing/response bodies use /har/start + /har/stop\"}}",
            .{ written, tab_id },
        ) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        resp.sendJson(request, buf.items);
        return;
    }

    const method = if (std.mem.eql(u8, mode, "disable")) protocol.Methods.network_disable else protocol.Methods.network_enable;
    _ = client.send(arena, method, null) catch {
        resp.sendError(request, 502, "Network command failed");
        return;
    };
    if (std.mem.eql(u8, mode, "disable")) client.clearNetworkRequests();
    const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"network\":\"{s}\"}}", .{mode}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handlePerfLcp(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
// Backwards compatible: while interception is inactive for this tab
// (nobody has called /intercept/start, or /intercept/stop already ran),
// this falls back to the pre-existing Resource Timing API snapshot so
// existing callers keep getting a non-empty answer. Once interception is
// active, this returns the REAL Fetch.requestPaused records the
// auto-responder recorded — including tabs where zero requests have paused
// yet (an empty "requests":[] is still a real, correct answer once
// active). The `source` field lets callers tell the two shapes apart.
fn handleInterceptRequests(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_id = resolveEffectiveTabIdAlloc(arena, request, bridge) orelse {
        resp.sendError(request, 400, "Missing tab_id parameter (or set X-Kuri-Session)");
        return;
    };
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    if (client.interceptActive()) {
        const records = client.snapshotPausedRequests(arena) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };

        var buf: std.ArrayList(u8) = .empty;
        buf.appendSlice(arena, "{\"source\":\"intercepted\",\"requests\":[") catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        for (records, 0..) |rec, i| {
            if (i > 0) buf.appendSlice(arena, ",") catch return;
            buf.appendSlice(arena, "{") catch return;
            writeJsonField(&buf, arena, "request_id", rec.request_id) catch return;
            buf.appendSlice(arena, ",") catch return;
            writeJsonField(&buf, arena, "url", rec.url) catch return;
            buf.appendSlice(arena, ",") catch return;
            writeJsonField(&buf, arena, "method", rec.method) catch return;
            buf.appendSlice(arena, ",") catch return;
            writeJsonField(&buf, arena, "resource_type", rec.resource_type) catch return;
            buf.appendSlice(arena, ",\"action\":\"") catch return;
            buf.appendSlice(arena, @tagName(rec.action_taken)) catch return;
            buf.print(arena, "\",\"status\":{d},\"timestamp\":{d}}}", .{ rec.status, rec.timestamp }) catch return;
        }
        buf.print(arena, "],\"count\":{d}}}", .{records.len}) catch return;

        resp.sendJson(request, buf.items);
        return;
    }

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

    // Splice a "source" field into the CDP response's top-level object so
    // existing callers parsing .result.result.value keep working exactly
    // as before, while new callers can check .source.
    const wrapped = if (response.len > 0 and response[0] == '{')
        std.fmt.allocPrint(arena, "{{\"source\":\"resource_timing\",{s}", .{response[1..]}) catch response
    else
        response;

    resp.sendJson(request, wrapped);
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
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
    const prompt_text: []const u8 = getDecodedQueryParamAlloc(arena, target, "text") orelse "";

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    _ = client.send(arena, protocol.Methods.page_enable, null) catch {};

    // mode=off / mode=disable turns the CDP-level auto-responder back off
    // without touching any dialog that might currently be open.
    const disabling = std.mem.eql(u8, mode, "off") or std.mem.eql(u8, mode, "disable");
    const accept = !std.mem.eql(u8, mode, "dismiss");
    const accept_str = if (accept) "true" else "false";

    // Wire the CDP read-loop auto-responder (client.zig) so
    // Page.javascriptDialogOpening is answered even between HTTP calls —
    // not just via the window-level JS listeners below, which only cover
    // dialogs the page itself can see and only while this handler's own
    // Runtime.evaluate calls are in flight.
    client.setDialogAuto(!disabling, accept, prompt_text) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    if (disabling) {
        const off_body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"mode\":\"{s}\"}}", .{mode}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        resp.sendJson(request, off_body);
        return;
    }

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

/// `?request_id=` (direct) or `?url=` (looked up against client.zig's
/// bounded Network collector -- see `findNetworkRequestByUrl`) resolve a
/// real CDP requestId, then this calls Network.getResponseBody against it.
/// This replaced a `runtime_evaluate(fetch(url))` workaround: that re-issued
/// a brand new same-origin-restricted request instead of returning what the
/// page actually received (wrong body on redirects/POSTs/opaque responses,
/// and simply failed cross-origin without CORS).
fn handleResponseBody(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const direct_request_id = getDecodedQueryParamAlloc(arena, target, "request_id");
    var request_id: []const u8 = undefined;
    var matched_url: ?[]const u8 = null;
    if (direct_request_id) |rid| {
        request_id = rid;
    } else {
        const url_pattern = getDecodedQueryParamAlloc(arena, target, "url") orelse {
            resp.sendError(request, 400, "Missing request_id or url parameter");
            return;
        };
        client.drainWsEvents(arena, 1);
        const rec = (client.findNetworkRequestByUrl(arena, url_pattern) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        }) orelse {
            resp.sendError(
                request,
                404,
                "No recorded network request matches that url substring (is Network.enable active for this tab, e.g. via /network?mode=enable, and did the request already happen?)",
            );
            return;
        };
        request_id = rec.request_id;
        matched_url = rec.url;
    }

    const escaped_request_id = jsonEscapeAlloc(arena, request_id) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const params = std.fmt.allocPrint(arena, "{{\"requestId\":\"{s}\"}}", .{escaped_request_id}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.network_get_response_body, params) catch {
        resp.sendError(request, 502, "Network.getResponseBody failed");
        return;
    };

    if (jsonscan.extractObject(response, "error")) |err_obj| {
        const err_msg = jsonscan.extractField(err_obj, "message") orelse "Network.getResponseBody returned an error";
        resp.sendError(request, 502, err_msg);
        return;
    }

    const body_field = jsonscan.extractField(response, "body") orelse {
        resp.sendJson(request, response);
        return;
    };
    const base64_str = jsonscan.extractField(response, "base64Encoded");
    const is_base64 = if (base64_str) |v| std.mem.eql(u8, v, "true") else false;

    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(arena, "{\"ok\":true,\"request_id\":") catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    writeJsonStringValue(&buf, arena, request_id) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    if (matched_url) |u| {
        buf.appendSlice(arena, ",\"url\":") catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        writeJsonStringValue(&buf, arena, u) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
    }
    buf.print(arena, ",\"base64Encoded\":{s},\"body\":\"{s}\"}}", .{ if (is_base64) "true" else "false", body_field }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, buf.items);
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
    // Dispatching a plain `new Event(type, ...)` never triggers the browser's
    // native default action for an untrusted event — a bare 'click' never
    // navigates a link and a bare 'submit' never actually submits a form,
    // only JS listeners fire. For the types where that matters, call the
    // real native method (el.click() / form.requestSubmit()) instead. Mouse
    // types need a real MouseEvent (listeners often read e.button/e.view);
    // pointer types (canvas apps, custom sliders, DnD libraries that listen
    // for pointerdown/pointermove) need a real PointerEvent with pointerId/
    // pointerType/clientX/clientY set, or `instanceof PointerEvent` checks
    // and coordinate reads silently see undefined; keyboard types need a
    // real KeyboardEvent for the same reason (dedicated /keydown, /keyup,
    // /keyboard/type already cover the common case via genuine
    // Input.dispatchKeyEvent, this is for symmetry/generic dispatch). Other
    // types (change, input, ...) have no native default action and a plain
    // bubbling+cancelable Event is exactly what listeners expect.
    const js = std.fmt.allocPrint(arena,
        \\function() {{ var t='{s}'; if (t==='click') {{ this.click(); return 'dispatched'; }} if (t==='submit') {{ var f = (this.tagName==='FORM') ? this : this.form; if (f) {{ if (f.requestSubmit) f.requestSubmit(); else f.submit(); return 'dispatched'; }} this.dispatchEvent(new Event('submit',{{bubbles:true,cancelable:true}})); return 'dispatched'; }} if (t==='dblclick'||t==='mousedown'||t==='mouseup'||t==='mouseover'||t==='mouseout'||t==='mouseenter'||t==='mouseleave') {{ this.dispatchEvent(new MouseEvent(t,{{bubbles:true,cancelable:true,view:window}})); return 'dispatched'; }} if (t==='pointerdown'||t==='pointerup'||t==='pointermove'||t==='pointerover'||t==='pointerout'||t==='pointerenter'||t==='pointerleave'||t==='pointercancel') {{ var r = this.getBoundingClientRect(); var cx = r.left + r.width/2, cy = r.top + r.height/2; this.dispatchEvent(new PointerEvent(t,{{bubbles:true,cancelable:true,view:window,pointerId:1,pointerType:'mouse',isPrimary:true,clientX:cx,clientY:cy}})); return 'dispatched'; }} if (t==='keydown'||t==='keyup'||t==='keypress') {{ this.dispatchEvent(new KeyboardEvent(t,{{bubbles:true,cancelable:true,view:window}})); return 'dispatched'; }} this.dispatchEvent(new Event(t,{{bubbles:true,cancelable:true}})); return 'dispatched'; }}
    , .{escaped_type}) catch {
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

/// Resolve the directory Chrome should save downloads into: `?dir=` query
/// param (percent-decoded) if given, else a fixed fallback. Both /download
/// and /wait/download call this instead of each hardcoding the same
/// literal path with no way for a caller to override it.
///
/// (An environment-variable tier was considered too, but this Zig
/// toolchain's `std.process` no longer exposes a plain
/// `getEnvVarOwned(allocator, key)` — env vars now go through
/// `std.process.Environ`/`Environ.Map`, which needs an already-scanned
/// environ handle this per-request code path doesn't have one of. Not
/// worth pulling that machinery in for a single fallback tier when the
/// query param already makes this configurable.)
fn resolveDownloadDir(arena: std.mem.Allocator, target: []const u8) []const u8 {
    if (getDecodedQueryParamAlloc(arena, target, "dir")) |d| return d;
    return "/tmp/kuri-downloads";
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
    const download_dir = resolveDownloadDir(arena, target);
    const escaped_dir = jsonEscapeAlloc(arena, download_dir) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const behavior_params = std.fmt.allocPrint(arena, "{{\"behavior\":\"allow\",\"downloadPath\":\"{s}\"}}", .{escaped_dir}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, "Page.setDownloadBehavior", behavior_params) catch {
        resp.sendError(request, 502, "Page.setDownloadBehavior failed");
        return;
    };
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
    // Runtime.bindingCalled is only delivered once the Runtime domain is
    // enabled -- without this, Runtime.addBinding silently succeeds but the
    // endpoint's whole purpose (observing page -> host calls) never fires.
    _ = client.send(arena, protocol.Methods.runtime_enable, null) catch {};
    _ = client.send(arena, protocol.Methods.runtime_add_binding, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    const body = std.fmt.allocPrint(
        arena,
        "{{\"ok\":true,\"action\":\"expose\",\"name\":\"{s}\",\"tab_id\":\"{s}\",\"retrieve_calls_at\":\"/expose/calls?tab_id={s}&name={s}\"}}",
        .{ escaped_name, tab_id, tab_id, escaped_name },
    ) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

/// Retrieval half of /expose: without this, `window.<name>(...)` calls the
/// page makes into the binding it just registered are captured by
/// `CdpClient`'s BindingCallRing (see client.zig's Case 2 collector) but
/// nothing ever hands them back out -- the whole reason /expose exists.
/// `?name=` filters to one binding; `?clear=true` drains the ring after
/// reading (so repeated polling doesn't see the same calls twice).
fn handleExposeCalls(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const name_filter = getDecodedQueryParamAlloc(arena, target, "name");
    const should_clear = if (getQueryParam(target, "clear")) |v| std.mem.eql(u8, v, "true") else false;

    // Best-effort: pull any bindingCalled events already sitting on the
    // socket into the ring before snapshotting -- see the "paused CDP
    // events only make forward progress while a command is in flight"
    // design limit noted on the collector accessors in client.zig. No-op
    // on Windows (see drainWsEvents).
    client.drainWsEvents(arena, 1);

    const calls = client.snapshotBindingCalls(arena) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(arena, "{\"ok\":true,\"calls\":[") catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    var written: usize = 0;
    for (calls) |call| {
        if (name_filter) |wanted| {
            if (!std.mem.eql(u8, call.name, wanted)) continue;
        }
        if (written > 0) buf.appendSlice(arena, ",") catch return;
        buf.appendSlice(arena, "{") catch return;
        writeJsonField(&buf, arena, "name", call.name) catch return;
        buf.appendSlice(arena, ",") catch return;
        writeJsonField(&buf, arena, "payload", call.payload) catch return;
        buf.print(arena, ",\"truncated\":{s},\"timestamp\":{d}}}", .{ if (call.truncated) "true" else "false", call.timestamp }) catch return;
        written += 1;
    }
    buf.print(arena, "],\"count\":{d},\"tab_id\":\"{s}\"}}", .{ written, tab_id }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    if (should_clear) client.clearBindingCalls();

    resp.sendJson(request, buf.items);
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
        \\  // lcp/cls/fid entry types are buffered by Chromium from navigation
        \\  // start regardless of whether a PerformanceObserver was ever
        \\  // registered, so getEntriesByType legitimately retrieves real,
        \\  // already-occurred values here (same technique /perf/lcp uses).
        \\  var lcp = 0, lcpMeasured = false;
        \\  try {
        \\    var lcpEntries = performance.getEntriesByType('largest-contentful-paint');
        \\    if (lcpEntries.length) { lcp = lcpEntries[lcpEntries.length - 1].startTime; lcpMeasured = true; }
        \\  } catch (e) {}
        \\  var cls = 0, clsMeasured = false;
        \\  try {
        \\    var clsEntries = performance.getEntriesByType('layout-shift');
        \\    clsMeasured = clsEntries.length > 0;
        \\    // Windowed CLS: group shifts into "sessions" (gap < 1s between
        \\    // consecutive shifts, session <= 5s total) and report the max
        \\    // session sum. This is the official web-vitals algorithm --
        \\    // unlike a lifetime running sum, it doesn't overstate CLS on
        \\    // long-lived SPA pages that accumulate many small unrelated
        \\    // shifts over a long session.
        \\    var sessionValue = 0, sessionEntries = [], maxSessionValue = 0;
        \\    clsEntries.forEach(function(e) {
        \\      if (e.hadRecentInput) return;
        \\      var first = sessionEntries[0];
        \\      var last = sessionEntries[sessionEntries.length - 1];
        \\      if (sessionValue && first && (e.startTime - last.startTime) < 1000 && (e.startTime - first.startTime) < 5000) {
        \\        sessionValue += e.value;
        \\        sessionEntries.push(e);
        \\      } else {
        \\        sessionValue = e.value;
        \\        sessionEntries = [e];
        \\      }
        \\      if (sessionValue > maxSessionValue) maxSessionValue = sessionValue;
        \\    });
        \\    cls = maxSessionValue;
        \\  } catch (e) {}
        \\  var fid = 0, fidMeasured = false;
        \\  try {
        \\    var fidEntries = performance.getEntriesByType('first-input');
        \\    if (fidEntries.length) { fid = fidEntries[0].processingStart - fidEntries[0].startTime; fidMeasured = true; }
        \\  } catch (e) {}
        \\  // *_measured distinguishes "genuinely zero" from "hasn't happened
        \\  // yet" -- fid/cls legitimately read 0 if called before any
        \\  // input/layout-shift has occurred, which looks identical to a
        \\  // real zero without this flag.
        \\  return JSON.stringify({
        \\    lcp: lcp, lcp_measured: lcpMeasured,
        \\    cls: cls, cls_measured: clsMeasured,
        \\    fid: fid, fid_measured: fidMeasured,
        \\    ttfb: ttfb, fcp: fcp, domInteractive: domInteractive
        \\  });
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

/// Extract the raw JSON array *interior* (without the enclosing `[`/`]`)
/// for `key` (e.g. "childFrames"), using the same string-aware
/// bracket-depth counting `jsonscan.extractObject` uses for `{`/`}`.
/// Returns null if `key` isn't present as an array or it never closes.
fn extractArrayInterior(json: []const u8, key: []const u8) ?[]const u8 {
    var key_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&key_buf, "\"{s}\":[", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const arr_start = key_pos + needle.len - 1; // points at '['
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var i = arr_start;
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
        switch (c) {
            '"' => in_string = true,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return json[arr_start + 1 .. i];
            },
            else => {},
        }
    }
    return null;
}

const JsonArrayElement = struct { slice: []const u8, next: usize };

/// Find the next top-level `{...}` object inside a JSON array's interior
/// (as returned by `extractArrayInterior`), scanning from `from`. Returns
/// the object slice plus the index just past its closing `}`, or null once
/// no more objects remain. String- and depth-aware, same idiom as
/// `jsonscan.extractObject`, so a nested `childFrames` array inside an
/// element (or a literal `,`/`{`/`}` inside a frame's URL string) never
/// causes a false split.
fn nextArrayObject(interior: []const u8, from: usize) ?JsonArrayElement {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var start: ?usize = null;
    var i = from;
    while (i < interior.len) : (i += 1) {
        const c = interior[i];
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
        switch (c) {
            '"' => in_string = true,
            '{' => {
                if (depth == 0) start = i;
                depth += 1;
            },
            '}' => {
                depth -= 1;
                if (depth == 0) {
                    if (start) |s| return .{ .slice = interior[s .. i + 1], .next = i + 1 };
                    start = null;
                }
            },
            else => {},
        }
    }
    return null;
}

/// Recursively search a `Page.getFrameTree` node (`{"frame":{...},
/// "childFrames":[...]}`) for a frame whose `name` matches exactly or
/// whose `url` contains `url_substr`, at ANY nesting depth. This is what
/// replaces `document.querySelector('iframe[...]')` against the top
/// document, which can only ever see the top document's *direct* iframe
/// children and is blind to a frame nested inside another frame. Returns
/// the matching frame's CDP frameId, borrowed from `tree_json`.
fn findFrameIdInTree(tree_json: []const u8, name: ?[]const u8, url_substr: ?[]const u8) ?[]const u8 {
    const frame_obj = jsonscan.extractObject(tree_json, "frame") orelse return null;
    const matches = blk: {
        if (name) |n| {
            const frame_name = jsonscan.extractField(frame_obj, "name") orelse break :blk false;
            break :blk std.mem.eql(u8, frame_name, n);
        }
        if (url_substr) |u| {
            const frame_url = jsonscan.extractField(frame_obj, "url") orelse break :blk false;
            break :blk std.mem.indexOf(u8, frame_url, u) != null;
        }
        break :blk false;
    };
    if (matches) return jsonscan.extractField(frame_obj, "id");

    const children = extractArrayInterior(tree_json, "childFrames") orelse return null;
    var cursor: usize = 0;
    while (nextArrayObject(children, cursor)) |elem| {
        if (findFrameIdInTree(elem.slice, name, url_substr)) |found| return found;
        cursor = elem.next;
    }
    return null;
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

    // Walk the full recursive frame tree (Page.getFrameTree, same call
    // /frames already uses) instead of `document.querySelector('iframe[...]
    // ')` against the top document -- that approach can only ever see the
    // top document's *direct* iframe children and is blind to a frame
    // nested inside another frame.
    _ = client.send(arena, protocol.Methods.page_enable, null) catch {};
    const tree_response = client.send(arena, protocol.Methods.page_get_frame_tree, null) catch {
        resp.sendError(request, 502, "Page.getFrameTree failed");
        return;
    };
    const frame_tree = jsonscan.extractObject(tree_response, "frameTree") orelse {
        resp.sendError(request, 500, "Could not parse Page.getFrameTree response");
        return;
    };
    const frame_id = findFrameIdInTree(frame_tree, name, url) orelse {
        resp.sendError(request, 404, "No frame in the frame tree (searched recursively) matches that name/url");
        return;
    };

    // Resolve an execution context scoped to exactly that frame via an
    // isolated world, then evaluate *inside* the target frame's own realm
    // -- so document/location are its own regardless of whether the frame
    // is cross-origin relative to the top document. This is why the old
    // `f.contentDocument.title`/`f.contentWindow.location.href` crossOrigin
    // fallback is gone: that check only existed because it was reaching
    // into the frame from the *parent's* realm, which same-origin policy
    // blocks; evaluating inside the frame's own context has no such check.
    const escaped_frame_id = jsonEscapeAlloc(arena, frame_id) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const isolated_params = std.fmt.allocPrint(arena, "{{\"frameId\":\"{s}\",\"worldName\":\"kuri_frame_probe\"}}", .{escaped_frame_id}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const isolated_response = client.send(arena, "Page.createIsolatedWorld", isolated_params) catch {
        // Honest failure case: this frame exists in the tree but this CDP
        // session can't attach an isolated world to it (e.g. a genuine
        // out-of-process cross-origin subframe not attached to this
        // target) -- report that rather than fabricating a result.
        resp.sendError(request, 502, "Page.createIsolatedWorld failed (frame may not be attached to this CDP session)");
        return;
    };
    const context_id = jsonscan.extractField(isolated_response, "executionContextId") orelse {
        resp.sendError(request, 502, "Page.createIsolatedWorld returned no executionContextId");
        return;
    };
    const js = "(function() { try { return JSON.stringify({ok:true,title:document.title,url:location.href}); } catch(e) { return JSON.stringify({ok:false,error:e.message}); } })()";
    const escaped_js = jsonEscapeAlloc(arena, js) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const eval_params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"contextId\":{s},\"returnByValue\":true}}", .{ escaped_js, context_id }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const response = client.send(arena, protocol.Methods.runtime_evaluate, eval_params) catch {
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
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };
    const response = client.send(arena, protocol.Methods.page_get_frame_tree, null) catch {
        resp.sendError(request, 502, "Page.getFrameTree failed");
        return;
    };
    // Response shape: {"id":N,"result":{"frameTree":{"frame":{"id":...,"loaderId":...,"url":...},...}}}
    // Search from "frameTree" onward so the top-level JSON-RPC "id" (a bare
    // number, not a string) is never mistaken for the frame's own "id".
    const frametree_pos = std.mem.indexOf(u8, response, "\"frameTree\"") orelse {
        resp.sendJson(request, "{\"ok\":true,\"frame\":\"main\"}");
        return;
    };
    const frame_id = extractSimpleJsonString(response, frametree_pos, "\"id\"") orelse "";
    const loader_id = extractSimpleJsonString(response, frametree_pos, "\"loaderId\"") orelse "";
    const frame_url = extractSimpleJsonString(response, frametree_pos, "\"url\"") orelse "";
    const body = std.fmt.allocPrint(
        arena,
        "{{\"ok\":true,\"frame\":\"main\",\"tab_id\":\"{s}\",\"frameId\":\"{s}\",\"loaderId\":\"{s}\",\"url\":\"{s}\"}}",
        .{ tab_id, frame_id, loader_id, frame_url },
    ) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
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

fn clampU32(s: ?[]const u8, default: u32, max: u32) u32 {
    const v = if (s) |str| (std.fmt.parseInt(u32, str, 10) catch default) else default;
    return @min(v, max);
}

fn callValueObject(arena: std.mem.Allocator, client: *CdpClient, object_id: []const u8, function_declaration: []const u8) ?[]const u8 {
    const escaped_fn = jsonEscapeAlloc(arena, function_declaration) orelse return null;
    const params = std.fmt.allocPrint(arena, "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"returnByValue\":true}}", .{ object_id, escaped_fn }) catch return null;
    const response = client.send(arena, protocol.Methods.runtime_call_function_on, params) catch return null;
    return extractJsonObjectField(response, "\"value\"");
}

/// Build the `{"id":"..."}` or `{"selector":"..."}` opts object passed to
/// window.__kuri_react.inspect(). Exactly one of id/selector is expected to
/// be non-null (enforced by the caller); selector is caller-controlled text
/// so it must be escaped before it lands inside a JS expression, same as
/// every other user-supplied string embedded elsewhere in this file.
fn buildReactInspectOpts(arena: std.mem.Allocator, id: ?[]const u8, selector: ?[]const u8) ?[]const u8 {
    if (id) |i| {
        const escaped_id = jsonEscapeAlloc(arena, i) orelse return null;
        return std.fmt.allocPrint(arena, "{{\"id\":\"{s}\"}}", .{escaped_id}) catch null;
    }
    if (selector) |s| {
        const escaped_sel = jsonEscapeAlloc(arena, s) orelse return null;
        return std.fmt.allocPrint(arena, "{{\"selector\":\"{s}\"}}", .{escaped_sel}) catch null;
    }
    return null;
}

/// React introspection. Dispatches into the persistent window.__kuri_react
/// library (src/cdp/js/react_fiber.js, injected by discoverTabs) instead of
/// rebuilding the fiber walk in an inline JS string per request. Every
/// __kuri_react.* entry point returns {"react":false} on pages with no React
/// (no fiber keys found on any DOM node) -- that check happens once, inside
/// the JS library, not per-endpoint here, so all four modes degrade the same
/// way. Responses come back via evalValueObject/callValueObject, i.e. as a
/// raw object slice -- never double-JSON-encoded through an internal
/// JSON.stringify like the old hook-gated stub did.
fn handleReact(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge, mode: []const u8) void {
    const target = request.head.target;
    const tab_id = requireEffectiveTabId(arena, request, bridge) orelse return;
    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    if (std.mem.eql(u8, mode, "tree")) {
        // Hard caps enforced here regardless of what the caller requests --
        // the number that actually matters is the 2MB CDP response ceiling
        // (client.zig's receiveMessageAlloc), not anything the JS itself
        // could sensibly self-limit to.
        const max_nodes = clampU32(getQueryParam(target, "max_nodes"), 500, 3000);
        const max_depth = clampU32(getQueryParam(target, "max_depth"), 40, 150);
        const include_text = if (getQueryParam(target, "include_host_text")) |v| std.mem.eql(u8, v, "true") else false;
        const expr = std.fmt.allocPrint(
            arena,
            "window.__kuri_react ? window.__kuri_react.tree({{\"maxNodes\":{d},\"maxDepth\":{d},\"includeHostText\":{s}}}) : {{\"react\":false}}",
            .{ max_nodes, max_depth, if (include_text) "true" else "false" },
        ) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const val = evalValueObject(arena, client, expr) orelse {
            resp.sendError(request, 502, "CDP command failed");
            return;
        };
        resp.sendJson(request, val);
        return;
    }

    if (std.mem.eql(u8, mode, "inspect")) {
        // ref: reuse the existing a11y-snapshot ref-resolution flow verbatim
        // (same shape as handleGetAttribute / handleBoundingBox) -- resolve
        // to a live DOM object, then call inspectElement(this) on it.
        if (getQueryParam(target, "ref")) |r| {
            bridge.mu.lockShared();
            const cache = bridge.snapshots.get(tab_id);
            bridge.mu.unlockShared();
            const bid = if (cache) |c| c.refs.get(r) else null;
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
            const val = callValueObject(
                arena,
                client,
                oid,
                "function(){ return window.__kuri_react ? window.__kuri_react.inspectElement(this) : {react:false}; }",
            ) orelse {
                resp.sendError(request, 502, "CDP command failed");
                return;
            };
            resp.sendJson(request, val);
            return;
        }

        // id (from a prior /react/tree or /react/suspense call) or selector.
        const id = getQueryParam(target, "id");
        const selector = getDecodedQueryParamAlloc(arena, target, "selector");
        if (id == null and selector == null) {
            resp.sendError(request, 400, "Provide one of: ref, id, selector");
            return;
        }
        const opts_json = buildReactInspectOpts(arena, id, selector) orelse {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const expr = std.fmt.allocPrint(
            arena,
            "window.__kuri_react ? window.__kuri_react.inspect({s}) : {{\"react\":false}}",
            .{opts_json},
        ) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const val = evalValueObject(arena, client, expr) orelse {
            resp.sendError(request, 502, "CDP command failed");
            return;
        };
        resp.sendJson(request, val);
        return;
    }

    if (std.mem.eql(u8, mode, "renders")) {
        // Not the React Profiler API (a much heavier commitment -- explicit
        // start/stopProfiling against a profiling bundle). This is a real,
        // bounded commit log fed by a hook stub that never depends on
        // __REACT_DEVTOOLS_GLOBAL_HOOK__ already existing; honest about its
        // one real limitation via hookAttachedBeforeInit/note in the payload
        // rather than a canned "not supported" or a made-up capability.
        const val = evalValueObject(arena, client, "window.__kuri_react ? window.__kuri_react.renders() : {\"react\":false}") orelse {
            resp.sendError(request, 502, "CDP command failed");
            return;
        };
        resp.sendJson(request, val);
        return;
    }

    if (std.mem.eql(u8, mode, "suspense")) {
        const max_nodes = clampU32(getQueryParam(target, "max_nodes"), 500, 3000);
        const expr = std.fmt.allocPrint(
            arena,
            "window.__kuri_react ? window.__kuri_react.suspense({{\"maxNodes\":{d}}}) : {{\"react\":false}}",
            .{max_nodes},
        ) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const val = evalValueObject(arena, client, expr) orelse {
            resp.sendError(request, 502, "CDP command failed");
            return;
        };
        resp.sendJson(request, val);
        return;
    }

    resp.sendError(request, 400, "Unknown react mode");
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

/// Scale a caller-supplied timeout (ms) into a `waitForEvent` attempt
/// count. Loosely calibrated, not exact: each attempt reads one message off
/// the CDP socket, which blocks for up to the socket's fixed ~10s read
/// timeout when idle, so on a truly idle connection the real wait is
/// bounded below by that single read timeout regardless of this value; on
/// a busy tab (other events arriving) this bounds how many unrelated
/// events get consumed before giving up. Same approximation existing call
/// sites (`waitForEvent(..., 1_000)`, `waitForEvent(..., 400)`) already
/// accept; clamped to a sane range either way.
fn timeoutMsToAttempts(timeout_ms: u64) u32 {
    const scaled: u64 = timeout_ms / 50;
    const clamped: u64 = if (scaled < 20) 20 else if (scaled > 20000) 20000 else scaled;
    return @intCast(clamped);
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
    const download_dir = resolveDownloadDir(arena, target);
    const escaped_dir = jsonEscapeAlloc(arena, download_dir) orelse {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    const behavior_params = std.fmt.allocPrint(arena, "{{\"behavior\":\"allow\",\"downloadPath\":\"{s}\"}}", .{escaped_dir}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    _ = client.send(arena, "Page.setDownloadBehavior", behavior_params) catch {
        resp.sendError(request, 502, "Page.setDownloadBehavior failed");
        return;
    };
    // Page.downloadWillBegin needs the Page domain enabled to fire at all.
    _ = client.send(arena, protocol.Methods.page_enable, null) catch {};

    // Wait for a real CDP signal instead of unconditionally returning a
    // canned success unrelated to whether a download ever happens.
    // Page.downloadWillBegin fires exactly once, at the moment Chrome
    // commits to a download, so a `waitForEvent` match unambiguously means
    // a download started.
    //
    // Known, deliberate limitation: `waitForEvent` only reports whether the
    // *method name* matched an incoming message -- client.zig's in-read-
    // loop dispatcher frees the actual event payload (guid/url/
    // suggestedFilename) before this call ever sees it, so this endpoint
    // can confirm a download *began* but cannot report its guid/path or
    // whether it later completed/canceled (Page.downloadProgress carries
    // that, but is a repeating multi-state stream and the same payload-
    // discarding limitation applies there too). Surfacing guid/completion
    // state honestly would require CdpClient to expose the matched event
    // body to callers, which is out of scope for a router.zig-only change
    // -- flagging that rather than fabricating a guid/state this endpoint
    // never actually observed.
    const began = client.waitForEvent(arena, "Page.downloadWillBegin", timeoutMsToAttempts(timeout_ms));
    if (!began) {
        const body = std.fmt.allocPrint(
            arena,
            "{{\"ok\":false,\"action\":\"waitForDownload\",\"detected\":false,\"error\":\"no Page.downloadWillBegin event observed within timeout\",\"timeout_ms\":{d}}}",
            .{timeout_ms},
        ) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        resp.sendJson(request, body);
        return;
    }
    const body = std.fmt.allocPrint(
        arena,
        "{{\"ok\":true,\"action\":\"waitForDownload\",\"detected\":true,\"event\":\"Page.downloadWillBegin\",\"note\":\"confirms a download started; per-download guid/path/completion state is not exposed by this endpoint\"}}",
        .{},
    ) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
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
    // Escape exactly once — `expr` is already escaped. Double-escaping turns a
    // newline into a literal backslash+n and makes Chrome reject the script.
    const params = std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":false}}", .{expr}) catch {
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

test "keyboard/type must iterate text by Unicode codepoint, not raw byte" {
    // handleKeyboardType used to do `for (text) |ch|`, splitting any
    // multi-byte UTF-8 character into individual invalid bytes. Confirm the
    // fix's iteration mechanism (std.unicode.Utf8Iterator) walks "héllo" as
    // 5 codepoints (h, é, l, l, o) — a raw byte loop would see 6 bytes
    // because é is 2 bytes in UTF-8.
    const text = "héllo";
    try std.testing.expectEqual(@as(usize, 6), text.len);

    var utf8_iter: std.unicode.Utf8Iterator = .{ .bytes = text, .i = 0 };
    var count: usize = 0;
    var codepoints: [8][]const u8 = undefined;
    while (utf8_iter.nextCodepointSlice()) |cp| : (count += 1) {
        codepoints[count] = cp;
    }
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expectEqualStrings("h", codepoints[0]);
    try std.testing.expectEqualStrings("é", codepoints[1]);
    try std.testing.expectEqualStrings("l", codepoints[2]);
    try std.testing.expectEqualStrings("l", codepoints[3]);
    try std.testing.expectEqualStrings("o", codepoints[4]);

    // jsonEscapeAlloc must pass the multi-byte codepoint through unmangled
    // (it only escapes '"', '\\', and control chars < 0x20).
    const escaped = jsonEscapeAlloc(std.testing.allocator, codepoints[1]);
    try std.testing.expect(escaped != null);
    try std.testing.expectEqualStrings("é", escaped.?);
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

test "screenshot/annotated route requires a ref, resolved via the snapshot cache like /upload" {
    const target = "/screenshot/annotated?tab_id=t1&ref=e7";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("e7", getQueryParam(target, "ref").?);
    try std.testing.expect(getQueryParam("/screenshot/annotated?tab_id=t1", "ref") == null);
}

test "dispatch route parameters" {
    const target = "/dispatch?tab_id=t1&ref=e2&type=click";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("e2", getQueryParam(target, "ref").?);
    try std.testing.expectEqualStrings("click", getQueryParam(target, "type").?);
}

test "dispatch route parses pointer and keyboard event types" {
    // These types fall into the PointerEvent/KeyboardEvent branches added
    // to handleDispatch's generated JS, instead of the generic-Event
    // fallback that used to leave e.g. e.pointerId/e.clientX/e.key
    // undefined for any listener that checked them.
    const pointer_target = "/dispatch?tab_id=t1&ref=e2&type=pointerdown";
    try std.testing.expectEqualStrings("pointerdown", getQueryParam(pointer_target, "type").?);
    const key_target = "/dispatch?tab_id=t1&ref=e2&type=keydown";
    try std.testing.expectEqualStrings("keydown", getQueryParam(key_target, "type").?);
}

test "resolveDownloadDir prefers the dir query param over the fixed default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const target = "/download?tab_id=t1&url=https://example.com/file&dir=/custom/downloads";
    try std.testing.expectEqualStrings("/custom/downloads", resolveDownloadDir(arena_state.allocator(), target));
}

test "resolveDownloadDir falls back to the fixed default with no dir param or env var" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const target = "/download?tab_id=t1&url=https://example.com/file";
    try std.testing.expectEqualStrings("/tmp/kuri-downloads", resolveDownloadDir(arena_state.allocator(), target));
}

test "timeoutMsToAttempts clamps to a sane range" {
    try std.testing.expectEqual(@as(u32, 20), timeoutMsToAttempts(0));
    try std.testing.expectEqual(@as(u32, 20), timeoutMsToAttempts(500));
    try std.testing.expectEqual(@as(u32, 600), timeoutMsToAttempts(30_000));
    try std.testing.expectEqual(@as(u32, 20000), timeoutMsToAttempts(10_000_000));
}

test "findFrameIdInTree finds a direct child by name" {
    const tree =
        \\{"frame":{"id":"MAIN","url":"https://example.com/"},"childFrames":[
        \\  {"frame":{"id":"CHILD1","name":"payment","url":"https://pay.example.com/"}}
        \\]}
    ;
    try std.testing.expectEqualStrings("CHILD1", findFrameIdInTree(tree, "payment", null).?);
}

test "findFrameIdInTree finds a frame nested two levels deep by url substring" {
    // This is exactly the case document.querySelector('iframe[...]') on the
    // top document cannot see: a frame nested inside another frame.
    const tree =
        \\{"frame":{"id":"MAIN","url":"https://example.com/"},"childFrames":[
        \\  {"frame":{"id":"MID","url":"https://widgets.example.com/"},"childFrames":[
        \\    {"frame":{"id":"DEEP","url":"https://checkout.example.com/pay?ref=1"}}
        \\  ]}
        \\]}
    ;
    try std.testing.expectEqualStrings("DEEP", findFrameIdInTree(tree, null, "checkout.example.com").?);
}

test "findFrameIdInTree returns null when nothing in the tree matches" {
    const tree =
        \\{"frame":{"id":"MAIN","url":"https://example.com/"},"childFrames":[
        \\  {"frame":{"id":"CHILD1","url":"https://ads.example.com/"}}
        \\]}
    ;
    try std.testing.expect(findFrameIdInTree(tree, "nope", null) == null);
    try std.testing.expect(findFrameIdInTree(tree, null, "nowhere.example.com") == null);
}

test "extractArrayInterior and nextArrayObject split a childFrames array despite a literal comma in a url string" {
    const tree =
        \\{"frame":{"id":"MAIN"},"childFrames":[
        \\  {"frame":{"id":"A","url":"https://example.com/?a=1,2"}},
        \\  {"frame":{"id":"B","url":"https://example.com/b"}}
        \\]}
    ;
    const interior = extractArrayInterior(tree, "childFrames").?;
    const first = nextArrayObject(interior, 0).?;
    try std.testing.expectEqualStrings("A", jsonscan.extractField(jsonscan.extractObject(first.slice, "frame").?, "id").?);
    const second = nextArrayObject(interior, first.next).?;
    try std.testing.expectEqualStrings("B", jsonscan.extractField(jsonscan.extractObject(second.slice, "frame").?, "id").?);
    try std.testing.expect(nextArrayObject(interior, second.next) == null);
}

test "mainframe route accepts an explicit tab_id" {
    const target = "/mainframe?tab_id=t1";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
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
    // Verify we have the expected number of routes. This list is documentation
    // (grouped roughly by when each tier landed); the actual source of truth is
    // the `Route` enum in `route()` -- the compiler's exhaustive switch already
    // guarantees every enum variant has a handler, so we only need to check here
    // that this list hasn't drifted from that enum's variant count.
    const routes = [_][]const u8{
        "/health",            "/tabs",                "/page/info",          "/discover",        "/navigate",              "/snapshot",
        "/action",            "/text",                "/screenshot",         "/evaluate",        "/browdie",               "/har/start",
        "/har/stop",          "/har/status",          "/har/replay",         "/close",           "/cookies",               "/cookies/clear",
        "/cookies/delete",    "/cookies/set",         "/storage/local",      "/storage/session", "/storage/local/clear",   "/storage/session/clear",
        "/get",               "/back",                "/forward",            "/reload",          "/diff/snapshot",         "/emulate",
        "/geolocation",       "/upload",              "/session/save",       "/session/load",    "/auth/profile/save",     "/auth/profile/load",
        "/auth/profile/list", "/auth/profile/delete", "/auth/extract",       "/debug/enable",    "/debug/disable",         "/screenshot/annotated",
        "/screenshot/diff",   "/screencast/start",    "/screencast/stop",    "/video/start",     "/video/stop",            "/console",
        "/intercept/start",   "/intercept/stop",      "/intercept/requests", "/intercept/rules", "/intercept/rules/clear", "/markdown",
        "/links",             "/pdf",                 "/dom/query",          "/dom/html",        "/headers",               "/script/inject",
        "/stop",
        // Tier 1 new endpoints
                     "/scrollintoview",      "/drag",               "/keyboard/type",   "/keyboard/inserttext",   "/keydown",
        "/keyup",             "/wait",                "/tab/current",        "/tab/new",         "/tab/close",             "/highlight",
        "/errors",            "/set/offline",         "/set/media",          "/set/credentials",
        // Tier 2 new endpoints
        "/find",                  "/trace/start",
        "/trace/stop",        "/profiler/start",      "/profiler/stop",      "/inspect",         "/window/new",            "/session/list",
        "/set/viewport",      "/set/useragent",       "/dom/attributes",     "/frames",          "/network",               "/perf/lcp",
        // Tier 3 new endpoints
        "/ws/start",          "/ws/stop",
        // Tier 4 new endpoints
                    "/batch",              "/element/state",
        // Tier 5 new endpoints
          "/find-element",          "/dialog/auto",
        "/dialog/accept",     "/dialog/dismiss",      "/mouse/move",         "/mouse/down",      "/mouse/up",              "/mouse/wheel",
        "/page/state",
        // Tier 6 new endpoints
               "/clipboard/read",      "/clipboard/write",    "/clear",           "/boundingbox",           "/wait/function",
        "/response/body",     "/setcontent",          "/selectall",          "/setvalue",        "/timezone",              "/locale",
        "/permissions",       "/tap",                 "/dispatch",           "/download",
        // Tier 7 new endpoints
               "/addstyle",              "/bringtofront",
        "/pushstate",         "/expose",              "/multiselect",        "/swipe",           "/vitals",                "/frame",
        "/mainframe",         "/getattribute",        "/inputvalue",         "/react/tree",      "/react/inspect",         "/react/renders",
        "/react/suspense",    "/recording/start",     "/recording/stop",     "/request/detail",  "/wait/download",         "/initscript/remove",
        "/evalhandle",        "/diff/url",
        // Advanced features
                   "/cache/set",          "/cache/get",       "/cache/clear",           "/cache/list",
        "/screenshot/som",    "/snapshot/changes",    "/recording/export",    "/replay",
        // Collector retrieval endpoints
          "/expose/calls",
    };
    const route_variant_count = @typeInfo(Route).@"enum".field_names.len;
    try std.testing.expectEqual(route_variant_count, routes.len);
    try std.testing.expectEqual(@as(usize, 149), routes.len);
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

test "handleMainFrame frame tree parsing must not read the top-level response id" {
    // Real Page.getFrameTree shape: the JSON-RPC envelope's own "id" (a bare
    // number, the command id) sits before "frameTree" — extractSimpleJsonString
    // only matches quoted string values, so searching from position 0 for
    // "id" must fail here (proving why handleMainFrame searches from the
    // "frameTree" offset instead of from 0).
    const response = "{\"id\":7,\"result\":{\"frameTree\":{\"frame\":{\"id\":\"F123\",\"loaderId\":\"L456\",\"url\":\"https://example.com/\"},\"childFrames\":[]}}}";
    try std.testing.expect(extractSimpleJsonString(response, 0, "\"id\"") == null);

    const frametree_pos = std.mem.indexOf(u8, response, "\"frameTree\"").?;
    const frame_id = extractSimpleJsonString(response, frametree_pos, "\"id\"");
    const loader_id = extractSimpleJsonString(response, frametree_pos, "\"loaderId\"");
    const frame_url = extractSimpleJsonString(response, frametree_pos, "\"url\"");
    try std.testing.expectEqualStrings("F123", frame_id.?);
    try std.testing.expectEqualStrings("L456", loader_id.?);
    try std.testing.expectEqualStrings("https://example.com/", frame_url.?);
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

test "jsonEscapeAlloc applied twice corrupts JS source — escape exactly once" {
    const arena = std.testing.allocator;
    // Regression guard for the /evaluate + /script/inject double-escape bug.
    // Escaping once is correct: a newline becomes the two-char sequence \n,
    // which JSON-decodes back to a real newline in the JS source.
    const once = jsonEscapeAlloc(arena, "return 1;\nreturn 2;").?;
    defer arena.free(once);
    try std.testing.expectEqualStrings("return 1;\\nreturn 2;", once);

    // Escaping the ALREADY-escaped string turns the backslash into `\\`, so
    // Chrome receives a literal backslash+n in the source and answers with
    // "SyntaxError: Invalid or unexpected token" instead of running anything.
    const twice = jsonEscapeAlloc(arena, once).?;
    defer arena.free(twice);
    try std.testing.expectEqualStrings("return 1;\\\\nreturn 2;", twice);
    try std.testing.expect(!std.mem.eql(u8, once, twice));
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

test "intercept/rules route matching" {
    const path = "/intercept/rules?tab_id=abc";
    const clean = path[0..std.mem.indexOfScalar(u8, path, '?').?];
    try std.testing.expectEqualStrings("/intercept/rules", clean);
}

test "intercept/rules/clear route matching" {
    const path = "/intercept/rules/clear?tab_id=abc";
    const clean = path[0..std.mem.indexOfScalar(u8, path, '?').?];
    try std.testing.expectEqualStrings("/intercept/rules/clear", clean);
}

test "intercept/start patterns query param parsing" {
    const target = "/intercept/start?tab_id=abc&patterns=*.png,*.jpg";
    try std.testing.expectEqualStrings("abc", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("*.png,*.jpg", getQueryParam(target, "patterns").?);
    // Missing patterns falls back to "*" at the handler level, not here.
    try std.testing.expect(getQueryParam("/intercept/start?tab_id=abc", "patterns") == null);
}

test "parseInterceptRuleBody parses a fulfill rule" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const body =
        \\{"url_pattern":"api.example.com","action":"fulfill","status":204,"content_type":"text/plain","body":"blocked"}
    ;
    const rule = parseInterceptRuleBody(arena, body).?;
    try std.testing.expectEqualStrings("api.example.com", rule.url_substring);
    try std.testing.expectEqual(InterceptRule.Action.fulfill, rule.action);
    try std.testing.expectEqual(@as(u16, 204), rule.status);
    try std.testing.expectEqualStrings("text/plain", rule.content_type);
    try std.testing.expectEqualStrings("blocked", rule.body);
}

test "parseInterceptRuleBody parses an abort rule with error_reason" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const body =
        \\{"url_pattern":"ads.","action":"abort","error_reason":"BlockedByClient"}
    ;
    const rule = parseInterceptRuleBody(arena, body).?;
    try std.testing.expectEqualStrings("ads.", rule.url_substring);
    try std.testing.expectEqual(InterceptRule.Action.abort, rule.action);
    try std.testing.expectEqualStrings("BlockedByClient", rule.error_reason);
}

test "parseInterceptRuleBody treats a bare * pattern as catch-all" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const body =
        \\{"url_pattern":"*","action":"continue"}
    ;
    const rule = parseInterceptRuleBody(arena, body).?;
    try std.testing.expectEqualStrings("", rule.url_substring);
    try std.testing.expectEqual(InterceptRule.Action.@"continue", rule.action);
}

test "parseInterceptRuleBody rejects an invalid action" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const body =
        \\{"url_pattern":"x","action":"redirect"}
    ;
    try std.testing.expect(parseInterceptRuleBody(arena, body) == null);
}

test "writeInterceptRuleJson serializes all rule fields" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var buf: std.ArrayList(u8) = .empty;
    try writeInterceptRuleJson(&buf, arena, .{
        .url_substring = "/blocked",
        .action = .abort,
        .error_reason = "Failed",
    });

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"url_pattern\":\"/blocked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"action\":\"abort\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"error_reason\":\"Failed\"") != null);
}

test "network route mode=list parameter" {
    const target = "/network?tab_id=t1&mode=list&url=example.com";
    try std.testing.expectEqualStrings("list", getQueryParam(target, "mode").?);
    try std.testing.expectEqualStrings("example.com", getQueryParam(target, "url").?);
}

test "expose/calls route parses tab_id, name, and clear parameters" {
    const target = "/expose/calls?tab_id=t1&name=myBinding&clear=true";
    try std.testing.expectEqualStrings("t1", getQueryParam(target, "tab_id").?);
    try std.testing.expectEqualStrings("myBinding", getQueryParam(target, "name").?);
    try std.testing.expectEqualStrings("true", getQueryParam(target, "clear").?);
}

test "expose/calls route matches cleanly" {
    const clean = if (std.mem.indexOfScalar(u8, "/expose/calls?tab_id=1&name=foo", '?')) |idx|
        "/expose/calls?tab_id=1&name=foo"[0..idx]
    else
        "/expose/calls?tab_id=1&name=foo";
    try std.testing.expectEqualStrings("/expose/calls", clean);
}

test "screencast/stop frames query parameter defaults to latest when absent" {
    const target = "/screencast/stop?tab_id=t1";
    try std.testing.expectEqualStrings("latest", getQueryParam(target, "frames") orelse "latest");
}

test "screencast/stop frames=all and frames=none are both parseable" {
    try std.testing.expectEqualStrings("all", getQueryParam("/screencast/stop?tab_id=t1&frames=all", "frames").?);
    try std.testing.expectEqualStrings("none", getQueryParam("/screencast/stop?tab_id=t1&frames=none", "frames").?);
}

test "response/body route accepts either request_id or url parameter" {
    try std.testing.expectEqualStrings("abc123", getQueryParam("/response/body?tab_id=t1&request_id=abc123", "request_id").?);
    try std.testing.expectEqualStrings("example.com", getQueryParam("/response/body?tab_id=t1&url=example.com", "url").?);
}

test "writeScreencastFrameJson serializes all frame fields" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var buf: std.ArrayList(u8) = .empty;
    try writeScreencastFrameJson(&buf, arena, .{
        .data_b64 = "Zm9v",
        .timestamp = 12345.5,
        .device_width = 1280,
        .device_height = 720,
        .session_id = 7,
    });

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"data_b64\":\"Zm9v\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"device_width\":1280") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"device_height\":720") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"session_id\":7") != null);
}

test "writeNetworkRecordJson serializes all request fields" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var buf: std.ArrayList(u8) = .empty;
    try writeNetworkRecordJson(&buf, arena, .{
        .request_id = "req-1",
        .url = "https://example.com/api",
        .url_truncated = false,
        .method = "GET",
        .mime_type = "application/json",
        .timestamp = 1000,
    });

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"request_id\":\"req-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"url\":\"https://example.com/api\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"method\":\"GET\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"mime_type\":\"application/json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"url_truncated\":false") != null);
}

test "trace/start requests transferMode ReturnAsStream so /trace/stop can drain a stream" {
    // Guards against silently dropping the transferMode param in a future
    // edit: without it, Tracing.tracingComplete carries no `stream` handle
    // and /trace/stop has nothing to read.
    const params_fmt = "{{\"categories\":\"{s}\",\"options\":\"sampling-frequency=10000\",\"transferMode\":\"ReturnAsStream\"}}";
    var buf: [256]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, params_fmt, .{"test.category"});
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"transferMode\":\"ReturnAsStream\"") != null);
}

test "video/start and video/stop are their own route entries, not screencast aliases" {
    // Regression guard: video/* used to be `const handleVideoStart =
    // handleScreencastStart;` -- a pure alias with no distinct wiring. Both
    // route paths must still resolve, and to a different function value
    // than the screencast handlers (thin wrappers around a shared core,
    // not the exact same function).
    try std.testing.expect(@TypeOf(handleVideoStart) == @TypeOf(handleScreencastStart));
    try std.testing.expect(&handleVideoStart != &handleScreencastStart);
    try std.testing.expect(&handleVideoStop != &handleScreencastStop);
}

// --- X-Kuri-Session resolution across handler shapes ---
//
// resolveEffectiveTabIdAlloc is the single shared resolver behind every
// handler shape in this file:
//   - `const tab_id = requireEffectiveTabId(...) orelse return;` (the vast
//     majority of handlers -- requireEffectiveTabId is a thin wrapper that
//     just adds the 400 sendError)
//   - `const tab_id = resolveEffectiveTabIdAlloc(...) orelse { sendError(...);
//     return; };` (the inline form used by /console, /errors, and the
//     /intercept/* handlers)
//   - `const tab_id = resolveEffectiveTabIdAlloc(...);` with no error at all,
//     used where a missing tab_id has its own fallback behavior (/navigate,
//     /close)
// A real std.http.Server.Request can't be constructed without a live
// connection, but Request itself only needs `head` (parsed request line) and
// `head_buffer` (raw bytes for iterateHeaders) populated -- exactly the
// pattern std.http.Server.Request's own `test iterateHeaders` uses.
fn testRequest(target: []const u8, head_buffer: []const u8, server: *std.http.Server) std.http.Server.Request {
    return .{
        .server = server,
        .head = .{
            .method = .GET,
            .target = target,
            .version = .@"HTTP/1.1",
            .expect = null,
            .content_type = null,
            .content_length = null,
            .transfer_encoding = .none,
            .transfer_compression = .identity,
            .keep_alive = true,
        },
        .head_buffer = @constCast(head_buffer),
    };
}

test "resolveEffectiveTabIdAlloc resolves session across representative handler shapes" {
    const allocator = std.testing.allocator;

    var bridge = Bridge.init(allocator);
    defer bridge.deinit();
    try bridge.setCurrentTab("sess-abc", "tab-from-session");

    var server: std.http.Server = .{
        .reader = .{
            .in = undefined,
            .state = .received_head,
            .interface = undefined,
            .max_head_len = 4096,
        },
        .out = undefined,
    };

    // Shape 1: explicit ?tab_id= wins even when a session header also
    // resolves -- the path every `requireEffectiveTabId(...) orelse return;`
    // handler takes for a normal, fully-specified call.
    {
        var request = testRequest(
            "/console?tab_id=explicit-tab",
            "GET /console?tab_id=explicit-tab HTTP/1.1\r\nX-Kuri-Session: sess-abc\r\n\r\n",
            &server,
        );
        const resolved = resolveEffectiveTabIdAlloc(allocator, &request, &bridge).?;
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings("explicit-tab", resolved);
    }

    // Shape 2: no tab_id, X-Kuri-Session header -- the case the audit flagged
    // as broken; exercised by both requireEffectiveTabId callers and the
    // inline resolveEffectiveTabIdAlloc callers (/console, /errors,
    // /intercept/*).
    {
        var request = testRequest(
            "/console",
            "GET /console HTTP/1.1\r\nX-Kuri-Session: sess-abc\r\n\r\n",
            &server,
        );
        const resolved = resolveEffectiveTabIdAlloc(allocator, &request, &bridge).?;
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings("tab-from-session", resolved);
    }

    // Shape 3: no tab_id, no header, session carried via ?session= query
    // param -- the fallback getSessionId offers callers that can't set
    // custom headers.
    {
        var request = testRequest(
            "/errors?session=sess-abc",
            "GET /errors?session=sess-abc HTTP/1.1\r\n\r\n",
            &server,
        );
        const resolved = resolveEffectiveTabIdAlloc(allocator, &request, &bridge).?;
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings("tab-from-session", resolved);
    }

    // Shape 4: no tab_id and no session at all -- resolves to null so the
    // caller's own orelse (requireEffectiveTabId's sendError, or an inline
    // one) is what fires, not a silent wrong-tab fallback.
    {
        var request = testRequest(
            "/intercept/requests",
            "GET /intercept/requests HTTP/1.1\r\n\r\n",
            &server,
        );
        try std.testing.expect(resolveEffectiveTabIdAlloc(allocator, &request, &bridge) == null);
    }
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
