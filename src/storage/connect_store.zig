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

// ─────────────────────────────────────────────────────────────────────────────
// Multi-tenant layer (Track 2). Each tenant gets its own vault file under
// <state_dir>/tenants/<tenant_id>/connections.ns, so the same `service` name in
// two tenants maps to two encrypted-at-rest payloads with no cross-visibility.
// The single-tenant functions above are unchanged (local `kuri connect` CLI).
// See docs/scaling/02-cloud-profiles.md.

pub const TenantError = error{InvalidTenantId};

/// Validate a network-supplied tenant id BEFORE it becomes a path component.
/// A profile store keyed by a client-supplied id is a path-traversal magnet, so
/// allow only `[A-Za-z0-9_-]`, length 1..64 — anything that could escape the
/// state root (`/`, `\`, `.`, NUL, empty, over-long) is rejected.
pub fn sanitizeTenantId(tenant_id: []const u8) TenantError!void {
    if (tenant_id.len == 0 or tenant_id.len > 64) return error.InvalidTenantId;
    for (tenant_id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return error.InvalidTenantId;
    }
}

/// Derive `<state_dir>/tenants/<tenant_id>`. Caller owns the returned path.
/// Errors (rather than sanitizing silently) on an invalid tenant id.
pub fn tenantStateDir(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    tenant_id: []const u8,
) ![]u8 {
    try sanitizeTenantId(tenant_id);
    return std.fs.path.join(allocator, &.{ state_dir, "tenants", tenant_id });
}

/// Tenant-scoped `saveSession`. `passphrase` is the per-tenant key the broker
/// resolves (never a global one in a managed deployment — see §3.2 of the doc).
pub fn saveSessionForTenant(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    tenant_id: []const u8,
    passphrase: ?[]const u8,
    name: []const u8,
    origin: []const u8,
    payload_json: []const u8,
) !void {
    const dir = try tenantStateDir(allocator, state_dir, tenant_id);
    defer allocator.free(dir);
    return saveSession(allocator, dir, passphrase, name, origin, payload_json);
}

/// Tenant-scoped `loadSession`. Caller owns the returned bytes.
pub fn loadSessionForTenant(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    tenant_id: []const u8,
    passphrase: ?[]const u8,
    name: []const u8,
) ![]u8 {
    const dir = try tenantStateDir(allocator, state_dir, tenant_id);
    defer allocator.free(dir);
    return loadSession(allocator, dir, passphrase, name);
}

/// Tenant-scoped `listSessions`. Caller frees each id and the outer slice.
pub fn listSessionsForTenant(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    tenant_id: []const u8,
    passphrase: ?[]const u8,
) ![][]const u8 {
    const dir = try tenantStateDir(allocator, state_dir, tenant_id);
    defer allocator.free(dir);
    return listSessions(allocator, dir, passphrase);
}

/// Tenant-scoped `deleteSession`.
pub fn deleteSessionForTenant(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    tenant_id: []const u8,
    passphrase: ?[]const u8,
    name: []const u8,
) !void {
    const dir = try tenantStateDir(allocator, state_dir, tenant_id);
    defer allocator.free(dir);
    return deleteSession(allocator, dir, passphrase, name);
}

test "connect_store isolates tenants and rejects path-traversal ids" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(dir);

    const payload_a = "{\"v\":1,\"who\":\"a\",\"cookies\":[]}";
    const payload_b = "{\"v\":1,\"who\":\"b\",\"cookies\":[]}";

    // Same service name ("github") under two tenants must stay isolated.
    try saveSessionForTenant(a, dir, "tenantA", "pw", "github", "https://github.com", payload_a);
    try saveSessionForTenant(a, dir, "tenantB", "pw", "github", "https://github.com", payload_b);

    const got_a = try loadSessionForTenant(a, dir, "tenantA", "pw", "github");
    defer a.free(got_a);
    try std.testing.expectEqualStrings(payload_a, got_a);

    const got_b = try loadSessionForTenant(a, dir, "tenantB", "pw", "github");
    defer a.free(got_b);
    try std.testing.expectEqualStrings(payload_b, got_b);

    // Each tenant only sees its own vault contents.
    const names_a = try listSessionsForTenant(a, dir, "tenantA", "pw");
    defer {
        for (names_a) |n| a.free(n);
        a.free(names_a);
    }
    try std.testing.expectEqual(@as(usize, 1), names_a.len);
    try std.testing.expectEqualStrings("github", names_a[0]);

    // Deleting tenant A's service leaves tenant B untouched.
    try deleteSessionForTenant(a, dir, "tenantA", "pw", "github");
    try std.testing.expectError(error.NotFound, loadSessionForTenant(a, dir, "tenantA", "pw", "github"));
    const still_b = try loadSessionForTenant(a, dir, "tenantB", "pw", "github");
    defer a.free(still_b);
    try std.testing.expectEqualStrings(payload_b, still_b);

    // Path-traversal / malformed tenant ids are rejected before touching the fs.
    try std.testing.expectError(error.InvalidTenantId, sanitizeTenantId("../etc"));
    try std.testing.expectError(error.InvalidTenantId, sanitizeTenantId("a/b"));
    try std.testing.expectError(error.InvalidTenantId, sanitizeTenantId("a\\b"));
    try std.testing.expectError(error.InvalidTenantId, sanitizeTenantId(""));
    try sanitizeTenantId("tenant_123-OK");
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
