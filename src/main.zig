const std = @import("std");
const config = @import("bridge/config.zig");
const server = @import("server/router.zig");
const Bridge = @import("bridge/bridge.zig").Bridge;

pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const cfg = config.load();

    std.log.info("agentic-browdie v0.1.0", .{});
    std.log.info("listening on {s}:{d}", .{ cfg.host, cfg.port });

    if (cfg.cdp_url) |url| {
        std.log.info("connecting to existing Chrome at {s}", .{url});
    } else {
        std.log.info("no CDP_URL set — will launch Chrome on first request", .{});
    }

    // Initialize bridge (central state)
    var bridge = Bridge.init(gpa);
    defer bridge.deinit();

    // Start HTTP server
    try server.run(gpa, &bridge, cfg);
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
}
