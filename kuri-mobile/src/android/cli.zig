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
    // Selectors. `--label` searches text/id/desc at once; these address one
    // attribute each, for when a label is ambiguous or absent.
    id: ?[]const u8 = null,
    class: ?[]const u8 = null,
    desc: ?[]const u8 = null,
    /// Which match to act on when a selector hits several. 0 = first.
    index: usize = 0,
    /// Restrict to elements that can actually be acted on.
    interactive: bool = false,
    /// `type --clear`: empty the focused field before typing.
    clear: bool = false,
    /// `notifications --open`: pull the shade down instead of reading it.
    open: bool = false,
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
        if (std.mem.eql(u8, name, "interactive")) {
            opts.interactive = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, name, "clear")) {
            opts.clear = true;
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, name, "open")) {
            opts.open = true;
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
        } else if (std.mem.eql(u8, name, "id")) {
            opts.id = val;
        } else if (std.mem.eql(u8, name, "class")) {
            opts.class = val;
        } else if (std.mem.eql(u8, name, "desc")) {
            opts.desc = val;
        } else if (std.mem.eql(u8, name, "index")) {
            opts.index = try std.fmt.parseInt(usize, val, 10);
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
    // Sleeping needs no device, and failing it with "no device attached" would
    // be a confusing way to lose a step in the middle of a script.
    if (std.mem.eql(u8, sub, "wait")) return cmdWait(gpa, cmd_args);

    const serial_opt = opts.serial;

    const serial = serial_opt orelse try resolveDefaultSerial(gpa);
    defer if (serial_opt == null) gpa.free(serial);

    var d = driver_mod.Driver.init(gpa, serial);

    if (std.mem.eql(u8, sub, "tap")) return cmdTap(gpa, &d, opts, cmd_args);
    if (std.mem.eql(u8, sub, "double-tap")) return cmdDoubleTap(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "long-press")) return cmdLongPress(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "swipe") or std.mem.eql(u8, sub, "scroll") or std.mem.eql(u8, sub, "pan")) return cmdSwipe(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "type")) return cmdType(gpa, &d, opts, cmd_args);
    if (std.mem.eql(u8, sub, "press")) return cmdPress(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "screenshot")) return cmdScreenshot(gpa, &d, cmd_args);
    if (std.mem.eql(u8, sub, "uitree")) return cmdUitree(gpa, &d, opts);
    if (std.mem.eql(u8, sub, "state") or std.mem.eql(u8, sub, "snapshot")) return cmdState(gpa, &d);
    if (std.mem.eql(u8, sub, "notifications")) return cmdNotifications(gpa, &d, opts);
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

/// Does this element satisfy every selector the caller supplied? Selectors are
/// AND-ed, so `--class EditText --desc Email` narrows rather than widens.
fn matchesSelectors(e: uitree.Element, opts: Opts) bool {
    if (opts.interactive and !e.interactive) return false;
    if (opts.label) |v| {
        if (std.mem.indexOf(u8, e.text, v) == null and
            std.mem.indexOf(u8, e.desc, v) == null and
            std.mem.indexOf(u8, e.id, v) == null) return false;
    }
    if (opts.id) |v| {
        // Accept either the short or the fully-qualified form, so a caller can
        // paste back the `btn_login` that a listing showed them.
        if (!std.mem.eql(u8, e.id, v) and
            !std.mem.eql(u8, uitree.shortId(e.id), v) and
            std.mem.indexOf(u8, e.id, v) == null) return false;
    }
    if (opts.class) |v| {
        if (std.mem.indexOf(u8, e.class, v) == null) return false;
    }
    if (opts.desc) |v| {
        if (std.mem.indexOf(u8, e.desc, v) == null) return false;
    }
    return true;
}

fn hasSelector(opts: Opts) bool {
    return opts.label != null or opts.id != null or opts.class != null or opts.desc != null;
}

/// The `--index`-th element matching the selectors, or null.
fn selectNth(els: []const uitree.Element, opts: Opts) ?uitree.Element {
    var seen: usize = 0;
    for (els) |e| {
        if (!matchesSelectors(e, opts)) continue;
        if (seen == opts.index) return e;
        seen += 1;
    }
    return null;
}

