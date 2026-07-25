//! End-to-end tests that drive the built binary against the local machine.
//!
//! Run with `zig build e2e-ios`. These are deliberately *not* part of
//! `zig build test`: they shell out to the real Xcode toolchain and, for most
//! cases, a booted simulator.
//!
//! The suite is built to be a CI gate, which means every case either runs or
//! reports SKIP with a reason — it never fails for a missing precondition.
//! Three capabilities are probed up front and gate their own groups:
//!
//!   * Xcode toolchain    — without it, the device-path group cannot run.
//!   * booted simulator   — without one, the simulator groups cannot run.
//!   * Accessibility grant — without it, uitree/find/wait-for-ui cannot run.
//!
//! The Accessibility gate is the one that matters for CI: those commands read
//! the Simulator's AX tree, and a GitHub runner has no TCC grant to give. That
//! is a missing permission, not a defect, so it skips rather than fails.
//!
//! By default it drives Settings (`com.apple.Preferences`), which ships on
//! every simulator, so the suite is reproducible on any machine. Point it at
//! your own app instead with:
//!
//!     KURI_E2E_BUNDLE_ID=com.amiai.baiizy \
//!     KURI_E2E_LABEL="Hello, world!" \
//!     KURI_E2E_APP=/path/to/Build/Products/Debug-iphonesimulator/baiizy.app \
//!     zig build e2e-ios
//!
//! Only non-input commands are exercised. `tap`/`swipe`/`gesture` post real
//! CGEvents, which seize the host cursor and focus — unacceptable in a suite
//! someone might run while working.

const std = @import("std");
const io = @import("io");
const h = @import("harness");

const run = h.run;
const report = h.report;
const skip = h.skip;
const expectCode = h.expectCode;
const expectNonZero = h.expectNonZero;
const expectContains = h.expectContains;
const expectExcludes = h.expectExcludes;
const getEnv = h.getEnv;
const finish = h.finish;

