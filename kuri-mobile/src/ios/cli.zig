//! `kuri-mobile ios <cmd>` dispatcher.

const std = @import("std");
const builtin = @import("builtin");
const simctl = @import("simctl.zig");
const usbmux = @import("usbmux.zig");
const devicectl = @import("devicectl.zig");
const sim_input = @import("sim_input.zig");
const sim_window = @import("sim_window.zig");
const io = @import("../common/io.zig");

pub fn run(gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len == 0) {
        try printUsage();
        return 1;
    }
    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "list-devices") or std.mem.eql(u8, sub, "devices")) {
        return cmdListDevices(gpa);
    }

    var udid_opt: ?[]const u8 = null;
    // Default to simulator. Use --device for real-device commands; that path
    // requires --udid and goes through devicectl.
    var simulator: bool = true;
    var idx: usize = 0;
    while (idx < rest.len and std.mem.startsWith(u8, rest[idx], "--")) {
        if (std.mem.eql(u8, rest[idx], "--udid")) {
            if (idx + 1 >= rest.len) return errMissing("--udid");
            udid_opt = rest[idx + 1];
            idx += 2;
        } else if (std.mem.eql(u8, rest[idx], "--simulator")) {
            simulator = true;
            idx += 1;
        } else if (std.mem.eql(u8, rest[idx], "--device")) {
            simulator = false;
            idx += 1;
        } else {
            io.writeStderr("unknown flag\n");
            return 2;
        }
    }
    const cmd_args = rest[idx..];

    if (std.mem.eql(u8, sub, "launch")) {
        if (cmd_args.len < 1) return errMissing("bundle-id");
        // Default behavior: target the booted sim if no --udid given.
        // Real-device launch always needs --udid (devicectl can't guess).
        if (!simulator) {
            const udid = udid_opt orelse return errMissing("--udid");
            try devicectl.launch(gpa, udid, cmd_args[0]);
            return 0;
        }
        const udid = udid_opt orelse try resolveBootedSim(gpa);
        defer if (udid_opt == null) gpa.free(udid);
        try simctl.Sim.init(udid).launch(gpa, cmd_args[0]);
        return 0;
    }
    if (std.mem.eql(u8, sub, "terminate")) {
        if (cmd_args.len < 1) return errMissing("bundle-id");
        if (!simulator) {
            const udid = udid_opt orelse return errMissing("--udid");
            try devicectl.terminate(gpa, udid, cmd_args[0]);
            return 0;
        }
        const udid = udid_opt orelse try resolveBootedSim(gpa);
        defer if (udid_opt == null) gpa.free(udid);
        try simctl.Sim.init(udid).terminate(gpa, cmd_args[0]);
        return 0;
    }
    if (std.mem.eql(u8, sub, "openurl") or std.mem.eql(u8, sub, "navigate")) {
        if (cmd_args.len < 1) return errMissing("url");
        const udid = udid_opt orelse try resolveBootedSim(gpa);
        defer if (udid_opt == null) gpa.free(udid);
        try simctl.Sim.init(udid).openUrl(gpa, cmd_args[0]);
        return 0;
    }
    if (std.mem.eql(u8, sub, "boot")) {
        const udid = udid_opt orelse return errMissing("--udid");
        try simctl.Sim.init(udid).boot(gpa);
        return 0;
    }
    if (std.mem.eql(u8, sub, "shutdown")) {
        const udid = udid_opt orelse return errMissing("--udid");
        try simctl.Sim.init(udid).shutdown(gpa);
        return 0;
    }
    if (std.mem.eql(u8, sub, "screenshot")) {
        const path = if (cmd_args.len >= 1) cmd_args[0] else "screenshot.png";
        if (!simulator and udid_opt != null) {
            io.writeStderr("screenshot on real iOS devices requires XCUITest; not supported in v1. Use --simulator.\n");
            return 3;
        }
        const udid = udid_opt orelse try resolveBootedSim(gpa);
        defer if (udid_opt == null) gpa.free(udid);
        try simctl.Sim.init(udid).screenshot(gpa, path);
        return 0;
    }
    if (std.mem.eql(u8, sub, "list-apps")) {
        const udid = udid_opt orelse return errMissing("--udid");
        if (!simulator) {
            io.writeStderr("list-apps on real device not supported in v1. Use --simulator.\n");
            return 3;
        }
        const out = try simctl.Sim.init(udid).listApps(gpa);
        defer gpa.free(out);
        io.writeStdout(out);
        return 0;
    }

    if (std.mem.eql(u8, sub, "tap")) return cmdTap(gpa, udid_opt, simulator, cmd_args);
    if (std.mem.eql(u8, sub, "swipe") or std.mem.eql(u8, sub, "scroll") or std.mem.eql(u8, sub, "pan")) return cmdSwipe(gpa, udid_opt, simulator, cmd_args);
    if (std.mem.eql(u8, sub, "type")) return cmdType(gpa, udid_opt, simulator, cmd_args);
    if (std.mem.eql(u8, sub, "uitree")) {
        // Honest scope: macOS AX on Simulator.app only exposes window chrome,
        // not the running iOS app's a11y tree. That bridge is XCUITest-only.
        io.writeStderr("uitree on iOS requires XCUITest (driverless mode does not have a11y access to the iOS app). Use Accessibility Inspector or run via XCUITest.\n");
        return 3;
    }

    try printUsage();
    return 1;
}

