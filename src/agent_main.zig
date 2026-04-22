/// kuri-agent — drive Chrome from the command line
///
/// Stateless CLI: each command connects via CDP, acts, disconnects.
/// Session (~/.kuri/session.json) persists: tab, refs, headers, stealth.
///
///   tabs → use <ws> → go <url> → snap → click @e3 → snap → ...
///
/// Key commands:
///   snap          a11y tree (~2k tokens)    snap --interactive (~1.3k)
///   click/type    act on @ref from snap     grab <ref> follows popups
///   stealth       anti-bot patches          cookies/headers/audit for security
const std = @import("std");
const compat = @import("compat.zig");
const CdpClient = @import("cdp/client.zig").CdpClient;
const protocol = @import("cdp/protocol.zig");
const a11y = @import("snapshot/a11y.zig");

const SESSION_FILE = ".kuri/session.json";
const DEFAULT_CDP_PORT: u16 = 9222;

const Session = struct {
    cdp_url: []const u8,
    refs: std.StringHashMap(u32),
    extra_headers: std.StringHashMap([]const u8),
    stealth: bool,

    fn init(allocator: std.mem.Allocator) Session {
        return .{
            .cdp_url = "",
            .refs = std.StringHashMap(u32).init(allocator),
            .extra_headers = std.StringHashMap([]const u8).init(allocator),
            .stealth = false,
        };
    }

    fn deinit(self: *Session) void {
        self.refs.deinit();
        self.extra_headers.deinit();
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const raw_args = init.minimal.args.toSlice(arena) catch
        std.process.fatal("failed to get args", .{});
    const args: []const []const u8 = @ptrCast(raw_args);
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
    if (std.mem.eql(u8, cmd, "open")) {
        const port = parsePortFlag(rest) orelse DEFAULT_CDP_PORT;
        const url = if (rest.len > 0 and rest[0][0] != '-') rest[0] else null;
        try cmdOpen(arena, port, url);
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
        jsonError("no session found ({s}). Run `kuri-agent tabs` then `kuri-agent use <ws_url>`", .{@errorName(err)});
        std.process.exit(1);
    };
    defer session.deinit();

    // Session-only commands (no CDP connection needed)
    if (std.mem.eql(u8, cmd, "set-header")) {
        if (rest.len < 2) fatal("set-header: requires <name> <value>\n", .{});
        try session.extra_headers.put(try arena.dupe(u8, rest[0]), try arena.dupe(u8, rest[1]));
        try saveSession(arena, &session);
        const out = try std.fmt.allocPrint(arena, "{{\"ok\":true,\"header\":\"{s}\",\"value\":\"{s}\"}}\n", .{ rest[0], rest[1] });
        compat.writeToStdout(out);
        return;
    }
    if (std.mem.eql(u8, cmd, "clear-headers")) {
        session.extra_headers.clearRetainingCapacity();
        try saveSession(arena, &session);
        compat.writeToStdout("{\"ok\":true,\"cleared\":true}\n");
        return;
    }
    if (std.mem.eql(u8, cmd, "show-headers")) {
        var hbuf: std.ArrayList(u8) = .empty;
        hbuf.appendSlice(arena, "{\"extra_headers\":{") catch {};
        var hit = session.extra_headers.iterator();
        var hfirst = true;
        while (hit.next()) |entry| {
            if (!hfirst) hbuf.appendSlice(arena, ",") catch {};
            hfirst = false;
            hbuf.print(arena, "\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* }) catch {};
        }
        hbuf.appendSlice(arena, "}}\n") catch {};
        compat.writeToStdout(hbuf.items);
        return;
    }

    if (session.cdp_url.len == 0) {
        jsonError("no tab attached. Run `kuri-agent use <ws_url>`", .{});
        std.process.exit(1);
    }

    var client = CdpClient.init(arena, session.cdp_url);
    defer client.deinit();

    // Apply stored extra headers before any navigation
    if (session.extra_headers.count() > 0) {
        applyExtraHeaders(arena, &client, &session) catch {};
    }

    // Apply stealth patches if enabled in session
    if (session.stealth) {
        applyStealth(arena, &client) catch {};
    }

    if (std.mem.eql(u8, cmd, "go")) {
        if (rest.len < 1) fatal("go: requires <url>\n", .{});
        try cmdNavigate(arena, &client, rest[0]);
        compat.threadSleep(1_000_000_000); // let page load
        autoSnap(arena, &client, &session);
    } else if (std.mem.eql(u8, cmd, "snap")) {
        try cmdSnap(arena, &client, &session, rest);
    } else if (std.mem.eql(u8, cmd, "click")) {
        if (rest.len < 1) fatal("click: requires <ref>\n", .{});
        try cmdAction(arena, &client, &session, "click", rest[0], null);
        autoSnap(arena, &client, &session);
    } else if (std.mem.eql(u8, cmd, "type") or std.mem.eql(u8, cmd, "fill")) {
        if (rest.len < 2) fatal("{s}: requires <ref> <text>\n", .{cmd});
        try cmdAction(arena, &client, &session, cmd, rest[0], rest[1]);
        autoSnap(arena, &client, &session);
    } else if (std.mem.eql(u8, cmd, "select")) {
        if (rest.len < 2) fatal("select: requires <ref> <value>\n", .{});
        try cmdAction(arena, &client, &session, "select", rest[0], rest[1]);
        autoSnap(arena, &client, &session);
    } else if (std.mem.eql(u8, cmd, "hover")) {
        if (rest.len < 1) fatal("hover: requires <ref>\n", .{});
        try cmdAction(arena, &client, &session, "hover", rest[0], null);
    } else if (std.mem.eql(u8, cmd, "focus")) {
        if (rest.len < 1) fatal("focus: requires <ref>\n", .{});
        try cmdAction(arena, &client, &session, "focus", rest[0], null);
    } else if (std.mem.eql(u8, cmd, "scroll")) {
        try cmdScroll(arena, &client);
        autoSnap(arena, &client, &session);
    } else if (std.mem.eql(u8, cmd, "viewport")) {
        try cmdViewport(arena, &client, rest);
    } else if (std.mem.eql(u8, cmd, "viewport")) {
        try cmdViewport(arena, &client, rest);
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
    } else if (std.mem.eql(u8, cmd, "cookies")) {
        try cmdCookies(arena, &client);
    } else if (std.mem.eql(u8, cmd, "headers")) {
        try cmdHeaders(arena, &client);
    } else if (std.mem.eql(u8, cmd, "audit")) {
        try cmdAudit(arena, &client);
    } else if (std.mem.eql(u8, cmd, "storage")) {
        const which = if (rest.len > 0) rest[0] else "all";
        try cmdStorage(arena, &client, which);
    } else if (std.mem.eql(u8, cmd, "jwt")) {
        try cmdJwt(arena, &client);
    } else if (std.mem.eql(u8, cmd, "fetch")) {
        if (rest.len < 2) fatal("fetch: requires <method> <url> [--data <json>]\n", .{});
        const fdata = parseFetchData(rest[2..]);
        try cmdFetch(arena, &client, rest[0], rest[1], fdata);
    } else if (std.mem.eql(u8, cmd, "probe")) {
        if (rest.len < 3) fatal("probe: requires <url-template> <start> <end>\n", .{});
        const start_id = std.fmt.parseInt(u32, rest[1], 10) catch fatal("probe: start must be integer\n", .{});
        const end_id = std.fmt.parseInt(u32, rest[2], 10) catch fatal("probe: end must be integer\n", .{});
        try cmdProbe(arena, &client, rest[0], start_id, end_id);
    } else if (std.mem.eql(u8, cmd, "grab")) {
        // Override window.open, click a ref, follow the redirect in-tab
        if (rest.len < 1) fatal("grab: requires <ref>\n", .{});
        try cmdGrab(arena, &client, &session, rest[0]);
    } else if (std.mem.eql(u8, cmd, "wait-for-tab")) {
        // Poll for a new tab to appear, auto-switch to it
        const port: u16 = parsePort(rest);
        try cmdWaitForTab(arena, port, &session);
    } else if (std.mem.eql(u8, cmd, "stealth")) {
        try cmdStealth(arena, &client);
    } else {
        fatal("unknown command '{s}'. Run kuri-agent with no args for help.", .{cmd});
    }
}
// ── Commands ─────────────────────────────────────────────────────────────────

fn cmdTabs(arena: std.mem.Allocator, port: u16) !void {
    const json = fetchChromeTabs(arena, "127.0.0.1", port) catch |err| {
        jsonError("cannot connect to Chrome on port {d}: {s}", .{ port, @errorName(err) });
        std.process.exit(1);
    };

    // Pretty-print each page tab
    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(arena, "[\n") catch {};

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

        if (!first) buf.appendSlice(arena, ",\n") catch {};
        first = false;
        buf.print(arena, "  {{\"id\":\"{s}\",\"url\":\"{s}\",\"title\":\"{s}\",\"ws\":\"{s}\"}}", .{
            id_val, url_val, title_val, ws_val,
        }) catch {};

        pos = ws_start + ws_val.len + 1;
    }
    buf.appendSlice(arena, "\n]\n") catch {};
    compat.writeToStdout(buf.items);
}

fn cmdUse(arena: std.mem.Allocator, ws_url: []const u8) !void {
    var session = Session.init(arena);
    session.cdp_url = ws_url;
    try saveSession(arena, &session);
    const out = try std.fmt.allocPrint(arena, "{{\"ok\":true,\"cdp_url\":\"{s}\"}}\n", .{ws_url});
    compat.writeToStdout(out);
}

/// Launch a visible (non-headless) Chrome with CDP, wait for it, auto-attach.
/// This is the "human mode" — real browser, real user, agent rides alongside.
fn cmdOpen(arena: std.mem.Allocator, port: u16, url: ?[]const u8) !void {
    // 1. Check if Chrome CDP is already available on this port
    if (tryAttach(arena, port, url)) return;

    // 2. Not running — launch visible Chrome with CDP
    const chrome_bin: []const u8 = switch (@import("builtin").os.tag) {
        .macos => "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        else => "google-chrome",
    };

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, chrome_bin);
    const port_flag = try std.fmt.allocPrint(arena, "--remote-debugging-port={d}", .{port});
    try argv.append(arena, port_flag);
    // Chrome requires a data dir for CDP; use default profile so cookies/logins persist
    const home = compat.getenv("HOME") orelse "/tmp";
    const data_dir = try std.fmt.allocPrint(arena, "--user-data-dir={s}/.kuri/chrome-profile", .{home});
    try argv.append(arena, data_dir);
    if (url) |u| try argv.append(arena, u);

    // Fork and exec Chrome
    const pid = std.c.fork();
    if (pid < 0) {
        fatal("Failed to fork for Chrome launch\n", .{});
    }
    if (pid == 0) {
        // Child process: exec Chrome
        var c_argv: [64]?[*:0]const u8 = undefined;
        for (argv.items, 0..) |arg, i| {
            if (i >= c_argv.len - 1) break;
            c_argv[i] = @ptrCast(arg.ptr);
        }
        c_argv[argv.items.len] = null;
        const c_execvp = @extern(*const fn ([*:0]const u8, [*:null]const ?[*:0]const u8) callconv(.c) c_int, .{ .name = "execvp" });
        _ = c_execvp(@ptrCast(argv.items[0].ptr), @ptrCast(&c_argv));
        std.c._exit(127);
    }

    // 3. Poll for CDP — try the requested port first, then fall back to 9222
    std.debug.print("Launching Chrome...\n", .{});
    const ports_to_try = if (port != DEFAULT_CDP_PORT)
        &[_]u16{ port, DEFAULT_CDP_PORT }
    else
        &[_]u16{port};

    var attempts: u32 = 0;
    while (attempts < 30) : (attempts += 1) {
        compat.threadSleep(500_000_000);
        for (ports_to_try) |p| {
            if (tryAttach(arena, p, url)) return;
        }
    }
    fatal("Chrome didn't start within 15s. Is it installed?\n", .{});
}

