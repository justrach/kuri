const std = @import("std");

pub const ValidationError = error{
    InvalidScheme,
    PrivateIp,
    LocalhostBlocked,
    InvalidUrl,
    MetadataIpBlocked,
};

pub fn validateUrl(url: []const u8) ValidationError!void {
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return ValidationError.InvalidScheme;
    }

    const host = extractHost(url) orelse return ValidationError.InvalidUrl;

    if (std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "::1")) {
        return ValidationError.LocalhostBlocked;
    }

    if (std.mem.eql(u8, host, "169.254.169.254") or std.mem.eql(u8, host, "100.100.100.200")) {
        return ValidationError.MetadataIpBlocked;
    }

    if (isPrivateIpv4(host)) {
        return ValidationError.PrivateIp;
    }
}

fn extractHost(url: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const after_scheme = url[scheme_end + 3 ..];

    const after_auth = if (std.mem.indexOfScalar(u8, after_scheme, '@')) |idx| after_scheme[idx + 1 ..] else after_scheme;

    // Handle IPv6 [::1] notation
    if (after_auth.len > 0 and after_auth[0] == '[') {
        if (std.mem.indexOfScalar(u8, after_auth, ']')) |bracket_end| {
            return after_auth[1..bracket_end];
        }
        return null;
    }

    var end = after_auth.len;
    if (std.mem.indexOfScalar(u8, after_auth, ':')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, after_auth, '/')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, after_auth, '?')) |idx| end = @min(end, idx);

    if (end == 0) return null;
    return after_auth[0..end];
}

fn isPrivateIpv4(host: []const u8) bool {
    var it = std.mem.splitScalar(u8, host, '.');
    const first_str = it.next() orelse return false;
    const first = std.fmt.parseInt(u8, first_str, 10) catch return false;

    if (first == 10) return true;
    if (first == 127) return true;

    const second_str = it.next() orelse return false;
    const second = std.fmt.parseInt(u8, second_str, 10) catch return false;

    if (first == 172 and second >= 16 and second <= 31) return true;
    if (first == 192 and second == 168) return true;

    return false;
}

test "validateUrl accepts valid URLs" {
    try validateUrl("https://example.com");
    try validateUrl("http://example.com/path?q=1");
    try validateUrl("https://sub.domain.com:8080/path");
}

test "validateUrl rejects invalid schemes" {
    try std.testing.expectError(ValidationError.InvalidScheme, validateUrl("ftp://example.com"));
    try std.testing.expectError(ValidationError.InvalidScheme, validateUrl("javascript:alert(1)"));
    try std.testing.expectError(ValidationError.InvalidScheme, validateUrl("file:///etc/passwd"));
}

test "validateUrl blocks localhost" {
    try std.testing.expectError(ValidationError.LocalhostBlocked, validateUrl("http://localhost"));
    try std.testing.expectError(ValidationError.LocalhostBlocked, validateUrl("http://127.0.0.1"));
    try std.testing.expectError(ValidationError.LocalhostBlocked, validateUrl("http://[::1]"));
}

test "validateUrl blocks private IPs" {
    try std.testing.expectError(ValidationError.PrivateIp, validateUrl("http://10.0.0.1"));
    try std.testing.expectError(ValidationError.PrivateIp, validateUrl("http://172.16.0.1"));
    try std.testing.expectError(ValidationError.PrivateIp, validateUrl("http://192.168.1.1"));
}

test "validateUrl blocks metadata IPs" {
    try std.testing.expectError(ValidationError.MetadataIpBlocked, validateUrl("http://169.254.169.254"));
    try std.testing.expectError(ValidationError.MetadataIpBlocked, validateUrl("http://100.100.100.200"));
}

test "extractHost" {
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com/path").?);
    try std.testing.expectEqualStrings("example.com", extractHost("https://example.com:8080").?);
    try std.testing.expectEqualStrings("example.com", extractHost("https://user:pass@example.com/path").?);
    try std.testing.expectEqualStrings("::1", extractHost("http://[::1]").?);
}
