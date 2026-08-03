//! kuri-gateway — the managed-service control plane (Track 1).
//!
//! Single-tenant `kuri` is one process = one Bridge = one Chrome. To run kuri as
//! a managed, multi-session service we put a thin gateway in front that:
//!   - authenticates tenants (bearer API keys, not the worker's per-process token)
//!   - leases/spawns/reaps one `kuri` worker (its own Chrome) per session
//!   - exposes an async task API (POST /v1/tasks) over the worker data plane
//!   - reverse-proxies the existing 200+ endpoints, scoped by session_id
//!
//! This file is the SCAFFOLD: the HTTP surface, the in-memory session table, and
//! the lifecycle interface are real and compile; worker process spawn and the
//! reverse proxy are stubbed (clearly marked) pending Track-1 implementation.
//! See docs/scaling/01-control-plane.md for the full design.
//!
//! Env:
//!   KURI_GATEWAY_PORT     listen port (default 9000)
//!   KURI_GATEWAY_KEY      required tenant API key (bearer); refuses to start unset
//!   KURI_WORKER_BIN       path to the `kuri` worker binary (default "kuri")
//!   KURI_WORKER_BASE_PORT first worker port (default 9300; incremented per session)

const std = @import("std");
const net = std.Io.net;
const compat = @import("compat.zig");
const resp = @import("server/response.zig");

const Cfg = struct {
    port: u16,
    api_key: []const u8,
    worker_bin: []const u8,
    worker_base_port: u16,
};

/// One leased worker (a `kuri` process owning one Chrome). Owned strings are
/// allocated from the gateway gpa and freed on removal.
const Session = struct {
    id: []const u8, // "sess_<hex>"
    tenant: []const u8,
    worker_token: []const u8, // the worker's own bearer; never leaves the gateway
    port: u16, // worker HTTP port on 127.0.0.1
    pid: ?i32, // null until worker spawn is wired
    created_ms: i64,
    last_used_ms: i64,
    expires_ms: i64,
    state: State,

    const State = enum { booting, ready, draining, dead };

    fn stateName(s: State) []const u8 {
        return switch (s) {
            .booting => "booting",
            .ready => "ready",
            .draining => "draining",
            .dead => "dead",
        };
    }
};

const Gateway = struct {
    gpa: std.mem.Allocator,
    cfg: Cfg,
    // NOTE: the accept loop is single-threaded today (like connect_broker), so
    // the session table needs no lock yet. When the background reaper thread
    // lands (§4), guard sessions/next_port with a lock introduced here.
    sessions: std.ArrayList(Session) = .empty,
    next_port: u16,

    fn deinit(self: *Gateway) void {
        for (self.sessions.items) |s| self.freeSession(s);
        self.sessions.deinit(self.gpa);
    }

    fn freeSession(self: *Gateway, s: Session) void {
        if (s.pid) |pid| killWorker(pid);
        self.gpa.free(s.id);
        self.gpa.free(s.tenant);
        self.gpa.free(s.worker_token);
    }
};

/// Monotonic-ish wall clock in ms. compat owns the platform clock; this wraps it.
fn nowMs() i64 {
    return compat.milliTimestamp();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const port: u16 = blk: {
        if (compat.getenv("KURI_GATEWAY_PORT")) |p| break :blk std.fmt.parseInt(u16, p, 10) catch 9000;
        break :blk 9000;
    };
    const worker_base: u16 = blk: {
        if (compat.getenv("KURI_WORKER_BASE_PORT")) |p| break :blk std.fmt.parseInt(u16, p, 10) catch 9300;
        break :blk 9300;
    };
    const api_key = compat.getenv("KURI_GATEWAY_KEY") orelse {
        compat.writeToStdout("kuri-gateway: set KURI_GATEWAY_KEY (the tenant API key clients authenticate with)\n");
        std.process.exit(2);
    };
    const worker_bin = compat.getenv("KURI_WORKER_BIN") orelse "kuri";

    var gw = Gateway{
        .gpa = gpa,
        .cfg = .{
            .port = port,
            .api_key = api_key,
            .worker_bin = worker_bin,
            .worker_base_port = worker_base,
        },
        .next_port = worker_base,
    };
    defer gw.deinit();

    const io = std.Io.Threaded.global_single_threaded.io();
    const address = try net.IpAddress.parseIp4("127.0.0.1", port);
    var tcp_server = try net.IpAddress.listen(&address, io, .{ .reuse_address = true });
    defer tcp_server.deinit(io);

    compat.writeToStdout(std.fmt.allocPrint(gpa, "kuri-gateway listening on 127.0.0.1:{d}\n  worker: {s} (base port {d})\n  data plane: ANY /v1/sessions/:id/<path>  |  tasks: /v1/tasks\n", .{
        port, worker_bin, worker_base,
    }) catch "kuri-gateway started\n");

    while (true) {
        const stream = tcp_server.accept(io) catch continue;
        handleConnection(&gw, stream);
    }
}

