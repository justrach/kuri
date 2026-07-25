//! `kuri update` — replace the installed binaries with the current release.
//!
//! Before this existed the only way to upgrade was to remember an installer
//! URL and pipe it to a shell. `kuri update` is the same operation with the
//! steps made checkable: it reads the signed channel manifest, compares the
//! published version against the one compiled into this binary, verifies the
//! download's SHA-256 *in process* rather than trusting a shell script to do
//! it, and only then swaps the binaries.
//!
//! Two deliberate choices:
//!
//!   * The hash is computed here, not shelled out to `shasum`. A verification
//!     step that depends on which of three hashing tools happens to be on PATH
//!     is a verification step that can silently not happen.
//!   * Binaries are installed by writing a temp file and `rename`-ing it over
//!     the target. Copying onto a running executable fails with ETXTBSY on
//!     Linux and corrupts a concurrently-executing image elsewhere; rename is
//!     atomic and leaves the running process on its old inode.
//!
//! `curl` is used purely as transport. Bringing the TLS stack in here would
//! mean this command, of all commands, could be broken by a TLS regression in
//! the thing it is meant to repair.

const std = @import("std");
const compat = @import("compat.zig");

const manifest_url = "https://raw.githubusercontent.com/justrach/kuri/release-channel/stable/latest.json";

/// Everything the tarball ships. `kuri-mobile` is the one that matters most
/// here: `kuri android`/`kuri ios` exec it as a sibling binary, so an install
/// that omits it leaves those subcommands broken with a confusing "not found"
/// rather than an honest failure. The shell installer omitted it for four
/// releases.
const binaries = [_][]const u8{
    "kuri",
    "kuri-agent",
    "kuri-fetch",
    "kuri-browse",
    "kuri-mobile",
};

pub const Options = struct {
    /// Report what would happen and exit, changing nothing.
    check_only: bool = false,
    /// Where to install. Defaults to the directory this binary runs from, so
    /// an update lands where the previous install did rather than in a second
    /// location that then shadows it on PATH.
    dir: ?[]const u8 = null,
};

const Asset = struct {
    url: []const u8,
    sha256: []const u8,
    version: []const u8,
};

pub fn run(gpa: std.mem.Allocator, current_version: []const u8, opts: Options) !u8 {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const target = try platformTarget(arena);
    printf(arena, "kuri {s} ({s})\n", .{ current_version, target });

    const manifest = fetch(arena, manifest_url) catch |err| {
        printfErr(arena, "could not reach the release channel: {s}\n", .{@errorName(err)});
        return 1;
    };
    const asset = parseAsset(arena, manifest, target) catch |err| {
        printfErr(arena, "malformed channel manifest ({s})\n", .{@errorName(err)});
        return 1;
    };

    // The manifest carries a leading "v"; the compiled-in version does not.
    const published = stripV(asset.version);
    if (std.mem.eql(u8, published, current_version)) {
        printf(arena, "already up to date ({s})\n", .{asset.version});
        return 0;
    }
    printf(arena, "update available: {s} -> {s}\n", .{ current_version, asset.version });
    if (opts.check_only) return 0;

    const dir = opts.dir orelse try installDir(arena);
    printf(arena, "installing to {s}\n", .{dir});

    const tmp_dir = try std.fmt.allocPrint(arena, "/tmp/kuri-update-{d}", .{std.c.getpid()});
    defer removeTree(gpa, tmp_dir);
    try mkdirp(tmp_dir);

    const tarball = try std.fmt.allocPrint(arena, "{s}/kuri.tar.gz", .{tmp_dir});
    printf(arena, "downloading {s}\n", .{asset.url});
    download(arena, asset.url, tarball) catch |err| {
        printfErr(arena, "download failed: {s}\n", .{@errorName(err)});
        return 1;
    };

    // Verified here rather than by a shell helper, so this cannot be skipped
    // by a machine that happens to lack shasum/sha256sum/openssl.
    const actual = try sha256File(arena, tarball);
    if (!std.ascii.eqlIgnoreCase(actual, asset.sha256)) {
        printfErr(arena, "checksum mismatch — refusing to install\n  expected {s}\n  actual   {s}\n", .{ asset.sha256, actual });
        return 1;
    }
    printf(arena, "sha256 ok\n", .{});

    const untar = try compat.runCommand(arena, &.{ "tar", "-xzf", tarball, "-C", tmp_dir }, 1 << 20);
    if (exitCode(untar.term) != 0) {
        printfErr(arena, "could not unpack the release archive\n", .{});
        return 1;
    }

    var installed: usize = 0;
    for (binaries) |name| {
        const src = try std.fmt.allocPrint(arena, "{s}/{s}", .{ tmp_dir, name });
        if (!fileExists(src)) continue;
        const dst = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
        installOne(arena, src, dst) catch |err| {
            printfErr(arena, "failed to install {s}: {s}\n", .{ name, @errorName(err) });
            return 1;
        };
        printf(arena, "  {s}\n", .{name});
        installed += 1;
    }
    if (installed == 0) {
        printfErr(arena, "the release archive contained none of the expected binaries\n", .{});
        return 1;
    }

    printf(arena, "updated to {s} ({d} binaries)\n", .{ asset.version, installed });
    return 0;
}

