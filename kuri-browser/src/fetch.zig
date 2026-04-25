const std = @import("std");
const cookies = @import("cookies.zig");
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
    TempDirCreateFailed,
};

pub const FetchResult = struct {
    requested_url: []const u8,
    url: []const u8,
    body: []const u8,
    status_code: u16,
    content_type: []const u8,
    redirect_chain: []const []const u8,
    cookie_count: usize,
};

const max_redirects = 10;
const max_body_bytes = 8 * 1024 * 1024;
const max_header_bytes = 256 * 1024;
const max_cookie_bytes = 64 * 1024;
const redirect_buf_len = 8192;

pub fn fetchHtml(allocator: std.mem.Allocator, url: []const u8, user_agent: []const u8) !FetchResult {
    try validateUrl(url);

    return fetchHtmlStd(allocator, url, user_agent) catch |err| switch (err) {
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => try fetchHtmlCurl(allocator, url, user_agent),
        else => return err,
    };
}

fn fetchHtmlStd(allocator: std.mem.Allocator, url: []const u8, user_agent: []const u8) !FetchResult {
    try validateUrl(url);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
    };
    defer client.deinit();

    var jar = cookies.CookieJar.init(allocator);
    defer jar.deinit();

    var redirect_chain: std.ArrayList([]const u8) = .empty;
    defer redirect_chain.deinit(allocator);

    var current_url = url;
    var current_url_buf_a: [redirect_buf_len]u8 = undefined;
    var current_url_buf_b: [redirect_buf_len]u8 = undefined;
    var resolve_buf: [redirect_buf_len]u8 = undefined;
    var use_buf_a = true;
    var redirects_seen: usize = 0;

    while (true) {
        const uri = try std.Uri.parse(current_url);
        const cookie_header = try jar.cookieHeader(allocator, current_url);
        defer if (cookie_header) |header| allocator.free(header);

        var base_headers = [_]std.http.Header{
            .{ .name = "User-Agent", .value = user_agent },
            .{ .name = "Accept", .value = "text/html,application/xhtml+xml,*/*" },
            .{ .name = "Accept-Encoding", .value = "gzip, deflate" },
        };
        var cookie_headers = [_]std.http.Header{
            .{ .name = "User-Agent", .value = user_agent },
            .{ .name = "Accept", .value = "text/html,application/xhtml+xml,*/*" },
            .{ .name = "Accept-Encoding", .value = "gzip, deflate" },
            .{ .name = "Cookie", .value = "" },
        };
        const extra_headers = if (cookie_header) |header| blk: {
            cookie_headers[3].value = header;
            break :blk cookie_headers[0..];
        } else base_headers[0..];

        var req = try client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = extra_headers,
        });
        defer req.deinit();

        try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        const status_code: u16 = @intFromEnum(response.head.status);

        try appendSetCookieHeaders(&jar, current_url, response.head);

        if (isRedirectStatus(status_code)) {
            if (redirects_seen >= max_redirects) return error.TooManyRedirects;

            const location = response.head.location orelse return error.RedirectLocationMissing;
            const next_url_buf = if (use_buf_a) current_url_buf_a[0..] else current_url_buf_b[0..];
            const next_url = try resolveValidatedRedirectUrl(current_url, location, resolve_buf[0..], next_url_buf);
            try redirect_chain.append(allocator, try allocator.dupe(u8, next_url));

            current_url = next_url;
            use_buf_a = !use_buf_a;
            redirects_seen += 1;
            continue;
        }

        if (status_code < 200 or status_code >= 300) {
            return error.HttpError;
        }

        const content_type = try allocator.dupe(u8, response.head.content_type orelse "text/html");
        errdefer allocator.free(content_type);

        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(allocator);

        var transfer_buf: [8192]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
        const reader = response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);
        try reader.appendRemainingUnlimited(allocator, &body);
        if (body.items.len > max_body_bytes) return error.ResponseTooLarge;

        return .{
            .requested_url = try allocator.dupe(u8, url),
            .url = try allocator.dupe(u8, current_url),
            .body = body.items,
            .status_code = status_code,
            .content_type = content_type,
            .redirect_chain = try redirect_chain.toOwnedSlice(allocator),
            .cookie_count = jar.count(),
        };
    }
}

fn fetchHtmlCurl(allocator: std.mem.Allocator, url: []const u8, user_agent: []const u8) !FetchResult {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const temp_dir_path = try createTempDir(allocator);
    defer allocator.free(temp_dir_path);
    defer cwd.deleteTree(io, temp_dir_path) catch {};

    const headers_path = try std.fmt.allocPrint(allocator, "{s}/headers.txt", .{temp_dir_path});
    defer allocator.free(headers_path);
    const body_path = try std.fmt.allocPrint(allocator, "{s}/body.bin", .{temp_dir_path});
    defer allocator.free(body_path);
    const cookie_path = try std.fmt.allocPrint(allocator, "{s}/cookies.txt", .{temp_dir_path});
    defer allocator.free(cookie_path);

    const result = try process.runCommand(allocator, &.{
        "curl",
        "-fsSL",
        "--compressed",
        "-A",
        user_agent,
        "-D",
        headers_path,
        "-o",
        body_path,
        "-c",
        cookie_path,
        "-b",
        cookie_path,
        url,
    }, 64 * 1024);
    defer allocator.free(result.stdout);

    if (result.term != 0) return error.HttpError;

    const header_bytes = cwd.readFileAlloc(io, headers_path, allocator, .limited(max_header_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return error.ResponseTooLarge,
        else => return err,
    };
    defer allocator.free(header_bytes);

    const body = cwd.readFileAlloc(io, body_path, allocator, .limited(max_body_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return error.ResponseTooLarge,
        else => return err,
    };

    var redirect_chain: std.ArrayList([]const u8) = .empty;
    defer redirect_chain.deinit(allocator);

    const meta = try parseCurlHeaderDump(allocator, url, header_bytes, &redirect_chain);
    errdefer allocator.free(meta.url);
    errdefer allocator.free(meta.content_type);

    return .{
        .requested_url = try allocator.dupe(u8, url),
        .url = meta.url,
        .body = body,
        .status_code = meta.status_code,
        .content_type = meta.content_type,
        .redirect_chain = try redirect_chain.toOwnedSlice(allocator),
        .cookie_count = try countCurlCookies(allocator, cookie_path),
    };
}

fn appendSetCookieHeaders(jar: *cookies.CookieJar, request_url: []const u8, head: std.http.Client.Response.Head) !void {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "set-cookie")) {
            try jar.absorbSetCookie(request_url, header.value);
        }
    }
}

