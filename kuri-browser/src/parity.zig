const std = @import("std");
const agent = @import("agent.zig");
const core = @import("core.zig");
const js_runtime = @import("js_runtime.zig");
const render = @import("render.zig");
const snapshot = @import("snapshot.zig");

pub const Options = struct {
    kuri_base: []const u8 = "http://127.0.0.1:8080",
    run_live: bool = true,
};

const FeatureStatus = enum {
    yes,
    partial,
    no,

    fn label(self: FeatureStatus) []const u8 {
        return switch (self) {
            .yes => "yes",
            .partial => "partial",
            .no => "no",
        };
    }

    fn numerator(self: FeatureStatus) usize {
        return switch (self) {
            .yes => 2,
            .partial => 1,
            .no => 0,
        };
    }
};

const LiveCheckId = enum {
    example_title,
    example_text,
    hn_selector_count,
    httpbingo_redirect_cookie,
    quotes_js_count,
    todomvc_shell,
    har_capture,
    action_click,
    snapshot_count,

    fn label(self: LiveCheckId) []const u8 {
        return switch (self) {
            .example_title => "example title parity",
            .example_text => "example text parity",
            .hn_selector_count => "HN selector count parity",
            .httpbingo_redirect_cookie => "httpbingo redirect + cookie parity",
            .quotes_js_count => "quotes JS DOM count parity",
            .todomvc_shell => "TodoMVC shell parity",
            .har_capture => "HAR capture parity",
            .action_click => "ref click action parity",
            .snapshot_count => "interactive snapshot parity",
        };
    }
};

const Feature = struct {
    name: []const u8,
    weight: usize,
    status: FeatureStatus,
    gap: []const u8,
    live_check: ?LiveCheckId = null,
};

const features = [_]Feature{
    .{
        .name = "Navigation + page metadata",
        .weight = 10,
        .status = .yes,
        .gap = "No issue on the static/runtime path; tracked against Kuri page-info/title behavior.",
        .live_check = .example_title,
    },
    .{
        .name = "Text extraction",
        .weight = 8,
        .status = .yes,
        .gap = "Text-first output is in good shape for static pages.",
        .live_check = .example_text,
    },
    .{
        .name = "DOM selectors",
        .weight = 8,
        .status = .yes,
        .gap = "Basic CSS selector support is present; broader selector parity is still future work.",
        .live_check = .hn_selector_count,
    },
    .{
        .name = "Redirects + cookies",
        .weight = 8,
        .status = .yes,
        .gap = "Current jar is session-scoped and still simpler than a full browser store.",
        .live_check = .httpbingo_redirect_cookie,
    },
    .{
        .name = "Forms inspect + submit",
        .weight = 8,
        .status = .partial,
        .gap = "GET/POST urlencoded flows work, but richer encodings and multi-step action parity are missing.",
    },
    .{
        .name = "Static subresource loading",
        .weight = 6,
        .status = .partial,
        .gap = "Top-level/static waterfalls load, but not all browser loading behavior is modeled.",
    },
    .{
        .name = "HAR capture",
        .weight = 6,
        .status = .partial,
        .gap = "Captures the standalone runtime flow, not full Chrome-level network instrumentation.",
        .live_check = .har_capture,
    },
    .{
        .name = "JS execution + eval",
        .weight = 12,
        .status = .partial,
        .gap = "Real sites now work, but QuickJS + shims are still not full browser semantics.",
        .live_check = .quotes_js_count,
    },
    .{
        .name = "Browser-side fetch/XHR/storage shims",
        .weight = 8,
        .status = .partial,
        .gap = "Fetch/XHR hooks exist; broader browser API coverage is still incomplete.",
    },
    .{
        .name = "SPA compatibility",
        .weight = 8,
        .status = .partial,
        .gap = "Representative React/TodoMVC path works, but arbitrary SPA support is not yet reliable.",
        .live_check = .todomvc_shell,
    },
    .{
        .name = "Wait semantics + async page events",
        .weight = 8,
        .status = .no,
        .gap = "No stable `waitFor*` / lifecycle model yet.",
    },
    .{
        .name = "Agent snapshots, refs, and actions",
        .weight = 8,
        .status = .partial,
        .gap = "Interactive snapshots with `eN` refs and basic click/type flows exist now, but broader action parity is still missing.",
        .live_check = .action_click,
    },
    .{
        .name = "Visual rendering + screenshots",
        .weight = 6,
        .status = .no,
        .gap = "No layout engine, paint model, or screenshot path.",
    },
    .{
        .name = "CDP / automation compatibility",
        .weight = 4,
        .status = .no,
        .gap = "No CDP-compatible server surface yet.",
    },
};

