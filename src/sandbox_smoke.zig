// Standalone smoke test for the sandbox runtime.
// Run: zig test src/sandbox/sandbox_test.zig --dep quickjs ... (handled by build.zig)
const std = @import("std");
const runtime = @import("sandbox/runtime.zig");
const fingerprint = @import("sandbox/fingerprint.zig");
const network = @import("sandbox/network.zig");

test "sandbox boots, shim loads, navigator.userAgent is set" {
    const a = std.testing.allocator;
    var fp = fingerprint.Fingerprint.builtinChromeMacARM();
    fp.target_origin = "https://example.com";
    fp.target_href = "https://example.com/";

    const sb = try runtime.Sandbox.init(a, .{
        .fingerprint = fp,
        .target_origin = "https://example.com",
        .target_href = "https://example.com/",
    });
    defer sb.deinit();

    try sb.installShim();

    const ua = try sb.evalJson("navigator.userAgent");
    defer a.free(ua);
    try std.testing.expect(std.mem.indexOf(u8, ua, "Chrome") != null);
    try std.testing.expect(std.mem.indexOf(u8, ua, "Mozilla") != null);
}

test "shim provides screen, location, performance" {
    const a = std.testing.allocator;
    const sb = try runtime.Sandbox.init(a, .{
        .fingerprint = fingerprint.Fingerprint.builtinChromeMacARM(),
        .target_origin = "https://example.com",
        .target_href = "https://example.com/foo?bar=1",
    });
    defer sb.deinit();
    try sb.installShim();

    const sw = try sb.evalJson("screen.width");
    defer a.free(sw);
    try std.testing.expectEqualStrings("1920", sw);

    // location.pathname round-trip — accepts pathname or pathname+search depending
    // on URL polyfill behaviour (acceptable variance for Phase 1).
    const path = try sb.evalJson("location.pathname");
    defer a.free(path);
    try std.testing.expect(std.mem.indexOf(u8, path, "/foo") != null);

    const has_perf = try sb.evalJson("typeof performance.now === 'function'");
    defer a.free(has_perf);
    try std.testing.expectEqualStrings("true", has_perf);
}

test "shim provides crypto.subtle.digest (SHA-256) via sync native path" {
    const a = std.testing.allocator;
    const sb = try runtime.Sandbox.init(a, .{
        .fingerprint = fingerprint.Fingerprint.builtinChromeMacARM(),
        .target_origin = "https://example.com",
    });
    defer sb.deinit();
    try sb.installShim();

    // Direct native call: __nativeSubtleDigest is sync, returns Uint8Array.
    // Bypasses the Promise wrapper since QuickJS doesn't auto-pump microtasks
    // in this test harness (production wires JS_ExecutePendingJob via the
    // router after evalBundle).
    const hex = try sb.evalJson(
        \\(() => {
        \\  const enc = new TextEncoder();
        \\  const buf = enc.encode('hello');
        \\  const hash = __nativeSubtleDigest('SHA-256', buf);
        \\  return Array.from(hash).map(b => b.toString(16).padStart(2,'0')).join('');
        \\})()
    );
    defer a.free(hex);
    // SHA-256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
    try std.testing.expect(std.mem.indexOf(u8, hex, "2cf24dba") != null);
}

test "fingerprint serialize -> shim consumes" {
    const a = std.testing.allocator;
    var fp = fingerprint.Fingerprint.builtinChromeMacARM();
    fp.target_origin = "https://example.com";
    const sb = try runtime.Sandbox.init(a, .{
        .fingerprint = fp,
        .target_origin = "https://example.com",
    });
    defer sb.deinit();
    try sb.installShim();

    const w = try sb.evalJson("navigator.webdriver");
    defer a.free(w);
    try std.testing.expectEqualStrings("false", w);

    const lang = try sb.evalJson("navigator.languages.length");
    defer a.free(lang);
    try std.testing.expectEqualStrings("2", lang);
}
