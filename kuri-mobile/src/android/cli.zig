//! `kuri-mobile android <cmd> ...` dispatcher.

const std = @import("std");
const adb = @import("adb.zig");
const driver_mod = @import("driver.zig");
const uitree = @import("../common/uitree.zig");
const tools = @import("tools.zig");
const io = @import("../common/io.zig");

/// Flags accepted before the subcommand's positionals.
const Opts = struct {
    serial: ?[]const u8 = null,
    label: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
    dur_ms: ?u64 = null,
    last: ?[]const u8 = null,
    predicate: ?[]const u8 = null,
    absent: bool = false,
    json: bool = false,
};

pub fn run(gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len == 0) {
        try printUsage();
        return 1;
    }

    const sub = args[0];
    const rest = args[1..];

    var opts: Opts = .{};
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(gpa);

    var idx: usize = 0;
    while (idx < rest.len) {
        const tok = rest[idx];
        if (!std.mem.startsWith(u8, tok, "--")) {
            try positional.append(gpa, tok);
            idx += 1;
            continue;
        }
        const name = tok[2..];
        if (std.mem.eql(u8, name, "absent")) {
            opts.absent = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, name, "json")) {
            opts.json = true;
            idx += 1;
            continue;
        }
        if (idx + 1 >= rest.len) return errMissing(tok);
        const val = rest[idx + 1];
        if (std.mem.eql(u8, name, "serial")) {
            opts.serial = val;
        } else if (std.mem.eql(u8, name, "label")) {
            opts.label = val;
        } else if (std.mem.eql(u8, name, "timeout")) {
            opts.timeout_ms = try std.fmt.parseInt(u64, val, 10);
        } else if (std.mem.eql(u8, name, "for")) {
            opts.dur_ms = try std.fmt.parseInt(u64, val, 10);
        } else if (std.mem.eql(u8, name, "last")) {
            opts.last = val;
        } else if (std.mem.eql(u8, name, "predicate")) {
            opts.predicate = val;
        } else {
            var arena_impl = std.heap.ArenaAllocator.init(gpa);
            defer arena_impl.deinit();
            io.printStderr(arena_impl.allocator(), "unknown flag: {s}\n", .{tok});
            return 2;
        }
        idx += 2;
    }
    const cmd_args = positional.items;

    // Commands that must work with no device attached are dispatched before
    // serial resolution, which would otherwise fail with DeviceNotFound.
    if (std.mem.eql(u8, sub, "tools")) {
        const text = if (opts.json) try tools.renderJson(gpa) else try tools.renderText(gpa);
        defer gpa.free(text);
        io.writeStdout(text);
        return 0;
    }
    if (std.mem.eql(u8, sub, "list-devices") or std.mem.eql(u8, sub, "devices")) {
        return cmdListDevices(gpa);
    }

    const serial_opt = opts.serial;

    const serial = serial_opt orelse try resolveDefaultSerial(gpa);
    defer if (serial_opt == null) gpa.free(serial);

    var d = driver_mod.Driver.init(gpa, serial);

    if (std.mem.eql(u8, sub, "tap")) return cmdTap(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "double-tap")) return cmdDoubleTap(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "long-press")) return cmdLongPress(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "swipe") or std.mem.eql(u8, sub, "scroll") or std.mem.eql(u8, sub, "pan")) return cmdSwipe(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "type")) return cmdType(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "press")) return cmdPress(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "screenshot")) return cmdScreenshot(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "uitree")) return cmdUitree(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "launch")) return cmdLaunch(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "terminate")) return cmdTerminate(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "list-apps")) return cmdListApps(gpa, &d);

    if (std.mem.eql(u8, sub, "doubletap")) return cmdDoubleTap(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "longpress")) return cmdLongPress(gpa, &d, cmd_args);

    if (std.mem.eql(u8, sub, "uninstall")) {
        if (cmd_args.len < 1) return errMissing("package");
        try d.uninstallApp(gpa, cmd_args[0]);
        return 0;
    }
    if (std.mem.eql(u8, sub, "clear")) {
        if (cmd_args.len < 1) return errMissing("package");
        try d.clearApp(gpa, cmd_args[0]);
        return 0;
    }
    if (std.mem.eql(u8, sub, "openurl") or std.mem.eql(u8, sub, "navigate")) {
        if (cmd_args.len < 1) return errMissing("url");
        try d.openUrl(gpa, cmd_args[0]);
        return 0;
    }
    if (std.mem.eql(u8, sub, "keyevent")) {
        if (cmd_args.len < 1) return errMissing("KEYCODE_* or number");
        try d.keyevent(gpa, cmd_args[0]);
        return 0;
    }
    if (std.mem.eql(u8, sub, "current-activity")) return emit(gpa, try d.currentActivity(gpa));
    if (std.mem.eql(u8, sub, "screen-info")) return emit(gpa, try d.screenInfo(gpa));
    if (std.mem.eql(u8, sub, "logcat")) {
        return emit(gpa, try d.logcat(gpa, opts.last orelse "200", opts.predicate));
    }
    if (std.mem.eql(u8, sub, "getprop")) {
        if (cmd_args.len < 1) return errMissing("property name");
        return emit(gpa, try d.getProp(gpa, cmd_args[0]));
    }
    if (std.mem.eql(u8, sub, "dumpsys")) {
        if (cmd_args.len < 1) return errMissing("section");
        return emit(gpa, try d.dumpsys(gpa, cmd_args[0]));
    }

    if (std.mem.eql(u8, sub, "touch")) return cmdTouch(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "gesture") or std.mem.eql(u8, sub, "drag")) return cmdGesture(gpa, &d, opts, cmd_args);
    if (std.mem.eql(u8, sub, "find")) return cmdFind(gpa, &d, opts);
    if (std.mem.eql(u8, sub, "wait-for-ui")) return cmdWaitForUi(gpa, &d, opts);
    if (std.mem.eql(u8, sub, "batch")) return cmdBatch(gpa, &d, cmd_args);

    try printUsage();
    return 1;
}

