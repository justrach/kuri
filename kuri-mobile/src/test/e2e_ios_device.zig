//! End-to-end tests against a *physically attached* iPhone or iPad.
//!
//! Run with `zig build e2e-ios-device`. Separate from `e2e-ios` because it
//! needs hardware plugged in, paired and unlocked — a precondition no CI
//! runner can satisfy. With nothing attached it reports SKIP and exits 0.
//!
//! Scope is deliberately narrower than the simulator suite, and the narrowing
//! is itself under test. devicectl exposes lifecycle, installation and
//! inspection, but no screen capture and no UI hierarchy, so tap/swipe/uitree/
//! screenshot are simulator-only until XCUITest is wired up. Group C asserts
//! those refuse cleanly *while a real device is attached* — the case where a
//! caller most plausibly expects them to work, and so the case where quietly
//! doing nothing would be most misleading.
//!
//! Inspection runs against whatever is plugged in. The app-lifecycle group
//! needs a bundle id, and the install/uninstall half needs a signed .app that
//! the device trusts:
//!
//!     KURI_E2E_DEVICE_BUNDLE_ID=com.apple.Preferences \
//!     KURI_E2E_DEVICE_APP=/path/to/Build/Products/Debug-iphoneos/MyApp.app \
//!     KURI_E2E_DEVICE_UDID=00008140-000... \
//!     zig build e2e-ios-device
//!
//! KURI_E2E_DEVICE_UDID is optional; with one device attached it is
//! discovered from `ios list-devices`.

const std = @import("std");
const io = @import("io");
const h = @import("harness");

const run = h.run;
const report = h.report;
const skip = h.skip;
const expectCode = h.expectCode;
const expectContains = h.expectContains;
const getEnv = h.getEnv;
const finish = h.finish;

/// Pull the udid out of the first `device\t<udid>\t...` row that
/// `ios list-devices` printed. Simulator rows start with `simulator`, so the
/// prefix is what separates real hardware from an emulated device.
fn firstAttachedUdid(listing: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "device\t")) continue;
        const rest = line["device\t".len..];
        const end = std.mem.indexOfScalar(u8, rest, '\t') orelse rest.len;
        const udid = std.mem.trim(u8, rest[0..end], " \r");
        if (udid.len > 0) return udid;
    }
    return null;
}

