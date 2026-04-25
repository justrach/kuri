const builtin = @import("builtin");
const std = @import("std");
const json_util = @import("../util/json.zig");
const compat = @import("../compat.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

pub const Backend = enum {
    keychain,
    file,
};

pub const AuthProfileMeta = struct {
    name: []const u8,
    origin: []const u8,
    saved_at: i64,
    backend: Backend,
};

const KEYCHAIN_SERVICE = "dev.justrach.kuri.auth-profile";

pub fn preferredBackend() Backend {
    return if (builtin.os.tag == .macos) .keychain else .file;
}

pub fn saveProfile(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    name: []const u8,
    origin: []const u8,
    payload_json: []const u8,
) !Backend {
    const backend = preferredBackend();
    const safe_name = try sanitizeName(allocator, name);
    defer allocator.free(safe_name);

    const dir_path = try authProfilesDir(allocator, state_dir);
    defer allocator.free(dir_path);
    try compat.cwdMakePath(dir_path);

    switch (backend) {
        .keychain => {
            try keychainUpsert(allocator, name, payload_json);
            deleteSecretFile(allocator, dir_path, safe_name) catch {};
        },
        .file => try writeSecretFile(allocator, dir_path, safe_name, payload_json),
    }

    try writeMetaFile(allocator, dir_path, safe_name, .{
        .name = name,
        .origin = origin,
        .saved_at = compat.timestampSeconds(),
        .backend = backend,
    });

    return backend;
}

pub fn loadProfile(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    name: []const u8,
) ![]u8 {
    const safe_name = try sanitizeName(allocator, name);
    defer allocator.free(safe_name);

    const dir_path = try authProfilesDir(allocator, state_dir);
    defer allocator.free(dir_path);

    const meta = try readMetaFile(allocator, dir_path, safe_name);
    defer freeMeta(allocator, meta);

    return switch (meta.backend) {
        .keychain => try keychainRead(allocator, meta.name),
        .file => try readSecretFile(allocator, dir_path, safe_name),
    };
}

pub fn deleteProfile(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    name: []const u8,
) !void {
    const safe_name = try sanitizeName(allocator, name);
    defer allocator.free(safe_name);

    const dir_path = try authProfilesDir(allocator, state_dir);
    defer allocator.free(dir_path);

    const meta = readMetaFile(allocator, dir_path, safe_name) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer freeMeta(allocator, meta);

    switch (meta.backend) {
        .keychain => keychainDelete(allocator, meta.name) catch {},
        .file => deleteSecretFile(allocator, dir_path, safe_name) catch {},
    }

    const meta_path = try metaFilePath(allocator, dir_path, safe_name);
    defer allocator.free(meta_path);
    compat.cwdDeleteFile(meta_path) catch {};
}

pub fn listProfiles(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
) ![]AuthProfileMeta {
    const dir_path = try authProfilesDir(allocator, state_dir);
    defer allocator.free(dir_path);

    var path_buf: [4096]u8 = undefined;
    if (dir_path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..dir_path.len], dir_path);
    path_buf[dir_path.len] = 0;
    const dir_z: [*:0]const u8 = path_buf[0..dir_path.len :0];

    const dp = std.c.opendir(dir_z) orelse return allocator.alloc(AuthProfileMeta, 0);
    defer _ = std.c.closedir(dp);

    var list: std.ArrayList(AuthProfileMeta) = .empty;
    defer list.deinit(allocator);

    while (std.c.readdir(dp)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.sliceTo(name_ptr, 0);
        if (!std.mem.endsWith(u8, name, ".meta.json")) continue;

        const safe_name = name[0 .. name.len - ".meta.json".len];
        const meta = readMetaFile(allocator, dir_path, safe_name) catch continue;
        try list.append(allocator, meta);
    }

    std.mem.sort(AuthProfileMeta, list.items, {}, struct {
        fn lessThan(_: void, a: AuthProfileMeta, b: AuthProfileMeta) bool {
            return a.saved_at > b.saved_at;
        }
    }.lessThan);

    return list.toOwnedSlice(allocator);
}

