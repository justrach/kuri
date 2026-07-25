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

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

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
    linkAppleFrameworks(b, test_mod, target);
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // End-to-end suite. Kept off `test` on purpose: it drives a real booted
    // simulator, which CI does not have. It receives the built binary's path
    // as argv[1] so it exercises exactly the artifact that would ship.
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("src/test/e2e_ios.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // 0.17 restricts imports to a module's own path, so the shared io helpers
    // come in as a named module rather than a relative path.
    e2e_mod.addImport("io", b.createModule(.{
        .root_source_file = b.path("src/common/io.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }));
    const e2e = b.addExecutable(.{ .name = "e2e-ios", .root_module = e2e_mod });
    const run_e2e = b.addRunArtifact(e2e);
    run_e2e.addArtifactArg(exe);
    run_e2e.addPassthruArgs();
    const e2e_step = b.step("e2e-ios", "Run iOS end-to-end tests (needs a booted simulator)");
    e2e_step.dependOn(&run_e2e.step);
}
