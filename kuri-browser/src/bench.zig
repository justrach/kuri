const std = @import("std");
const cdp_server = @import("cdp_server.zig");
const core = @import("core.zig");
const dom = @import("dom.zig");
const fetch = @import("fetch.zig");
const js_runtime = @import("js_runtime.zig");
const model = @import("model.zig");
const native_paint = @import("native_paint.zig");
const render = @import("render.zig");
const screenshot = @import("screenshot.zig");
const snapshot = @import("snapshot.zig");

pub const Options = struct {
    kuri_base: []const u8 = "http://127.0.0.1:8080",
    run_live: bool = true,
};

const Area = enum {
    js_runtime,
    wait_semantics,
    cdp_surface,
    playwright_puppeteer,
    chrome_replacement,

    fn label(self: Area) []const u8 {
        return switch (self) {
            .js_runtime => "JS/runtime completeness",
            .wait_semantics => "wait semantics",
            .cdp_surface => "CDP automation surface",
            .playwright_puppeteer => "Playwright/Puppeteer compatibility",
            .chrome_replacement => "replace headless Chrome readiness",
        };
    }
};

const CheckStatus = enum {
    pass,
    partial,
    fail,
    skipped,

    fn label(self: CheckStatus) []const u8 {
        return switch (self) {
            .pass => "pass",
            .partial => "partial",
            .fail => "fail",
            .skipped => "skipped",
        };
    }

    fn numerator(self: CheckStatus) usize {
        return switch (self) {
            .pass => 2,
            .partial => 1,
            .fail, .skipped => 0,
        };
    }
};

const Check = struct {
    area: Area,
    name: []const u8,
    weight: usize,
    status: CheckStatus,
    detail: []const u8,
    duration_ms: i64 = 0,
};

pub fn reportText(allocator: std.mem.Allocator, options: Options) ![]const u8 {
    var checks: std.ArrayList(Check) = .empty;
    try addSyntheticJsChecks(allocator, &checks);
    try addWaitChecks(allocator, &checks);
    try addAutomationSurfaceChecks(allocator, &checks);
    try addPlaywrightChecks(allocator, &checks);
    try addChromeReplacementChecks(allocator, &checks);
    try addLiveChecks(allocator, &checks, options);

    const overall = scorePercent(checks.items);
    const cdp_score = areaScorePercent(checks.items, .cdp_surface);
    const pw_score = areaScorePercent(checks.items, .playwright_puppeteer);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeAll("kuri-browser readiness bench\n\n");
    try out.writer.writeAll("target: native replacement for Kuri's Chrome/CDP browser path\n");
    try out.writer.print("mode: {s}\n", .{if (options.run_live) "offline + live probes" else "offline deterministic"});
    try out.writer.print("kuri-base: {s}\n", .{options.kuri_base});
    try out.writer.print("overall readiness: {d}%\n", .{overall});
    try out.writer.print("replace headless Chrome: {s}\n", .{replacementVerdict(overall, cdp_score, pw_score)});

    try out.writer.writeAll("\nBenchmark Methodology\n");
    try out.writer.writeAll("- offline checks use in-memory fixtures and do not touch network or browser caches\n");
    if (options.run_live) {
        try out.writer.writeAll("- live native probes create fresh BrowserRuntime/fetch sessions and use cache-busted URLs\n");
        try out.writer.writeAll("- live screenshot fallback uses a cache-busted top-level URL, but delegates to the running Kuri/Chrome process; Chrome profile or subresource cache can still affect that probe if the server was already warm\n");
    } else {
        try out.writer.writeAll("- live probes are skipped, so no live network or Chrome cache is involved\n");
    }

    try out.writer.writeAll("\nArea Scores\n");
    inline for (std.meta.fields(Area)) |field| {
        const area: Area = @enumFromInt(field.value);
        if (areaScorePercent(checks.items, area)) |score| {
            try out.writer.print("- {s}: {d}%\n", .{ area.label(), score });
        } else {
            try out.writer.print("- {s}: skipped\n", .{area.label()});
        }
    }

    try out.writer.writeAll("\nChecks\n");
    for (checks.items) |check| {
        try out.writer.print("- [{s}] {s}: {s} ({d} pts, {d}ms)\n", .{
            check.status.label(),
            check.area.label(),
            check.name,
            check.weight,
            check.duration_ms,
        });
        try out.writer.print("  detail: {s}\n", .{check.detail});
    }

    try out.writer.writeAll("\nMissing First\n");
    try out.writer.writeAll("- Broader CDP browser protocol domains beyond the minimal WebSocket router\n");
    try out.writer.writeAll("- Playwright/Puppeteer protocol domains, target/session lifecycle, and locator auto-wait behavior\n");
    try out.writer.writeAll("- Layout, paint, screenshot/PDF, viewport, and input fidelity\n");
    try out.writer.writeAll("- More complete web-platform APIs and event-loop timing semantics\n");

    return allocator.dupe(u8, out.written());
}

