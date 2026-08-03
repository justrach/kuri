//! kuri-connect-broker — the key-holding broker daemon for the `connect` feature.
//!
//! Level-2 hardening: the agent (kuri-agent) never holds the vault passphrase.
//! This separate process holds `KURI_VAULT_PASSPHRASE`, opens the encrypted
//! nanostore vault, and exposes ONLY inject/list/save/delete over a
//! token-gated loopback HTTP API. It connects to the agent's own tab (a `cdp`
//! ws URL passed by the caller) to inject a decrypted session, and NEVER
//! returns secret values. So a compromised agent cannot decrypt the at-rest
//! vault or dump other saved services — its blast radius shrinks to the
//! sessions it explicitly asks the broker to load.
//!
//! Endpoints (all require ?token=<broker-token>):
//!   GET /list                      -> {"connections":[...]}
//!   GET /load?service=&cdp=<ws>    -> {"ok":true}        (decrypt + inject)
//!   GET /save?service=&cdp=<ws>    -> {"ok":true}        (capture + encrypt)
//!   GET /delete?service=           -> {"ok":true}
//!
//! Env: KURI_VAULT_PASSPHRASE (null => passwordless), STATE_DIR (default .kuri),
//!      KURI_BROKER_PORT (default 8765), KURI_BROKER_TOKEN (generated if unset).

const std = @import("std");
const net = std.Io.net;
const compat = @import("compat.zig");
const resp = @import("server/response.zig");
const connect_store = @import("storage/connect_store.zig");
const connect_cdp = @import("connect_cdp.zig");
const CdpClient = @import("cdp/client.zig").CdpClient;

const Cfg = struct {
    state_dir: []const u8,
    passphrase: ?[]const u8,
    token: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const state_dir = compat.getenv("STATE_DIR") orelse ".kuri";
    const passphrase = compat.getenv("KURI_VAULT_PASSPHRASE");
    const port: u16 = blk: {
        if (compat.getenv("KURI_BROKER_PORT")) |p| break :blk std.fmt.parseInt(u16, p, 10) catch 8765;
        break :blk 8765;
    };
    const token = compat.getenv("KURI_BROKER_TOKEN") orelse {
        compat.writeToStdout("kuri-connect-broker: set KURI_BROKER_TOKEN (a shared secret the agent uses to authenticate)\n");
        std.process.exit(2);
    };

    const cfg = Cfg{ .state_dir = state_dir, .passphrase = passphrase, .token = token };

    const io = std.Io.Threaded.global_single_threaded.io();
    const address = try net.IpAddress.parseIp4("127.0.0.1", port);
    var tcp_server = try net.IpAddress.listen(&address, io, .{ .reuse_address = true });
    defer tcp_server.deinit(io);

    compat.writeToStdout(std.fmt.allocPrint(gpa, "kuri-connect-broker listening on 127.0.0.1:{d}\n  token: {s}\n  vault: {s}/connections.ns ({s})\n", .{
        port, token, state_dir, if (passphrase != null) "passphrase-protected" else "passwordless",
    }) catch "kuri-connect-broker started\n");

    while (true) {
        const stream = tcp_server.accept(io) catch continue;
        handleConnection(gpa, cfg, stream);
    }
}

fn handleConnection(gpa: std.mem.Allocator, cfg: Cfg, stream: net.Stream) void {
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

    var request = http_server.receiveHead() catch return;
    route(&request, arena, cfg);
}

fn route(request: *std.http.Server.Request, arena: std.mem.Allocator, cfg: Cfg) void {
    const target = request.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;

    const token = getParam(target, "token") orelse "";
    if (!std.mem.eql(u8, token, cfg.token)) {
        resp.sendError(request, 401, "Unauthorized");
        return;
    }

    if (std.mem.eql(u8, path, "/list")) {
        handleList(request, arena, cfg);
    } else if (std.mem.eql(u8, path, "/load")) {
        handleLoad(request, arena, cfg);
    } else if (std.mem.eql(u8, path, "/save")) {
        handleSave(request, arena, cfg);
    } else if (std.mem.eql(u8, path, "/delete")) {
        handleDelete(request, arena, cfg);
    } else {
        resp.sendError(request, 404, "Not Found");
    }
}

fn handleList(request: *std.http.Server.Request, arena: std.mem.Allocator, cfg: Cfg) void {
    const names = connect_store.listSessions(arena, cfg.state_dir, cfg.passphrase) catch |err| {
        resp.sendError(request, 500, @errorName(err));
        return;
    };
    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(arena, "{\"connections\":[") catch {};
    for (names, 0..) |n, i| {
        if (i > 0) buf.appendSlice(arena, ",") catch {};
        buf.print(arena, "\"{s}\"", .{n}) catch {};
    }
    buf.appendSlice(arena, "]}") catch {};
    resp.sendJson(request, buf.items);
}

fn handleLoad(request: *std.http.Server.Request, arena: std.mem.Allocator, cfg: Cfg) void {
    const service = getParam(request.head.target, "service") orelse {
        resp.sendError(request, 400, "Missing service");
        return;
    };
    const cdp = getParam(request.head.target, "cdp") orelse {
        resp.sendError(request, 400, "Missing cdp");
        return;
    };
    const payload = connect_store.loadSession(arena, cfg.state_dir, cfg.passphrase, service) catch |err| {
        resp.sendError(request, 404, @errorName(err));
        return;
    };
    var client = CdpClient.init(arena, cdp);
    defer client.deinit();
    connect_cdp.restorePayload(arena, &client, payload);
    // Never echo the payload — only confirm the injection happened.
    resp.sendJson(request, "{\"ok\":true,\"loaded\":true}");
}

fn handleSave(request: *std.http.Server.Request, arena: std.mem.Allocator, cfg: Cfg) void {
    const service = getParam(request.head.target, "service") orelse {
        resp.sendError(request, 400, "Missing service");
        return;
    };
    const cdp = getParam(request.head.target, "cdp") orelse {
        resp.sendError(request, 400, "Missing cdp");
        return;
    };
    var client = CdpClient.init(arena, cdp);
    defer client.deinit();
    const payload = connect_cdp.capturePayload(arena, &client, service) catch |err| {
        resp.sendError(request, 502, @errorName(err));
        return;
    };
    const origin = connect_cdp.originOf(payload);
    connect_store.saveSession(arena, cfg.state_dir, cfg.passphrase, service, origin, payload) catch |err| {
        resp.sendError(request, 500, @errorName(err));
        return;
    };
    resp.sendJson(request, "{\"ok\":true,\"saved\":true,\"encrypted\":true}");
}

fn handleDelete(request: *std.http.Server.Request, arena: std.mem.Allocator, cfg: Cfg) void {
    const service = getParam(request.head.target, "service") orelse {
        resp.sendError(request, 400, "Missing service");
        return;
    };
    connect_store.deleteSession(arena, cfg.state_dir, cfg.passphrase, service) catch |err| {
        resp.sendError(request, 404, @errorName(err));
        return;
    };
    resp.sendJson(request, "{\"ok\":true,\"deleted\":true}");
}

/// Extract `name`'s value from a `?a=1&name=val&b=2` query. Values run to the
/// next '&' or end — safe for `cdp` ws URLs (which contain no '&').
fn getParam(target: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}
