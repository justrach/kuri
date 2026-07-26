const std = @import("std");

/// Hand-rolled, zero-copy JSON substring scanning shared by the CDP event
/// consumers (`har.zig`'s Network event parsing and `client.zig`'s in-read-
/// loop Fetch.requestPaused handling). Deliberately NOT `std.json` — these
/// call sites need cheap substring slicing per CDP event, not a parse tree,
/// and this matches the pre-existing idiom in `har.zig` (see
/// `extractField`/`extractHeadersObject`, which this module generalizes).
///
/// All returned slices borrow from the input `json` slice — callers must
/// `allocator.dupe(...)` anything they need to outlive it.
/// Extract the object value for `key` (e.g. "request", "response", "headers")
/// as a raw JSON substring, by counting brace depth from the object's `{`.
/// Returns null if `key` isn't found as an object (i.e. `"key":{`) or the
/// object never closes (malformed/truncated JSON).
pub fn extractObject(json: []const u8, key: []const u8) ?[]const u8 {
    var key_buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&key_buf, "\"{s}\":{{", .{key}) catch return null;
    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const obj_start = key_pos + needle.len - 1; // include the opening {

    // Brace-depth counting must be JSON-string-aware: a literal '{' or '}'
    // inside a string value (e.g. an unescaped '{' in a request URL's query
    // string — '{'/'}' are NOT in the WHATWG URL query percent-encode set,
    // so they pass through a real browser request unescaped) would otherwise
    // desync `depth` and either return null (hanging a paused Fetch request
    // forever, since the caller never replies to Chrome) or return a
    // truncated object. So: track whether we're inside a string literal and
    // ignore braces there, honoring backslash escapes so an escaped quote
    // (\") doesn't prematurely end the string.
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var i = obj_start;
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
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return json[obj_start .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

/// Extract a simple string or scalar (number/bool/null) field value from
/// JSON. Zero-copy: the returned slice borrows from `json` and is NOT
/// unescaped (a `"` field containing `\"` is returned with the backslash
/// still in it) — fine for our use, which is re-embedding CDP-supplied
/// values verbatim into a new outgoing CDP command, never displaying them.
pub fn extractField(json: []const u8, field: []const u8) ?[]const u8 {
    var search_buf: [256]u8 = undefined;
    const prefix = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{field}) catch return null;

    const field_pos = std.mem.indexOf(u8, json, prefix) orelse return null;
    const after_field = field_pos + prefix.len;

    // Skip colon and whitespace
    var i = after_field;
    while (i < json.len and (json[i] == ':' or json[i] == ' ' or json[i] == '\t')) : (i += 1) {}
    if (i >= json.len) return null;

    if (json[i] == '"') {
        const val_start = i + 1;
        // Find the closing quote, honoring backslash escapes. A naive
        // indexOfScalarPos would stop at the first `"` byte and truncate the
        // value at an embedded `\"` — reachable from real Chrome payloads
        // (opaque-path URLs like javascript:/data:/mailto: keep raw quotes,
        // as do header values echoed into a Fetch.requestPaused event). A
        // truncated value is not merely wrong: these slices get re-embedded
        // verbatim into the outgoing CDP reply, so cutting mid-escape emits a
        // trailing backslash, Chrome rejects the malformed command, and the
        // paused request is never answered — i.e. the page hangs.
        var j = val_start;
        while (j < json.len) : (j += 1) {
            switch (json[j]) {
                '\\' => j += 1, // skip the escaped byte
                '"' => return json[val_start..j],
                else => {},
            }
        }
        return null;
    }

    const val_start = i;
    var val_end = i;
    while (val_end < json.len) : (val_end += 1) {
        switch (json[val_end]) {
            ',', '}', ']', ' ', '\t', '\r', '\n' => break,
            else => {},
        }
    }
    if (val_end == val_start) return null;
    return json[val_start..val_end];
}