fn reportNoMatch(gpa: std.mem.Allocator, opts: Opts) u8 {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    io.printStderr(arena_impl.allocator(), "no element matching selectors (label={s} id={s} class={s} desc={s} index={d})\n", .{
        opts.label orelse "-",
        opts.id orelse "-",
        opts.class orelse "-",
        opts.desc orelse "-",
        opts.index,
    });
    return 4;
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
    if (!hasSelector(opts)) return errMissing("--label <text> (or --id/--class/--desc)");
    const els = try snapshot(gpa, d);
    defer uitree.freeElements(gpa, els);

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var hits: usize = 0;
    for (els) |e| {
        if (!matchesSelectors(e, opts)) continue;
        defer hits += 1;
        // The leading match ordinal is what `--index` addresses, so printing it
        // means a caller can disambiguate without counting lines themselves.
        if (uitree.centroid(e)) |c| {
            io.printStdout(arena, "{d}\t{s}\tid={s}\ttext={s}\ttap={d},{d}\n", .{ hits, e.class, uitree.shortId(e.id), e.text, c[0], c[1] });
        } else {
            io.printStdout(arena, "{d}\t{s}\tid={s}\ttext={s}\ttap=-\n", .{ hits, e.class, uitree.shortId(e.id), e.text });
        }
    }
    // Non-zero on no match so `find` works directly as a test assertion.
    if (hits == 0) return reportNoMatch(gpa, opts);
    return 0;
}

/// Foreground app plus every element worth acting on, in one round trip.
/// Previously this took three calls (`current-activity`, `screen-info`,
/// `uitree`) and left the caller to filter the noise out of the third.
fn cmdState(gpa: std.mem.Allocator, d: *driver_mod.Driver) !u8 {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // Context first: the elements below mean little without knowing which
    // screen produced them.
    if (d.currentActivity(gpa)) |act| {
        defer gpa.free(act);
        io.printStdout(arena, "app\t{s}\n", .{std.mem.trim(u8, act, " \t\r\n")});
    } else |_| {}
    if (d.screenInfo(gpa)) |info| {
        defer gpa.free(info);
        var it = std.mem.splitScalar(u8, info, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r\n");
            if (t.len != 0) io.printStdout(arena, "screen\t{s}\n", .{t});
        }
    } else |_| {}

    const els = try snapshot(gpa, d);
    defer uitree.freeElements(gpa, els);

    var shown: usize = 0;
    for (els) |e| {
        if (!e.interactive) continue;
        const c = uitree.centroid(e) orelse continue;
        io.printStdout(arena, "@e{d}\t{s}\tid={s}\ttext={s}\tdesc={s}\ttap={d},{d}{s}{s}{s}{s}\n", .{
            e.ref,
            shortClass(e.class),
            uitree.shortId(e.id),
            e.text,
            e.desc,
            c[0],
            c[1],
            if (e.scrollable) "\t*scrollable" else "",
            if (e.checkable) (if (e.checked) "\t*checked" else "\t*unchecked") else "",
            if (e.password) "\t*password" else "",
            if (e.focused) "\t*focused" else "",
        });
        shown += 1;
    }
    if (shown == 0) io.writeStderr("no interactive elements — the screen may still be loading\n");
    return 0;
}

fn shortClass(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '.')) |dot| return s[dot + 1 ..];
    return s;
}

fn cmdWait(gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len < 1) return errMissing("<milliseconds>");
    const ms = std.fmt.parseInt(u64, args[0], 10) catch {
        var arena_impl = std.heap.ArenaAllocator.init(gpa);
        defer arena_impl.deinit();
        io.printStderr(arena_impl.allocator(), "expected milliseconds — got '{s}'\n", .{args[0]});
        return 2;
    };
    io.sleepMs(ms);
    return 0;
}

/// Posted notifications, parsed out of `dumpsys notification`. Android-MCP's
/// equivalent only pulls the shade down, which tells an agent nothing it can
/// read; `--open` does that too, for when the goal is to interact with them.
fn cmdNotifications(gpa: std.mem.Allocator, d: *driver_mod.Driver, opts: Opts) !u8 {
    if (opts.open) {
        try d.expandNotifications(gpa);
        return 0;
    }
    const dump = try d.notificationDump(gpa);
    defer gpa.free(dump);

    const rendered = try renderNotifications(gpa, dump);
    defer gpa.free(rendered);
    if (rendered.len == 0) {
        io.writeStderr("no notifications parsed — `android dumpsys notification` has the raw output\n");
        return 0;
    }
    io.writeStdout(rendered);
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

/// Extract `pkg / title / text` per posted notification from a
/// `dumpsys notification --noredact` dump.
///
/// This is a debug format, not an API: the extras have been printed both as
/// `android.title=Value` and as `android.title=String (Value)` across
/// versions, so both are accepted and anything unrecognised is skipped rather
/// than guessed at. Records carrying neither a title nor a body are dropped —
/// every app with a foreground service has one and none of them are readable.
fn renderNotifications(gpa: std.mem.Allocator, dump: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var pkg: []const u8 = "";
    var title: []const u8 = "";
    var body: []const u8 = "";
    var in_record = false;

    var it = std.mem.splitScalar(u8, dump, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.indexOf(u8, line, "NotificationRecord(") != null) {
            if (in_record) try flushNotification(gpa, &out, pkg, title, body);
            in_record = true;
            pkg = extractUntilSpace(line, "pkg=") orelse "";
            title = "";
            body = "";
            continue;
        }
        if (!in_record) continue;
        if (extractExtra(line, "android.title=")) |v| {
            title = v;
        } else if (extractExtra(line, "android.text=")) |v| {
            body = v;
        }
    }
    if (in_record) try flushNotification(gpa, &out, pkg, title, body);
    return try out.toOwnedSlice(gpa);
}

