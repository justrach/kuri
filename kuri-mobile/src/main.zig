//! kuri-mobile — drive Android and iOS devices from the command line.
//!
//! Layout:
//!     kuri-mobile android <cmd> ...   (adb wire protocol, native Zig)
//!     kuri-mobile ios     <cmd> ...   (simctl + usbmuxd + devicectl)
//!
//! v1 scope is "driverless": no on-device app is installed. This trades
//! `run_code` and rich iOS real-device UI tree for a clean, dependency-free
//! Zig host. See README for details.

const std = @import("std");
const android_cli = @import("android/cli.zig");
const ios_cli = @import("ios/cli.zig");
const io = @import("common/io.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const argv = try init.args.toSlice(arena);

    if (argv.len < 2) {
        try printUsage();
        std.process.exit(1);
    }

    const sub = argv[1];
    const rest = argv[2..];

    if (std.mem.eql(u8, sub, "android")) {
        const code = android_cli.run(gpa, rest) catch |err| return reportError(err);
        if (code != 0) std.process.exit(code);
        return;
    }
    if (std.mem.eql(u8, sub, "ios")) {
        const code = ios_cli.run(gpa, rest) catch |err| return reportError(err);
        if (code != 0) std.process.exit(code);
        return;
    }
    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h") or std.mem.eql(u8, sub, "help")) {
        try printUsage();
        return;
    }
    if (std.mem.eql(u8, sub, "--version")) {
        try writeStdout("kuri-mobile 0.0.1\n");
        return;
    }

    try printUsage();
    std.process.exit(1);
}

fn printUsage() !void {
    io.writeStderr(
        \\kuri-mobile <platform> <cmd> [args]
        \\
        \\Platforms:
        \\  android   drive Android devices via adb (Zig-native client)
        \\  ios       drive iOS simulators (simctl) and real devices (devicectl)
        \\
        \\Run `kuri-mobile <platform>` with no args for per-platform help.
        \\
    );
}

fn writeStdout(s: []const u8) !void {
    io.writeStdout(s);
}

/// Print a friendly one-liner for known errors and exit with a non-zero
/// code, instead of letting Zig dump a release-mode stack trace. Falls
/// back to `error: <name>` for anything we don't recognize.
fn reportError(err: anyerror) noreturn {
    const name = @errorName(err);
    const friendly: []const u8 = switch (err) {
        error.AdbServerUnreachable => "could not reach adb server on 127.0.0.1:5037. Is `adb start-server` running?",
        error.DeviceNotFound => "no device attached. Plug in a phone with USB debugging enabled, or boot an emulator.",
        error.AdbCommandFailed => "adb returned FAIL — see the warning log above for details.",
        error.AdbProtocolError => "unexpected response from adb server (protocol error).",
        error.UnexpectedEof => "adb connection closed mid-message.",
        error.UnknownButton => "unknown button name; run the platform subcommand with no args for the supported list.",
        error.NoBootedSimulator => "no booted iOS Simulator found. Run `kuri-mobile ios boot --udid <UDID>` first or pass --udid.",
        error.XcodeNotFound =>
            \\no Xcode toolchain with `simctl` found. `xcode-select -p` may point at
            \\CommandLineTools, which does not ship simctl. Fix with either:
            \\  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
            \\  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer kuri-mobile ios ...
        ,
        // xcode.run already printed the failing tool's own diagnostic above.
        error.CommandFailed => "the Xcode tool reported a failure (see the message above).",
        error.AccessibilityNotTrusted => "macOS Accessibility permission is required to drive the Simulator. Grant it to your terminal in System Settings -> Privacy & Security -> Accessibility.",
        error.SimulatorNotRunning => "Simulator.app is not running. Boot a simulator first (`kuri-mobile ios boot --udid <UDID>`).",
        error.ButtonNotFound => "that button is not present in the current Simulator window (some buttons only appear for certain device types).",
        error.ButtonPressFailed => "the Simulator rejected the button press.",
        error.MacOsOnly => "iOS commands are macOS-only.",
        else => "",
    };
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();
    if (friendly.len != 0) {
        io.printStderr(arena_impl.allocator(), "error: {s}\n", .{friendly});
    } else {
        io.printStderr(arena_impl.allocator(), "error: {s}\n", .{name});
    }
    std.process.exit(1);
}

// Pull all module tests in.
test {
    _ = @import("android/adb.zig");
    _ = @import("android/driver.zig");
    _ = @import("common/uitree.zig");
    _ = @import("ios/usbmux.zig");
    _ = @import("ios/xcode.zig");
    _ = @import("ios/simctl.zig");
    _ = @import("ios/sim_ax.zig");
    _ = @import("ios/sim_input.zig");
    _ = @import("ios/sim_window.zig");
}
