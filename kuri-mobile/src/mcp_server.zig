//! `kuri-mobile mcp` — the Model Context Protocol face of the tool tables.
//!
//! COMPARISON.md calls the missing MCP transport "the only gap that changes
//! what kuri *is* rather than how much it covers", and predicts it can be
//! generated from the tool tables instead of hand-written. This file is that
//! prediction made true: `tools/list` is rendered from the same
//! `ios/tools.zig` and `android/tools.zig` data the CLI help comes from, so
//! a command added to a table appears here with zero further work.
//!
//! Transport is MCP stdio: newline-delimited JSON-RPC 2.0 on stdin/stdout.
//! `tools/call` re-executes this same binary as a child process rather than
//! dispatching in-process — stdout belongs to the protocol here, and the CLI
//! writes to it freely. A ~2 MB static binary respawns in single-digit
//! milliseconds, which is cheaper than being wrong about fd ownership.

const std = @import("std");
const io = @import("common/io.zig");
const toolinfo = @import("common/toolinfo.zig");
const ios_tools = @import("ios/tools.zig");
const android_tools = @import("android/tools.zig");

const protocol_fallback = "2025-06-18";
const server_version = "0.4.14";
const max_line = 4 * 1024 * 1024;
const max_tool_output = 8 * 1024 * 1024;

/// Serve until stdin closes. `self_exe` is argv[0], re-invoked for every
/// tools/call; execvp resolves it through PATH exactly as the caller's
/// invocation did.
pub fn run(gpa: std.mem.Allocator, self_exe: []const u8) !u8 {
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);

    while (try readLine(gpa, &pending)) |line| {
        defer gpa.free(line);
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;

        var arena_impl = std.heap.ArenaAllocator.init(gpa);
        defer arena_impl.deinit();
        const resp = try handleMessage(arena_impl.allocator(), line, self_exe);
        if (resp) |r| {
            io.writeStdout(r);
            io.writeStdout("\n");
        }
    }
    return 0;
}

/// Pull one newline-terminated message off fd 0. A final unterminated chunk
/// at EOF still counts as a message; null means the stream is done.
fn readLine(gpa: std.mem.Allocator, pending: *std.ArrayList(u8)) !?[]u8 {
    while (true) {
        if (std.mem.indexOfScalar(u8, pending.items, '\n')) |nl| {
            const line = try gpa.dupe(u8, pending.items[0..nl]);
            const rest_len = pending.items.len - nl - 1;
            std.mem.copyForwards(u8, pending.items[0..rest_len], pending.items[nl + 1 ..]);
            pending.shrinkRetainingCapacity(rest_len);
            return line;
        }
        var buf: [4096]u8 = undefined;
        const n = std.c.read(0, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) {
            if (pending.items.len == 0) return null;
            const line = try gpa.dupe(u8, pending.items);
            pending.clearRetainingCapacity();
            return line;
        }
        try pending.appendSlice(gpa, buf[0..@intCast(n)]);
        if (pending.items.len > max_line) return error.LineTooLong;
    }
}

/// The request id, kept in its wire type so responses echo it faithfully.
const Id = union(enum) {
    integer: i64,
    string: []const u8,
    none,

    fn from(v: ?std.json.Value) Id {
        const val = v orelse return .none;
        return switch (val) {
            .integer => |n| .{ .integer = n },
            .string => |s| .{ .string = s },
            else => .none,
        };
    }

    fn append(self: Id, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        switch (self) {
            .integer => |n| {
                var nbuf: [24]u8 = undefined;
                const s = try std.fmt.bufPrint(&nbuf, "{d}", .{n});
                try out.appendSlice(gpa, s);
            },
            .string => |s| try toolinfo.appendJsonString(gpa, out, s),
            .none => try out.appendSlice(gpa, "null"),
        }
    }
};

/// One JSON-RPC message in, at most one out. Notifications (no id) get null.
/// Exposed for tests; `self_exe` is only touched by tools/call.
pub fn handleMessage(arena: std.mem.Allocator, line: []const u8, self_exe: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, line, .{}) catch {
        return try rpcError(arena, .none, -32700, "parse error");
    };
    if (parsed.value != .object) return try rpcError(arena, .none, -32600, "invalid request");
    const obj = parsed.value.object;

    const method_val = obj.get("method") orelse
        return try rpcError(arena, Id.from(obj.get("id")), -32600, "invalid request");
    if (method_val != .string) return try rpcError(arena, Id.from(obj.get("id")), -32600, "invalid request");
    const method = method_val.string;
    const id = Id.from(obj.get("id"));

    if (std.mem.eql(u8, method, "initialize")) {
        var proto: []const u8 = protocol_fallback;
        if (obj.get("params")) |p| {
            if (p == .object) {
                if (p.object.get("protocolVersion")) |v| {
                    if (v == .string) proto = v.string;
                }
            }
        }
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "{\"jsonrpc\":\"2.0\",\"id\":");
        try id.append(arena, &out);
        try out.appendSlice(arena, ",\"result\":{\"protocolVersion\":");
        try toolinfo.appendJsonString(arena, &out, proto);
        try out.appendSlice(arena, ",\"capabilities\":{\"tools\":{\"listChanged\":false}},\"serverInfo\":{\"name\":\"kuri-mobile\",\"version\":\"" ++ server_version ++ "\"}}}");
        return try out.toOwnedSlice(arena);
    }
    if (std.mem.eql(u8, method, "ping")) {
        return try rpcResult(arena, id, "{}");
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        const tools_json = try renderTools(arena);
        return try rpcResult(arena, id, tools_json);
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        return try handleCall(arena, obj, id, self_exe);
    }

    // Notifications are fire-and-forget whatever their method.
    if (id == .none) return null;
    return try rpcError(arena, id, -32601, "method not found");
}

