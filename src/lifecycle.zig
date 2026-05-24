const std = @import("std");
const launcher = @import("chrome/launcher.zig");

/// 🛑 SIGINT/SIGTERM hook so kuri's `defer chrome.deinit()` actually runs.
///
/// Without this, Ctrl+C in the foreground or `kill <pid>` from a supervisor
/// drops kuri instantly: the OS doesn't unwind Zig defers, the child Chrome
/// becomes orphaned, and its SingletonLock/SingletonSocket are left behind
/// pointing at a now-dead PID. The next `kuri` then hangs for ~15s in
/// waitForDebuggerUrl before erroring out with ConnectionRefused.
///
/// We install a tiny C signal handler that calls `Launcher.deinit` (which is
/// just `kill(pid, SIGKILL); waitpid(pid)` — both signal-safe) on the global
/// launcher pointer, then `_exit(128 + sig)` so we don't try to unwind Zig
/// code from inside a signal frame.
var launcher_ptr: ?*launcher.Launcher = null;

pub fn install(l: *launcher.Launcher) void {
    if (@import("builtin").os.tag == .windows) {
        launcher_ptr = l;
        return;
    }

    var sa: std.c.Sigaction = std.mem.zeroes(std.c.Sigaction);
    sa.handler = .{ .handler = handler };
    sa.flags = std.c.SA.RESTART;

    _ = std.c.sigaction(std.c.SIG.INT, &sa, null);
    _ = std.c.sigaction(std.c.SIG.TERM, &sa, null);
    _ = std.c.sigaction(std.c.SIG.HUP, &sa, null);
}

fn handler(sig: std.c.SIG) callconv(.c) void {
    if (launcher_ptr) |l| {
        l.deinit();
        launcher_ptr = null;
    }
    // Skip Zig's std.process.exit — that re-enters allocators and stdio. Use
    // the libc primitive that just sets the exit code and goes.
    std.c.exit(128 + @as(c_int, @intCast(@intFromEnum(sig))));
}