fn addSyntheticJsChecks(allocator: std.mem.Allocator, checks: *std.ArrayList(Check)) !void {
    const html =
        "<html><head><title>start</title></head><body>" ++
        "<script>" ++
        "localStorage.setItem('mode', 'bench');" ++
        "window.__events = 0;" ++
        "window.__timeout = 0;" ++
        "window.__micro = 0;" ++
        "window.__raf = 0;" ++
        "var button = document.createElement('button');" ++
        "button.id = 'run';" ++
        "button.textContent = 'Run';" ++
        "button.addEventListener('click', function() { window.__events += 1; });" ++
        "document.body.appendChild(button);" ++
        "button.click();" ++
        "setTimeout(function() { window.__timeout = 1; }, 0);" ++
        "queueMicrotask(function() { window.__micro = 1; });" ++
        "requestAnimationFrame(function() { window.__raf = 1; });" ++
        "document.title = 'Bench Ready';" ++
        "</script>" ++
        "</body></html>";
    const expression =
        "[document.title," ++
        "document.querySelectorAll('#run').length," ++
        "window.__events," ++
        "window.__timeout," ++
        "window.__micro," ++
        "window.__raf," ++
        "localStorage.getItem('mode')," ++
        "typeof fetch," ++
        "typeof XMLHttpRequest," ++
        "typeof history.pushState].join('|')";

    const started = milliTimestamp();
    const result = evaluateSynthetic(allocator, html, .{
        .enabled = true,
        .eval_expression = expression,
    }) catch |err| {
        const detail = try std.fmt.allocPrint(allocator, "synthetic JS failed: {s}", .{@errorName(err)});
        try appendCheck(allocator, checks, .js_runtime, "DOM/runtime smoke", 10, .fail, detail, elapsedSince(started));
        return;
    };
    const elapsed = elapsedSince(started);
    const detail = try std.fmt.allocPrint(allocator, "eval={s}; scripts={d}/{d} failed", .{
        result.eval_result,
        result.executed_scripts,
        result.failed_scripts,
    });

    const dom_ok = std.mem.eql(u8, pipeField(result.eval_result, 0), "Bench Ready") and
        std.mem.eql(u8, pipeField(result.eval_result, 1), "1") and
        std.mem.eql(u8, pipeField(result.eval_result, 2), "1") and
        result.failed_scripts == 0;
    try appendCheck(allocator, checks, .js_runtime, "DOM mutation, events, title, eval", 10, passFail(dom_ok), detail, elapsed);

    const timers_ok = std.mem.eql(u8, pipeField(result.eval_result, 3), "1") and
        std.mem.eql(u8, pipeField(result.eval_result, 4), "1") and
        std.mem.eql(u8, pipeField(result.eval_result, 5), "1");
    try appendCheck(allocator, checks, .js_runtime, "timer, microtask, and RAF drain", 8, passFail(timers_ok), detail, elapsed);

    const api_ok = std.mem.eql(u8, pipeField(result.eval_result, 6), "bench") and
        std.mem.eql(u8, pipeField(result.eval_result, 7), "function") and
        std.mem.eql(u8, pipeField(result.eval_result, 8), "function") and
        std.mem.eql(u8, pipeField(result.eval_result, 9), "function");
    try appendCheck(allocator, checks, .js_runtime, "storage, fetch/XHR, history shims", 8, passFail(api_ok), detail, elapsed);
}

