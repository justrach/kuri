//! `kuri-mobile ios <cmd>` dispatcher.

const std = @import("std");
const builtin = @import("builtin");
const simctl = @import("simctl.zig");
const usbmux = @import("usbmux.zig");
const devicectl = @import("devicectl.zig");
const sim_input = @import("sim_input.zig");
const sim_window = @import("sim_window.zig");
const sim_ax = @import("sim_ax.zig");
const xcode = @import("xcode.zig");
const io = @import("../common/io.zig");
const uitree = @import("../common/uitree.zig");

/// Flags accepted before *or* after the subcommand's positional arguments,
/// so `key return --cmd` and `key --cmd return` both work.
const Opts = struct {
    udid: ?[]const u8 = null,
    /// Default to simulator. `--device` routes real-device commands through
    /// devicectl and requires --udid.
    simulator: bool = true,
    mods: u64 = 0,
    dur_ms: ?u64 = null,
    last: ?[]const u8 = null,
    predicate: ?[]const u8 = null,
    /// Accessibility label / identifier to target instead of coordinates.
    label: ?[]const u8 = null,
};

/// Consume a recognized flag at `rest[idx]`, returning how many tokens it
/// used, or null if the token isn't a known flag.
fn takeFlag(opts: *Opts, rest: []const []const u8, idx: usize) !?usize {
    const tok = rest[idx];
    if (!std.mem.startsWith(u8, tok, "--")) return null;
    const name = tok[2..];

    if (std.mem.eql(u8, name, "simulator")) {
        opts.simulator = true;
        return 1;
    }
    if (std.mem.eql(u8, name, "device")) {
        opts.simulator = false;
        return 1;
    }
    if (sim_input.lookupModifier(name)) |bit| {
        opts.mods |= bit;
        return 1;
    }

    // Value-taking flags.
    const needs_value = std.mem.eql(u8, name, "udid") or
        std.mem.eql(u8, name, "for") or
        std.mem.eql(u8, name, "last") or
        std.mem.eql(u8, name, "predicate") or
        std.mem.eql(u8, name, "label");
    if (!needs_value) return null;
    if (idx + 1 >= rest.len) return error.MissingFlagValue;
    const val = rest[idx + 1];

    if (std.mem.eql(u8, name, "udid")) {
        opts.udid = val;
    } else if (std.mem.eql(u8, name, "for")) {
        opts.dur_ms = try std.fmt.parseInt(u64, val, 10);
    } else if (std.mem.eql(u8, name, "last")) {
        opts.last = val;
    } else if (std.mem.eql(u8, name, "predicate")) {
        opts.predicate = val;
    } else if (std.mem.eql(u8, name, "label")) {
        opts.label = val;
    }
    return 2;
}

