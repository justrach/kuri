//! Anonymous, opt-out usage telemetry for kuri.
//!
//! Design mirrors codedb's telemetry (lock-free ring → on-disk WAL →
//! background cloud sync → truncate on success), but the payload is shaped as
//! OpenTelemetry **OTLP/HTTP logs** JSON so it can be POSTed straight at an
//! OTel collector or any `/v1/logs`-compatible endpoint.
//!
//! ## Privacy
//! We record only aggregate usage signal — never anything that identifies a
//! user or what they browse:
//!   - the **route name** only (`/navigate`, `/screenshot`, …). The query
//!     string is stripped *before* it reaches here, so the navigated URL,
//!     selectors, cookies, and page content are never seen by telemetry.
//!   - HTTP method, response status code, latency (ns), and response size
//!     (bytes) — the "how much" the user asked for.
//!   - platform (os/arch), kuri version, and a random per-install instance id
//!     (so distinct installs can be counted without any PII).
//!
//! ## Opt out
//!   - `KURI_NO_TELEMETRY=1` (any non-empty value), or
//!   - the `--no-telemetry` CLI flag.
//!
//! ## Endpoint
//! Defaults to `DEFAULT_TELEMETRY_URL` (a placeholder until the real ingest is
//! live). Override with `KURI_TELEMETRY_URL`. The local WAL at
//! `~/.kuri/telemetry.ndjson` is written regardless; sync only ships it.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");

const VERSION = @import("build_options").version;
const PLATFORM_OS = @tagName(builtin.os.tag);
const PLATFORM_ARCH = @tagName(builtin.cpu.arch);

/// Where synced telemetry is POSTed: an OTLP/HTTP logs ingest that accepts the
/// envelope documented in docs/telemetry.md. Override with KURI_TELEMETRY_URL.
const DEFAULT_TELEMETRY_URL = "https://codegraff.com/api/telemetry/v1/kuri";

const RING_SIZE = 256;
/// Inline flush cadence — must be a power of two so the hot path masks instead
/// of mods. RING_SIZE / FLUSH_INTERVAL_EVENTS ≥ 4 keeps the ring from wrapping
/// before a flush even under a burst.
const FLUSH_INTERVAL_EVENTS: u64 = 64;
/// Cap how much WAL we read+wrap+ship per sync, so a runaway file can't OOM.
const MAX_WAL_READ_BYTES = 8 * 1024 * 1024;

/// Tiny CAS spinlock. `record()` is the hot path (called per HTTP request from
/// per-connection threads); an uncontended spinlock lock+unlock is ~5–10 ns vs
/// ~100–200 ns for a pthread mutex, and contention is near-zero since the only
/// other writer is the rare flush().
const SpinLock = struct {
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic)) |_| {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};

const EventKind = enum(u8) { session_start, http_request };

const Event = struct {
    kind: EventKind = .session_start,
    time_ns: i128 = 0,
    route: [64]u8 = .{0} ** 64,
    route_len: u8 = 0,
    method: [8]u8 = .{0} ** 8,
    method_len: u8 = 0,
    status: u16 = 0,
    latency_ns: i64 = 0,
    bytes: u32 = 0,
    is_error: bool = false,
};

/// Per-request response capture. Each HTTP connection runs on its own thread,
/// so a thread-local lets response.zig hand the status + body size back to
/// handleConnection without threading state through all ~180 handlers.
pub const ResponseInfo = struct { status: u16 = 0, bytes: u32 = 0, captured: bool = false };
pub threadlocal var tl_response: ResponseInfo = .{};

/// Called by response.zig right before it writes the HTTP response. Records the
/// status + body size for the in-flight request on this thread.
pub fn noteResponse(status: u16, body_len: usize) void {
    tl_response = .{
        .status = status,
        .bytes = @intCast(@min(body_len, std.math.maxInt(u32))),
        .captured = true,
    };
}

/// Reset the thread-local before dispatching a request so a prior keep-alive
/// request's response can't leak into this one.
pub fn beginRequest() void {
    tl_response = .{};
}