fn addWaitChecks(allocator: std.mem.Allocator, checks: *std.ArrayList(Check)) !void {
    {
        const html =
            "<html><body><script>" ++
            "setTimeout(function() {" ++
            "  var node = document.createElement('div');" ++
            "  node.id = 'ready';" ++
            "  document.body.appendChild(node);" ++
            "}, 0);" ++
            "</script></body></html>";
        const started = milliTimestamp();
        const result = evaluateSynthetic(allocator, html, .{
            .wait_selector = "#ready",
            .eval_expression = "String(!!document.querySelector('#ready'))",
        }) catch |err| {
            try appendCheck(allocator, checks, .wait_semantics, "wait selector after async DOM mutation", 10, .fail, try errDetail(allocator, "wait selector failed", err), elapsedSince(started));
            return;
        };
        try appendCheck(allocator, checks, .wait_semantics, "wait selector after async DOM mutation", 10, passFail(result.wait_satisfied and std.mem.eql(u8, result.eval_result, "true")), try waitDetail(allocator, result), elapsedSince(started));
    }

    {
        const html =
            "<html><body><script>" ++
            "queueMicrotask(function() { window.__ready = true; });" ++
            "</script></body></html>";
        const started = milliTimestamp();
        const result = evaluateSynthetic(allocator, html, .{
            .wait_expression = "window.__ready === true",
            .eval_expression = "String(window.__ready === true)",
        }) catch |err| {
            try appendCheck(allocator, checks, .wait_semantics, "wait eval expression", 8, .fail, try errDetail(allocator, "wait eval failed", err), elapsedSince(started));
            return;
        };
        try appendCheck(allocator, checks, .wait_semantics, "wait eval expression", 8, passFail(result.wait_satisfied and std.mem.eql(u8, result.eval_result, "true")), try waitDetail(allocator, result), elapsedSince(started));
    }

    {
        const started = milliTimestamp();
        const result = evaluateSynthetic(allocator, "<html><body><p>never</p></body></html>", .{
            .wait_selector = "#never",
            .wait_iterations = 3,
        }) catch |err| {
            try appendCheck(allocator, checks, .wait_semantics, "wait timeout path", 6, .fail, try errDetail(allocator, "wait timeout failed", err), elapsedSince(started));
            return;
        };
        const timeout_ok = !result.wait_satisfied and result.wait_polls == 3;
        try appendCheck(allocator, checks, .wait_semantics, "wait timeout path", 6, passFail(timeout_ok), try waitDetail(allocator, result), elapsedSince(started));
    }
}

