/// kuri-agent — scriptable CLI for Chrome automation via CDP
///
/// Usage: kuri-agent <command> [args...]
///
/// Session (~/.kuri/session.json) stores: cdp_url, refs (ref→backendNodeId map).
/// Commands read/write the session so multiple invocations share state.
///
/// Commands:
///   tabs [--port N]            list Chrome tabs (default port 9222)
///   use <ws_url>               attach to a tab (save to session)
///   go <url>                   navigate current tab
///   snap [--text] [--interactive] [--depth N]  a11y snapshot
///   click <ref>                click element by @eN ref
///   type <ref> <text>          type into element
///   fill <ref> <text>          fill input value
///   select <ref> <value>       select dropdown option
///   hover <ref>                hover over element
///   focus <ref>                focus element
///   scroll                     scroll down
///   eval <js>                  evaluate JavaScript
///   text [selector]            get page text
///   shot [--out <file>]        screenshot (saves PNG, prints path)
///   back                       navigate back
///   forward                    navigate forward
///   reload                     reload page
///   status                     show current session

const std = @import("std");
const CdpClient = @import("cdp/client.zig").CdpClient;
const protocol = @import("cdp/protocol.zig");
const a11y = @import("snapshot/a11y.zig");

const SESSION_FILE = ".kuri/session.json";
const DEFAULT_CDP_PORT: u16 = 9222;

const Session = struct {
    cdp_url: []const u8,
    refs: std.StringHashMap(u32),

    fn init(allocator: std.mem.Allocator) Session {
        return .{
            .cdp_url = "",
            .refs = std.StringHashMap(u32).init(allocator),
        };
    }

    fn deinit(self: *Session) void {
        self.refs.deinit();
    }
};

pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    const cmd = args[1];
    const rest = args[2..];

    // Commands that don't need a session
    if (std.mem.eql(u8, cmd, "tabs")) {
        const port = parsePortFlag(rest) orelse DEFAULT_CDP_PORT;
        try cmdTabs(arena, port);
        return;
    }
    if (std.mem.eql(u8, cmd, "use")) {
        if (rest.len < 1) fatal("use: requires <ws_url>\n", .{});
        try cmdUse(arena, rest[0]);
        return;
    }
    if (std.mem.eql(u8, cmd, "status")) {
        try cmdStatus(arena);
        return;
    }

    // All other commands need a session with a valid cdp_url
    var session = loadSession(arena) catch |err| {
        std.debug.print("error: no session found ({s}). Run `kuri-agent tabs` then `kuri-agent use <ws_url>`\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer session.deinit();

    if (session.cdp_url.len == 0) {
        std.debug.print("error: no tab attached. Run `kuri-agent use <ws_url>`\n", .{});
        std.process.exit(1);
    }

    var client = CdpClient.init(arena, session.cdp_url);
    defer client.deinit();

    if (std.mem.eql(u8, cmd, "go")) {
        if (rest.len < 1) fatal("go: requires <url>\n", .{});
        try cmdNavigate(arena, &client, rest[0]);
    } else if (std.mem.eql(u8, cmd, "snap")) {
        try cmdSnap(arena, &client, &session, rest);
    } else if (std.mem.eql(u8, cmd, "click")) {
        if (rest.len < 1) fatal("click: requires <ref>\n", .{});
        try cmdAction(arena, &client, &session, "click", rest[0], null);
    } else if (std.mem.eql(u8, cmd, "type") or std.mem.eql(u8, cmd, "fill")) {
        if (rest.len < 2) fatal("{s}: requires <ref> <text>\n", .{cmd});
        try cmdAction(arena, &client, &session, cmd, rest[0], rest[1]);
    } else if (std.mem.eql(u8, cmd, "select")) {
        if (rest.len < 2) fatal("select: requires <ref> <value>\n", .{});
        try cmdAction(arena, &client, &session, "select", rest[0], rest[1]);
    } else if (std.mem.eql(u8, cmd, "hover")) {
        if (rest.len < 1) fatal("hover: requires <ref>\n", .{});
        try cmdAction(arena, &client, &session, "hover", rest[0], null);
    } else if (std.mem.eql(u8, cmd, "focus")) {
        if (rest.len < 1) fatal("focus: requires <ref>\n", .{});
        try cmdAction(arena, &client, &session, "focus", rest[0], null);
    } else if (std.mem.eql(u8, cmd, "scroll")) {
        try cmdScroll(arena, &client);
    } else if (std.mem.eql(u8, cmd, "eval")) {
        if (rest.len < 1) fatal("eval: requires <js>\n", .{});
        try cmdEval(arena, &client, rest[0]);
    } else if (std.mem.eql(u8, cmd, "text")) {
        const selector = if (rest.len > 0) rest[0] else null;
        try cmdText(arena, &client, selector);
    } else if (std.mem.eql(u8, cmd, "shot")) {
        const out = parseOutFlag(rest);
        try cmdScreenshot(arena, &client, out);
    } else if (std.mem.eql(u8, cmd, "back")) {
        try cmdSimpleNav(arena, &client, "Page.goBack");
    } else if (std.mem.eql(u8, cmd, "forward")) {
        try cmdSimpleNav(arena, &client, "Page.goForward");
    } else if (std.mem.eql(u8, cmd, "reload")) {
        try cmdSimpleNav(arena, &client, protocol.Methods.page_reload);
    } else {
        std.debug.print("error: unknown command '{s}'\n", .{cmd});
        printUsage();
        std.process.exit(1);
    }
}

// ── Commands ─────────────────────────────────────────────────────────────────

fn cmdTabs(arena: std.mem.Allocator, port: u16) !void {
    const json = fetchChromeTabs(arena, "127.0.0.1", port) catch |err| {
        std.debug.print("error: cannot connect to Chrome on port {d}: {s}\n", .{ port, @errorName(err) });
        std.process.exit(1);
    };

    // Pretty-print each page tab
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(arena);
    w.writeAll("[\n") catch {};

    var first = true;
    var pos: usize = 0;
    while (pos < json.len) {
        const ws_start = std.mem.indexOfPos(u8, json, pos, "\"webSocketDebuggerUrl\"") orelse break;
        const ws_val = extractString(json, ws_start, "\"webSocketDebuggerUrl\"") orelse {
            pos = ws_start + 1;
            continue;
        };
        const type_val = extractString(json, pos, "\"type\"") orelse "page";
        if (!std.mem.eql(u8, type_val, "page")) {
            pos = ws_start + ws_val.len + 1;
            continue;
        }
        const id_val = extractString(json, pos, "\"id\"") orelse "";
        const url_val = extractString(json, pos, "\"url\"") orelse "";
        const title_val = extractString(json, pos, "\"title\"") orelse "";

        if (!first) w.writeAll(",\n") catch {};
        first = false;
        w.print("  {{\"id\":\"{s}\",\"url\":\"{s}\",\"title\":\"{s}\",\"ws\":\"{s}\"}}", .{
            id_val, url_val, title_val, ws_val,
        }) catch {};

        pos = ws_start + ws_val.len + 1;
    }
    w.writeAll("\n]\n") catch {};
    std.fs.File.stdout().writeAll(buf.items) catch {};
}

fn cmdUse(arena: std.mem.Allocator, ws_url: []const u8) !void {
    var session = Session.init(arena);
    session.cdp_url = ws_url;
    try saveSession(arena, &session);
    const stdout = std.fs.File.stdout();
    const out = try std.fmt.allocPrint(arena, "{{\"ok\":true,\"cdp_url\":\"{s}\"}}\n", .{ws_url});
    stdout.writeAll(out) catch {};
}

fn cmdStatus(arena: std.mem.Allocator) !void {
    var session = loadSession(arena) catch {
        std.fs.File.stdout().writeAll("{\"ok\":false,\"error\":\"no session\"}\n") catch {};
        return;
    };
    defer session.deinit();
    const stdout = std.fs.File.stdout();
    const out = try std.fmt.allocPrint(arena, "{{\"ok\":true,\"cdp_url\":\"{s}\",\"refs\":{d}}}\n", .{
        session.cdp_url, session.refs.count(),
    });
    stdout.writeAll(out) catch {};
}

fn cmdNavigate(arena: std.mem.Allocator, client: *CdpClient, url: []const u8) !void {
    const params = try std.fmt.allocPrint(arena, "{{\"url\":\"{s}\"}}", .{url});
    const response = client.send(arena, protocol.Methods.page_navigate, params) catch |err| {
        std.debug.print("error: CDP navigate failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.fs.File.stdout().writeAll(response) catch {};
    std.fs.File.stdout().writeAll("\n") catch {};
}

fn cmdSnap(arena: std.mem.Allocator, client: *CdpClient, session: *Session, flags: []const []const u8) !void {
    const want_text = hasFlag(flags, "--text");
    const want_interactive = hasFlag(flags, "--interactive");
    const depth = parseDepthFlag(flags);

    const raw = client.send(arena, protocol.Methods.accessibility_get_full_tree, null) catch |err| {
        std.debug.print("error: CDP accessibility failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const nodes = parseA11yNodes(arena, raw) catch {
        std.debug.print("error: failed to parse a11y tree\n", .{});
        std.process.exit(1);
    };

    const opts = a11y.SnapshotOpts{
        .filter_interactive = want_interactive,
        .format_text = want_text,
        .max_depth = depth,
    };

    const snapshot = a11y.buildSnapshot(nodes, opts, arena) catch {
        std.debug.print("error: failed to build snapshot\n", .{});
        std.process.exit(1);
    };

    // Save refs to session
    session.refs.clearRetainingCapacity();
    for (snapshot) |node| {
        if (node.backend_node_id) |bid| {
            const owned_ref = arena.dupe(u8, node.ref) catch continue;
            session.refs.put(owned_ref, bid) catch {};
        }
    }
    saveSession(arena, session) catch {};

    const stdout = std.fs.File.stdout();
    if (want_text) {
        const text = a11y.formatText(snapshot, arena) catch "{}";
        stdout.writeAll(text) catch {};
        stdout.writeAll("\n") catch {};
        return;
    }

    // JSON output
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(arena);
    w.writeAll("[") catch {};
    for (snapshot, 0..) |node, i| {
        if (i > 0) w.writeAll(",") catch {};
        w.print("{{\"ref\":\"{s}\",\"role\":\"{s}\",\"name\":\"{s}\"", .{ node.ref, node.role, node.name }) catch {};
        if (node.value.len > 0) {
            w.print(",\"value\":\"{s}\"", .{node.value}) catch {};
        }
        w.writeAll("}") catch {};
    }
    w.writeAll("]\n") catch {};
    stdout.writeAll(buf.items) catch {};
}

fn cmdAction(arena: std.mem.Allocator, client: *CdpClient, session: *Session, action: []const u8, ref: []const u8, value: ?[]const u8) !void {
    // Normalize ref: strip leading '@' if present
    const clean_ref = if (ref.len > 0 and ref[0] == '@') ref[1..] else ref;

    // Scroll/press don't need a node ref
    if (std.mem.eql(u8, action, "scroll")) {
        try cmdScroll(arena, client);
        return;
    }

    const bid = session.refs.get(clean_ref) orelse {
        std.debug.print("error: ref '{s}' not found. Run `kuri-agent snap` first.\n", .{ref});
        std.process.exit(1);
    };

    // Step 1: resolve backend node → objectId
    const resolve_params = try std.fmt.allocPrint(arena, "{{\"backendNodeId\":{d}}}", .{bid});
    const resolve_resp = client.send(arena, protocol.Methods.dom_resolve_node, resolve_params) catch |err| {
        std.debug.print("error: DOM.resolveNode failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const object_id = extractString(resolve_resp, 0, "\"objectId\"") orelse {
        std.debug.print("error: could not extract objectId from resolveNode response\n", .{});
        std.process.exit(1);
    };

    // Step 2: build JS function for the action
    const js_fn: []const u8 = blk: {
        if (std.mem.eql(u8, action, "click")) break :blk "function() { this.scrollIntoViewIfNeeded(); this.click(); return 'clicked'; }";
        if (std.mem.eql(u8, action, "hover")) break :blk "function() { this.dispatchEvent(new MouseEvent('mouseover', {bubbles:true})); return 'hovered'; }";
        if (std.mem.eql(u8, action, "focus")) break :blk "function() { this.focus(); return 'focused'; }";
        if (std.mem.eql(u8, action, "dblclick")) break :blk "function() { this.scrollIntoViewIfNeeded(); this.dispatchEvent(new MouseEvent('dblclick', {bubbles:true,cancelable:true})); return 'dblclicked'; }";
        if (std.mem.eql(u8, action, "blur")) break :blk "function() { this.blur(); return 'blurred'; }";
        if (std.mem.eql(u8, action, "check")) break :blk "function() { if (!this.checked) { this.click(); } return 'checked'; }";
        if (std.mem.eql(u8, action, "uncheck")) break :blk "function() { if (this.checked) { this.click(); } return 'unchecked'; }";
        if (std.mem.eql(u8, action, "type") or std.mem.eql(u8, action, "fill")) {
            const v = value orelse {
                std.debug.print("error: {s} requires a value\n", .{action});
                std.process.exit(1);
            };
            break :blk try std.fmt.allocPrint(arena,
                "function() {{ this.focus(); this.value = '{s}'; this.dispatchEvent(new Event('input', {{bubbles:true}})); return 'filled'; }}",
                .{v});
        }
        if (std.mem.eql(u8, action, "select")) {
            const v = value orelse {
                std.debug.print("error: select requires a value\n", .{});
                std.process.exit(1);
            };
            break :blk try std.fmt.allocPrint(arena,
                "function() {{ this.value = '{s}'; this.dispatchEvent(new Event('change', {{bubbles:true}})); return 'selected'; }}",
                .{v});
        }
        std.debug.print("error: unknown action '{s}'\n", .{action});
        std.process.exit(1);
    };

    // Escape the js_fn for JSON string embedding
    const escaped_fn = try escapeForJson(arena, js_fn);

    // Step 3: call function on resolved object
    const call_params = try std.fmt.allocPrint(arena,
        "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"returnByValue\":true}}",
        .{ object_id, escaped_fn });
    const response = client.send(arena, protocol.Methods.runtime_call_function_on, call_params) catch |err| {
        std.debug.print("error: Runtime.callFunctionOn failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.fs.File.stdout().writeAll(response) catch {};
    std.fs.File.stdout().writeAll("\n") catch {};
}

fn cmdScroll(arena: std.mem.Allocator, client: *CdpClient) !void {
    const params = "{\"expression\":\"window.scrollBy(0, 500) || 'scrolled'\",\"returnByValue\":true}";
    const response = client.send(arena, protocol.Methods.runtime_evaluate, @constCast(params)) catch |err| {
        std.debug.print("error: scroll failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.fs.File.stdout().writeAll(response) catch {};
    std.fs.File.stdout().writeAll("\n") catch {};
}

fn cmdEval(arena: std.mem.Allocator, client: *CdpClient, expr: []const u8) !void {
    const escaped = try escapeForJson(arena, expr);
    const params = try std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped});
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch |err| {
        std.debug.print("error: eval failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.fs.File.stdout().writeAll(response) catch {};
    std.fs.File.stdout().writeAll("\n") catch {};
}

fn cmdText(arena: std.mem.Allocator, client: *CdpClient, selector: ?[]const u8) !void {
    const params: []const u8 = if (selector) |sel|
        try std.fmt.allocPrint(arena, "{{\"expression\":\"document.querySelector('{s}')?.innerText || null\",\"returnByValue\":true}}", .{sel})
    else
        @as([]const u8, "{\"expression\":\"document.body.innerText\",\"returnByValue\":true}");

    const response = client.send(arena, protocol.Methods.runtime_evaluate, @constCast(params)) catch |err| {
        std.debug.print("error: text failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.fs.File.stdout().writeAll(response) catch {};
    std.fs.File.stdout().writeAll("\n") catch {};
}

fn cmdScreenshot(arena: std.mem.Allocator, client: *CdpClient, out_path: ?[]const u8) !void {
    const params = "{\"format\":\"png\",\"quality\":80}";
    const response = client.send(arena, protocol.Methods.page_capture_screenshot, @constCast(params)) catch |err| {
        std.debug.print("error: screenshot failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // Extract base64 data from response
    const b64 = extractString(response, 0, "\"data\"") orelse {
        std.debug.print("error: no data field in screenshot response\n", .{});
        std.process.exit(1);
    };

    // Decode base64
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(b64) catch {
        std.debug.print("error: invalid base64 in screenshot\n", .{});
        std.process.exit(1);
    };
    const decoded = try arena.alloc(u8, decoded_len);
    std.base64.standard.Decoder.decode(decoded, b64) catch {
        std.debug.print("error: base64 decode failed\n", .{});
        std.process.exit(1);
    };

    // Determine output path — default to ~/.kuri/screenshots/<timestamp>.png
    const path: []const u8 = out_path orelse blk: {
        const home = std.posix.getenv("HOME") orelse ".";
        const shots_dir = try std.fmt.allocPrint(arena, "{s}/.kuri/screenshots", .{home});
        std.fs.cwd().makePath(shots_dir) catch {};
        const ts = std.time.timestamp();
        break :blk try std.fmt.allocPrint(arena, "{s}/{d}.png", .{ shots_dir, ts });
    };

    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        std.debug.print("error: cannot create file '{s}': {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };
    defer file.close();
    file.writeAll(decoded) catch {};

    const out = try std.fmt.allocPrint(arena, "{{\"ok\":true,\"path\":\"{s}\",\"bytes\":{d}}}\n", .{ path, decoded.len });
    std.fs.File.stdout().writeAll(out) catch {};
}

fn cmdSimpleNav(arena: std.mem.Allocator, client: *CdpClient, method: []const u8) !void {
    const response = client.send(arena, method, null) catch |err| {
        std.debug.print("error: {s} failed: {s}\n", .{ method, @errorName(err) });
        std.process.exit(1);
    };
    std.fs.File.stdout().writeAll(response) catch {};
    std.fs.File.stdout().writeAll("\n") catch {};
}

// ── Session I/O ───────────────────────────────────────────────────────────────

fn sessionPath(arena: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse ".";
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ home, SESSION_FILE });
}

fn loadSession(arena: std.mem.Allocator) !Session {
    const path = try sessionPath(arena);
    const data = std.fs.cwd().readFileAlloc(arena, path, 1024 * 1024) catch return error.NoSession;

    var session = Session.init(arena);

    // Extract cdp_url
    if (extractString(data, 0, "\"cdp_url\"")) |url| {
        session.cdp_url = try arena.dupe(u8, url);
    }

    // Extract refs object: "refs":{"e0":123,"e1":456,...}
    if (std.mem.indexOf(u8, data, "\"refs\"")) |refs_pos| {
        const obj_start = std.mem.indexOfScalarPos(u8, data, refs_pos, '{') orelse return session;
        var pos = obj_start + 1;
        while (pos < data.len) {
            // Find key string
            const q1 = std.mem.indexOfScalarPos(u8, data, pos, '"') orelse break;
            if (data[q1] == '}') break;
            const q2 = std.mem.indexOfScalarPos(u8, data, q1 + 1, '"') orelse break;
            if (q2 >= data.len) break;
            const key = data[q1 + 1 .. q2];
            if (std.mem.eql(u8, key, "")) break;
            // Find colon then integer value
            const colon = std.mem.indexOfScalarPos(u8, data, q2 + 1, ':') orelse break;
            var num_start = colon + 1;
            while (num_start < data.len and data[num_start] == ' ') : (num_start += 1) {}
            var num_end = num_start;
            while (num_end < data.len and data[num_end] >= '0' and data[num_end] <= '9') : (num_end += 1) {}
            if (num_end == num_start) break;
            const bid = std.fmt.parseInt(u32, data[num_start..num_end], 10) catch break;
            const owned_key = try arena.dupe(u8, key);
            try session.refs.put(owned_key, bid);
            pos = num_end + 1;
            // Skip comma
            if (pos < data.len and data[pos] == ',') pos += 1;
        }
    }

    return session;
}

fn saveSession(arena: std.mem.Allocator, session: *Session) !void {
    const path = try sessionPath(arena);

    // Ensure ~/.kuri exists
    const home = std.posix.getenv("HOME") orelse ".";
    const dir_path = try std.fmt.allocPrint(arena, "{s}/.kuri", .{home});
    std.fs.cwd().makeDir(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(arena);
    w.print("{{\"cdp_url\":\"{s}\",\"refs\":{{", .{session.cdp_url}) catch {};

    var it = session.refs.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) w.writeAll(",") catch {};
        first = false;
        w.print("\"{s}\":{d}", .{ entry.key_ptr.*, entry.value_ptr.* }) catch {};
    }
    w.writeAll("}}\n") catch {};

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

// ── Chrome tab discovery ──────────────────────────────────────────────────────

fn fetchChromeTabs(arena: std.mem.Allocator, host: []const u8, port: u16) ![]const u8 {
    const address = try std.net.Address.parseIp4(host, port);
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    const timeout = std.posix.timeval{ .sec = 3, .usec = 0 };
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    const req = try std.fmt.allocPrint(arena, "GET /json/list HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ host, port });
    try stream.writeAll(req);

    var buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = stream.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    const raw = buf[0..total];
    const body_start = (std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.InvalidResponse) + 4;
    return arena.dupe(u8, raw[body_start..]);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Extract a JSON string value for a given field key, starting at `start`.
/// Returns the content between the quotes after the field's colon.
fn extractString(json: []const u8, start: usize, field: []const u8) ?[]const u8 {
    const field_pos = std.mem.indexOfPos(u8, json, start, field) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, json, field_pos + field.len, ':') orelse return null;
    var i = colon + 1;
    while (i < json.len and (json[i] == ' ' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const end = std.mem.indexOfScalarPos(u8, json, i, '"') orelse return null;
    return json[i..end];
}

/// Parse CDP a11y tree response into A11yNode slice.
fn parseA11yNodes(arena: std.mem.Allocator, raw_json: []const u8) ![]const a11y.A11yNode {
    var nodes: std.ArrayList(a11y.A11yNode) = .empty;

    const nodes_start = std.mem.indexOf(u8, raw_json, "\"nodes\"") orelse return nodes.toOwnedSlice(arena);
    const array_start = std.mem.indexOfScalarPos(u8, raw_json, nodes_start, '[') orelse return nodes.toOwnedSlice(arena);

    var pos = array_start + 1;
    while (pos < raw_json.len) {
        const node_start = std.mem.indexOfPos(u8, raw_json, pos, "\"nodeId\"") orelse break;
        const role_val = extractJsonStringField(raw_json, node_start, "\"role\"") orelse "";
        const name_val = extractNestedValue(raw_json, node_start) orelse "";
        const backend_id = extractSimpleJsonInt(raw_json, node_start, "\"backendDOMNodeId\"");

        if (role_val.len > 0) {
            try nodes.append(arena, .{
                .ref = "",
                .role = role_val,
                .name = name_val,
                .value = "",
                .backend_node_id = backend_id,
                .depth = 0,
            });
        }

        const next_node = std.mem.indexOfPos(u8, raw_json, node_start + 10, "\"nodeId\"") orelse raw_json.len;
        pos = next_node;
    }

    return nodes.toOwnedSlice(arena);
}

fn extractJsonStringField(json: []const u8, start: usize, field: []const u8) ?[]const u8 {
    const field_pos = std.mem.indexOfPos(u8, json, start, field) orelse return null;
    if (field_pos - start > 2000) return null;
    const colon = std.mem.indexOfScalarPos(u8, json, field_pos + field.len, ':') orelse return null;
    const value_field = std.mem.indexOfPos(u8, json, colon, "\"value\"") orelse return null;
    if (value_field - colon > 100) return null;
    const val_colon = std.mem.indexOfScalarPos(u8, json, value_field + 7, ':') orelse return null;
    const quote_start = std.mem.indexOfScalarPos(u8, json, val_colon + 1, '"') orelse return null;
    const quote_end = std.mem.indexOfScalarPos(u8, json, quote_start + 1, '"') orelse return null;
    return json[quote_start + 1 .. quote_end];
}

fn extractNestedValue(json: []const u8, start: usize) ?[]const u8 {
    const name_pos = std.mem.indexOfPos(u8, json, start, "\"name\"") orelse return null;
    if (name_pos - start > 800) return null;
    return extractJsonStringField(json, name_pos - 1, "\"name\"");
}

fn extractSimpleJsonInt(json: []const u8, start: usize, field: []const u8) ?u32 {
    const field_pos = std.mem.indexOfPos(u8, json, start, field) orelse return null;
    if (field_pos - start > 2000) return null;
    const colon = std.mem.indexOfScalarPos(u8, json, field_pos + field.len, ':') orelse return null;
    var i = colon + 1;
    while (i < json.len and json[i] == ' ') : (i += 1) {}
    var end = i;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
    if (end == i) return null;
    return std.fmt.parseInt(u32, json[i..end], 10) catch null;
}

/// Escape a string for embedding inside a JSON string value.
fn escapeForJson(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(arena);
    for (s) |c| {
        switch (c) {
            '"' => w.writeAll("\\\"") catch {},
            '\\' => w.writeAll("\\\\") catch {},
            '\n' => w.writeAll("\\n") catch {},
            '\r' => w.writeAll("\\r") catch {},
            '\t' => w.writeAll("\\t") catch {},
            else => w.writeByte(c) catch {},
        }
    }
    return buf.items;
}

fn hasFlag(flags: []const []const u8, flag: []const u8) bool {
    for (flags) |f| {
        if (std.mem.eql(u8, f, flag)) return true;
    }
    return false;
}

fn parsePortFlag(flags: []const []const u8) ?u16 {
    for (flags, 0..) |f, i| {
        if (std.mem.eql(u8, f, "--port") and i + 1 < flags.len) {
            return std.fmt.parseInt(u16, flags[i + 1], 10) catch null;
        }
    }
    return null;
}

fn parseDepthFlag(flags: []const []const u8) ?u16 {
    for (flags, 0..) |f, i| {
        if (std.mem.eql(u8, f, "--depth") and i + 1 < flags.len) {
            return std.fmt.parseInt(u16, flags[i + 1], 10) catch null;
        }
    }
    return null;
}

fn parseOutFlag(flags: []const []const u8) ?[]const u8 {
    for (flags, 0..) |f, i| {
        if (std.mem.eql(u8, f, "--out") and i + 1 < flags.len) {
            return flags[i + 1];
        }
    }
    // Also accept bare filename (no --out flag) as positional arg
    for (flags) |f| {
        if (!std.mem.startsWith(u8, f, "--")) return f;
    }
    return null;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(1);
}

fn printUsage() void {
    std.debug.print(
        \\kuri-agent — agentic Chrome CLI
        \\
        \\Usage: kuri-agent <command> [args...]
        \\
        \\Discovery:
        \\  tabs [--port N]              list Chrome tabs (default: 9222)
        \\  use <ws_url>                 attach to a tab, save to session
        \\  status                       show current session
        \\
        \\Navigation:
        \\  go <url>                     navigate to URL
        \\  back                         go back
        \\  forward                      go forward
        \\  reload                       reload page
        \\
        \\Page inspection:
        \\  snap [--text] [--interactive] [--depth N]
        \\                               a11y snapshot (saves refs for actions)
        \\  text [css-selector]          get page text
        \\  eval <js>                    evaluate JavaScript
        \\  shot [--out <file.png>]      take screenshot
        \\
        \\Actions (require a prior `snap`):
        \\  click <ref>                  click element (@e3 or e3)
        \\  type <ref> <text>            type text into element
        \\  fill <ref> <text>            fill input value
        \\  select <ref> <value>         select dropdown option
        \\  hover <ref>                  hover over element
        \\  focus <ref>                  focus element
        \\  scroll                       scroll down 500px
        \\
        \\Session stored at: ~/.kuri/session.json
        \\
    , .{});
}