const LiveState = enum {
    pass,
    fail,
    skipped,

    fn label(self: LiveState) []const u8 {
        return switch (self) {
            .pass => "pass",
            .fail => "fail",
            .skipped => "skipped",
        };
    }
};

const LiveCheckResult = struct {
    id: LiveCheckId,
    state: LiveState,
    detail: []const u8,
};

const PageInfo = struct {
    tab_id: []const u8 = "",
    url: []const u8 = "",
    title: []const u8 = "",
};

const KuriClient = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    base_url: []const u8,

    fn init(allocator: std.mem.Allocator, base_url: []const u8) KuriClient {
        return .{
            .allocator = allocator,
            .client = .{
                .allocator = allocator,
                .io = std.Io.Threaded.global_single_threaded.io(),
            },
            .base_url = std.mem.trim(u8, base_url, "/"),
        };
    }

    fn deinit(self: *KuriClient) void {
        self.client.deinit();
    }

    fn health(self: *KuriClient) !void {
        const url = try buildUrl(self.allocator, self.base_url, "/health", &.{});
        _ = try self.get(url);
    }

    fn openTab(self: *KuriClient, url_value: []const u8) ![]const u8 {
        const url = try buildUrl(self.allocator, self.base_url, "/tab/new", &.{
            .{ .key = "url", .value = url_value },
            .{ .key = "wait", .value = "true" },
        });
        const body = try self.get(url);
        return try parseJsonStringField(self.allocator, body, "tab_id");
    }

    fn closeTab(self: *KuriClient, tab_id: []const u8) void {
        const url = buildUrl(self.allocator, self.base_url, "/tab/close", &.{
            .{ .key = "tab_id", .value = tab_id },
        }) catch return;
        _ = self.get(url) catch {};
    }

    fn pageInfo(self: *KuriClient, tab_id: []const u8) !PageInfo {
        const url = try buildUrl(self.allocator, self.base_url, "/page/info", &.{
            .{ .key = "tab_id", .value = tab_id },
        });
        const body = try self.get(url);
        return .{
            .tab_id = try parseJsonStringField(self.allocator, body, "tab_id"),
            .url = try parseJsonStringField(self.allocator, body, "url"),
            .title = try parseJsonStringField(self.allocator, body, "title"),
        };
    }

    fn text(self: *KuriClient, tab_id: []const u8, selector: ?[]const u8) ![]const u8 {
        const query = if (selector) |sel|
            &[_]QueryParam{
                .{ .key = "tab_id", .value = tab_id },
                .{ .key = "selector", .value = sel },
            }
        else
            &[_]QueryParam{
                .{ .key = "tab_id", .value = tab_id },
            };
        const url = try buildUrl(self.allocator, self.base_url, "/text", query);
        const body = try self.get(url);
        return try parseCdpResultValue(self.allocator, body);
    }

    fn evaluate(self: *KuriClient, tab_id: []const u8, expression: []const u8) ![]const u8 {
        const url = try buildUrl(self.allocator, self.base_url, "/evaluate", &.{
            .{ .key = "tab_id", .value = tab_id },
            .{ .key = "expression", .value = expression },
        });
        const body = try self.get(url);
        return try parseCdpResultValue(self.allocator, body);
    }

    fn startHar(self: *KuriClient, tab_id: []const u8) !void {
        const url = try buildUrl(self.allocator, self.base_url, "/har/start", &.{
            .{ .key = "tab_id", .value = tab_id },
        });
        _ = try self.get(url);
    }

    fn navigate(self: *KuriClient, tab_id: []const u8, target_url: []const u8) !void {
        const url = try buildUrl(self.allocator, self.base_url, "/navigate", &.{
            .{ .key = "tab_id", .value = tab_id },
            .{ .key = "url", .value = target_url },
        });
        _ = try self.get(url);
    }

    fn stopHar(self: *KuriClient, tab_id: []const u8) !usize {
        const url = try buildUrl(self.allocator, self.base_url, "/har/stop", &.{
            .{ .key = "tab_id", .value = tab_id },
        });
        const body = try self.get(url);
        return try parseJsonIntField(body, "entries");
    }

    fn action(self: *KuriClient, tab_id: []const u8, action_name: []const u8, ref: []const u8, value: ?[]const u8) !void {
        const url = if (value) |action_value|
            try buildUrl(self.allocator, self.base_url, "/action", &.{
                .{ .key = "tab_id", .value = tab_id },
                .{ .key = "action", .value = action_name },
                .{ .key = "ref", .value = ref },
                .{ .key = "value", .value = action_value },
            })
        else
            try buildUrl(self.allocator, self.base_url, "/action", &.{
                .{ .key = "tab_id", .value = tab_id },
                .{ .key = "action", .value = action_name },
                .{ .key = "ref", .value = ref },
            });
        _ = try self.get(url);
    }

    fn waitReady(self: *KuriClient, tab_id: []const u8) !void {
        const url = try buildUrl(self.allocator, self.base_url, "/wait", &.{
            .{ .key = "tab_id", .value = tab_id },
            .{ .key = "timeout", .value = "5000" },
        });
        _ = try self.get(url);
    }

    fn waitSelector(self: *KuriClient, tab_id: []const u8, selector: []const u8) bool {
        const url = buildUrl(self.allocator, self.base_url, "/wait", &.{
            .{ .key = "tab_id", .value = tab_id },
            .{ .key = "selector", .value = selector },
            .{ .key = "timeout", .value = "5000" },
        }) catch return false;
        _ = self.get(url) catch return false;
        return true;
    }

    fn snapshotCount(self: *KuriClient, tab_id: []const u8) !usize {
        const url = try buildUrl(self.allocator, self.base_url, "/snapshot", &.{
            .{ .key = "tab_id", .value = tab_id },
            .{ .key = "filter", .value = "interactive" },
            .{ .key = "format", .value = "compact" },
        });
        const body = try self.get(url);
        return countCompactSnapshotLines(body);
    }

    fn get(self: *KuriClient, url: []const u8) ![]const u8 {
        const uri = try std.Uri.parse(url);
        var attempts: usize = 0;
        while (attempts < 2) : (attempts += 1) {
            var req = try self.client.request(.GET, uri, .{});
            defer req.deinit();

            try req.sendBodiless();
            var response = req.receiveHead(&.{}) catch |err| switch (err) {
                error.HttpConnectionClosing => continue,
                else => return err,
            };
            if (response.head.status != .ok) return error.UnexpectedHttpStatus;

            var body: std.ArrayList(u8) = .empty;
            var transfer_buf: [8192]u8 = undefined;
            var decompress: std.http.Decompress = undefined;
            var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
            const reader = response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);
            try reader.appendRemainingUnlimited(self.allocator, &body);
            return body.items;
        }
        return error.HttpConnectionClosing;
    }
};