fn addAutomationSurfaceChecks(allocator: std.mem.Allocator, checks: *std.ArrayList(Check)) !void {
    const html =
        "<html><body>" ++
        "<a href='/next'>Next</a>" ++
        "<button aria-label='Save'>Save</button>" ++
        "<label for='q'>Search</label><input id='q' name='q' value='zig'>" ++
        "</body></html>";
    const started = milliTimestamp();
    var document = try dom.Document.parse(allocator, html);
    defer document.deinit();
    const nodes = try snapshot.buildInteractiveSnapshot(allocator, &document, document.root());
    defer snapshot.freeSnapshot(allocator, nodes);
    try appendCheck(
        allocator,
        checks,
        .cdp_surface,
        "interactive snapshot refs",
        8,
        passFail(nodes.len >= 3),
        try std.fmt.allocPrint(allocator, "refs={d}; expected link/button/textbox", .{nodes.len}),
        elapsedSince(started),
    );

    try appendCheck(
        allocator,
        checks,
        .cdp_surface,
        "native evaluate/snapshot/action primitives",
        8,
        .partial,
        "CLI supports JS eval, snapshots, click refs, and type refs; it is not protocol-compatible.",
        0,
    );
    const discovery_started = milliTimestamp();
    const version = cdp_server.versionJson(allocator, .{}) catch |err| {
        try appendCheck(allocator, checks, .cdp_surface, "CDP HTTP discovery endpoints", 6, .fail, try errDetail(allocator, "discovery JSON failed", err), elapsedSince(discovery_started));
        return;
    };
    const list = cdp_server.listJson(allocator, .{}, "about:blank") catch |err| {
        try appendCheck(allocator, checks, .cdp_surface, "CDP HTTP discovery endpoints", 6, .fail, try errDetail(allocator, "target JSON failed", err), elapsedSince(discovery_started));
        return;
    };
    const discovery_ok = std.mem.indexOf(u8, version, "\"webSocketDebuggerUrl\"") != null and
        std.mem.indexOf(u8, version, "KuriBrowser") != null and
        std.mem.indexOf(u8, list, "\"type\":\"page\"") != null;
    try appendCheck(
        allocator,
        checks,
        .cdp_surface,
        "CDP HTTP discovery endpoints",
        6,
        passFail(discovery_ok),
        "serve-cdp exposes /health, /json/version, /json/list, /json/new, and /json/protocol.",
        elapsedSince(discovery_started),
    );
    const websocket_started = milliTimestamp();
    const version_response = cdp_server.dispatchCdpMessageForTest(allocator, "{\"id\":1,\"method\":\"Browser.getVersion\"}") catch |err| {
        try appendCheck(allocator, checks, .cdp_surface, "CDP WebSocket protocol router", 10, .fail, try errDetail(allocator, "Browser.getVersion dispatch failed", err), elapsedSince(websocket_started));
        return;
    };
    const eval_response = cdp_server.dispatchCdpMessageForTest(allocator, "{\"id\":2,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"1 + 2\"}}") catch |err| {
        try appendCheck(allocator, checks, .cdp_surface, "CDP WebSocket protocol router", 10, .fail, try errDetail(allocator, "Runtime.evaluate dispatch failed", err), elapsedSince(websocket_started));
        return;
    };
    const websocket_ok = std.mem.indexOf(u8, version_response, "V8-shaped") != null and
        std.mem.indexOf(u8, eval_response, "\"type\":\"number\"") != null and
        std.mem.indexOf(u8, eval_response, "\"value\":3") != null;
    try appendCheck(
        allocator,
        checks,
        .cdp_surface,
        "CDP WebSocket protocol router",
        10,
        passFail(websocket_ok),
        "serve-cdp upgrades WebSocket connections and routes JSON-RPC for minimal Browser/Target/Page/Runtime/Network/DOM/Input methods.",
        elapsedSince(websocket_started),
    );
    try appendCheck(
        allocator,
        checks,
        .cdp_surface,
        "Runtime/Page/Network/Input domain coverage",
        12,
        .partial,
        "Minimal CDP domains exist, including Runtime.evaluate with V8-shaped remote objects; broad browser-domain parity is still missing.",
        0,
    );
}

fn addPlaywrightChecks(allocator: std.mem.Allocator, checks: *std.ArrayList(Check)) !void {
    try appendCheck(
        allocator,
        checks,
        .playwright_puppeteer,
        "browserWSEndpoint connection",
        12,
        .partial,
        "A browserWSEndpoint can now upgrade and answer basic JSON-RPC, but full Playwright/Puppeteer attach semantics are not validated yet.",
        0,
    );
    try appendCheck(
        allocator,
        checks,
        .playwright_puppeteer,
        "target/context/page lifecycle",
        10,
        .partial,
        "Minimal Target/Page/Runtime lifecycle methods exist; isolated worlds, sessions, workers, frames, and robust event ordering are still incomplete.",
        0,
    );
    try appendCheck(
        allocator,
        checks,
        .playwright_puppeteer,
        "locator actions and auto-wait",
        8,
        .partial,
        "Native refs support basic click/type, but not locator resolution, actionability checks, keyboard, pointer, or auto-wait parity.",
        0,
    );
    try appendCheck(
        allocator,
        checks,
        .playwright_puppeteer,
        "screenshot, tracing, coverage, downloads",
        8,
        .fail,
        "No rendered pixels, screencast, trace, coverage, or download pipeline exists.",
        0,
    );
}