fn handleConnection(gw: *Gateway, stream: net.Stream) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    defer stream.close(io);

    var arena_impl = std.heap.ArenaAllocator.init(gw.gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var read_buf: [16384]u8 = undefined;
    var net_reader = net.Stream.Reader.init(stream, io, &read_buf);
    var write_buf: [16384]u8 = undefined;
    var net_writer = net.Stream.Writer.init(stream, io, &write_buf);
    var http_server = std.http.Server.init(&net_reader.interface, &net_writer.interface);

    var request = http_server.receiveHead() catch return;
    // One request per connection (we close on return, no keep-alive loop). Force
    // keep_alive off so std's respond() path doesn't try to discard an unframed
    // body — a keep-alive POST without Content-Length otherwise trips an assert
    // in std.http.Server.discardBody. The reverse proxy (§6) will stream bodies.
    request.head.keep_alive = false;
    route(gw, &request, arena);
}

fn route(gw: *Gateway, request: *std.http.Server.Request, arena: std.mem.Allocator) void {
    const target = request.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
    const method = request.head.method;

    // Health is unauthenticated so load balancers / probes can hit it.
    if (std.mem.eql(u8, path, "/health")) {
        handleHealth(gw, request, arena);
        return;
    }

    // Everything else requires the tenant bearer key.
    if (!authorized(gw, request)) {
        resp.sendError(request, 401, "Unauthorized");
        return;
    }
    // Scaffold: a single static key maps to one tenant. Real impl resolves the
    // key against a tenant/plan store (see §7 of the design doc).
    const tenant = "default";

    if (std.mem.eql(u8, path, "/v1/sessions")) {
        switch (method) {
            .POST => handleCreateSession(gw, request, arena, tenant),
            .GET => handleListSessions(gw, request, arena, tenant),
            else => resp.sendError(request, 405, "Method Not Allowed"),
        }
        return;
    }

    if (std.mem.startsWith(u8, path, "/v1/sessions/")) {
        const rest = path["/v1/sessions/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            // /v1/sessions/:id/<data-path>  → reverse proxy to the worker.
            const sid = rest[0..slash];
            const data_path = rest[slash..]; // leading '/'
            handleProxy(gw, request, arena, tenant, sid, data_path);
        } else {
            // /v1/sessions/:id  → get or delete.
            switch (method) {
                .GET => handleGetSession(gw, request, arena, tenant, rest),
                .DELETE => handleDeleteSession(gw, request, arena, tenant, rest),
                else => resp.sendError(request, 405, "Method Not Allowed"),
            }
        }
        return;
    }

    if (std.mem.eql(u8, path, "/v1/tasks") or std.mem.startsWith(u8, path, "/v1/tasks/")) {
        // TODO(Track 1, §5): async task executor over the worker /batch endpoint.
        resp.sendError(request, 501, "tasks not yet implemented (scaffold)");
        return;
    }

    resp.sendError(request, 404, "Not Found");
}

/// Constant-time-ish bearer check against the configured tenant key.
fn authorized(gw: *Gateway, request: *std.http.Server.Request) bool {
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
            const prefix = "Bearer ";
            if (h.value.len > prefix.len and std.mem.startsWith(u8, h.value, prefix)) {
                const presented = h.value[prefix.len..];
                return constEql(presented, gw.cfg.api_key);
            }
        }
    }
    return false;
}

fn constEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

fn handleHealth(gw: *Gateway, request: *std.http.Server.Request, arena: std.mem.Allocator) void {
    const n = gw.sessions.items.len;
    const body = std.fmt.allocPrint(arena, "{{\"ok\":true,\"service\":\"kuri-gateway\",\"sessions\":{d}}}", .{n}) catch "{\"ok\":true}";
    resp.sendJson(request, body);
}