const QueryParam = struct {
    key: []const u8,
    value: []const u8,
};

pub fn reportText(allocator: std.mem.Allocator, options: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    const estimated = estimatedParityPercent();
    const coverage = automatedCoveragePercent();
    const live_results = try runLiveChecks(allocator, options);
    const validated = validatedParityPercent(live_results);

    try out.writer.writeAll("kuri-browser parity\n\n");
    try out.writer.print("target: Kuri CDP HTTP surface\n", .{});
    try out.writer.print("kuri-base: {s}\n", .{options.kuri_base});
    try out.writer.print("estimated feature parity: {d}%\n", .{estimated});
    try out.writer.print("automated validation coverage: {d}%\n", .{coverage});
    if (options.run_live and liveChecksRan(live_results)) {
        try out.writer.print("live-validated parity: {d}%\n", .{validated});
    } else if (!options.run_live) {
        try out.writer.writeAll("live-validated parity: skipped (--offline)\n");
    } else {
        try out.writer.writeAll("live-validated parity: skipped (Kuri server unavailable)\n");
    }

    try out.writer.writeAll("\nFeature Matrix\n");
    for (features) |feature| {
        try out.writer.print("- [{s}] {d} pts: {s}\n", .{
            feature.status.label(),
            feature.weight,
            feature.name,
        });
        try out.writer.print("  gap: {s}\n", .{feature.gap});
        if (feature.live_check) |check_id| {
            try out.writer.print("  live-check: {s}\n", .{check_id.label()});
        }
    }

    try out.writer.writeAll("\nLive Checks\n");
    for (live_results) |result| {
        try out.writer.print("- [{s}] {s}\n", .{
            result.state.label(),
            result.id.label(),
        });
        try out.writer.print("  detail: {s}\n", .{result.detail});
    }

    try out.writer.writeAll("\nMissing Next\n");
    try out.writer.writeAll("- Wait semantics and async lifecycle control\n");
    try out.writer.writeAll("- Broader ref-driven actions plus keyboard/select/checkbox parity\n");
    try out.writer.writeAll("- Screenshot/rendered output\n");
    try out.writer.writeAll("- Broader SPA/browser API coverage beyond the current representative sites\n");
    try out.writer.writeAll("- Any CDP-compatibility layer\n");

    return allocator.dupe(u8, out.written());
}