/// Read the `pid=<N>` line that `ios launch --device` prints.
fn parsePid(out: []const u8) ?i64 {
    const marker = "pid=";
    const at = std.mem.indexOf(u8, out, marker) orelse return null;
    const rest = out[at + marker.len ..];
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(i64, rest[0..end], 10) catch null;
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
        io.writeStderr("usage: e2e-ios-device <path-to-kuri-mobile>\n");
        std.process.exit(2);
    }
    const bin = argv[1];

    // --- find a device ------------------------------------------------------
    const listing = try run(gpa, bin, &.{ "ios", "list-devices" });
    defer listing.deinit(gpa);

    const udid = getEnv("KURI_E2E_DEVICE_UDID") orelse firstAttachedUdid(listing.stdout) orelse {
        io.writeStdout("SKIP: no physically attached iOS device; nothing to test.\n");
        io.writeStdout("      Plug in an iPhone/iPad, unlock it, and trust this Mac.\n");
        return finish(arena);
    };
    io.printStdout(arena, "e2e-ios-device against {s}\n\n", .{udid});

    // --- Group A: inspection ------------------------------------------------
    // Everything here is read-only, so it runs against any attached device
    // without needing an app, a signature or a provisioning profile.
    io.writeStdout("inspection\n");
    {
        report(
            arena,
            std.mem.indexOf(u8, listing.stdout, "device\t") != null,
            "list-devices reports an attached physical device",
            "no device row in the listing",
        );
    }
    {
        const r = try run(gpa, bin, &.{ "ios", "device-info", "--udid", udid });
        defer r.deinit(gpa);
        expectCode(arena, "device-info exits 0", r, 0);
        // devicectl labels the hardware section this way in its info table; if
        // it comes back empty the command "succeeded" without telling us
        // anything, which is the failure mode this whole suite exists for.
        report(
            arena,
            r.stdout.len > 32,
            "device-info returns a non-empty report",
            "output was empty or near-empty",
        );
    }
    {
        const r = try run(gpa, bin, &.{ "ios", "displays", "--udid", udid });
        defer r.deinit(gpa);
        expectCode(arena, "displays exits 0", r, 0);
    }
    // A locked screen is the most common reason a device automation run does
    // nothing useful: SpringBoard refuses every launch with "the device was
    // not, or could not be, unlocked". That is the environment, not a bug, so
    // it gates the lifecycle group rather than failing it — and phones
    // re-lock on their own screen timeout, so a suite that ignored this would
    // go red purely for taking too long to get to the interesting part.
    var locked = false;
    {
        const r = try run(gpa, bin, &.{ "ios", "lock-state", "--udid", udid });
        defer r.deinit(gpa);
        expectCode(arena, "lock-state exits 0", r, 0);
        locked = std.mem.indexOf(u8, r.stdout, "passcodeRequired: true") != null;
    }
    {
        const r = try run(gpa, bin, &.{ "ios", "device-processes", "--udid", udid });
        defer r.deinit(gpa);
        expectCode(arena, "device-processes exits 0", r, 0);
    }
    {
        const r = try run(gpa, bin, &.{ "ios", "list-apps", "--device", "--udid", udid });
        defer r.deinit(gpa);
        expectCode(arena, "list-apps exits 0", r, 0);
    }

    // --- Group C: the documented limits, with hardware attached -------------
    // Placed before the lifecycle group so it runs even when no bundle id was
    // supplied — the registry claiming these are simulator-only is a promise
    // that should be checked on every run.
    io.writeStdout("\ndocumented limits (device attached)\n");
    const unsupported = [_]struct { name: []const u8, argv: []const []const u8 }{
        .{ .name = "screenshot", .argv = &.{ "ios", "screenshot", "--device", "--udid", udid, "/tmp/kuri-e2e-device.png" } },
        .{ .name = "tap", .argv = &.{ "ios", "tap", "--device", "--udid", udid, "10", "10" } },
        .{ .name = "swipe", .argv = &.{ "ios", "swipe", "--device", "--udid", udid, "10", "10", "20", "20" } },
        .{ .name = "uitree", .argv = &.{ "ios", "uitree", "--device", "--udid", udid } },
    };
    for (unsupported) |c| {
        const r = try run(gpa, bin, c.argv);
        defer r.deinit(gpa);
        const name = std.fmt.allocPrint(arena, "{s} --device refuses with exit 3", .{c.name}) catch c.name;
        expectCode(arena, name, r, 3);
        const why = std.fmt.allocPrint(arena, "{s} --device points at XCUITest", .{c.name}) catch c.name;
        expectContains(arena, why, r.stdout, "XCUITest");
    }

    // --- Group B: app lifecycle ---------------------------------------------
    io.writeStdout("\napp lifecycle\n");
    const bundle_id = getEnv("KURI_E2E_DEVICE_BUNDLE_ID") orelse {
        skip(arena, "install/launch/terminate/uninstall", "set KURI_E2E_DEVICE_BUNDLE_ID");
        return finish(arena);
    };
    if (locked) {
        skip(arena, "install/launch/terminate/uninstall", "device is locked — unlock it and keep the screen awake");
        return finish(arena);
    }
    const app_path = getEnv("KURI_E2E_DEVICE_APP");

    if (app_path) |p| {
        const r = try run(gpa, bin, &.{ "ios", "install", "--device", "--udid", udid, p });
        defer r.deinit(gpa);
        expectCode(arena, "install a signed .app onto the device", r, 0);
    } else {
        skip(arena, "install", "set KURI_E2E_DEVICE_APP to a signed .app");
    }

    {
        // Installation has to be *observable*, not merely un-errored. This is
        // the device equivalent of asking the simulator to list its apps.
        const r = try run(gpa, bin, &.{ "ios", "list-apps", "--device", "--udid", udid });
        defer r.deinit(gpa);
        expectCode(arena, "list-apps exits 0 before launch", r, 0);
        expectContains(arena, "list-apps shows the target bundle id", r.stdout, bundle_id);
    }

    // launch -> terminate by pid. This is the exact contract devicectl
    // enforces: `device process terminate` accepts `--pid` and nothing else,
    // so a launch that does not surface its pid leaves the app unstoppable.
    {
        const r = try run(gpa, bin, &.{ "ios", "launch", "--device", "--udid", udid, bundle_id });
        defer r.deinit(gpa);
        expectCode(arena, "launch on the device exits 0", r, 0);
        expectContains(arena, "launch reports the pid it started", r.stdout, "pid=");

        if (parsePid(r.stdout)) |pid| {
            const pid_str = std.fmt.allocPrint(arena, "{d}", .{pid}) catch "0";
            const t = try run(gpa, bin, &.{ "ios", "terminate", "--device", "--udid", udid, "--pid", pid_str });
            defer t.deinit(gpa);
            expectCode(arena, "terminate --pid stops the launched process", t, 0);
        } else {
            report(arena, false, "terminate --pid stops the launched process", "launch printed no parseable pid");
        }
    }

    // launch -> terminate by bundle id. The convenience path: kuri resolves
    // the bundle id to a running pid itself, because devicectl will not.
    {
        const r = try run(gpa, bin, &.{ "ios", "launch", "--device", "--udid", udid, bundle_id });
        defer r.deinit(gpa);
        expectCode(arena, "relaunch on the device exits 0", r, 0);

        const t = try run(gpa, bin, &.{ "ios", "terminate", "--device", "--udid", udid, bundle_id });
        defer t.deinit(gpa);
        expectCode(arena, "terminate by bundle id resolves a pid and stops it", t, 0);
        expectContains(arena, "terminate by bundle id reports which pid it stopped", t.stdout, "terminated pid=");
    }

    // Terminating something that is not running is a distinct, reportable
    // outcome (exit 4) — not a success, and not a crash.
    {
        const r = try run(gpa, bin, &.{ "ios", "terminate", "--device", "--udid", udid, "com.kuri.e2e.definitely.not.installed" });
        defer r.deinit(gpa);
        expectCode(arena, "terminate of an absent app exits 4", r, 4);
    }

    if (app_path != null) {
        {
            const r = try run(gpa, bin, &.{ "ios", "uninstall", "--device", "--udid", udid, bundle_id });
            defer r.deinit(gpa);
            expectCode(arena, "uninstall removes the app", r, 0);
        }
        {
            // The mirror of the install assertion: removal has to be visible
            // in the inventory, or "uninstalled" is just an exit code.
            const r = try run(gpa, bin, &.{ "ios", "list-apps", "--device", "--udid", udid });
            defer r.deinit(gpa);
            expectCode(arena, "list-apps exits 0 after uninstall", r, 0);
            const gone = std.mem.indexOf(u8, r.stdout, bundle_id) == null;
            report(arena, gone, "list-apps no longer shows the uninstalled bundle id", "bundle id still listed");
        }
    } else {
        skip(arena, "uninstall", "set KURI_E2E_DEVICE_APP to a signed .app");
    }

    return finish(arena);
}