/// Try to connect to Chrome on the given port, optionally navigate, and save session.
fn tryAttach(arena: std.mem.Allocator, port: u16, url: ?[]const u8) bool {
    const json = fetchChromeTabs(arena, "127.0.0.1", port) catch return false;

    // Find the first page target
    var pos: usize = 0;
    while (pos < json.len) {
        const ws_start = std.mem.indexOfPos(u8, json, pos, "\"webSocketDebuggerUrl\"") orelse break;
        const ws = extractString(json, ws_start, "\"webSocketDebuggerUrl\"") orelse {
            pos = ws_start + 1;
            continue;
        };
        const type_val = extractString(json, pos, "\"type\"") orelse "page";
        if (!std.mem.eql(u8, type_val, "page")) {
            pos = ws_start + ws.len + 1;
            continue;
        }

        // Found a page tab — navigate if URL given, then attach
        if (url) |u| {
            var session = Session.init(arena);
            session.cdp_url = arena.dupe(u8, ws) catch return false;
            saveSession(arena, &session) catch {};
            var client = CdpClient.init(arena, ws);
            defer client.deinit();
            cmdNavigate(arena, &client, u) catch {};
        }
        cmdUse(arena, ws) catch {};
        return true;
    }
    return false;
}


fn cmdStatus(arena: std.mem.Allocator) !void {
    var session = loadSession(arena) catch {
        compat.writeToStdout("{\"ok\":false,\"error\":\"no session\"}\n");
        return;
    };
    defer session.deinit();
    const out = try std.fmt.allocPrint(arena, "{{\"ok\":true,\"cdp_url\":\"{s}\",\"refs\":{d}}}\n", .{
        session.cdp_url, session.refs.count(),
    });
    compat.writeToStdout(out);
}