fn handleCreateSession(gw: *Gateway, request: *std.http.Server.Request, arena: std.mem.Allocator, tenant: []const u8) void {
    // Allocate identifiers + a port, then spawn a real worker (its own Chrome).
    var id_bytes: [12]u8 = undefined;
    compat.randomBytes(id_bytes[0..]);
    var tok_bytes: [24]u8 = undefined;
    compat.randomBytes(tok_bytes[0..]);
    const id_hex = std.fmt.bytesToHex(id_bytes, .lower); // [24]u8
    const tok_hex = std.fmt.bytesToHex(tok_bytes, .lower); // [48]u8

    const id = std.fmt.allocPrint(gw.gpa, "sess_{s}", .{id_hex[0..]}) catch {
        resp.sendError(request, 500, "alloc");
        return;
    };
    const worker_token = gw.gpa.dupe(u8, tok_hex[0..]) catch {
        gw.gpa.free(id);
        resp.sendError(request, 500, "alloc");
        return;
    };
    const tenant_owned = gw.gpa.dupe(u8, tenant) catch {
        gw.gpa.free(id);
        gw.gpa.free(worker_token);
        resp.sendError(request, 500, "alloc");
        return;
    };

    const now = nowMs();
    const port = gw.next_port;
    gw.next_port +%= 1;
    const sess = Session{
        .id = id,
        .tenant = tenant_owned,
        .worker_token = worker_token,
        .port = port,
        .pid = null,
        .created_ms = now,
        .last_used_ms = now,
        .expires_ms = now + 900 * 1000, // default 15 min TTL (plan cap applies)
        .state = .booting,
    };
    gw.sessions.append(gw.gpa, sess) catch {
        gw.freeSession(sess);
        resp.sendError(request, 500, "session table full");
        return;
    };

    // Spawn the worker process (its own Chrome on 127.0.0.1:port) and block until
    // it answers /health. The accept loop is single-threaded today, so boot is
    // serialized; async boot + a background reaper land with the rest of section 4.
    const sptr = &gw.sessions.items[gw.sessions.items.len - 1];
    const booted = spawnWorker(gw, sptr, arena) and workerReady(arena, sptr.port, sptr.worker_token);
    if (!booted) {
        // Tear the half-spawned worker down and drop the reservation.
        const removed = gw.sessions.swapRemove(gw.sessions.items.len - 1);
        gw.freeSession(removed);
        resp.sendError(request, 503, "worker failed to boot");
        return;
    }
    sptr.state = .ready;

    const body = std.fmt.allocPrint(arena,
        "{{\"session_id\":\"{s}\",\"state\":\"{s}\",\"expires_at_ms\":{d}," ++
        "\"port\":{d},\"live_url\":null}}",
        .{ sptr.id, Session.stateName(sptr.state), sptr.expires_ms, sptr.port },
    ) catch "{\"error\":\"alloc\"}";
    resp.sendJson(request, body);
}

fn handleGetSession(gw: *Gateway, request: *std.http.Server.Request, arena: std.mem.Allocator, tenant: []const u8, sid: []const u8) void {
    const s = findSession(gw, tenant, sid) orelse {
        resp.sendError(request, 404, "session not found");
        return;
    };
    const body = std.fmt.allocPrint(arena,
        "{{\"session_id\":\"{s}\",\"state\":\"{s}\",\"created_at_ms\":{d}," ++
        "\"last_used_ms\":{d},\"expires_at_ms\":{d}}}",
        .{ s.id, Session.stateName(s.state), s.created_ms, s.last_used_ms, s.expires_ms },
    ) catch "{\"error\":\"alloc\"}";
    resp.sendJson(request, body);
}

