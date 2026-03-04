const std = @import("std");

/// Generate a filename from URL and format.
/// Format: {domain}_{path}_{date}.{ext}
pub fn generateFilename(url: []const u8, ext: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const domain = extractDomain(url);
    const epoch: u64 = @intCast(std.time.timestamp());
    const epoch_secs = epoch;

    // Simple date: use epoch seconds for uniqueness
    return std.fmt.allocPrint(allocator, "{s}_{d}.{s}", .{ domain, epoch_secs, ext });
}

fn extractDomain(url: []const u8) []const u8 {
    // Skip scheme
    const after_scheme = if (std.mem.indexOf(u8, url, "://")) |idx| url[idx + 3 ..] else url;

    // Take until port or path
    var end = after_scheme.len;
    if (std.mem.indexOfScalar(u8, after_scheme, ':')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, after_scheme, '/')) |idx| end = @min(end, idx);

    return after_scheme[0..end];
}

/// Check that a directory path is safe (no traversal).
pub fn validateOutputDir(path: []const u8) bool {
    // Reject directory traversal
    if (std.mem.indexOf(u8, path, "..") != null) return false;
    return true;
}

test "extractDomain" {
    try std.testing.expectEqualStrings("example.com", extractDomain("https://example.com/path"));
    try std.testing.expectEqualStrings("example.com", extractDomain("https://example.com:8080/path"));
    try std.testing.expectEqualStrings("sub.example.com", extractDomain("http://sub.example.com"));
}

test "validateOutputDir blocks traversal" {
    try std.testing.expect(validateOutputDir("./output"));
    try std.testing.expect(validateOutputDir("/tmp/crawl"));
    try std.testing.expect(!validateOutputDir("../../../etc"));
    try std.testing.expect(!validateOutputDir("/tmp/../etc"));
}
