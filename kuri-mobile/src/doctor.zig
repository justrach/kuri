//! `kuri-mobile doctor` — check the preconditions before they bite.
//!
//! Every check here corresponds to a failure that is otherwise diagnosed
//! badly at the point of use: a CommandLineTools-only `xcode-select` makes
//! device listing look empty rather than broken, and a missing Accessibility
//! grant makes taps silently do nothing. Reporting them up front, with the
//! exact remedy, is cheaper than debugging the symptom.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("common/io.zig");
const xcode = @import("ios/xcode.zig");
const simctl = @import("ios/simctl.zig");
const sim_ax = @import("ios/sim_ax.zig");
const adb = @import("android/adb.zig");

const Status = enum {
    ok,
    warn,
    fail,

    fn mark(self: Status) []const u8 {
        return switch (self) {
            .ok => "ok  ",
            .warn => "warn",
            .fail => "FAIL",
        };
    }
};

const Report = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    failures: usize = 0,

    fn line(self: *Report, status: Status, name: []const u8, detail: []const u8) void {
        if (status == .fail) self.failures += 1;
        io.printStdout(self.arena, "[{s}] {s}: {s}\n", .{ status.mark(), name, detail });
    }

    fn hint(self: *Report, text: []const u8) void {
        io.printStdout(self.arena, "         -> {s}\n", .{text});
    }
};

pub fn run(gpa: std.mem.Allocator) !u8 {
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    var rep: Report = .{ .gpa = gpa, .arena = arena_impl.allocator() };

    io.writeStdout("kuri-mobile doctor\n\n");

    // --- host ---------------------------------------------------------------
    io.writeStdout("iOS\n");
    if (builtin.os.tag != .macos) {
        rep.line(.warn, "host", "not macOS — iOS commands are unavailable, Android still works");
    } else {
        rep.line(.ok, "host", "macOS");

        // --- toolchain ------------------------------------------------------
        if (xcode.developerDir(gpa)) |dir| {
            rep.line(.ok, "developer dir", dir);
            const simctl_path = try std.fmt.allocPrint(rep.arena, "{s}/usr/bin/simctl", .{dir});
            if (xcode.fileExists(simctl_path)) {
                rep.line(.ok, "simctl", simctl_path);
            } else {
                rep.line(.fail, "simctl", "not present in the resolved toolchain");
            }
        } else |err| {
            rep.line(.fail, "developer dir", @errorName(err));
            rep.hint("sudo xcode-select -s /Applications/Xcode.app/Contents/Developer");
            rep.hint("or set DEVELOPER_DIR to an Xcode.app that ships simctl");
        }

        // --- accessibility --------------------------------------------------
        if (sim_ax.accessibilityTrusted()) {
            rep.line(.ok, "accessibility", "this process is trusted");
        } else {
            rep.line(.fail, "accessibility", "not trusted — tap/swipe/type/uitree/button will not work");
            rep.hint("System Settings -> Privacy & Security -> Accessibility, add your terminal");
        }

        // --- Simulator.app --------------------------------------------------
        if (sim_ax.simulatorPid(gpa)) |maybe_pid| {
            if (maybe_pid) |pid| {
                const d = try std.fmt.allocPrint(rep.arena, "running (pid {d})", .{pid});
                rep.line(.ok, "Simulator.app", d);
            } else {
                rep.line(.warn, "Simulator.app", "not running — input and uitree need it open");
                rep.hint("kuri-mobile ios open-sim");
            }
        } else |err| {
            rep.line(.warn, "Simulator.app", @errorName(err));
        }

        // --- devices --------------------------------------------------------
        if (simctl.listDevices(gpa)) |sims| {
            defer simctl.freeSimDevices(gpa, sims);
            var booted: usize = 0;
            for (sims) |s| {
                if (std.mem.eql(u8, s.state, "Booted")) booted += 1;
            }
            const d = try std.fmt.allocPrint(rep.arena, "{d} available, {d} booted", .{ sims.len, booted });
            if (booted == 0) {
                rep.line(.warn, "simulators", d);
                rep.hint("kuri-mobile ios boot --udid <UDID>");
            } else {
                rep.line(.ok, "simulators", d);
            }
        } else |err| {
            rep.line(.fail, "simulators", @errorName(err));
        }
    }

    // --- android ------------------------------------------------------------
    io.writeStdout("\nAndroid\n");
    var client = adb.Client.init(gpa);
    if (client.hostQuery("host:version")) |ver| {
        defer gpa.free(ver);
        const d = try std.fmt.allocPrint(rep.arena, "reachable on 127.0.0.1:5037 (protocol {s})", .{
            std.mem.trim(u8, ver, " \t\r\n"),
        });
        rep.line(.ok, "adb server", d);
    } else |err| {
        // A missing adb server is a warning, not a failure: it blocks only the
        // Android half, and plenty of users of this tool never touch Android.
        rep.line(.warn, "adb server", @errorName(err));
        rep.hint("adb start-server (Android commands only; iOS is unaffected)");
    }

    io.writeStdout("\n");
    if (rep.failures == 0) {
        io.writeStdout("no blocking problems found.\n");
        return 0;
    }
    io.printStdout(rep.arena, "{d} blocking problem(s) found.\n", .{rep.failures});
    return 3;
}
