const std = @import("std");

pub const R2Config = struct {
    endpoint_url: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    bucket_name: []const u8,
};

pub fn loadConfig() ?R2Config {
    const endpoint = std.posix.getenv("R2_ENDPOINT_URL") orelse return null;
    const access_key = std.posix.getenv("R2_ACCESS_KEY") orelse return null;
    const secret_key = std.posix.getenv("R2_SECRET_KEY") orelse return null;
    const bucket = std.posix.getenv("R2_BUCKET_NAME") orelse return null;

    return .{
        .endpoint_url = endpoint,
        .access_key = access_key,
        .secret_key = secret_key,
        .bucket_name = bucket,
    };
}

test "loadConfig returns null without env" {
    const cfg = loadConfig();
    try std.testing.expect(cfg == null);
}