/// Install one binary: copy to a temp name beside the target, mark it
/// executable, drop macOS quarantine, then rename over the target.
///
/// The temp file is created in the *destination* directory on purpose —
/// rename cannot cross filesystems, and /tmp frequently is one.
fn installOne(arena: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const staged = try std.fmt.allocPrint(arena, "{s}.new-{d}", .{ dst, std.c.getpid() });

    const cp = try compat.runCommand(arena, &.{ "cp", src, staged }, 1 << 16);
    if (exitCode(cp.term) != 0) return error.CopyFailed;

    const chmod = try compat.runCommand(arena, &.{ "chmod", "755", staged }, 1 << 16);
    if (exitCode(chmod.term) != 0) return error.ChmodFailed;

    // Downloaded files carry com.apple.quarantine, which makes Gatekeeper
    // prompt on first run. Best-effort: absent on Linux, and harmless to fail.
    if (@import("builtin").os.tag == .macos) {
        const x = compat.runCommand(arena, &.{ "xattr", "-d", "com.apple.quarantine", staged }, 1 << 16) catch null;
        _ = x;
    }

    const s = try dupeZ(arena, staged);
    const d = try dupeZ(arena, dst);
    if (std.c.rename(s.ptr, d.ptr) != 0) return error.RenameFailed;
}

fn fetch(arena: std.mem.Allocator, url: []const u8) ![]u8 {
    const r = try compat.runCommand(arena, &.{ "curl", "-fsSL", url }, 4 << 20);
    if (exitCode(r.term) != 0) return error.FetchFailed;
    return r.stdout;
}

fn download(arena: std.mem.Allocator, url: []const u8, out_path: []const u8) !void {
    const r = try compat.runCommand(arena, &.{ "curl", "-fL", "--retry", "2", "-o", out_path, url }, 1 << 20);
    if (exitCode(r.term) != 0) return error.DownloadFailed;
}

/// Pull this platform's entry out of the channel manifest.
fn parseAsset(arena: std.mem.Allocator, manifest: []const u8, target: []const u8) !Asset {
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, manifest, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotAnObject,
    };
    const version = switch (root.get("version") orelse return error.NoVersion) {
        .string => |s| s,
        else => return error.NoVersion,
    };
    const assets = switch (root.get("assets") orelse return error.NoAssets) {
        .object => |o| o,
        else => return error.NoAssets,
    };
    const entry = switch (assets.get(target) orelse return error.NoAssetForPlatform) {
        .object => |o| o,
        else => return error.NoAssetForPlatform,
    };
    const url = switch (entry.get("url") orelse return error.NoUrl) {
        .string => |s| s,
        else => return error.NoUrl,
    };
    const sha = switch (entry.get("sha256") orelse return error.NoSha) {
        .string => |s| s,
        else => return error.NoSha,
    };
    // Copied out because `parsed` owns them and is freed on return.
    return .{
        .url = try arena.dupe(u8, url),
        .sha256 = try arena.dupe(u8, sha),
        .version = try arena.dupe(u8, version),
    };
}

/// `<arch>-<os>`, matching the manifest's asset keys.
fn platformTarget(arena: std.mem.Allocator) ![]const u8 {
    const b = @import("builtin");
    const arch = switch (b.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => return error.UnsupportedArch,
    };
    const os = switch (b.os.tag) {
        .macos => "macos",
        .linux => "linux",
        else => return error.UnsupportedOs,
    };
    return std.fmt.allocPrint(arena, "{s}-{s}", .{ arch, os });
}

/// Where to install: KURI_INSTALL_DIR, else the directory holding the running
/// binary, else ~/.local/bin. Preferring the running binary's own directory is
/// what makes `kuri update` upgrade *this* install rather than creating a
/// second one that may or may not win on PATH.
fn installDir(arena: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("KURI_INSTALL_DIR")) |v| {
        const s = std.mem.span(v);
        if (s.len > 0) return s;
    }
    if (selfDir(arena)) |d| return d else |_| {}
    if (std.c.getenv("HOME")) |v| {
        return std.fmt.allocPrint(arena, "{s}/.local/bin", .{std.mem.span(v)});
    }
    return error.NoInstallDir;
}

extern "c" fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;

