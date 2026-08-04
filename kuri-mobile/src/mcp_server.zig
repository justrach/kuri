//! `kuri-mobile mcp` — the Model Context Protocol face of the tool tables,
//! built on the mcp-zig library (github.com/justrach/mcp-zig).
//!
//! COMPARISON.md calls the missing MCP transport "the only gap that changes
//! what kuri *is* rather than how much it covers", and predicts it can be
//! generated from the tool tables instead of hand-written. This file is that
//! prediction made true twice over: the *tool registry* is generated at
//! comptime from `ios/tools.zig` and `android/tools.zig`, and the *protocol*
//! (JSON-RPC loop, version negotiation, logging, notifications, stateless
//! 2026-07-28 mode) is mcp-zig's, not ours. A command added to a table
//! appears as an MCP tool with zero further work; a protocol revision lands
//! by bumping the dependency.
//!
//! `tools/call` re-executes this same binary as a child process rather than
//! dispatching in-process — stdout belongs to the protocol here, and the CLI
//! writes to it freely. A ~2 MB static binary respawns in single-digit
//! milliseconds, which is cheaper than being wrong about fd ownership.

const std = @import("std");
const mcp = @import("mcp");
const cio = @import("common/io.zig");
const toolinfo = @import("common/toolinfo.zig");
const ios_tools = @import("ios/tools.zig");
const android_tools = @import("android/tools.zig");

const max_tool_output = 8 * 1024 * 1024;

/// argv[0], set by main before `run`. tools/call re-invokes it through
/// execvp, so a PATH-resolved invocation re-resolves the same way.
pub var self_exe: []const u8 = "kuri-mobile";

/// Serve MCP over stdio until the client closes the stream.
pub fn run(gpa: std.mem.Allocator, io_impl: std.Io) !u8 {
    mcp.runWithRegistry(gpa, io_impl, Registry);
    return 0;
}

// ── comptime registry generation ─────────────────────────────────────────────

/// Every tool takes the same argument: the CLI tokens it would receive on a
/// terminal. The per-tool description carries the usage; keeping the schema
/// uniform keeps the mapping to the CLI exact.
const args_schema =
    \\{"type":"object","properties":{"args":{"type":"array","items":{"type":"string"},"description":"raw CLI tokens, positionals then flags, e.g. [\"12\",\"34\"] or [\"--udid\",\"ABC\"]"}}}
;

/// MCP tool names allow [a-zA-Z0-9_-]; the CLI's dashes are normalized to
/// underscores so every client tokenizer treats a name as one word.
fn underscored(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (s) |c| out = out ++ &[_]u8{if (c == '-') '_' else c};
        return out;
    }
}

/// Dispatch metadata parallel to the ToolDef list: which platform subcommand
/// an MCP tool name maps back to.
const Target = struct { platform: []const u8, cli_name: []const u8 };

fn unusedHandler(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8)) void {
    // Dispatch happens through Registry.dispatchFastOk; ToolDef just wants a
    // handler to exist.
    _ = alloc;
    _ = args;
    _ = out;
}

fn platformDefs(
    comptime prefix: []const u8,
    comptime platform: toolinfo.Platform,
    comptime table: []const toolinfo.Tool,
) [table.len]mcp.registry.ToolDef {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var defs: [table.len]mcp.registry.ToolDef = undefined;
        for (table, 0..) |t, i| {
            var desc: []const u8 = t.summary;
            if (t.args.len != 0) desc = desc ++ " | args: " ++ t.args;
            if (t.flags.len != 0) {
                desc = desc ++ " | flags:";
                for (t.flags) |f| desc = desc ++ " " ++ f;
            }
            desc = desc ++ " | runs on: " ++ t.scope.text(platform);
            defs[i] = .{
                .name = prefix ++ "_" ++ underscored(t.name),
                .handler = unusedHandler,
                .description = desc,
                .input_schema = args_schema,
            };
        }
        return defs;
    }
}

fn platformTargets(
    comptime prefix: []const u8,
    comptime table: []const toolinfo.Tool,
) [table.len]Target {
    comptime {
        var targets: [table.len]Target = undefined;
        for (table, 0..) |t, i| {
            targets[i] = .{ .platform = prefix, .cli_name = t.name };
        }
        return targets;
    }
}

const doctor_def = mcp.registry.ToolDef{
    .name = "doctor",
    .handler = unusedHandler,
    .description = "check toolchain, accessibility grant, simulators and adb",
    .input_schema = args_schema,
};

const all_defs = platformDefs("ios", .ios, &ios_tools.all) ++
    platformDefs("android", .android, &android_tools.all) ++
    [_]mcp.registry.ToolDef{doctor_def};

const all_targets = platformTargets("ios", &ios_tools.all) ++
    platformTargets("android", &android_tools.all) ++
    [_]Target{.{ .platform = "", .cli_name = "doctor" }};