pub fn estimatedParityPercent() usize {
    var numer: usize = 0;
    var denom: usize = 0;
    for (features) |feature| {
        numer += feature.weight * feature.status.numerator();
        denom += feature.weight * 2;
    }
    return percentRounded(numer, denom);
}

pub fn automatedCoveragePercent() usize {
    var covered: usize = 0;
    var total: usize = 0;
    for (features) |feature| {
        total += feature.weight;
        if (feature.live_check != null) covered += feature.weight;
    }
    return percentRounded(covered, total);
}

fn validatedParityPercent(results: []const LiveCheckResult) usize {
    var numer: usize = 0;
    var denom: usize = 0;
    for (features) |feature| {
        denom += feature.weight * 2;
        const check_id = feature.live_check orelse continue;
        const state = liveStateFor(results, check_id) orelse continue;
        if (state == .pass) numer += feature.weight * feature.status.numerator();
    }
    return percentRounded(numer, denom);
}

fn liveChecksRan(results: []const LiveCheckResult) bool {
    for (results) |result| {
        if (result.state != .skipped) return true;
    }
    return false;
}

fn liveStateFor(results: []const LiveCheckResult, id: LiveCheckId) ?LiveState {
    for (results) |result| {
        if (result.id == id) return result.state;
    }
    return null;
}