// --- tap / swipe / type implementations (Simulator only) -------------------
// Coordinates are *device pixels* matching `xcrun simctl io ... screenshot`,
// so the same numbers you'd plug into `adb shell input tap` work here.

/// Returns null if OK, or an exit code if the command should bail without
/// raising a Zig error (so the user just sees the message + a clean status).
fn guardSim(simulator: bool) ?u8 {
    if (builtin.os.tag != .macos) {
        io.writeStderr("ios input commands are macOS-only.\n");
        return 3;
    }
    if (!simulator) {
        io.writeStderr("tap/swipe/type on real iOS devices requires XCUITest; not supported in v1. Use --simulator.\n");
        return 3;
    }
    return null;
}

fn parseF64(s: []const u8) !f64 {
    if (std.fmt.parseFloat(f64, s)) |v| return v else |_| {}
    const i = try std.fmt.parseInt(i64, s, 10);
    return @floatFromInt(i);
}

const Resolved = struct {
    udid: []const u8,
    owned: bool, // true => caller must free .udid

    fn deinit(self: Resolved, gpa: std.mem.Allocator) void {
        if (self.owned) gpa.free(self.udid);
    }
};

fn resolveUdid(gpa: std.mem.Allocator, udid_opt: ?[]const u8) !Resolved {
    if (udid_opt) |u| return .{ .udid = u, .owned = false };
    const u = try resolveBootedSim(gpa);
    return .{ .udid = u, .owned = true };
}

fn prepSimAndPoint(
    gpa: std.mem.Allocator,
    udid: []const u8,
    dev_x: f64,
    dev_y: f64,
) !sim_input.CGPoint {
    try sim_window.activate(gpa);
    const win = try sim_window.frontWindowRect(gpa);
    const px = try sim_window.devicePixelSize(gpa, udid);
    return sim_window.deviceToScreen(win, px, dev_x, dev_y);
}

fn cmdTap(gpa: std.mem.Allocator, udid_opt: ?[]const u8, simulator: bool, args: []const []const u8) !u8 {
    if (guardSim(simulator)) |code| return code;
    if (args.len < 2) return errMissing("x y");
    const x = try parseF64(args[0]);
    const y = try parseF64(args[1]);
    const r = try resolveUdid(gpa, udid_opt);
    defer r.deinit(gpa);
    const p = try prepSimAndPoint(gpa, r.udid, x, y);
    sim_input.tap(p);
    return 0;
}

fn cmdSwipe(gpa: std.mem.Allocator, udid_opt: ?[]const u8, simulator: bool, args: []const []const u8) !u8 {
    if (guardSim(simulator)) |code| return code;
    if (args.len < 4) return errMissing("x1 y1 x2 y2 [duration_ms]");
    const x1 = try parseF64(args[0]);
    const y1 = try parseF64(args[1]);
    const x2 = try parseF64(args[2]);
    const y2 = try parseF64(args[3]);
    const dur: u64 = if (args.len >= 5) try std.fmt.parseInt(u64, args[4], 10) else 300;
    const r = try resolveUdid(gpa, udid_opt);
    defer r.deinit(gpa);
    try sim_window.activate(gpa);
    const win = try sim_window.frontWindowRect(gpa);
    const px = try sim_window.devicePixelSize(gpa, r.udid);
    const a = sim_window.deviceToScreen(win, px, x1, y1);
    const b = sim_window.deviceToScreen(win, px, x2, y2);
    sim_input.swipe(a, b, dur);
    return 0;
}