pub fn freeProfiles(allocator: std.mem.Allocator, profiles: []AuthProfileMeta) void {
    for (profiles) |profile| freeMeta(allocator, profile);
    allocator.free(profiles);
}

fn freeMeta(allocator: std.mem.Allocator, meta: AuthProfileMeta) void {
    allocator.free(meta.name);
    allocator.free(meta.origin);
}

fn authProfilesDir(allocator: std.mem.Allocator, state_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ state_dir, "auth-profiles" });
}

fn metaFilePath(allocator: std.mem.Allocator, dir_path: []const u8, safe_name: []const u8) ![]u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.meta.json", .{safe_name});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ dir_path, file_name });
}

fn secretFilePath(allocator: std.mem.Allocator, dir_path: []const u8, safe_name: []const u8) ![]u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.secret.json", .{safe_name});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ dir_path, file_name });
}

fn sanitizeName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (name.len == 0) return error.InvalidProfileName;

    const out = try allocator.alloc(u8, name.len);
    errdefer allocator.free(out);

    var has_visible = false;
    for (name, 0..) |c, i| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') {
            out[i] = c;
            has_visible = true;
        } else if (std.ascii.isWhitespace(c) or c == '/' or c == '\\') {
            out[i] = '_';
        } else {
            out[i] = '_';
        }
    }

    if (!has_visible) return error.InvalidProfileName;
    return out;
}

fn writeMetaFile(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    safe_name: []const u8,
    meta: AuthProfileMeta,
) !void {
    const name_escaped = try json_util.jsonEscape(meta.name, allocator);
    defer allocator.free(name_escaped);
    const origin_escaped = try json_util.jsonEscape(meta.origin, allocator);
    defer allocator.free(origin_escaped);

    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"name\":\"{s}\",\"origin\":\"{s}\",\"saved_at\":{d},\"backend\":\"{s}\"}}",
        .{
            name_escaped,
            origin_escaped,
            meta.saved_at,
            if (meta.backend == .keychain) "keychain" else "file",
        },
    );
    defer allocator.free(body);

    const path = try metaFilePath(allocator, dir_path, safe_name);
    defer allocator.free(path);
    try writeFile(path, body);
}

fn readMetaFile(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    safe_name: []const u8,
) !AuthProfileMeta {
    const path = try metaFilePath(allocator, dir_path, safe_name);
    defer allocator.free(path);

    const body = try compat.cwdReadFile(allocator, path, 1024 * 1024);
    defer allocator.free(body);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), body, .{}) catch {
        return error.InvalidProfileMeta;
    };
    const object = switch (parsed) {
        .object => |obj| obj,
        else => return error.InvalidProfileMeta,
    };

    const name_value = object.get("name") orelse return error.InvalidProfileMeta;
    const name = switch (name_value) {
        .string => |value| value,
        else => return error.InvalidProfileMeta,
    };

    const origin_value = object.get("origin") orelse return error.InvalidProfileMeta;
    const origin = switch (origin_value) {
        .string => |value| value,
        else => return error.InvalidProfileMeta,
    };

    const saved_at_value = object.get("saved_at") orelse return error.InvalidProfileMeta;
    const saved_at = switch (saved_at_value) {
        .integer => |value| value,
        .number_string => |value| std.fmt.parseInt(i64, value, 10) catch return error.InvalidProfileMeta,
        else => return error.InvalidProfileMeta,
    };

    const backend_raw = if (object.get("backend")) |backend_value| switch (backend_value) {
        .string => |value| value,
        else => return error.InvalidProfileMeta,
    } else "file";

    return .{
        .name = try allocator.dupe(u8, name),
        .origin = try allocator.dupe(u8, origin),
        .saved_at = saved_at,
        .backend = if (std.mem.eql(u8, backend_raw, "keychain")) .keychain else .file,
    };
}