pub const Telemetry = struct {
    ring: [RING_SIZE]Event = undefined,
    head: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    tail: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    enabled: bool = false,
    write_lock: SpinLock = .{},
    call_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Paths (owned, fixed buffers — telemetry outlives any arena).
    wal_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    wal_path_len: usize = 0,
    tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    tmp_path_len: usize = 0,

    // Anonymous per-install id (hex). Lets distinct installs be counted with no PII.
    instance_id: [64]u8 = undefined,
    instance_id_len: usize = 0,

    // Per-process session id (hex), regenerated every run (not persisted).
    session_id: [32]u8 = undefined,
    session_id_len: usize = 0,

    // Ingest URL (owned).
    url_buf: [1024]u8 = undefined,
    url_len: usize = 0,

    // Scratch buffer for formatting a single event into the WAL.
    fmt_buf: [2048]u8 = undefined,

    // Background cloud-sync thread.
    sync_thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sync_interval_seconds: u64 = 30,

    fn walPath(self: *Telemetry) []const u8 {
        return self.wal_path_buf[0..self.wal_path_len];
    }
    fn tmpPath(self: *Telemetry) []const u8 {
        return self.tmp_path_buf[0..self.tmp_path_len];
    }
    fn instanceId(self: *Telemetry) []const u8 {
        return self.instance_id[0..self.instance_id_len];
    }
    fn sessionId(self: *Telemetry) []const u8 {
        return self.session_id[0..self.session_id_len];
    }
    fn url(self: *Telemetry) []const u8 {
        return self.url_buf[0..self.url_len];
    }
};

/// Module-level singleton. A global keeps the call sites (handleConnection,
/// response.zig) free of pointer plumbing; `record()` is internally locked and
/// the global is fully populated by init() before any connection thread spawns.
var g_telem: Telemetry = .{};

pub fn instance() *Telemetry {
    return &g_telem;
}

/// Initialize telemetry. Safe to call once at startup. `disabled` comes from the
/// --no-telemetry CLI flag; KURI_NO_TELEMETRY is also honored here.
pub fn init(allocator: std.mem.Allocator, disabled: bool) void {
    const self = &g_telem;
    self.enabled = false;

    if (disabled) return;
    if (compat.getenv("KURI_NO_TELEMETRY")) |v| {
        if (v.len > 0) return;
    }
    if (builtin.os.tag == .windows) return; // file/curl helpers are POSIX-only

    const home = compat.getenv("HOME") orelse "/tmp";
    const data_dir = std.fmt.allocPrint(allocator, "{s}/.kuri", .{home}) catch return;
    defer allocator.free(data_dir);
    compat.cwdMakePath(data_dir) catch {};

    const wal = std.fmt.bufPrint(&self.wal_path_buf, "{s}/telemetry.ndjson", .{data_dir}) catch return;
    self.wal_path_len = wal.len;
    const tmp = std.fmt.bufPrint(&self.tmp_path_buf, "{s}/telemetry.otlp.tmp", .{data_dir}) catch return;
    self.tmp_path_len = tmp.len;

    // Resolve the ingest URL: env override wins, else the compiled default.
    const resolved_url = compat.getenv("KURI_TELEMETRY_URL") orelse DEFAULT_TELEMETRY_URL;
    if (resolved_url.len == 0 or resolved_url.len > self.url_buf.len) return;
    @memcpy(self.url_buf[0..resolved_url.len], resolved_url);
    self.url_len = resolved_url.len;

    loadOrCreateInstanceId(self, allocator, data_dir);

    // Fresh session id per process run (16 random bytes → 32 hex chars).
    var session_bytes: [16]u8 = undefined;
    compat.randomBytes(session_bytes[0..]);
    const session_hex = std.fmt.bytesToHex(session_bytes, .lower);
    @memcpy(self.session_id[0..session_hex.len], session_hex[0..]);
    self.session_id_len = session_hex.len;

    self.enabled = true;
}

