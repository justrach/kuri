const std = @import("std");
const Config = @import("../bridge/config.zig").Config;

/// Check auth header against configured secret.
/// Returns true if no secret is configured or if the header matches.
pub fn checkAuth(request: *std.http.Server.Request, cfg: Config) bool {
    const secret = cfg.auth_secret orelse return true;

    // Iterate headers to find Authorization
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            return constantTimeEql(header.value, secret);
        }
    }
    return false;
}

/// Constant-time string comparison to prevent timing attacks.
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |ca, cb| {
        diff |= ca ^ cb;
    }
    return diff == 0;
}

test "constantTimeEql" {
    try std.testing.expect(constantTimeEql("secret123", "secret123"));
    try std.testing.expect(!constantTimeEql("secret123", "secret456"));
    try std.testing.expect(!constantTimeEql("short", "longer"));
}
