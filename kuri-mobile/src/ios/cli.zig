//! `kuri-mobile ios <cmd>` dispatcher.

const std = @import("std");
const simctl = @import("simctl.zig");
const usbmux = @import("usbmux.zig");
const devicectl = @import("devicectl.zig");
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

    if (std.mem.eql(u8, sub, "tap") or std.mem.eql(u8, sub, "swipe") or std.mem.eql(u8, sub, "type") or std.mem.eql(u8, sub, "uitree")) {
        var arena_impl = std.heap.ArenaAllocator.init(gpa);
        defer arena_impl.deinit();
        io.printStderr(arena_impl.allocator(), "'{s}' on iOS requires XCUITest, which is not bundled in v1 (driverless mode).\n", .{sub});
        return 3;
    }

    try printUsage();
    return 1;
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
        \\Not implemented in v1 (driverless mode):
        \\  tap, swipe, type, uitree on real devices
        \\    these require an on-device XCUITest runner; intentionally skipped.
        \\
    );
}
