const std = @import("std");

/// A native macOS build inherits the SDK search paths automatically, but
/// cross-compiling to the *other* macOS arch does not — the linker then fails
/// with "unable to find framework 'ApplicationServices'". Point it at the
/// active SDK explicitly so `-Dtarget=x86_64-macos` works from Apple Silicon.
fn linkAppleFrameworks(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .macos) return;
    mod.linkFramework("ApplicationServices", .{});
    const sdk = std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result) orelse return;
    mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
    mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // MCP protocol machinery (JSON-RPC loop, version negotiation, transports)
    // comes from mcp-zig; kuri only supplies the tool registry.
    const mcp_dep = b.dependency("mcp_zig", .{ .target = target, .optimize = optimize });
    const mcp_module = mcp_dep.module("mcp");

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_mod.addImport("mcp", mcp_module);

    // CGEvent (tap/swipe) and AXUIElement live in ApplicationServices on macOS.
    linkAppleFrameworks(b, root_mod, target);

    const exe = b.addExecutable(.{
        .name = "kuri-mobile",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run kuri-mobile");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("mcp", mcp_module);
    linkAppleFrameworks(b, test_mod, target);
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // End-to-end suites. Kept off `test` on purpose: they shell out to the
    // real Xcode toolchain, and most cases need a booted simulator or an
    // attached phone. Each receives the built binary's path as argv[1] so it
    // exercises exactly the artifact that would ship.
    //
    // 0.17 restricts imports to a module's own path, so the shared helpers
    // come in as named modules rather than relative paths.
    const io_mod = b.createModule(.{
        .root_source_file = b.path("src/common/io.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const harness_mod = b.createModule(.{
        .root_source_file = b.path("src/test/harness.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    harness_mod.addImport("io", io_mod);

    const Suite = struct { step: []const u8, src: []const u8, desc: []const u8 };
    const suites = [_]Suite{
        .{
            .step = "e2e-ios",
            .src = "src/test/e2e_ios.zig",
            .desc = "Run iOS end-to-end tests (simulator; skips what the host cannot provide)",
        },
        .{
            .step = "e2e-ios-device",
            .src = "src/test/e2e_ios_device.zig",
            .desc = "Run iOS end-to-end tests against an attached physical device",
        },
    };
    for (suites) |s| {
        const mod = b.createModule(.{
            .root_source_file = b.path(s.src),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mod.addImport("io", io_mod);
        mod.addImport("harness", harness_mod);
        const exe_suite = b.addExecutable(.{ .name = s.step, .root_module = mod });
        const run_suite = b.addRunArtifact(exe_suite);
        run_suite.addArtifactArg(exe);
        run_suite.addPassthruArgs();
        b.step(s.step, s.desc).dependOn(&run_suite.step);

        // The suites' own parsing helpers — which udid a listing names, which
        // pid a launch printed — decide what the hardware cases assert on, so
        // they belong in `zig build test` where they run everywhere. Needs a
        // second module: a test root cannot be shared with an executable root.
        const test_suite_mod = b.createModule(.{
            .root_source_file = b.path(s.src),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        test_suite_mod.addImport("io", io_mod);
        test_suite_mod.addImport("harness", harness_mod);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_suite_mod })).step);
    }
}