fn runLiveChecks(allocator: std.mem.Allocator, options: Options) ![]LiveCheckResult {
    if (!options.run_live) return skippedResults(allocator, "offline mode");

    var kuri = KuriClient.init(allocator, options.kuri_base);
    defer kuri.deinit();

    kuri.health() catch |err| {
        return skippedResults(allocator, try std.fmt.allocPrint(allocator, "Kuri unavailable: {s}", .{@errorName(err)}));
    };

        return allocator.dupe(LiveCheckResult, &.{
            try checkExampleTitle(allocator, &kuri),
            try checkExampleText(allocator, &kuri),
            try checkHnSelectorCount(allocator, &kuri),
            try checkHttpbingoCookieRedirect(allocator, &kuri),
            try checkQuotesJsCount(allocator, &kuri),
            try checkTodoMvcShell(allocator, &kuri),
            try checkHarCapture(allocator, &kuri),
            try checkExampleActionClick(allocator, &kuri),
            try checkExampleSnapshotCount(allocator, &kuri),
        });
}

fn skippedResults(allocator: std.mem.Allocator, reason: []const u8) ![]LiveCheckResult {
    const all = [_]LiveCheckResult{
        .{ .id = .example_title, .state = .skipped, .detail = reason },
        .{ .id = .example_text, .state = .skipped, .detail = reason },
        .{ .id = .hn_selector_count, .state = .skipped, .detail = reason },
        .{ .id = .httpbingo_redirect_cookie, .state = .skipped, .detail = reason },
        .{ .id = .quotes_js_count, .state = .skipped, .detail = reason },
        .{ .id = .todomvc_shell, .state = .skipped, .detail = reason },
        .{ .id = .har_capture, .state = .skipped, .detail = reason },
        .{ .id = .action_click, .state = .skipped, .detail = reason },
        .{ .id = .snapshot_count, .state = .skipped, .detail = reason },
    };
    return allocator.dupe(LiveCheckResult, &all);
}

fn checkExampleTitle(allocator: std.mem.Allocator, kuri: *KuriClient) !LiveCheckResult {
    const url = "https://example.com";
    const runtime = core.BrowserRuntime.init(allocator);
    const page = try runtime.loadPage(url);
    const tab_id = try kuri.openTab(url);
    defer kuri.closeTab(tab_id);
    const info = try kuri.pageInfo(tab_id);
    const passed = std.mem.eql(u8, page.title, info.title);
    return .{
        .id = .example_title,
        .state = if (passed) .pass else .fail,
        .detail = try std.fmt.allocPrint(allocator, "native=\"{s}\" kuri=\"{s}\"", .{ page.title, info.title }),
    };
}

fn checkExampleText(allocator: std.mem.Allocator, kuri: *KuriClient) !LiveCheckResult {
    const url = "https://example.com";
    const runtime = core.BrowserRuntime.init(allocator);
    const page = try runtime.loadPage(url);
    const tab_id = try kuri.openTab(url);
    defer kuri.closeTab(tab_id);
    const text = try kuri.text(tab_id, null);
    const passed = std.mem.indexOf(u8, page.text, "Example Domain") != null and std.mem.indexOf(u8, text, "Example Domain") != null;
    return .{
        .id = .example_text,
        .state = if (passed) .pass else .fail,
        .detail = try std.fmt.allocPrint(allocator, "native_has_example={any} kuri_has_example={any}", .{
            std.mem.indexOf(u8, page.text, "Example Domain") != null,
            std.mem.indexOf(u8, text, "Example Domain") != null,
        }),
    };
}

fn checkHnSelectorCount(allocator: std.mem.Allocator, kuri: *KuriClient) !LiveCheckResult {
    const url = "https://news.ycombinator.com";
    const selector = ".titleline > a";
    const runtime = core.BrowserRuntime.init(allocator);
    const page = try runtime.loadPage(url);
    const native_matches = try page.dom.querySelectorAll(allocator, page.dom.root(), selector);
    const native_count = native_matches.len;

    const tab_id = try kuri.openTab(url);
    defer kuri.closeTab(tab_id);
    const kuri_count = try kuri.evaluate(tab_id, "String(document.querySelectorAll('.titleline > a').length)");
    const native_count_text = try std.fmt.allocPrint(allocator, "{d}", .{native_count});
    const passed = native_count > 0 and std.mem.eql(u8, native_count_text, kuri_count);
    return .{
        .id = .hn_selector_count,
        .state = if (passed) .pass else .fail,
        .detail = try std.fmt.allocPrint(allocator, "native={d} kuri={s}", .{ native_count, kuri_count }),
    };
}