/// Print an owned buffer and free it — the shape most read-only commands take.
fn emit(gpa: std.mem.Allocator, buf: []u8) u8 {
    defer gpa.free(buf);
    io.writeStdout(buf);
    return 0;
}

/// Fetch and parse the uiautomator hierarchy. Caller frees with
/// `uitree.freeElements`.
fn snapshot(gpa: std.mem.Allocator, d: *driver_mod.Driver) ![]uitree.Element {
    const xml = try d.uitreeXml(gpa);
    defer gpa.free(xml);
    return try uitree.parseAndroidXml(gpa, xml);
}

/// Exact match on text/id/desc first, then a substring fallback, so callers
/// don't have to reproduce long labels verbatim. Mirrors the iOS behaviour.
fn findByLabel(els: []const uitree.Element, label: []const u8) ?uitree.Element {
    for (els) |e| {
        if (std.mem.eql(u8, e.text, label) or
            std.mem.eql(u8, e.id, label) or
            std.mem.eql(u8, e.desc, label)) return e;
    }
    for (els) |e| {
        if (std.mem.indexOf(u8, e.text, label) != null or
            std.mem.indexOf(u8, e.desc, label) != null or
            std.mem.indexOf(u8, e.id, label) != null) return e;
    }
    return null;
}

fn parsePoint(tok: []const u8) !struct { x: i32, y: i32 } {
    const comma = std.mem.indexOfScalar(u8, tok, ',') orelse return error.BadPoint;
    return .{
        .x = try std.fmt.parseInt(i32, tok[0..comma], 10),
        .y = try std.fmt.parseInt(i32, tok[comma + 1 ..], 10),
    };
}