fn rpcResult(arena: std.mem.Allocator, id: Id, result_json: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"jsonrpc\":\"2.0\",\"id\":");
    try id.append(arena, &out);
    try out.appendSlice(arena, ",\"result\":");
    try out.appendSlice(arena, result_json);
    try out.appendSlice(arena, "}");
    return try out.toOwnedSlice(arena);
}

fn rpcError(arena: std.mem.Allocator, id: Id, code: i32, message: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"jsonrpc\":\"2.0\",\"id\":");
    try id.append(arena, &out);
    var nbuf: [16]u8 = undefined;
    const code_s = try std.fmt.bufPrint(&nbuf, "{d}", .{code});
    try out.appendSlice(arena, ",\"error\":{\"code\":");
    try out.appendSlice(arena, code_s);
    try out.appendSlice(arena, ",\"message\":");
    try toolinfo.appendJsonString(arena, &out, message);
    try out.appendSlice(arena, "}}");
    return try out.toOwnedSlice(arena);
}

/// MCP tool names allow [a-zA-Z0-9_-]; the CLI's dashes are kept legal but
/// normalized to underscores so every client tokenizer treats a name as one
/// word. `ios list-devices` -> `ios_list_devices`.
fn appendMcpName(gpa: std.mem.Allocator, out: *std.ArrayList(u8), platform: []const u8, cli_name: []const u8) !void {
    try out.appendSlice(gpa, platform);
    try out.append(gpa, '_');
    for (cli_name) |ch| try out.append(gpa, if (ch == '-') '_' else ch);
}

fn mcpNameMatches(mcp_suffix: []const u8, cli_name: []const u8) bool {
    if (mcp_suffix.len != cli_name.len) return false;
    for (mcp_suffix, cli_name) |m, c| {
        const want: u8 = if (c == '-') '_' else c;
        if (m != want) return false;
    }
    return true;
}

const input_schema =
    \\{"type":"object","properties":{"args":{"type":"array","items":{"type":"string"},"description":"raw CLI tokens, positionals then flags, e.g. [\"12\",\"34\"] or [\"--udid\",\"ABC\"]"}}}
;

fn appendToolEntry(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    platform_key: []const u8,
    platform: toolinfo.Platform,
    t: toolinfo.Tool,
) !void {
    try out.appendSlice(arena, "{\"name\":\"");
    try appendMcpName(arena, out, platform_key, t.name);
    try out.appendSlice(arena, "\",\"description\":");

    var desc: std.ArrayList(u8) = .empty;
    try desc.appendSlice(arena, t.summary);
    if (t.args.len != 0) {
        try desc.appendSlice(arena, " | args: ");
        try desc.appendSlice(arena, t.args);
    }
    if (t.flags.len != 0) {
        try desc.appendSlice(arena, " | flags:");
        for (t.flags) |f| {
            try desc.append(arena, ' ');
            try desc.appendSlice(arena, f);
        }
    }
    try desc.appendSlice(arena, " | runs on: ");
    try desc.appendSlice(arena, t.scope.text(platform));
    try toolinfo.appendJsonString(arena, out, desc.items);

    try out.appendSlice(arena, ",\"inputSchema\":");
    try out.appendSlice(arena, input_schema);
    try out.appendSlice(arena, "}");
}

/// The `tools` result object, generated from both platform tables plus the
/// cross-platform doctor.
fn renderTools(arena: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"tools\":[");
    var first = true;
    for (ios_tools.all) |t| {
        if (!first) try out.append(arena, ',');
        first = false;
        try appendToolEntry(arena, &out, "ios", .ios, t);
    }
    for (android_tools.all) |t| {
        if (!first) try out.append(arena, ',');
        first = false;
        try appendToolEntry(arena, &out, "android", .android, t);
    }
    try out.appendSlice(arena, ",{\"name\":\"doctor\",\"description\":\"check toolchain, accessibility grant, simulators and adb\",\"inputSchema\":");
    try out.appendSlice(arena, input_schema);
    try out.appendSlice(arena, "}]}");
    return try out.toOwnedSlice(arena);
}

const Target = struct { platform: []const u8, cli_name: []const u8 };

