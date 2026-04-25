const std = @import("std");
const compat = @import("compat.zig");
const config = @import("bridge/config.zig");
const server = @import("server/router.zig");
const Bridge = @import("bridge/bridge.zig").Bridge;
const launcher = @import("chrome/launcher.zig");

const version = "0.3.3";

const CliAction = enum {
    run,
    help,
    version,
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
        .run => {},
    }

    const cfg = config.load();
    var runtime_cfg = cfg;

    std.log.info("kuri v{s}", .{version});
    std.log.info("listening on {s}:{d}", .{ cfg.host, cfg.port });

    // Chrome lifecycle management
    var chrome = launcher.Launcher.init(gpa, cfg);
    defer chrome.deinit();

    if (cfg.cdp_url) |url| {
        std.log.info("connecting to existing Chrome at {s}", .{url});
    } else {
        std.log.info("launching managed Chrome instance", .{});
    }

    const start_result = try chrome.start(cfg);
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

    return error.UnknownArgument;
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
        \\    kuri -h, --help          Show this help
        \\    kuri -V, --version       Print version and exit
        \\
        \\  ENVIRONMENT
        \\    HOST                     Bind host (default: 127.0.0.1)
        \\    PORT                     Bind port (default: 8080)
        \\    HEADLESS                 Launch managed Chrome headless=true by default
        \\    CDP_URL                  Attach to existing Chrome instead of launching one
        \\    STATE_DIR                State directory (default: .kuri)
        \\    KURI_SECRET              Optional auth secret (alias: BROWDIE_SECRET)
        \\    KURI_EXTENSIONS          Comma-separated Chrome extensions
        \\    KURI_PROXY               Proxy URL for managed Chrome
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

test "parseCliAction rejects unknown argument" {
    try std.testing.expectError(error.UnknownArgument, parseCliAction(&.{ "kuri", "--wat" }));
}

test {
    _ = @import("bridge/config.zig");
    _ = @import("bridge/bridge.zig");
    _ = @import("server/router.zig");
    _ = @import("server/response.zig");
    _ = @import("server/middleware.zig");
    _ = @import("cdp/protocol.zig");
    _ = @import("cdp/client.zig");
    _ = @import("cdp/websocket.zig");
    _ = @import("cdp/actions.zig");
    _ = @import("cdp/stealth.zig");
    _ = @import("cdp/har.zig");
    _ = @import("snapshot/a11y.zig");
    _ = @import("snapshot/diff.zig");
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
    _ = @import("util/tls.zig");
}
