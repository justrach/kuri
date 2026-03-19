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
        std.debug.print("error: no session found ({s}). Run `kuri-agent tabs` then `kuri-agent use <ws_url>`\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer session.deinit();

    // Session-only commands (no CDP connection needed)
    if (std.mem.eql(u8, cmd, "set-header")) {
        if (rest.len < 2) fatal("set-header: requires <name> <value>\n", .{});
        try session.extra_headers.put(try arena.dupe(u8, rest[0]), try arena.dupe(u8, rest[1]));
        try saveSession(arena, &session);
        const out = try std.fmt.allocPrint(arena, "{{\"ok\":true,\"header\":\"{s}\",\"value\":\"{s}\"}}\n", .{ rest[0], rest[1] });
        std.fs.File.stdout().writeAll(out) catch {};
        return;
    }
    if (std.mem.eql(u8, cmd, "clear-headers")) {
        session.extra_headers.clearRetainingCapacity();
        try saveSession(arena, &session);
        std.fs.File.stdout().writeAll("{\"ok\":true,\"cleared\":true}\n") catch {};
        return;
    }
    if (std.mem.eql(u8, cmd, "show-headers")) {
        var hbuf: std.ArrayList(u8) = .empty;
        const hw = hbuf.writer(arena);
        hw.writeAll("{\"extra_headers\":{") catch {};
        var hit = session.extra_headers.iterator();
        var hfirst = true;
        while (hit.next()) |entry| {
            if (!hfirst) hw.writeAll(",") catch {};
            hfirst = false;
            hw.print("\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* }) catch {};
        }
        hw.writeAll("}}\n") catch {};
        std.fs.File.stdout().writeAll(hbuf.items) catch {};
        return;
    }

    if (session.cdp_url.len == 0) {
        std.debug.print("error: no tab attached. Run `kuri-agent use <ws_url>`\n", .{});
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

/// Launch a visible (non-headless) Chrome with CDP, wait for it, auto-attach.
/// This is the "human mode" — real browser, real user, agent rides alongside.
fn cmdOpen(arena: std.mem.Allocator, port: u16, url: ?[]const u8) !void {
    // Check if Chrome is already running on this port
    const existing = fetchChromeTabs(arena, "127.0.0.1", port) catch null;
    if (existing) |json| {
        // Already running — just attach to first tab
        if (extractString(json, 0, "\"webSocketDebuggerUrl\"")) |ws| {
            const type_val = extractString(json, 0, "\"type\"") orelse "page";
            if (std.mem.eql(u8, type_val, "page")) {
                // Navigate if URL provided
                if (url) |u| {
                    var session = Session.init(arena);
                    session.cdp_url = try arena.dupe(u8, ws);
                    try saveSession(arena, &session);
                    var client = CdpClient.init(arena, ws);
                    defer client.deinit();
                    try cmdNavigate(arena, &client, u);
                }
                try cmdUse(arena, ws);
                return;
            }
        }
    }

    // Find Chrome binary
    const chrome_bin: []const u8 = switch (@import("builtin").os.tag) {
        .macos => "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        else => blk: {
            // Try common Linux paths
            const paths = [_][]const u8{ "google-chrome", "chromium-browser", "chromium" };
            for (paths) |p| {
                if (std.fs.cwd().access(p, .{})) |_| {
                    break :blk p;
                } else |_| {}
            }
            break :blk "google-chrome";
        },
    };

    // Build args: visible Chrome (NOT headless) with CDP port
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, chrome_bin);
    const port_flag = try std.fmt.allocPrint(arena, "--remote-debugging-port={d}", .{port});
    try argv.append(arena, port_flag);
    if (url) |u| try argv.append(arena, u);

    // Spawn Chrome in background
    var child = std.process.Child.init(argv.items, arena);
    try child.spawn();

    // Wait for CDP to come up (poll /json)
    std.debug.print("Launching Chrome (port {d})...\n", .{port});
    var attempts: u32 = 0;
    while (attempts < 30) : (attempts += 1) {
        std.Thread.sleep(500_000_000);
        const json = fetchChromeTabs(arena, "127.0.0.1", port) catch continue;
        if (extractString(json, 0, "\"webSocketDebuggerUrl\"")) |ws| {
            const type_val = extractString(json, 0, "\"type\"") orelse "page";
            if (std.mem.eql(u8, type_val, "page")) {
                try cmdUse(arena, ws);
                return;
            }
        }
    }
    fatal("Chrome didn't start within 15s. Is it installed?\n", .{});
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
    const want_json = hasFlag(flags, "--json");
    const want_semantic = hasFlag(flags, "--semantic");
    const want_all = hasFlag(flags, "--all");
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
        .filter_semantic = want_semantic,
        .compact = !want_json and !want_text and !want_all,
        .json_output = want_json,
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

    // --text: legacy indented text
    if (want_text) {
        const text = a11y.formatText(snapshot, arena) catch "{}";
        stdout.writeAll(text) catch {};
        stdout.writeAll("\n") catch {};
        return;
    }

    // --json: old JSON array (backward compat)
    if (want_json) {
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
        return;
    }

    // Default: compact text-tree (role "name" @ref)
    const compact = a11y.formatCompact(snapshot, arena) catch "error\n";
    stdout.writeAll(compact) catch {};
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
                std.debug.print("error: unknown viewport preset '{s}'. Use mobile/tablet/desktop or <width> <height>\n", .{preset});
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
        std.debug.print("error: viewport failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    _ = response;

    const out = try std.fmt.allocPrint(arena,
        "{{\"ok\":true,\"width\":{d},\"height\":{d},\"dpr\":{d},\"mobile\":{s}}}\n",
        .{ width, height, dpr, if (mobile) "true" else "false" });
    std.fs.File.stdout().writeAll(out) catch {};
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

// ── Tab following ─────────────────────────────────────────────────────────────

/// Override window.open → location.href, then click a ref so the redirect
/// happens in the same tab instead of a blocked popup. Solves Google Flights
/// style "book with X" buttons that open airline sites in new windows.
fn cmdGrab(arena: std.mem.Allocator, client: *CdpClient, session: *Session, ref: []const u8) !void {
    // 1. Inject window.open override that redirects in-tab
    const inject_js =
        \\(function(){
        \\  window.__kuriOpenUrl = null;
        \\  var orig = window.open;
        \\  window.open = function(url, name, features) {
        \\    if (url && url !== 'about:blank') {
        \\      window.__kuriOpenUrl = url;
        \\      location.href = url;
        \\      return null;
        \\    }
        \\    return orig.call(window, url, name, features);
        \\  };
        \\  return 'hooked';
        \\})()
    ;
    const inject_escaped = try escapeForJson(arena, inject_js);
    const inject_params = try std.fmt.allocPrint(arena,
        "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{inject_escaped});
    _ = client.send(arena, protocol.Methods.runtime_evaluate, inject_params) catch {};

    // 2. Click the element via the normal action flow
    try cmdAction(arena, client, session, "click", ref, null);

    // 3. Wait briefly then report what happened
    std.Thread.sleep(3_000_000_000);

    // Check if we navigated to a new URL
    const check_js = "location.href";
    const check_escaped = try escapeForJson(arena, check_js);
    const check_params = try std.fmt.allocPrint(arena,
        "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{check_escaped});
    const check_resp = client.send(arena, protocol.Methods.runtime_evaluate, check_params) catch {
        // Connection lost means the page navigated away
        const out = try std.fmt.allocPrint(arena,
            "{{\"ok\":true,\"action\":\"navigated\",\"note\":\"page navigated, run snap to see new page\"}}\n", .{});
        std.fs.File.stdout().writeAll(out) catch {};
        return;
    };
    const url_start = std.mem.indexOf(u8, check_resp, "\"value\":\"") orelse {
        std.fs.File.stdout().writeAll("{\"ok\":true,\"action\":\"clicked\",\"note\":\"no redirect detected — check tabs\"}\n") catch {};
        return;
    };
    const val_begin = url_start + 9;
    const val_end = std.mem.indexOfPos(u8, check_resp, val_begin, "\"") orelse check_resp.len;
    const new_url = check_resp[val_begin..val_end];

    const out = try std.fmt.allocPrint(arena,
        "{{\"ok\":true,\"action\":\"navigated\",\"url\":\"{s}\"}}\n", .{new_url});
    std.fs.File.stdout().writeAll(out) catch {};
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
            std.Thread.sleep(500_000_000);
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
                std.fs.File.stdout().writeAll(out) catch {};
                return;
            }
            pos = ws_start + ws_val.len + 1;
        }
        std.Thread.sleep(500_000_000);
    }

    std.fs.File.stdout().writeAll("{\"ok\":false,\"error\":\"no new tab detected after 10s\"}\n") catch {};
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
    std.fs.File.stdout().writeAll(out) catch {};
}

// ── Security ──────────────────────────────────────────────────────────────────

/// List all cookies with security flag annotations (Secure, HttpOnly, SameSite).
fn cmdCookies(arena: std.mem.Allocator, client: *CdpClient) !void {
    const response = client.send(arena, protocol.Methods.network_get_cookies, null) catch |err| {
        std.debug.print("error: Network.getCookies failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const stdout = std.fs.File.stdout();
    const cookies_pos = std.mem.indexOf(u8, response, "\"cookies\"") orelse {
        stdout.writeAll(response) catch {};
        stdout.writeAll("\n") catch {};
        return;
    };
    const arr_start = std.mem.indexOfScalarPos(u8, response, cookies_pos, '[') orelse {
        stdout.writeAll("{\"cookies\":[]}\n") catch {};
        return;
    };
    var pos = arr_start + 1;
    var count: usize = 0;
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(arena);
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
            w.print("  {s}  domain={s} path={s}", .{ name, domain, path_val }) catch {};
            if (secure) w.writeAll("  [Secure]") catch {};
            if (http_only) w.writeAll(" [HttpOnly]") catch {};
            if (same_site.len > 0) w.print(" [SameSite={s}]", .{same_site}) catch {};
            if (!secure) w.writeAll("  [!Secure]") catch {};
            if (!http_only) w.writeAll(" [!HttpOnly]") catch {};
            w.writeAll("\n") catch {};
        }
        pos = i + 1;
    }
    if (count == 0) {
        stdout.writeAll("{\"cookies\":0}\n") catch {};
    } else {
        const hdr = try std.fmt.allocPrint(arena, "cookies ({d}):\n", .{count});
        stdout.writeAll(hdr) catch {};
        stdout.writeAll(buf.items) catch {};
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
        std.debug.print("error: headers eval failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.fs.File.stdout().writeAll(response) catch {};
    std.fs.File.stdout().writeAll("\n") catch {};
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
        std.debug.print("error: audit eval failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.fs.File.stdout().writeAll(response) catch {};
    std.fs.File.stdout().writeAll("\n") catch {};
}

/// Apply session's stored extra HTTP headers via CDP Network domain.
fn applyExtraHeaders(arena: std.mem.Allocator, client: *CdpClient, session: *Session) !void {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(arena);
    w.writeAll("{\"headers\":{") catch {};
    var it = session.extra_headers.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) w.writeAll(",") catch {};
        first = false;
        w.print("\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* }) catch {};
    }
    w.writeAll("}}") catch {};
    _ = client.send(arena, protocol.Methods.network_set_extra_http_headers, buf.items) catch {};
}

/// Dump localStorage and/or sessionStorage contents.
fn cmdStorage(arena: std.mem.Allocator, client: *CdpClient, which: []const u8) !void {
    var js: std.ArrayList(u8) = .empty;
    const jw = js.writer(arena);
    jw.writeAll("(()=>{") catch {};
    jw.writeAll("const r={};") catch {};
    if (std.mem.eql(u8, which, "local") or std.mem.eql(u8, which, "all")) {
        jw.writeAll("r.localStorage=Object.fromEntries(Object.entries(localStorage));") catch {};
    }
    if (std.mem.eql(u8, which, "session") or std.mem.eql(u8, which, "all")) {
        jw.writeAll("r.sessionStorage=Object.fromEntries(Object.entries(sessionStorage));") catch {};
    }
    jw.writeAll("return JSON.stringify(r);") catch {};
    jw.writeAll("})()") catch {};
    const escaped = try escapeForJson(arena, js.items);
    const params = try std.fmt.allocPrint(arena,
        "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped});
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch |err| {
        std.debug.print("error: storage eval failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.fs.File.stdout().writeAll(response) catch {};
    std.fs.File.stdout().writeAll("\n") catch {};
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
        std.debug.print("error: jwt scan failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.fs.File.stdout().writeAll(response) catch {};
    std.fs.File.stdout().writeAll("\n") catch {};
}

/// Make an authenticated fetch() from browser context (uses current cookies + extra headers).
fn cmdFetch(arena: std.mem.Allocator, client: *CdpClient, method: []const u8, url: []const u8, data: ?[]const u8) !void {
    var js: std.ArrayList(u8) = .empty;
    const jw = js.writer(arena);
    jw.writeAll("(async()=>{") catch {};
    jw.writeAll("const opts={credentials:'include',method:'") catch {};
    jw.writeAll(method) catch {};
    jw.writeAll("'};") catch {};
    if (data) |d| {
        jw.writeAll("opts.body=JSON.stringify(") catch {};
        jw.writeAll(d) catch {};
        jw.writeAll(");opts.headers={'Content-Type':'application/json'};") catch {};
    }
    jw.writeAll("const r=await fetch('") catch {};
    jw.writeAll(url) catch {};
    jw.writeAll("',opts);") catch {};
    jw.writeAll("const body=await r.text();") catch {};
    jw.writeAll("const hdrs={};r.headers.forEach((v,k)=>{hdrs[k]=v;});") catch {};
    jw.writeAll("return JSON.stringify({status:r.status,url:r.url,headers:hdrs,body:body.substring(0,5000)});") catch {};
    jw.writeAll("})()") catch {};
    const escaped = try escapeForJson(arena, js.items);
    const params = try std.fmt.allocPrint(arena,
        "{{\"expression\":\"{s}\",\"returnByValue\":true,\"awaitPromise\":true}}", .{escaped});
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch |err| {
        std.debug.print("error: fetch failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    std.fs.File.stdout().writeAll(response) catch {};
    std.fs.File.stdout().writeAll("\n") catch {};
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
    const jw = js.writer(arena);
    jw.writeAll("(async()=>{") catch {};
    jw.writeAll("const results=[];") catch {};
    jw.print("const tmpl='{s}';", .{tmpl}) catch {};
    jw.print("for(let id={d};id<={d};id++){{", .{ start_id, end_id }) catch {};
    jw.writeAll("const url=tmpl.split('{id}').join(String(id));") catch {};
    jw.writeAll("try{const r=await fetch(url,{credentials:'include'});") catch {};
    jw.writeAll("results.push({id,url,status:r.status});}") catch {};
    jw.writeAll("catch(e){results.push({id,url,error:e.message});}") catch {};
    jw.writeAll("}") catch {};
    jw.writeAll("return JSON.stringify(results);") catch {};
    jw.writeAll("})()") catch {};
    const escaped = try escapeForJson(arena, js.items);
    const params = try std.fmt.allocPrint(arena,
        "{{\"expression\":\"{s}\",\"returnByValue\":true,\"awaitPromise\":true}}", .{escaped});
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch |err| {
        std.debug.print("error: probe failed: {s}\n", .{@errorName(err)});
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
    w.writeAll("},\"extra_headers\":{") catch {};
    var eit = session.extra_headers.iterator();
    var efirst = true;
    while (eit.next()) |entry| {
        if (!efirst) w.writeAll(",") catch {};
        efirst = false;
        w.print("\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* }) catch {};
    }
    w.print("}},\"stealth\":{s}}}\n", .{if (session.stealth) "true" else "false"}) catch {};

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