fn cmdTouch(gpa: std.mem.Allocator, d: *driver_mod.Driver, args: []const []const u8) !u8 {
    if (args.len < 3) return errMissing("<down|up|move> <x> <y>");
    const phase = if (std.mem.eql(u8, args[0], "down"))
        "DOWN"
    else if (std.mem.eql(u8, args[0], "up"))
        "UP"
    else if (std.mem.eql(u8, args[0], "move"))
        "MOVE"
    else {
        io.writeStderr("unknown touch phase (want down|move|up)\n");
        return 2;
    };
    try d.motionEvent(gpa, phase, try std.fmt.parseInt(i32, args[1], 10), try std.fmt.parseInt(i32, args[2], 10));
    return 0;
}

fn cmdGesture(gpa: std.mem.Allocator, d: *driver_mod.Driver, opts: Opts, args: []const []const u8) !u8 {
    if (args.len < 2) return errMissing("<x1,y1> <x2,y2> [x3,y3 ...]");
    var pts: std.ArrayList([2]i32) = .empty;
    defer pts.deinit(gpa);
    for (args) |tok| {
        const p = parsePoint(tok) catch {
            var arena_impl = std.heap.ArenaAllocator.init(gpa);
            defer arena_impl.deinit();
            io.printStderr(arena_impl.allocator(), "expected x,y — got: {s}\n", .{tok});
            return 2;
        };
        try pts.append(gpa, .{ p.x, p.y });
    }
    // Spread the requested duration across the legs of the path.
    const total = opts.dur_ms orelse 400;
    const step: u32 = @intCast(@max(total / @max(pts.items.len - 1, 1), 16));
    try d.gesture(gpa, pts.items, step);
    return 0;
}

fn cmdFind(gpa: std.mem.Allocator, d: *driver_mod.Driver, opts: Opts) !u8 {
    const label = opts.label orelse return errMissing("--label <text>");
    const els = try snapshot(gpa, d);
    defer uitree.freeElements(gpa, els);

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var hits: usize = 0;
    for (els) |e| {
        const m = std.mem.indexOf(u8, e.text, label) != null or
            std.mem.indexOf(u8, e.desc, label) != null or
            std.mem.indexOf(u8, e.id, label) != null;
        if (!m) continue;
        hits += 1;
        if (uitree.centroid(e)) |c| {
            io.printStdout(arena, "{s}\tid={s}\ttext={s}\ttap={d},{d}\n", .{ e.class, e.id, e.text, c[0], c[1] });
        } else {
            io.printStdout(arena, "{s}\tid={s}\ttext={s}\ttap=-\n", .{ e.class, e.id, e.text });
        }
    }
    // Non-zero on no match so `find` works directly as a test assertion.
    if (hits == 0) {
        io.printStderr(arena, "no element matching label: {s}\n", .{label});
        return 4;
    }
    return 0;
}

/// Poll the hierarchy until an element appears (or disappears with --absent).
/// Deadline is wall-clock: each poll costs a uiautomator dump, so counting
/// sleeps would overshoot the requested timeout substantially.
fn cmdWaitForUi(gpa: std.mem.Allocator, d: *driver_mod.Driver, opts: Opts) !u8 {
    const label = opts.label orelse return errMissing("--label <text>");
    const timeout = opts.timeout_ms orelse 10_000;
    const deadline = io.monotonicMs() + @as(i64, @intCast(timeout));

    while (true) {
        const present = blk: {
            const els = snapshot(gpa, d) catch break :blk false;
            defer uitree.freeElements(gpa, els);
            break :blk findByLabel(els, label) != null;
        };
        if (present != opts.absent) return 0;
        if (io.monotonicMs() >= deadline) break;
        io.sleepMs(250);
    }

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    io.printStderr(arena_impl.allocator(), "timed out after {d}ms waiting for '{s}' to {s}\n", .{
        timeout,
        label,
        if (opts.absent) "disappear" else "appear",
    });
    return 4;
}