fn selfDir(arena: std.mem.Allocator) ![]const u8 {
    var buf: [4096]u8 = undefined;
    var path: []const u8 = undefined;
    switch (@import("builtin").os.tag) {
        .macos => {
            var size: u32 = buf.len;
            if (_NSGetExecutablePath(&buf, &size) != 0) return error.PathTooLong;
            path = std.mem.sliceTo(&buf, 0);
        },
        .linux => {
            const n = std.c.readlink("/proc/self/exe", &buf, buf.len);
            if (n <= 0) return error.NoSelfPath;
            path = buf[0..@intCast(n)];
        },
        else => return error.UnsupportedOs,
    }
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.NoSelfPath;
    return arena.dupe(u8, path[0..slash]);
}

fn sha256File(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const p = try dupeZ(arena, path);
    const fd = std.c.open(p.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        hasher.update(buf[0..@intCast(n)]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.allocPrint(arena, "{x}", .{&digest});
}

fn fileExists(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const fd = std.c.open(buf[0..path.len :0], .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return false;
    _ = std.c.close(fd);
    return true;
}

fn mkdirp(path: []const u8) !void {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    const r = try compat.runCommand(arena_impl.allocator(), &.{ "mkdir", "-p", path }, 1 << 16);
    if (exitCode(r.term) != 0) return error.MkdirFailed;
}

fn removeTree(gpa: std.mem.Allocator, path: []const u8) void {
    const r = compat.runCommand(gpa, &.{ "rm", "-rf", path }, 1 << 16) catch return;
    gpa.free(r.stdout);
}

fn exitCode(term: i32) i32 {
    return (term >> 8) & 0xFF;
}

/// NUL-terminated copy for the libc calls below. Hand-rolled because the std
/// spelling for this has changed across the Zig versions this project tracks
/// (`dupeZ` -> `dupeSentinel`), and this file should not need touching for it.
fn dupeZ(arena: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const out = try arena.allocSentinel(u8, s.len, 0);
    @memcpy(out[0..s.len], s);
    return out;
}

/// Tags are published as `v0.4.12`; the version compiled into the binary is
/// `0.4.12`. Spelled out here rather than via std.mem, whose trim helpers have
/// been renamed twice across the Zig versions this project has tracked.
fn stripV(s: []const u8) []const u8 {
    return if (s.len > 0 and (s[0] == 'v' or s[0] == 'V')) s[1..] else s;
}

fn printf(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(arena, fmt, args) catch return;
    compat.writeToStdout(s);
}

fn printfErr(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(arena, fmt, args) catch return;
    compat.writeToStderr(s);
}

// --- tests ------------------------------------------------------------------

test "parseAsset reads the entry for this platform" {
    const manifest =
        \\{"channel":"stable","version":"v9.9.9","assets":{
        \\  "aarch64-macos":{"url":"https://example/a.tar.gz","sha256":"abc","size":1,"notarized":false},
        \\  "x86_64-linux":{"url":"https://example/b.tar.gz","sha256":"def","size":2,"notarized":false}}}
    ;
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = try parseAsset(arena_impl.allocator(), manifest, "aarch64-macos");
    try std.testing.expectEqualStrings("v9.9.9", a.version);
    try std.testing.expectEqualStrings("https://example/a.tar.gz", a.url);
    try std.testing.expectEqualStrings("abc", a.sha256);
}

test "parseAsset rejects a manifest without this platform" {
    const manifest =
        \\{"version":"v1.0.0","assets":{"x86_64-linux":{"url":"u","sha256":"s"}}}
    ;
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    try std.testing.expectError(
        error.NoAssetForPlatform,
        parseAsset(arena_impl.allocator(), manifest, "aarch64-macos"),
    );
}

test "parseAsset rejects malformed json rather than guessing" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    try std.testing.expectError(
        error.SyntaxError,
        parseAsset(arena_impl.allocator(), "not json", "aarch64-macos"),
    );
}

test "sha256File matches a known digest" {
    // echo -n "kuri" | shasum -a 256
    const path = "/tmp/kuri-update-sha-test";
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const p = try dupeZ(arena, path);
    const fd = std.c.open(p.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    _ = std.c.write(fd, "kuri", 4);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(p.ptr);

    const got = try sha256File(arena, path);
    try std.testing.expectEqualStrings(
        "8e7540f71f55b5b3e678624b2a0ec3d206d461e83e9eef3d7afb51c2bb6e516e",
        got,
    );
}

test "version comparison ignores the manifest's leading v" {
    try std.testing.expectEqualStrings("0.4.12", stripV("v0.4.12"));
    try std.testing.expectEqualStrings("0.4.12", stripV("0.4.12"));
    try std.testing.expectEqualStrings("", stripV(""));
    // Only the leading v goes; a version is not a series of them.
    try std.testing.expectEqualStrings("v1.0.0", stripV("vv1.0.0"));
}
