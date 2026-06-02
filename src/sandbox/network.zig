// network.zig — outbound HTTP for the bundle replay sandbox.
//
// Phase 1 implementation: subprocess to `curl_chrome131` (curl-impersonate-chrome).
// Trade-off: ~5ms per-call overhead vs ~0ms for libcurl FFI, but zero linker
// complexity. The Client interface is stable, so a future libcurl-impersonate
// FFI backend can drop in without changing runtime.zig.
//
// Curl-impersonate ships per-Chrome-version binaries on PATH after
//   brew install lwthiker/taps/curl-impersonate
// On Linux: `apt install curl-impersonate` or vendor the static binary.
//
// The binary name is derived from `impersonate_profile` in Client.Options.

const std = @import("std");
const compat = @import("../compat.zig");
const curl_lib = @import("curl_lib.zig");

pub const Header = struct {
    name: []const u8,
    value: []const u8,

    pub fn dupe(self: Header, allocator: std.mem.Allocator) !Header {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .value = try allocator.dupe(u8, self.value),
        };
    }
};

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8 = "",
    path: []const u8 = "/",
    expires: i64 = 0, // 0 = session
    secure: bool = false,
    http_only: bool = false,
    same_site: []const u8 = "",
};

pub const CookieJar = struct {
    allocator: std.mem.Allocator,
    cookies: std.ArrayList(Cookie),
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) CookieJar {
        return .{
            .allocator = allocator,
            .cookies = .empty,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *CookieJar) void {
        self.cookies.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Parse a Set-Cookie header value and merge into the jar. The format is:
    ///   name=value; Path=/; Domain=.x.com; Expires=...; Secure; HttpOnly; SameSite=Lax
    pub fn applySetCookie(self: *CookieJar, default_host: []const u8, header_value: []const u8) !void {
        const a = self.arena.allocator();

        var iter = std.mem.splitScalar(u8, header_value, ';');
        const first = std.mem.trim(u8, iter.first(), " \t");
        const eq = std.mem.indexOfScalar(u8, first, '=') orelse return;
        const name = std.mem.trim(u8, first[0..eq], " \t");
        const value = std.mem.trim(u8, first[eq + 1 ..], " \t");
        if (name.len == 0) return;

        var cookie = Cookie{
            .name = try a.dupe(u8, name),
            .value = try a.dupe(u8, value),
            .domain = try a.dupe(u8, default_host),
            .path = "/",
        };

        while (iter.next()) |raw_attr| {
            const attr = std.mem.trim(u8, raw_attr, " \t");
            if (attr.len == 0) continue;
            const ae = std.mem.indexOfScalar(u8, attr, '=');
            if (ae) |aep| {
                const k = std.mem.trim(u8, attr[0..aep], " \t");
                const v = std.mem.trim(u8, attr[aep + 1 ..], " \t");
                if (std.ascii.eqlIgnoreCase(k, "domain")) {
                    cookie.domain = try a.dupe(u8, std.mem.trimStart(u8, v, "."));
                } else if (std.ascii.eqlIgnoreCase(k, "path")) {
                    cookie.path = try a.dupe(u8, v);
                } else if (std.ascii.eqlIgnoreCase(k, "max-age")) {
                    const ma = std.fmt.parseInt(i64, v, 10) catch 0;
                    if (ma > 0) cookie.expires = compat.timestampSeconds() + ma;
                } else if (std.ascii.eqlIgnoreCase(k, "samesite")) {
                    cookie.same_site = try a.dupe(u8, v);
                }
                // Expires (HTTP-date) intentionally ignored — Max-Age takes precedence
                // and most session cookies use Max-Age in modern stacks.
            } else {
                if (std.ascii.eqlIgnoreCase(attr, "secure")) cookie.secure = true;
                if (std.ascii.eqlIgnoreCase(attr, "httponly")) cookie.http_only = true;
            }
        }

        // Replace existing cookie with same name+domain+path, else append.
        var i: usize = 0;
        while (i < self.cookies.items.len) : (i += 1) {
            const c = self.cookies.items[i];
            if (std.mem.eql(u8, c.name, cookie.name) and
                std.mem.eql(u8, c.domain, cookie.domain) and
                std.mem.eql(u8, c.path, cookie.path))
            {
                self.cookies.items[i] = cookie;
                return;
            }
        }
        try self.cookies.append(self.allocator, cookie);
    }

    /// Write `name1=value1; name2=value2` for cookies matching the given host.
    pub fn formatHeaderValue(
        self: *CookieJar,
        scratch: std.mem.Allocator,
        host: []const u8,
        out: *std.ArrayList(u8),
    ) !void {
        _ = scratch;
        const now = compat.timestampSeconds();
        var first_written = true;
        for (self.cookies.items) |c| {
            if (c.expires > 0 and c.expires < now) continue;
            if (!hostMatchesDomain(host, c.domain)) continue;
            if (!first_written) try out.appendSlice(self.allocator, "; ");
            try out.appendSlice(self.allocator, c.name);
            try out.append(self.allocator, '=');
            try out.appendSlice(self.allocator, c.value);
            first_written = false;
        }
    }

    pub fn snapshot(self: *CookieJar, allocator: std.mem.Allocator) ![]Cookie {
        const out = try allocator.alloc(Cookie, self.cookies.items.len);
        for (self.cookies.items, 0..) |c, i| {
            out[i] = .{
                .name = try allocator.dupe(u8, c.name),
                .value = try allocator.dupe(u8, c.value),
                .domain = try allocator.dupe(u8, c.domain),
                .path = try allocator.dupe(u8, c.path),
                .expires = c.expires,
                .secure = c.secure,
                .http_only = c.http_only,
                .same_site = try allocator.dupe(u8, c.same_site),
            };
        }
        return out;
    }
};

fn hostMatchesDomain(host: []const u8, domain: []const u8) bool {
    if (domain.len == 0) return true;
    if (std.mem.eql(u8, host, domain)) return true;
    if (host.len > domain.len + 1 and host[host.len - domain.len - 1] == '.' and
        std.mem.endsWith(u8, host, domain)) return true;
    return false;
}

pub const Client = struct {
    pub const Options = struct {
        impersonate_profile: []const u8 = "chrome131",
        target_origin: []const u8 = "",
        max_response_bytes: usize = 16 * 1024 * 1024,
        connect_timeout_s: u32 = 10,
        max_total_s: u32 = 30,
    };

    allocator: std.mem.Allocator,
    options: Options,

    pub fn init(allocator: std.mem.Allocator, options: Options) Client {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn deinit(self: *Client) void {
        _ = self;
    }

    pub const SendArgs = struct {
        method: []const u8,
        url: []const u8,
        headers_json: []const u8 = "",
        body: ?[]const u8 = null,
        cookie_jar: *CookieJar,
    };

    pub fn send(self: *Client, args: SendArgs) !Response {
        return runCurlImpersonate(self, args);
    }

    /// Resolve the curl binary to invoke.
    ///   1. $UNBROWSE_CURL_IMPERSONATE — explicit override (full path or name)
    ///   2. curl_<profile>           — curl-impersonate naming convention
    fn binaryName(self: *Client, buf: []u8) ![]const u8 {
        if (compat.getenv("UNBROWSE_CURL_IMPERSONATE")) |v| {
            return std.fmt.bufPrint(buf, "{s}", .{v});
        }
        return std.fmt.bufPrint(buf, "curl_{s}", .{self.options.impersonate_profile});
    }
};

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: u16,
    status_text: []const u8,
    final_url: []const u8,
    headers: []Header,
    body: []const u8,
    redirected: bool,

    pub fn deinit(self: *Response) void {
        const a = self.allocator;
        for (self.headers) |h| {
            a.free(h.name);
            a.free(h.value);
        }
        a.free(self.headers);
        a.free(self.status_text);
        a.free(self.final_url);
        a.free(self.body);
    }
};

fn runCurlImpersonate(client: *Client, args: Client.SendArgs) !Response {
    const a = client.allocator;

    // 1. Parse the JSON-shaped header object the runtime hands us into
    //    a curl_lib.Header slice. headers_json may be empty.
    const url_parsed = try parseUrl(args.url);
    var hdr_storage: std.ArrayList(curl_lib.Header) = .empty;
    defer hdr_storage.deinit(a);
    var hdr_strings: std.ArrayList([]u8) = .empty;
    defer {
        for (hdr_strings.items) |s| a.free(s);
        hdr_strings.deinit(a);
    }
    if (args.headers_json.len > 0) {
        try parseHeadersJsonInto(a, args.headers_json, &hdr_storage, &hdr_strings);
    }

    // 2. Cookie header from jar (libcurl-impersonate doesn't auto-scope; we do).
    var cookie_buf: std.ArrayList(u8) = .empty;
    defer cookie_buf.deinit(a);
    try args.cookie_jar.formatHeaderValue(a, url_parsed.host, &cookie_buf);

    // 3. Run via the static-linked libcurl-impersonate.
    var resp = curl_lib.perform(a, .{
        .method = args.method,
        .url = args.url,
        .headers = hdr_storage.items,
        .body = args.body,
        .cookie_header = cookie_buf.items,
        .impersonate = client.options.impersonate_profile,
        .connect_timeout_ms = client.options.connect_timeout_s * 1000,
        .total_timeout_ms = client.options.max_total_s * 1000,
        .follow_redirects = true,
        .max_redirects = 10,
    }) catch |e| {
        std.log.warn("[sandbox-net] curl_lib.perform failed: {s}", .{@errorName(e)});
        return error.CurlFailed;
    };
    defer resp.deinit();

    // 4. Parse Set-Cookie headers from the raw response header buffer and
    //    feed them back into the jar so they're available on subsequent
    //    requests (and reflected in the final replay response).
    try applySetCookiesFromHeaders(args.cookie_jar, url_parsed.host, resp.raw_headers);

    // 5. Build the network.Response (allocator-owned, mirrors prior shape).
    var headers_list: std.ArrayList(Header) = .empty;
    errdefer {
        for (headers_list.items) |h| {
            a.free(h.name);
            a.free(h.value);
        }
        headers_list.deinit(a);
    }
    var status_text_owned: []u8 = try a.dupe(u8, "");
    errdefer a.free(status_text_owned);

    var line_iter = std.mem.splitSequence(u8, resp.raw_headers, "\r\n");
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "HTTP/")) {
            // Status text after "HTTP/x.x NNN <text>".
            const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const after = line[sp1 + 1 ..];
            if (std.mem.indexOfScalar(u8, after, ' ')) |sp2| {
                a.free(status_text_owned);
                status_text_owned = try a.dupe(u8, after[sp2 + 1 ..]);
            }
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (name.len == 0) continue;
        try headers_list.append(a, .{
            .name = try a.dupe(u8, name),
            .value = try a.dupe(u8, value),
        });
    }

    return .{
        .allocator = a,
        .status = resp.status,
        .status_text = status_text_owned,
        .final_url = try a.dupe(u8, resp.final_url),
        .headers = try headers_list.toOwnedSlice(a),
        .body = try a.dupe(u8, resp.body),
        .redirected = resp.redirect_count > 0,
    };
}