fn writeSecretFile(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    safe_name: []const u8,
    payload_json: []const u8,
) !void {
    const path = try secretFilePath(allocator, dir_path, safe_name);
    defer allocator.free(path);
    try writeFile(path, payload_json);
}

fn readSecretFile(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    safe_name: []const u8,
) ![]u8 {
    const path = try secretFilePath(allocator, dir_path, safe_name);
    defer allocator.free(path);
    return compat.cwdReadFile(allocator, path, 8 * 1024 * 1024);
}

fn deleteSecretFile(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    safe_name: []const u8,
) !void {
    const path = try secretFilePath(allocator, dir_path, safe_name);
    defer allocator.free(path);
    compat.cwdDeleteFile(path) catch {};
}

fn writeFile(path: []const u8, contents: []const u8) !void {
    try compat.cwdWriteFile(path, contents);
}

fn keychainUpsert(allocator: std.mem.Allocator, name: []const u8, payload_json: []const u8) !void {
    keychainDelete(allocator, name) catch {};
    const stdout = try runCommand(allocator, &.{
        "security",
        "add-generic-password",
        "-a",
        name,
        "-s",
        KEYCHAIN_SERVICE,
        "-U",
        "-w",
        payload_json,
    });
    allocator.free(stdout);
}

fn keychainRead(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return try runCommand(allocator, &.{
        "security",
        "find-generic-password",
        "-a",
        name,
        "-s",
        KEYCHAIN_SERVICE,
        "-w",
    });
}

fn keychainDelete(allocator: std.mem.Allocator, name: []const u8) !void {
    const stdout = try runCommand(allocator, &.{
        "security",
        "delete-generic-password",
        "-a",
        name,
        "-s",
        KEYCHAIN_SERVICE,
    });
    allocator.free(stdout);
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try compat.runCommand(allocator, argv, 8 * 1024 * 1024);
    if ((result.term & 0x7f) != 0 or ((result.term >> 8) & 0xff) != 0) {
        allocator.free(result.stdout);
        return error.CommandFailed;
    }

    const trimmed = std.mem.trim(u8, result.stdout, "\r\n");
    if (trimmed.len == result.stdout.len) return result.stdout;

    const output = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);
    return output;
}

fn deleteTreeAbsolute(dir: []const u8) void {
    var buf: [4096]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "rm -rf {s}", .{dir}) catch return;
    buf[cmd.len] = 0;
    const pid = std.c.fork();
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", buf[0..cmd.len :0], null };
        _ = std.c.execve("/bin/sh", &argv, @ptrCast(std.c.environ));
        std.c.exit(127);
    }
    if (pid > 0) _ = std.c.waitpid(pid, null, 0);
}

test "auth profile sanitizeName normalizes unsafe characters" {
    const value = try sanitizeName(std.testing.allocator, "prod/google oauth");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("prod_google_oauth", value);
}

test "auth profile file-backed round trip" {
    const allocator = std.testing.allocator;
    const dir = try std.fmt.allocPrint(allocator, "/tmp/kuri_auth_profile_test_{d}", .{compat.timestampSeconds()});
    defer allocator.free(dir);
    defer deleteTreeAbsolute(dir);

    const profiles_dir = try authProfilesDir(allocator, dir);
    defer allocator.free(profiles_dir);
    try compat.cwdMakePath(profiles_dir);

    const safe_name = try sanitizeName(allocator, "demo");
    defer allocator.free(safe_name);

    try writeSecretFile(allocator, profiles_dir, safe_name, "{\"token\":\"abc\"}");
    try writeMetaFile(allocator, profiles_dir, safe_name, .{
        .name = "demo",
        .origin = "https://example.com",
        .saved_at = 123,
        .backend = .file,
    });

    const loaded = try readSecretFile(allocator, profiles_dir, safe_name);
    defer allocator.free(loaded);
    try std.testing.expectEqualStrings("{\"token\":\"abc\"}", loaded);

    const profiles = try listProfiles(allocator, dir);
    defer freeProfiles(allocator, profiles);
    try std.testing.expectEqual(@as(usize, 1), profiles.len);
    try std.testing.expectEqualStrings("demo", profiles[0].name);
}

