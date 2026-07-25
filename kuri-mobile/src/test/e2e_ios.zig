//! End-to-end tests that drive a real iOS Simulator through the built binary.
//!
//! Run with `zig build e2e-ios`. These are deliberately *not* part of
//! `zig build test`: they need a booted simulator, which CI does not have.
//! When no simulator is booted the suite reports SKIP and exits 0, so it can
//! sit in a pipeline without becoming a flaky gate.
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

var passed: usize = 0;
var failed: usize = 0;

const Result = struct {
    stdout: []u8,
    code: i32,
    elapsed_ms: i64,

    fn deinit(self: Result, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
    }
};

/// Invoke the built kuri-mobile with `args`, capturing output and timing.
fn run(gpa: std.mem.Allocator, bin: []const u8, args: []const []const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bin);
    try argv.appendSlice(gpa, args);

    const start = io.monotonicMs();
    const r = try io.runCommand(gpa, argv.items, 32 * 1024 * 1024);
    return .{
        .stdout = r.stdout,
        .code = (r.term >> 8) & 0xFF,
        .elapsed_ms = io.monotonicMs() - start,
    };
}

fn report(arena: std.mem.Allocator, ok: bool, name: []const u8, detail: []const u8) void {
    if (ok) {
        passed += 1;
        io.printStdout(arena, "  ok   {s}\n", .{name});
    } else {
        failed += 1;
        io.printStdout(arena, "  FAIL {s}: {s}\n", .{ name, detail });
    }
}

fn expectCode(arena: std.mem.Allocator, name: []const u8, r: Result, want: i32) void {
    if (r.code == want) return report(arena, true, name, "");
    const d = std.fmt.allocPrint(arena, "exit {d}, wanted {d}", .{ r.code, want }) catch "exit mismatch";
    report(arena, false, name, d);
}

fn expectContains(arena: std.mem.Allocator, name: []const u8, haystack: []const u8, needle: []const u8) void {
    if (std.mem.indexOf(u8, haystack, needle) != null) return report(arena, true, name, "");
    const d = std.fmt.allocPrint(arena, "output did not contain '{s}'", .{needle}) catch "missing substring";
    report(arena, false, name, d);
}

fn getEnv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

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

    {
        const r = try run(gpa, bin, &.{"doctor"});
        defer r.deinit(gpa);
        // 0 = healthy, 3 = blocking problems found; both mean doctor ran.
        const ok = r.code == 0 or r.code == 3;
        report(arena, ok, "doctor runs and reports", "unexpected exit");
        expectContains(arena, "doctor covers iOS and Android", r.stdout, "adb server");
    }

    // --- Is a simulator available? -----------------------------------------
    const devices = try run(gpa, bin, &.{ "ios", "list-devices" });
    defer devices.deinit(gpa);
    if (std.mem.indexOf(u8, devices.stdout, "Booted") == null) {
        io.writeStdout("\nSKIP: no booted simulator; device-backed cases not run.\n");
        io.printStdout(arena, "\n{d} passed, {d} failed\n", .{ passed, failed });
        std.process.exit(if (failed == 0) 0 else 1);
    }

    io.writeStdout("\ndevice-backed\n");

    // --- Group 2: install + launch ------------------------------------------
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

    // --- Group 3: observation -----------------------------------------------
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

    // --- Group 4: wait-for-ui semantics + timeout regression ----------------
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

    // --- Group 5: screenshot -------------------------------------------------
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

    io.printStdout(arena, "\n{d} passed, {d} failed\n", .{ passed, failed });
    std.process.exit(if (failed == 0) 0 else 1);
}
