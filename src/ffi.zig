//! C-ABI surface for embedding kuri's stateless fetch into a host process.
//!
//! No HTTP server, no Bridge, no shared state — one call in, rendered bytes out.
//! Designed for in-process binding (e.g. Bun `bun:ffi` dlopen) so a host can drive
//! kuri's fetch/render path without spawning the long-lived `kuri` server.
//!
//! Reuses the same helpers the `kuri-fetch` one-shot entrypoint uses:
//!   validator.validateUrl (SSRF guard) → http_fetch.fetchHttp → markdown.htmlToMarkdown.
const std = @import("std");
const validator = @import("crawler/validator.zig");
const markdown = @import("crawler/markdown.zig");
const http_fetch = @import("util/http_fetch.zig");

const DEFAULT_UA = "Mozilla/5.0 (compatible; kuri-ffi/0.3.3)";

/// Fetch `url_ptr` (NUL-terminated) and render it.
///   mode 0 = markdown, anything else = raw HTML.
/// Returns a C-owned, NUL-terminated buffer the caller MUST free with `kuri_free`,
/// or null on a blocked URL / fetch / render error. Stateless: no globals touched.
export fn kuri_fetch(url_ptr: [*:0]const u8, mode: c_int) callconv(.c) ?[*:0]u8 {
    const url = std.mem.span(url_ptr);
    validator.validateUrl(url) catch return null;

    var arena_impl = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const html = http_fetch.fetchHttp(arena, url, DEFAULT_UA) catch return null;
    const out: []const u8 = switch (mode) {
        0 => markdown.htmlToMarkdown(html, arena) catch return null,
        else => html,
    };

    // Copy into a C-owned, NUL-terminated buffer that survives `arena.deinit()`.
    const buf = std.heap.c_allocator.allocSentinel(u8, out.len, 0) catch return null;
    @memcpy(buf, out);
    return buf.ptr;
}

/// Free a buffer returned by `kuri_fetch`. Null-safe.
export fn kuri_free(ptr: ?[*:0]u8) callconv(.c) void {
    if (ptr) |p| std.heap.c_allocator.free(std.mem.span(p));
}

/// Liveness probe for the embedding host (returns the ABI version).
export fn kuri_ffi_abi_version() callconv(.c) c_int {
    return 1;
}
