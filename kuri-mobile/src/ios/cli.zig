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
const tools = @import("tools.zig");
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
    /// Upper bound for `wait-for-ui` polling.
    timeout_ms: ?u64 = null,
    /// Invert `wait-for-ui`: wait for the element to go away.
    absent: bool = false,
    /// Machine-readable output where a command supports it.
    json: bool = false,
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
    if (std.mem.eql(u8, name, "absent")) {
        opts.absent = true;
        return 1;
    }
    if (std.mem.eql(u8, name, "json")) {
        opts.json = true;
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
        std.mem.eql(u8, name, "timeout") or
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
    } else if (std.mem.eql(u8, name, "timeout")) {
        opts.timeout_ms = try std.fmt.parseInt(u64, val, 10);
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

    if (std.mem.eql(u8, sub, "tools")) return cmdTools(gpa, opts);

    if (std.mem.eql(u8, sub, "list-devices") or std.mem.eql(u8, sub, "devices")) {
        return cmdListDevices(gpa);
    }
    if (std.mem.eql(u8, sub, "erase")) {
        const udid = opts.udid orelse return errMissing("--udid");
        try simctl.Sim.init(udid).erase(gpa);
        return 0;
    }
    if (std.mem.eql(u8, sub, "open-sim")) {
        try simctl.openSimulatorApp(gpa);
        return 0;
    }
    if (std.mem.eql(u8, sub, "install")) {
        if (cmd_args.len < 1) return errMissing("path.app");
        if (!opts.simulator) {
            const udid = opts.udid orelse return errMissing("--udid");
            try devicectl.install(gpa, udid, cmd_args[0]);
            return 0;
        }
        const r = try resolveUdid(gpa, opts.udid);
        defer r.deinit(gpa);
        try simctl.Sim.init(r.udid).install(gpa, cmd_args[0]);
        return 0;
    }
    if (std.mem.eql(u8, sub, "uninstall")) {
        if (cmd_args.len < 1) return errMissing("bundle-id");
        if (!opts.simulator) {
            const udid = opts.udid orelse return errMissing("--udid");
            try devicectl.uninstall(gpa, udid, cmd_args[0]);
            return 0;
        }
        const r = try resolveUdid(gpa, opts.udid);
        defer r.deinit(gpa);
        try simctl.Sim.init(r.udid).uninstall(gpa, cmd_args[0]);
        return 0;
    }
    // Real-device inspection. devicectl exposes no screenshot or UI tree, so
    // these are the commands a physical device genuinely supports.
    if (std.mem.eql(u8, sub, "device-info") or std.mem.eql(u8, sub, "device-processes") or
        std.mem.eql(u8, sub, "lock-state") or std.mem.eql(u8, sub, "displays") or
        std.mem.eql(u8, sub, "reboot"))
    {
        const udid = opts.udid orelse return errMissing("--udid");
        if (std.mem.eql(u8, sub, "reboot")) {
            try devicectl.reboot(gpa, udid);
            return 0;
        }
        const out = if (std.mem.eql(u8, sub, "device-info"))
            try devicectl.details(gpa, udid)
        else if (std.mem.eql(u8, sub, "device-processes"))
            try devicectl.processes(gpa, udid)
        else if (std.mem.eql(u8, sub, "lock-state"))
            try devicectl.lockState(gpa, udid)
        else
            try devicectl.displays(gpa, udid);
        defer gpa.free(out);
        io.writeStdout(out);
        return 0;
    }
    if (std.mem.eql(u8, sub, "set-location")) {
        if (cmd_args.len < 2) return errMissing("<lat> <lon>");
        const r = try resolveUdid(gpa, opts.udid);
        defer r.deinit(gpa);
        try simctl.Sim.init(r.udid).setLocation(gpa, cmd_args[0], cmd_args[1]);
        return 0;
    }
    if (std.mem.eql(u8, sub, "reset-location")) {
        const r = try resolveUdid(gpa, opts.udid);
        defer r.deinit(gpa);
        try simctl.Sim.init(r.udid).clearLocation(gpa);
        return 0;
    }
    if (std.mem.eql(u8, sub, "keyboard")) {
        if (cmd_args.len < 1) return errMissing("<on|off>");
        const on = std.mem.eql(u8, cmd_args[0], "on");
        if (!on and !std.mem.eql(u8, cmd_args[0], "off")) return errMissing("<on|off>");
        try simctl.setHardwareKeyboard(gpa, on);
        return 0;
    }
    if (std.mem.eql(u8, sub, "record-video")) {
        if (cmd_args.len < 1) return errMissing("path.mp4");
        const r = try resolveUdid(gpa, opts.udid);
        defer r.deinit(gpa);
        try simctl.Sim.init(r.udid).recordVideo(gpa, cmd_args[0], opts.dur_ms orelse 5000);
        return 0;
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
        const out = if (opts.simulator)
            try simctl.Sim.init(udid).listApps(gpa)
        else
            try devicectl.listApps(gpa, udid);
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

    if (std.mem.eql(u8, sub, "gesture") or std.mem.eql(u8, sub, "drag")) return cmdGesture(gpa, opts, cmd_args);
    if (std.mem.eql(u8, sub, "touch")) return cmdTouch(gpa, opts, cmd_args);
    if (std.mem.eql(u8, sub, "key-sequence")) return cmdKeySequence(gpa, opts, cmd_args);
    if (std.mem.eql(u8, sub, "batch")) return cmdBatch(gpa, opts, cmd_args);

    if (std.mem.eql(u8, sub, "uitree")) return cmdUiTree(gpa, opts);
    if (std.mem.eql(u8, sub, "find")) return cmdFind(gpa, opts);
    if (std.mem.eql(u8, sub, "wait-for-ui")) return cmdWaitForUi(gpa, opts);

    try printUsage();
    return 1;
}

/// The meta tool: enumerate the command surface. `--json` is the form an
/// agent consumes to discover what it can call without parsing help text.
fn cmdTools(gpa: std.mem.Allocator, opts: Opts) !u8 {
    const text = if (opts.json) try tools.renderJson(gpa) else try tools.renderText(gpa);
    defer gpa.free(text);
    io.writeStdout(text);
    return 0;
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

/// Send literal text to the Simulator's focused field.
///
/// Routed through System Events `keystroke` rather than CGEvent because it is
/// Unicode-safe and needs no virtual-keycode table. Assumes the caller has
/// already brought the Simulator forward.
fn typeText(gpa: std.mem.Allocator, text: []const u8) !void {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // Escape backslashes and double-quotes for the AppleScript string literal.
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(arena);
    for (text) |c| {
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
}

fn cmdType(gpa: std.mem.Allocator, opts: Opts, args: []const []const u8) !u8 {
    if (guardSim(opts.simulator)) |code| return code;
    if (args.len < 1) return errMissing("text");
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

    try typeText(gpa, joined.items);
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

/// Parse an "x,y" pair. Used by `gesture`, where packing each point into one
/// token keeps a long path readable on the command line.
fn parsePoint(tok: []const u8) !struct { x: f64, y: f64 } {
    const comma = std.mem.indexOfScalar(u8, tok, ',') orelse return error.BadPoint;
    return .{
        .x = try parseF64(tok[0..comma]),
        .y = try parseF64(tok[comma + 1 ..]),
    };
}

/// Drag along a multi-point path.
fn cmdGesture(gpa: std.mem.Allocator, opts: Opts, args: []const []const u8) !u8 {
    if (guardSim(opts.simulator)) |code| return code;
    if (args.len < 2) return errMissing("<x1,y1> <x2,y2> [x3,y3 ...]");

    const r = try resolveUdid(gpa, opts.udid);
    defer r.deinit(gpa);
    try sim_window.activate(gpa);
    const win = try sim_window.frontWindowRect(gpa);
    const px = try sim_window.devicePixelSize(gpa, r.udid);

    var pts: std.ArrayList(sim_input.CGPoint) = .empty;
    defer pts.deinit(gpa);
    for (args) |tok| {
        const p = parsePoint(tok) catch {
            var arena_impl = std.heap.ArenaAllocator.init(gpa);
            defer arena_impl.deinit();
            io.printStderr(arena_impl.allocator(), "expected x,y — got: {s}\n", .{tok});
            return 2;
        };
        try pts.append(gpa, sim_window.deviceToScreen(win, px, p.x, p.y));
    }

    sim_input.gesture(pts.items, opts.dur_ms orelse 400);
    return 0;
}

/// Raw touch down/move/up, for gestures the named commands don't cover.
fn cmdTouch(gpa: std.mem.Allocator, opts: Opts, args: []const []const u8) !u8 {
    if (guardSim(opts.simulator)) |code| return code;
    if (args.len < 3) return errMissing("<down|up|move> <x> <y>");
    const phase = args[0];
    const x = try parseF64(args[1]);
    const y = try parseF64(args[2]);

    const r = try resolveUdid(gpa, opts.udid);
    defer r.deinit(gpa);
    const p = try prepSimAndPoint(gpa, r.udid, x, y);

    if (std.mem.eql(u8, phase, "down")) {
        sim_input.touchDown(p);
    } else if (std.mem.eql(u8, phase, "move")) {
        sim_input.touchMove(p);
    } else if (std.mem.eql(u8, phase, "up")) {
        sim_input.touchUp(p);
    } else {
        var arena_impl = std.heap.ArenaAllocator.init(gpa);
        defer arena_impl.deinit();
        io.printStderr(arena_impl.allocator(), "unknown touch phase: {s} (want down|move|up)\n", .{phase});
        return 2;
    }
    return 0;
}

/// Press several named keys in order — `key-sequence tab tab return`.
fn cmdKeySequence(gpa: std.mem.Allocator, opts: Opts, args: []const []const u8) !u8 {
    if (guardSim(opts.simulator)) |code| return code;
    if (args.len < 1) return errMissing("key-name [key-name ...]");

    // Validate the whole sequence before pressing anything: a typo halfway
    // through would otherwise leave the UI in a half-driven state.
    for (args) |name| {
        if (sim_input.lookupKey(name) == null) {
            var arena_impl = std.heap.ArenaAllocator.init(gpa);
            defer arena_impl.deinit();
            io.printStderr(arena_impl.allocator(), "unknown key: {s}\n", .{name});
            return 2;
        }
    }

    try sim_window.activate(gpa);
    for (args) |name| {
        sim_input.keyPress(sim_input.lookupKey(name).?, opts.mods);
        io.sleepMs(60);
    }
    return 0;
}

/// Run several actions in one process.
///
/// The win is not syntax but setup cost: resolving the UDID and activating
/// the Simulator window happen once for the whole sequence instead of once
/// per command, which is most of the wall-clock in a per-action shell loop.
fn cmdBatch(gpa: std.mem.Allocator, opts: Opts, args: []const []const u8) !u8 {
    if (guardSim(opts.simulator)) |code| return code;
    if (args.len < 1) return errMissing("<action> [action ...]  e.g. tap:120,400 type:hi key:return");

    const r = try resolveUdid(gpa, opts.udid);
    defer r.deinit(gpa);
    try sim_window.activate(gpa);
    const win = try sim_window.frontWindowRect(gpa);
    const px = try sim_window.devicePixelSize(gpa, r.udid);

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
            // Everything after the colon is literal text, commas included.
            try typeText(gpa, rest);
            continue;
        }
        if (std.mem.eql(u8, verb, "key")) {
            const code = sim_input.lookupKey(rest) orelse {
                io.printStderr(arena, "step {d}: unknown key '{s}'\n", .{ step + 1, rest });
                return 2;
            };
            sim_input.keyPress(code, 0);
            continue;
        }
        if (std.mem.eql(u8, verb, "button")) {
            try sim_ax.press(gpa, rest);
            continue;
        }
        if (std.mem.eql(u8, verb, "label")) {
            const els = try sim_ax.dumpElements(gpa, r.udid);
            defer uitree.freeElements(gpa, els);
            const hit = findByLabel(els, rest) orelse {
                io.printStderr(arena, "step {d}: no element matching label '{s}'\n", .{ step + 1, rest });
                return 4;
            };
            const c = uitree.centroid(hit) orelse return error.ElementHasNoBounds;
            sim_input.tap(sim_window.deviceToScreen(win, px, @floatFromInt(c[0]), @floatFromInt(c[1])));
            continue;
        }

        // Remaining verbs are all comma-separated numbers.
        var nums: std.ArrayList(f64) = .empty;
        defer nums.deinit(gpa);
        var it = std.mem.splitScalar(u8, rest, ',');
        while (it.next()) |n| {
            if (n.len == 0) continue;
            try nums.append(gpa, parseF64(n) catch {
                io.printStderr(arena, "step {d}: '{s}' is not a number\n", .{ step + 1, n });
                return 2;
            });
        }
        const v = nums.items;

        if (std.mem.eql(u8, verb, "tap") and v.len >= 2) {
            sim_input.tap(sim_window.deviceToScreen(win, px, v[0], v[1]));
        } else if (std.mem.eql(u8, verb, "doubletap") and v.len >= 2) {
            sim_input.doubleTap(sim_window.deviceToScreen(win, px, v[0], v[1]));
        } else if (std.mem.eql(u8, verb, "longpress") and v.len >= 2) {
            const hold: u64 = if (v.len >= 3) @intFromFloat(v[2]) else 500;
            sim_input.longPress(sim_window.deviceToScreen(win, px, v[0], v[1]), hold);
        } else if (std.mem.eql(u8, verb, "swipe") and v.len >= 4) {
            const dur: u64 = if (v.len >= 5) @intFromFloat(v[4]) else 300;
            sim_input.swipe(
                sim_window.deviceToScreen(win, px, v[0], v[1]),
                sim_window.deviceToScreen(win, px, v[2], v[3]),
                dur,
            );
        } else {
            io.printStderr(arena, "step {d}: unknown or malformed action '{s}'\n", .{ step + 1, spec });
            return 2;
        }
    }
    return 0;
}

/// Print every element matching `--label`, with a tap-ready centroid.
/// Unlike `tap --label` this reports *all* candidates, which is what you
/// want when a tap targeted the wrong one of several similar labels.
fn cmdFind(gpa: std.mem.Allocator, opts: Opts) !u8 {
    if (guardSim(opts.simulator)) |code| return code;
    const label = opts.label orelse return errMissing("--label <text>");

    const r = try resolveUdid(gpa, opts.udid);
    defer r.deinit(gpa);
    try sim_window.activate(gpa);
    const els = try sim_ax.dumpElements(gpa, r.udid);
    defer uitree.freeElements(gpa, els);

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var hits: usize = 0;
    for (els) |e| {
        const matches = std.mem.indexOf(u8, e.desc, label) != null or
            std.mem.indexOf(u8, e.text, label) != null or
            std.mem.eql(u8, e.id, label);
        if (!matches) continue;
        hits += 1;
        if (uitree.centroid(e)) |c| {
            io.printStdout(arena, "{s}\tid={s}\tlabel={s}\ttap={d},{d}\n", .{ e.class, e.id, e.desc, c[0], c[1] });
        } else {
            io.printStdout(arena, "{s}\tid={s}\tlabel={s}\ttap=-\n", .{ e.class, e.id, e.desc });
        }
    }
    // Exit non-zero on no match so `find` is usable directly as a test assertion.
    if (hits == 0) {
        io.printStderr(arena, "no element matching label: {s}\n", .{label});
        return 4;
    }
    return 0;
}

/// Block until an element appears (or, with --absent, goes away).
///
/// This is the piece that lets an agent stop guessing at sleeps: it polls the
/// accessibility tree rather than the clock, so it returns as soon as the UI
/// is actually ready and fails loudly when it never becomes ready.
fn cmdWaitForUi(gpa: std.mem.Allocator, opts: Opts) !u8 {
    if (guardSim(opts.simulator)) |code| return code;
    const label = opts.label orelse return errMissing("--label <text>");
    const timeout = opts.timeout_ms orelse 10_000;
    const poll_ms: u64 = 250;

    const r = try resolveUdid(gpa, opts.udid);
    defer r.deinit(gpa);
    try sim_window.activate(gpa);

    // Deadline is wall-clock, not a count of sleeps. Each poll costs a simctl
    // spawn plus an accessibility walk (~0.5s), so summing only the sleep
    // intervals would overshoot a requested timeout by several times over.
    const deadline = io.monotonicMs() + @as(i64, @intCast(timeout));
    while (true) {
        // A tree that isn't readable yet is a "not yet", not a hard failure:
        // on a freshly booted simulator the accessibility bridge takes a few
        // seconds to populate, which is precisely what callers wait through.
        const present = blk: {
            const els = sim_ax.dumpElements(gpa, r.udid) catch break :blk false;
            defer uitree.freeElements(gpa, els);
            break :blk findByLabel(els, label) != null;
        };
        if (present != opts.absent) return 0;

        if (io.monotonicMs() >= deadline) break;
        io.sleepMs(poll_ms);
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

/// Rendered from the same table `ios tools` serves, so a command can never
/// exist in the dispatcher but go missing from the help.
fn printUsage() !void {
    io.writeStderr(
        \\kuri-mobile ios <cmd> [args]
        \\
        \\Global flags: --udid U  --simulator|--device  --json
        \\Run `kuri-mobile ios tools --json` for the machine-readable surface.
        \\
        \\
    );

    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const text = tools.renderText(gpa_impl.allocator()) catch return;
    defer gpa_impl.allocator().free(text);
    io.writeStderr(text);

    io.writeStderr(
        \\Not supported in v1 (driverless mode):
        \\  tap, swipe, type, uitree on real iOS devices  -> need XCUITest (no host process to inspect)
        \\  pinch / two-finger gestures                   -> need multi-touch wiring
        \\  camera & speech-recognition permissions       -> not exposed by simctl privacy
        \\
    );
}
