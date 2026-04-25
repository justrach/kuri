const std = @import("std");
const compat = @import("../compat.zig");
const validator = @import("../crawler/validator.zig");

const max_redirects = 10;
const redirect_buf_len = 8192;
const curl_header_limit = 64 * 1024;

pub fn fetchHttp(allocator: std.mem.Allocator, url: []const u8, user_agent: []const u8) ![]const u8 {
    try validator.validateUrl(url);

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

    var current_url = url;
    var redirect_resolve_buf: [redirect_buf_len]u8 = undefined;
    var redirect_url_buf_a: [redirect_buf_len]u8 = undefined;
    var redirect_url_buf_b: [redirect_buf_len]u8 = undefined;
    var use_first_redirect_buf = true;
    var redirects_seen: usize = 0;

    while (true) {
        const uri = try std.Uri.parse(current_url);

        var req = try client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = &.{
                .{ .name = "User-Agent", .value = user_agent },
                .{ .name = "Accept", .value = "text/html,application/xhtml+xml,*/*" },
                .{ .name = "Accept-Encoding", .value = "gzip, deflate" },
            },
        });
        defer req.deinit();

        try req.sendBodiless();

        var response = try req.receiveHead(&.{});
        const status_code = @intFromEnum(response.head.status);
        if (isRedirectStatusCode(status_code)) {
            if (redirects_seen >= max_redirects) return error.TooManyHttpRedirects;
            const location = response.head.location orelse return error.HttpRedirectLocationMissing;
            const next_url_buf = if (use_first_redirect_buf) redirect_url_buf_a[0..] else redirect_url_buf_b[0..];
            current_url = try resolveValidatedRedirectUrl(current_url, location, redirect_resolve_buf[0..], next_url_buf);
            use_first_redirect_buf = !use_first_redirect_buf;
            redirects_seen += 1;
            continue;
        }

        if (response.head.status != .ok) {
            std.debug.print("HTTP {d}\n", .{status_code});
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
}

fn fetchHttpCurl(allocator: std.mem.Allocator, url: []const u8, user_agent: []const u8) ![]const u8 {
    var current_url = url;
    var redirect_resolve_buf: [redirect_buf_len]u8 = undefined;
    var redirect_url_buf_a: [redirect_buf_len]u8 = undefined;
    var redirect_url_buf_b: [redirect_buf_len]u8 = undefined;
    var use_first_redirect_buf = true;
    var redirects_seen: usize = 0;

    while (true) {
        const head_result = try compat.runCommand(allocator, &.{
            "curl",
            "-sS",
            "--compressed",
            "-A",
            user_agent,
            "-D",
            "-",
            "-o",
            "/dev/null",
            current_url,
        }, curl_header_limit);
        defer allocator.free(head_result.stdout);

        if (head_result.term != 0) return error.CommandFailed;

        const response_head = try parseCurlResponseHead(head_result.stdout);
        if (isRedirectStatusCode(response_head.status_code)) {
            if (redirects_seen >= max_redirects) return error.TooManyHttpRedirects;
            const location = response_head.location orelse return error.HttpRedirectLocationMissing;
            const next_url_buf = if (use_first_redirect_buf) redirect_url_buf_a[0..] else redirect_url_buf_b[0..];
            current_url = try resolveValidatedRedirectUrl(current_url, location, redirect_resolve_buf[0..], next_url_buf);
            use_first_redirect_buf = !use_first_redirect_buf;
            redirects_seen += 1;
            continue;
        }

        if (response_head.status_code != 200) {
            std.debug.print("HTTP {d}\n", .{response_head.status_code});
            return error.HttpError;
        }

        const body_result = try compat.runCommand(allocator, &.{
            "curl",
            "-fsS",
            "--compressed",
            "-A",
            user_agent,
            current_url,
        }, 16 * 1024 * 1024);
        if (body_result.term != 0 or body_result.stdout.len == 0) {
            allocator.free(body_result.stdout);
            return error.CommandFailed;
        }

        return body_result.stdout;
    }
}

