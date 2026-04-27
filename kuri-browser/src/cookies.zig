const std = @import("std");

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8,
    secure: bool,
    host_only: bool,
};

pub const CookieJar = struct {
    allocator: std.mem.Allocator,
    cookies: std.ArrayList(Cookie) = .empty,

    pub fn init(allocator: std.mem.Allocator) CookieJar {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CookieJar) void {
        for (self.cookies.items) |cookie| {
            self.allocator.free(cookie.name);
            self.allocator.free(cookie.value);
            self.allocator.free(cookie.domain);
            self.allocator.free(cookie.path);
        }
        self.cookies.deinit(self.allocator);
    }

    pub fn count(self: *const CookieJar) usize {
        return self.cookies.items.len;
    }

    pub fn absorbSetCookie(self: *CookieJar, request_url: []const u8, header_value: []const u8) !void {
        var host_buf: [256]u8 = undefined;
        const request_host = try extractNormalizedHost(request_url, &host_buf);
        const request_path = extractRequestPath(request_url) catch "/";

        var parts = std.mem.splitScalar(u8, header_value, ';');
        const first = parts.next() orelse return;
        const eq_index = std.mem.indexOfScalar(u8, first, '=') orelse return;

        const name = std.mem.trim(u8, first[0..eq_index], " \t");
        const value = std.mem.trim(u8, first[eq_index + 1 ..], " \t");
        if (name.len == 0) return;

        var cookie_domain = request_host;
        var cookie_path = defaultCookiePath(request_path);
        var secure = false;
        var host_only = true;
        var should_delete = false;

        var attr_buf: [256]u8 = undefined;
        while (parts.next()) |raw_attr| {
            const attr = std.mem.trim(u8, raw_attr, " \t");
            if (attr.len == 0) continue;

            if (std.mem.indexOfScalar(u8, attr, '=')) |attr_eq| {
                const attr_name = std.mem.trim(u8, attr[0..attr_eq], " \t");
                const attr_value = std.mem.trim(u8, attr[attr_eq + 1 ..], " \t");

                if (std.ascii.eqlIgnoreCase(attr_name, "domain")) {
                    const normalized = normalizeHost(stripLeadingDot(attr_value), &attr_buf) orelse continue;
                    if (!domainMatches(request_host, normalized)) continue;
                    cookie_domain = normalized;
                    host_only = false;
                    continue;
                }

                if (std.ascii.eqlIgnoreCase(attr_name, "path")) {
                    if (attr_value.len > 0 and attr_value[0] == '/') {
                        cookie_path = attr_value;
                    }
                    continue;
                }

                if (std.ascii.eqlIgnoreCase(attr_name, "max-age")) {
                    const seconds = std.fmt.parseInt(i64, attr_value, 10) catch continue;
                    if (seconds <= 0) should_delete = true;
                    continue;
                }

                continue;
            }

            if (std.ascii.eqlIgnoreCase(attr, "secure")) {
                secure = true;
            }
        }

        self.removeMatching(cookie_domain, cookie_path, name);
        if (should_delete) return;

        try self.cookies.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .value = try self.allocator.dupe(u8, value),
            .domain = try self.allocator.dupe(u8, cookie_domain),
            .path = try self.allocator.dupe(u8, cookie_path),
            .secure = secure,
            .host_only = host_only,
        });
    }

    pub fn cookieHeader(self: *const CookieJar, allocator: std.mem.Allocator, request_url: []const u8) !?[]const u8 {
        var host_buf: [256]u8 = undefined;
        const request_host = try extractNormalizedHost(request_url, &host_buf);
        const request_path = extractRequestPath(request_url) catch "/";
        const is_https = std.mem.startsWith(u8, request_url, "https://");

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var matched = false;
        for (self.cookies.items) |cookie| {
            if (!cookieMatches(cookie, request_host, request_path, is_https)) continue;
            if (matched) try out.appendSlice(allocator, "; ");
            try out.appendSlice(allocator, cookie.name);
            try out.append(allocator, '=');
            try out.appendSlice(allocator, cookie.value);
            matched = true;
        }

        if (!matched) {
            out.deinit(allocator);
            return null;
        }

        return try out.toOwnedSlice(allocator);
    }

    fn removeMatching(self: *CookieJar, domain: []const u8, path: []const u8, name: []const u8) void {
        var i: usize = 0;
        while (i < self.cookies.items.len) {
            const cookie = self.cookies.items[i];
            if (std.mem.eql(u8, cookie.domain, domain) and
                std.mem.eql(u8, cookie.path, path) and
                std.mem.eql(u8, cookie.name, name))
            {
                self.allocator.free(cookie.name);
                self.allocator.free(cookie.value);
                self.allocator.free(cookie.domain);
                self.allocator.free(cookie.path);
                _ = self.cookies.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }
};

fn cookieMatches(cookie: Cookie, request_host: []const u8, request_path: []const u8, is_https: bool) bool {
    if (cookie.secure and !is_https) return false;

    if (cookie.host_only) {
        if (!std.mem.eql(u8, cookie.domain, request_host)) return false;
    } else if (!domainMatches(request_host, cookie.domain)) {
        return false;
    }

    return pathMatches(request_path, cookie.path);
}

fn domainMatches(host: []const u8, domain: []const u8) bool {
    if (std.mem.eql(u8, host, domain)) return true;
    if (host.len <= domain.len) return false;
    if (!std.mem.endsWith(u8, host, domain)) return false;
    return host[host.len - domain.len - 1] == '.';
}

fn pathMatches(request_path: []const u8, cookie_path: []const u8) bool {
    if (!std.mem.startsWith(u8, request_path, cookie_path)) return false;
    if (request_path.len == cookie_path.len) return true;
    if (cookie_path.len == 0 or cookie_path[cookie_path.len - 1] == '/') return true;
    return request_path[cookie_path.len] == '/';
}

fn defaultCookiePath(request_path: []const u8) []const u8 {
    if (request_path.len == 0 or request_path[0] != '/') return "/";
    if (request_path.len == 1) return "/";

    const last_slash = std.mem.lastIndexOfScalar(u8, request_path, '/') orelse return "/";
    if (last_slash == 0) return "/";
    return request_path[0..last_slash];
}

fn extractNormalizedHost(url: []const u8, buf: []u8) ![]const u8 {
    const uri = try std.Uri.parse(url);
    const host = uri.host orelse return error.InvalidUrl;
    const raw_host = switch (host) {
        .raw => |raw| stripIpv6Brackets(raw),
        .percent_encoded => |encoded| stripIpv6Brackets(encoded),
    };
    return normalizeHost(raw_host, buf) orelse error.InvalidUrl;
}

fn extractRequestPath(url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(url);
    const raw_path = switch (uri.path) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| encoded,
    };
    if (raw_path.len == 0) return "/";
    return raw_path;
}

