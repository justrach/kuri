const std = @import("std");
const compat = @import("../compat.zig");

pub fn fetchHttp(allocator: std.mem.Allocator, url: []const u8, user_agent: []const u8) ![]const u8 {
    return fetchHttpStd(allocator, url, user_agent) catch |err| switch (err) {
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => {
            if (fetchHttpCurl(allocator, url, user_agent)) |body| {
                return body;
            } else |_| {
                return err;
            }
        },
        else => return err,
    };
}

fn fetchHttpStd(allocator: std.mem.Allocator, url: []const u8, user_agent: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = std.Io.Threaded.global_single_threaded.io() };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var req = try client.request(.GET, uri, .{
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = user_agent },
            .{ .name = "Accept", .value = "text/html,application/xhtml+xml,*/*" },
            .{ .name = "Accept-Encoding", .value = "gzip, deflate" },
        },
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    if (response.head.status != .ok) {
        std.debug.print("HTTP {d}\n", .{@intFromEnum(response.head.status)});
        return error.HttpError;
    }

    var body: std.ArrayList(u8) = .empty;
    var transfer_buf: [8192]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);
    try reader.appendRemainingUnlimited(allocator, &body);

    return body.items;
}

fn fetchHttpCurl(allocator: std.mem.Allocator, url: []const u8, user_agent: []const u8) ![]const u8 {
    const result = try compat.runCommand(allocator, &.{
        "curl",
        "-fsSL",
        "--compressed",
        "-A",
        user_agent,
        url,
    }, 16 * 1024 * 1024);
    if (result.term != 0 or result.stdout.len == 0) return error.CommandFailed;
    return result.stdout;
}
