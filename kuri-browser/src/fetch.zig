const std = @import("std");
const process = @import("process.zig");

pub const ValidationError = error{
    InvalidScheme,
    InvalidUrl,
    LocalhostBlocked,
    PrivateIp,
};

pub const FetchError = ValidationError || error{
    HttpError,
    TooManyRedirects,
    RedirectLocationMissing,
    RedirectLocationInvalid,
    RedirectLocationOversize,
    ResponseTooLarge,
};

pub const FetchResult = struct {
    url: []const u8,
    body: []const u8,
    status_code: u16,
    content_type: []const u8,
};

const max_redirects = 10;
const max_body_bytes = 8 * 1024 * 1024;
const redirect_buf_len = 8192;

pub fn fetchHtml(allocator: std.mem.Allocator, url: []const u8, user_agent: []const u8) !FetchResult {
    try validateUrl(url);

    const body = fetchHtmlStd(allocator, url, user_agent) catch |err| switch (err) {
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => try fetchHtmlCurl(allocator, url, user_agent),
        else => return err,
    };

    return .{
        .url = try allocator.dupe(u8, url),
        .body = body,
        .status_code = 200,
        .content_type = try allocator.dupe(u8, "text/html"),
    };
}

fn fetchHtmlStd(allocator: std.mem.Allocator, url: []const u8, user_agent: []const u8) ![]const u8 {
    try validateUrl(url);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
    };
    defer client.deinit();

    var current_url = url;
    var current_url_buf_a: [redirect_buf_len]u8 = undefined;
    var current_url_buf_b: [redirect_buf_len]u8 = undefined;
    var resolve_buf: [redirect_buf_len]u8 = undefined;
    var use_buf_a = true;
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
        const status_code: u16 = @intFromEnum(response.head.status);

        if (isRedirectStatus(status_code)) {
            if (redirects_seen >= max_redirects) return error.TooManyRedirects;
            const location = response.head.location orelse return error.RedirectLocationMissing;
            const next_url_buf = if (use_buf_a) current_url_buf_a[0..] else current_url_buf_b[0..];
            current_url = try resolveValidatedRedirectUrl(current_url, location, resolve_buf[0..], next_url_buf);
            use_buf_a = !use_buf_a;
            redirects_seen += 1;
            continue;
        }

        if (status_code < 200 or status_code >= 300) {
            return error.HttpError;
        }

        var body: std.ArrayList(u8) = .empty;
        var transfer_buf: [8192]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
        const reader = response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);
        try reader.appendRemainingUnlimited(allocator, &body);
        if (body.items.len > max_body_bytes) return error.ResponseTooLarge;

        return body.items;
    }
}

fn fetchHtmlCurl(allocator: std.mem.Allocator, url: []const u8, user_agent: []const u8) ![]const u8 {
    const result = try process.runCommand(allocator, &.{
        "curl",
        "-fsSL",
        "--compressed",
        "-A",
        user_agent,
        url,
    }, max_body_bytes);

    if (result.term != 0 or result.stdout.len == 0) {
        allocator.free(result.stdout);
        return error.HttpError;
    }

    return result.stdout;
}

pub fn validateUrl(url: []const u8) ValidationError!void {
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return error.InvalidScheme;
    }

    const raw_host = extractHost(url) orelse return error.InvalidUrl;
    var normalized_host_buf: [256]u8 = undefined;
    const host = normalizeHost(raw_host, &normalized_host_buf) orelse return error.InvalidUrl;

    if (isLocalhostAlias(host) or std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "::1")) {
        return error.LocalhostBlocked;
    }
    if (isPrivateIpv4(host) or isPrivateIpv6(host)) {
        return error.PrivateIp;
    }
}

fn isRedirectStatus(status_code: u16) bool {
    return status_code >= 300 and status_code < 400;
}

fn extractHost(url: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    const host = uri.host orelse return null;
    return switch (host) {
        .raw => |raw| stripIpv6Brackets(raw),
        .percent_encoded => |encoded| stripIpv6Brackets(encoded),
    };
}

fn stripIpv6Brackets(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        return host[1 .. host.len - 1];
    }
    return host;
}

fn normalizeHost(host: []const u8, buf: []u8) ?[]const u8 {
    var trimmed = host;
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '.') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    if (trimmed.len == 0 or trimmed.len > buf.len) return null;
    for (trimmed, 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return buf[0..trimmed.len];
}

fn isLocalhostAlias(host: []const u8) bool {
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "localhost.localdomain") or
        std.mem.endsWith(u8, host, ".localhost") or
        std.mem.endsWith(u8, host, ".localhost.localdomain");
}

fn isPrivateIpv4(host: []const u8) bool {
    var it = std.mem.splitScalar(u8, host, '.');
    const first_str = it.next() orelse return false;
    const first = std.fmt.parseInt(u8, first_str, 10) catch return false;
    if (first == 10 or first == 127) return true;

    const second_str = it.next() orelse return false;
    const second = std.fmt.parseInt(u8, second_str, 10) catch return false;
    if (first == 172 and second >= 16 and second <= 31) return true;
    if (first == 192 and second == 168) return true;
    return false;
}

fn isPrivateIpv6(host: []const u8) bool {
    var buf: [64]u8 = undefined;
    if (host.len > buf.len) return false;
    const lower = std.ascii.lowerString(buf[0..host.len], host);

    if (std.mem.eql(u8, lower, "::1")) return true;
    if (std.mem.startsWith(u8, lower, "fe8") or
        std.mem.startsWith(u8, lower, "fe9") or
        std.mem.startsWith(u8, lower, "fea") or
        std.mem.startsWith(u8, lower, "feb")) return true;
    if (std.mem.startsWith(u8, lower, "fc") or std.mem.startsWith(u8, lower, "fd")) return true;

    const mapped_prefix = "::ffff:";
    if (std.mem.startsWith(u8, lower, mapped_prefix)) {
        return isPrivateIpv4(lower[mapped_prefix.len..]);
    }
    return false;
}

fn resolveValidatedRedirectUrl(base_url: []const u8, location: []const u8, aux_buf: []u8, out_buf: []u8) ![]const u8 {
    const base_uri = try std.Uri.parse(base_url);
    if (location.len > aux_buf.len) return error.RedirectLocationOversize;

    @memcpy(aux_buf[0..location.len], location);
    var remaining_aux = aux_buf;
    const resolved_uri = base_uri.resolveInPlace(location.len, &remaining_aux) catch {
        return error.RedirectLocationInvalid;
    };

    const resolved_url = std.fmt.bufPrint(out_buf, "{f}", .{resolved_uri}) catch return error.RedirectLocationOversize;
    try validateUrl(resolved_url);
    return resolved_url;
}

test "validateUrl accepts public http urls" {
    try validateUrl("https://example.com");
    try validateUrl("http://news.ycombinator.com");
}

test "validateUrl rejects localhost and private ranges" {
    try std.testing.expectError(error.LocalhostBlocked, validateUrl("http://localhost"));
    try std.testing.expectError(error.PrivateIp, validateUrl("http://10.0.0.1"));
    try std.testing.expectError(error.PrivateIp, validateUrl("http://192.168.1.7"));
}