fn handleDeleteSession(gw: *Gateway, request: *std.http.Server.Request, arena: std.mem.Allocator, tenant: []const u8, sid: []const u8) void {
    var billed_ms: i64 = 0;
    var found = false;
    for (gw.sessions.items, 0..) |s, i| {
        if (std.mem.eql(u8, s.tenant, tenant) and std.mem.eql(u8, s.id, sid)) {
            billed_ms = nowMs() - s.created_ms;
            // freeSession SIGTERMs + reaps the worker pid; the worker's own
            // lifecycle hook tears down its Chrome cleanly on the signal.
            const removed = gw.sessions.swapRemove(i);
            gw.freeSession(removed);
            found = true;
            break;
        }
    }
    if (!found) {
        resp.sendError(request, 404, "session not found");
        return;
    }
    const body = std.fmt.allocPrint(arena, "{{\"stopped\":true,\"billed_ms\":{d}}}", .{billed_ms}) catch "{\"stopped\":true}";
    resp.sendJson(request, body);
}

fn handleListSessions(gw: *Gateway, request: *std.http.Server.Request, arena: std.mem.Allocator, tenant: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    buf.appendSlice(arena, "{\"sessions\":[") catch {};
    var first = true;
    for (gw.sessions.items) |s| {
        if (!std.mem.eql(u8, s.tenant, tenant)) continue;
        if (!first) buf.appendSlice(arena, ",") catch {};
        first = false;
        buf.print(arena, "{{\"session_id\":\"{s}\",\"state\":\"{s}\"}}", .{ s.id, Session.stateName(s.state) }) catch {};
    }
    buf.appendSlice(arena, "]}") catch {};
    resp.sendJson(request, buf.items);
}

fn handleProxy(gw: *Gateway, request: *std.http.Server.Request, arena: std.mem.Allocator, tenant: []const u8, sid: []const u8, data_path: []const u8) void {
    _ = data_path;
    const s = findSession(gw, tenant, sid) orelse {
        resp.sendError(request, 404, "session not found");
        return;
    };
    if (s.state != .ready) {
        resp.sendError(request, 503, "worker not ready");
        return;
    }
    s.last_used_ms = nowMs();

    // Forward the path+query that follows /v1/sessions/<sid> to the worker verbatim.
    const prefix_len = "/v1/sessions/".len + sid.len;
    const target = request.head.target;
    const fwd_path = if (target.len > prefix_len) target[prefix_len..] else "/";
    const req_body = readReqBody(request, arena);

    const wr = callWorker(arena, s.port, s.worker_token, methodName(request.head.method), fwd_path, req_body) orelse {
        resp.sendError(request, 502, "worker unreachable");
        return;
    };

    request.respond(wr.body, .{
        .status = @enumFromInt(wr.status),
        .extra_headers = &.{
            .{ .name = "content-type", .value = wr.content_type },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
    }) catch |err| {
        std.log.err("proxy: failed to relay worker response: {s}", .{@errorName(err)});
    };
}

// --- worker process lifecycle + reverse-proxy plumbing (Track 1, section 4 + 6) ---

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// SIGTERM a worker and reap it. The worker's own lifecycle hook tears down its
/// Chrome cleanly on the signal (see main.zig lifecycle.install).
fn killWorker(pid: i32) void {
    _ = std.c.kill(pid, std.c.SIG.TERM);
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
}

/// Fork+exec a `kuri` worker bound to 127.0.0.1:sess.port with its own bearer
/// token and an isolated HOME, so each Chrome gets its own profile dir and they
/// never collide on Chromium's SingletonLock. Sets sess.pid; returns false on
/// fork failure. Every string is built in the parent before the fork — the child
/// only calls setenv/exec, which are async-signal-safe.
fn spawnWorker(gw: *Gateway, sess: *Session, arena: std.mem.Allocator) bool {
    // Per-session scratch under /tmp isolates the worker's Chrome profile, bridge
    // state, and token file from every other session.
    const home = std.fmt.allocPrint(arena, "/tmp/kuri-gw/{s}", .{sess.id}) catch return false;
    compat.cwdMakePath(home) catch {};

    const port_str = std.fmt.allocPrint(arena, "{d}", .{sess.port}) catch return false;
    const state_str = std.fmt.allocPrint(arena, "{s}/state", .{home}) catch return false;

    const bin_z = arena.dupeSentinel(u8, gw.cfg.worker_bin, 0) catch return false;
    const port_z = arena.dupeSentinel(u8, port_str, 0) catch return false;
    const token_z = arena.dupeSentinel(u8, sess.worker_token, 0) catch return false;
    const home_z = arena.dupeSentinel(u8, home, 0) catch return false;
    const state_z = arena.dupeSentinel(u8, state_str, 0) catch return false;

    var argv = [_:null]?[*:0]const u8{bin_z.ptr};

    const pid = std.c.fork();
    if (pid < 0) return false;
    if (pid == 0) {
        // Child: silence stdio, set the worker's env, exec.
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(c_uint, 0));
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 1);
            _ = std.c.dup2(devnull, 2);
            _ = std.c.close(devnull);
        }
        _ = setenv("PORT", port_z.ptr, 1);
        _ = setenv("HOST", "127.0.0.1", 1);
        _ = setenv("HEADLESS", "true", 1);
        _ = setenv("KURI_API_TOKEN", token_z.ptr, 1);
        _ = setenv("HOME", home_z.ptr, 1);
        _ = setenv("STATE_DIR", state_z.ptr, 1);
        _ = setenv("KURI_NO_TELEMETRY", "1", 1);
        _ = compat.execvp(argv[0].?, @ptrCast(&argv));
        std.c._exit(127);
    }
    sess.pid = pid;
    return true;
}

