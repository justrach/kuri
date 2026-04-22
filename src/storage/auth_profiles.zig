const builtin = @import("builtin");
const std = @import("std");
const json_util = @import("../util/json.zig");
const compat = @import("../compat.zig");

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

    const name = extractStringField(body, "\"name\"") orelse return error.InvalidProfileMeta;
    const origin = extractStringField(body, "\"origin\"") orelse return error.InvalidProfileMeta;
    const backend_raw = extractStringField(body, "\"backend\"") orelse "file";
    const saved_at = extractIntField(body, "\"saved_at\"") orelse return error.InvalidProfileMeta;

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

fn extractStringField(json: []const u8, field: []const u8) ?[]const u8 {
    const field_pos = std.mem.indexOf(u8, json, field) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, json, field_pos + field.len, ':') orelse return null;
    const quote_start = std.mem.indexOfScalarPos(u8, json, colon + 1, '"') orelse return null;
    const value_start = quote_start + 1;
    const value_end = std.mem.indexOfScalarPos(u8, json, value_start, '"') orelse return null;
    return json[value_start..value_end];
}

fn extractIntField(json: []const u8, field: []const u8) ?i64 {
    const field_pos = std.mem.indexOf(u8, json, field) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, json, field_pos + field.len, ':') orelse return null;
    var start = colon + 1;
    while (start < json.len and (json[start] == ' ' or json[start] == '\n' or json[start] == '\r')) : (start += 1) {}
    var end = start;
    while (end < json.len and (json[end] == '-' or std.ascii.isDigit(json[end]))) : (end += 1) {}
    return std.fmt.parseInt(i64, json[start..end], 10) catch null;
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
    // Build null-terminated argv for execve
    const argv_z = try allocator.alloc(?[*:0]const u8, argv.len + 1);
    defer allocator.free(argv_z);
    for (argv, 0..) |arg, i| {
        argv_z[i] = @ptrCast(arg.ptr);
    }
    argv_z[argv.len] = null;

    // Create pipe for capturing stdout
    var pipe_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.CommandFailed;

    const pid = std.c.fork();
    if (pid < 0) return error.CommandFailed;

    if (pid == 0) {
        // Child: close read end, redirect stdout to pipe write end
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.dup2(pipe_fds[1], 1);
        _ = std.c.close(pipe_fds[1]);
        // Redirect stderr to /dev/null
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(c_uint, 0));
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 2);
            _ = std.c.close(devnull);
        }
        _ = std.c.execve(argv_z[0].?, @ptrCast(argv_z.ptr), @ptrCast(std.c.environ));
        std.c.exit(127);
    }

    // Parent: close write end, read stdout from pipe
    _ = std.c.close(pipe_fds[1]);
    defer _ = std.c.close(pipe_fds[0]);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(pipe_fds[0], &buf, buf.len);
        if (n <= 0) break;
        try output.appendSlice(allocator, buf[0..@intCast(n)]);
    }

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    // Check exit status (WIFEXITED && WEXITSTATUS == 0)
    if ((status & 0x7f) != 0 or ((status >> 8) & 0xff) != 0) return error.CommandFailed;

    const trimmed = std.mem.trim(u8, output.items, "\r\n");
    return try allocator.dupe(u8, trimmed);
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

test "sanitizeName normalizes unsafe characters" {
    const value = try sanitizeName(std.testing.allocator, "prod/google oauth");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("prod_google_oauth", value);
}

test "file-backed auth profile round trip" {
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