pub fn run(gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len == 0) {
        try printUsage();
        return 1;
    }
    const sub = args[0];
    const rest = args[1..];

    // Split flags from positionals anywhere in the argument list.
    const passes_through_flags = std.mem.eql(u8, sub, "status-bar") or
        std.mem.eql(u8, sub, "status_bar");
    var opts: Opts = .{};
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(gpa);

    var idx: usize = 0;
    while (idx < rest.len) {
        const consumed = takeFlag(&opts, rest, idx) catch |err| switch (err) {
            error.MissingFlagValue => return errMissing(rest[idx]),
            else => return err,
        };
        if (consumed) |n| {
            idx += n;
        } else {
            // `status-bar` forwards its own flags (--time, --batteryLevel, …)
            // straight to simctl, so unrecognized flags are data here, not
            // user error.
            if (passes_through_flags) {
                try positional.append(gpa, rest[idx]);
                idx += 1;
                continue;
            }
            if (std.mem.startsWith(u8, rest[idx], "--")) {
                var arena_impl = std.heap.ArenaAllocator.init(gpa);
                defer arena_impl.deinit();
                io.printStderr(arena_impl.allocator(), "unknown flag: {s}\n", .{rest[idx]});
                return 2;
            }
            try positional.append(gpa, rest[idx]);
            idx += 1;
        }
    }
    const cmd_args = positional.items;

    if (std.mem.eql(u8, sub, "list-devices") or std.mem.eql(u8, sub, "devices")) {
        return cmdListDevices(gpa);
    }

    if (std.mem.eql(u8, sub, "launch")) {
        if (cmd_args.len < 1) return errMissing("bundle-id");
        // Real-device launch always needs --udid (devicectl can't guess).
        if (!opts.simulator) {
            const udid = opts.udid orelse return errMissing("--udid");
            try devicectl.launch(gpa, udid, cmd_args[0]);
            return 0;
        }
        const r = try resolveUdid(gpa, opts.udid);
        defer r.deinit(gpa);
        try simctl.Sim.init(r.udid).launch(gpa, cmd_args[0]);
        return 0;
    }
    if (std.mem.eql(u8, sub, "terminate")) {
        if (cmd_args.len < 1) return errMissing("bundle-id");
        if (!opts.simulator) {
            const udid = opts.udid orelse return errMissing("--udid");
            try devicectl.terminate(gpa, udid, cmd_args[0]);
            return 0;
        }
        const r = try resolveUdid(gpa, opts.udid);
        defer r.deinit(gpa);
        try simctl.Sim.init(r.udid).terminate(gpa, cmd_args[0]);
        return 0;
    }
    if (std.mem.eql(u8, sub, "openurl") or std.mem.eql(u8, sub, "navigate")) {
        if (cmd_args.len < 1) return errMissing("url");
        const r = try resolveUdid(gpa, opts.udid);
        defer r.deinit(gpa);
        try simctl.Sim.init(r.udid).openUrl(gpa, cmd_args[0]);
        return 0;
    }
    if (std.mem.eql(u8, sub, "boot")) {
        const udid = opts.udid orelse return errMissing("--udid");
        try simctl.Sim.init(udid).boot(gpa);
        return 0;
    }
    if (std.mem.eql(u8, sub, "shutdown")) {
        const udid = opts.udid orelse return errMissing("--udid");
        try simctl.Sim.init(udid).shutdown(gpa);
        return 0;
    }
    if (std.mem.eql(u8, sub, "screenshot")) {
        const path = if (cmd_args.len >= 1) cmd_args[0] else "screenshot.png";
        if (!opts.simulator and opts.udid != null) {
            io.writeStderr("screenshot on real iOS devices requires XCUITest; not supported in v1. Use --simulator.\n");
            return 3;
        }
        const r = try resolveUdid(gpa, opts.udid);
        defer r.deinit(gpa);
        try simctl.Sim.init(r.udid).screenshot(gpa, path);
        return 0;
    }
    if (std.mem.eql(u8, sub, "list-apps")) {
        const udid = opts.udid orelse return errMissing("--udid");
        if (!opts.simulator) {
            io.writeStderr("list-apps on real device not supported in v1. Use --simulator.\n");
            return 3;
        }
        const out = try simctl.Sim.init(udid).listApps(gpa);
        defer gpa.free(out);
        io.writeStdout(out);
        return 0;
    }

    if (std.mem.eql(u8, sub, "tap")) return cmdTap(gpa, opts, cmd_args);
    if (std.mem.eql(u8, sub, "doubletap") or std.mem.eql(u8, sub, "dbltap")) return cmdDoubleTap(gpa, opts, cmd_args);
    if (std.mem.eql(u8, sub, "longpress") or std.mem.eql(u8, sub, "long-press")) return cmdLongPress(gpa, opts, cmd_args);
    if (std.mem.eql(u8, sub, "swipe") or std.mem.eql(u8, sub, "scroll") or std.mem.eql(u8, sub, "pan")) return cmdSwipe(gpa, opts, cmd_args);
    if (std.mem.eql(u8, sub, "type")) return cmdType(gpa, opts, cmd_args);
    if (std.mem.eql(u8, sub, "key")) return cmdKey(gpa, opts, cmd_args);
    if (std.mem.eql(u8, sub, "button")) return cmdButton(gpa, opts, cmd_args);
    if (std.mem.eql(u8, sub, "background")) return cmdBackground(gpa, opts, cmd_args);
    if (std.mem.eql(u8, sub, "privacy")) return cmdPrivacy(gpa, opts, cmd_args);
    if (std.mem.eql(u8, sub, "ui")) return cmdUi(gpa, opts, cmd_args);
    if (std.mem.eql(u8, sub, "status-bar") or std.mem.eql(u8, sub, "status_bar")) return cmdStatusBar(gpa, opts, cmd_args);
    if (std.mem.eql(u8, sub, "log")) return cmdLog(gpa, opts, cmd_args);

    if (std.mem.eql(u8, sub, "uitree")) return cmdUiTree(gpa, opts);

    try printUsage();
    return 1;
}