fn checkHttpbingoCookieRedirect(allocator: std.mem.Allocator, kuri: *KuriClient) !LiveCheckResult {
    const url = "https://httpbingo.org/cookies/set?session=kuri-browser";
    const runtime = core.BrowserRuntime.init(allocator);
    const page = try runtime.loadPage(url);

    const tab_id = try kuri.openTab(url);
    defer kuri.closeTab(tab_id);
    const info = try kuri.pageInfo(tab_id);
    const body_text = try kuri.text(tab_id, null);

    const native_ok = page.cookie_count > 0 and std.mem.endsWith(u8, page.url, "/cookies");
    const kuri_ok = std.mem.endsWith(u8, info.url, "/cookies") and std.mem.indexOf(u8, body_text, "session") != null;
    return .{
        .id = .httpbingo_redirect_cookie,
        .state = if (native_ok and kuri_ok) .pass else .fail,
        .detail = try std.fmt.allocPrint(allocator, "native_url={s} cookies={d}; kuri_url={s} body_has_session={any}", .{
            page.url,
            page.cookie_count,
            info.url,
            std.mem.indexOf(u8, body_text, "session") != null,
        }),
    };
}

fn checkQuotesJsCount(allocator: std.mem.Allocator, kuri: *KuriClient) !LiveCheckResult {
    const url = "https://quotes.toscrape.com/js/";
    const expression = "String(document.querySelectorAll('.quote').length)";
    const runtime = core.BrowserRuntime.init(allocator);
    const page = try runtime.loadPageWithOptions(url, .{
        .enabled = true,
        .eval_expression = expression,
    });

    const tab_id = try kuri.openTab(url);
    defer kuri.closeTab(tab_id);
    const kuri_count = try kuri.evaluate(tab_id, expression);
    const passed = std.mem.eql(u8, page.js.eval_result, kuri_count) and std.mem.eql(u8, kuri_count, "10");
    return .{
        .id = .quotes_js_count,
        .state = if (passed) .pass else .fail,
        .detail = try std.fmt.allocPrint(allocator, "native={s} kuri={s}", .{ page.js.eval_result, kuri_count }),
    };
}

fn checkTodoMvcShell(allocator: std.mem.Allocator, kuri: *KuriClient) !LiveCheckResult {
    const url = "https://demo.playwright.dev/todomvc/";
    const expression = "String(!!document.querySelector('.todoapp')) + '|' + String(!!document.querySelector('.new-todo'))";
    const runtime = core.BrowserRuntime.init(allocator);
    const page = try runtime.loadPageWithOptions(url, .{
        .enabled = true,
        .eval_expression = expression,
    });

    const tab_id = try kuri.openTab(url);
    defer kuri.closeTab(tab_id);
    const kuri_todoapp = kuri.waitSelector(tab_id, ".todoapp");
    const kuri_input = kuri.waitSelector(tab_id, ".new-todo");
    const kuri_info = try kuri.pageInfo(tab_id);
    const native_ok = std.mem.eql(u8, page.js.eval_result, "true|true");
    const passed = native_ok and kuri_todoapp and kuri_input and
        std.mem.indexOf(u8, page.title, "TodoMVC") != null and
        std.mem.indexOf(u8, kuri_info.title, "TodoMVC") != null;
    return .{
        .id = .todomvc_shell,
        .state = if (passed) .pass else .fail,
        .detail = try std.fmt.allocPrint(allocator, "native={s}|{s} kuri={any}|{any}|{s}", .{
            page.js.eval_result,
            page.title,
            kuri_todoapp,
            kuri_input,
            kuri_info.title,
        }),
    };
}

