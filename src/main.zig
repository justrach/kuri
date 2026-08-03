const std = @import("std");
const compat = @import("compat.zig");
const config = @import("bridge/config.zig");
const server = @import("server/router.zig");
const Bridge = @import("bridge/bridge.zig").Bridge;
const launcher = @import("chrome/launcher.zig");
const api_token = @import("server/api_token.zig");
const lifecycle = @import("lifecycle.zig");
const updater = @import("update.zig");
const telemetry = @import("telemetry.zig");

const version = @import("build_options").version;

const CliAction = enum {
    run,
    help,
    version,
    mobile,
    token,
    update,
};

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const args = try init.args.toSlice(arena_impl.allocator());

    const action = parseCliAction(args) catch {
        printUnknownArgument(args[1]);
        std.process.exit(1);
    };
    switch (action) {
        .help => {
            printUsage();
            return;
        },
        .version => {
            compat.writeToStdout("kuri " ++ version ++ "\n");
            return;
        },
        .mobile => {
            // Dispatch `kuri android <...>` and `kuri ios <...>` to the
            // sibling kuri-mobile binary. Keeps the mobile code in its
            // own subproject (kuri-mobile/) and avoids pulling those
            // modules into the main browser binary.
            try execMobile(arena_impl.allocator(), args);
            return;
        },
        .token => {
            // Print (or generate then print) the API token used to authenticate
            // against the kuri HTTP API. Useful for shell aliases:
            //   curl -H "Authorization: Bearer $(kuri token)" http://127.0.0.1:8080/tabs
            var resolved = try api_token.ensure(gpa);
            defer resolved.deinit(gpa);
            compat.writeToStdout(resolved.token);
            compat.writeToStdout("\n");
            return;
        },
        .update => {
            var opts: updater.Options = .{};
            for (args[2..]) |a| {
                if (std.mem.eql(u8, a, "--check")) {
                    opts.check_only = true;
                } else if (std.mem.startsWith(u8, a, "--dir=")) {
                    opts.dir = a["--dir=".len..];
                } else {
                    printUnknownArgument(a);
                    std.process.exit(1);
                }
            }
            const code = try updater.run(gpa, version, opts);
            if (code != 0) std.process.exit(code);
            return;
        },
        .run => {},
    }

    const cfg = config.load();
    var runtime_cfg = cfg;

    // Phase 0a: never let the HTTP server run without an auth token. If the
    // user didn't set KURI_API_TOKEN/KURI_SECRET, generate one and persist to
    // ~/.kuri/api.token (0600). The token must outlive `runtime_cfg`, so we
    // leak it deliberately into a static-lifetime slice held by the gpa.
    const resolved_token = try api_token.ensure(gpa);
    runtime_cfg.auth_secret = resolved_token.token;
    switch (resolved_token.source) {
        .env => std.log.info("api auth: using token from environment", .{}),
        .file_loaded => std.log.info("api auth: loaded token from {s}", .{resolved_token.path.?}),
        .file_generated => std.log.info("api auth: generated fresh token at {s} (run `kuri token` to print)", .{resolved_token.path.?}),
    }

    std.log.info("kuri v{s}", .{version});
    std.log.info("listening on {s}:{d}", .{ cfg.host, cfg.port });

    // Chrome lifecycle management
    var chrome = launcher.Launcher.init(gpa, cfg);
    defer chrome.deinit();

    // Hook SIGINT/SIGTERM/SIGHUP so the deferred deinit actually runs when
    // we're killed by a supervisor or Ctrl+C — otherwise the child Chrome
    // orphans and leaves a stale SingletonLock for the next run.
    lifecycle.install(&chrome);

    if (cfg.cdp_url) |url| {
        std.log.info("connecting to existing Chrome at {s}", .{url});
    } else {
        std.log.info("launching managed Chrome instance", .{});
    }

    const start_result = chrome.start(cfg) catch |err| {
        std.log.err("could not start managed Chrome or reach its DevTools endpoint: {s}", .{@errorName(err)});
        std.log.err("another Chrome or kuri may be holding the profile lock or the CDP port.", .{});
        std.log.err("try: pkill -f -- --remote-debugging-port ; rm -f \"$HOME\"/.kuri/chrome-profile*/Singleton* ; then re-run kuri", .{});
        return err;
    };
    runtime_cfg.cdp_url = start_result.cdp_url;
    std.log.info("CDP endpoint: {s}", .{start_result.cdp_url});
    std.log.info("CDP port: {d}", .{start_result.cdp_port});

    // Initialize bridge (central state)
    var bridge = Bridge.init(gpa);
    defer bridge.deinit();

    // Hydrate the bridge before serving so first-run /tabs works immediately.
    var startup_arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer startup_arena_impl.deinit();
    const startup_discovered = try server.discoverTabs(startup_arena_impl.allocator(), &bridge, runtime_cfg, start_result.cdp_port);
    std.log.info("startup discovery registered {d} tabs", .{startup_discovered});

    // Anonymous, opt-out usage telemetry (KURI_NO_TELEMETRY / --no-telemetry).
    // Records route names, latency, status, and byte counts only — never URLs,
    // page content, or anything that identifies a user. See src/telemetry.zig.
    telemetry.init(gpa, telemetryDisabled(args));
    defer telemetry.deinit();
    telemetry.startSyncThread();
    telemetry.recordSessionStart();

    // Print the Jupyter-style banner *just* before the server loop blocks.
    // Token visibility is redacted when stderr isn't a TTY (see api_token.zig).
    var banner_buf: [2048]u8 = undefined;
    api_token.printStartupBanner(banner_buf[0..], version, cfg.host, cfg.port, resolved_token);

    // Start HTTP server
    try server.run(gpa, &bridge, runtime_cfg, start_result.cdp_port);
}

