//! Session defaults: the four values every build-family invocation repeats.
//!
//! XcodeBuildMCP calls this `session_set_defaults`, and its docs are right
//! that it is the cheapest real ergonomic win an agent-facing CLI can buy:
//! `kuri ios build-run` with no arguments beats retyping a project path and
//! scheme on every call. The rules that keep hidden state from becoming a
//! footgun:
//!
//!   - only four known keys: project, scheme, configuration, udid
//!   - defaults fill *absent* values only — an explicit flag or positional
//!     always wins
//!   - only the build-family commands consult them; tap/screenshot/etc.
//!     keep their existing "booted simulator" resolution untouched
//!
//! Storage is one flat `key=value` file in $HOME (no directory to create,
//! libc-only I/O), overridable with KURI_MOBILE_DEFAULTS for tests.

const std = @import("std");
const io = @import("../common/io.zig");
const xcode = @import("xcode.zig");

const file_name = ".kuri-mobile-ios-defaults";
const max_file = 64 * 1024;

pub const known_keys = [_][]const u8{ "project", "scheme", "configuration", "udid" };

pub fn isKnownKey(key: []const u8) bool {
    for (known_keys) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

pub const Defaults = struct {
    project: ?[]u8 = null,
    scheme: ?[]u8 = null,
    configuration: ?[]u8 = null,
    udid: ?[]u8 = null,

    pub fn deinit(self: Defaults, gpa: std.mem.Allocator) void {
        if (self.project) |v| gpa.free(v);
        if (self.scheme) |v| gpa.free(v);
        if (self.configuration) |v| gpa.free(v);
        if (self.udid) |v| gpa.free(v);
    }

    fn slot(self: *Defaults, key: []const u8) ?*?[]u8 {
        if (std.mem.eql(u8, key, "project")) return &self.project;
        if (std.mem.eql(u8, key, "scheme")) return &self.scheme;
        if (std.mem.eql(u8, key, "configuration")) return &self.configuration;
        if (std.mem.eql(u8, key, "udid")) return &self.udid;
        return null;
    }
};

fn getEnv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

/// Where the defaults live. Caller frees.
pub fn filePath(gpa: std.mem.Allocator) ![]u8 {
    if (getEnv("KURI_MOBILE_DEFAULTS")) |p| return gpa.dupe(u8, p);
    const home = getEnv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, file_name });
}

/// Parse `key=value` lines into a Defaults. Unknown keys are ignored rather
/// than fatal so an older binary can read a newer file.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Defaults {
    var d: Defaults = .{};
    errdefer d.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        if (value.len == 0) continue;
        const s = d.slot(key) orelse continue;
        if (s.*) |old| gpa.free(old);
        s.* = try gpa.dupe(u8, value);
    }
    return d;
}

/// Serialize in a stable key order so the file diffs cleanly. Caller frees.
pub fn serialize(gpa: std.mem.Allocator, d: Defaults) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const pairs = [_]struct { key: []const u8, value: ?[]const u8 }{
        .{ .key = "project", .value = d.project },
        .{ .key = "scheme", .value = d.scheme },
        .{ .key = "configuration", .value = d.configuration },
        .{ .key = "udid", .value = d.udid },
    };
    for (pairs) |p| {
        if (p.value) |v| {
            try out.appendSlice(gpa, p.key);
            try out.append(gpa, '=');
            try out.appendSlice(gpa, v);
            try out.append(gpa, '\n');
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Load current defaults; a missing file is simply "nothing set".
pub fn load(gpa: std.mem.Allocator) !Defaults {
    const path = try filePath(gpa);
    defer gpa.free(path);
    if (!xcode.fileExists(path)) return .{};
    const text = try io.readFile(gpa, path, max_file);
    defer gpa.free(text);
    return parse(gpa, text);
}

/// Set one key, preserving the others.
pub fn set(gpa: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    if (!isKnownKey(key)) return error.UnknownKey;
    var d = try load(gpa);
    defer d.deinit(gpa);
    const s = d.slot(key).?;
    if (s.*) |old| gpa.free(old);
    s.* = try gpa.dupe(u8, value);
    const text = try serialize(gpa, d);
    defer gpa.free(text);
    const path = try filePath(gpa);
    defer gpa.free(path);
    try io.writeFile(path, text);
}

/// Clear one key, preserving the others.
pub fn clearKey(gpa: std.mem.Allocator, key: []const u8) !void {
    if (!isKnownKey(key)) return error.UnknownKey;
    var d = try load(gpa);
    defer d.deinit(gpa);
    const s = d.slot(key).?;
    if (s.*) |old| gpa.free(old);
    s.* = null;
    const text = try serialize(gpa, d);
    defer gpa.free(text);
    const path = try filePath(gpa);
    defer gpa.free(path);
    try io.writeFile(path, text);
}

/// Clear everything by removing the file.
pub fn clearAll(gpa: std.mem.Allocator) !void {
    const path = try filePath(gpa);
    defer gpa.free(path);
    io.removeFile(path);
}

test "parse fills known keys, ignores junk, last write wins" {
    const gpa = std.testing.allocator;
    const d = try parse(gpa,
        \\# comment
        \\project = /tmp/Demo.xcodeproj
        \\scheme=First
        \\scheme=Demo
        \\mystery=ignored
        \\udid=
        \\not-a-line
        \\
    );
    defer d.deinit(gpa);
    try std.testing.expectEqualStrings("/tmp/Demo.xcodeproj", d.project.?);
    try std.testing.expectEqualStrings("Demo", d.scheme.?);
    try std.testing.expect(d.configuration == null);
    try std.testing.expect(d.udid == null);
}

test "serialize round-trips through parse" {
    const gpa = std.testing.allocator;
    var d: Defaults = .{};
    d.project = try gpa.dupe(u8, "/x/App.xcworkspace");
    d.configuration = try gpa.dupe(u8, "Release");
    defer d.deinit(gpa);

    const text = try serialize(gpa, d);
    defer gpa.free(text);
    const back = try parse(gpa, text);
    defer back.deinit(gpa);
    try std.testing.expectEqualStrings("/x/App.xcworkspace", back.project.?);
    try std.testing.expectEqualStrings("Release", back.configuration.?);
    try std.testing.expect(back.scheme == null);
}

test "isKnownKey accepts the four keys and nothing else" {
    try std.testing.expect(isKnownKey("project"));
    try std.testing.expect(isKnownKey("udid"));
    try std.testing.expect(!isKnownKey("PROJECT"));
    try std.testing.expect(!isKnownKey("destination"));
}