/// Resolve an MCP tool name back to a platform subcommand.
fn findTarget(name: []const u8) ?Target {
    if (std.mem.eql(u8, name, "doctor")) return .{ .platform = "", .cli_name = "doctor" };
    if (std.mem.startsWith(u8, name, "ios_")) {
        const suffix = name["ios_".len..];
        for (ios_tools.all) |t| {
            if (mcpNameMatches(suffix, t.name)) return .{ .platform = "ios", .cli_name = t.name };
        }
    }
    if (std.mem.startsWith(u8, name, "android_")) {
        const suffix = name["android_".len..];
        for (android_tools.all) |t| {
            if (mcpNameMatches(suffix, t.name)) return .{ .platform = "android", .cli_name = t.name };
        }
    }
    return null;
}

fn handleCall(
    arena: std.mem.Allocator,
    obj: std.json.ObjectMap,
    id: Id,
    self_exe: []const u8,
) ![]u8 {
    const params = obj.get("params") orelse return try rpcError(arena, id, -32602, "missing params");
    if (params != .object) return try rpcError(arena, id, -32602, "invalid params");
    const name_val = params.object.get("name") orelse return try rpcError(arena, id, -32602, "missing tool name");
    if (name_val != .string) return try rpcError(arena, id, -32602, "invalid tool name");

    const target = findTarget(name_val.string) orelse
        return try rpcError(arena, id, -32602, "unknown tool");

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, self_exe);
    if (target.platform.len != 0) try argv.append(arena, target.platform);
    try argv.append(arena, target.cli_name);

    if (params.object.get("arguments")) |a| {
        if (a == .object) {
            if (a.object.get("args")) |raw| {
                if (raw != .array) return try rpcError(arena, id, -32602, "args must be an array of strings");
                for (raw.array.items) |item| {
                    if (item != .string) return try rpcError(arena, id, -32602, "args must be an array of strings");
                    try argv.append(arena, item.string);
                }
            }
        }
    }

    const r = try io.runCommand(arena, argv.items, max_tool_output);
    const code = (r.term >> 8) & 0xFF;

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"content\":[{\"type\":\"text\",\"text\":");
    try toolinfo.appendJsonString(arena, &out, r.stdout);
    try out.appendSlice(arena, "}],\"isError\":");
    try out.appendSlice(arena, if (code == 0) "false" else "true");
    try out.appendSlice(arena, "}");
    return try rpcResult(arena, id, out.items);
}

// --- tests -------------------------------------------------------------------

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "initialize echoes the client protocol version and names the server" {
    var arena_impl = testArena();
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const resp = (try handleMessage(arena,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}
    , "unused")).?;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, resp, .{});
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("2025-03-26", result.get("protocolVersion").?.string);
    try std.testing.expectEqualStrings("kuri-mobile", result.get("serverInfo").?.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("id").?.integer);
}

test "tools/list is valid JSON and covers both tables plus doctor" {
    var arena_impl = testArena();
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const resp = (try handleMessage(arena,
        \\{"jsonrpc":"2.0","id":"a","method":"tools/list"}
    , "unused")).?;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, resp, .{});
    const tools = parsed.value.object.get("result").?.object.get("tools").?.array;
    try std.testing.expectEqual(ios_tools.all.len + android_tools.all.len + 1, tools.items.len);
    for (tools.items) |t| {
        const name = t.object.get("name").?.string;
        for (name) |ch| {
            const ok = std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-';
            try std.testing.expect(ok);
        }
        try std.testing.expect(t.object.get("inputSchema") != null);
    }
}

test "tools/call re-execs the binary with mapped subcommand and args" {
    var arena_impl = testArena();
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    // `echo` stands in for the binary: the captured output IS the argv we
    // would have run, which is exactly what this test wants to see.
    const resp = (try handleMessage(arena,
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"ios_list_devices","arguments":{"args":["--udid","ABC"]}}}
    , "echo")).?;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, resp, .{});
    const result = parsed.value.object.get("result").?.object;
    const text = result.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expectEqualStrings("ios list-devices --udid ABC\n", text);
    try std.testing.expectEqual(false, result.get("isError").?.bool);
}

test "unknown method errors, notifications stay silent" {
    var arena_impl = testArena();
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const err_resp = (try handleMessage(arena,
        \\{"jsonrpc":"2.0","id":2,"method":"resources/list"}
    , "unused")).?;
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, err_resp, .{});
    try std.testing.expectEqual(@as(i64, -32601), parsed.value.object.get("error").?.object.get("code").?.integer);

    const note = try handleMessage(arena,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    , "unused");
    try std.testing.expect(note == null);
}

test "findTarget maps names back to CLI subcommands" {
    try std.testing.expectEqualStrings("list-devices", findTarget("ios_list_devices").?.cli_name);
    try std.testing.expectEqualStrings("build-run", findTarget("ios_build_run").?.cli_name);
    try std.testing.expectEqualStrings("android", findTarget("android_tap").?.platform);
    try std.testing.expectEqualStrings("doctor", findTarget("doctor").?.cli_name);
    try std.testing.expect(findTarget("ios_nonsense") == null);
    try std.testing.expect(findTarget("web_tap") == null);
}
