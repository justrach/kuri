const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Single source of truth for the version: build.zig.zon.
    // Exposed to source via `@import("build_options").version` so the version
    // string never has to be hand-edited in src/*.zig on a release.
    const version = @import("build.zig.zon").version;
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    // nanostore: encrypted secret/connection vault (sibling library), used by
    // the `kuri connect` feature for persisted, encrypted browser logins.
    const nanostore_dep = b.dependency("nanostore", .{
        .target = target,
        .optimize = optimize,
    });
    const nanostore_mod = nanostore_dep.module("nanostore");

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
    exe.root_module.addOptions("build_options", build_options);
    exe.root_module.addImport("nanostore", nanostore_mod);

    b.installArtifact(exe);

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
    unit_tests.root_module.addOptions("build_options", build_options);
    unit_tests.root_module.addImport("nanostore", nanostore_mod);
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
    fetch_exe.root_module.addOptions("build_options", build_options);
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
    fetch_tests.root_module.addOptions("build_options", build_options);
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
    browse_exe.root_module.addOptions("build_options", build_options);
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
    browse_tests.root_module.addOptions("build_options", build_options);
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
    agent_exe.root_module.addOptions("build_options", build_options);
    agent_exe.root_module.addImport("nanostore", nanostore_mod);
    b.installArtifact(agent_exe);
    const run_agent = b.addRunArtifact(agent_exe);
    run_agent.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_agent.addArgs(args);
    }
    const agent_step = b.step("agent", "Run kuri-agent scriptable CLI");
    agent_step.dependOn(&run_agent.step);

    // kuri-mcp: Model Context Protocol (stdio) server that forwards to the kuri
    // HTTP API, exposing chrome-devtools-mcp-compatible tools with kuri's
    // compact (token-efficient) accessibility snapshot.
    const mcp_exe = b.addExecutable(.{
        .name = "kuri-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mcp_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    mcp_exe.root_module.addOptions("build_options", build_options);
    b.installArtifact(mcp_exe);
    const run_mcp = b.addRunArtifact(mcp_exe);
    run_mcp.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_mcp.addArgs(args);
    const mcp_step = b.step("mcp", "Run kuri-mcp MCP server");
    mcp_step.dependOn(&run_mcp.step);

    // kuri-connect-broker: key-holding broker daemon for the `connect` feature.
    // Holds KURI_VAULT_PASSPHRASE so the agent never does, and exposes only
    // inject/list/save/delete over a token-gated loopback API.
    const broker_exe = b.addExecutable(.{
        .name = "kuri-connect-broker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/connect_broker.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    broker_exe.root_module.addOptions("build_options", build_options);
    broker_exe.root_module.addImport("nanostore", nanostore_mod);
    b.installArtifact(broker_exe);
    const run_broker = b.addRunArtifact(broker_exe);
    run_broker.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_broker.addArgs(args);
    const broker_step = b.step("broker", "Run kuri-connect-broker daemon");
    broker_step.dependOn(&run_broker.step);

    // kuri-gateway: managed-service control plane (Track 1). Spawns/leases one
    // `kuri` worker (its own Chrome) per session, exposes an async task API, and
    // reverse-proxies the data plane scoped by session_id. Pulls in build_options
    // transitively via server/response.zig -> telemetry.zig.
    const gateway_exe = b.addExecutable(.{
        .name = "kuri-gateway",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gateway_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    gateway_exe.root_module.addOptions("build_options", build_options);
    b.installArtifact(gateway_exe);
    const run_gateway = b.addRunArtifact(gateway_exe);
    run_gateway.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_gateway.addArgs(args);
    const gateway_step = b.step("gateway", "Run kuri-gateway control plane");
    gateway_step.dependOn(&run_gateway.step);

    // kuri-gateway unit tests (session table, auth helpers).
    const gateway_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gateway_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    gateway_tests.root_module.addOptions("build_options", build_options);
    const run_gateway_tests = b.addRunArtifact(gateway_tests);
    const gateway_test_step = b.step("test-gateway", "Run kuri-gateway unit tests");
    gateway_test_step.dependOn(&run_gateway_tests.step);
}
