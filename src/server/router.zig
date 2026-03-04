const std = @import("std");
const net = std.net;
const Bridge = @import("../bridge/bridge.zig").Bridge;
const TabEntry = @import("../bridge/bridge.zig").TabEntry;
const Config = @import("../bridge/config.zig").Config;
const resp = @import("response.zig");
const middleware = @import("middleware.zig");
const json_util = @import("../util/json.zig");
const protocol = @import("../cdp/protocol.zig");

pub fn run(gpa: std.mem.Allocator, bridge: *Bridge, cfg: Config) !void {
    const address = try net.Address.parseIp4(cfg.host, cfg.port);
    var tcp_server = try address.listen(.{
        .reuse_address = true,
    });
    defer tcp_server.deinit();

    std.log.info("server ready on {s}:{d}", .{ cfg.host, cfg.port });

    while (true) {
        const conn = tcp_server.accept() catch |err| {
            std.log.err("accept error: {s}", .{@errorName(err)});
            continue;
        };

        const thread = std.Thread.spawn(.{}, handleConnection, .{ gpa, bridge, cfg, conn }) catch |err| {
            std.log.err("thread spawn error: {s}", .{@errorName(err)});
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(gpa: std.mem.Allocator, bridge: *Bridge, cfg: Config, conn: net.Server.Connection) void {
    defer conn.stream.close();

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var read_buf: [8192]u8 = undefined;
    var net_reader = net.Stream.Reader.init(conn.stream, &read_buf);
    var write_buf: [8192]u8 = undefined;
    var net_writer = net.Stream.Writer.init(conn.stream, &write_buf);

    var http_server = std.http.Server.init(net_reader.interface(), &net_writer.interface);

    while (true) {
        var request = http_server.receiveHead() catch |err| {
            if (err == error.EndOfStream) return;
            std.log.debug("receiveHead error: {s}", .{@errorName(err)});
            return;
        };

        if (!middleware.checkAuth(&request, cfg)) {
            resp.sendError(&request, 401, "Unauthorized");
            return;
        }

        route(&request, arena, bridge, cfg);

        if (!request.head.keep_alive) return;
    }
}

fn route(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge, cfg: Config) void {
    const path = request.head.target;
    const clean_path = if (std.mem.indexOfScalar(u8, path, '?')) |idx| path[0..idx] else path;

    if (std.mem.eql(u8, clean_path, "/health")) {
        handleHealth(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/tabs")) {
        handleTabs(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/discover")) {
        handleDiscover(request, arena, bridge, cfg);
    } else if (std.mem.eql(u8, clean_path, "/navigate")) {
        handleNavigate(request, arena, bridge, cfg);
    } else if (std.mem.eql(u8, clean_path, "/snapshot")) {
        handleSnapshot(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/action")) {
        handleAction(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/text")) {
        handleText(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/screenshot")) {
        handleScreenshot(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/evaluate")) {
        handleEvaluate(request, arena, bridge);
    } else if (std.mem.eql(u8, clean_path, "/browdie")) {
        handleBrowdie(request);
    } else {
        resp.sendError(request, 404, "Not Found");
    }
}

// --- Query string helpers ---

fn getQueryParam(target: []const u8, key: []const u8) ?[]const u8 {
    const query_start = (std.mem.indexOfScalar(u8, target, '?') orelse return null) + 1;
    const query = target[query_start..];
    var iter = std.mem.splitScalar(u8, query, '&');
    while (iter.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            if (std.mem.eql(u8, pair[0..eq], key)) {
                return pair[eq + 1 ..];
            }
        }
    }
    return null;
}

fn readRequestBody(request: *std.http.Server.Request, arena: std.mem.Allocator) ?[]const u8 {
    var buf: [65536]u8 = undefined;
    var reader = request.reader(&buf) orelse return null;
    const body = reader.readAll(arena) catch return null;
    if (body.len == 0) return null;
    return body;
}

// --- Route handlers ---

fn handleHealth(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tab_count = bridge.tabCount();
    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"tabs\":{d},\"version\":\"0.1.0\",\"name\":\"browdie\"}}", .{tab_count}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleTabs(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const tabs = bridge.listTabs(arena) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    var json_buf: std.ArrayList(u8) = .empty;
    const writer = json_buf.writer(arena);

    writer.writeAll("[") catch return;
    for (tabs, 0..) |tab, i| {
        if (i > 0) writer.writeAll(",") catch return;
        writer.print("{{\"id\":\"{s}\",\"url\":\"{s}\",\"title\":\"{s}\"}}", .{ tab.id, tab.url, tab.title }) catch return;
    }
    writer.writeAll("]") catch return;

    resp.sendJson(request, json_buf.items);
}

fn handleNavigate(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge, cfg: Config) void {
    const target = request.head.target;
    const url = getQueryParam(target, "url") orelse {
        resp.sendError(request, 400, "Missing url parameter");
        return;
    };
    const tab_id = getQueryParam(target, "tab_id");

    // If we have a tab, use its CDP client
    if (tab_id) |tid| {
        const client = bridge.getCdpClient(tid) orelse {
            resp.sendError(request, 404, "Tab not found");
            return;
        };
        const params = std.fmt.allocPrint(arena, "{{\"url\":\"{s}\"}}", .{url}) catch {
            resp.sendError(request, 500, "Internal Server Error");
            return;
        };
        const response = client.send(arena, protocol.Methods.page_navigate, params) catch {
            resp.sendError(request, 502, "CDP command failed");
            return;
        };
        resp.sendJson(request, response);
        return;
    }

    // No tab specified — discover from Chrome debugging endpoint
    _ = cfg;
    const body = std.fmt.allocPrint(arena, "{{\"status\":\"ok\",\"url\":\"{s}\",\"message\":\"Navigate requires tab_id. Use /tabs to list available tabs.\"}}", .{url}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, body);
}

fn handleSnapshot(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const filter = getQueryParam(target, "filter");
    const format = getQueryParam(target, "format");

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // Get full a11y tree from Chrome
    const raw_response = client.send(arena, protocol.Methods.accessibility_get_full_tree, null) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };

    // If format=raw, return the raw CDP response
    if (format) |f| {
        if (std.mem.eql(u8, f, "raw")) {
            resp.sendJson(request, raw_response);
            return;
        }
    }

    // Parse and filter the a11y tree
    const a11y = @import("../snapshot/a11y.zig");
    const nodes = parseA11yNodes(arena, raw_response) catch {
        resp.sendError(request, 500, "Failed to parse a11y tree");
        return;
    };

    const opts = a11y.SnapshotOpts{
        .filter_interactive = if (filter) |f| std.mem.eql(u8, f, "interactive") else false,
        .format_text = if (format) |f| std.mem.eql(u8, f, "text") else false,
    };

    const snapshot = a11y.buildSnapshot(nodes, opts, arena) catch {
        resp.sendError(request, 500, "Failed to build snapshot");
        return;
    };

    // Text format for LLM-friendly output
    if (opts.format_text) {
        const text = a11y.formatText(snapshot, arena) catch {
            resp.sendError(request, 500, "Failed to format snapshot");
            return;
        };
        resp.sendJson(request, text);
        return;
    }

    // JSON format
    var json_buf: std.ArrayList(u8) = .empty;
    const writer = json_buf.writer(arena);
    writer.writeAll("[") catch return;
    for (snapshot, 0..) |node, i| {
        if (i > 0) writer.writeAll(",") catch return;
        writer.print("{{\"ref\":\"{s}\",\"role\":\"{s}\",\"name\":\"{s}\"", .{ node.ref, node.role, node.name }) catch return;
        if (node.value.len > 0) {
            writer.print(",\"value\":\"{s}\"", .{node.value}) catch return;
        }
        writer.writeAll("}") catch return;
    }
    writer.writeAll("]") catch return;
    resp.sendJson(request, json_buf.items);
}

fn handleAction(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const action = getQueryParam(target, "action") orelse {
        resp.sendError(request, 400, "Missing action parameter");
        return;
    };
    const ref = getQueryParam(target, "ref") orelse {
        resp.sendError(request, 400, "Missing ref parameter (e.g. e0, e1)");
        return;
    };
    const value = getQueryParam(target, "value");

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    // Look up the ref in the snapshot cache to get the backend node ID
    bridge.mu.lockShared();
    const cache = bridge.snapshots.get(tab_id);
    bridge.mu.unlockShared();

    const node_id = if (cache) |c| c.refs.get(ref) else null;
    _ = node_id;

    // Build the appropriate CDP command based on action
    const actions = @import("../cdp/actions.zig");
    const kind = actions.ActionKind.fromString(action) orelse {
        resp.sendError(request, 400, "Unknown action type");
        return;
    };

    const js_expr = switch (kind) {
        .click => std.fmt.allocPrint(arena,
            "document.querySelector('[data-browdie-ref=\"{s}\"]')?.click() || 'clicked'", .{ref}),
        .focus => std.fmt.allocPrint(arena,
            "document.querySelector('[data-browdie-ref=\"{s}\"]')?.focus() || 'focused'", .{ref}),
        .hover => std.fmt.allocPrint(arena,
            "document.querySelector('[data-browdie-ref=\"{s}\"]')?.dispatchEvent(new MouseEvent('mouseover')) || 'hovered'", .{ref}),
        .fill, .@"type" => if (value) |v|
            std.fmt.allocPrint(arena,
                "(() => {{ const el = document.querySelector('[data-browdie-ref=\"{s}\"]'); if(el) {{ el.value = '{s}'; el.dispatchEvent(new Event('input')); return 'filled'; }} return 'not found'; }})()", .{ ref, v })
        else {
            resp.sendError(request, 400, "Missing value parameter for fill/type");
            return;
        },
        .press => if (value) |v|
            std.fmt.allocPrint(arena,
                "document.dispatchEvent(new KeyboardEvent('keydown', {{key: '{s}'}})) || 'pressed'", .{v})
        else {
            resp.sendError(request, 400, "Missing value parameter for press");
            return;
        },
        .select => if (value) |v|
            std.fmt.allocPrint(arena,
                "(() => {{ const el = document.querySelector('[data-browdie-ref=\"{s}\"]'); if(el) {{ el.value = '{s}'; el.dispatchEvent(new Event('change')); return 'selected'; }} return 'not found'; }})()", .{ ref, v })
        else {
            resp.sendError(request, 400, "Missing value parameter for select");
            return;
        },
        .scroll => std.fmt.allocPrint(arena,
            "window.scrollBy(0, 500) || 'scrolled'", .{}),
    } catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    const params = std.fmt.allocPrint(arena,
        "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{js_expr}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleText(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const params = "{\"expression\":\"document.body.innerText\",\"returnByValue\":true}";
    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleScreenshot(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const format = getQueryParam(target, "format") orelse "png";
    const quality = getQueryParam(target, "quality") orelse "80";

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const params = std.fmt.allocPrint(arena,
        "{{\"format\":\"{s}\",\"quality\":{s}}}", .{ format, quality }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    const response = client.send(arena, protocol.Methods.page_capture_screenshot, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

fn handleEvaluate(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge) void {
    const target = request.head.target;
    const tab_id = getQueryParam(target, "tab_id") orelse {
        resp.sendError(request, 400, "Missing tab_id parameter");
        return;
    };
    const expr = getQueryParam(target, "expression") orelse {
        resp.sendError(request, 400, "Missing expression parameter");
        return;
    };

    const client = bridge.getCdpClient(tab_id) orelse {
        resp.sendError(request, 404, "Tab not found");
        return;
    };

    const params = std.fmt.allocPrint(arena,
        "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{expr}) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };

    const response = client.send(arena, protocol.Methods.runtime_evaluate, params) catch {
        resp.sendError(request, 502, "CDP command failed");
        return;
    };
    resp.sendJson(request, response);
}

/// 🧁 Easter egg: she's a bro + a baddie = browdie
fn handleBrowdie(request: *std.http.Server.Request) void {
    const browdie =
        \\{"browdie":"🧁",
        \\"vibe":"not just a bro, not just a baddie — a browdie.",
        \\"powers":["sees the web through a11y trees","97% token reduction","stealth mode UA rotation","zero node_modules"],
        \\"catchphrase":"she browses different.",
        \\"built_with":"zig 0.15.1 btw"}
    ;
    resp.sendJson(request, browdie);
}

fn handleDiscover(request: *std.http.Server.Request, arena: std.mem.Allocator, bridge: *Bridge, cfg: Config) void {
    const cdp_base = cfg.cdp_url orelse {
        resp.sendError(request, 400, "No CDP_URL configured");
        return;
    };

    // Parse host:port from CDP URL (strip ws:// prefix and path)
    const after_scheme = if (std.mem.startsWith(u8, cdp_base, "ws://"))
        cdp_base[5..]
    else
        cdp_base;
    const host_end = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
    const host_port = after_scheme[0..host_end];

    var host: []const u8 = "127.0.0.1";
    var port: u16 = 9222;
    if (std.mem.indexOfScalar(u8, host_port, ':')) |colon| {
        host = host_port[0..colon];
        if (std.mem.eql(u8, host, "localhost")) host = "127.0.0.1";
        port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch 9222;
    }

    const address = net.Address.parseIp4(host, port) catch {
        resp.sendError(request, 502, "Cannot resolve Chrome address");
        return;
    };
    const stream = net.tcpConnectToAddress(address) catch {
        resp.sendError(request, 502, "Cannot connect to Chrome");
        return;
    };
    defer stream.close();

    // Set read timeout (2 seconds) to avoid blocking forever
    const timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    // HTTP/1.1 required — Chrome ignores HTTP/1.0
    const http_req = std.fmt.allocPrint(arena, "GET /json/list HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ host, port }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    stream.writeAll(http_req) catch {
        resp.sendError(request, 502, "Failed to send request to Chrome");
        return;
    };

    // Read response with Content-Length awareness
    var response_buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < response_buf.len) {
        const n = stream.read(response_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        // Once we have headers, check Content-Length to know when body is complete
        if (std.mem.indexOf(u8, response_buf[0..total], "\r\n\r\n")) |hdr_end| {
            const headers = response_buf[0..hdr_end];
            if (findContentLength(headers)) |content_len| {
                const body_start = hdr_end + 4;
                if (total >= body_start + content_len) break;
            }
        }
    }

    if (total == 0) {
        resp.sendError(request, 502, "Empty response from Chrome");
        return;
    }
    const raw_response = response_buf[0..total];

    const body_start = (std.mem.indexOf(u8, raw_response, "\r\n\r\n") orelse {
        resp.sendError(request, 502, "Invalid response from Chrome");
        return;
    }) + 4;
    const body = raw_response[body_start..total];

    // Parse targets and register tabs
    var registered: usize = 0;
    var pos: usize = 0;
    while (pos < body.len) {
        const id_start = std.mem.indexOfPos(u8, body, pos, "\"id\"") orelse break;

        const id_val = extractSimpleJsonString(body, id_start, "\"id\"") orelse {
            pos = id_start + 4;
            continue;
        };
        const type_val = extractSimpleJsonString(body, id_start, "\"type\"") orelse "page";
        const url_val = extractSimpleJsonString(body, id_start, "\"url\"") orelse "";
        const title_val = extractSimpleJsonString(body, id_start, "\"title\"") orelse "";
        const ws_val = extractSimpleJsonString(body, id_start, "\"webSocketDebuggerUrl\"") orelse "";

        if (std.mem.eql(u8, type_val, "page") and ws_val.len > 0) {
            // Dupe strings into arena so they outlive the stack buffer
            const entry = TabEntry{
                .id = arena.dupe(u8, id_val) catch id_val,
                .url = arena.dupe(u8, url_val) catch url_val,
                .title = arena.dupe(u8, title_val) catch title_val,
                .ws_url = arena.dupe(u8, ws_val) catch ws_val,
                .created_at = @intCast(std.time.timestamp()),
                .last_accessed = @intCast(std.time.timestamp()),
            };
            bridge.putTab(entry) catch {};
            registered += 1;
        }

        const next_id = std.mem.indexOfPos(u8, body, id_start + 4, "\"id\"") orelse body.len;
        pos = next_id;
    }

    const result = std.fmt.allocPrint(arena,
        "{{\"discovered\":{d},\"total_tabs\":{d}}}", .{ registered, bridge.tabCount() }) catch {
        resp.sendError(request, 500, "Internal Server Error");
        return;
    };
    resp.sendJson(request, result);
}

fn findContentLength(headers: []const u8) ?usize {
    // Chrome sends "Content-Length:1773" (no space after colon)
    const patterns = [_][]const u8{ "Content-Length:", "Content-Length: ", "content-length:", "content-length: " };
    for (patterns) |pat| {
        if (std.mem.indexOf(u8, headers, pat)) |cl_pos| {
            const val_start = cl_pos + pat.len;
            const val_end = std.mem.indexOfScalarPos(u8, headers, val_start, '\r') orelse continue;
            const val_str = std.mem.trim(u8, headers[val_start..val_end], " ");
            return std.fmt.parseInt(usize, val_str, 10) catch continue;
        }
    }
    return null;
}

fn extractSimpleJsonString(json: []const u8, start: usize, field: []const u8) ?[]const u8 {
    const field_pos = std.mem.indexOfPos(u8, json, start, field) orelse return null;
    if (field_pos - start > 1000) return null;
    const colon = std.mem.indexOfScalarPos(u8, json, field_pos + field.len, ':') orelse return null;
    // Skip whitespace and find opening quote
    var i = colon + 1;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    if (i >= json.len or json[i] != '"') return null;
    const val_start = i + 1;
    const val_end = std.mem.indexOfScalarPos(u8, json, val_start, '"') orelse return null;
    return json[val_start..val_end];
}

// --- A11y tree parsing helper ---

fn parseA11yNodes(arena: std.mem.Allocator, raw_json: []const u8) ![]const @import("../snapshot/a11y.zig").A11yNode {
    const a11y = @import("../snapshot/a11y.zig");
    // Parse the CDP response to extract node info
    // The response has { "result": { "nodes": [ ... ] } }
    // We do a simple scan for role/name/nodeId patterns
    var nodes: std.ArrayList(a11y.A11yNode) = .empty;

    // Find "nodes" array start
    const nodes_start = std.mem.indexOf(u8, raw_json, "\"nodes\"") orelse return nodes.toOwnedSlice(arena);
    const array_start = std.mem.indexOfScalarPos(u8, raw_json, nodes_start, '[') orelse return nodes.toOwnedSlice(arena);

    // Simple state-machine parser for CDP a11y nodes
    var pos = array_start + 1;
    var depth: u16 = 0;
    while (pos < raw_json.len) {
        // Find next nodeId
        const node_start = std.mem.indexOfPos(u8, raw_json, pos, "\"nodeId\"") orelse break;
        const role_val = extractJsonStringField(raw_json, node_start, "\"role\"") orelse "";
        const name_val = extractNestedValue(raw_json, node_start) orelse "";

        if (role_val.len > 0) {
            try nodes.append(arena, .{
                .ref = "",
                .role = role_val,
                .name = name_val,
                .value = "",
                .backend_node_id = null,
                .depth = depth,
            });
        }

        // Move past this node object
        const next_node = std.mem.indexOfPos(u8, raw_json, node_start + 10, "\"nodeId\"") orelse raw_json.len;
        pos = next_node;
        depth = 0; // flat for now
    }

    return nodes.toOwnedSlice(arena);
}

fn extractJsonStringField(json: []const u8, start: usize, field: []const u8) ?[]const u8 {
    const field_pos = std.mem.indexOfPos(u8, json, start, field) orelse return null;
    // Limit search to next 500 chars (within same node object)
    if (field_pos - start > 500) return null;
    // Find the value string after ":"
    const colon = std.mem.indexOfScalarPos(u8, json, field_pos + field.len, ':') orelse return null;
    // Look for nested "value" field
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

test "route matching" {
    const path = "/health?foo=bar";
    const clean = if (std.mem.indexOfScalar(u8, path, '?')) |idx| path[0..idx] else path;
    try std.testing.expectEqualStrings("/health", clean);
}

test "getQueryParam" {
    try std.testing.expectEqualStrings("bar", getQueryParam("/test?foo=bar", "foo").?);
    try std.testing.expectEqualStrings("123", getQueryParam("/test?a=1&tab_id=123&b=2", "tab_id").?);
    try std.testing.expect(getQueryParam("/test?foo=bar", "baz") == null);
    try std.testing.expect(getQueryParam("/test", "foo") == null);
}