/// Start the background sync thread. Call AFTER init() and after g_telem is at
/// its final address (it's a global, so that's always true here). No-op when
/// disabled or already started.
pub fn startSyncThread() void {
    const self = &g_telem;
    if (!self.enabled or self.sync_thread != null) return;
    self.sync_thread = std.Thread.spawn(.{}, syncThreadFn, .{self}) catch return;
}

pub fn deinit() void {
    const self = &g_telem;
    self.should_stop.store(true, .release);
    if (self.sync_thread) |th| {
        th.join();
        self.sync_thread = null;
    }
    if (!self.enabled) return;
    flush(self);
    syncToCloud(self); // final ship on shutdown
}

fn loadOrCreateInstanceId(self: *Telemetry, allocator: std.mem.Allocator, data_dir: []const u8) void {
    const id_path = std.fmt.allocPrint(allocator, "{s}/instance_id", .{data_dir}) catch return;
    defer allocator.free(id_path);

    if (compat.cwdAccess(id_path)) {
        if (compat.cwdReadFile(allocator, id_path, 128)) |raw| {
            defer allocator.free(raw);
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len > 0 and trimmed.len <= self.instance_id.len) {
                @memcpy(self.instance_id[0..trimmed.len], trimmed);
                self.instance_id_len = trimmed.len;
                return;
            }
        } else |_| {}
    }

    // Generate a fresh 16-byte random id, hex-encoded (32 chars).
    var raw_bytes: [16]u8 = undefined;
    compat.randomBytes(raw_bytes[0..]);
    const hex = std.fmt.bytesToHex(raw_bytes, .lower);
    @memcpy(self.instance_id[0..hex.len], hex[0..]);
    self.instance_id_len = hex.len;
    compat.cwdWriteFile(id_path, hex[0..]) catch {};
}

// --- Recording ---

pub fn recordSessionStart() void {
    record(&g_telem, .{ .kind = .session_start, .time_ns = compat.nanoTimestamp() });
}

/// Record one HTTP request. `route` must be the path with the query string
/// already stripped (the dispatcher's clean_path) — never the raw target.
pub fn recordRequest(route: []const u8, method: []const u8, status: u16, latency_ns: i64, response_bytes: u32, is_error: bool) void {
    const self = &g_telem;
    if (!self.enabled) return;

    var ev = Event{
        .kind = .http_request,
        .time_ns = compat.nanoTimestamp(),
        .status = status,
        .latency_ns = latency_ns,
        .bytes = response_bytes,
        .is_error = is_error,
    };
    const rlen: u8 = @intCast(@min(route.len, ev.route.len));
    @memcpy(ev.route[0..rlen], route[0..rlen]);
    ev.route_len = rlen;
    const mlen: u8 = @intCast(@min(method.len, ev.method.len));
    @memcpy(ev.method[0..mlen], method[0..mlen]);
    ev.method_len = mlen;

    record(self, ev);
}

fn record(self: *Telemetry, ev: Event) void {
    if (!self.enabled) return;

    self.write_lock.lock();
    const next = self.head.fetchAdd(1, .monotonic);
    const slot = next % RING_SIZE;
    self.ring[slot] = ev;
    const tail = self.tail.load(.monotonic);
    if ((next + 1) -% tail > RING_SIZE) {
        self.tail.store((next + 1) -% RING_SIZE, .monotonic);
    }
    self.write_lock.unlock();

    const count = self.call_count.fetchAdd(1, .monotonic) + 1;
    if (count & (FLUSH_INTERVAL_EVENTS - 1) == 0) {
        flush(self);
    }
}

// --- WAL flush ---

fn openAppend(path: []const u8) ?std.c.fd_t {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const fd = std.c.open(
        buf[0..path.len :0],
        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
        @as(std.c.mode_t, 0o600),
    );
    if (fd < 0) return null;
    return fd;
}

