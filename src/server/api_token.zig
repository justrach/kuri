const std = @import("std");
const compat = @import("../compat.zig");

/// 🔐 API token bootstrap.
///
/// Phase 0a of the secret-containment plan: kuri's HTTP API must require
/// `Authorization: Bearer <token>` on every non-/health route. Without this,
/// `curl http://127.0.0.1:8080/cookies` is a free credential dump for anything
/// running on the loopback interface (other shell users, sloppy local malware,
/// browser extensions that probe localhost, etc).
///
/// Resolution order:
///   1. `KURI_API_TOKEN` env var (preferred for CI / process supervisors)
///   2. `KURI_SECRET` / `BROWDIE_SECRET` env vars (legacy aliases)
///   3. `~/.kuri/api.token` (auto-generated at 0600 on first launch)
///
/// The token is 32 random bytes hex-encoded (64 chars). Caller owns the
/// returned slice; pass it back into `Config.auth_secret` and let it live
/// for the process lifetime.
const token_byte_len: usize = 32;
const token_hex_len: usize = token_byte_len * 2;
const max_token_file_size: usize = 4096;

pub const Source = enum {
    env,
    file_loaded,
    file_generated,
};

pub const Resolved = struct {
    token: []u8,
    source: Source,
    path: ?[]u8, // owned; null when source==env

    pub fn deinit(self: *Resolved, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        if (self.path) |p| allocator.free(p);
    }
};

/// Returns a token to use for `Config.auth_secret`. Always non-empty.
pub fn ensure(allocator: std.mem.Allocator) !Resolved {
    if (compat.getenv("KURI_API_TOKEN")) |v| {
        if (v.len > 0) return .{ .token = try allocator.dupe(u8, v), .source = .env, .path = null };
    }
    if (compat.getenv("KURI_SECRET")) |v| {
        if (v.len > 0) return .{ .token = try allocator.dupe(u8, v), .source = .env, .path = null };
    }
    if (compat.getenv("BROWDIE_SECRET")) |v| {
        if (v.len > 0) return .{ .token = try allocator.dupe(u8, v), .source = .env, .path = null };
    }

    const token_path = try resolveTokenPath(allocator);
    errdefer allocator.free(token_path);

    // Try to load an existing token file.
    if (compat.cwdAccess(token_path)) {
        if (compat.cwdReadFile(allocator, token_path, max_token_file_size)) |raw| {
            defer allocator.free(raw);
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len > 0) {
                const dup = try allocator.dupe(u8, trimmed);
                return .{ .token = dup, .source = .file_loaded, .path = token_path };
            }
        } else |_| {
            // fall through and regenerate
        }
    }

    // Generate a fresh token, persist with 0600.
    const dir_path = std.fs.path.dirname(token_path) orelse ".";
    try compat.cwdMakePath(dir_path);

    var raw_bytes: [token_byte_len]u8 = undefined;
    compat.randomBytes(raw_bytes[0..]);
    const hex_buf = std.fmt.bytesToHex(raw_bytes, .lower);

    try writeMode0600(token_path, hex_buf[0..]);

    const dup = try allocator.dupe(u8, hex_buf[0..]);
    return .{ .token = dup, .source = .file_generated, .path = token_path };
}

fn resolveTokenPath(allocator: std.mem.Allocator) ![]u8 {
    const home = compat.getenv("HOME") orelse "/tmp";
    return std.fmt.allocPrint(allocator, "{s}/.kuri/api.token", .{home});
}

fn writeMode0600(path: []const u8, data: []const u8) !void {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z: [*:0]const u8 = buf[0..path.len :0];

    // O_WRONLY | O_CREAT | O_TRUNC, mode 0600.
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);

    try compat.fdWriteAll(fd, data);
    // Belt-and-suspenders: enforce mode even if umask widened it.
    _ = std.c.fchmod(fd, 0o600);
}

/// 🪧 Jupyter-style startup banner.
///
/// Inspired by the way `jupyter notebook` prints its access URL with the
/// token baked in. Goal: on first run the user *sees* the token and the
/// example curl invocation. They never have to remember `kuri token`.
///
/// Safety rules:
///   - If the token came from env, never echo it (the operator already
///     controls it; re-printing it just creates another copy in scrollback).
///   - If we loaded the token from disk and stderr is a TTY, show only the
///     first 12 chars + ellipsis. Full value stays one `kuri token` away.
///   - If we just generated a fresh token, print the full value *only* when
///     stderr is a TTY. When stderr is piped to a log file (launchd, k8s,
///     docker logs) we redact, because that's exactly the channel where a
///     leaked token causes the most damage.
pub fn printStartupBanner(
    writer_buf: []u8,
    version_str: []const u8,
    host: []const u8,
    port: u16,
    resolved: Resolved,
) void {
    const stderr_is_tty = compat.isTtyStderr();

    var token_buf: [128]u8 = undefined;
    const token_line: []const u8 = switch (resolved.source) {
        .env => "from environment (KURI_API_TOKEN)",
        .file_loaded => blk: {
            if (stderr_is_tty) {
                const head_len = @min(resolved.token.len, 12);
                const s = std.fmt.bufPrint(
                    &token_buf,
                    "{s}\xE2\x80\xA6  (run `kuri token` to print)",
                    .{resolved.token[0..head_len]},
                ) catch break :blk "loaded from file (run `kuri token` to print)";
                break :blk s;
            }
            break :blk "loaded from file (run `kuri token` to print)";
        },
        .file_generated => if (stderr_is_tty)
            resolved.token
        else
            "[redacted; run `kuri token` to print]",
    };

    const path_line: []const u8 = if (resolved.path) |p| p else "n/a (using env var)";

    const banner = std.fmt.bufPrint(
        writer_buf,
        \\
        \\─────────────────────────────────────────────────────────────────
        \\  kuri {s} listening on http://{s}:{d}
        \\
        \\  API token: {s}
        \\  Source:    {s}
        \\
        \\  Try it:
        \\    curl -H "Authorization: Bearer $(kuri token)" \
        \\         http://{s}:{d}/tabs
        \\─────────────────────────────────────────────────────────────────
        \\
        \\
    ,
        .{ version_str, host, port, token_line, path_line, host, port },
    ) catch return;
    compat.writeToStderr(banner);
}

test "hex output is 64 lowercase hex chars" {
    var raw: [token_byte_len]u8 = undefined;
    @memset(raw[0..], 0xAB);
    const hex_buf = std.fmt.bytesToHex(raw, .lower);
    try std.testing.expectEqual(@as(usize, 64), hex_buf.len);
    for (hex_buf) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(ok);
    }
}