test "auth profile metadata round trip preserves escaped JSON strings" {
    const allocator = std.testing.allocator;
    const dir = try std.fmt.allocPrint(
        allocator,
        "/tmp/kuri_auth_profile_meta_test_{d}_{d}",
        .{ compat.timestampSeconds(), std.c.getpid() },
    );
    defer allocator.free(dir);
    defer deleteTreeAbsolute(dir);

    const profiles_dir = try authProfilesDir(allocator, dir);
    defer allocator.free(profiles_dir);
    try compat.cwdMakePath(profiles_dir);

    const name = "demo \"qa\"\\profile";
    const origin = "https://example.com/callback?label=\"qa\"&path=C:\\Users\\demo";
    const safe_name = try sanitizeName(allocator, name);
    defer allocator.free(safe_name);

    try writeMetaFile(allocator, profiles_dir, safe_name, .{
        .name = name,
        .origin = origin,
        .saved_at = 456,
        .backend = .keychain,
    });

    const meta = try readMetaFile(allocator, profiles_dir, safe_name);
    defer freeMeta(allocator, meta);

    try std.testing.expectEqualStrings(name, meta.name);
    try std.testing.expectEqualStrings(origin, meta.origin);
    try std.testing.expectEqual(@as(i64, 456), meta.saved_at);
    try std.testing.expectEqual(Backend.keychain, meta.backend);
}

test "auth profile runCommand resolves executables from PATH" {
    const allocator = std.testing.allocator;
    const dir = try std.fmt.allocPrint(
        allocator,
        "/tmp/kuri_auth_profile_path_test_{d}_{d}",
        .{ compat.timestampSeconds(), std.c.getpid() },
    );
    defer allocator.free(dir);
    defer deleteTreeAbsolute(dir);

    try compat.cwdMakePath(dir);

    const script_path = try std.fs.path.join(allocator, &.{ dir, "kuri-path-check" });
    defer allocator.free(script_path);
    try writeFile(script_path, "#!/bin/sh\nprintf path-ok\n");

    const script_path_z = try allocator.allocSentinel(u8, script_path.len, 0);
    defer allocator.free(script_path_z);
    @memcpy(script_path_z[0..script_path.len], script_path);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(script_path_z, 0o755));

    const path_name = "PATH";
    const path_name_z = try allocator.allocSentinel(u8, path_name.len, 0);
    defer allocator.free(path_name_z);
    @memcpy(path_name_z[0..path_name.len], path_name);

    const old_path = compat.getenv(path_name);
    const old_path_copy = if (old_path) |value| try allocator.dupe(u8, value) else null;
    defer if (old_path_copy) |value| allocator.free(value);
    const old_path_z = if (old_path_copy) |value| blk: {
        const value_z = try allocator.allocSentinel(u8, value.len, 0);
        @memcpy(value_z[0..value.len], value);
        break :blk value_z;
    } else null;
    defer if (old_path_z) |value| allocator.free(value);
    defer {
        if (old_path_z) |value| {
            _ = setenv(path_name_z, value, 1);
        } else {
            _ = unsetenv(path_name_z);
        }
    }

    const dir_z = try allocator.allocSentinel(u8, dir.len, 0);
    defer allocator.free(dir_z);
    @memcpy(dir_z[0..dir.len], dir);
    try std.testing.expectEqual(@as(c_int, 0), setenv(path_name_z, dir_z, 1));

    const output = try runCommand(allocator, &.{"kuri-path-check"});
    defer allocator.free(output);
    try std.testing.expectEqualStrings("path-ok", output);
}