fn stripIpv6Brackets(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        return host[1 .. host.len - 1];
    }
    return host;
}

fn stripLeadingDot(value: []const u8) []const u8 {
    if (value.len > 0 and value[0] == '.') return value[1..];
    return value;
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

test "cookie jar sends secure cookies only over https" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();

    try jar.absorbSetCookie("https://example.com/login", "session=abc123; Path=/; Secure");

    const https_header = (try jar.cookieHeader(std.testing.allocator, "https://example.com/dashboard")).?;
    defer std.testing.allocator.free(https_header);
    try std.testing.expectEqualStrings("session=abc123", https_header);

    try std.testing.expectEqual(@as(?[]const u8, null), try jar.cookieHeader(std.testing.allocator, "http://example.com/dashboard"));
}

test "cookie jar respects host-only and domain cookies" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();

    try jar.absorbSetCookie("https://sub.example.com/", "host_only=yes; Path=/");
    try jar.absorbSetCookie("https://sub.example.com/", "shared=ok; Domain=example.com; Path=/");

    const same_host = (try jar.cookieHeader(std.testing.allocator, "https://sub.example.com/account")).?;
    defer std.testing.allocator.free(same_host);
    try std.testing.expectEqualStrings("host_only=yes; shared=ok", same_host);

    const sibling_host = (try jar.cookieHeader(std.testing.allocator, "https://www.example.com/account")).?;
    defer std.testing.allocator.free(sibling_host);
    try std.testing.expectEqualStrings("shared=ok", sibling_host);
}

test "cookie jar deletes cookies when max-age is zero" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();

    try jar.absorbSetCookie("https://example.com/login", "session=abc123; Path=/");
    try std.testing.expectEqual(@as(usize, 1), jar.count());

    try jar.absorbSetCookie("https://example.com/login", "session=gone; Path=/; Max-Age=0");
    try std.testing.expectEqual(@as(usize, 0), jar.count());
}