/// A udid that cannot exist, for asserting how the device path fails.
const fake_udid = "00000000-DEADBEEFDEADBEEF";

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const argv = try init.args.toSlice(arena);
    if (argv.len < 2) {
        io.writeStderr("usage: e2e-ios <path-to-kuri-mobile>\n");
        std.process.exit(2);
    }
    const bin = argv[1];

    const bundle_id = getEnv("KURI_E2E_BUNDLE_ID") orelse "com.apple.Preferences";
    const label = getEnv("KURI_E2E_LABEL") orelse "General";
    const app_path = getEnv("KURI_E2E_APP");

    io.printStdout(arena, "e2e-ios against {s} (label: '{s}')\n\n", .{ bundle_id, label });

    // --- Group 1: no device required ---------------------------------------
    io.writeStdout("registry (no device needed)\n");
    inline for (.{ "ios", "android" }) |platform| {
        const r = try run(gpa, bin, &.{ platform, "tools", "--json" });
        defer r.deinit(gpa);
        expectCode(arena, platform ++ " tools --json exits 0", r, 0);

        // Must be valid JSON, and every entry must carry the fields a caller
        // needs to build an invocation.
        if (std.json.parseFromSlice(std.json.Value, gpa, r.stdout, .{})) |parsed| {
            defer parsed.deinit();
            const tools = parsed.value.object.get("tools").?.array;
            var complete = tools.items.len > 0;
            for (tools.items) |t| {
                if (t.object.get("name") == null or
                    t.object.get("scope") == null or
                    t.object.get("summary") == null) complete = false;
            }
            report(arena, complete, platform ++ " tools --json entries are complete", "missing name/scope/summary");
        } else |_| {
            report(arena, false, platform ++ " tools --json parses", "invalid JSON");
        }
    }

    // The registry is what an agent reads to decide what it may call, so a
    // command silently losing its device scope is a correctness bug in the
    // contract even when every command still works.
    var xcode_ok = false;
    {
        const r = try run(gpa, bin, &.{"doctor"});
        defer r.deinit(gpa);
        // 0 = healthy, 3 = blocking problems found; both mean doctor ran.
        const ok = r.code == 0 or r.code == 3;
        report(arena, ok, "doctor runs and reports", "unexpected exit");
        expectContains(arena, "doctor covers iOS and Android", r.stdout, "adb server");

        xcode_ok = std.mem.indexOf(u8, r.stdout, "developer dir: /") != null;
    }

    // --- Group 2: real-device command contract (no device needed) ----------
    //
    // Every case here is a regression guard for the class of bug shipped
    // before 0.4.10: `--device` commands that resolved `devicectl` through
    // xcode-select, never checked the exit status, and so reported success
    // while doing nothing. A fake udid is enough to pin the whole class —
    // what matters is that failure is *loud*, and that the invocation
    // devicectl receives is well-formed.
    io.writeStdout("\nreal-device command contract (no device needed)\n");
    if (!xcode_ok) {
        skip(arena, "device-path cases", "no Xcode toolchain resolved");
    } else {
        // Anything routed at a device that does not exist must fail.
        const device_cases = [_]struct { name: []const u8, argv: []const []const u8 }{
            .{ .name = "launch", .argv = &.{ "ios", "launch", "--device", "--udid", fake_udid, "com.foo" } },
            .{ .name = "install", .argv = &.{ "ios", "install", "--device", "--udid", fake_udid, "/tmp/kuri-e2e-absent.app" } },
            .{ .name = "uninstall", .argv = &.{ "ios", "uninstall", "--device", "--udid", fake_udid, "com.foo" } },
            .{ .name = "list-apps", .argv = &.{ "ios", "list-apps", "--device", "--udid", fake_udid } },
            .{ .name = "device-info", .argv = &.{ "ios", "device-info", "--udid", fake_udid } },
            .{ .name = "device-processes", .argv = &.{ "ios", "device-processes", "--udid", fake_udid } },
            .{ .name = "lock-state", .argv = &.{ "ios", "lock-state", "--udid", fake_udid } },
            .{ .name = "displays", .argv = &.{ "ios", "displays", "--udid", fake_udid } },
        };
        for (device_cases) |c| {
            const r = try run(gpa, bin, c.argv);
            defer r.deinit(gpa);
            const name = std.fmt.allocPrint(arena, "{s} --device fails loudly on an absent device", .{c.name}) catch c.name;
            expectNonZero(arena, name, r);
        }

        // The invocation itself has to be well-formed. Before 0.4.11 this
        // built `devicectl device process terminate --device <udid> <bundle>`,
        // but devicectl's terminate takes `--pid` and no bundle id at all, so
        // it could only ever fail with a usage error. Asserting the *absence*
        // of devicectl's argument-parser complaint is what distinguishes
        // "the device is missing" from "we called devicectl wrong".
        {
            const r = try run(gpa, bin, &.{ "ios", "terminate", "--device", "--udid", fake_udid, "--pid", "1234" });
            defer r.deinit(gpa);
            expectNonZero(arena, "terminate --pid fails loudly on an absent device", r);
            expectExcludes(arena, "terminate --pid is a well-formed devicectl call", r.stdout, "Missing expected argument");
            expectExcludes(arena, "terminate --pid is not a devicectl usage error", r.stdout, "Usage: devicectl");
        }
        {
            const r = try run(gpa, bin, &.{ "ios", "terminate", "--device", "--udid", fake_udid, "com.foo" });
            defer r.deinit(gpa);
            expectNonZero(arena, "terminate by bundle id fails loudly on an absent device", r);
            expectExcludes(arena, "terminate by bundle id is a well-formed devicectl call", r.stdout, "Missing expected argument");
        }

        // Missing arguments are user error (exit 2), distinct from a tool
        // failure (exit 1) — a script needs to tell those apart.
        {
            const r = try run(gpa, bin, &.{ "ios", "launch", "--device", "com.foo" });
            defer r.deinit(gpa);
            expectCode(arena, "launch --device without --udid exits 2", r, 2);
            expectContains(arena, "launch --device names the missing flag", r.stdout, "--udid");
        }
        {
            const r = try run(gpa, bin, &.{ "ios", "terminate", "--device", "--udid", fake_udid });
            defer r.deinit(gpa);
            expectCode(arena, "terminate --device without a target exits 2", r, 2);
            expectContains(arena, "terminate --device names the missing target", r.stdout, "--pid");
        }

        // Commands devicectl genuinely cannot do must refuse up front (exit 3)
        // rather than fail obscurely somewhere inside the toolchain.
        const unsupported = [_]struct { name: []const u8, argv: []const []const u8 }{
            .{ .name = "screenshot", .argv = &.{ "ios", "screenshot", "--device", "--udid", fake_udid, "/tmp/kuri-e2e-nope.png" } },
            .{ .name = "tap", .argv = &.{ "ios", "tap", "--device", "--udid", fake_udid, "10", "10" } },
            .{ .name = "uitree", .argv = &.{ "ios", "uitree", "--device", "--udid", fake_udid } },
        };
        for (unsupported) |c| {
            const r = try run(gpa, bin, c.argv);
            defer r.deinit(gpa);
            const name = std.fmt.allocPrint(arena, "{s} --device refuses with exit 3", .{c.name}) catch c.name;
            expectCode(arena, name, r, 3);
            const why = std.fmt.allocPrint(arena, "{s} --device explains why", .{c.name}) catch c.name;
            expectContains(arena, why, r.stdout, "XCUITest");
        }
    }

    // --- Is a simulator available? -----------------------------------------
    const devices = try run(gpa, bin, &.{ "ios", "list-devices" });
    defer devices.deinit(gpa);
    if (std.mem.indexOf(u8, devices.stdout, "Booted") == null) {
        io.writeStdout("\nSKIP: no booted simulator; device-backed cases not run.\n");
        return finish(arena);
    }

    io.writeStdout("\ndevice-backed\n");

    // --- Group 3: install + launch ------------------------------------------
    if (app_path) |p| {
        const r = try run(gpa, bin, &.{ "ios", "install", p });
        defer r.deinit(gpa);
        expectCode(arena, "install the app bundle", r, 0);
    }
    {
        const r = try run(gpa, bin, &.{ "ios", "launch", bundle_id });
        defer r.deinit(gpa);
        expectCode(arena, "launch by bundle id", r, 0);
    }

    // --- Group 4: observation via the accessibility tree ---------------------
    //
    // Everything below reads the Simulator's AX hierarchy, which needs two
    // things this process may not have: a macOS Accessibility grant, and
    // Simulator.app actually running (a `simctl boot` alone leaves the runtime
    // up but the window absent). Neither is a regression when missing, and a
    // CI runner can supply neither, so both are probed and skipped rather than
    // failed.
    //
    // Probed here rather than reused from the earlier doctor run because
    // Simulator.app's state can change between the two points — booting an app
    // is exactly the sort of thing that starts it.
    var ax_ok = false;
    var sim_app_ok = false;
    {
        const r = try run(gpa, bin, &.{"doctor"});
        defer r.deinit(gpa);
        ax_ok = std.mem.indexOf(u8, r.stdout, "accessibility: this process is trusted") != null;
        // Specifically the window, not just the process: `simctl boot` leaves
        // Simulator.app running with nothing on screen, and the tree hangs
        // off a window.
        sim_app_ok = std.mem.indexOf(u8, r.stdout, "window on screen") != null;
    }
    if (!ax_ok) {
        skip(arena, "wait-for-ui / uitree / find", "no Accessibility grant for this process");
    } else if (!sim_app_ok) {
        skip(arena, "wait-for-ui / uitree / find", "Simulator.app has no window on screen; try `ios open-sim`");
    } else {
        {
            // The app needs a moment to render before its tree is populated; this
            // is exactly what wait-for-ui exists for, so use it as the barrier.
            const r = try run(gpa, bin, &.{ "ios", "wait-for-ui", "--label", label, "--timeout", "20000" });
            defer r.deinit(gpa);
            expectCode(arena, "wait-for-ui finds a present element", r, 0);
        }
        {
            const r = try run(gpa, bin, &.{ "ios", "uitree" });
            defer r.deinit(gpa);
            expectCode(arena, "uitree exits 0", r, 0);
            expectContains(arena, "uitree contains the expected label", r.stdout, label);
            expectContains(arena, "uitree reports device-pixel bounds", r.stdout, "@");
        }
        {
            const r = try run(gpa, bin, &.{ "ios", "find", "--label", label });
            defer r.deinit(gpa);
            expectCode(arena, "find locates a present element", r, 0);
            expectContains(arena, "find emits a tap-ready centroid", r.stdout, "tap=");
        }
        {
            const r = try run(gpa, bin, &.{ "ios", "find", "--label", "kuriE2ENoSuchElement" });
            defer r.deinit(gpa);
            // Non-zero on no match is what lets `find` be used as an assertion.
            expectCode(arena, "find exits 4 when nothing matches", r, 4);
        }

        // --- Group 5: wait-for-ui semantics + timeout regression ------------
        {
            const r = try run(gpa, bin, &.{ "ios", "wait-for-ui", "--label", "kuriE2ENoSuchElement", "--absent", "--timeout", "5000" });
            defer r.deinit(gpa);
            expectCode(arena, "wait-for-ui --absent passes for a missing element", r, 0);
        }
        {
            // Regression guard for the 0.4.7 bug: the deadline used to sum sleep
            // intervals while ignoring each poll's cost, so a 3s timeout waited
            // ~13.5s. Allow headroom for one final in-flight poll, but fail if we
            // drift back toward a multiple of the request.
            const want_ms: i64 = 3000;
            const r = try run(gpa, bin, &.{ "ios", "wait-for-ui", "--label", "kuriE2ENoSuchElement", "--timeout", "3000" });
            defer r.deinit(gpa);
            expectCode(arena, "wait-for-ui times out with exit 4", r, 4);

            const ok = r.elapsed_ms >= want_ms and r.elapsed_ms < want_ms * 3;
            const d = std.fmt.allocPrint(arena, "took {d}ms for a {d}ms timeout", .{ r.elapsed_ms, want_ms }) catch "bad timing";
            report(arena, ok, "wait-for-ui honours its wall-clock deadline", d);
        }
    }

    // --- Group 6: screenshot -------------------------------------------------
    // simctl renders this itself, so unlike the AX group it runs without any
    // Accessibility grant — which makes it the main visual check CI can do.
    {
        const path = "/tmp/kuri-e2e-shot.png";
        const r = try run(gpa, bin, &.{ "ios", "screenshot", path });
        defer r.deinit(gpa);
        expectCode(arena, "screenshot exits 0", r, 0);

        // Verify it is a real PNG, not an empty or truncated file.
        if (std.c.fopen(path, "rb")) |fh| {
            defer _ = std.c.fclose(fh);
            var magic: [8]u8 = undefined;
            const n = std.c.fread(&magic, 1, 8, fh);
            const ok = n == 8 and std.mem.eql(u8, magic[0..8], "\x89PNG\r\n\x1a\n");
            report(arena, ok, "screenshot writes a valid PNG", "bad PNG magic");
        } else {
            report(arena, false, "screenshot writes a valid PNG", "file not created");
        }
    }

    // --- Group 7: simulator state, no Accessibility needed -------------------
    // These all route through simctl, so they are exactly the coverage a CI
    // runner *can* provide beyond install/launch/screenshot.
    {
        const r = try run(gpa, bin, &.{ "ios", "list-apps" });
        defer r.deinit(gpa);
        expectCode(arena, "list-apps exits 0", r, 0);
        expectContains(arena, "list-apps includes the target bundle id", r.stdout, bundle_id);
    }
    {
        // Pinning the status bar is what makes screenshots comparable between
        // runs, so it needs to survive both directions.
        const r = try run(gpa, bin, &.{ "ios", "status-bar", "override", "--time", "9:41" });
        defer r.deinit(gpa);
        expectCode(arena, "status-bar override exits 0", r, 0);
    }
    {
        const r = try run(gpa, bin, &.{ "ios", "status-bar", "clear" });
        defer r.deinit(gpa);
        expectCode(arena, "status-bar clear exits 0", r, 0);
    }
    {
        const r = try run(gpa, bin, &.{ "ios", "ui", "appearance", "dark" });
        defer r.deinit(gpa);
        expectCode(arena, "ui appearance dark exits 0", r, 0);
    }
    {
        const r = try run(gpa, bin, &.{ "ios", "ui", "appearance" });
        defer r.deinit(gpa);
        expectCode(arena, "ui appearance reads back", r, 0);
        expectContains(arena, "ui appearance reports the value just set", r.stdout, "dark");
    }
    {
        const r = try run(gpa, bin, &.{ "ios", "ui", "appearance", "light" });
        defer r.deinit(gpa);
        expectCode(arena, "ui appearance light exits 0", r, 0);
    }
    {
        const r = try run(gpa, bin, &.{ "ios", "set-location", "37.7749", "-122.4194" });
        defer r.deinit(gpa);
        expectCode(arena, "set-location exits 0", r, 0);
    }
    {
        const r = try run(gpa, bin, &.{ "ios", "reset-location" });
        defer r.deinit(gpa);
        expectCode(arena, "reset-location exits 0", r, 0);
    }
    {
        // `log` exists to back assertions, which means it must terminate on
        // its own rather than stream forever.
        const r = try run(gpa, bin, &.{ "ios", "log", "--last", "10s" });
        defer r.deinit(gpa);
        expectCode(arena, "log --last returns bounded output", r, 0);
    }
    {
        const r = try run(gpa, bin, &.{ "ios", "terminate", bundle_id });
        defer r.deinit(gpa);
        expectCode(arena, "terminate by bundle id", r, 0);
    }

    return finish(arena);
}