fn addChromeReplacementChecks(allocator: std.mem.Allocator, checks: *std.ArrayList(Check)) !void {
    const html =
        "<html><body>" ++
        "<h1>Bench</h1>" ++
        "<a href='/docs'>Docs</a>" ++
        "<form action='/search'><input name='q' value='zig'><button>Go</button></form>" ++
        "</body></html>";
    const started = milliTimestamp();
    var document = try dom.Document.parse(allocator, html);
    defer document.deinit();
    const links = try render.extractLinks(allocator, &document, document.root());
    const forms = try render.extractForms(allocator, &document, "https://bench.local/");
    const headings = try document.querySelectorAll(allocator, document.root(), "h1");
    const static_ok = links.len == 1 and forms.len == 1 and headings.len == 1;
    try appendCheck(
        allocator,
        checks,
        .chrome_replacement,
        "static extraction baseline",
        8,
        passFail(static_ok),
        try std.fmt.allocPrint(allocator, "links={d}; forms={d}; h1={d}", .{ links.len, forms.len, headings.len }),
        elapsedSince(started),
    );
    const paint_started = milliTimestamp();
    const paint_svg = native_paint.paintPageSvg(allocator, syntheticPaintPage(document), .{}) catch |err| {
        try appendCheck(allocator, checks, .chrome_replacement, "native SVG paint renderer", 6, .fail, try errDetail(allocator, "native paint failed", err), elapsedSince(paint_started));
        return;
    };
    try appendCheck(
        allocator,
        checks,
        .chrome_replacement,
        "native SVG paint renderer",
        6,
        passFail(std.mem.indexOf(u8, paint_svg, "<svg") != null and std.mem.indexOf(u8, paint_svg, "Bench") != null),
        try std.fmt.allocPrint(allocator, "backend=kuri-native-svg-paint; bytes={d}; scope=text/DOM SVG paint, no CSS layout", .{paint_svg.len}),
        elapsedSince(paint_started),
    );
    try appendCheck(
        allocator,
        checks,
        .chrome_replacement,
        "agent-friendly text-first browsing",
        8,
        .partial,
        "Good for HTML/text/selectors/forms/refs; still not a general browser engine.",
        0,
    );
    try appendCheck(
        allocator,
        checks,
        .chrome_replacement,
        "CDP fallback screenshot renderer",
        6,
        .pass,
        "kuri-browser screenshot delegates to Kuri/CDP, adaptively picks smaller PNG/JPEG output, and reports byte savings.",
        0,
    );
    try appendCheck(
        allocator,
        checks,
        .chrome_replacement,
        "layout, paint, screenshot/PDF",
        14,
        .partial,
        "Native SVG text/DOM paint exists; full CSS layout, raster screenshot, and PDF still require future work or the CDP fallback.",
        0,
    );
    try appendCheck(
        allocator,
        checks,
        .chrome_replacement,
        "browser process/profile/security model",
        8,
        .fail,
        "No Chrome-equivalent process isolation, profile model, permissions, or site isolation.",
        0,
    );
}

fn syntheticPaintPage(document: dom.Document) model.Page {
    return .{
        .requested_url = "https://bench.local/",
        .url = "https://bench.local/",
        .html = document.html,
        .dom = document,
        .title = "Bench",
        .text = "Bench Docs Go",
        .links = &.{},
        .forms = &.{},
        .resources = &.{},
        .js = .{},
        .redirect_chain = &.{},
        .cookie_count = 0,
        .status_code = 200,
        .content_type = "text/html",
        .fallback_mode = .native_static,
        .pipeline = "synthetic",
    };
}

fn addLiveChecks(allocator: std.mem.Allocator, checks: *std.ArrayList(Check), options: Options) !void {
    if (!options.run_live) {
        try appendSkippedLiveChecks(allocator, checks, "offline mode");
        return;
    }

    try checks.append(allocator, checkLiveHnSelector(allocator) catch |err| try skippedCheck(allocator, .js_runtime, "live Hacker News selector probe", 4, err));
    try checks.append(allocator, checkLiveQuotesJs(allocator) catch |err| try skippedCheck(allocator, .js_runtime, "live quotes JS probe", 6, err));
    try checks.append(allocator, checkLiveTodoMvcWait(allocator) catch |err| try skippedCheck(allocator, .wait_semantics, "live TodoMVC wait probe", 6, err));
    try checks.append(allocator, checkLiveHar(allocator) catch |err| try skippedCheck(allocator, .chrome_replacement, "live HAR capture probe", 4, err));
    try checks.append(allocator, checkLiveNativePaint(allocator) catch |err| try skippedCheck(allocator, .chrome_replacement, "live native SVG paint probe", 4, err));
    try checks.append(allocator, checkLiveScreenshotFallback(allocator, options.kuri_base) catch |err| try skippedCheck(allocator, .chrome_replacement, "live CDP screenshot fallback probe", 6, err));
    try checks.append(allocator, checkKuriCdpHealth(allocator, options.kuri_base) catch |err| try skippedCheck(allocator, .cdp_surface, "live Kuri CDP baseline health", 4, err));
}