// --- tap / swipe / type implementations (Simulator only) -------------------
// Coordinates are *device pixels* matching `simctl io ... screenshot`,
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

/// Dump the running iOS app's accessibility tree.
fn cmdUiTree(gpa: std.mem.Allocator, opts: Opts) !u8 {
    if (guardSim(opts.simulator)) |code| return code;
    const r = try resolveUdid(gpa, opts.udid);
    defer r.deinit(gpa);

    try sim_window.activate(gpa);
    const els = sim_ax.dumpElements(gpa, r.udid) catch |err| switch (err) {
        error.AccessibilityTreeEmpty => {
            io.writeStderr(
                \\the simulated screen exposes no accessibility elements.
                \\
                \\Usually one of:
                \\  - no app is in the foreground (launch one first)
                \\  - the app genuinely publishes no accessibility information
                \\  - the runtime needs a moment after launch; retry
                \\
            );
            return 3;
        },
        else => return err,
    };
    defer uitree.freeElements(gpa, els);

    const text = try uitree.renderText(gpa, els);
    defer gpa.free(text);
    io.writeStdout(text);
    return 0;
}

/// Find an element whose accessibility label, identifier or value matches
/// `label`. Exact match first, then a substring fallback so callers don't
/// have to reproduce long labels verbatim.
fn findByLabel(els: []const uitree.Element, label: []const u8) ?uitree.Element {
    for (els) |e| {
        if (std.mem.eql(u8, e.desc, label) or
            std.mem.eql(u8, e.id, label) or
            std.mem.eql(u8, e.text, label)) return e;
    }
    for (els) |e| {
        if (std.mem.indexOf(u8, e.desc, label) != null or
            std.mem.indexOf(u8, e.text, label) != null) return e;
    }
    return null;
}

/// Tap whatever carries `label`, using the a11y tree's own frame. This is
/// what makes a tap survive layout changes, unlike a hard-coded coordinate.
fn tapByLabel(gpa: std.mem.Allocator, opts: Opts, label: []const u8) !u8 {
    const r = try resolveUdid(gpa, opts.udid);
    defer r.deinit(gpa);

    try sim_window.activate(gpa);
    const els = try sim_ax.dumpElements(gpa, r.udid);
    defer uitree.freeElements(gpa, els);

    const hit = findByLabel(els, label) orelse {
        var arena_impl = std.heap.ArenaAllocator.init(gpa);
        defer arena_impl.deinit();
        io.printStderr(arena_impl.allocator(), "no element matching label: {s}\n", .{label});
        return 4;
    };
    const c = uitree.centroid(hit) orelse return error.ElementHasNoBounds;
    const p = try prepSimAndPoint(gpa, r.udid, @floatFromInt(c[0]), @floatFromInt(c[1]));
    sim_input.tap(p);
    return 0;
}

fn cmdTap(gpa: std.mem.Allocator, opts: Opts, args: []const []const u8) !u8 {
    if (guardSim(opts.simulator)) |code| return code;
    if (opts.label) |l| return tapByLabel(gpa, opts, l);
    if (args.len < 2) return errMissing("x y (or --label <text>)");
    const x = try parseF64(args[0]);
    const y = try parseF64(args[1]);
    const r = try resolveUdid(gpa, opts.udid);
    defer r.deinit(gpa);
    const p = try prepSimAndPoint(gpa, r.udid, x, y);
    sim_input.tap(p);
    return 0;
}