/// The registry mcp-zig serves. tools_list is comptime-rendered through
/// mcp-zig's own ToolDef JSON builder; dispatch re-execs the CLI and feeds
/// the exit code into the result's isError via dispatchFastOk.
pub const Registry = struct {
    pub const tools_list = blk: {
        @setEvalBranchQuota(1_000_000);
        var buf: []const u8 = "{\"tools\":[";
        for (all_defs, 0..) |def, i| {
            if (i != 0) buf = buf ++ ",";
            buf = buf ++ mcp.registry.toolJson(def);
        }
        break :blk buf ++ "]}";
    };

    /// Identity override: without it the server introduces itself as
    /// mcp-zig. Pinned to mcp-zig's default legacy protocol version, which
    /// is also what mainstream clients request.
    pub const initialize_result = "{\"protocolVersion\":\"" ++ mcp.PROTOCOL_VERSION ++
        "\",\"capabilities\":{\"tools\":{\"listChanged\":false},\"logging\":{}}," ++
        "\"serverInfo\":{\"name\":\"kuri-mobile\",\"title\":\"kuri mobile device driver\",\"version\":\"0.6.0\"}," ++
        "\"instructions\":\"Drive iOS simulators and Android devices: lifecycle, Xcode build, observation, input. Every tool takes {\\\"args\\\":[...]} — the raw CLI tokens its description documents.\"}";

    pub fn parse(name: []const u8) ?usize {
        inline for (all_defs, 0..) |def, i| {
            if (std.mem.eql(u8, name, def.name)) return i;
        }
        return null;
    }

    pub fn dispatchFast(
        alloc: std.mem.Allocator,
        io_impl: std.Io,
        tool: usize,
        args_raw: []const u8,
        out: *std.ArrayList(u8),
    ) void {
        _ = dispatchFastOk(alloc, io_impl, tool, args_raw, out);
    }

    /// The bool feeds the CallToolResult's isError, so a failing kuri
    /// command surfaces as a failed tool call, not as success-shaped text.
    pub fn dispatchFastOk(
        alloc: std.mem.Allocator,
        io_impl: std.Io,
        tool: usize,
        args_raw: []const u8,
        out: *std.ArrayList(u8),
    ) bool {
        _ = io_impl;
        const target = all_targets[tool];

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        argv.append(alloc, self_exe) catch return false;
        if (target.platform.len != 0) argv.append(alloc, target.platform) catch return false;
        argv.append(alloc, target.cli_name) catch return false;

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, args_raw, .{}) catch {
            out.appendSlice(alloc, "error: arguments must be a JSON object") catch {};
            return false;
        };
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("args")) |raw| {
                if (raw != .array) {
                    out.appendSlice(alloc, "error: args must be an array of strings") catch {};
                    return false;
                }
                for (raw.array.items) |item| {
                    if (item != .string) {
                        out.appendSlice(alloc, "error: args must be an array of strings") catch {};
                        return false;
                    }
                    argv.append(alloc, item.string) catch return false;
                }
            }
        }

        const r = cio.runCommand(alloc, argv.items, max_tool_output) catch {
            out.appendSlice(alloc, "error: failed to spawn kuri-mobile") catch {};
            return false;
        };
        defer alloc.free(r.stdout);
        out.appendSlice(alloc, r.stdout) catch {};
        return (r.term >> 8) & 0xFF == 0;
    }
};

// ── tests ────────────────────────────────────────────────────────────────────

test "tools_list is valid JSON and covers both tables plus doctor" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, Registry.tools_list, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array;
    try std.testing.expectEqual(ios_tools.all.len + android_tools.all.len + 1, tools.items.len);
    for (tools.items) |t| {
        const name = t.object.get("name").?.string;
        for (name) |ch| {
            const ok = std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-';
            try std.testing.expect(ok);
        }
        try std.testing.expect(t.object.get("inputSchema") != null);
        try std.testing.expect(t.object.get("description") != null);
    }
}

test "parse maps MCP names back to platform subcommands" {
    const idx = Registry.parse("ios_build_run") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ios", all_targets[idx].platform);
    try std.testing.expectEqualStrings("build-run", all_targets[idx].cli_name);

    const android_idx = Registry.parse("android_tap") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("android", all_targets[android_idx].platform);

    const doctor_idx = Registry.parse("doctor") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("", all_targets[doctor_idx].platform);

    try std.testing.expect(Registry.parse("ios_nonsense") == null);
    try std.testing.expect(Registry.parse("web_tap") == null);
}

test "dispatchFastOk re-execs the binary with mapped subcommand and args" {
    const gpa = std.testing.allocator;
    const saved = self_exe;
    defer self_exe = saved;
    // `echo` stands in for the binary: the captured output IS the argv we
    // would have run, which is exactly what this test wants to see.
    self_exe = "echo";

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const idx = Registry.parse("ios_list_devices").?;
    const ok = Registry.dispatchFastOk(gpa, undefined, idx,
        \\{"args":["--udid","ABC"]}
    , &out);
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings("ios list-devices --udid ABC\n", out.items);
}

test "initialize_result carries the kuri identity" {
    try std.testing.expect(std.mem.indexOf(u8, Registry.initialize_result, "kuri-mobile") != null);
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, Registry.initialize_result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "kuri-mobile",
        parsed.value.object.get("serverInfo").?.object.get("name").?.string,
    );
}
