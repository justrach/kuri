const std = @import("std");
const net = std.Io.net;

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9333,
};

const browser_id = "kuri-browser";
const page_id = "kuri-page-1";

pub fn serve(gpa: std.mem.Allocator, options: Options) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const address = try net.IpAddress.parseIp4(options.host, options.port);
    var tcp_server = try net.IpAddress.listen(&address, io, .{
        .reuse_address = true,
    });
    defer tcp_server.deinit(io);

    std.debug.print("kuri-browser CDP discovery server listening on http://{s}:{d}\n", .{ options.host, options.port });
    std.debug.print("discovery: http://{s}:{d}/json/version\n", .{ options.host, options.port });

    while (true) {
        const stream = tcp_server.accept(io) catch |err| {
            std.log.err("accept error: {s}", .{@errorName(err)});
            continue;
        };

        const thread = std.Thread.spawn(.{}, handleConnection, .{ gpa, options, stream }) catch |err| {
            std.log.err("thread spawn error: {s}", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(gpa: std.mem.Allocator, options: Options, stream: net.Stream) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    defer stream.close(io);

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var read_buf: [8192]u8 = undefined;
    var net_reader = net.Stream.Reader.init(stream, io, &read_buf);
    var write_buf: [8192]u8 = undefined;
    var net_writer = net.Stream.Writer.init(stream, io, &write_buf);

    var http_server = std.http.Server.init(&net_reader.interface, &net_writer.interface);
    while (true) {
        var request = http_server.receiveHead() catch |err| {
            if (err == error.EndOfStream) return;
            std.log.debug("receiveHead error: {s}", .{@errorName(err)});
            return;
        };

        route(&request, arena, options);
        if (!request.head.keep_alive) return;
        _ = arena_impl.reset(.retain_capacity);
    }
}

fn route(request: *std.http.Server.Request, arena: std.mem.Allocator, options: Options) void {
    const target = request.head.target;
    const clean_path = if (std.mem.indexOfScalar(u8, target, '?')) |idx| target[0..idx] else target;

    if (!std.mem.eql(u8, @tagName(request.head.method), "GET") and
        !std.mem.eql(u8, @tagName(request.head.method), "PUT"))
    {
        sendJson(request, "{\"error\":\"method not allowed\"}", 405);
        return;
    }

    if (std.mem.eql(u8, clean_path, "/health")) {
        sendJson(request, "{\"status\":\"ok\",\"service\":\"kuri-browser-cdp\"}", 200);
        return;
    }
    if (std.mem.eql(u8, clean_path, "/json/version")) {
        const body = versionJson(arena, options) catch {
            sendJson(request, "{\"error\":\"internal server error\"}", 500);
            return;
        };
        sendJson(request, body, 200);
        return;
    }
    if (std.mem.eql(u8, clean_path, "/json") or std.mem.eql(u8, clean_path, "/json/list")) {
        const body = listJson(arena, options, "about:blank") catch {
            sendJson(request, "{\"error\":\"internal server error\"}", 500);
            return;
        };
        sendJson(request, body, 200);
        return;
    }
    if (std.mem.eql(u8, clean_path, "/json/new")) {
        const url = targetUrlFromQuery(target);
        const body = targetJson(arena, options, url) catch {
            sendJson(request, "{\"error\":\"internal server error\"}", 500);
            return;
        };
        sendJson(request, body, 200);
        return;
    }
    if (std.mem.eql(u8, clean_path, "/json/protocol")) {
        sendJson(request, protocolJson(), 200);
        return;
    }
    if (std.mem.startsWith(u8, clean_path, "/devtools/")) {
        sendJson(request, "{\"error\":\"CDP WebSocket protocol is not implemented yet\"}", 501);
        return;
    }

    sendJson(request, "{\"error\":\"not found\"}", 404);
}

pub fn versionJson(allocator: std.mem.Allocator, options: Options) ![]const u8 {
    const ws = try browserWsUrl(allocator, options);
    return jsonObject(allocator, &.{
        .{ .key = "Browser", .value = "KuriBrowser/0.0.0" },
        .{ .key = "Protocol-Version", .value = "1.3" },
        .{ .key = "User-Agent", .value = "kuri-browser/0.0.0" },
        .{ .key = "V8-Version", .value = "QuickJS" },
        .{ .key = "WebKit-Version", .value = "kuri-native" },
        .{ .key = "webSocketDebuggerUrl", .value = ws },
    });
}

pub fn listJson(allocator: std.mem.Allocator, options: Options, url: []const u8) ![]const u8 {
    const target = try targetJson(allocator, options, url);
    return std.fmt.allocPrint(allocator, "[{s}]", .{target});
}

pub fn targetJson(allocator: std.mem.Allocator, options: Options, url: []const u8) ![]const u8 {
    const ws = try pageWsUrl(allocator, options);
    return jsonObject(allocator, &.{
        .{ .key = "id", .value = page_id },
        .{ .key = "type", .value = "page" },
        .{ .key = "title", .value = "Kuri Browser" },
        .{ .key = "url", .value = if (url.len == 0) "about:blank" else url },
        .{ .key = "webSocketDebuggerUrl", .value = ws },
    });
}

fn browserWsUrl(allocator: std.mem.Allocator, options: Options) ![]const u8 {
    return std.fmt.allocPrint(allocator, "ws://{s}:{d}/devtools/browser/{s}", .{ options.host, options.port, browser_id });
}

fn pageWsUrl(allocator: std.mem.Allocator, options: Options) ![]const u8 {
    return std.fmt.allocPrint(allocator, "ws://{s}:{d}/devtools/page/{s}", .{ options.host, options.port, page_id });
}

const JsonPair = struct {
    key: []const u8,
    value: []const u8,
};

fn jsonObject(allocator: std.mem.Allocator, pairs: []const JsonPair) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeByte('{');
    for (pairs, 0..) |pair, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(pair.key, .{}, &out.writer);
        try out.writer.writeByte(':');
        try std.json.Stringify.value(pair.value, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    return allocator.dupe(u8, out.written());
}

fn protocolJson() []const u8 {
    return
    \\{"version":{"major":"1","minor":"3"},"domains":[
    \\{"domain":"Browser","experimental":false,"deprecated":false,"commands":[],"events":[]},
    \\{"domain":"Target","experimental":false,"deprecated":false,"commands":[],"events":[]},
    \\{"domain":"Page","experimental":false,"deprecated":false,"commands":[],"events":[]},
    \\{"domain":"Runtime","experimental":false,"deprecated":false,"commands":[],"events":[]}
    \\]}
    ;
}

fn targetUrlFromQuery(target: []const u8) []const u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return "about:blank";
    const query = target[query_start + 1 ..];
    if (query.len == 0) return "about:blank";
    if (std.mem.startsWith(u8, query, "url=")) return query["url=".len..];
    return query;
}

fn sendJson(request: *std.http.Server.Request, body: []const u8, status_code: u10) void {
    const status: std.http.Status = @enumFromInt(status_code);
    request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
    }) catch |err| {
        std.log.err("failed to respond: {s}", .{@errorName(err)});
    };
}
