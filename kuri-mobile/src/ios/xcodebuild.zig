//! The build slice of the Xcode toolchain: list schemes, build for the
//! simulator, and resolve where the product landed.
//!
//! This is deliberately the *driver-adjacent* corner of XcodeBuildMCP's build
//! surface — enough that "here is a project, get it onto the booted
//! simulator" is one command — and no more. Tests, coverage, macOS targets
//! and scaffolding stay out of scope; a device driver that grows a full build
//! server stops being either.
//!
//! xcodebuild is invoked by absolute path through xcode.zig for the same
//! reason simctl is: on a machine where xcode-select points at
//! CommandLineTools, bare `xcodebuild` fails before it reads its arguments.

const std = @import("std");
const xcode = @import("xcode.zig");
const io = @import("../common/io.zig");

/// A clean single-target build logs tens of KiB; a real workspace with
/// SwiftPM resolution logs tens of MiB. The cap bounds memory, not the
/// build: past it the log is truncated, the build still completes.
const max_log = 32 * 1024 * 1024;
const max_settings = 4 * 1024 * 1024;

/// How much of a failed build log is worth replaying. The diagnostic that
/// matters is at the bottom — xcodebuild ends with the failing command and
/// an error summary — so a bounded tail beats the full megabytes.
const fail_tail_lines = 60;

pub const Built = struct {
    app_path: []u8,
    bundle_id: []u8,

    pub fn deinit(self: Built, gpa: std.mem.Allocator) void {
        gpa.free(self.app_path);
        gpa.free(self.bundle_id);
    }
};

/// xcodebuild names its container flag after the file type; callers just
/// hand us a path.
fn containerFlag(path: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, path, ".xcworkspace")) "-workspace" else "-project";
}

/// `xcodebuild -list`: schemes, targets and configurations, verbatim.
pub fn listSchemes(gpa: std.mem.Allocator, container: []const u8) ![]u8 {
    return xcode.run(gpa, "xcodebuild", &.{ containerFlag(container), container, "-list" }, max_settings);
}

fn commonArgs(
    gpa: std.mem.Allocator,
    container: []const u8,
    scheme: []const u8,
    configuration: []const u8,
) !std.ArrayList([]const u8) {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        containerFlag(container), container,
        "-scheme",                scheme,
        "-configuration",         configuration,
        // A generic destination builds for the simulator platform without
        // naming a device, so it works whatever simulators the host has.
        "-destination",           "generic/platform=iOS Simulator",
    });
    return argv;
}

/// Last `n` lines of a text, without allocating.
pub fn tailLines(text: []const u8, n: usize) []const u8 {
    var idx = text.len;
    var newlines: usize = 0;
    while (idx > 0) {
        idx -= 1;
        if (text[idx] == '\n') {
            newlines += 1;
            if (newlines > n) return text[idx + 1 ..];
        }
    }
    return text;
}

/// Value of `KEY = value` in `-showBuildSettings` output. Requires `=` right
/// after the key so TARGET_BUILD_DIR cannot match a longer key it prefixes.
pub fn settingValue(settings: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, settings, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        const after = std.mem.trimStart(u8, trimmed[key.len..], " ");
        if (!std.mem.startsWith(u8, after, "=")) continue;
        return std.mem.trim(u8, after[1..], " \t");
    }
    return null;
}

/// Ask xcodebuild where the scheme's product lands and what its bundle id
/// is. Separate from the build so `build` can answer without rebuilding.
pub fn resolveProduct(
    gpa: std.mem.Allocator,
    container: []const u8,
    scheme: []const u8,
    configuration: []const u8,
) !Built {
    var argv = try commonArgs(gpa, container, scheme, configuration);
    defer argv.deinit(gpa);
    try argv.append(gpa, "-showBuildSettings");
    const out = try xcode.run(gpa, "xcodebuild", argv.items, max_settings);
    defer gpa.free(out);

    const dir = settingValue(out, "TARGET_BUILD_DIR") orelse return error.BuildSettingMissing;
    const product = settingValue(out, "FULL_PRODUCT_NAME") orelse return error.BuildSettingMissing;
    const bundle = settingValue(out, "PRODUCT_BUNDLE_IDENTIFIER") orelse return error.BuildSettingMissing;

    const app_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, product });
    errdefer gpa.free(app_path);
    return .{ .app_path = app_path, .bundle_id = try gpa.dupe(u8, bundle) };
}