fn parseCliAction(args: []const []const u8) !CliAction {
    if (args.len <= 1) return .run;

    if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        return .help;
    }
    if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-V")) {
        return .version;
    }

    if (std.mem.eql(u8, args[1], "android") or std.mem.eql(u8, args[1], "ios")) {
        return .mobile;
    }

    if (std.mem.eql(u8, args[1], "token")) {
        return .token;
    }

    // `upgrade` is accepted too: it is what half of people type, and failing
    // an upgrade command over vocabulary is a poor way to meet a user who is
    // trying to get onto a newer version.
    if (std.mem.eql(u8, args[1], "update") or std.mem.eql(u8, args[1], "upgrade")) {
        return .update;
    }

    // Server-mode flags (e.g. `kuri --no-telemetry`) don't switch the action.
    if (std.mem.eql(u8, args[1], "--no-telemetry")) {
        return .run;
    }

    return error.UnknownArgument;
}

/// Whether to disable usage telemetry: `--no-telemetry` on the command line
/// (KURI_NO_TELEMETRY is checked inside telemetry.init).
fn telemetryDisabled(args: []const []const u8) bool {
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--no-telemetry")) return true;
    }
    return false;
}

/// Locate `kuri-mobile` next to this binary (or in PATH) and execvp it.
fn execMobile(arena: std.mem.Allocator, args: []const []const u8) !void {
    // Try a sibling path next to argv[0] first; otherwise fall back to PATH.
    const sibling: ?[]const u8 = blk: {
        const argv0 = args[0];
        const dir = std.fs.path.dirname(argv0) orelse break :blk null;
        if (dir.len == 0) break :blk null;
        const candidate = try std.fmt.allocPrint(arena, "{s}/kuri-mobile", .{dir});
        break :blk candidate;
    };

    // Build argv: kuri-mobile <android|ios> <rest...>
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(arena);
    try argv.append(arena, sibling orelse "kuri-mobile");
    for (args[1..]) |a| try argv.append(arena, a);

    // Convert to NUL-terminated C strings.
    var c_args: std.ArrayList([:0]u8) = .empty;
    defer {
        for (c_args.items) |s| arena.free(s);
        c_args.deinit(arena);
    }
    for (argv.items) |a| {
        const dup = try arena.allocSentinel(u8, a.len, 0);
        @memcpy(dup[0..a.len], a);
        try c_args.append(arena, dup);
    }
    const c_argv = try arena.alloc(?[*:0]const u8, c_args.items.len + 1);
    for (c_args.items, 0..) |s, i| c_argv[i] = s.ptr;
    c_argv[c_args.items.len] = null;

    _ = compat.execvp(c_args.items[0].ptr, @ptrCast(c_argv.ptr));
    std.debug.print("error: failed to exec '{s}'. Is kuri-mobile installed alongside kuri?\n", .{argv.items[0]});
    std.process.exit(127);
}

fn printUnknownArgument(arg: []const u8) void {
    std.debug.print("error: unknown argument '{s}'\n", .{arg});
    std.debug.print("Run 'kuri --help' for usage.\n", .{});
}