/// Poll GET /health on the worker until it answers 200 or we give up (~30s of
/// 200ms ticks). Chrome cold-start is ~1-3s but headless first-run can be slower.
fn workerReady(arena: std.mem.Allocator, port: u16, token: []const u8) bool {
    // Generous budget: cold first-run headless Chrome with a brand-new profile dir
    // can take well over 30s on first launch (Gatekeeper + profile setup), though
    // warm boots are ~1-3s. Blocking the single-threaded accept loop this long is a
    // scaffold tradeoff — async boot + a background reaper are the real fix (sec 4).
    var i: u32 = 0;
    while (i < 450) : (i += 1) { // 450 * 200ms = 90s
        if (callWorker(arena, port, token, "GET", "/health", null)) |wr| {
            if (wr.status == 200) return true;
        }
        compat.threadSleep(200 * std.time.ns_per_ms);
    }
    return false;
}

const WorkerResponse = struct {
    status: u16,
    content_type: []const u8,
    body: []const u8,
};

/// Open a one-shot HTTP/1.1 connection to 127.0.0.1:port, send method+path with
/// the worker's bearer token, and return the parsed response. Connection: close
/// plus a Content-Length-aware read keep this correct for the JSON data plane
/// (chunked / streaming endpoints like /screencast are a known v1 limitation).
fn callWorker(arena: std.mem.Allocator, port: u16, token: []const u8, method: []const u8, path: []const u8, req_body: ?[]const u8) ?WorkerResponse {
    const stream = compat.tcpConnectToIp4(port) catch return null;
    defer stream.close();

    // Bound every recv/send so one wedged worker can't hang the single-threaded
    // accept loop forever. 60s comfortably covers slow page ops (navigate/snapshot)
    // while still guaranteeing forward progress.
    const tv = std.posix.timeval{ .sec = 60, .usec = 0 };
    stream.setSockOpt(std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
    stream.setSockOpt(std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv));

    var req: std.ArrayList(u8) = .empty;
    req.print(arena, "{s} {s} HTTP/1.1\r\n", .{ method, path }) catch return null;
    req.appendSlice(arena, "Host: 127.0.0.1\r\n") catch return null;
    req.print(arena, "Authorization: Bearer {s}\r\n", .{token}) catch return null;
    req.appendSlice(arena, "Connection: close\r\n") catch return null;
    if (req_body) |b| {
        req.appendSlice(arena, "Content-Type: application/json\r\n") catch return null;
        req.print(arena, "Content-Length: {d}\r\n", .{b.len}) catch return null;
    }
    req.appendSlice(arena, "\r\n") catch return null;
    if (req_body) |b| req.appendSlice(arena, b) catch return null;
    stream.writeAll(req.items) catch return null;

    const max_resp: usize = 16 * 1024 * 1024;
    var raw: std.ArrayList(u8) = .empty;
    var chunk: [16384]u8 = undefined;
    while (true) {
        const n = stream.read(&chunk) catch break;
        if (n == 0) break;
        raw.appendSlice(arena, chunk[0..n]) catch break;
        if (raw.items.len > max_resp) break;
        // Stop once we have headers + a complete Content-Length body, so we never
        // block waiting for the peer to close the socket.
        if (responseComplete(raw.items)) break;
    }
    return parseHttpResponse(raw.items);
}

