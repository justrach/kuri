//! connect_store.zig — storage backend for kuri's `connect` feature.
//!
//! Persists a browser LOGIN SESSION (the cookies + localStorage +
//! sessionStorage payload that the server already captures for auth profiles)
//! encrypted at rest, using the sibling `nanostore` vault. Each service is a
//! nanostore `session` connection stored under "connections/<name>", so the
//! agent can replay a logged-in session without re-authenticating.
//!
//! The vault file lives at `<state_dir>/connections.ns` (mode 0600). When a
//! passphrase is provided (from `KURI_VAULT_PASSPHRASE`) the data encryption
//! key is wrapped with an Argon2id-derived key; otherwise the vault runs in
//! passwordless mode (DEK protected by the 0600 file mode).

const std = @import("std");
const nanostore = @import("nanostore");
const compat = @import("../compat.zig");

const VAULT_FILE = "connections.ns";
const conn_prefix = "connections/";

fn openVault(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    passphrase: ?[]const u8,
) !nanostore.Vault {
    compat.cwdMakePath(state_dir) catch {};
    const path = try std.fs.path.join(allocator, &.{ state_dir, VAULT_FILE });
    defer allocator.free(path);
    return nanostore.Vault.open(allocator, .{ .path = path, .passphrase = passphrase });
}

/// Persist `payload_json` (the captured session blob) under `name`. `origin`
/// is stored as the connection's base_url hint. Overwrites any existing entry.
pub fn saveSession(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    passphrase: ?[]const u8,
    name: []const u8,
    origin: []const u8,
    payload_json: []const u8,
) !void {
    var vault = try openVault(allocator, state_dir, passphrase);
    defer vault.deinit();
    try vault.setConnection(.{
        .id = name,
        .base_url = origin,
        .auth = .{ .session = payload_json },
    });
}

/// Load the stored session payload for `name`. Caller owns the returned bytes.
pub fn loadSession(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    passphrase: ?[]const u8,
    name: []const u8,
) ![]u8 {
    var vault = try openVault(allocator, state_dir, passphrase);
    defer vault.deinit();
    const conn = try vault.getConnection(allocator, name);
    defer vault.freeConnection(allocator, conn);
    return switch (conn.auth) {
        .session => |blob| try allocator.dupe(u8, blob),
        // A connection saved by this module is always a `session`; anything
        // else means the entry was written by another tool.
        else => error.NotASessionConnection,
    };
}

/// List stored connection names. Caller frees each id and the outer slice.
pub fn listSessions(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    passphrase: ?[]const u8,
) ![][]const u8 {
    var vault = try openVault(allocator, state_dir, passphrase);
    defer vault.deinit();
    return vault.listConnections(allocator);
}

/// Delete the stored session for `name`.
pub fn deleteSession(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    passphrase: ?[]const u8,
    name: []const u8,
) !void {
    var vault = try openVault(allocator, state_dir, passphrase);
    defer vault.deinit();
    const path = try std.fmt.allocPrint(allocator, conn_prefix ++ "{s}", .{name});
    defer allocator.free(path);
    try vault.delete(path);
}

test "connect_store round-trips a session payload encrypted at rest" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(dir);

    const payload = "{\"version\":1,\"name\":\"acme\",\"origin\":\"https://acme.example.com\",\"cookies\":[{\"name\":\"sessionid\",\"value\":\"abc123\"}],\"local_storage\":{},\"session_storage\":{}}";

    try saveSession(a, dir, "pw", "acme", "https://acme.example.com", payload);

    const got = try loadSession(a, dir, "pw", "acme");
    defer a.free(got);
    try std.testing.expectEqualStrings(payload, got);

    const names = try listSessions(a, dir, "pw");
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("acme", names[0]);

    // (Encryption-at-rest is guaranteed + tested by nanostore itself.)
    // Wrong passphrase is rejected.
    try std.testing.expectError(error.BadPassphrase, loadSession(a, dir, "wrong", "acme"));

    try deleteSession(a, dir, "pw", "acme");
    try std.testing.expectError(error.NotFound, loadSession(a, dir, "pw", "acme"));
}