/// Escape `"`, `\`, and common control characters for safe embedding inside
/// a JSON string literal. Allocates; caller frees. Used only for strings we
/// did NOT receive from Chrome (dialog prompt text, rule content-type/error
/// fields set by a caller) — values echoed straight back from a CDP event
/// (requestId, url, method) are already validly-escaped JSON and are never
/// passed through this function.
pub fn escapeJsonAlloc(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

// ── Tests ───────────────────────────────────────────────────────────────

test "extractField finds string and numeric values" {
    const json = "{\"method\":\"Network.requestWillBeSent\",\"requestId\":\"abc123\",\"status\":304}";
    try std.testing.expectEqualStrings("abc123", extractField(json, "requestId").?);
    try std.testing.expectEqualStrings("304", extractField(json, "status").?);
    try std.testing.expect(extractField(json, "nonexistent") == null);
}

test "extractObject extracts a balanced nested object" {
    const json = "{\"method\":\"Fetch.requestPaused\",\"params\":{\"requestId\":\"1\",\"request\":{\"url\":\"https://example.com/\",\"method\":\"GET\",\"headers\":{\"a\":\"b\"}},\"resourceType\":\"Document\"}}";
    const request_obj = extractObject(json, "request").?;
    try std.testing.expectEqualStrings("https://example.com/", extractField(request_obj, "url").?);
    try std.testing.expectEqualStrings("GET", extractField(request_obj, "method").?);
}

test "extractObject returns null when key is absent" {
    try std.testing.expect(extractObject("{\"a\":1}", "request") == null);
}

test "extractObject is unfazed by unbalanced literal braces inside a string value (GraphQL-over-GET query string)" {
    // '{' and '}' are not in the WHATWG URL query percent-encode set, so a
    // request like fetch('https://api.example.com/graphql?q={a{b') reaches
    // Fetch.requestPaused with literal, unescaped braces in the url string.
    // A naive (non-string-aware) brace counter desyncs on these and never
    // sees depth return to 0, returning null — which upstream (autoRespondFetch)
    // turns into a silently buffered, never-answered Fetch.requestPaused event,
    // hanging the paused request forever.
    const json = "{\"method\":\"Fetch.requestPaused\",\"params\":{\"requestId\":\"1\",\"request\":{\"url\":\"https://api.example.com/graphql?q={a{b\",\"method\":\"GET\",\"headers\":{\"a\":\"b\"}},\"resourceType\":\"Document\"}}";
    const request_obj = extractObject(json, "request").?;
    try std.testing.expectEqualStrings("https://api.example.com/graphql?q={a{b", extractField(request_obj, "url").?);
    try std.testing.expectEqualStrings("GET", extractField(request_obj, "method").?);
}

test "extractObject is unfazed by a string value with more literal '}' than '{'" {
    const json = "{\"params\":{\"requestId\":\"1\",\"request\":{\"url\":\"https://example.com/?q=}}\",\"method\":\"GET\"}}}";
    const request_obj = extractObject(json, "request").?;
    try std.testing.expectEqualStrings("https://example.com/?q=}}", extractField(request_obj, "url").?);
    try std.testing.expectEqualStrings("GET", extractField(request_obj, "method").?);
}

test "extractObject does not end a string early on an escaped quote containing a brace-adjacent char" {
    const json = "{\"params\":{\"request\":{\"note\":\"say \\\"hi}\\\" ok\",\"method\":\"GET\"}}}";
    const request_obj = extractObject(json, "request").?;
    try std.testing.expectEqualStrings("GET", extractField(request_obj, "method").?);
}

test "extractField does not truncate a string value at an escaped quote" {
    // Reachable from real Chrome payloads: opaque-path schemes (javascript:,
    // data:, mailto:) use the C0-control-only percent-encode set, so a raw `"`
    // survives into request.url and arrives JSON-escaped as \". A naive
    // first-quote scan cuts the value there — and because these slices are
    // re-embedded verbatim into the outgoing Fetch reply, the cut leaves a
    // trailing backslash, Chrome rejects the command, and the paused request
    // is never answered.
    const json = "{\"url\":\"javascript:alert(\\\"hi\\\")\",\"method\":\"GET\"}";
    try std.testing.expectEqualStrings("javascript:alert(\\\"hi\\\")", extractField(json, "url").?);
    try std.testing.expectEqualStrings("GET", extractField(json, "method").?);
}

test "extractField returns null on an unterminated string value" {
    try std.testing.expect(extractField("{\"url\":\"https://example.com/", "url") == null);
    // A trailing backslash must not run the escape skip past the buffer end.
    try std.testing.expect(extractField("{\"url\":\"abc\\", "url") == null);
}

test "escapeJsonAlloc escapes quotes and backslashes" {
    const out = try escapeJsonAlloc(std.testing.allocator, "he said \"hi\"\\ok");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("he said \\\"hi\\\"\\\\ok", out);
}

test "escapeJsonAlloc passes through plain strings unchanged" {
    const out = try escapeJsonAlloc(std.testing.allocator, "plain text");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("plain text", out);
}