fn cmdDoubleTap(gpa: std.mem.Allocator, opts: Opts, args: []const []const u8) !u8 {
    if (guardSim(opts.simulator)) |code| return code;
    if (args.len < 2) return errMissing("x y");
    const x = try parseF64(args[0]);
    const y = try parseF64(args[1]);
    const r = try resolveUdid(gpa, opts.udid);
    defer r.deinit(gpa);
    const p = try prepSimAndPoint(gpa, r.udid, x, y);
    sim_input.doubleTap(p);
    return 0;
}

fn cmdLongPress(gpa: std.mem.Allocator, opts: Opts, args: []const []const u8) !u8 {
    if (guardSim(opts.simulator)) |code| return code;
    if (args.len < 2) return errMissing("x y [hold_ms]");
    const x = try parseF64(args[0]);
    const y = try parseF64(args[1]);
    // iOS treats ~500ms as the threshold for "long press" / haptic touch.
    const hold: u64 = if (args.len >= 3) try std.fmt.parseInt(u64, args[2], 10) else 500;
    const r = try resolveUdid(gpa, opts.udid);
    defer r.deinit(gpa);
    const p = try prepSimAndPoint(gpa, r.udid, x, y);
    sim_input.longPress(p, hold);
    return 0;
}

fn cmdSwipe(gpa: std.mem.Allocator, opts: Opts, args: []const []const u8) !u8 {
    if (guardSim(opts.simulator)) |code| return code;
    if (args.len < 4) return errMissing("x1 y1 x2 y2 [duration_ms]");
    const x1 = try parseF64(args[0]);
    const y1 = try parseF64(args[1]);
    const x2 = try parseF64(args[2]);
    const y2 = try parseF64(args[3]);
    const dur: u64 = if (args.len >= 5) try std.fmt.parseInt(u64, args[4], 10) else 300;
    const r = try resolveUdid(gpa, opts.udid);
    defer r.deinit(gpa);
    try sim_window.activate(gpa);
    const win = try sim_window.frontWindowRect(gpa);
    const px = try sim_window.devicePixelSize(gpa, r.udid);
    const a = sim_window.deviceToScreen(win, px, x1, y1);
    const b = sim_window.deviceToScreen(win, px, x2, y2);
    sim_input.swipe(a, b, dur);
    return 0;
}