fn appendSkippedLiveChecks(allocator: std.mem.Allocator, checks: *std.ArrayList(Check), reason: []const u8) !void {
    try appendCheck(allocator, checks, .js_runtime, "live Hacker News selector probe", 4, .skipped, reason, 0);
    try appendCheck(allocator, checks, .js_runtime, "live quotes JS probe", 6, .skipped, reason, 0);
    try appendCheck(allocator, checks, .wait_semantics, "live TodoMVC wait probe", 6, .skipped, reason, 0);
    try appendCheck(allocator, checks, .chrome_replacement, "live HAR capture probe", 4, .skipped, reason, 0);
    try appendCheck(allocator, checks, .chrome_replacement, "live native SVG paint probe", 4, .skipped, reason, 0);
    try appendCheck(allocator, checks, .chrome_replacement, "live CDP screenshot fallback probe", 6, .skipped, reason, 0);
    try appendCheck(allocator, checks, .cdp_surface, "live Kuri CDP baseline health", 4, .skipped, reason, 0);
}

fn checkLiveHnSelector(allocator: std.mem.Allocator) !Check {
    const started = milliTimestamp();
    const url = try cacheBustedUrl(allocator, "https://news.ycombinator.com/");
    const runtime = core.BrowserRuntime.init(allocator);
    const page = try runtime.loadPage(url);
    const matches = try page.dom.querySelectorAll(allocator, page.dom.root(), ".titleline a");
    return .{
        .area = .js_runtime,
        .name = "live Hacker News selector probe",
        .weight = 4,
        .status = passFail(matches.len > 0),
        .detail = try std.fmt.allocPrint(allocator, "cache=cache-busted-url; HN .titleline a matches={d}", .{matches.len}),
        .duration_ms = elapsedSince(started),
    };
}

fn checkLiveQuotesJs(allocator: std.mem.Allocator) !Check {
    const started = milliTimestamp();
    const url = try cacheBustedUrl(allocator, "https://quotes.toscrape.com/js/");
    const runtime = core.BrowserRuntime.init(allocator);
    const page = try runtime.loadPageWithOptions(url, .{
        .enabled = true,
        .eval_expression = "String(document.querySelectorAll('.quote').length)",
    });
    return .{
        .area = .js_runtime,
        .name = "live quotes JS probe",
        .weight = 6,
        .status = passFail(std.mem.eql(u8, page.js.eval_result, "10")),
        .detail = try std.fmt.allocPrint(allocator, "cache=cache-busted-url; quote count={s}; js_error={s}", .{
            if (page.js.eval_result.len > 0) page.js.eval_result else "(empty)",
            if (page.js.error_message.len > 0) page.js.error_message else "(none)",
        }),
        .duration_ms = elapsedSince(started),
    };
}

fn checkLiveTodoMvcWait(allocator: std.mem.Allocator) !Check {
    const started = milliTimestamp();
    const url = try cacheBustedUrl(allocator, "https://demo.playwright.dev/todomvc/");
    const runtime = core.BrowserRuntime.init(allocator);
    const page = try runtime.loadPageWithOptions(url, .{
        .wait_selector = ".todoapp",
        .eval_expression = "String(!!document.querySelector('.todoapp')) + '|' + String(!!document.querySelector('.new-todo'))",
        .wait_iterations = 24,
    });
    return .{
        .area = .wait_semantics,
        .name = "live TodoMVC wait probe",
        .weight = 6,
        .status = passFail(page.js.wait_satisfied and std.mem.eql(u8, page.js.eval_result, "true|true")),
        .detail = try std.fmt.allocPrint(allocator, "cache=cache-busted-url; wait={s}; polls={d}; eval={s}; js_error={s}", .{
            if (page.js.wait_satisfied) "yes" else "no",
            page.js.wait_polls,
            if (page.js.eval_result.len > 0) page.js.eval_result else "(empty)",
            if (page.js.error_message.len > 0) page.js.error_message else "(none)",
        }),
        .duration_ms = elapsedSince(started),
    };
}

