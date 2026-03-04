const std = @import("std");

/// Readability JS script embedded at comptime.
pub const readability_script = @embedFile("js/readability.js");

/// Result from readability extraction.
pub const ReadabilityResult = struct {
    title: []const u8,
    content: []const u8,
    text_content: []const u8,
    excerpt: []const u8,
};

test "readability script loads" {
    try std.testing.expect(readability_script.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, readability_script, "extractContent") != null);
}
