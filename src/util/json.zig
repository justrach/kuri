const std = @import("std");

/// Write a JSON object with string key-value pairs.
pub fn writeJsonObject(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, fields: []const [2][]const u8) !void {
    try buf.appendSlice(allocator, "{");
    for (fields, 0..) |field, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.print(allocator, "\"{s}\":\"{s}\"", .{ field[0], field[1] });
    }
    try buf.appendSlice(allocator, "}");
}

/// Escape a string for JSON output.
pub fn jsonEscape(input: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (input) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.print(allocator, "\\u{x:0>4}", .{c});
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    return buf.toOwnedSlice(allocator);
}

test "jsonEscape handles special chars" {
    const result = try jsonEscape("hello \"world\"\nnewline", std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("hello \\\"world\\\"\\nnewline", result);
}

test "jsonEscape handles backslash" {
    const result = try jsonEscape("path\\to\\file", std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("path\\\\to\\\\file", result);
}

/// Unescape a JSON string literal (the contents between quotes).
///
/// Handles: `\n \t \r \b \f \\ \" \/` plus `\uXXXX` including UTF-16
/// surrogate pairs (`😀` → `😀`).
///
/// On malformed input (short `\u`, invalid hex, lone surrogate) the
/// offending backslash is emitted literally and scanning continues —
/// matches `jsonEscape`'s permissive style and avoids erroring on
/// CDP responses that occasionally stream partial frames.
pub fn jsonUnescape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            try buf.append(allocator, s[i]);
            i += 1;
            continue;
        }

        switch (s[i + 1]) {
            'n' => {
                try buf.append(allocator, '\n');
                i += 2;
            },
            't' => {
                try buf.append(allocator, '\t');
                i += 2;
            },
            'r' => {
                try buf.append(allocator, '\r');
                i += 2;
            },
            'b' => {
                try buf.append(allocator, 0x08);
                i += 2;
            },
            'f' => {
                try buf.append(allocator, 0x0C);
                i += 2;
            },
            '\\' => {
                try buf.append(allocator, '\\');
                i += 2;
            },
            '"' => {
                try buf.append(allocator, '"');
                i += 2;
            },
            '/' => {
                try buf.append(allocator, '/');
                i += 2;
            },
            'u' => {
                // Need `\uXXXX` — 6 chars minimum
                if (i + 6 > s.len) {
                    try buf.append(allocator, s[i]);
                    i += 1;
                    continue;
                }
                const hi = std.fmt.parseInt(u16, s[i + 2 .. i + 6], 16) catch {
                    try buf.append(allocator, s[i]);
                    i += 1;
                    continue;
                };

                var cp: u21 = hi;
                var consumed: usize = 6;

                // UTF-16 surrogate pair: `\uD8xx\uDCxx` → U+10000..U+10FFFF
                if (hi >= 0xD800 and hi <= 0xDBFF) {
                    if (i + 12 <= s.len and s[i + 6] == '\\' and s[i + 7] == 'u') {
                        if (std.fmt.parseInt(u16, s[i + 8 .. i + 12], 16)) |lo| {
                            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                                cp = 0x10000 +
                                    (@as(u21, hi - 0xD800) << 10) +
                                    (lo - 0xDC00);
                                consumed = 12;
                            }
                        } else |_| {}
                    }
                }

                var utf8_buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &utf8_buf) catch {
                    // Lone surrogate / invalid codepoint → emit literally
                    try buf.append(allocator, s[i]);
                    i += 1;
                    continue;
                };
                try buf.appendSlice(allocator, utf8_buf[0..n]);
                i += consumed;
            },
            else => {
                try buf.append(allocator, s[i]);
                i += 1;
            },
        }
    }

    return buf.toOwnedSlice(allocator);
}

test "jsonUnescape handles basic escapes" {
    const result = try jsonUnescape(std.testing.allocator, "hello\\nworld\\t!");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("hello\nworld\t!", result);
}

test "jsonUnescape handles quote and backslash" {
    const result = try jsonUnescape(std.testing.allocator, "say \\\"hi\\\" \\\\ back");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("say \"hi\" \\ back", result);
}

test "jsonUnescape handles \\uXXXX basic multilingual plane" {
    // Japanese "コンテンツ" in \uXXXX form
    const result = try jsonUnescape(
        std.testing.allocator,
        "\\u30b3\\u30f3\\u30c6\\u30f3\\u30c4",
    );
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("コンテンツ", result);
}

test "jsonUnescape handles surrogate pair (emoji)" {
    // U+1F600 (😀) as 😀
    const result = try jsonUnescape(std.testing.allocator, "\\uD83D\\uDE00");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("😀", result);
}

test "jsonUnescape handles mixed content" {
    const result = try jsonUnescape(
        std.testing.allocator,
        "\\u30b3\\u30f3\\n\\u30c6\\u30f3\\u30c4",
    );
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("コン\nテンツ", result);
}

test "jsonUnescape tolerates malformed \\u (short)" {
    const result = try jsonUnescape(std.testing.allocator, "bad \\u30 tail");
    defer std.testing.allocator.free(result);

    // Truncated escape → emit backslash literally, continue scanning
    try std.testing.expectEqualStrings("bad \\u30 tail", result);
}

test "jsonUnescape tolerates malformed \\u (invalid hex)" {
    const result = try jsonUnescape(std.testing.allocator, "bad \\uXYZW tail");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("bad \\uXYZW tail", result);
}

test "jsonUnescape tolerates lone high surrogate" {
    // High surrogate without a following low surrogate — fall through literally
    const result = try jsonUnescape(std.testing.allocator, "\\uD83D hello");
    defer std.testing.allocator.free(result);

    // utf8Encode rejects the lone surrogate → backslash emitted literally
    try std.testing.expectEqualStrings("\\uD83D hello", result);
}

test "jsonUnescape handles \\r \\b \\f \\/" {
    const result = try jsonUnescape(std.testing.allocator, "ab\\rcd\\bef\\fgh\\/ij");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("ab\rcd\x08ef\x0cgh/ij", result);
}

test "jsonUnescape tolerates lone low surrogate" {
    // 0xDE00 alone (no preceding high surrogate) — utf8Encode rejects it,
    // the backslash is emitted literally and scanning continues.
    const result = try jsonUnescape(std.testing.allocator, "\\uDE00 tail");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("\\uDE00 tail", result);
}

test "jsonUnescape tolerates high surrogate followed by non-low surrogate" {
    // \uD83D followed by A ('A') — not a valid low surrogate, so we
    // don't pair. The high surrogate falls back to literal; the following
    // A is then decoded normally.
    const result = try jsonUnescape(std.testing.allocator, "\\uD83D\\u0041");
    defer std.testing.allocator.free(result);

    // Literal `\uD83D` (6 chars) + decoded 'A'
    try std.testing.expectEqualStrings("\\uD83DA", result);
}