const CurlMeta = struct {
    url: []const u8,
    status_code: u16,
    content_type: []const u8,
};

const HeaderBlock = struct {
    status_code: ?u16 = null,
    location: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
};

fn parseCurlHeaderDump(
    allocator: std.mem.Allocator,
    start_url: []const u8,
    header_bytes: []const u8,
    redirect_chain: *std.ArrayList([]const u8),
) !CurlMeta {
    var current_url = start_url;
    var last_status: u16 = 0;
    var last_content_type: []const u8 = "text/html";
    var block: HeaderBlock = .{};

    var lines = std.mem.splitScalar(u8, header_bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) {
            try finalizeHeaderBlock(allocator, &current_url, &last_status, &last_content_type, block, redirect_chain);
            block = .{};
            continue;
        }

        if (std.mem.startsWith(u8, line, "HTTP/")) {
            block.status_code = parseStatusCode(line);
            continue;
        }

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "location")) {
            block.location = value;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "content-type")) {
            block.content_type = value;
            continue;
        }
    }

    try finalizeHeaderBlock(allocator, &current_url, &last_status, &last_content_type, block, redirect_chain);
    if (last_status == 0) return error.HttpError;

    return .{
        .url = try allocator.dupe(u8, current_url),
        .status_code = last_status,
        .content_type = try allocator.dupe(u8, last_content_type),
    };
}

fn finalizeHeaderBlock(
    allocator: std.mem.Allocator,
    current_url: *[]const u8,
    last_status: *u16,
    last_content_type: *[]const u8,
    block: HeaderBlock,
    redirect_chain: *std.ArrayList([]const u8),
) !void {
    const status_code = block.status_code orelse return;
    last_status.* = status_code;
    if (block.content_type) |value| last_content_type.* = value;

    if (isRedirectStatus(status_code)) {
        const location = block.location orelse return error.RedirectLocationMissing;
        var aux_buf: [redirect_buf_len]u8 = undefined;
        var out_buf: [redirect_buf_len]u8 = undefined;
        const next_url = try resolveValidatedRedirectUrl(current_url.*, location, aux_buf[0..], out_buf[0..]);
        const owned_next = try allocator.dupe(u8, next_url);
        try redirect_chain.append(allocator, owned_next);
        current_url.* = owned_next;
    }
}

fn parseStatusCode(line: []const u8) ?u16 {
    var it = std.mem.splitScalar(u8, line, ' ');
    _ = it.next();
    const status_str = it.next() orelse return null;
    return std.fmt.parseInt(u16, status_str, 10) catch null;
}

fn countCurlCookies(allocator: std.mem.Allocator, cookie_path: []const u8) !usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const cookie_bytes = cwd.readFileAlloc(io, cookie_path, allocator, .limited(max_cookie_bytes)) catch |err| switch (err) {
        error.FileNotFound => return 0,
        error.StreamTooLong => return 0,
        else => return err,
    };
    defer allocator.free(cookie_bytes);

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, cookie_bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        count += 1;
    }
    return count;
}

fn createTempDir(allocator: std.mem.Allocator) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    var attempts: usize = 0;
    while (attempts < 8) : (attempts += 1) {
        const pid: u32 = @intCast(std.c.getpid());
        const candidate = try std.fmt.allocPrint(allocator, ".kuri-browser-fetch-{d}-{d}", .{ pid, attempts });
        errdefer allocator.free(candidate);

        cwd.createDir(io, candidate, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(candidate);
                continue;
            },
            else => return err,
        };

        return candidate;
    }

    return error.TempDirCreateFailed;
}

fn freeOwnedStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
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

test "parseCurlHeaderDump tracks redirect chain and final content type" {
    var redirect_chain: std.ArrayList([]const u8) = .empty;
    defer {
        freeOwnedStrings(std.testing.allocator, redirect_chain.items);
        redirect_chain.deinit(std.testing.allocator);
    }

    const headers =
        "HTTP/1.1 302 Found\r\n" ++
        "Location: /final\r\n" ++
        "\r\n" ++
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/html; charset=utf-8\r\n" ++
        "\r\n";

    const meta = try parseCurlHeaderDump(std.testing.allocator, "https://example.com/start", headers, &redirect_chain);
    defer std.testing.allocator.free(meta.url);
    defer std.testing.allocator.free(meta.content_type);

    try std.testing.expectEqual(@as(usize, 1), redirect_chain.items.len);
    try std.testing.expectEqualStrings("https://example.com/final", redirect_chain.items[0]);
    try std.testing.expectEqualStrings("https://example.com/final", meta.url);
    try std.testing.expectEqual(@as(u16, 200), meta.status_code);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", meta.content_type);
}
