const std = @import("std");

pub const CrawlResult = struct {
    url: []const u8,
    html: ?[]const u8 = null,
    markdown: ?[]const u8 = null,
    err: ?[]const u8 = null,
    elapsed_ms: u64 = 0,
};

pub const PipelineOpts = struct {
    max_concurrent: usize = 5,
    output_dir: []const u8 = ".",
};

test "CrawlResult defaults" {
    const result = CrawlResult{ .url = "https://example.com" };
    try std.testing.expectEqualStrings("https://example.com", result.url);
    try std.testing.expect(result.html == null);
    try std.testing.expect(result.err == null);
}