fn checkHarCapture(allocator: std.mem.Allocator, kuri: *KuriClient) !LiveCheckResult {
    const native = try render.renderUrlArtifacts(allocator, "https://example.com", .{ .capture_har = true });
    const native_entries = countHarEntries(native.har_json orelse "{}") catch 0;

    const tab_id = try kuri.openTab("about:blank");
    defer kuri.closeTab(tab_id);
    try kuri.startHar(tab_id);
    try kuri.navigate(tab_id, "https://example.com");
    const kuri_entries = try kuri.stopHar(tab_id);
    const passed = native_entries > 0 and kuri_entries > 0;
    return .{
        .id = .har_capture,
        .state = if (passed) .pass else .fail,
        .detail = try std.fmt.allocPrint(allocator, "native_entries={d} kuri_entries={d}", .{ native_entries, kuri_entries }),
    };
}

fn checkExampleActionClick(allocator: std.mem.Allocator, kuri: *KuriClient) !LiveCheckResult {
    const native = try agent.runUrlActions(allocator, "https://example.com", &.{
        .{ .click = "e0" },
    }, false, .{});

    const tab_id = try kuri.openTab("https://example.com");
    defer kuri.closeTab(tab_id);
    _ = try kuri.snapshotCount(tab_id);
    try kuri.action(tab_id, "click", "e0", null);
    try kuri.waitReady(tab_id);
    const kuri_page = try kuri.pageInfo(tab_id);

    const native_ok = std.mem.indexOf(u8, native.page.title, "Example Domains") != null;
    const kuri_ok = std.mem.indexOf(u8, kuri_page.title, "Example Domains") != null;
    return .{
        .id = .action_click,
        .state = if (native_ok and kuri_ok) .pass else .fail,
        .detail = try std.fmt.allocPrint(allocator, "native=\"{s}\" kuri=\"{s}\"", .{ native.page.title, kuri_page.title }),
    };
}

fn checkExampleSnapshotCount(allocator: std.mem.Allocator, kuri: *KuriClient) !LiveCheckResult {
    const url = "https://example.com";
    const runtime = core.BrowserRuntime.init(allocator);
    const page = try runtime.loadPage(url);
    const native_nodes = try snapshot.buildInteractiveSnapshot(allocator, &page.dom, page.dom.root());
    defer snapshot.freeSnapshot(allocator, native_nodes);

    const tab_id = try kuri.openTab(url);
    defer kuri.closeTab(tab_id);
    const kuri_count = try kuri.snapshotCount(tab_id);
    const passed = native_nodes.len == kuri_count;
    return .{
        .id = .snapshot_count,
        .state = if (passed) .pass else .fail,
        .detail = try std.fmt.allocPrint(allocator, "native={d} kuri={d}", .{ native_nodes.len, kuri_count }),
    };
}

fn countHarEntries(har_json: []const u8) !usize {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_impl.allocator(), har_json, .{});
    const root = switch (parsed) {
        .object => |obj| obj,
        else => return error.InvalidJson,
    };
    const log_val = root.get("log") orelse return error.MissingField;
    const log_obj = switch (log_val) {
        .object => |obj| obj,
        else => return error.InvalidJson,
    };
    const entries_val = log_obj.get("entries") orelse return error.MissingField;
    return switch (entries_val) {
        .array => |arr| arr.items.len,
        else => error.InvalidJson,
    };
}

fn countCompactSnapshotLines(body: []const u8) usize {
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, body, '\n');
    while (iter.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r\n").len > 0) count += 1;
    }
    return count;
}