fn cmdType(gpa: std.mem.Allocator, opts: Opts, args: []const []const u8) !u8 {
    if (guardSim(opts.simulator)) |code| return code;
    if (args.len < 1) return errMissing("text");
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

/// Modified key press — the primitive for hardware-keyboard shortcuts such
/// as Command-Return, which plain `type` cannot express.
fn cmdKey(gpa: std.mem.Allocator, opts: Opts, args: []const []const u8) !u8 {
    if (guardSim(opts.simulator)) |code| return code;
    if (args.len < 1) return errMissing("key-name");

    var mods = opts.mods;
    // Also accept modifiers written bare after the key name.
    for (args[1..]) |a| {
        const name = if (std.mem.startsWith(u8, a, "--")) a[2..] else a;
        mods |= sim_input.lookupModifier(name) orelse 0;
    }

    const code = sim_input.lookupKey(args[0]) orelse {
        var arena_impl = std.heap.ArenaAllocator.init(gpa);
        defer arena_impl.deinit();
        io.printStderr(arena_impl.allocator(), "unknown key: {s}\n", .{args[0]});
        return 2;
    };

    try sim_window.activate(gpa);
    sim_input.keyPress(code, mods);
    return 0;
}

/// Simulator hardware/toolbar buttons via host AX.
fn cmdButton(gpa: std.mem.Allocator, opts: Opts, args: []const []const u8) !u8 {
    if (guardSim(opts.simulator)) |code| return code;
    if (args.len < 1) return errMissing("button-name");
    try sim_window.activate(gpa);
    try sim_ax.press(gpa, args[0]);
    return 0;
}

/// Background the app, optionally bringing it back — the lifecycle
/// transition behind "suspend during an in-flight request" and
/// "does state survive a brief background/foreground cycle" bugs.
fn cmdBackground(gpa: std.mem.Allocator, opts: Opts, args: []const []const u8) !u8 {
    if (guardSim(opts.simulator)) |code| return code;

    try sim_window.activate(gpa);
    try sim_ax.press(gpa, "home");

    const hold = opts.dur_ms orelse 3000;
    var ts: std.c.timespec = .{
        .sec = @intCast(hold / 1000),
        .nsec = @intCast((hold % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);

    // Relaunching by bundle id is how you foreground an already-running app;
    // simctl launch attaches to the existing process rather than restarting.
    if (args.len >= 1) {
        const r = try resolveUdid(gpa, opts.udid);
        defer r.deinit(gpa);
        try simctl.Sim.init(r.udid).launch(gpa, args[0]);
    }
    return 0;
}

fn cmdPrivacy(gpa: std.mem.Allocator, opts: Opts, args: []const []const u8) !u8 {
    if (args.len < 2) return errMissing("<grant|revoke|reset> <service> [bundle-id]");
    const action = args[0];
    const service = args[1];

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    if (simctl.isPrivacyUnsupported(service)) {
        io.printStderr(arena,
            \\simctl cannot control the '{s}' permission — Apple does not expose it.
            \\
            \\Supported services: microphone, photos, photos-add, location, contacts,
            \\calendar, reminders, motion, media-library, siri, all.
            \\
            \\To reset camera or speech-recognition state, erase the device
            \\(`kuri ios shutdown --udid U` then `simctl erase U`) or test on hardware.
            \\
        , .{service});
        return 3;
    }
    if (!simctl.isPrivacyService(service)) {
        io.printStderr(arena, "unknown privacy service: {s}\n", .{service});
        return 2;
    }

    const r = try resolveUdid(gpa, opts.udid);
    defer r.deinit(gpa);
    const bundle: ?[]const u8 = if (args.len >= 3) args[2] else null;
    try simctl.Sim.init(r.udid).privacy(gpa, action, service, bundle);
    return 0;
}

/// Accessibility/appearance settings — the sweep axis for Dynamic Type and
/// contrast checks. CLI uses dashes; simctl uses underscores.
fn cmdUi(gpa: std.mem.Allocator, opts: Opts, args: []const []const u8) !u8 {
    if (args.len < 1) return errMissing("<appearance|content-size|increase-contrast> [value]");
    const opt = if (std.mem.eql(u8, args[0], "content-size"))
        "content_size"
    else if (std.mem.eql(u8, args[0], "increase-contrast"))
        "increase_contrast"
    else
        args[0];

    const r = try resolveUdid(gpa, opts.udid);
    defer r.deinit(gpa);
    const value: ?[]const u8 = if (args.len >= 2) args[1] else null;
    const out = try simctl.Sim.init(r.udid).ui(gpa, opt, value);
    defer gpa.free(out);
    io.writeStdout(out);
    return 0;
}

/// Pin the status bar so screenshots are comparable across runs.
fn cmdStatusBar(gpa: std.mem.Allocator, opts: Opts, args: []const []const u8) !u8 {
    const r = try resolveUdid(gpa, opts.udid);
    defer r.deinit(gpa);
    const sim = simctl.Sim.init(r.udid);
    if (args.len >= 1 and std.mem.eql(u8, args[0], "clear")) {
        try sim.statusBarClear(gpa);
        return 0;
    }
    // Everything after an optional leading "override" is passed through.
    const extra = if (args.len >= 1 and std.mem.eql(u8, args[0], "override")) args[1..] else args;
    try sim.statusBar(gpa, extra);
    return 0;
}

/// Bounded os_log query — assertion-friendly, unlike a blocking stream.
fn cmdLog(gpa: std.mem.Allocator, opts: Opts, args: []const []const u8) !u8 {
    _ = args;
    const r = try resolveUdid(gpa, opts.udid);
    defer r.deinit(gpa);
    const out = try simctl.Sim.init(r.udid).logShow(gpa, opts.last orelse "30s", opts.predicate);
    defer gpa.free(out);
    io.writeStdout(out);
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

    // Simulators. A failure here must be reported, not swallowed: an empty
    // list and a broken toolchain are very different answers, and conflating
    // them is what made a missing Xcode look like "no devices".
    var sim_failed = false;
    const sims = simctl.listDevices(gpa) catch |err| blk: {
        sim_failed = true;
        reportToolchainError(arena, err);
        break :blk &[_]simctl.SimDevice{};
    };
    defer simctl.freeSimDevices(gpa, sims);
    for (sims) |s| {
        io.printStdout(arena, "simulator\t{s}\t{s}\t{s}\n", .{ s.udid, s.state, s.name });
    }

    // Real devices via usbmuxd — independent of Xcode, so still worth trying.
    const reals = usbmux.listDevices(gpa) catch &[_]usbmux.Device{};
    defer usbmux.freeDevices(gpa, reals);
    for (reals) |r| {
        io.printStdout(arena, "device\t{s}\t{s}\tpid={d}\n", .{ r.udid, r.connection, r.product_id });
    }

    // Nothing enumerated *and* the simulator side errored: report failure so
    // scripts don't read this as a clean "no devices attached".
    if (sim_failed and reals.len == 0) return 3;
    return 0;
}

fn reportToolchainError(arena: std.mem.Allocator, err: anyerror) void {
    switch (err) {
        error.XcodeNotFound => io.writeStderr(
            \\error: no Xcode toolchain with `simctl` found.
            \\
            \\`xcode-select -p` may point at CommandLineTools, which has no simctl.
            \\Fix with one of:
            \\  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
            \\  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer kuri ios ...
            \\
        ),
        // xcode.run already printed the tool's own diagnostic.
        error.CommandFailed => {},
        else => io.printStderr(arena, "error listing simulators: {s}\n", .{@errorName(err)}),
    }
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
        \\  tap       [--udid U] <x> <y> | --label <text>
        \\  doubletap [--udid U] <x> <y>                          (alias: dbltap)
        \\  longpress [--udid U] <x> <y> [hold_ms]                (alias: long-press; default 500ms)
        \\  swipe     [--udid U] <x1> <y1> <x2> <y2> [duration_ms]   (alias: scroll, pan)
        \\  type      [--udid U] <text...>
        \\  key       <name> [--cmd|--shift|--ctrl|--opt]         e.g. `key return --cmd`
        \\                                                        names: return enter tab space
        \\                                                               delete escape left right up down
        \\
        \\Accessibility tree (Simulator, no XCUITest needed):
        \\  uitree                             flat element list: role, a11y id, label, bounds
        \\                                     bounds are device pixels, matching tap/screenshot
        \\
        \\Hardware buttons (via Simulator's own accessibility tree):
        \\  button    <home|lock|volup|voldown|action|rotate>
        \\  background [--for MS] [bundle-id]  press Home, wait, then re-foreground
        \\
        \\Device state:
        \\  privacy   <grant|revoke|reset> <service> [bundle-id]
        \\  ui        <appearance|content-size|increase-contrast> [value]
        \\  status-bar override --time 9:41 ... | status-bar clear
        \\  log       [--last 30s] [--predicate 'subsystem == "com.example.app"']
        \\
        \\Not implemented in v1 (driverless mode):
        \\  tap, swipe, type, uitree on real iOS devices    -> need XCUITest (no host process to inspect)
        \\  pinch / rotate / two-finger gestures            -> need multi-touch wiring
        \\  camera & speech-recognition permissions         -> not exposed by simctl privacy
        \\
    );
}
