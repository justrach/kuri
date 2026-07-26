const std = @import("std");
const compat = @import("../compat.zig");

/// Stealth JS script embedded at comptime.
pub const stealth_script = @embedFile("js/stealth.js");

/// Console + error collector script embedded at comptime. Injected on every
/// new document so window.__kuri_console / window.__kuri_errors are populated
/// from page load; read + cleared by the /console and /errors endpoints.
pub const console_collector_script = @embedFile("js/console_collector.js");

/// React fiber introspector, embedded at comptime. Injected on every new
/// document so window.__kuri_react is populated before react-dom's own init
/// runs (needed for version detection + commit observation); read by the
/// /react/tree, /react/inspect, /react/renders and /react/suspense endpoints.
pub const react_fiber_script = @embedFile("js/react_fiber.js");

/// User agents for rotation.
pub const user_agents = [_][]const u8{
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:137.0) Gecko/20100101 Firefox/137.0",
};

/// Get a pseudo-random user agent based on timestamp.
pub fn randomUserAgent() []const u8 {
    const ts: u64 = @intCast(compat.timestampSeconds());
    return user_agents[ts % user_agents.len];
}

test "stealth script loads" {
    try std.testing.expect(stealth_script.len > 0);
    // The script is injected on new document AND evaluated into the live page,
    // so it must be safe to run twice in the same global. A top-level `const`
    // made the second run a SyntaxError that aborted the whole injection and
    // leaked a kuri-internal error into the page's /errors stream.
    try std.testing.expect(std.mem.indexOf(u8, stealth_script, "__kuri_stealth_applied") != null);
    try std.testing.expect(std.mem.indexOf(u8, stealth_script, "(function () {") != null);
    // No top-level `const`/`let`: every declaration must be inside the IIFE.
    try std.testing.expect(!std.mem.startsWith(u8, stealth_script, "const "));
    try std.testing.expect(std.mem.indexOf(u8, stealth_script, "\nconst ") == null);
    try std.testing.expect(std.mem.indexOf(u8, stealth_script, "\nlet ") == null);
}

test "console collector script loads" {
    try std.testing.expect(console_collector_script.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, console_collector_script, "__kuri_console") != null);
    try std.testing.expect(std.mem.indexOf(u8, console_collector_script, "__kuri_errors") != null);
}

test "react fiber script loads" {
    try std.testing.expect(react_fiber_script.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, react_fiber_script, "__kuri_react") != null);
    try std.testing.expect(std.mem.indexOf(u8, react_fiber_script, "__reactFiber$") != null);
    try std.testing.expect(std.mem.indexOf(u8, react_fiber_script, "__REACT_DEVTOOLS_GLOBAL_HOOK__") != null);
    // Never gate discovery on the devtools hook — must find fibers standalone.
    try std.testing.expect(std.mem.indexOf(u8, react_fiber_script, "__reactContainer$") != null);
}

test "randomUserAgent returns valid UA" {
    const ua = randomUserAgent();
    try std.testing.expect(ua.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, ua, "Mozilla") != null);
}