fn buildUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8, query: []const QueryParam) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeAll(base_url);
    try out.writer.writeAll(path);
    if (query.len > 0) {
        try out.writer.writeByte('?');
        for (query, 0..) |pair, i| {
            if (i > 0) try out.writer.writeByte('&');
            const key_component: std.Uri.Component = .{ .raw = pair.key };
            try key_component.formatQuery(&out.writer);
            try out.writer.writeByte('=');
            const value_component: std.Uri.Component = .{ .raw = pair.value };
            try value_component.formatQuery(&out.writer);
        }
    }
    return allocator.dupe(u8, out.written());
}

fn parseJsonStringField(allocator: std.mem.Allocator, body: []const u8, field: []const u8) ![]const u8 {
    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_impl.allocator(), body, .{});
    const object = switch (parsed) {
        .object => |obj| obj,
        else => return error.InvalidJson,
    };
    const value = object.get(field) orelse return error.MissingField;
    return switch (value) {
        .string => |s| allocator.dupe(u8, s),
        else => error.InvalidJson,
    };
}

fn parseJsonIntField(body: []const u8, field: []const u8) !usize {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_impl.allocator(), body, .{});
    const object = switch (parsed) {
        .object => |obj| obj,
        else => return error.InvalidJson,
    };
    const value = object.get(field) orelse return error.MissingField;
    return switch (value) {
        .integer => |v| std.math.cast(usize, v) orelse return error.InvalidJson,
        else => error.InvalidJson,
    };
}

fn parseCdpResultValue(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_impl.allocator(), body, .{});
    const root = switch (parsed) {
        .object => |obj| obj,
        else => return error.InvalidJson,
    };
    const result1 = switch (root.get("result") orelse return error.MissingField) {
        .object => |obj| obj,
        else => return error.InvalidJson,
    };
    const result2 = switch (result1.get("result") orelse return error.MissingField) {
        .object => |obj| obj,
        else => return error.InvalidJson,
    };
    if (result2.get("value")) |value| {
        return jsonValueToString(allocator, value);
    }
    if (result2.get("description")) |value| {
        return jsonValueToString(allocator, value);
    }
    if (result2.get("type")) |value| {
        return jsonValueToString(allocator, value);
    }
    return error.MissingField;
}

fn jsonValueToString(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .null => allocator.dupe(u8, "null"),
        .bool => |v| allocator.dupe(u8, if (v) "true" else "false"),
        .integer => |v| std.fmt.allocPrint(allocator, "{d}", .{v}),
        .float => |v| std.fmt.allocPrint(allocator, "{d}", .{v}),
        .number_string => |v| allocator.dupe(u8, v),
        .string => |v| allocator.dupe(u8, v),
        else => error.InvalidJson,
    };
}

fn percentRounded(numer: usize, denom: usize) usize {
    if (denom == 0) return 0;
    return (numer * 100 + denom / 2) / denom;
}

test "estimated parity percent stays stable" {
    try std.testing.expectEqual(@as(usize, 57), estimatedParityPercent());
    try std.testing.expectEqual(@as(usize, 63), automatedCoveragePercent());
}

test "parse cdp result value handles string and integer" {
    const allocator = std.testing.allocator;
    const string_value = try parseCdpResultValue(allocator, "{\"result\":{\"result\":{\"type\":\"string\",\"value\":\"hello\"}}}");
    defer allocator.free(string_value);
    try std.testing.expectEqualStrings("hello", string_value);

    const int_value = try parseCdpResultValue(allocator, "{\"result\":{\"result\":{\"type\":\"number\",\"value\":10}}}");
    defer allocator.free(int_value);
    try std.testing.expectEqualStrings("10", int_value);
}

test "build url encodes query values" {
    const allocator = std.testing.allocator;
    const url = try buildUrl(allocator, "http://127.0.0.1:8080", "/evaluate", &.{
        .{ .key = "expression", .value = "document.querySelector('.x').innerText" },
    });
    defer allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "document.querySelector%28%27.x%27%29.innerText") != null);
}
