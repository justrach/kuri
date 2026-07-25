//! Shared plumbing for the end-to-end suites.
//!
//! Both suites drive the *built binary* rather than calling into the library,
//! so what they assert on is exactly what a user or an agent would observe:
//! an exit code and some text. That makes the assertion vocabulary small —
//! exit codes, substring presence, substring absence — and worth sharing so
//! the two suites report identically.
//!
//! The counters are module-level rather than threaded through a context: a
//! suite is one process running one sequence, and a global tally keeps every
//! call site down to the assertion itself.

const std = @import("std");
const io = @import("io");

pub var passed: usize = 0;
pub var failed: usize = 0;
pub var skipped: usize = 0;

pub const Result = struct {
    stdout: []u8,
    code: i32,
    elapsed_ms: i64,

    pub fn deinit(self: Result, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
    }
};

/// Invoke the built binary with `args`, capturing output and timing.
/// `runCommand` merges stderr into stdout, so `stdout` carries diagnostics too.
pub fn run(gpa: std.mem.Allocator, bin: []const u8, args: []const []const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bin);
    try argv.appendSlice(gpa, args);

    const start = io.monotonicMs();
    const r = try io.runCommand(gpa, argv.items, 32 * 1024 * 1024);
    return .{
        .stdout = r.stdout,
        .code = (r.term >> 8) & 0xFF,
        .elapsed_ms = io.monotonicMs() - start,
    };
}

pub fn report(arena: std.mem.Allocator, ok: bool, name: []const u8, detail: []const u8) void {
    if (ok) {
        passed += 1;
        io.printStdout(arena, "  ok   {s}\n", .{name});
    } else {
        failed += 1;
        io.printStdout(arena, "  FAIL {s}: {s}\n", .{ name, detail });
    }
}

/// A precondition the machine cannot supply. Distinct from a failure on
/// purpose: these suites run in CI, where a missing simulator or a missing
/// Accessibility grant is the environment, not a regression.
pub fn skip(arena: std.mem.Allocator, name: []const u8, why: []const u8) void {
    skipped += 1;
    io.printStdout(arena, "  skip {s} ({s})\n", .{ name, why });
}

pub fn expectCode(arena: std.mem.Allocator, name: []const u8, r: Result, want: i32) void {
    if (r.code == want) return report(arena, true, name, "");
    const d = std.fmt.allocPrint(arena, "exit {d}, wanted {d}", .{ r.code, want }) catch "exit mismatch";
    report(arena, false, name, d);
}

/// The core anti-silent-success assertion: a command that could not have done
/// anything must not report that it did.
pub fn expectNonZero(arena: std.mem.Allocator, name: []const u8, r: Result) void {
    if (r.code != 0) return report(arena, true, name, "");
    report(arena, false, name, "exited 0 — a command that did nothing reported success");
}

pub fn expectContains(arena: std.mem.Allocator, name: []const u8, haystack: []const u8, needle: []const u8) void {
    if (std.mem.indexOf(u8, haystack, needle) != null) return report(arena, true, name, "");
    const d = std.fmt.allocPrint(arena, "output did not contain '{s}'", .{needle}) catch "missing substring";
    report(arena, false, name, d);
}

pub fn expectExcludes(arena: std.mem.Allocator, name: []const u8, haystack: []const u8, needle: []const u8) void {
    if (std.mem.indexOf(u8, haystack, needle) == null) return report(arena, true, name, "");
    const d = std.fmt.allocPrint(arena, "output contained '{s}'", .{needle}) catch "unexpected substring";
    report(arena, false, name, d);
}

pub fn getEnv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

/// Print the tally and exit. Skips never fail the run.
pub fn finish(arena: std.mem.Allocator) noreturn {
    io.printStdout(arena, "\n{d} passed, {d} failed, {d} skipped\n", .{ passed, failed, skipped });
    std.process.exit(if (failed == 0) 0 else 1);
}