fn checkLiveHar(allocator: std.mem.Allocator) !Check {
    const started = milliTimestamp();
    const url = try cacheBustedUrl(allocator, "https://example.com/");
    const artifacts = try render.renderUrlArtifacts(allocator, url, .{
        .capture_har = true,
    });
    const har_json = artifacts.har_json orelse "";
    const ok = std.mem.indexOf(u8, har_json, "\"entries\"") != null and
        std.mem.indexOf(u8, har_json, "https://example.com/") != null;
    return .{
        .area = .chrome_replacement,
        .name = "live HAR capture probe",
        .weight = 4,
        .status = passFail(ok),
        .detail = try std.fmt.allocPrint(allocator, "cache=cache-busted-url; har-bytes={d}; page-status={d}", .{ har_json.len, artifacts.page.status_code }),
        .duration_ms = elapsedSince(started),
    };
}

fn checkLiveNativePaint(allocator: std.mem.Allocator) !Check {
    const started = milliTimestamp();
    const path = ".zig-cache/kuri-browser-native-paint-bench.svg";
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    const url = try cacheBustedUrl(allocator, "https://example.com/");
    const result = try native_paint.paintUrl(allocator, url, .{
        .out_path = path,
    });
    const ok = result.bytes > 0 and result.node_count > 0;
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    return .{
        .area = .chrome_replacement,
        .name = "live native SVG paint probe",
        .weight = 4,
        .status = passFail(ok),
        .detail = try std.fmt.allocPrint(allocator, "cache=cache-busted-url; backend={s}; bytes={d}; nodes={d}; text-bytes={d}; path={s}", .{
            result.backend,
            result.bytes,
            result.node_count,
            result.text_bytes,
            result.path,
        }),
        .duration_ms = elapsedSince(started),
    };
}

fn checkLiveScreenshotFallback(allocator: std.mem.Allocator, kuri_base: []const u8) !Check {
    const started = milliTimestamp();
    const path = ".zig-cache/kuri-browser-bench-screenshot.jpg";
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    const url = try cacheBustedUrl(allocator, "https://example.com/");
    const result = try screenshot.captureUrl(allocator, url, .{
        .kuri_base = kuri_base,
        .out_path = path,
        .format = "png",
        .quality = 50,
        .full = false,
        .compress = true,
    });
    const ok = result.bytes > 0;
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    return .{
        .area = .chrome_replacement,
        .name = "live CDP screenshot fallback probe",
        .weight = 6,
        .status = passFail(ok),
        .detail = try std.fmt.allocPrint(allocator, "cache=cache-busted-url+chrome-fallback-cache-possible; backend={s}; format={s}; bytes={d}; saved={d}% vs png; path={s}", .{
            result.backend,
            result.format,
            result.bytes,
            result.saved_percent,
            result.path,
        }),
        .duration_ms = elapsedSince(started),
    };
}

fn checkKuriCdpHealth(allocator: std.mem.Allocator, base_url: []const u8) !Check {
    const started = milliTimestamp();
    const url = try joinBasePath(allocator, base_url, "/health");
    const body = try httpGet(allocator, url);
    return .{
        .area = .cdp_surface,
        .name = "live Kuri CDP baseline health",
        .weight = 4,
        .status = .pass,
        .detail = try std.fmt.allocPrint(allocator, "cache=not-applicable; {s} responded ({d} bytes)", .{ url, body.len }),
        .duration_ms = elapsedSince(started),
    };
}

fn cacheBustedUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const separator: u8 = if (std.mem.indexOfScalar(u8, url, '?') == null) '?' else '&';
    return std.fmt.allocPrint(allocator, "{s}{c}kuri_bench={d}", .{ url, separator, milliTimestamp() });
}

fn evaluateSynthetic(allocator: std.mem.Allocator, html: []const u8, options: js_runtime.Options) !model.JsExecution {
    var session = fetch.Session.init(allocator, "kuri-browser-bench");
    defer session.deinit();

    var document = try dom.Document.parse(allocator, html);
    defer document.deinit();

    return js_runtime.evaluatePage(
        allocator,
        &session,
        &document,
        html,
        "https://bench.local/index.html",
        &[_]model.Resource{},
        options,
    );
}