// --- tests ------------------------------------------------------------------
// The parsing helpers run without hardware, so they are checked here rather
// than only exercised on a machine with a phone plugged into it.

test "firstAttachedUdid picks the device row, not a simulator row" {
    const listing =
        "simulator\tAAAA-1111\tShutdown\tiPhone 17 Pro\n" ++
        "simulator\tBBBB-2222\tBooted\tiPhone Air\n" ++
        "device\t00008140-CAFE\tUSB\tpid=4776\n";
    try std.testing.expectEqualStrings("00008140-CAFE", firstAttachedUdid(listing).?);
}

test "firstAttachedUdid returns null when only simulators are listed" {
    const listing = "simulator\tAAAA-1111\tShutdown\tiPhone 17 Pro\n";
    try std.testing.expect(firstAttachedUdid(listing) == null);
}

test "parsePid reads the launch pid line" {
    try std.testing.expectEqual(@as(?i64, 867), parsePid("pid=867\n"));
    try std.testing.expectEqual(@as(?i64, 12), parsePid("noise\npid=12\nmore\n"));
}

test "parsePid rejects output with no pid" {
    try std.testing.expect(parsePid("") == null);
    try std.testing.expect(parsePid("pid=\n") == null);
    try std.testing.expect(parsePid("launched ok\n") == null);
}
