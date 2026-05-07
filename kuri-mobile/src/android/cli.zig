//! `kuri-mobile android <cmd> ...` dispatcher.

const std = @import("std");
const adb = @import("adb.zig");
const driver_mod = @import("driver.zig");
const uitree = @import("../common/uitree.zig");
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

    var serial_opt: ?[]const u8 = null;
    var idx: usize = 0;
    while (idx < rest.len and std.mem.startsWith(u8, rest[idx], "--")) : (idx += 2) {
        if (std.mem.eql(u8, rest[idx], "--serial")) {
            if (idx + 1 >= rest.len) return errMissing("--serial");
            serial_opt = rest[idx + 1];
        } else {
            io.writeStderr("unknown flag\n");
            return 2;
        }
    }
    const cmd_args = rest[idx..];

    const serial = serial_opt orelse try resolveDefaultSerial(gpa);
    defer if (serial_opt == null) gpa.free(serial);

    var d = driver_mod.Driver.init(gpa, serial);

    if (std.mem.eql(u8, sub, "tap")) return cmdTap(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "double-tap")) return cmdDoubleTap(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "long-press")) return cmdLongPress(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "swipe") or std.mem.eql(u8, sub, "scroll")) return cmdSwipe(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "type")) return cmdType(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "press")) return cmdPress(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "screenshot")) return cmdScreenshot(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "uitree")) return cmdUitree(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "launch")) return cmdLaunch(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "terminate")) return cmdTerminate(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "list-apps")) return cmdListApps(gpa, &d);

    try printUsage();
    return 1;
}

fn errMissing(name: []const u8) u8 {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    io.printStderr(arena_impl.allocator(), "missing argument: {s}\n", .{name});
    return 2;
}

fn cmdListDevices(gpa: std.mem.Allocator) !u8 {
    var c = adb.Client.init(gpa);
    const raw = try c.hostQuery("host:devices");
    defer gpa.free(raw);
    const devs = try adb.parseDevices(gpa, raw);
    defer adb.freeDevices(gpa, devs);

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    for (devs) |d| io.printStdout(arena_impl.allocator(), "{s}\t{s}\n", .{ d.serial, d.state });
    return 0;
}

fn resolveDefaultSerial(gpa: std.mem.Allocator) ![]const u8 {
    var c = adb.Client.init(gpa);
    const raw = try c.hostQuery("host:devices");
    defer gpa.free(raw);
    const devs = try adb.parseDevices(gpa, raw);
    defer adb.freeDevices(gpa, devs);
    for (devs) |d| {
        if (std.mem.eql(u8, d.state, "device")) return try gpa.dupe(u8, d.serial);
    }
    return error.DeviceNotFound;
}

fn cmdTap(gpa: std.mem.Allocator, d: *driver_mod.Driver, args: []const []const u8) !u8 {
    if (args.len < 2) return errMissing("x y");
    const x = try std.fmt.parseInt(i32, args[0], 10);
    const y = try std.fmt.parseInt(i32, args[1], 10);
    try d.tap(gpa, x, y);
    return 0;
}

fn cmdDoubleTap(gpa: std.mem.Allocator, d: *driver_mod.Driver, args: []const []const u8) !u8 {
    if (args.len < 2) return errMissing("x y");
    const x = try std.fmt.parseInt(i32, args[0], 10);
    const y = try std.fmt.parseInt(i32, args[1], 10);
    try d.doubleTap(gpa, x, y);
    return 0;
}

fn cmdLongPress(gpa: std.mem.Allocator, d: *driver_mod.Driver, args: []const []const u8) !u8 {
    if (args.len < 2) return errMissing("x y [duration_ms]");
    const x = try std.fmt.parseInt(i32, args[0], 10);
    const y = try std.fmt.parseInt(i32, args[1], 10);
    const ms: u32 = if (args.len >= 3) try std.fmt.parseInt(u32, args[2], 10) else 800;
    try d.longPress(gpa, x, y, ms);
    return 0;
}

fn cmdSwipe(gpa: std.mem.Allocator, d: *driver_mod.Driver, args: []const []const u8) !u8 {
    if (args.len < 4) return errMissing("x1 y1 x2 y2 [duration_ms]");
    const x1 = try std.fmt.parseInt(i32, args[0], 10);
    const y1 = try std.fmt.parseInt(i32, args[1], 10);
    const x2 = try std.fmt.parseInt(i32, args[2], 10);
    const y2 = try std.fmt.parseInt(i32, args[3], 10);
    const ms: u32 = if (args.len >= 5) try std.fmt.parseInt(u32, args[4], 10) else 300;
    try d.swipe(gpa, x1, y1, x2, y2, ms);
    return 0;
}

fn cmdType(gpa: std.mem.Allocator, d: *driver_mod.Driver, args: []const []const u8) !u8 {
    if (args.len < 1) return errMissing("text");
    const text = try std.mem.join(gpa, " ", args);
    defer gpa.free(text);
    try d.typeText(gpa, text);
    return 0;
}

fn cmdPress(gpa: std.mem.Allocator, d: *driver_mod.Driver, args: []const []const u8) !u8 {
    if (args.len < 1) return errMissing("button");
    try d.pressButton(gpa, args[0]);
    return 0;
}

fn cmdScreenshot(gpa: std.mem.Allocator, d: *driver_mod.Driver, args: []const []const u8) !u8 {
    const path = if (args.len >= 1) args[0] else "screenshot.png";
    const bytes = try d.screenshot(gpa);
    defer gpa.free(bytes);
    try io.writeFile(path, bytes);
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    io.printStderr(arena_impl.allocator(), "wrote {d} bytes to {s}\n", .{ bytes.len, path });
    return 0;
}

fn cmdUitree(gpa: std.mem.Allocator, d: *driver_mod.Driver, args: []const []const u8) !u8 {
    _ = args;
    const xml = try d.uitreeXml(gpa);
    defer gpa.free(xml);
    const els = try uitree.parseAndroidXml(gpa, xml);
    defer uitree.freeElements(gpa, els);
    const text = try uitree.renderText(gpa, els);
    defer gpa.free(text);
    io.writeStdout(text);
    return 0;
}

fn cmdLaunch(gpa: std.mem.Allocator, d: *driver_mod.Driver, args: []const []const u8) !u8 {
    if (args.len < 1) return errMissing("package");
    try d.launchApp(gpa, args[0]);
    return 0;
}

fn cmdTerminate(gpa: std.mem.Allocator, d: *driver_mod.Driver, args: []const []const u8) !u8 {
    if (args.len < 1) return errMissing("package");
    try d.terminateApp(gpa, args[0]);
    return 0;
}

fn cmdListApps(gpa: std.mem.Allocator, d: *driver_mod.Driver) !u8 {
    const out = try d.listApps(gpa);
    defer gpa.free(out);
    io.writeStdout(out);
    return 0;
}

fn printUsage() !void {
    io.writeStderr(
        \\kuri-mobile android <cmd> [args]
        \\
        \\Commands:
        \\  list-devices
        \\  tap <x> <y>
        \\  double-tap <x> <y>
        \\  long-press <x> <y> [ms]
        \\  swipe <x1> <y1> <x2> <y2> [ms]
        \\  type <text...>
        \\  press <button>          # home|back|menu|enter|tab|space|del|volumeUp|volumeDown|power|dpad{Up,Down,Left,Right,Center}
        \\  screenshot [path.png]
        \\  uitree
        \\  launch <package>
        \\  terminate <package>
        \\  list-apps
        \\
        \\Global flags:
        \\  --serial <id>           # target device (auto-picks single attached device)
        \\
    );
}