/// Build the scheme for the iOS Simulator and return the built product.
/// On failure the tail of the build log goes to stderr — that is where
/// xcodebuild puts the failing command and the error summary.
pub fn buildForSim(
    gpa: std.mem.Allocator,
    container: []const u8,
    scheme: []const u8,
    configuration: []const u8,
) !Built {
    var argv = try commonArgs(gpa, container, scheme, configuration);
    defer argv.deinit(gpa);
    try argv.append(gpa, "build");

    const r = try xcode.tryRun(gpa, "xcodebuild", argv.items, max_log);
    defer gpa.free(r.stdout);
    if (r.code != 0) {
        io.writeStderr(tailLines(r.stdout, fail_tail_lines));
        var arena_impl = std.heap.ArenaAllocator.init(gpa);
        defer arena_impl.deinit();
        io.printStderr(arena_impl.allocator(), "\nxcodebuild failed (exit {d}); log tail above\n", .{r.code});
        return error.CommandFailed;
    }
    return resolveProduct(gpa, container, scheme, configuration);
}

/// Run the scheme's tests on a concrete simulator. Unlike the build, a test
/// action cannot use a generic destination — the tests have to execute
/// somewhere — so this takes the udid the caller resolved. The log tail is
/// printed either way; xcodebuild ends it with the test summary.
pub fn testForSim(
    gpa: std.mem.Allocator,
    container: []const u8,
    scheme: []const u8,
    configuration: []const u8,
    udid: []const u8,
) !bool {
    const dest = try std.fmt.allocPrint(gpa, "platform=iOS Simulator,id={s}", .{udid});
    defer gpa.free(dest);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        containerFlag(container), container,
        "-scheme",                scheme,
        "-configuration",         configuration,
        "-destination",           dest,
        "test",
    });

    const r = try xcode.tryRun(gpa, "xcodebuild", argv.items, max_log);
    defer gpa.free(r.stdout);
    io.writeStderr(tailLines(r.stdout, if (r.code == 0) 12 else fail_tail_lines));
    return r.code == 0;
}

/// `xcodebuild clean` for the scheme.
pub fn clean(
    gpa: std.mem.Allocator,
    container: []const u8,
    scheme: []const u8,
    configuration: []const u8,
) !void {
    var argv = try commonArgs(gpa, container, scheme, configuration);
    defer argv.deinit(gpa);
    try argv.append(gpa, "clean");
    const out = try xcode.run(gpa, "xcodebuild", argv.items, max_settings);
    gpa.free(out);
}

test "settingValue reads a key and refuses prefix collisions" {
    const settings =
        "Build settings for action build and target Demo:\n" ++
        "    TARGET_BUILD_DIR_SUFFIXED = /wrong\n" ++
        "    TARGET_BUILD_DIR = /right/Debug-iphonesimulator\n" ++
        "    FULL_PRODUCT_NAME = Demo.app\n" ++
        "    PRODUCT_BUNDLE_IDENTIFIER = com.example.demo\n";
    try std.testing.expectEqualStrings(
        "/right/Debug-iphonesimulator",
        settingValue(settings, "TARGET_BUILD_DIR").?,
    );
    try std.testing.expectEqualStrings("Demo.app", settingValue(settings, "FULL_PRODUCT_NAME").?);
    try std.testing.expectEqualStrings("com.example.demo", settingValue(settings, "PRODUCT_BUNDLE_IDENTIFIER").?);
    try std.testing.expect(settingValue(settings, "MISSING_KEY") == null);
}

test "tailLines bounds a log from the end" {
    const log = "one\ntwo\nthree\nfour\n";
    try std.testing.expectEqualStrings("three\nfour\n", tailLines(log, 2));
    try std.testing.expectEqualStrings(log, tailLines(log, 100));
    try std.testing.expectEqualStrings("", tailLines("", 5));
}

test "containerFlag picks workspace for .xcworkspace" {
    try std.testing.expectEqualStrings("-workspace", containerFlag("App.xcworkspace"));
    try std.testing.expectEqualStrings("-project", containerFlag("App.xcodeproj"));
}