fn flushNotification(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    pkg: []const u8,
    title: []const u8,
    body: []const u8,
) !void {
    if (title.len == 0 and body.len == 0) return;
    const line = try std.fmt.allocPrint(gpa, "{s}\t{s}\t{s}\n", .{ pkg, title, body });
    defer gpa.free(line);
    try out.appendSlice(gpa, line);
}

fn extractUntilSpace(line: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    const rest = line[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    return rest[0..end];
}

fn extractExtra(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    var v = std.mem.trim(u8, line[key.len..], " \t");
    // Older dumps print the declared type before the value.
    if (std.mem.startsWith(u8, v, "String (") and std.mem.endsWith(u8, v, ")")) {
        v = v["String (".len .. v.len - 1];
    }
    if (v.len == 0 or std.mem.eql(u8, v, "null")) return null;
    return v;
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

/// `tap` advertised `--label` in the tool table but only ever read positional
/// coordinates, so the documented form failed with "missing argument: x y".
/// Selectors are now honoured, and extended to id/class/desc.
fn cmdTap(gpa: std.mem.Allocator, d: *driver_mod.Driver, opts: Opts, args: []const []const u8) !u8 {
    if (hasSelector(opts)) {
        const els = try snapshot(gpa, d);
        defer uitree.freeElements(gpa, els);
        const hit = selectNth(els, opts) orelse return reportNoMatch(gpa, opts);
        const c = uitree.centroid(hit) orelse {
            io.writeStderr("matched element has no bounds to tap\n");
            return 4;
        };
        try d.tap(gpa, c[0], c[1]);
        return 0;
    }
    if (args.len < 2) return errMissing("x y (or --label/--id/--class/--desc)");
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

/// Longest field we will clear key-by-key. `input text` appends, so replacing
/// a value means deleting what is there; a runaway length here would be a very
/// long shell command, and no real field is this big.
const max_clear_chars = 512;

fn cmdType(gpa: std.mem.Allocator, d: *driver_mod.Driver, opts: Opts, args: []const []const u8) !u8 {
    if (args.len < 1) return errMissing("text");
    if (opts.clear) {
        // Delete exactly what the field holds. Android has no "select all"
        // keyevent that works across versions, so the count comes from the
        // focused element in the hierarchy — precise, and one round trip
        // because `input keyevent` accepts a list of keycodes.
        const els = try snapshot(gpa, d);
        defer uitree.freeElements(gpa, els);
        var chars: usize = 0;
        for (els) |e| {
            if (!e.focused) continue;
            chars = std.unicode.utf8CountCodepoints(e.text) catch e.text.len;
            break;
        }
        if (chars > max_clear_chars) chars = max_clear_chars;
        if (chars != 0) try d.clearText(gpa, chars);
    }
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

fn cmdUitree(gpa: std.mem.Allocator, d: *driver_mod.Driver, opts: Opts) !u8 {
    const xml = try d.uitreeXml(gpa);
    defer gpa.free(xml);
    const els = try uitree.parseAndroidXml(gpa, xml);
    defer uitree.freeElements(gpa, els);

    // Default stays "everything meaningful" — static labels are context an
    // agent reads even though it cannot tap them. `--interactive` drops to
    // just what can be acted on, which on a dense screen is a fraction of it.
    if (!opts.interactive) {
        const text = try uitree.renderText(gpa, els);
        defer gpa.free(text);
        io.writeStdout(text);
        return 0;
    }

    var kept: std.ArrayList(uitree.Element) = .empty;
    defer kept.deinit(gpa);
    for (els) |e| {
        if (e.interactive) try kept.append(gpa, e);
    }
    const text = try uitree.renderText(gpa, kept.items);
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

// ---------------------------------------------------------------- tests

test "renderNotifications reads both extras spellings and keeps the package" {
    // Two records: the modern bare-value form and the older typed form.
    const dump =
        \\Current Notification Manager state:
        \\  NotificationRecord(0x1: pkg=com.example.chat user=0 id=7 tag=null
        \\    extras={
        \\      android.title=Alice
        \\      android.text=Lunch at one?
        \\    }
        \\  NotificationRecord(0x2: pkg=com.example.mail user=0 id=9 tag=null
        \\    extras={
        \\      android.title=String (Receipt)
        \\      android.text=String (Your order shipped)
        \\    }
    ;
    const out = try renderNotifications(std.testing.allocator, dump);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        "com.example.chat\tAlice\tLunch at one?\n" ++
            "com.example.mail\tReceipt\tYour order shipped\n",
        out,
    );
}

test "renderNotifications drops records with nothing readable" {
    // Every app running a foreground service posts one of these; listing them
    // would bury the notifications a caller actually wants.
    const dump =
        \\  NotificationRecord(0x1: pkg=com.example.sync user=0 id=1 tag=null
        \\    extras={
        \\      android.title=null
        \\    }
        \\  NotificationRecord(0x2: pkg=com.example.chat user=0 id=2 tag=null
        \\    extras={
        \\      android.title=Bob
        \\    }
    ;
    const out = try renderNotifications(std.testing.allocator, dump);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("com.example.chat\tBob\t\n", out);
}

test "renderNotifications yields nothing for a dump with no records" {
    const out = try renderNotifications(std.testing.allocator, "Current Notification Manager state:\n  (zen mode)\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

const test_els = [_]uitree.Element{
    .{ .ref = 0, .class = "android.widget.Button", .text = "Sign in", .id = "com.x:id/btn_sign_in", .desc = "", .interactive = true },
    .{ .ref = 1, .class = "android.widget.TextView", .text = "Sign in to continue", .id = "", .desc = "", .interactive = false },
    .{ .ref = 2, .class = "android.widget.EditText", .text = "", .id = "com.x:id/email", .desc = "Email address", .interactive = true },
};

test "id selector accepts the short form a listing prints" {
    // `find` prints `btn_sign_in`; pasting that straight back must work.
    try std.testing.expect(matchesSelectors(test_els[0], .{ .id = "btn_sign_in" }));
    try std.testing.expect(matchesSelectors(test_els[0], .{ .id = "com.x:id/btn_sign_in" }));
    try std.testing.expect(!matchesSelectors(test_els[0], .{ .id = "email" }));
}

test "selectors are AND-ed and --interactive excludes static text" {
    // "Sign in" matches both the button and the label; adding a class narrows
    // it to the one that can be tapped.
    try std.testing.expect(matchesSelectors(test_els[1], .{ .label = "Sign in" }));
    try std.testing.expect(!matchesSelectors(test_els[1], .{ .label = "Sign in", .class = "Button" }));
    try std.testing.expect(matchesSelectors(test_els[0], .{ .label = "Sign in", .class = "Button" }));
    try std.testing.expect(!matchesSelectors(test_els[1], .{ .label = "Sign in", .interactive = true }));
}

test "selectNth walks matches in order and runs out cleanly" {
    const first = selectNth(&test_els, .{ .label = "Sign in" }).?;
    try std.testing.expectEqual(@as(u32, 0), first.ref);
    const second = selectNth(&test_els, .{ .label = "Sign in", .index = 1 }).?;
    try std.testing.expectEqual(@as(u32, 1), second.ref);
    try std.testing.expect(selectNth(&test_els, .{ .label = "Sign in", .index = 2 }) == null);
}

test "desc selector reaches an element with no text at all" {
    // An icon-only field is addressable by content-desc and nothing else.
    try std.testing.expect(matchesSelectors(test_els[2], .{ .desc = "Email" }));
    try std.testing.expect(!matchesSelectors(test_els[0], .{ .desc = "Email" }));
}

test "hasSelector distinguishes a selector from bare flags" {
    try std.testing.expect(!hasSelector(.{}));
    try std.testing.expect(!hasSelector(.{ .interactive = true, .index = 3 }));
    try std.testing.expect(hasSelector(.{ .label = "x" }));
    try std.testing.expect(hasSelector(.{ .desc = "x" }));
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