fn cmdNavigate(arena: std.mem.Allocator, client: *CdpClient, url: []const u8) !void {
    const escaped_url = try escapeForJson(arena, url);
    const params = try std.fmt.allocPrint(arena, "{{\"url\":\"{s}\"}}", .{escaped_url});
    _ = client.send(arena, protocol.Methods.page_navigate, params) catch |err| {
        jsonError("navigate failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    const out = try std.fmt.allocPrint(arena, "{{\"ok\":true,\"url\":\"{s}\"}}\n", .{escaped_url});
    compat.writeToStdout(out);
}

fn cmdSnap(arena: std.mem.Allocator, client: *CdpClient, session: *Session, flags: []const []const u8) !void {
    const want_text = hasFlag(flags, "--text");
    const want_interactive = hasFlag(flags, "--interactive");
    const want_json = hasFlag(flags, "--json");
    const want_semantic = hasFlag(flags, "--semantic");
    const want_all = hasFlag(flags, "--all");
    const depth = parseDepthFlag(flags);

    const raw = client.send(arena, protocol.Methods.accessibility_get_full_tree, null) catch |err| {
        jsonError("CDP accessibility failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    const nodes = parseA11yNodes(arena, raw) catch {
        jsonError("failed to parse a11y tree", .{});
        std.process.exit(1);
    };

    const opts = a11y.SnapshotOpts{
        .filter_interactive = want_interactive,
        .filter_semantic = want_semantic,
        .compact = !want_json and !want_text and !want_all,
        .json_output = want_json,
        .format_text = want_text,
        .max_depth = depth,
    };

    const snapshot = a11y.buildSnapshot(nodes, opts, arena) catch {
        jsonError("failed to build snapshot", .{});
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

    // --text: legacy indented text
    if (want_text) {
        const text = a11y.formatText(snapshot, arena) catch "{}";
        compat.writeToStdout(text);
        compat.writeToStdout("\n");
        return;
    }

    // --json: old JSON array (backward compat)
    if (want_json) {
        var buf: std.ArrayList(u8) = .empty;
        buf.appendSlice(arena, "[") catch {};
        for (snapshot, 0..) |node, i| {
            if (i > 0) buf.appendSlice(arena, ",") catch {};
            buf.print(arena, "{{\"ref\":\"{s}\",\"role\":\"{s}\",\"name\":\"{s}\"", .{ node.ref, node.role, node.name }) catch {};
            if (node.value.len > 0) {
                buf.print(arena, ",\"value\":\"{s}\"", .{node.value}) catch {};
            }
            buf.appendSlice(arena, "}") catch {};
        }
        buf.appendSlice(arena, "]\n") catch {};
        compat.writeToStdout(buf.items);
        return;
    }

    // Default: compact text-tree (role "name" @ref)
    const compact = a11y.formatCompact(snapshot, arena) catch "error\n";
    compat.writeToStdout(compact);
}

/// Auto-snap: get URL/title + interactive snapshot. Used after actions and navigation.
fn autoSnap(arena: std.mem.Allocator, client: *CdpClient, session: *Session) void {
    // Get current URL + title
    const url_resp = client.send(arena, protocol.Methods.runtime_evaluate,
        "{\"expression\":\"JSON.stringify({url:location.href,title:document.title})\",\"returnByValue\":true}") catch null;
    if (url_resp) |resp| {
        const val = extractCdpValue(resp);
        const unescaped = unescapeJson(arena, val);
        compat.writeToStdout(unescaped);
        compat.writeToStdout("\n");
    }

    // Interactive snap
    const raw = client.send(arena, protocol.Methods.accessibility_get_full_tree, null) catch return;
    const nodes = parseA11yNodes(arena, raw) catch return;
    const opts = a11y.SnapshotOpts{
        .filter_interactive = true,
        .filter_semantic = false,
        .compact = true,
        .json_output = false,
        .format_text = false,
        .max_depth = null,
    };
    const snapshot = a11y.buildSnapshot(nodes, opts, arena) catch return;

    // Save refs
    session.refs.clearRetainingCapacity();
    for (snapshot) |node| {
        if (node.backend_node_id) |bid| {
            const owned_ref = arena.dupe(u8, node.ref) catch continue;
            session.refs.put(owned_ref, bid) catch {};
        }
    }
    saveSession(arena, session) catch {};

    const compact = a11y.formatCompact(snapshot, arena) catch return;
    compat.writeToStdout(compact);
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
        jsonError("ref '{s}' not found. Run `kuri-agent snap` first.", .{ref});
        std.process.exit(1);
    };

    // Step 1: resolve backend node → objectId
    const resolve_params = try std.fmt.allocPrint(arena, "{{\"backendNodeId\":{d}}}", .{bid});
    const resolve_resp = client.send(arena, protocol.Methods.dom_resolve_node, resolve_params) catch |err| {
        jsonError("DOM.resolveNode failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    const object_id = extractString(resolve_resp, 0, "\"objectId\"") orelse {
        jsonError("could not extract objectId from resolveNode response", .{});
        std.process.exit(1);
    };

    const value_action_fn =
        \\function(value, append) {
        \\  const target = (() => {
        \\    if (!this) return null;
        \\    if (this instanceof HTMLLabelElement && this.control) return this.control;
        \\    if (this instanceof HTMLInputElement || this instanceof HTMLTextAreaElement || this instanceof HTMLSelectElement) return this;
        \\    if (this.isContentEditable) return this;
        \\    if (typeof this.querySelector === "function") {
        \\      const nested = this.querySelector("input,textarea,select,[contenteditable=\"true\"],[contenteditable=\"\"],[role=\"textbox\"]");
        \\      if (nested) return nested;
        \\    }
        \\    return this;
        \\  })();
        \\  if (!target) return "missing-target";
        \\  target.focus?.();
        \\  if (target.isContentEditable) {
        \\    const existing = typeof target.textContent === "string" ? target.textContent : "";
        \\    target.textContent = append ? (existing + value) : value;
        \\  } else if ("value" in target) {
        \\    const existing = typeof target.value === "string" ? target.value : "";
        \\    target.value = append ? (existing + value) : value;
        \\  }
        \\  target.dispatchEvent(new Event("input", {bubbles:true}));
        \\  target.dispatchEvent(new Event("change", {bubbles:true}));
        \\  return "filled";
        \\}
    ;
    const select_action_fn =
        \\function(value) {
        \\  const target = (() => {
        \\    if (!this) return null;
        \\    if (this instanceof HTMLLabelElement && this.control) return this.control;
        \\    if (this instanceof HTMLSelectElement) return this;
        \\    if (typeof this.querySelector === "function") {
        \\      const nested = this.querySelector("select");
        \\      if (nested) return nested;
        \\    }
        \\    return this;
        \\  })();
        \\  if (!target) return "missing-target";
        \\  let next = value;
        \\  if ("options" in target && target.options) {
        \\    for (const opt of target.options) {
        \\      const text = (opt.textContent || "").trim();
        \\      const label = (opt.label || "").trim();
        \\      if (opt.value === value || text === value || label === value) {
        \\        next = opt.value;
        \\        break;
        \\      }
        \\    }
        \\  }
        \\  if ("value" in target) target.value = next;
        \\  target.dispatchEvent(new Event("input", {bubbles:true}));
        \\  target.dispatchEvent(new Event("change", {bubbles:true}));
        \\  return "selected";
        \\}
    ;

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
                jsonError("{s} requires a value", .{action});
                std.process.exit(1);
            };
            _ = v;
            break :blk value_action_fn;
        }
        if (std.mem.eql(u8, action, "select")) {
            const v = value orelse {
                jsonError("select requires a value", .{});
                std.process.exit(1);
            };
            _ = v;
            break :blk select_action_fn;
        }
        jsonError("unknown action '{s}'", .{action});
        std.process.exit(1);
    };

    // Escape the js_fn for JSON string embedding
    const escaped_fn = try escapeForJson(arena, js_fn);

    // Step 3: call function on resolved object
    const call_params = if (std.mem.eql(u8, action, "type") or std.mem.eql(u8, action, "fill")) blk: {
        const v = value orelse {
            jsonError("{s} requires a value", .{action});
            std.process.exit(1);
        };
        const escaped_v = try escapeForJson(arena, v);
        break :blk try std.fmt.allocPrint(
            arena,
            "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"arguments\":[{{\"value\":\"{s}\"}},{{\"value\":{s}}}],\"returnByValue\":true}}",
            .{ object_id, escaped_fn, escaped_v, if (std.mem.eql(u8, action, "type")) "true" else "false" },
        );
    } else if (std.mem.eql(u8, action, "select")) blk: {
        const v = value orelse {
            jsonError("select requires a value", .{});
            std.process.exit(1);
        };
        const escaped_v = try escapeForJson(arena, v);
        break :blk try std.fmt.allocPrint(
            arena,
            "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"arguments\":[{{\"value\":\"{s}\"}}],\"returnByValue\":true}}",
            .{ object_id, escaped_fn, escaped_v },
        );
    } else try std.fmt.allocPrint(
        arena,
        "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"returnByValue\":true}}",
        .{ object_id, escaped_fn },
    );
    const response = client.send(arena, protocol.Methods.runtime_call_function_on, call_params) catch |err| {
        jsonError("Runtime.callFunctionOn failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    const val = extractCdpValue(response);
    const out = try std.fmt.allocPrint(arena, "{{\"ok\":true,\"action\":\"{s}\"}}\n", .{val});
    compat.writeToStdout(out);
}

fn cmdScroll(arena: std.mem.Allocator, client: *CdpClient) !void {
    const params = "{\"expression\":\"window.scrollBy(0, 500) || 'scrolled'\",\"returnByValue\":true}";
    const response = client.send(arena, protocol.Methods.runtime_evaluate, @constCast(params)) catch |err| {
        jsonError("scroll failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    _ = response;
    compat.writeToStdout("{\"ok\":true}\n");
}

fn cmdViewport(arena: std.mem.Allocator, client: *CdpClient, args: []const []const u8) !void {
    // Presets: mobile (390x844), tablet (768x1024), desktop (1280x800)
    // Custom:  viewport <width> <height> [--dpr N]
    var width: u32 = 390;
    var height: u32 = 844;
    var dpr: u32 = 2;
    var mobile: bool = true;

    if (args.len > 0) {
        const preset = args[0];
        if (std.mem.eql(u8, preset, "mobile") or std.mem.eql(u8, preset, "m")) {
            width = 390; height = 844; dpr = 2; mobile = true;
        } else if (std.mem.eql(u8, preset, "tablet") or std.mem.eql(u8, preset, "t")) {
            width = 768; height = 1024; dpr = 2; mobile = true;
        } else if (std.mem.eql(u8, preset, "desktop") or std.mem.eql(u8, preset, "d")) {
            width = 1280; height = 800; dpr = 1; mobile = false;
        } else if (std.mem.eql(u8, preset, "reset")) {
            width = 1280; height = 800; dpr = 1; mobile = false;
        } else {
            // numeric width — expect viewport <w> <h> [--dpr N]
            width = std.fmt.parseInt(u32, preset, 10) catch {
                jsonError("unknown viewport preset '{s}'. Use mobile/tablet/desktop or <width> <height>", .{preset});
                std.process.exit(1);
            };
            height = if (args.len > 1) std.fmt.parseInt(u32, args[1], 10) catch 900 else 900;
            dpr = 1;
            mobile = width < 768;
            // --dpr flag
            var i: usize = 2;
            while (i + 1 < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--dpr")) {
                    dpr = std.fmt.parseInt(u32, args[i + 1], 10) catch dpr;
                    break;
                }
            }
        }
    }

    const params = try std.fmt.allocPrint(arena,
        "{{\"width\":{d},\"height\":{d},\"deviceScaleFactor\":{d},\"mobile\":{s}}}",
        .{ width, height, dpr, if (mobile) "true" else "false" });

    const response = client.send(arena, protocol.Methods.emulation_set_device_metrics, params) catch |err| {
        jsonError("viewport failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    _ = response;

    const out = try std.fmt.allocPrint(arena,
        "{{\"ok\":true,\"width\":{d},\"height\":{d},\"dpr\":{d},\"mobile\":{s}}}\n",
        .{ width, height, dpr, if (mobile) "true" else "false" });
    compat.writeToStdout(out);
}

fn cmdEval(arena: std.mem.Allocator, client: *CdpClient, expr: []const u8) !void {
    const escaped = try escapeForJson(arena, expr);
    const params = try std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped});
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch |err| {
        jsonError("eval failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    const val = unescapeJson(arena, extractCdpValue(response));
    compat.writeToStdout(val);
    compat.writeToStdout("\n");
}

fn cmdText(arena: std.mem.Allocator, client: *CdpClient, selector: ?[]const u8) !void {
    const expr = if (selector) |sel| blk: {
        const escaped_sel = try escapeForJson(arena, sel);
        break :blk try std.fmt.allocPrint(arena,
            "(() => {{ const el = document.querySelector(\"{s}\"); return el ? (el.innerText ?? '') : ''; }})()",
            .{escaped_sel},
        );
    } else
        @as([]const u8, "document.body ? document.body.innerText : ''");
    const escaped_expr = try escapeForJson(arena, expr);
    const params = try std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped_expr});

    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch |err| {
        jsonError("text failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    const val = unescapeJson(arena, extractCdpValue(response));
    compat.writeToStdout(val);
    compat.writeToStdout("\n");
}

fn cmdScreenshot(arena: std.mem.Allocator, client: *CdpClient, out_path: ?[]const u8) !void {
    const params = "{\"format\":\"png\",\"quality\":80}";
    const response = client.send(arena, protocol.Methods.page_capture_screenshot, @constCast(params)) catch |err| {
        jsonError("screenshot failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    // Extract base64 data from response
    const b64 = extractString(response, 0, "\"data\"") orelse {
        jsonError("no data field in screenshot response", .{});
        std.process.exit(1);
    };

    // Decode base64
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(b64) catch {
        jsonError("invalid base64 in screenshot", .{});
        std.process.exit(1);
    };
    const decoded = try arena.alloc(u8, decoded_len);
    std.base64.standard.Decoder.decode(decoded, b64) catch {
        jsonError("base64 decode failed", .{});
        std.process.exit(1);
    };

    // Determine output path — default to ~/.kuri/screenshots/<timestamp>.png
    const path: []const u8 = out_path orelse blk: {
        const home = compat.getenv("HOME") orelse ".";
        const shots_dir = try std.fmt.allocPrint(arena, "{s}/.kuri/screenshots", .{home});
        compat.cwdMakePath(shots_dir) catch {};
        const ts = compat.timestampSeconds();
        break :blk try std.fmt.allocPrint(arena, "{s}/{d}.png", .{ shots_dir, ts });
    };

    const file = compat.cwdCreateFile(path) catch |err| {
        jsonError("cannot create file '{s}': {s}", .{ path, @errorName(err) });
        std.process.exit(1);
    };
    defer compat.fdClose(file);
    compat.fdWriteAll(file, decoded) catch {};

    const out = try std.fmt.allocPrint(arena, "{{\"ok\":true,\"path\":\"{s}\",\"bytes\":{d}}}\n", .{ path, decoded.len });
    compat.writeToStdout(out);
}

fn cmdSimpleNav(arena: std.mem.Allocator, client: *CdpClient, method: []const u8) !void {
    const response = client.send(arena, method, null) catch |err| {
        jsonError("{s} failed: {s}", .{ method, @errorName(err) });
        std.process.exit(1);
    };
    _ = response;
    compat.writeToStdout("{\"ok\":true}\n");
}

// ── Tab following ─────────────────────────────────────────────────────────────
/// Intercept popups + form target="_blank", click a ref, follow the redirect
/// in the same tab. Works with Google Flights booking buttons that use
/// dynamically created forms with target="_blank".
fn cmdGrab(arena: std.mem.Allocator, client: *CdpClient, session: *Session, ref: []const u8) !void {
    // 1. Hook window.open AND form target to force same-tab navigation
    const inject_js =
        \\(function(){
        \\  window.open = function(url) {
        \\    if (url && url !== 'about:blank') location.href = url;
        \\    return null;
        \\  };
        \\  var oc = document.createElement.bind(document);
        \\  document.createElement = function(t) {
        \\    var el = oc(t);
        \\    if (t.toLowerCase() === 'form') {
        \\      Object.defineProperty(el, 'target', {
        \\        set: function() {},
        \\        get: function() { return '_self'; }
        \\      });
        \\    }
        \\    return el;
        \\  };
        \\  return 'hooked';
        \\})()
    ;
    const inject_escaped = try escapeForJson(arena, inject_js);
    const inject_params = try std.fmt.allocPrint(arena,
        "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{inject_escaped});
    _ = client.send(arena, protocol.Methods.runtime_evaluate, inject_params) catch {};

    // 2. Click the element
    try cmdAction(arena, client, session, "click", ref, null);

    // 3. Wait for navigation (up to 8s)
    var attempts: u32 = 0;
    const orig_url = blk: {
        const r = client.send(arena, protocol.Methods.runtime_evaluate,
            "{\"expression\":\"location.href\",\"returnByValue\":true}") catch break :blk "";
        const s = std.mem.indexOf(u8, r, "\"value\":\"") orelse break :blk "";
        const b = s + 9;
        const e = std.mem.indexOfPos(u8, r, b, "\"") orelse break :blk "";
        break :blk r[b..e];
    };

    while (attempts < 16) : (attempts += 1) {
        compat.threadSleep(500_000_000);
        const resp = client.send(arena, protocol.Methods.runtime_evaluate,
            "{\"expression\":\"location.href\",\"returnByValue\":true}") catch {
            // Connection lost = page navigated away
            const out = try std.fmt.allocPrint(arena,
                "{{\"ok\":true,\"action\":\"navigated\",\"note\":\"page navigated, run snap to see new page\"}}\n", .{});
            compat.writeToStdout(out);
            return;
        };
        if (std.mem.indexOf(u8, resp, "\"value\":\"")) |s| {
            const b = s + 9;
            const e = std.mem.indexOfPos(u8, resp, b, "\"") orelse continue;
            const new_url = resp[b..e];
            if (!std.mem.eql(u8, new_url, orig_url)) {
                const out = try std.fmt.allocPrint(arena,
                    "{{\"ok\":true,\"action\":\"navigated\",\"url\":\"{s}\"}}\n", .{new_url});
                compat.writeToStdout(out);
                return;
            }
        }
    }
    compat.writeToStdout("{\"ok\":true,\"action\":\"clicked\",\"note\":\"no redirect detected — check tabs\"}\n");
}

/// Poll Chrome /json for a new tab, auto-switch to it.
/// Useful after a click opens a popup/new tab that wasn't caught by `grab`.
fn cmdWaitForTab(arena: std.mem.Allocator, port: u16, session: *Session) !void {
    // Get current tab IDs
    const known_ws = session.cdp_url;

    // Poll up to 10 seconds for a new tab
    var attempts: u32 = 0;
    while (attempts < 20) : (attempts += 1) {
        const json = fetchChromeTabs(arena, "127.0.0.1", port) catch {
            compat.threadSleep(500_000_000);
            continue;
        };

        // Look for a websocket URL we don't already know
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

            if (!std.mem.eql(u8, ws_val, known_ws)) {
                // Found a new tab — switch to it
                const url_val = extractString(json, pos, "\"url\"") orelse "";
                const title_val = extractString(json, pos, "\"title\"") orelse "";
                session.cdp_url = ws_val;
                try saveSession(arena, session);
                const out = try std.fmt.allocPrint(arena,
                    "{{\"ok\":true,\"switched\":true,\"url\":\"{s}\",\"title\":\"{s}\",\"ws\":\"{s}\"}}\n",
                    .{ url_val, title_val, ws_val });
                compat.writeToStdout(out);
                return;
            }
            pos = ws_start + ws_val.len + 1;
        }
        compat.threadSleep(500_000_000);
    }

    compat.writeToStdout("{\"ok\":false,\"error\":\"no new tab detected after 10s\"}\n");
}

fn parsePort(args: []const []const u8) u16 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port")) {
            return std.fmt.parseInt(u16, args[i + 1], 10) catch 9222;
        }
    }
    return 9222;
}

// ── Stealth ───────────────────────────────────────────────────────────────────
/// Apply stealth patches (called on every CDP connection when session.stealth=true).
fn applyStealth(arena: std.mem.Allocator, client: *CdpClient) !void {
    const stealth = @import("cdp/stealth.zig");
    const ua = stealth.randomUserAgent();
    const ua_escaped = try escapeForJson(arena, ua);

    // Network-level UA override
    _ = client.send(arena, protocol.Methods.network_enable, null) catch {};
    const net_params = try std.fmt.allocPrint(arena,
        "{{\"userAgent\":\"{s}\"}}", .{ua_escaped});
    _ = client.send(arena, "Network.setUserAgentOverride", net_params) catch {};

    // Combined stealth script: override navigator.userAgent + stealth.js
    const ua_js = try std.fmt.allocPrint(arena,
        "Object.defineProperty(navigator,'userAgent',{{get:()=>'{s}',configurable:true}});", .{ua});
    const combined = try std.fmt.allocPrint(arena,
        "{s}\n{s}", .{ ua_js, stealth.stealth_script });
    const escaped = try escapeForJson(arena, combined);

    // Inject into current page
    const eval_params = try std.fmt.allocPrint(arena,
        "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped});
    _ = client.send(arena, protocol.Methods.runtime_evaluate, eval_params) catch {};

    // Persist across navigations within this session
    const persist_params = try std.fmt.allocPrint(arena,
        "{{\"source\":\"{s}\"}}", .{escaped});
    _ = client.send(arena, "Page.addScriptToEvaluateOnNewDocument", persist_params) catch {};
}

/// Enable stealth mode: apply patches + save to session so every future command re-applies.
fn cmdStealth(arena: std.mem.Allocator, client: *CdpClient) !void {
    try applyStealth(arena, client);

    // Save stealth=true to session
    var session = loadSession(arena) catch Session.init(arena);
    session.stealth = true;
    try saveSession(arena, &session);

    const stealth = @import("cdp/stealth.zig");
    const ua = stealth.randomUserAgent();
    const ua_escaped = try escapeForJson(arena, ua);
    const out = try std.fmt.allocPrint(arena,
        "{{\"ok\":true,\"ua\":\"{s}\",\"stealth\":true,\"persisted\":true}}\n", .{ua_escaped});
    compat.writeToStdout(out);
}

// ── Security ──────────────────────────────────────────────────────────────────

/// List all cookies with security flag annotations (Secure, HttpOnly, SameSite).
fn cmdCookies(arena: std.mem.Allocator, client: *CdpClient) !void {
    const response = client.send(arena, protocol.Methods.network_get_cookies, null) catch |err| {
        jsonError("Network.getCookies failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    const cookies_pos = std.mem.indexOf(u8, response, "\"cookies\"") orelse {
        compat.writeToStdout(response);
        compat.writeToStdout("\n");
        return;
    };
    const arr_start = std.mem.indexOfScalarPos(u8, response, cookies_pos, '[') orelse {
        compat.writeToStdout("{\"cookies\":[]}\n");
        return;
    };
    var pos = arr_start + 1;
    var count: usize = 0;
    var buf: std.ArrayList(u8) = .empty;
    while (pos < response.len) {
        const obj_start = std.mem.indexOfScalarPos(u8, response, pos, '{') orelse break;
        var depth: usize = 1;
        var i = obj_start + 1;
        while (i < response.len and depth > 0) : (i += 1) {
            if (response[i] == '{') depth += 1;
            if (response[i] == '}') depth -= 1;
        }
        const cookie_json = response[obj_start..i];
        const name = extractString(cookie_json, 0, "\"name\"") orelse "";
        const domain = extractString(cookie_json, 0, "\"domain\"") orelse "";
        const path_val = extractString(cookie_json, 0, "\"path\"") orelse "";
        const same_site = extractString(cookie_json, 0, "\"sameSite\"") orelse "";
        const http_only = std.mem.indexOf(u8, cookie_json, "\"httpOnly\":true") != null;
        const secure = std.mem.indexOf(u8, cookie_json, "\"secure\":true") != null;
        if (name.len > 0) {
            count += 1;
            buf.print(arena, "  {s}  domain={s} path={s}", .{ name, domain, path_val }) catch {};
            if (secure) buf.appendSlice(arena, "  [Secure]") catch {};
            if (http_only) buf.appendSlice(arena, " [HttpOnly]") catch {};
            if (same_site.len > 0) buf.print(arena, " [SameSite={s}]", .{same_site}) catch {};
            if (!secure) buf.appendSlice(arena, "  [!Secure]") catch {};
            if (!http_only) buf.appendSlice(arena, " [!HttpOnly]") catch {};
            buf.appendSlice(arena, "\n") catch {};
        }
        pos = i + 1;
    }
    if (count == 0) {
        compat.writeToStdout("{\"cookies\":0}\n");
    } else {
        const hdr = try std.fmt.allocPrint(arena, "cookies ({d}):\n", .{count});
        compat.writeToStdout(hdr);
        compat.writeToStdout(buf.items);
    }
}

/// Fetch security-relevant response headers for the current page via JS fetch HEAD.
fn cmdHeaders(arena: std.mem.Allocator, client: *CdpClient) !void {
    const js =
        \\(async()=>{try{
        \\const r=await fetch(location.href,{method:'HEAD',credentials:'include'});
        \\const hs=['content-security-policy','strict-transport-security','x-frame-options',
        \\ 'x-content-type-options','referrer-policy','permissions-policy',
        \\ 'cross-origin-opener-policy','cross-origin-embedder-policy','x-xss-protection'];
        \\const out={url:location.href,status:r.status,headers:{}};
        \\hs.forEach(h=>{const v=r.headers.get(h);out.headers[h]=v??'(missing)';});
        \\return JSON.stringify(out);
        \\}catch(e){return JSON.stringify({error:e.message});}})()
    ;
    const escaped = try escapeForJson(arena, js);
    const params = try std.fmt.allocPrint(arena,
        "{{\"expression\":\"{s}\",\"returnByValue\":true,\"awaitPromise\":true}}", .{escaped});
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch |err| {
        jsonError("headers eval failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    compat.writeToStdout(unescapeJson(arena, extractCdpValue(response)));
    compat.writeToStdout("\n");
}

/// Security audit: HTTPS, missing security headers, JS-visible cookies.
fn cmdAudit(arena: std.mem.Allocator, client: *CdpClient) !void {
    const js =
        \\(async()=>{
        \\const issues=[];
        \\const r={protocol:location.protocol,url:location.href,headers:{},issues:[]};
        \\if(location.protocol!=='https:')issues.push('NOT_HTTPS');
        \\try{
        \\ const res=await fetch(location.href,{method:'HEAD',credentials:'include'});
        \\ const req=['content-security-policy','strict-transport-security',
        \\  'x-frame-options','x-content-type-options','referrer-policy'];
        \\ req.forEach(h=>{
        \\  const v=res.headers.get(h);r.headers[h]=v??null;
        \\  if(!v)issues.push('MISSING:'+h);
        \\ });
        \\}catch(e){issues.push('FETCH_ERROR:'+e.message);}
        \\r.js_visible_cookies=document.cookie?document.cookie.split(';').length:0;
        \\if(r.js_visible_cookies>0)issues.push('COOKIES_EXPOSED_TO_JS:'+r.js_visible_cookies);
        \\r.issues=issues;
        \\r.score=Math.max(0,10-issues.length*2);
        \\return JSON.stringify(r);
        \\})()
    ;
    const escaped = try escapeForJson(arena, js);
    const params = try std.fmt.allocPrint(arena,
        "{{\"expression\":\"{s}\",\"returnByValue\":true,\"awaitPromise\":true}}", .{escaped});
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch |err| {
        jsonError("audit eval failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    compat.writeToStdout(unescapeJson(arena, extractCdpValue(response)));
    compat.writeToStdout("\n");
}

/// Apply session's stored extra HTTP headers via CDP Network domain.
fn applyExtraHeaders(arena: std.mem.Allocator, client: *CdpClient, session: *Session) !void {
    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(arena, "{\"headers\":{") catch {};
    var it = session.extra_headers.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) buf.appendSlice(arena, ",") catch {};
        first = false;
        buf.print(arena, "\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* }) catch {};
    }
    buf.appendSlice(arena, "}}") catch {};
    _ = client.send(arena, protocol.Methods.network_set_extra_http_headers, buf.items) catch {};
}

/// Dump localStorage and/or sessionStorage contents.
fn cmdStorage(arena: std.mem.Allocator, client: *CdpClient, which: []const u8) !void {
    var js: std.ArrayList(u8) = .empty;
    js.appendSlice(arena, "(()=>{") catch {};
    js.appendSlice(arena, "const r={};") catch {};
    if (std.mem.eql(u8, which, "local") or std.mem.eql(u8, which, "all")) {
        js.appendSlice(arena, "r.localStorage=Object.fromEntries(Object.entries(localStorage));") catch {};
    }
    if (std.mem.eql(u8, which, "session") or std.mem.eql(u8, which, "all")) {
        js.appendSlice(arena, "r.sessionStorage=Object.fromEntries(Object.entries(sessionStorage));") catch {};
    }
    js.appendSlice(arena, "return JSON.stringify(r);") catch {};
    js.appendSlice(arena, "})()") catch {};
    const escaped = try escapeForJson(arena, js.items);
    const params = try std.fmt.allocPrint(arena,
        "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped});
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch |err| {
        jsonError("storage eval failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    compat.writeToStdout(response);
    compat.writeToStdout("\n");
}

/// Scan localStorage, sessionStorage, and cookies for JWT tokens, decode payloads.
fn cmdJwt(arena: std.mem.Allocator, client: *CdpClient) !void {
    const js =
        \\(()=>{
        \\const tokens=[];
        \\const re=/eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/g;
        \\function decode(t){try{const p=t.split('.')[1];return JSON.parse(atob(p.replace(/-/g,'+').replace(/_/g,'/')));}catch(e){return null;}}
        \\function scan(src,label){if(!src)return;const ms=src.match(re)||[];ms.forEach(t=>{tokens.push({source:label,token:t.substring(0,80)+'...',payload:decode(t)});});}
        \\for(let i=0;i<localStorage.length;i++){const k=localStorage.key(i);scan(localStorage.getItem(k),'localStorage:'+k);}
        \\for(let i=0;i<sessionStorage.length;i++){const k=sessionStorage.key(i);scan(sessionStorage.getItem(k),'sessionStorage:'+k);}
        \\scan(document.cookie,'cookie');
        \\return JSON.stringify({found:tokens.length,tokens});
        \\})()
    ;
    const escaped = try escapeForJson(arena, js);
    const params = try std.fmt.allocPrint(arena,
        "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped});
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch |err| {
        jsonError("jwt scan failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    compat.writeToStdout(response);
    compat.writeToStdout("\n");
}

/// Make an authenticated fetch() from browser context (uses current cookies + extra headers).
fn cmdFetch(arena: std.mem.Allocator, client: *CdpClient, method: []const u8, url: []const u8, data: ?[]const u8) !void {
    var js: std.ArrayList(u8) = .empty;
    js.appendSlice(arena, "(async()=>{") catch {};
    js.appendSlice(arena, "const opts={credentials:'include',method:'") catch {};
    js.appendSlice(arena, method) catch {};
    js.appendSlice(arena, "'};") catch {};
    if (data) |d| {
        js.appendSlice(arena, "opts.body=JSON.stringify(") catch {};
        js.appendSlice(arena, d) catch {};
        js.appendSlice(arena, ");opts.headers={'Content-Type':'application/json'};") catch {};
    }
    js.appendSlice(arena, "const r=await fetch('") catch {};
    js.appendSlice(arena, url) catch {};
    js.appendSlice(arena, "',opts);") catch {};
    js.appendSlice(arena, "const body=await r.text();") catch {};
    js.appendSlice(arena, "const hdrs={};r.headers.forEach((v,k)=>{hdrs[k]=v;});") catch {};
    js.appendSlice(arena, "return JSON.stringify({status:r.status,url:r.url,headers:hdrs,body:body.substring(0,5000)});") catch {};
    js.appendSlice(arena, "})()") catch {};
    const escaped = try escapeForJson(arena, js.items);
    const params = try std.fmt.allocPrint(arena,
        "{{\"expression\":\"{s}\",\"returnByValue\":true,\"awaitPromise\":true}}", .{escaped});
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch |err| {
        jsonError("fetch failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    compat.writeToStdout(response);
    compat.writeToStdout("\n");
}

fn parseFetchData(flags: []const []const u8) ?[]const u8 {
    for (flags, 0..) |f, i| {
        if (std.mem.eql(u8, f, "--data") and i + 1 < flags.len) return flags[i + 1];
    }
    return null;
}

/// Enumerate a URL template by substituting {id} with a range — IDOR probe.
fn cmdProbe(arena: std.mem.Allocator, client: *CdpClient, tmpl: []const u8, start_id: u32, end_id: u32) !void {
    var js: std.ArrayList(u8) = .empty;
    js.appendSlice(arena, "(async()=>{") catch {};
    js.appendSlice(arena, "const results=[];") catch {};
    js.print(arena, "const tmpl='{s}';", .{tmpl}) catch {};
    js.print(arena, "for(let id={d};id<={d};id++){{", .{ start_id, end_id }) catch {};
    js.appendSlice(arena, "const url=tmpl.split('{id}').join(String(id));") catch {};
    js.appendSlice(arena, "try{const r=await fetch(url,{credentials:'include'});") catch {};
    js.appendSlice(arena, "results.push({id,url,status:r.status});}") catch {};
    js.appendSlice(arena, "catch(e){results.push({id,url,error:e.message});}") catch {};
    js.appendSlice(arena, "}") catch {};
    js.appendSlice(arena, "return JSON.stringify(results);") catch {};
    js.appendSlice(arena, "})()") catch {};
    const escaped = try escapeForJson(arena, js.items);
    const params = try std.fmt.allocPrint(arena,
        "{{\"expression\":\"{s}\",\"returnByValue\":true,\"awaitPromise\":true}}", .{escaped});
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch |err| {
        jsonError("probe failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    compat.writeToStdout(response);
    compat.writeToStdout("\n");
}


// ── Session I/O ───────────────────────────────────────────────────────────────

fn sessionPath(arena: std.mem.Allocator) ![]const u8 {
    const home = compat.getenv("HOME") orelse ".";
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ home, SESSION_FILE });
}

fn loadSession(arena: std.mem.Allocator) !Session {
    const path = try sessionPath(arena);
    const data = compat.cwdReadFile(arena, path, 1024 * 1024) catch return error.NoSession;

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

    // Extract extra_headers object: "extra_headers":{"X-Auth":"value",...}
    if (std.mem.indexOf(u8, data, "\"extra_headers\"")) |eh_pos| {
        const eh_obj = std.mem.indexOfScalarPos(u8, data, eh_pos, '{') orelse return session;
        var epos = eh_obj + 1;
        while (epos < data.len) {
            const eq1 = std.mem.indexOfScalarPos(u8, data, epos, '"') orelse break;
            if (data[eq1 + 1] == '}' or eq1 + 1 >= data.len) break;
            const eq2 = std.mem.indexOfScalarPos(u8, data, eq1 + 1, '"') orelse break;
            const ekey = data[eq1 + 1 .. eq2];
            if (ekey.len == 0) break;
            const ecolon = std.mem.indexOfScalarPos(u8, data, eq2 + 1, ':') orelse break;
            var evs = ecolon + 1;
            while (evs < data.len and data[evs] == ' ') : (evs += 1) {}
            if (evs >= data.len or data[evs] != '"') break;
            evs += 1;
            const eve = std.mem.indexOfScalarPos(u8, data, evs, '"') orelse break;
            const owned_ekey = try arena.dupe(u8, ekey);
            const owned_eval = try arena.dupe(u8, data[evs..eve]);
            try session.extra_headers.put(owned_ekey, owned_eval);
            epos = eve + 1;
            if (epos < data.len and data[epos] == ',') epos += 1;
            if (epos < data.len and data[epos] == '}') break;
        }
    }

    // Extract stealth flag
    if (std.mem.indexOf(u8, data, "\"stealth\":true")) |_| {
        session.stealth = true;
    }

    return session;
}

fn saveSession(arena: std.mem.Allocator, session: *Session) !void {
    const path = try sessionPath(arena);

    // Ensure ~/.kuri exists
    const home = compat.getenv("HOME") orelse ".";
    const dir_path = try std.fmt.allocPrint(arena, "{s}/.kuri", .{home});
    compat.cwdMakePath(dir_path) catch {};

    var buf: std.ArrayList(u8) = .empty;
    buf.print(arena, "{{\"cdp_url\":\"{s}\",\"refs\":{{", .{session.cdp_url}) catch {};

    var it = session.refs.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) buf.appendSlice(arena, ",") catch {};
        first = false;
        buf.print(arena, "\"{s}\":{d}", .{ entry.key_ptr.*, entry.value_ptr.* }) catch {};
    }
    buf.appendSlice(arena, "},\"extra_headers\":{") catch {};
    var eit = session.extra_headers.iterator();
    var efirst = true;
    while (eit.next()) |entry| {
        if (!efirst) buf.appendSlice(arena, ",") catch {};
        efirst = false;
        buf.print(arena, "\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* }) catch {};
    }
    buf.print(arena, "}},\"stealth\":{s}}}\n", .{if (session.stealth) "true" else "false"}) catch {};

    try compat.cwdWriteFile(path, buf.items);
}

// ── Chrome tab discovery ──────────────────────────────────────────────────────

extern "c" fn connect(sock: std.c.fd_t, addr: *const std.posix.sockaddr, addrlen: std.posix.socklen_t) c_int;

fn fetchChromeTabs(arena: std.mem.Allocator, host: []const u8, port: u16) ![]const u8 {
    _ = host;
    // Create TCP socket
    const raw_fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (raw_fd < 0) return error.ConnectionRefused;
    const fd: std.posix.fd_t = raw_fd;

    // Connect to 127.0.0.1:port
    var addr: std.posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
    };
    if (connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) != 0) {
        _ = std.c.close(fd);
        return error.ConnectionRefused;
    }

    // Set receive timeout
    const timeout = std.posix.timeval{ .sec = 3, .usec = 0 };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    // Send HTTP request
    const req = try std.fmt.allocPrint(arena, "GET /json/list HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{port});
    var sent: usize = 0;
    while (sent < req.len) {
        const n = std.c.write(fd, req.ptr + sent, req.len - sent);
        if (n <= 0) {
            _ = std.c.close(fd);
            return error.WriteFailed;
        }
        sent += @intCast(n);
    }

    // Read response
    var buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    _ = std.c.close(fd);

    const raw = buf[0..total];
    const body_start = (std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.InvalidResponse) + 4;
    return arena.dupe(u8, raw[body_start..]);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Extract a JSON string value for a given field key, starting at `start`.
/// Returns the content between the quotes after the field's colon.

/// Extract the value from a CDP Runtime.evaluate / callFunctionOn response.
/// Handles: {"id":N,"result":{"result":{"type":"string","value":"..."}}}
/// Returns the raw value string, or the full response if not parseable.
fn extractCdpValue(resp: []const u8) []const u8 {
    // Check for error — extract just the description string
    if (std.mem.indexOf(u8, resp, "\"exceptionDetails\"")) |_| {
        // Find "description":"Error: ..."
        if (std.mem.indexOf(u8, resp, "\"description\":\"")) |desc_pos| {
            const start = desc_pos + 15;
            var i = start;
            while (i < resp.len) {
                if (resp[i] == '\\') { i += 2; continue; }
                if (resp[i] == '"') return resp[start..i];
                i += 1;
            }
        }
        return resp;
    }
    // Find "value": and extract
    const marker = "\"value\":";
    const pos = std.mem.indexOf(u8, resp, marker) orelse return resp;
    const after = pos + marker.len;
    if (after >= resp.len) return resp;
    // String value: "value":"..." — skip escaped quotes
    if (resp[after] == '"') {
        var i = after + 1;
        while (i < resp.len) {
            if (resp[i] == '\\') { i += 2; continue; }
            if (resp[i] == '"') return resp[after + 1 .. i];
            i += 1;
        }
        return resp;
    }
    // Non-string value (number, bool, null, object): find end
    const end = std.mem.indexOfAny(u8, resp[after..], "}") orelse return resp;
    return resp[after .. after + end];
}

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

/// Unescape JSON string escapes: \n → newline, \t → tab, \\ → backslash, \" → quote
fn unescapeJson(arena: std.mem.Allocator, s: []const u8) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                'n' => { buf.append(arena, '\n') catch {}; i += 2; },
                't' => { buf.append(arena, '\t') catch {}; i += 2; },
                '\\' => { buf.append(arena, '\\') catch {}; i += 2; },
                '"' => { buf.append(arena, '"') catch {}; i += 2; },
                '/' => { buf.append(arena, '/') catch {}; i += 2; },
                else => { buf.append(arena, s[i]) catch {}; i += 1; },
            }
        } else {
            buf.append(arena, s[i]) catch {};
            i += 1;
        }
    }
    return buf.items;
}

/// Parse CDP a11y tree response into A11yNode slice.
/// Single-pass parser — scans the JSON once instead of indexOf per field.
fn parseA11yNodes(arena: std.mem.Allocator, raw_json: []const u8) ![]const a11y.A11yNode {
    var nodes: std.ArrayList(a11y.A11yNode) = .empty;

    const nodes_start = std.mem.indexOf(u8, raw_json, "\"nodes\"") orelse return nodes.toOwnedSlice(arena);
    const array_start = std.mem.indexOfScalarPos(u8, raw_json, nodes_start, '[') orelse return nodes.toOwnedSlice(arena);

    // Single pass: scan for node boundaries and extract fields inline
    var pos = array_start + 1;
    while (pos < raw_json.len) {
        // Find next node object
        const obj_start = std.mem.indexOfScalarPos(u8, raw_json, pos, '{') orelse break;

        // Find the end of this node object (match braces)
        var depth: u32 = 1;
        var obj_end = obj_start + 1;
        var in_string = false;
        while (obj_end < raw_json.len and depth > 0) : (obj_end += 1) {
            if (raw_json[obj_end] == '\\' and in_string) { obj_end += 1; continue; }
            if (raw_json[obj_end] == '"') { in_string = !in_string; continue; }
            if (!in_string) {
                if (raw_json[obj_end] == '{') depth += 1;
                if (raw_json[obj_end] == '}') depth -= 1;
            }
        }

        const node_json = raw_json[obj_start..obj_end];

        // Extract fields from this node's JSON slice (bounded search)
        const role_val = extractFieldValue(node_json, "\"role\"") orelse "";
        const name_val = extractNameValue(node_json) orelse "";
        const backend_id = extractFieldInt(node_json, "\"backendDOMNodeId\"");

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

        pos = obj_end;
    }

    return nodes.toOwnedSlice(arena);
}

/// Extract a string value from a JSON field like "role":{"type":"role","value":"button"}
fn extractFieldValue(json: []const u8, field: []const u8) ?[]const u8 {
    const field_pos = std.mem.indexOf(u8, json, field) orelse return null;
    // Find "value":"..." within the next 150 bytes
    const search_end = @min(json.len, field_pos + 150);
    const val_pos = std.mem.indexOf(u8, json[field_pos..search_end], "\"value\"") orelse return null;
    const abs_val = field_pos + val_pos;
    const colon = std.mem.indexOfScalarPos(u8, json, abs_val + 7, ':') orelse return null;
    const q1 = std.mem.indexOfScalarPos(u8, json, colon + 1, '"') orelse return null;
    const q2 = std.mem.indexOfScalarPos(u8, json, q1 + 1, '"') orelse return null;
    return json[q1 + 1 .. q2];
}

/// Extract name value — "name":{"type":"...","value":"..."}
fn extractNameValue(json: []const u8) ?[]const u8 {
    const name_pos = std.mem.indexOf(u8, json, "\"name\"") orelse return null;
    return extractFieldValue(json[name_pos..], "\"name\"");
}

/// Extract integer value from "fieldName":123
fn extractFieldInt(json: []const u8, field: []const u8) ?u32 {
    const field_pos = std.mem.indexOf(u8, json, field) orelse return null;
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
    for (s) |c| {
        switch (c) {
            '"' => buf.appendSlice(arena, "\\\"") catch {},
            '\\' => buf.appendSlice(arena, "\\\\") catch {},
            '\n' => buf.appendSlice(arena, "\\n") catch {},
            '\r' => buf.appendSlice(arena, "\\r") catch {},
            '\t' => buf.appendSlice(arena, "\\t") catch {},
            else => buf.append(arena, c) catch {},
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

fn jsonError(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "unknown error";
    const clean = std.mem.trimEnd(u8, msg, "\n");
    var out_buf: [600]u8 = undefined;
    const out = std.fmt.bufPrint(&out_buf, "{{\"error\":\"{s}\"}}\n", .{clean}) catch "{\"error\":\"unknown\"}\n";
    compat.writeToStdout(out);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    // Output JSON error to stdout so agents can parse it
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "unknown error";
    // Strip trailing newline
    const clean = std.mem.trimEnd(u8, msg, "\n");
    var out_buf: [600]u8 = undefined;
    const out = std.fmt.bufPrint(&out_buf, "{{\"error\":\"{s}\"}}\n", .{clean}) catch "{\"error\":\"fatal\"}\n";
    compat.writeToStdout(out);
    std.process.exit(1);
}

fn printUsage() void {
    std.debug.print(
        \\kuri-agent — drive Chrome from the command line
        \\
        \\  kuri-agent open https://example.com     launch Chrome + attach (one step)
        \\  kuri-agent snap                          read the page (~2k tokens)
        \\  kuri-agent click @e3                     act on it
        \\
        \\Setup:
        \\  open [url] [--port N]  launch visible Chrome, auto-attach
        \\  tabs [--port N]        list tabs on running Chrome
        \\  use <ws_url>           attach to a specific tab
        \\  status                 show session
        \\  stealth                anti-bot mode (persists)
        \\
        \\Navigate:
        \\  go <url>               open URL
        \\  back / forward         history
        \\  reload                 reload
        \\
        \\Read:
        \\  snap [flags]           a11y tree (compact text-tree default)
        \\    --interactive          buttons, links, inputs only (~1.3k tokens)
        \\    --json / --text        alternate formats
        \\    --depth N              limit depth
        \\  text [selector]        page text
        \\  shot [--out file.png]  screenshot
        \\  eval <js>              run JavaScript
        \\
        \\Act:
        \\  click <ref>            click element
        \\  type <ref> <text>      type text
        \\  fill <ref> <text>      clear + fill
        \\  select <ref> <val>     dropdown
        \\  hover / focus <ref>    hover or focus
        \\  scroll                 scroll down
        \\  grab <ref>             click + follow popup in-tab
        \\
        \\Security:
        \\  cookies / headers      inspect
        \\  audit                  full scan
        \\  storage [local|session] web storage
        \\  jwt                    find + decode JWTs
        \\  fetch <GET|POST> <url> browser-authenticated fetch
        \\  probe <url/{{id}}> <N> <M>  IDOR enumeration
        \\
        \\Headers (persisted):
        \\  set-header <k> <v>     add header
        \\  clear-headers          remove all
        \\  show-headers           list
        \\
        \\Session: ~/.kuri/session.json
        \\
    , .{});
}