fn printUsage() void {
    compat.writeToStdout(
        \\  kuri — browser automation server
        \\
        \\  USAGE
        \\    kuri                     Start the HTTP/CDP server
        \\    kuri android <cmd>       Drive Android devices (delegates to kuri-mobile)
        \\    kuri ios <cmd>           Drive iOS sims/devices (delegates to kuri-mobile)
        \\    kuri token               Print the API token (creates one if missing)
        \\    kuri update              Update to the current release (--check to only report)
        \\    kuri --no-telemetry      Start the server with usage telemetry disabled
        \\    kuri -h, --help          Show this help
        \\    kuri -V, --version       Print version and exit
        \\
        \\  ENVIRONMENT
        \\    HOST                     Bind host (default: 127.0.0.1)
        \\    PORT                     Bind port (default: 8080)
        \\    HEADLESS                 Launch managed Chrome headless=true by default
        \\    CDP_URL                  Attach to existing Chrome instead of launching one
        \\    STATE_DIR                State directory (default: .kuri)
        \\    KURI_API_TOKEN           Bearer token for the HTTP API (auto-generated if unset)
        \\    KURI_SECRET              Legacy alias of KURI_API_TOKEN (also: BROWDIE_SECRET)
        \\    KURI_EXTENSIONS          Comma-separated Chrome extensions
        \\    KURI_PROXY               Proxy URL for managed Chrome
        \\    KURI_NO_TELEMETRY        Disable anonymous usage telemetry (or use --no-telemetry)
        \\    KURI_TELEMETRY_URL       Override the telemetry ingest endpoint (OTLP/HTTP logs)
        \\    STALE_TAB_INTERVAL_S     Tab staleness interval (default: 30)
        \\    REQUEST_TIMEOUT_MS       Default request timeout (default: 30000)
        \\    NAVIGATE_TIMEOUT_MS      Default navigate timeout (default: 30000)
        \\
        \\  EXAMPLES
        \\    kuri
        \\    PORT=9229 HEADLESS=false kuri
        \\    CDP_URL=http://127.0.0.1:9222/json/version kuri
        \\
    );
}

test "parseCliAction defaults to run" {
    try std.testing.expectEqual(CliAction.run, try parseCliAction(&.{"kuri"}));
}

test "parseCliAction handles help and version" {
    try std.testing.expectEqual(CliAction.help, try parseCliAction(&.{ "kuri", "--help" }));
    try std.testing.expectEqual(CliAction.help, try parseCliAction(&.{ "kuri", "-h" }));
    try std.testing.expectEqual(CliAction.version, try parseCliAction(&.{ "kuri", "--version" }));
    try std.testing.expectEqual(CliAction.version, try parseCliAction(&.{ "kuri", "-V" }));
}

test "parseCliAction recognises token subcommand" {
    try std.testing.expectEqual(CliAction.token, try parseCliAction(&.{ "kuri", "token" }));
}

test "parseCliAction recognises update and its upgrade alias" {
    try std.testing.expectEqual(CliAction.update, try parseCliAction(&.{ "kuri", "update" }));
    try std.testing.expectEqual(CliAction.update, try parseCliAction(&.{ "kuri", "upgrade" }));
}

test "parseCliAction rejects unknown argument" {
    try std.testing.expectError(error.UnknownArgument, parseCliAction(&.{ "kuri", "--wat" }));
}

test {
    _ = @import("bridge/config.zig");
    _ = @import("bridge/bridge.zig");
    _ = @import("server/router.zig");
    _ = @import("server/response.zig");
    _ = @import("server/middleware.zig");
    _ = @import("server/api_token.zig");
    _ = @import("lifecycle.zig");
    _ = @import("cdp/protocol.zig");
    _ = @import("cdp/client.zig");
    _ = @import("cdp/websocket.zig");
    _ = @import("cdp/actions.zig");
    _ = @import("cdp/dispatch.zig");
    _ = @import("cdp/stealth.zig");
    _ = @import("cdp/har.zig");
    _ = @import("snapshot/a11y.zig");
    _ = @import("snapshot/diff.zig");
    _ = @import("snapshot/replay.zig");
    _ = @import("snapshot/ref_cache.zig");
    _ = @import("crawler/validator.zig");
    _ = @import("crawler/markdown.zig");
    _ = @import("crawler/fetcher.zig");
    _ = @import("crawler/pipeline.zig");
    _ = @import("crawler/extractor.zig");
    _ = @import("util/json.zig");
    _ = @import("test/harness.zig");
    _ = @import("chrome/launcher.zig");
    _ = @import("test/integration.zig");
    _ = @import("storage/local.zig");
    _ = @import("storage/auth_profiles.zig");
    _ = @import("storage/connect_store.zig");
    _ = @import("util/tls.zig");
    _ = @import("update.zig");
}