/// Drain the ring to the on-disk WAL as newline-delimited OTLP logRecord JSON.
fn flush(self: *Telemetry) void {
    if (!self.enabled) return;

    self.write_lock.lock();
    defer self.write_lock.unlock();

    const tail = self.tail.load(.monotonic);
    const head = self.head.load(.monotonic);
    if (tail == head) return;

    const fd = openAppend(self.walPath()) orelse {
        // Couldn't open the WAL — drop these events rather than spin.
        self.tail.store(head, .monotonic);
        return;
    };
    defer compat.fdClose(fd);

    var i = tail;
    while (i != head) : (i +%= 1) {
        const ev = self.ring[i % RING_SIZE];
        const len = formatLogRecord(self, &ev) catch continue;
        compat.fdWriteAll(fd, self.fmt_buf[0..len]) catch continue;
    }
    self.tail.store(head, .monotonic);
}

/// Format one event as a single kuri.telemetry.v1 logRecord JSON object +
/// trailing newline. `body` is a plain string event name; `attributes` is a
/// flat JSON object (the shape the ingest endpoint flattens into a row).
fn formatLogRecord(self: *Telemetry, ev: *const Event) !usize {
    var stream = std.Io.Writer.fixed(&self.fmt_buf);
    const w = &stream;
    const time_ns: u64 = @intCast(@max(ev.time_ns, 0));

    const body_name = switch (ev.kind) {
        .session_start => "kuri.session.start",
        .http_request => "kuri.http.request",
    };

    // severityNumber 9 = INFO. timeUnixNano is a string to avoid JS precision
    // loss; attribute values use native JSON types (numbers/bools/strings).
    try w.print(
        "{{\"timeUnixNano\":\"{d}\",\"body\":\"{s}\",\"severityText\":\"INFO\",\"severityNumber\":9,\"attributes\":{{",
        .{ time_ns, body_name },
    );

    switch (ev.kind) {
        .session_start => {
            // Platform lives on the session event (attributes are persisted).
            try w.print("\"os.type\":\"{s}\",\"host.arch\":\"{s}\"", .{ PLATFORM_OS, PLATFORM_ARCH });
        },
        .http_request => {
            try w.print("\"http.route\":\"{s}\",", .{ev.route[0..ev.route_len]});
            try w.print("\"http.request.method\":\"{s}\",", .{ev.method[0..ev.method_len]});
            try w.print("\"http.response.status_code\":{d},", .{ev.status});
            try w.print("\"http.server.request.duration_ns\":{d},", .{ev.latency_ns});
            try w.print("\"http.response.body.size\":{d},", .{ev.bytes});
            try w.print("\"error\":{s}", .{if (ev.is_error) "true" else "false"});
        },
    }

    try w.writeAll("}}\n");
    return w.end;
}

// --- Cloud sync ---

/// Wrap the WAL's logRecords in a kuri.telemetry.v1 envelope and POST it. On a
/// 2xx the WAL is truncated. Runs on the background thread (and once at
/// shutdown), so it never blocks a request.
fn syncToCloud(self: *Telemetry) void {
    if (!self.enabled or self.wal_path_len == 0 or self.url_len == 0) return;

    const allocator = std.heap.page_allocator;
    const wal = compat.cwdReadFile(allocator, self.walPath(), MAX_WAL_READ_BYTES) catch return;
    defer allocator.free(wal);
    if (wal.len == 0) return;

    const body = buildPayload(self, allocator, wal) catch return;
    defer allocator.free(body);

    // Stage the body in a temp file; curl ships it with no shell interpolation.
    compat.cwdWriteFile(self.tmpPath(), body) catch return;

    var data_arg_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const data_arg = std.fmt.bufPrint(&data_arg_buf, "@{s}", .{self.tmpPath()}) catch return;

    const result = compat.runCommand(allocator, &.{
        "curl",          "-sf",
        "-X",            "POST",
        self.url(),      "-H",
        "Content-Type: application/json",
        "--data-binary", data_arg,
        "--max-time",    "5",
    }, 4096) catch return;
    allocator.free(result.stdout);

    compat.cwdDeleteFile(self.tmpPath()) catch {};

    // curl -f exits non-zero on HTTP >= 400; only clear the WAL on a clean ship.
    if (result.term == 0) {
        const fd = compat.cwdCreateFile(self.walPath()) catch return;
        compat.fdClose(fd);
    }
}

