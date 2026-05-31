const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "kuri",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // Stateless FFI shared library — embed kuri's fetch/render path in-process
    // (no server, no Bridge). Pure-Zig deps (validator/markdown) + spawned curl;
    // needs no quickjs / curl-impersonate linkage. Built with `zig build ffi`.
    const ffi_lib = b.addLibrary(.{
        .name = "kuri_ffi",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ffi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const ffi_install = b.addInstallArtifact(ffi_lib, .{});
    const ffi_step = b.step("ffi", "Build the stateless FFI shared library (libkuri_ffi)");
    ffi_step.dependOn(&ffi_install.step);

    // Run step
    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);

    // Tests — all tests compiled from main.zig root (needed for ../compat.zig imports)
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);


    // merjs E2E test binary
    const compat_mod = b.createModule(.{
        .root_source_file = b.path("src/compat.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const merjs_e2e_mod = b.createModule(.{
        .root_source_file = b.path("src/test/merjs_e2e.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    merjs_e2e_mod.addImport("compat", compat_mod);
    const merjs_e2e = b.addExecutable(.{
        .name = "merjs-e2e",
        .root_module = merjs_e2e_mod,
    });
    b.installArtifact(merjs_e2e);
    const run_merjs_e2e = b.addRunArtifact(merjs_e2e);
    const merjs_e2e_step = b.step("merjs-e2e", "Run merjs E2E tests (requires merjs + kuri + Chrome live)");
    merjs_e2e_step.dependOn(&run_merjs_e2e.step);

    // QuickJS dependency
    const quickjs_dep = b.dependency("quickjs", .{
        .target = target,
        .optimize = optimize,
    });

    // Sandbox (bundle replay) needs QuickJS in the main exe + tests.
    exe.root_module.addImport("quickjs", quickjs_dep.module("quickjs"));
    exe.root_module.linkLibrary(quickjs_dep.artifact("quickjs-ng"));
    unit_tests.root_module.addImport("quickjs", quickjs_dep.module("quickjs"));
    unit_tests.root_module.linkLibrary(quickjs_dep.artifact("quickjs-ng"));

    // ── curl-impersonate (statically linked into kuri binary) ────────────────
    // Vendored archives at vendor/curl-impersonate/<arch>-<os>/libcurl-impersonate.a
    // contain libcurl + BoringSSL + nghttp2 + brotli + zstd + libpsl, all
    // baked into one static library. Single FFI call site
    // (src/sandbox/curl_lib.zig) wraps it for the bundle replay sandbox.
    const ci_arch_os = pickCurlImpersonateTriple(target.result) catch null;
    if (ci_arch_os) |triple| {
        const ci_lib_path = b.path(b.fmt("vendor/curl-impersonate/{s}/libcurl-impersonate.a", .{triple}));
        const ci_include = b.path("vendor/curl-impersonate/include");
        for ([_]*std.Build.Step.Compile{ exe, unit_tests }) |compile_step| {
            compile_step.root_module.addObjectFile(ci_lib_path);
            compile_step.root_module.addIncludePath(ci_include);
            // libcurl-impersonate's BoringSSL needs system frameworks for DNS,
            // keychain access (cert validation fallback path), and SystemConfig.
            if (target.result.os.tag == .macos) {
                // BoringSSL is C++; need libc++ runtime.
                compile_step.root_module.link_libcpp = true;
                // Frameworks: cert validation, DNS resolution, keychain.
                compile_step.root_module.linkFramework("CoreFoundation", .{});
                compile_step.root_module.linkFramework("Security", .{});
                compile_step.root_module.linkFramework("SystemConfiguration", .{});
                // System libs: iconv (libidn punycode), ICU (uidna_*).
                compile_step.root_module.linkSystemLibrary("iconv", .{});
                compile_step.root_module.linkSystemLibrary("icucore", .{});
            }
            if (target.result.os.tag == .linux) {
                compile_step.root_module.link_libcpp = true;
                compile_step.root_module.linkSystemLibrary("z", .{});
                compile_step.root_module.linkSystemLibrary("pthread", .{});
                compile_step.root_module.linkSystemLibrary("dl", .{});
                compile_step.root_module.linkSystemLibrary("idn2", .{});
            }
        }
    } else {
        std.log.warn(
            "kuri build: no vendored libcurl-impersonate for {s}-{s}; sandbox will fall back to subprocess curl",
            .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) },
        );
    }

    // Sandbox-only test step (sidesteps pre-existing chrome/launcher test bitrot).
    const sandbox_test_mod = b.createModule(.{
        .root_source_file = b.path("src/sandbox_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sandbox_test_mod.addImport("quickjs", quickjs_dep.module("quickjs"));
    const sandbox_tests = b.addTest(.{ .root_module = sandbox_test_mod });
    sandbox_tests.root_module.linkLibrary(quickjs_dep.artifact("quickjs-ng"));
    // Same curl-impersonate wiring as exe + unit_tests so curl_lib symbols resolve.
    if (pickCurlImpersonateTriple(target.result) catch null) |triple| {
        sandbox_tests.root_module.addObjectFile(
            b.path(b.fmt("vendor/curl-impersonate/{s}/libcurl-impersonate.a", .{triple})),
        );
        sandbox_tests.root_module.addIncludePath(b.path("vendor/curl-impersonate/include"));
        if (target.result.os.tag == .macos) {
            sandbox_tests.root_module.link_libcpp = true;
            sandbox_tests.root_module.linkFramework("CoreFoundation", .{});
            sandbox_tests.root_module.linkFramework("Security", .{});
            sandbox_tests.root_module.linkFramework("SystemConfiguration", .{});
            sandbox_tests.root_module.linkSystemLibrary("iconv", .{});
            sandbox_tests.root_module.linkSystemLibrary("icucore", .{});
        }
        if (target.result.os.tag == .linux) {
            sandbox_tests.root_module.link_libcpp = true;
            sandbox_tests.root_module.linkSystemLibrary("z", .{});
            sandbox_tests.root_module.linkSystemLibrary("pthread", .{});
            sandbox_tests.root_module.linkSystemLibrary("dl", .{});
            sandbox_tests.root_module.linkSystemLibrary("idn2", .{});
        }
        sandbox_tests.root_module.linkSystemLibrary("z", .{});
    }
    const sandbox_test_step = b.step("test-sandbox", "Run sandbox-only tests");
    sandbox_test_step.dependOn(&b.addRunArtifact(sandbox_tests).step);

    // kuri-fetch standalone CLI (no Chrome dependency)
    const fetch_mod = b.createModule(.{
        .root_source_file = b.path("src/fetch_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fetch_mod.addImport("quickjs", quickjs_dep.module("quickjs"));
    const fetch_exe = b.addExecutable(.{
        .name = "kuri-fetch",
        .root_module = fetch_mod,
    });
    fetch_exe.root_module.linkLibrary(quickjs_dep.artifact("quickjs-ng"));
    b.installArtifact(fetch_exe);
    const run_fetch = b.addRunArtifact(fetch_exe);
    run_fetch.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_fetch.addArgs(args);
    }
    const fetch_step = b.step("fetch", "Run kuri-fetch standalone CLI");
    fetch_step.dependOn(&run_fetch.step);

    // kuri-fetch tests
    const fetch_test_mod = b.createModule(.{
        .root_source_file = b.path("src/fetch_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fetch_test_mod.addImport("quickjs", quickjs_dep.module("quickjs"));
    const fetch_tests = b.addTest(.{
        .root_module = fetch_test_mod,
    });
    fetch_tests.root_module.linkLibrary(quickjs_dep.artifact("quickjs-ng"));
    const run_fetch_tests = b.addRunArtifact(fetch_tests);
    const fetch_test_step = b.step("test-fetch", "Run kuri-fetch unit tests");
    fetch_test_step.dependOn(&run_fetch_tests.step);

    // kuri-browse interactive terminal browser
    const browse_exe = b.addExecutable(.{
        .name = "kuri-browse",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/browse_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(browse_exe);
    const run_browse = b.addRunArtifact(browse_exe);
    run_browse.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_browse.addArgs(args);
    }
    const browse_step = b.step("browse", "Run kuri-browse interactive terminal browser");
    browse_step.dependOn(&run_browse.step);

    // kuri-browse tests
    const browse_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/browse_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_browse_tests = b.addRunArtifact(browse_tests);
    const browse_test_step = b.step("test-browse", "Run kuri-browse unit tests");
    browse_test_step.dependOn(&run_browse_tests.step);

    // Benchmarks
    const bench = b.addExecutable(.{
        .name = "kuri-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // kuri-agent: scriptable agentic CLI (no HTTP server)
    const agent_exe = b.addExecutable(.{
        .name = "kuri-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/agent_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(agent_exe);
    const run_agent = b.addRunArtifact(agent_exe);
    run_agent.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_agent.addArgs(args);
    }
    const agent_step = b.step("agent", "Run kuri-agent scriptable CLI");
    agent_step.dependOn(&run_agent.step);

    // The CDP websocket transport (src/cdp/websocket.zig) calls into winsock
    // (ws2_32) on Windows. Link it for every binary that pulls in the CDP path.
    if (target.result.os.tag == .windows) {
        const ws_consumers = [_]*std.Build.Step.Compile{
            exe, unit_tests, merjs_e2e, agent_exe, browse_exe, fetch_exe, bench, sandbox_tests, fetch_tests, browse_tests,
        };
        for (ws_consumers) |compile_step| compile_step.root_module.linkSystemLibrary("ws2_32", .{});
    }
}

/// Map (cpu.arch, os.tag) → vendor/curl-impersonate subdir name.
/// Returns error.UnsupportedTriple if no archive is vendored for this target.
fn pickCurlImpersonateTriple(t: std.Target) ![]const u8 {
    return switch (t.os.tag) {
        .macos => switch (t.cpu.arch) {
            .aarch64 => "aarch64-macos",
            .x86_64 => "x86_64-macos",
            else => error.UnsupportedTriple,
        },
        .linux => switch (t.cpu.arch) {
            .aarch64 => "aarch64-linux-gnu",
            .x86_64 => "x86_64-linux-gnu",
            else => error.UnsupportedTriple,
        },
        else => error.UnsupportedTriple,
    };
}