const CurlResponseHead = struct {
    status_code: u16,
    location: ?[]const u8,
};

fn isRedirectStatusCode(status_code: u16) bool {
    return status_code >= 300 and status_code < 400;
}

fn resolveValidatedRedirectUrl(base_url: []const u8, location: []const u8, aux_buf: []u8, out_buf: []u8) ![]const u8 {
    const base_uri = try std.Uri.parse(base_url);
    if (location.len > aux_buf.len) return error.HttpRedirectLocationOversize;

    @memcpy(aux_buf[0..location.len], location);
    var remaining_aux = aux_buf;
    const resolved_uri = base_uri.resolveInPlace(location.len, &remaining_aux) catch |err| switch (err) {
        error.UnexpectedCharacter,
        error.InvalidFormat,
        error.InvalidPort,
        error.InvalidHostName,
        => return error.HttpRedirectLocationInvalid,
        error.NoSpaceLeft => return error.HttpRedirectLocationOversize,
    };

    const resolved_url = std.fmt.bufPrint(out_buf, "{f}", .{resolved_uri}) catch return error.HttpRedirectLocationOversize;
    try validator.validateUrl(resolved_url);
    return resolved_url;
}

fn parseCurlResponseHead(output: []const u8) !CurlResponseHead {
    const block = findLastCurlHeaderBlock(output) orelse return error.HttpHeadersInvalid;
    var lines = std.mem.tokenizeAny(u8, block, "\r\n");

    const status_line = lines.next() orelse return error.HttpHeadersInvalid;
    var parts = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = parts.next() orelse return error.HttpHeadersInvalid;
    const status_code = std.fmt.parseInt(u16, parts.next() orelse return error.HttpHeadersInvalid, 10) catch {
        return error.HttpHeadersInvalid;
    };

    var location: ?[]const u8 = null;
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..separator], "Location")) continue;
        location = std.mem.trim(u8, line[separator + 1 ..], " \t");
    }

    return .{
        .status_code = status_code,
        .location = location,
    };
}

fn findLastCurlHeaderBlock(output: []const u8) ?[]const u8 {
    var block_start: usize = 0;
    var last_http_block: ?[]const u8 = null;
    var cursor: usize = 0;

    while (cursor <= output.len) {
        const line_end = std.mem.indexOfScalarPos(u8, output, cursor, '\n') orelse output.len;
        const line = std.mem.trimEnd(u8, output[cursor..line_end], "\r");

        if (line.len == 0) {
            const block = output[block_start..cursor];
            if (std.mem.startsWith(u8, block, "HTTP/")) {
                last_http_block = block;
            }
            block_start = if (line_end < output.len) line_end + 1 else output.len;
        }

        if (line_end == output.len) break;
        cursor = line_end + 1;
    }

    if (block_start < output.len) {
        const block = output[block_start..];
        if (std.mem.startsWith(u8, block, "HTTP/")) {
            last_http_block = block;
        }
    }

    return last_http_block;
}

test "resolveValidatedRedirectUrl resolves relative locations" {
    var aux_buf: [256]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    const resolved = try resolveValidatedRedirectUrl("https://example.com/start?q=1", "/next", aux_buf[0..], out_buf[0..]);
    try std.testing.expectEqualStrings("https://example.com/next", resolved);
}

test "resolveValidatedRedirectUrl rejects localhost redirects" {
    var aux_buf: [256]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    try std.testing.expectError(
        validator.ValidationError.LocalhostBlocked,
        resolveValidatedRedirectUrl("https://example.com/start", "http://LOCALHOST./admin", aux_buf[0..], out_buf[0..]),
    );
}

test "parseCurlResponseHead prefers the last response block" {
    const sample =
        "HTTP/1.1 100 Continue\r\n\r\n" ++
        "HTTP/2 302\r\n" ++
        "location: /next\r\n" ++
        "x-test: 1\r\n\r\n";

    const head = try parseCurlResponseHead(sample);
    try std.testing.expectEqual(@as(u16, 302), head.status_code);
    try std.testing.expectEqualStrings("/next", head.location.?);
}