fn cmdType(gpa: std.mem.Allocator, udid_opt: ?[]const u8, simulator: bool, args: []const []const u8) !u8 {
    if (guardSim(simulator)) |code| return code;
    if (args.len < 1) return errMissing("text");
    _ = udid_opt;
    // Bring sim to front so keystrokes go to its focused field, then use
    // System Events `keystroke` for Unicode-safe input. This avoids having
    // to maintain a CGEvent keycode table.
    try sim_window.activate(gpa);

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(arena);
    for (args, 0..) |a, i| {
        if (i > 0) try joined.append(arena, ' ');
        try joined.appendSlice(arena, a);
    }

    // Escape backslashes and double-quotes for AppleScript string literal.
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(arena);
    for (joined.items) |c| {
        if (c == '\\' or c == '"') try escaped.append(arena, '\\');
        try escaped.append(arena, c);
    }

    const script = try std.fmt.allocPrint(
        arena,
        "tell application \"System Events\" to tell process \"Simulator\" to keystroke \"{s}\"",
        .{escaped.items},
    );
    const r = try io.runCommand(gpa, &.{ "osascript", "-e", script }, 64 * 1024);
    gpa.free(r.stdout);
    return 0;
}

/// Find the single booted iOS Simulator. Returns owned UDID slice; caller frees.
fn resolveBootedSim(gpa: std.mem.Allocator) ![]const u8 {
    const sims = try simctl.listDevices(gpa);
    defer simctl.freeSimDevices(gpa, sims);
    for (sims) |s| {
        if (std.mem.eql(u8, s.state, "Booted")) return try gpa.dupe(u8, s.udid);
    }
    return error.NoBootedSimulator;
}

fn errMissing(name: []const u8) u8 {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    io.printStderr(arena_impl.allocator(), "missing argument: {s}\n", .{name});
    return 2;
}

fn cmdListDevices(gpa: std.mem.Allocator) !u8 {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // Simulators
    const sims = simctl.listDevices(gpa) catch &[_]simctl.SimDevice{};
    defer simctl.freeSimDevices(gpa, sims);
    for (sims) |s| {
        io.printStdout(arena, "simulator\t{s}\t{s}\t{s}\n", .{ s.udid, s.state, s.name });
    }

    // Real devices via usbmuxd
    const reals = usbmux.listDevices(gpa) catch &[_]usbmux.Device{};
    defer usbmux.freeDevices(gpa, reals);
    for (reals) |r| {
        io.printStdout(arena, "device\t{s}\t{s}\tpid={d}\n", .{ r.udid, r.connection, r.product_id });
    }

    return 0;
}

fn printUsage() !void {
    io.writeStderr(
        \\kuri-mobile ios <cmd> [args]
        \\
        \\Commands:
        \\  list-devices                       list both simulators and real devices
        \\  boot       --udid U                boot a simulator
        \\  shutdown   --udid U                shut down a simulator
        \\  openurl   [--udid U] <url>         navigate (opens https/http in Safari on the booted sim)
        \\  navigate  [--udid U] <url>         alias for openurl
        \\  launch    --udid U [--simulator|--device] <bundle-id>
        \\  terminate --udid U [--simulator|--device] <bundle-id>
        \\  screenshot [--udid U] [path.png]   defaults to the booted sim if --udid omitted
        \\  list-apps  --udid U --simulator
        \\
        \\Simulator-only input (macOS, device-pixel coords matching screenshot):
        \\  tap   [--udid U] <x> <y>
        \\  swipe [--udid U] <x1> <y1> <x2> <y2> [duration_ms]   (alias: scroll, pan)
        \\  type  [--udid U] <text...>
        \\
        \\Not implemented in v1 (driverless mode):
        \\  tap, swipe, type on real iOS devices            -> needs XCUITest
        \\  uitree (simulator or device)                    -> needs XCUITest / Accessibility Inspector
        \\
    );
}