/// Build the kuri.telemetry.v1 JSON body the ingest endpoint expects. `wal` is
/// newline-delimited, each line already a complete logRecord object, so we join
/// lines with commas and wrap them in the resource/scope/session envelope.
fn buildPayload(self: *Telemetry, allocator: std.mem.Allocator, wal: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"schema_version\":\"kuri.telemetry.v1\",\"resource\":{\"service.name\":\"kuri\",\"service.version\":\"");
    try out.appendSlice(allocator, VERSION);
    try out.appendSlice(allocator, "\",\"service.instance.id\":\"");
    try out.appendSlice(allocator, self.instanceId());
    try out.appendSlice(allocator, "\",\"telemetry.sdk.language\":\"zig\",\"telemetry.sdk.name\":\"kuri\",\"telemetry.sdk.version\":\"");
    try out.appendSlice(allocator, VERSION);
    try out.appendSlice(allocator, "\"},\"scope\":{\"name\":\"kuri\",\"version\":\"");
    try out.appendSlice(allocator, VERSION);
    try out.appendSlice(allocator, "\"},\"session\":{\"id\":\"");
    try out.appendSlice(allocator, self.sessionId());
    try out.appendSlice(allocator, "\"},\"logRecords\":[");

    var first = true;
    var it = std.mem.splitScalar(u8, wal, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.appendSlice(allocator, trimmed);
    }

    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn syncThreadFn(self: *Telemetry) void {
    const tick_ms: u64 = 100;
    const ticks_per_interval: u64 = self.sync_interval_seconds * 1000 / tick_ms;
    while (!self.should_stop.load(.acquire)) {
        var i: u64 = 0;
        while (i < ticks_per_interval) : (i += 1) {
            if (self.should_stop.load(.acquire)) return;
            compat.threadSleep(tick_ms * std.time.ns_per_ms);
        }
        if (self.should_stop.load(.acquire)) return;
        flush(self);
        syncToCloud(self);
    }
}

// --- Tests ---

test "init honors --no-telemetry (disabled flag)" {
    init(std.testing.allocator, true);
    try std.testing.expect(!g_telem.enabled);
}

test "disabled telemetry record is a no-op" {
    init(std.testing.allocator, true);
    recordSessionStart();
    recordRequest("/navigate", "GET", 200, 123, 456, false);
    try std.testing.expectEqual(@as(u32, 0), g_telem.head.load(.monotonic));
}

test "formatLogRecord emits kuri.telemetry.v1 logRecord for a request" {
    var t = Telemetry{};
    var ev = Event{ .kind = .http_request, .time_ns = 1, .status = 200, .latency_ns = 99, .bytes = 12 };
    @memcpy(ev.route[0..9], "/navigate");
    ev.route_len = 9;
    @memcpy(ev.method[0..3], "GET");
    ev.method_len = 3;
    const len = try formatLogRecord(&t, &ev);
    const s = t.fmt_buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, s, "\"body\":\"kuri.http.request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"http.route\":\"/navigate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"http.response.status_code\":200") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"error\":false") != null);
    try std.testing.expect(s[s.len - 1] == '\n');
}

test "buildPayload wraps wal lines in kuri.telemetry.v1 envelope" {
    var t = Telemetry{};
    @memcpy(t.instance_id[0..4], "inst");
    t.instance_id_len = 4;
    @memcpy(t.session_id[0..4], "sess");
    t.session_id_len = 4;
    const wal = "{\"a\":1}\n{\"a\":2}\n";
    const body = try buildPayload(&t, std.testing.allocator, wal);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.startsWith(u8, body, "{\"schema_version\":\"kuri.telemetry.v1\""));
    try std.testing.expect(std.mem.endsWith(u8, body, "]}"));
    try std.testing.expect(std.mem.indexOf(u8, body, "\"logRecords\":[{\"a\":1},{\"a\":2}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"service.instance.id\":\"inst\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"session\":{\"id\":\"sess\"}") != null);
}