/// Several actions over one adb client. The win is session setup: serial
/// resolution happens once for the whole sequence instead of per command.
fn cmdBatch(gpa: std.mem.Allocator, d: *driver_mod.Driver, args: []const []const u8) !u8 {
    if (args.len < 1) return errMissing("<action> [action ...]  e.g. tap:120,400 type:hi press:enter");

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    for (args, 0..) |spec, step| {
        const colon = std.mem.indexOfScalar(u8, spec, ':') orelse {
            io.printStderr(arena, "step {d}: expected verb:args — got '{s}'\n", .{ step + 1, spec });
            return 2;
        };
        const verb = spec[0..colon];
        const rest = spec[colon + 1 ..];

        if (std.mem.eql(u8, verb, "wait")) {
            io.sleepMs(try std.fmt.parseInt(u64, rest, 10));
            continue;
        }
        if (std.mem.eql(u8, verb, "type")) {
            try d.typeText(gpa, rest);
            continue;
        }
        if (std.mem.eql(u8, verb, "press")) {
            try d.pressButton(gpa, rest);
            continue;
        }
        if (std.mem.eql(u8, verb, "key")) {
            try d.keyevent(gpa, rest);
            continue;
        }
        if (std.mem.eql(u8, verb, "label")) {
            const els = try snapshot(gpa, d);
            defer uitree.freeElements(gpa, els);
            const hit = findByLabel(els, rest) orelse {
                io.printStderr(arena, "step {d}: no element matching label '{s}'\n", .{ step + 1, rest });
                return 4;
            };
            const c = uitree.centroid(hit) orelse return error.ElementHasNoBounds;
            try d.tap(gpa, c[0], c[1]);
            continue;
        }

        var nums: std.ArrayList(i32) = .empty;
        defer nums.deinit(gpa);
        var it = std.mem.splitScalar(u8, rest, ',');
        while (it.next()) |n| {
            if (n.len == 0) continue;
            try nums.append(gpa, std.fmt.parseInt(i32, n, 10) catch {
                io.printStderr(arena, "step {d}: '{s}' is not a number\n", .{ step + 1, n });
                return 2;
            });
        }
        const v = nums.items;

        if (std.mem.eql(u8, verb, "tap") and v.len >= 2) {
            try d.tap(gpa, v[0], v[1]);
        } else if (std.mem.eql(u8, verb, "doubletap") and v.len >= 2) {
            try d.doubleTap(gpa, v[0], v[1]);
        } else if (std.mem.eql(u8, verb, "longpress") and v.len >= 2) {
            try d.longPress(gpa, v[0], v[1], if (v.len >= 3) @intCast(v[2]) else 500);
        } else if (std.mem.eql(u8, verb, "swipe") and v.len >= 4) {
            try d.swipe(gpa, v[0], v[1], v[2], v[3], if (v.len >= 5) @intCast(v[4]) else 300);
        } else {
            io.printStderr(arena, "step {d}: unknown or malformed action '{s}'\n", .{ step + 1, spec });
            return 2;
        }
    }
    return 0;
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

/// Rendered from the same table `android tools` serves, so a command can
/// never exist in the dispatcher but go missing from the help.
fn printUsage() !void {
    io.writeStderr(
        \\kuri-mobile android <cmd> [args]
        \\
        \\Global flags: --serial <id>  --label <text>  --timeout MS  --for MS
        \\              --last N  --predicate <text>  --absent  --json
        \\--serial auto-picks the single attached device when omitted.
        \\Run `kuri-mobile android tools --json` for the machine-readable surface.
        \\
        \\
    );

    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const text = tools.renderText(gpa_impl.allocator()) catch return;
    defer gpa_impl.allocator().free(text);
    io.writeStderr(text);

    io.writeStderr(
        \\press names: home back menu enter tab space del recents wakeup sleep
        \\             volumeUp volumeDown power dpad{Up,Down,Left,Right,Center}
        \\
        \\Not supported: install (needs the adb SYNC protocol, not implemented)
        \\               record-video (needs file pull off the device)
        \\
    );
}