fn applySetCookiesFromHeaders(jar: *CookieJar, default_host: []const u8, raw: []const u8) !void {
    var iter = std.mem.splitSequence(u8, raw, "\r\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "set-cookie")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        jar.applySetCookie(default_host, value) catch {};
    }
}

fn parseHeadersJsonInto(
    allocator: std.mem.Allocator,
    json_str: []const u8,
    out: *std.ArrayList(curl_lib.Header),
    string_storage: *std.ArrayList([]u8),
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        const v_node = entry.value_ptr.*;
        const v: []const u8 = switch (v_node) {
            .string => |s| s,
            else => continue,
        };
        const name_dup = try allocator.dupe(u8, k);
        try string_storage.append(allocator, name_dup);
        const value_dup = try allocator.dupe(u8, v);
        try string_storage.append(allocator, value_dup);
        try out.append(allocator, .{ .name = name_dup, .value = value_dup });
    }
}

const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    is_https: bool,
};

fn parseUrl(url: []const u8) !ParsedUrl {
    var rest = url;
    var is_https = false;
    if (std.mem.startsWith(u8, rest, "https://")) {
        rest = rest[8..]; is_https = true;
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest[7..];
    } else return error.BadScheme;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const colon = std.mem.indexOfScalar(u8, authority, ':');
    if (colon) |c| {
        const port = std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch (if (is_https) @as(u16, 443) else 80);
        return .{ .host = authority[0..c], .port = port, .is_https = is_https };
    }
    return .{ .host = authority, .port = if (is_https) 443 else 80, .is_https = is_https };
}


test "cookie jar set/get roundtrip" {
    const a = std.testing.allocator;
    var jar = CookieJar.init(a);
    defer jar.deinit();

    try jar.applySetCookie("example.com", "session=abc123; Path=/; Domain=.example.com; Secure; HttpOnly; SameSite=Lax");
    try jar.applySetCookie("example.com", "csrf=tok9; Path=/");

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    try jar.formatHeaderValue(a, "www.example.com", &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "session=abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "csrf=tok9") != null);
}

test "host matches domain" {
    try std.testing.expect(hostMatchesDomain("example.com", "example.com"));
    try std.testing.expect(hostMatchesDomain("www.example.com", "example.com"));
    try std.testing.expect(!hostMatchesDomain("example.com", "other.com"));
    try std.testing.expect(!hostMatchesDomain("evilexample.com", "example.com"));
}