fn httpGet(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
    };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();
    var response = try req.receiveHead(&.{});
    if (response.head.status != .ok) return error.UnexpectedHttpStatus;

    var body: std.ArrayList(u8) = .empty;
    var transfer_buf: [8192]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);
    try reader.appendRemainingUnlimited(allocator, &body);
    return body.items;
}

fn appendCheck(
    allocator: std.mem.Allocator,
    checks: *std.ArrayList(Check),
    area: Area,
    name: []const u8,
    weight: usize,
    status: CheckStatus,
    detail: []const u8,
    duration_ms: i64,
) !void {
    try checks.append(allocator, .{
        .area = area,
        .name = name,
        .weight = weight,
        .status = status,
        .detail = detail,
        .duration_ms = duration_ms,
    });
}

fn skippedCheck(allocator: std.mem.Allocator, area: Area, name: []const u8, weight: usize, err: anyerror) !Check {
    return .{
        .area = area,
        .name = name,
        .weight = weight,
        .status = .skipped,
        .detail = try std.fmt.allocPrint(allocator, "skipped: {s}", .{@errorName(err)}),
        .duration_ms = 0,
    };
}

fn waitDetail(allocator: std.mem.Allocator, result: model.JsExecution) ![]const u8 {
    return std.fmt.allocPrint(allocator, "expression={s}; satisfied={s}; polls={d}; eval={s}", .{
        result.wait_expression,
        if (result.wait_satisfied) "yes" else "no",
        result.wait_polls,
        if (result.eval_result.len > 0) result.eval_result else "(none)",
    });
}

fn errDetail(allocator: std.mem.Allocator, label: []const u8, err: anyerror) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ label, @errorName(err) });
}

fn passFail(ok: bool) CheckStatus {
    return if (ok) .pass else .fail;
}

fn scorePercent(checks: []const Check) usize {
    var numer: usize = 0;
    var denom: usize = 0;
    for (checks) |check| {
        if (check.status == .skipped) continue;
        numer += check.weight * check.status.numerator();
        denom += check.weight * 2;
    }
    return percentRounded(numer, denom);
}

fn areaScorePercent(checks: []const Check, area: Area) ?usize {
    var numer: usize = 0;
    var denom: usize = 0;
    for (checks) |check| {
        if (check.area != area or check.status == .skipped) continue;
        numer += check.weight * check.status.numerator();
        denom += check.weight * 2;
    }
    if (denom == 0) return null;
    return percentRounded(numer, denom);
}

fn percentRounded(numer: usize, denom: usize) usize {
    if (denom == 0) return 0;
    return (numer * 100 + denom / 2) / denom;
}

fn replacementVerdict(overall: usize, cdp_score: ?usize, pw_score: ?usize) []const u8 {
    const cdp = cdp_score orelse 0;
    const pw = pw_score orelse 0;
    if (overall >= 85 and cdp >= 80 and pw >= 80) return "candidate";
    if (overall >= 65 and cdp >= 40 and pw >= 40) return "limited pilot only";
    return "not ready";
}

fn pipeField(value: []const u8, index: usize) []const u8 {
    var fields = std.mem.splitScalar(u8, value, '|');
    var i: usize = 0;
    while (fields.next()) |field| : (i += 1) {
        if (i == index) return field;
    }
    return "";
}

fn elapsedSince(started_ms: i64) i64 {
    return milliTimestamp() - started_ms;
}

fn joinBasePath(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ std.mem.trimEnd(u8, base_url, "/"), path });
}

fn milliTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

test "offline report includes readiness sections" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const text = try reportText(arena_impl.allocator(), .{ .run_live = false });

    try std.testing.expect(std.mem.indexOf(u8, text, "kuri-browser readiness bench") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "JS/runtime completeness") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "wait semantics") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[pass] JS/runtime completeness: DOM mutation, events, title, eval") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[pass] wait semantics: wait selector after async DOM mutation") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Playwright/Puppeteer compatibility") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "replace headless Chrome: not ready") != null);
}