/// True once `raw` holds the status line, all headers, and (if a Content-Length
/// is present) the whole body. Without a Content-Length we read until EOF.
fn responseComplete(raw: []const u8) bool {
    const hdr_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return false;
    const headers = raw[0..hdr_end];
    const body_len = raw.len - (hdr_end + 4);
    if (findContentLength(headers)) |cl| return body_len >= cl;
    return false;
}

fn findContentLength(headers: []const u8) ?usize {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), "content-length")) {
            const v = std.mem.trim(u8, line[colon + 1 ..], " ");
            return std.fmt.parseInt(usize, v, 10) catch null;
        }
    }
    return null;
}

fn parseHttpResponse(raw: []const u8) ?WorkerResponse {
    const line_end = std.mem.indexOf(u8, raw, "\r\n") orelse return null;
    const status_line = raw[0..line_end];
    const sp1 = std.mem.indexOfScalar(u8, status_line, ' ') orelse return null;
    const after = status_line[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
    const status = std.fmt.parseInt(u16, after[0..sp2], 10) catch return null;

    const hdr_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return null;
    const headers = raw[line_end + 2 .. hdr_end];
    const body = raw[hdr_end + 4 ..];

    var content_type: []const u8 = "application/json";
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), "content-type")) {
            content_type = std.mem.trim(u8, line[colon + 1 ..], " ");
        }
    }
    return .{ .status = status, .content_type = content_type, .body = body };
}

fn methodName(m: std.http.Method) []const u8 {
    return switch (m) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
        .PATCH => "PATCH",
        .HEAD => "HEAD",
        .OPTIONS => "OPTIONS",
        else => "GET",
    };
}

fn readReqBody(request: *std.http.Server.Request, arena: std.mem.Allocator) ?[]const u8 {
    if (!request.head.method.requestHasBody()) return null;
    if (request.head.expect != null) return null;
    const content_length = request.head.content_length orelse return null;
    if (content_length == 0) return null;
    const max_body: usize = 4 * 1024 * 1024;
    const len: usize = @intCast(@min(content_length, max_body));
    var buf: [65536]u8 = undefined;
    const reader = request.readerExpectNone(&buf);
    const body = reader.readAlloc(arena, len) catch return null;
    if (body.len == 0) return null;
    return body;
}

/// Returns a borrowed pointer into the sessions table (single-threaded today).
fn findSession(gw: *Gateway, tenant: []const u8, sid: []const u8) ?*Session {
    for (gw.sessions.items) |*s| {
        if (std.mem.eql(u8, s.tenant, tenant) and std.mem.eql(u8, s.id, sid)) return s;
    }
    return null;
}

/// Bump last_used_ms for idle-reap accounting (single-threaded today).
fn sessTouch(gw: *Gateway, sid: []const u8) void {
    for (gw.sessions.items) |*s| {
        if (std.mem.eql(u8, s.id, sid)) {
            s.last_used_ms = nowMs();
            return;
        }
    }
}

test "constEql distinguishes equal and unequal" {
    try std.testing.expect(constEql("abc", "abc"));
    try std.testing.expect(!constEql("abc", "abd"));
    try std.testing.expect(!constEql("abc", "ab"));
}

test "session table create/find/remove round-trip" {
    var gw = Gateway{
        .gpa = std.testing.allocator,
        .cfg = .{ .port = 0, .api_key = "k", .worker_bin = "kuri", .worker_base_port = 9300 },
        .next_port = 9300,
    };
    defer gw.deinit();

    const id = try gw.gpa.dupe(u8, "sess_test");
    const tok = try gw.gpa.dupe(u8, "tok");
    const ten = try gw.gpa.dupe(u8, "default");
    try gw.sessions.append(gw.gpa, .{
        .id = id,
        .tenant = ten,
        .worker_token = tok,
        .port = 9300,
        .pid = null,
        .created_ms = 0,
        .last_used_ms = 0,
        .expires_ms = 1000,
        .state = .booting,
    });

    try std.testing.expect(findSession(&gw, "default", "sess_test") != null);
    try std.testing.expect(findSession(&gw, "other", "sess_test") == null);
    try std.testing.expect(findSession(&gw, "default", "nope") == null);
}
