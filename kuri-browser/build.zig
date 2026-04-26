const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const quickjs_dep = b.dependency("quickjs", .{
        .target = target,
        .optimize = optimize,
    });

    const jsengine_mod = b.createModule(.{
        .root_source_file = b.path("../src/js_engine.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    jsengine_mod.addImport("quickjs", quickjs_dep.module("quickjs"));

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_mod.addImport("jsengine", jsengine_mod);
    root_mod.addImport("quickjs", quickjs_dep.module("quickjs"));

    const exe = b.addExecutable(.{
        .name = "kuri-browser",
        .root_module = root_mod,
    });
    exe.root_module.linkLibrary(quickjs_dep.artifact("quickjs-ng"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run kuri-browser");
    run_step.dependOn(&run_cmd.step);

    const main_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    main_test_mod.addImport("jsengine", jsengine_mod);
    main_test_mod.addImport("quickjs", quickjs_dep.module("quickjs"));
    const main_tests = b.addTest(.{
        .root_module = main_test_mod,
    });
    main_tests.root_module.linkLibrary(quickjs_dep.artifact("quickjs-ng"));
    const run_main_tests = b.addRunArtifact(main_tests);

    const runtime_test_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    runtime_test_mod.addImport("jsengine", jsengine_mod);
    runtime_test_mod.addImport("quickjs", quickjs_dep.module("quickjs"));
    const runtime_tests = b.addTest(.{
        .root_module = runtime_test_mod,
    });
    runtime_tests.root_module.linkLibrary(quickjs_dep.artifact("quickjs-ng"));
    const run_runtime_tests = b.addRunArtifact(runtime_tests);

    const jsengine_test_mod = b.createModule(.{
        .root_source_file = b.path("../src/js_engine.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    jsengine_test_mod.addImport("quickjs", quickjs_dep.module("quickjs"));
    const jsengine_tests = b.addTest(.{
        .root_module = jsengine_test_mod,
    });
    jsengine_tests.root_module.linkLibrary(quickjs_dep.artifact("quickjs-ng"));
    const run_jsengine_tests = b.addRunArtifact(jsengine_tests);

    const test_step = b.step("test", "Run kuri-browser tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_runtime_tests.step);
    test_step.dependOn(&run_jsengine_tests.step);
}
