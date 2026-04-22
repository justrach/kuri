const std = @import("std");
const compat = @import("../compat.zig");

/// Generate a filename from URL and format.
/// Format: {domain}_{path}_{date}.{ext}
pub fn generateFilename(url: []const u8, ext: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const domain = extractDomain(url);
    const epoch: u64 = @intCast(compat.timestampSeconds());
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

/// Return domain with dots replaced by underscores, e.g. "sub.example.com" -> "sub_example_com".
pub fn getDomainNameSanitized(url: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const domain = extractDomain(url);
    const result = try allocator.dupe(u8, domain);
    for (result) |*c| {
        if (c.* == '.') c.* = '_';
    }
    return result;
}

/// Public alias for extractDomain — returns the domain string with dots kept.
pub fn getDomainName(url: []const u8) []const u8 {
    return extractDomain(url);
}

/// Save content to output_dir/<filename>.<ext>.
/// Validates output_dir, creates it if needed, writes the file, returns the full path (caller owns).
pub fn saveToLocal(
    content: []const u8,
    url: []const u8,
    ext: []const u8,
    output_dir: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    if (!validateOutputDir(output_dir)) return error.InvalidPath;

    // Create directory if it doesn't exist
    compat.cwdMakePath(output_dir) catch {};

    const filename = try generateFilename(url, ext, allocator);
    defer allocator.free(filename);

    const filepath = try std.fs.path.join(allocator, &.{ output_dir, filename });

    const fd = compat.cwdCreateFile(filepath) catch |err| {
        allocator.free(filepath);
        return err;
    };
    defer compat.fdClose(fd);
    compat.fdWriteAll(fd, content) catch |err| {
        allocator.free(filepath);
        return err;
    };

    return filepath;
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

test "getDomainNameSanitized replaces dots" {
    const allocator = std.testing.allocator;
    const d = try getDomainNameSanitized("https://sub.example.com/path", allocator);
    defer allocator.free(d);
    try std.testing.expectEqualStrings("sub_example_com", d);
}

test "getDomainName returns domain with dots" {
    const d = getDomainName("https://sub.example.com/path");
    try std.testing.expectEqualStrings("sub.example.com", d);
}

test "saveToLocal writes file and returns path" {
    const allocator = std.testing.allocator;
    const epoch: u64 = @intCast(compat.timestampSeconds());
    const dir = try std.fmt.allocPrint(allocator, "/tmp/browdie_test_{d}", .{epoch});
    defer allocator.free(dir);

    const filepath = try saveToLocal("hello world", "https://test.example.com/page", "txt", dir, allocator);
    defer allocator.free(filepath);

    // Verify file content
    const content = try compat.cwdReadFile(std.testing.allocator, filepath, 64);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("hello world", content);

    // Clean up test dir
    deleteTreeAbsolute(dir);
}

fn deleteTreeAbsolute(dir: []const u8) void {
    var buf: [4096]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "rm -rf {s}", .{dir}) catch return;
    buf[cmd.len] = 0;
    const pid = std.c.fork();
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", buf[0..cmd.len :0], null };
        _ = std.c.execve("/bin/sh", &argv, @ptrCast(std.c.environ));
        std.c.exit(127);
    }
    if (pid > 0) _ = std.c.waitpid(pid, null, 0);
}

test "saveToLocal rejects traversal" {
    const allocator = std.testing.allocator;
    const result = saveToLocal("x", "https://example.com", "txt", "../../../etc", allocator);
    try std.testing.expectError(error.InvalidPath, result);
}
