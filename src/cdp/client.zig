const std = @import("std");
const protocol = @import("protocol.zig");
const WebSocketClient = @import("websocket.zig").WebSocketClient;
const compat = @import("../compat.zig");
const jsonscan = @import("jsonscan.zig");

pub const EventBuffer = struct {
    const BufferedEvent = struct {
        data: []const u8,
        owner: std.mem.Allocator,
    };

    items: std.ArrayListUnmanaged(BufferedEvent),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EventBuffer {
        return .{
            .items = .empty,
            .allocator = allocator,
        };
    }

    pub fn len(self: *const EventBuffer) usize {
        return self.items.items.len;
    }

    pub fn push(self: *EventBuffer, owner: std.mem.Allocator, event: []const u8) void {
        if (self.items.items.len >= 256) {
            // Drop oldest event — free its data before removing
            const oldest = self.items.orderedRemove(0);
            oldest.owner.free(oldest.data);
        }
        // Dupe event data into our persistent allocator so it survives arena resets
        const duped = self.allocator.dupe(u8, event) catch {
            return;
        };
        // Free the original from the caller's arena
        owner.free(event);
        self.items.append(self.allocator, .{ .data = duped, .owner = self.allocator }) catch {
            self.allocator.free(duped);
        };
    }

    /// Check if any buffered event matches a CDP method name exactly.
    pub fn hasEvent(self: *EventBuffer, method: []const u8) bool {
        for (self.items.items) |item| {
            if (eventMatchesMethod(item.data, method)) return true;
        }
        return false;
    }

    /// Consume the oldest buffered event matching a CDP method name exactly.
    pub fn consumeEvent(self: *EventBuffer, method: []const u8) bool {
        for (self.items.items, 0..) |item, i| {
            if (!eventMatchesMethod(item.data, method)) continue;

            const matched = self.items.orderedRemove(i);
            matched.owner.free(matched.data);
            return true;
        }
        return false;
    }

    /// Drain all events, freeing memory.
    pub fn drain(self: *EventBuffer) void {
        for (self.items.items) |item| {
            item.owner.free(item.data);
        }
        self.items.clearRetainingCapacity();
    }

    pub fn drainTo(self: *EventBuffer, allocator: std.mem.Allocator) ![]BufferedEvent {
        const out = try allocator.dupe(BufferedEvent, self.items.items);
        self.items.clearRetainingCapacity();
        return out;
    }

    pub fn deinit(self: *EventBuffer) void {
        self.drain();
        self.items.deinit(self.allocator);
    }
};

/// A fixed-capacity ring that remembers the command IDs of CDP messages we
/// injected ourselves from inside the read loop (Fetch.continueRequest /
/// Fetch.fulfillRequest / Fetch.failRequest / Page.handleJavaScriptDialog).
/// Their acks must be dropped when observed, not buffered as junk events —
/// no caller ever sent them and no caller is waiting for them.
///
/// 32 is enough because acks for injected commands only need to be tracked
/// for the window between "we write the reply" and "we observe its ack in
/// the same thread's read loop" — nothing else ever reads this socket
/// concurrently (the owning mutex is held for the whole loop), so acks
/// return in near-FIFO order within the next 1-2 reads. On overflow the
/// oldest tracked id is dropped; if Chrome's ack for it arrives later it
/// falls through as one harmless buffered junk event that ages out of
/// EventBuffer's 256-cap ring — never a hang or a misapplied reply.
pub const InjectedIds = struct {
    const CAP = 32;
    ids: [CAP]u32 = @splat(0),
    head: usize = 0,
    len: usize = 0,

    pub fn remember(self: *InjectedIds, id: u32) void {
        const idx = (self.head + self.len) % CAP;
        self.ids[idx] = id;
        if (self.len < CAP) {
            self.len += 1;
        } else {
            self.head = (self.head + 1) % CAP;
        }
    }

    /// If `msg` is a response ack for one of our tracked ids, remove it from
    /// the ring and return true.
    pub fn consumeIfMatch(self: *InjectedIds, msg: []const u8) bool {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const idx = (self.head + i) % CAP;
            if (CdpClient.matchesResponseId(msg, self.ids[idx])) {
                // Shift everything after idx back by one to close the gap,
                // preserving relative order of the remaining tracked ids.
                var j = idx;
                while (j != (self.head + self.len - 1) % CAP) {
                    const nxt = (j + 1) % CAP;
                    self.ids[j] = self.ids[nxt];
                    j = nxt;
                }
                self.len -= 1;
                return true;
            }
        }
        return false;
    }
};

/// One CDP Fetch-interception rule. Rules are matched in order; the first
/// whose `url_substring` is contained in the paused request's URL wins
/// ("" matches everything, so an empty-substring rule is a catch-all).
pub const InterceptRule = struct {
    url_substring: []const u8, // owned dupe; "" == matches everything
    action: Action,
    status: u16 = 200, // fulfill only
    body: []const u8 = "", // fulfill only — raw bytes (base64'd at send time)
    content_type: []const u8 = "application/json",
    error_reason: []const u8 = "Failed", // abort only — a Network.ErrorReason string

    pub const Action = enum { @"continue", abort, fulfill };
};

/// Bookkeeping record for one Fetch.requestPaused event we auto-answered.
pub const PausedRequestRecord = struct {
    request_id: []const u8, // owned dupe (CdpClient.allocator)
    url: []const u8,
    method: []const u8,
    resource_type: []const u8,
    action_taken: InterceptRule.Action,
    status: u16, // 0 for continue/abort
    timestamp: i64,
};

/// Bounded ring (fixed array, not ArrayListUnmanaged — the record shape and
/// cap are fixed by spec) of the last ~200 paused requests we answered.
pub const RequestRing = struct {
    const CAP = 200;
    allocator: std.mem.Allocator,
    items: [CAP]?PausedRequestRecord = @splat(null),
    next: usize = 0,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) RequestRing {
        return .{ .allocator = allocator };
    }

    fn freeRecord(self: *RequestRing, rec: PausedRequestRecord) void {
        self.allocator.free(rec.request_id);
        self.allocator.free(rec.url);
        self.allocator.free(rec.method);
        self.allocator.free(rec.resource_type);
    }

    pub fn push(self: *RequestRing, rec: PausedRequestRecord) void {
        if (self.items[self.next]) |old| self.freeRecord(old);
        self.items[self.next] = rec;
        self.next = (self.next + 1) % CAP;
        if (self.count < CAP) self.count += 1;
    }

    /// Number of live records currently held (<= CAP).
    pub fn len(self: *const RequestRing) usize {
        return self.count;
    }

    /// Drop all currently-held records, freeing their owned strings, and
    /// reset the ring to empty. Unlike `deinit`, the ring remains usable
    /// for `push` immediately afterward.
    pub fn clear(self: *RequestRing) void {
        for (self.items) |maybe| {
            if (maybe) |rec| self.freeRecord(rec);
        }
        self.items = @splat(null);
        self.next = 0;
        self.count = 0;
    }

    /// Copy out currently-held records in chronological order (oldest
    /// first). Caller owns the returned slice AND every string inside it
    /// (all duped into `allocator`, exactly like
    /// `CdpClient.snapshotInterceptRules` — pass a per-request arena and
    /// nothing further needs freeing).
    ///
    /// The strings MUST be duped rather than aliased: the ring's own copies
    /// are freed by `push` (rotation) and `clear`, which run on whatever
    /// thread is draining the CDP socket. A caller that held borrowed
    /// slices past the `CdpClient.mu` critical section — e.g. the router
    /// serializing records to JSON — would read freed memory.
    pub fn snapshot(self: *const RequestRing, allocator: std.mem.Allocator) ![]PausedRequestRecord {
        const out = try allocator.alloc(PausedRequestRecord, self.count);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |r| {
                allocator.free(r.request_id);
                allocator.free(r.url);
                allocator.free(r.method);
                allocator.free(r.resource_type);
            }
            allocator.free(out);
        }
        const start = if (self.count < CAP) 0 else self.next;
        for (0..self.count) |i| {
            const rec = self.items[(start + i) % CAP].?;

            const request_id = try allocator.dupe(u8, rec.request_id);
            errdefer allocator.free(request_id);
            const url = try allocator.dupe(u8, rec.url);
            errdefer allocator.free(url);
            const method = try allocator.dupe(u8, rec.method);
            errdefer allocator.free(method);
            const resource_type = try allocator.dupe(u8, rec.resource_type);

            out[filled] = .{
                .request_id = request_id,
                .url = url,
                .method = method,
                .resource_type = resource_type,
                .action_taken = rec.action_taken,
                .status = rec.status,
                .timestamp = rec.timestamp,
            };
            filled += 1;
        }
        return out;
    }

    pub fn deinit(self: *RequestRing) void {
        for (self.items) |maybe| {
            if (maybe) |rec| self.freeRecord(rec);
        }
    }
};

/// Per-tab Fetch-interception state: the rule set plus the paused-request
/// ring. Lives on `CdpClient` exactly like `event_buf` does.
pub const InterceptState = struct {
    allocator: std.mem.Allocator, // == CdpClient.allocator (persistent GPA, NOT a per-call arena)
    rules: std.ArrayListUnmanaged(InterceptRule) = .empty,
    requests: RequestRing,
    active: bool = false, // whether Fetch interception is currently enabled for this tab (set by the router's /intercept/start and /intercept/stop)

    pub fn init(allocator: std.mem.Allocator) InterceptState {
        return .{
            .allocator = allocator,
            .requests = RequestRing.init(allocator),
        };
    }

    /// Append a rule, duping all owned string fields into `self.allocator`.
    pub fn addRule(self: *InterceptState, rule: InterceptRule) !void {
        const owned_url = try self.allocator.dupe(u8, rule.url_substring);
        errdefer self.allocator.free(owned_url);
        const owned_body = try self.allocator.dupe(u8, rule.body);
        errdefer self.allocator.free(owned_body);
        const owned_ct = try self.allocator.dupe(u8, rule.content_type);
        errdefer self.allocator.free(owned_ct);
        const owned_err = try self.allocator.dupe(u8, rule.error_reason);
        errdefer self.allocator.free(owned_err);

        try self.rules.append(self.allocator, .{
            .url_substring = owned_url,
            .action = rule.action,
            .status = rule.status,
            .body = owned_body,
            .content_type = owned_ct,
            .error_reason = owned_err,
        });
    }

    fn freeRule(self: *InterceptState, rule: InterceptRule) void {
        self.allocator.free(rule.url_substring);
        self.allocator.free(rule.body);
        self.allocator.free(rule.content_type);
        self.allocator.free(rule.error_reason);
    }

    pub fn clearRules(self: *InterceptState) void {
        for (self.rules.items) |rule| self.freeRule(rule);
        self.rules.clearRetainingCapacity();
    }

    /// Find the first rule whose `url_substring` is contained in `url`.
    /// Returns null when no rule matches — callers MUST treat null as
    /// "continue unmodified", never as "no response needed": that is
    /// exactly the deadlock this whole design exists to prevent.
    pub fn findMatch(self: *const InterceptState, url: []const u8) ?*const InterceptRule {
        for (self.rules.items) |*r| {
            if (r.url_substring.len == 0 or std.mem.indexOf(u8, url, r.url_substring) != null) return r;
        }
        return null;
    }

    pub fn deinit(self: *InterceptState) void {
        self.clearRules();
        self.rules.deinit(self.allocator);
        self.requests.deinit();
    }
};

/// Per-tab Page.javascriptDialogOpening auto-responder state. Disabled
/// (`enabled = false`) by default: unlike Fetch.requestPaused, a paused
/// dialog does not by itself justify always auto-answering — the router
/// already exposes a manual dialog-respond flow, and this must not race it.
pub const DialogAutoState = struct {
    enabled: bool = false,
    accept: bool = true,
    prompt_text: []const u8 = "", // owned dupe when non-empty; freed/replaced by `set`

    /// Update the auto-answer config, freeing the previous prompt_text.
    pub fn set(self: *DialogAutoState, allocator: std.mem.Allocator, enabled: bool, accept: bool, prompt_text: []const u8) !void {
        const owned = try allocator.dupe(u8, prompt_text);
        if (self.prompt_text.len > 0) allocator.free(self.prompt_text);
        self.prompt_text = owned;
        self.enabled = enabled;
        self.accept = accept;
    }

    pub fn deinit(self: *DialogAutoState, allocator: std.mem.Allocator) void {
        if (self.prompt_text.len > 0) allocator.free(self.prompt_text);
        self.prompt_text = "";
    }
};

/// One captured `Page.screencastFrame` event. Frame bytes vary wildly in
/// size (a single JPEG frame can be a few KB or several MB depending on
/// page content/quality), so unlike the fixed-shape rings below this is
/// held in a growable list with a running byte counter — see
/// `ScreencastRing` for why.
pub const ScreencastFrameRecord = struct {
    data_b64: []const u8, // owned dupe — base64 image bytes, exactly as Chrome sent them
    timestamp: f64, // metadata.timestamp, Chrome's clock
    device_width: u32,
    device_height: u32,
    session_id: i64, // the sessionId this frame was acked with
};

/// Bounded by BOTH frame count and total bytes. Deliberately NOT a fixed
/// `[CAP]?T` array like `RequestRing`: frame payloads vary from a few KB
/// to multiple MB, so admitting one large frame can require evicting
/// *several* old small frames to stay under the byte cap — a fixed array
/// evicts exactly one slot per push and can't express that. This is the
/// one collector ring in this file that deliberately diverges from
/// `RequestRing`'s shape; every other ring below keeps that shape.
pub const ScreencastRing = struct {
    pub const MAX_COUNT = 30;
    pub const MAX_BYTES = 32 * 1024 * 1024; // 32 MiB total, across all held frames' data_b64

    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(ScreencastFrameRecord) = .empty,
    total_bytes: usize = 0,
    dropped_oversize: usize = 0, // frames that alone exceeded MAX_BYTES and were rejected outright (never inserted) — exposed via CdpClient.droppedScreencastFrameCount rather than silently discarded

    pub fn init(allocator: std.mem.Allocator) ScreencastRing {
        return .{ .allocator = allocator };
    }

    fn freeRecord(self: *ScreencastRing, rec: ScreencastFrameRecord) void {
        self.allocator.free(rec.data_b64);
    }

    /// Takes ownership of `rec.data_b64` (an `self.allocator` dupe already
    /// made by the caller): stores it, evicting the oldest frames first
    /// until both caps are satisfied, OR frees it and counts it as dropped
    /// if it alone would exceed `MAX_BYTES` — this never evicts every held
    /// frame just to make room for one outlier.
    pub fn push(self: *ScreencastRing, rec: ScreencastFrameRecord) void {
        if (rec.data_b64.len > MAX_BYTES) {
            std.log.warn("cdp collector: dropping oversize screencast frame ({d} bytes > {d} cap)", .{ rec.data_b64.len, MAX_BYTES });
            self.dropped_oversize += 1;
            self.freeRecord(rec);
            return;
        }
        while (self.items.items.len > 0 and (self.items.items.len >= MAX_COUNT or self.total_bytes + rec.data_b64.len > MAX_BYTES)) {
            const evicted = self.items.orderedRemove(0);
            self.total_bytes -= evicted.data_b64.len;
            self.freeRecord(evicted);
        }
        self.items.append(self.allocator, rec) catch {
            self.freeRecord(rec);
            return;
        };
        self.total_bytes += rec.data_b64.len;
    }

    pub fn len(self: *const ScreencastRing) usize {
        return self.items.items.len;
    }

    pub fn clear(self: *ScreencastRing) void {
        for (self.items.items) |rec| self.freeRecord(rec);
        self.items.clearRetainingCapacity();
        self.total_bytes = 0;
    }

    /// Copy out held frames, oldest first, every `data_b64` duped into
    /// `allocator` — same dupe-on-snapshot contract as
    /// `RequestRing.snapshot` (see its doc comment): the ring's own copies
    /// are freed by `push` (eviction) and `clear`, which run on whatever
    /// thread is draining the CDP socket, so a caller must never alias
    /// past `CdpClient.mu`.
    pub fn snapshot(self: *const ScreencastRing, allocator: std.mem.Allocator) ![]ScreencastFrameRecord {
        const out = try allocator.alloc(ScreencastFrameRecord, self.items.items.len);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |r| allocator.free(r.data_b64);
            allocator.free(out);
        }
        for (self.items.items, 0..) |rec, i| {
            out[i] = .{
                .data_b64 = try allocator.dupe(u8, rec.data_b64),
                .timestamp = rec.timestamp,
                .device_width = rec.device_width,
                .device_height = rec.device_height,
                .session_id = rec.session_id,
            };
            filled += 1;
        }
        return out;
    }

    /// The single most recent frame, if any. Same dupe contract as `snapshot`.
    pub fn latest(self: *const ScreencastRing, allocator: std.mem.Allocator) !?ScreencastFrameRecord {
        if (self.items.items.len == 0) return null;
        const rec = self.items.items[self.items.items.len - 1];
        return .{
            .data_b64 = try allocator.dupe(u8, rec.data_b64),
            .timestamp = rec.timestamp,
            .device_width = rec.device_width,
            .device_height = rec.device_height,
            .session_id = rec.session_id,
        };
    }

    pub fn deinit(self: *ScreencastRing) void {
        for (self.items.items) |rec| self.freeRecord(rec);
        self.items.deinit(self.allocator);
    }
};

/// One captured `Runtime.bindingCalled` event (a page calling a function
/// exposed via `window.<name>` / `Runtime.addBinding`, e.g. `/expose`).
pub const BindingCallRecord = struct {
    pub const MAX_NAME = 256; // binding names are short JS identifiers we ourselves registered; capped defensively anyway
    pub const MAX_PAYLOAD = 64 * 1024; // 64 KiB — payloads are page-supplied strings and can be arbitrarily large

    name: []const u8, // owned dupe, truncated to MAX_NAME
    payload: []const u8, // owned dupe, truncated to MAX_PAYLOAD
    truncated: bool, // true if payload was cut to MAX_PAYLOAD (name truncation is not separately flagged: names this short are never attacker-controlled in practice)
    timestamp: i64,
};

/// Fixed-capacity ring, same shape as `RequestRing`: bounded by both a
/// fixed slot count AND a fixed per-record byte cap, so total memory is
/// bounded (CAP * (MAX_NAME + MAX_PAYLOAD)) even without a running byte
/// counter like `ScreencastRing` needs.
pub const BindingCallRing = struct {
    pub const CAP = 200;

    allocator: std.mem.Allocator,
    items: [CAP]?BindingCallRecord = @splat(null),
    next: usize = 0,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) BindingCallRing {
        return .{ .allocator = allocator };
    }

    fn freeRecord(self: *BindingCallRing, rec: BindingCallRecord) void {
        self.allocator.free(rec.name);
        self.allocator.free(rec.payload);
    }

    pub fn push(self: *BindingCallRing, rec: BindingCallRecord) void {
        if (self.items[self.next]) |old| self.freeRecord(old);
        self.items[self.next] = rec;
        self.next = (self.next + 1) % CAP;
        if (self.count < CAP) self.count += 1;
    }

    pub fn len(self: *const BindingCallRing) usize {
        return self.count;
    }

    pub fn clear(self: *BindingCallRing) void {
        for (self.items) |maybe| if (maybe) |rec| self.freeRecord(rec);
        self.items = @splat(null);
        self.next = 0;
        self.count = 0;
    }

    /// Dupe-on-snapshot, same contract as `RequestRing.snapshot`.
    pub fn snapshot(self: *const BindingCallRing, allocator: std.mem.Allocator) ![]BindingCallRecord {
        const out = try allocator.alloc(BindingCallRecord, self.count);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |r| {
                allocator.free(r.name);
                allocator.free(r.payload);
            }
            allocator.free(out);
        }
        const start = if (self.count < CAP) 0 else self.next;
        for (0..self.count) |i| {
            const rec = self.items[(start + i) % CAP].?;
            const name = try allocator.dupe(u8, rec.name);
            errdefer allocator.free(name);
            const payload = try allocator.dupe(u8, rec.payload);
            out[filled] = .{ .name = name, .payload = payload, .truncated = rec.truncated, .timestamp = rec.timestamp };
            filled += 1;
        }
        return out;
    }

    pub fn deinit(self: *BindingCallRing) void {
        for (self.items) |maybe| if (maybe) |rec| self.freeRecord(rec);
    }
};

/// One `Network.requestWillBeSent`/`responseReceived` pair, tracked
/// *alongside* (never instead of) `HarRecorder`'s own consumption of the
/// same events — see `collectNetworkRequestWillBeSent`/`ResponseReceived`,
/// which always return `false` from `collect` so the event still reaches
/// `event_buf` for `flushEventsToHar`. This ring exists only so
/// `findNetworkRequestByUrl` can hand `/response/body` a real `requestId`.
pub const NetworkRecord = struct {
    pub const MAX_URL = 8 * 1024; // 8 KiB — generous for real URLs; bounds a pathological data:/blob: URL

    request_id: []const u8, // owned dupe
    url: []const u8, // owned dupe, truncated to MAX_URL
    url_truncated: bool,
    method: []const u8, // owned dupe
    mime_type: []const u8, // owned dupe when non-empty; "" (not allocator-owned) until responseReceived fills it in
    timestamp: i64,
};

/// Fixed-capacity ring, same shape and cap as `RequestRing`. Never holds a
/// response body — bodies are fetched on demand via `Network.getResponseBody`
/// using the `requestId` this ring hands back.
pub const NetworkRing = struct {
    pub const CAP = 200;

    allocator: std.mem.Allocator,
    items: [CAP]?NetworkRecord = @splat(null),
    next: usize = 0,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) NetworkRing {
        return .{ .allocator = allocator };
    }

    fn freeRecord(self: *NetworkRing, rec: NetworkRecord) void {
        self.allocator.free(rec.request_id);
        self.allocator.free(rec.url);
        self.allocator.free(rec.method);
        if (rec.mime_type.len > 0) self.allocator.free(rec.mime_type);
    }

    pub fn push(self: *NetworkRing, rec: NetworkRecord) void {
        if (self.items[self.next]) |old| self.freeRecord(old);
        self.items[self.next] = rec;
        self.next = (self.next + 1) % CAP;
        if (self.count < CAP) self.count += 1;
    }

    pub fn len(self: *const NetworkRing) usize {
        return self.count;
    }

    /// Attach a mime type to the record matching `request_id`, freeing any
    /// previous one. Takes ownership of `owned_mime` only when a match is
    /// found (return true); the caller must free it themselves on `false`
    /// (request already evicted from the 200-record ring).
    pub fn updateMimeType(self: *NetworkRing, request_id: []const u8, owned_mime: []const u8) bool {
        var i: usize = 0;
        while (i < CAP) : (i += 1) {
            if (self.items[i]) |rec| {
                if (std.mem.eql(u8, rec.request_id, request_id)) {
                    if (rec.mime_type.len > 0) self.allocator.free(rec.mime_type);
                    self.items[i].?.mime_type = owned_mime;
                    return true;
                }
            }
        }
        return false;
    }

    pub fn clear(self: *NetworkRing) void {
        for (self.items) |maybe| if (maybe) |rec| self.freeRecord(rec);
        self.items = @splat(null);
        self.next = 0;
        self.count = 0;
    }

    fn dupeRecord(allocator: std.mem.Allocator, rec: NetworkRecord) !NetworkRecord {
        const request_id = try allocator.dupe(u8, rec.request_id);
        errdefer allocator.free(request_id);
        const url = try allocator.dupe(u8, rec.url);
        errdefer allocator.free(url);
        const method = try allocator.dupe(u8, rec.method);
        errdefer allocator.free(method);
        const mime_type = if (rec.mime_type.len > 0) try allocator.dupe(u8, rec.mime_type) else "";
        return .{
            .request_id = request_id,
            .url = url,
            .url_truncated = rec.url_truncated,
            .method = method,
            .mime_type = mime_type,
            .timestamp = rec.timestamp,
        };
    }

    /// Dupe-on-snapshot, same contract as `RequestRing.snapshot`.
    pub fn snapshot(self: *const NetworkRing, allocator: std.mem.Allocator) ![]NetworkRecord {
        const out = try allocator.alloc(NetworkRecord, self.count);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |r| {
                allocator.free(r.request_id);
                allocator.free(r.url);
                allocator.free(r.method);
                if (r.mime_type.len > 0) allocator.free(r.mime_type);
            }
            allocator.free(out);
        }
        const start = if (self.count < CAP) 0 else self.next;
        for (0..self.count) |i| {
            const rec = self.items[(start + i) % CAP].?;
            out[filled] = try dupeRecord(allocator, rec);
            filled += 1;
        }
        return out;
    }

    /// Last-match-wins scan (oldest to newest) for the most recent request
    /// whose URL contains `url_substring`. Result duped independent of ring
    /// storage, same contract as `snapshot`.
    pub fn findByUrlSubstring(self: *const NetworkRing, allocator: std.mem.Allocator, url_substring: []const u8) !?NetworkRecord {
        const start = if (self.count < CAP) 0 else self.next;
        var found: ?NetworkRecord = null;
        for (0..self.count) |i| {
            const rec = self.items[(start + i) % CAP].?;
            if (std.mem.indexOf(u8, rec.url, url_substring) != null) found = rec;
        }
        const rec = found orelse return null;
        return try dupeRecord(allocator, rec);
    }

    pub fn deinit(self: *NetworkRing) void {
        for (self.items) |maybe| if (maybe) |rec| self.freeRecord(rec);
    }
};

/// The one-shot IO stream handle from a `Tracing.tracingComplete` event
/// (only populated when `Tracing.start` was called with
/// `"transferMode":"ReturnAsStream"` — see `CdpClient.takeTraceStream`'s
/// doc comment). Never holds trace bytes themselves: a full trace can be
/// tens of MB, and the whole point of ReturnAsStream is to keep it out of
/// this process's memory until a caller explicitly drains it via `IO.read`.
pub const TraceStreamRecord = struct {
    stream_handle: []const u8, // owned dupe
    data_loss: bool,
    trace_format: []const u8, // owned dupe when non-empty; "" if the event didn't include one
};

/// Singleton — only one trace can be active per tab, so there is nothing
/// to bound beyond "one record, replaced wholesale on the next
/// `tracingComplete`".
pub const TraceStreamState = struct {
    allocator: std.mem.Allocator,
    current: ?TraceStreamRecord = null,

    pub fn init(allocator: std.mem.Allocator) TraceStreamState {
        return .{ .allocator = allocator };
    }

    fn freeRecord(self: *TraceStreamState, rec: TraceStreamRecord) void {
        self.allocator.free(rec.stream_handle);
        if (rec.trace_format.len > 0) self.allocator.free(rec.trace_format);
    }

    /// Replace any previously-recorded (and presumably already-consumed or
    /// abandoned) stream handle with a new one.
    pub fn set(self: *TraceStreamState, rec: TraceStreamRecord) void {
        if (self.current) |old| self.freeRecord(old);
        self.current = rec;
    }

    /// Destructive read: dupes the current record into `allocator` then
    /// clears `self.current`, unlike every other collector accessor in
    /// this file (all of which are non-destructive peeks). This is
    /// intentional, not an oversight — see `CdpClient.takeTraceStream`'s
    /// doc comment for why a stream handle can't be safely re-peeked.
    pub fn take(self: *TraceStreamState, allocator: std.mem.Allocator) !?TraceStreamRecord {
        const cur = self.current orelse return null;
        const stream_handle = try allocator.dupe(u8, cur.stream_handle);
        errdefer allocator.free(stream_handle);
        const trace_format = if (cur.trace_format.len > 0) try allocator.dupe(u8, cur.trace_format) else "";
        self.freeRecord(cur);
        self.current = null;
        return .{ .stream_handle = stream_handle, .data_loss = cur.data_loss, .trace_format = trace_format };
    }

    pub fn deinit(self: *TraceStreamState) void {
        if (self.current) |cur| self.freeRecord(cur);
    }
};

/// Bag of every passive CDP-event collector's state, lives on `CdpClient`
/// exactly like `intercept`/`dialog_auto` do (same persistent-allocator
/// rule: `allocator` here is always `CdpClient.allocator`, the process's
/// GPA, never a per-HTTP-request arena — see `InterceptState`'s doc
/// comment, which states the same invariant).
pub const CollectorState = struct {
    allocator: std.mem.Allocator,
    screencast: ScreencastRing,
    bindings: BindingCallRing,
    network: NetworkRing,
    tracing: TraceStreamState,

    pub fn init(allocator: std.mem.Allocator) CollectorState {
        return .{
            .allocator = allocator,
            .screencast = ScreencastRing.init(allocator),
            .bindings = BindingCallRing.init(allocator),
            .network = NetworkRing.init(allocator),
            .tracing = TraceStreamState.init(allocator),
        };
    }

    pub fn deinit(self: *CollectorState) void {
        self.screencast.deinit();
        self.bindings.deinit();
        self.network.deinit();
        self.tracing.deinit();
    }
};

/// 🧁 she's not just a bro, not just a baddie — she's a browdie.
/// CDP WebSocket client that talks to Chrome DevTools Protocol.
pub const CdpClient = struct {
    allocator: std.mem.Allocator,
    cdp_url: []const u8,
    next_id: std.atomic.Value(u32),
    ws: ?WebSocketClient,
    connected: bool,
    dead: bool,
    mu: compat.PthreadMutex,

    // Owned read buffer for WebSocket I/O. Only ever needed for the one-shot
    // HTTP upgrade response in the handshake and RFC 6455 control-frame
    // (ping/pong) scratch space, both capped well under this size -- actual
    // message bodies go through `receiveMessageAlloc`, which allocates its
    // own buffer and never touches this one. 16KiB replaces a previous
    // 512KiB allocation that was ~97% headroom nothing in the codebase
    // could reach (see perf task notes). `ws_write_buf` used to live here
    // too but had zero readers anywhere -- removed as dead storage.
    ws_read_buf: [16 * 1024]u8,

    event_buf: EventBuffer,
    injected_ids: InjectedIds,
    intercept: InterceptState,
    dialog_auto: DialogAutoState,
    collectors: CollectorState,

    pub fn init(allocator: std.mem.Allocator, cdp_url: []const u8) CdpClient {
        return .{
            .allocator = allocator,
            .cdp_url = cdp_url,
            .next_id = std.atomic.Value(u32).init(1),
            .ws = null,
            .connected = false,
            .dead = false,
            .mu = .{},
            .ws_read_buf = undefined,
            .event_buf = EventBuffer.init(allocator),
            .injected_ids = .{},
            .intercept = InterceptState.init(allocator),
            .dialog_auto = .{},
            .collectors = CollectorState.init(allocator),
        };
    }

    pub fn nextId(self: *CdpClient) u32 {
        return self.next_id.fetchAdd(1, .monotonic);
    }

    /// Connect to Chrome CDP WebSocket endpoint.
    pub fn connectWs(self: *CdpClient) !void {
        if (self.connected) return;
        // Close stale WebSocket if present
        if (self.ws) |*old_ws| {
            old_ws.close();
            self.ws = null;
        }
        self.ws = WebSocketClient.connect(
            self.allocator,
            self.cdp_url,
            &self.ws_read_buf,
        ) catch return error.ConnectionRefused;
        self.connected = true;
    }

    /// Send a CDP command and receive the response. Allocates result.
    /// Send a CDP command and receive the matching response. Allocates result.
    /// Skips CDP events (messages without matching id) and correlates by command ID.
    pub fn send(self: *CdpClient, allocator: std.mem.Allocator, method: []const u8, params_json: ?[]const u8) ![]const u8 {
        self.mu.lock();
        defer self.mu.unlock();

        if (!self.connected) try self.connectWs();

        var ws = &(self.ws orelse return error.ConnectionRefused);

        const sent_id = self.nextId();
        const msg = try self.buildMessageWithId(allocator, sent_id, method, params_json);
        defer allocator.free(msg);

        ws.sendText(msg) catch {
            // Connection broke — mark dead so the caller can invalidate this client
            self.connected = false;
            self.dead = true;
            return error.ConnectionRefused;
        };

        // Read responses, buffer events, max 500 attempts
        // Heavy SPAs (Shopee, SIA) flood hundreds of CDP events during page load
        var attempts: u32 = 0;
        while (attempts < 500) : (attempts += 1) {
            const response = ws.receiveMessageAlloc(allocator, 2 * 1024 * 1024) catch |err| switch (err) {
                error.ConnectionClosed => {
                    self.connected = false;
                    self.dead = true;
                    return error.ConnectionRefused;
                },
                else => {
                    // Timeout or read error — if we've read some events, retry a few more times
                    if (attempts > 0) continue;
                    self.connected = false;
                    self.dead = true;
                    return error.ConnectionRefused;
                },
            };

            if (matchesResponseId(response, sent_id)) {
                return response;
            }

            // Not our response — handle it inline (drop injected-command ack,
            // auto-answer Fetch.requestPaused/dialog) or buffer it as an event.
            self.handleOrBuffer(allocator, response, ws);
        }

        return error.ConnectionRefused;
    }

    /// Check if a JSON response contains "id":N matching our sent command ID.
    pub fn matchesResponseId(json: []const u8, expected_id: u32) bool {
        // Look for "id": pattern near the start of the message
        const id_pos = std.mem.indexOf(u8, json, "\"id\"") orelse return false;
        // Only check first 50 chars — CDP response "id" is always near the top
        if (id_pos > 50) return false;
        const colon = std.mem.indexOfScalarPos(u8, json, id_pos + 3, ':') orelse return false;
        // Skip whitespace after colon
        var i = colon + 1;
        while (i < json.len and json[i] == ' ') : (i += 1) {}
        // Parse the number
        var end = i;
        while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
        if (end == i) return false;
        const parsed_id = std.fmt.parseInt(u32, json[i..end], 10) catch return false;
        return parsed_id == expected_id;
    }

    /// Build a JSON-RPC message for a CDP command with an explicit ID.
    pub fn buildMessageWithId(_: *CdpClient, allocator: std.mem.Allocator, id: u32, method: []const u8, params_json: ?[]const u8) ![]const u8 {
        if (params_json) |p| {
            return std.fmt.allocPrint(allocator, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, p });
        } else {
            return std.fmt.allocPrint(allocator, "{{\"id\":{d},\"method\":\"{s}\"}}", .{ id, method });
        }
    }

    /// Build a JSON-RPC message for a CDP command (auto-assigns next ID).
    pub fn buildMessage(self: *CdpClient, allocator: std.mem.Allocator, method: []const u8, params_json: ?[]const u8) ![]const u8 {
        return self.buildMessageWithId(allocator, self.nextId(), method, params_json);
    }

    pub fn disconnect(self: *CdpClient) void {
        if (self.ws) |*ws| {
            ws.close();
            self.ws = null;
        }
        self.connected = false;
    }

    /// Wait for a specific CDP event by polling buffered events and reading new ones.
    /// Returns true if the event was seen within max_attempts reads.
    ///
    /// The exact message that satisfies the wait is ALSO run through `collect`
    /// (the same passive-collector dispatch `handleOrBuffer` uses for every
    /// other message) before being discarded -- otherwise a collector whose
    /// only source event happens to be the thing someone is waiting for (e.g.
    /// `collectTracingComplete`, awaited directly by /trace/stop) would never
    /// fire: its event would be freed raw right here instead. `collect` never
    /// frees `response` itself (same contract `handleOrBuffer` relies on), so
    /// `response` is still unconditionally freed afterward, preserving this
    /// fast path's original behavior for methods `collect` doesn't know about
    /// (Page.loadEventFired, Page.downloadWillBegin, ...).
    pub fn waitForEvent(self: *CdpClient, allocator: std.mem.Allocator, method: []const u8, max_attempts: u32) bool {
        self.mu.lock();
        defer self.mu.unlock();

        // Consume a buffered match so the same event can't satisfy later waits.
        if (self.event_buf.consumeEvent(method)) return true;

        var ws = &(self.ws orelse return false);
        var attempts: u32 = 0;
        while (attempts < max_attempts) : (attempts += 1) {
            const response = ws.receiveMessageAlloc(allocator, 2 * 1024 * 1024) catch return false;
            if (eventMatchesMethod(response, method)) {
                _ = self.collect(allocator, response, ws);
                allocator.free(response);
                return true;
            }
            self.handleOrBuffer(allocator, response, ws);
        }
        return false;
    }

    pub fn drainWsEvents(self: *CdpClient, allocator: std.mem.Allocator, timeout_sec: i32) void {
        if (@import("builtin").os.tag == .windows) return;
        self.mu.lock();
        defer self.mu.unlock();

        var ws = &(self.ws orelse return);
        const drain_timeout = std.posix.timeval{ .sec = timeout_sec, .usec = 0 };
        const orig_timeout = std.posix.timeval{ .sec = 10, .usec = 0 };
        std.posix.setsockopt(ws.fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&drain_timeout)) catch {};
        defer std.posix.setsockopt(ws.fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&orig_timeout)) catch {};

        var drained: u32 = 0;
        while (drained < 2000) : (drained += 1) {
            const msg = ws.receiveMessageAlloc(allocator, 2 * 1024 * 1024) catch break;
            self.handleOrBuffer(allocator, msg, ws);
        }
    }

    // ── In-read-loop auto-responder ─────────────────────────────────────
    //
    // Called from send()/waitForEvent()/drainWsEvents() — all three already
    // hold self.mu — for every message that did not satisfy the caller's
    // own wait condition. This is the ONLY place matching/replying logic
    // lives; the three call sites each do one thing: hand the message here
    // instead of pushing it straight to event_buf.

    /// Takes ownership of `msg` (allocated with `allocator`): either
    /// consumed here (dropped ack, auto-answered event) or handed to
    /// event_buf.push, which dupes it into self.allocator and frees the
    /// caller's copy — same contract EventBuffer.push already had.
    fn handleOrBuffer(self: *CdpClient, allocator: std.mem.Allocator, msg: []const u8, ws: *WebSocketClient) void {
        // (a) Ack for one of OUR OWN injected auto-reply commands — drop,
        // not a real event for any caller to see.
        if (self.injected_ids.consumeIfMatch(msg)) {
            allocator.free(msg);
            return;
        }

        // (b) Something we auto-answer inline (Fetch.requestPaused / dialog).
        if (self.autoRespond(allocator, msg, ws)) {
            allocator.free(msg);
            return;
        }

        // (b.5) A passive collector fully consumes this one (screencast /
        // bindingCalled / tracingComplete) -- Network.* collectors return
        // false here on purpose so step (c) still runs for them.
        if (self.collect(allocator, msg, ws)) {
            allocator.free(msg);
            return;
        }

        // (c) Ordinary event — existing behavior, unchanged.
        self.event_buf.push(allocator, msg);
    }

    /// Returns true if `msg` was handled (caller should free it, not buffer it).
    fn autoRespond(self: *CdpClient, allocator: std.mem.Allocator, msg: []const u8, ws: *WebSocketClient) bool {
        if (eventMatchesMethod(msg, "Fetch.requestPaused")) {
            return self.autoRespondFetch(allocator, msg, ws);
        }
        if (self.dialog_auto.enabled and eventMatchesMethod(msg, "Page.javascriptDialogOpening")) {
            return self.autoRespondDialog(allocator, ws);
        }
        return false;
    }

    const RequestPausedFields = struct {
        request_id: []const u8,
        url: []const u8,
        method: []const u8,
        resource_type: []const u8,
    };

    fn extractRequestPausedFields(event_json: []const u8) ?RequestPausedFields {
        const request_id = jsonscan.extractField(event_json, "requestId") orelse return null;
        const request_obj = jsonscan.extractObject(event_json, "request") orelse return null;
        const url = jsonscan.extractField(request_obj, "url") orelse return null;
        const method = jsonscan.extractField(request_obj, "method") orelse "GET";
        const resource_type = jsonscan.extractField(event_json, "resourceType") orelse "Other";
        return .{ .request_id = request_id, .url = url, .method = method, .resource_type = resource_type };
    }

    /// Fetch.requestPaused -> match rules -> failRequest | fulfillRequest |
    /// continueRequest, written inline on the already-open `ws`.
    ///
    /// ALWAYS answers — even when no rule matches (continueRequest with no
    /// modifications) — because once Chrome has paused a request on us,
    /// failing to reply hangs the page forever. This is the single most
    /// important correctness property of the whole design, so it is not
    /// gated by any "interception enabled" flag: if we can see the event at
    /// all, Fetch domain is already enabled on the Chrome side, and we must
    /// resolve it.
    fn autoRespondFetch(self: *CdpClient, allocator: std.mem.Allocator, event_json: []const u8, ws: *WebSocketClient) bool {
        const fields = extractRequestPausedFields(event_json) orelse return false;
        const rule = self.intercept.findMatch(fields.url);
        const action: InterceptRule.Action = if (rule) |r| r.action else .@"continue";

        var params: []const u8 = undefined;
        var method: []const u8 = undefined;

        switch (action) {
            .@"continue" => {
                method = protocol.Methods.fetch_continue_request;
                params = std.fmt.allocPrint(allocator, "{{\"requestId\":\"{s}\"}}", .{fields.request_id}) catch return false;
            },
            .abort => {
                method = protocol.Methods.fetch_fail_request;
                const raw_reason = if (rule) |r| r.error_reason else "Failed";
                const reason = jsonscan.escapeJsonAlloc(allocator, raw_reason) catch return false;
                defer allocator.free(reason);
                params = std.fmt.allocPrint(allocator, "{{\"requestId\":\"{s}\",\"errorReason\":\"{s}\"}}", .{ fields.request_id, reason }) catch return false;
            },
            .fulfill => {
                method = protocol.Methods.fetch_fulfill_request;
                const r = rule.?; // action == .fulfill only ever comes from a matched rule
                const enc = std.base64.standard.Encoder;
                const b64_buf = allocator.alloc(u8, enc.calcSize(r.body.len)) catch return false;
                defer allocator.free(b64_buf);
                const b64_body = enc.encode(b64_buf, r.body);
                const content_type = jsonscan.escapeJsonAlloc(allocator, r.content_type) catch return false;
                defer allocator.free(content_type);
                params = std.fmt.allocPrint(
                    allocator,
                    "{{\"requestId\":\"{s}\",\"responseCode\":{d},\"responseHeaders\":[{{\"name\":\"Content-Type\",\"value\":\"{s}\"}}],\"body\":\"{s}\"}}",
                    .{ fields.request_id, r.status, content_type, b64_body },
                ) catch return false;
            },
        }
        defer allocator.free(params);

        const id = self.nextId();
        const cmd = self.buildMessageWithId(allocator, id, method, params) catch return false;
        defer allocator.free(cmd);

        ws.sendText(cmd) catch {
            self.connected = false;
            self.dead = true;
            return false;
        };
        self.injected_ids.remember(id);

        const status: u16 = if (action == .fulfill) rule.?.status else 0;
        self.recordPausedRequest(fields, action, status);

        return true;
    }

    fn recordPausedRequest(self: *CdpClient, fields: RequestPausedFields, action: InterceptRule.Action, status: u16) void {
        const rid = self.allocator.dupe(u8, fields.request_id) catch return;
        const url_dup = self.allocator.dupe(u8, fields.url) catch {
            self.allocator.free(rid);
            return;
        };
        const method_dup = self.allocator.dupe(u8, fields.method) catch {
            self.allocator.free(rid);
            self.allocator.free(url_dup);
            return;
        };
        const rtype_dup = self.allocator.dupe(u8, fields.resource_type) catch {
            self.allocator.free(rid);
            self.allocator.free(url_dup);
            self.allocator.free(method_dup);
            return;
        };

        self.intercept.requests.push(.{
            .request_id = rid,
            .url = url_dup,
            .method = method_dup,
            .resource_type = rtype_dup,
            .action_taken = action,
            .status = status,
            .timestamp = compat.milliTimestamp(),
        });
    }

    /// Page.javascriptDialogOpening -> Page.handleJavaScriptDialog, gated by
    /// `dialog_auto.enabled` (checked by the caller, `autoRespond`).
    ///
    /// Sharper caveat than Fetch: an unanswered dialog suspends all further
    /// JS execution and most CDP traffic on the page, not just one request.
    fn autoRespondDialog(self: *CdpClient, allocator: std.mem.Allocator, ws: *WebSocketClient) bool {
        const prompt_text = jsonscan.escapeJsonAlloc(allocator, self.dialog_auto.prompt_text) catch return false;
        defer allocator.free(prompt_text);

        const params = std.fmt.allocPrint(
            allocator,
            "{{\"accept\":{s},\"promptText\":\"{s}\"}}",
            .{ if (self.dialog_auto.accept) "true" else "false", prompt_text },
        ) catch return false;
        defer allocator.free(params);

        const id = self.nextId();
        const cmd = self.buildMessageWithId(allocator, id, protocol.Methods.page_handle_dialog, params) catch return false;
        defer allocator.free(cmd);

        ws.sendText(cmd) catch {
            self.connected = false;
            self.dead = true;
            return false;
        };
        self.injected_ids.remember(id);
        return true;
    }

    // ── Passive CDP event collectors ─────────────────────────────────────
    //
    // Unlike `autoRespond` above (which answers Chrome inline because an
    // unanswered Fetch/dialog event hangs the page), everything here is
    // read-only bookkeeping: extract a few fields with `jsonscan`, dupe
    // them into `self.collectors`, and either fully consume the event
    // (screencast/bindings/tracing — nothing else in this codebase reads
    // them) or merely observe it (Network.* — `HarRecorder` still needs to
    // see it via `event_buf`, so these always return false here; see
    // `flushEventsToHar` in router.zig, and `har.zig`'s own
    // `handleCdpEvent`, which must keep working unmodified).
    //
    // `collect` is the ONE generic mechanism plugged into `handleOrBuffer`
    // (a single new line there, mirroring the `autoRespond` call above):
    // it extracts the event's "method" field exactly once and scans a
    // small static table, rather than each event type re-scanning the
    // whole message with its own `eventMatchesMethod` call the way
    // `autoRespond` does above (fine for 2 event types, wasteful for the
    // 5 handled here). Per-event-type *behavior* still differs (ack vs.
    // record-only vs. observe-and-forward), which is why each table entry
    // still needs its own handler function — but the registration and
    // routing are singular and data-driven, not five bespoke branches.

    const CollectHandler = *const fn (*CdpClient, std.mem.Allocator, []const u8, *WebSocketClient) bool;
    const CollectEntry = struct { method: []const u8, handler: CollectHandler };

    const collect_table = [_]CollectEntry{
        .{ .method = "Page.screencastFrame", .handler = collectScreencastFrame },
        .{ .method = "Runtime.bindingCalled", .handler = collectBindingCalled },
        .{ .method = "Network.requestWillBeSent", .handler = collectNetworkRequestWillBeSent },
        .{ .method = "Network.responseReceived", .handler = collectNetworkResponseReceived },
        .{ .method = "Tracing.tracingComplete", .handler = collectTracingComplete },
    };

    /// Returns true if `msg` was fully consumed here (caller should free
    /// it, not buffer it) — same "handled means free it" contract as
    /// `autoRespond`.
    fn collect(self: *CdpClient, allocator: std.mem.Allocator, msg: []const u8, ws: *WebSocketClient) bool {
        const method = jsonscan.extractField(msg, "method") orelse return false;
        for (collect_table) |entry| {
            if (std.mem.eql(u8, method, entry.method)) {
                return entry.handler(self, allocator, msg, ws);
            }
        }
        return false;
    }

    /// `Page.screencastFrame` -> ack + record. The ack MUST happen even if
    /// everything after it fails to parse/store: an unacked frame stalls
    /// the whole screencast stream (Chrome won't send the next one until
    /// it's acked), so this always returns true (event fully handled)
    /// once the ack attempt has been made, regardless of storage outcome.
    fn collectScreencastFrame(self: *CdpClient, allocator: std.mem.Allocator, msg: []const u8, ws: *WebSocketClient) bool {
        if (jsonscan.extractField(msg, "sessionId")) |session_id_str| {
            const params = std.fmt.allocPrint(allocator, "{{\"sessionId\":{s}}}", .{session_id_str}) catch return true;
            defer allocator.free(params);
            const id = self.nextId();
            const cmd = self.buildMessageWithId(allocator, id, protocol.Methods.page_screencast_frame_ack, params) catch return true;
            defer allocator.free(cmd);
            ws.sendText(cmd) catch {
                self.connected = false;
                self.dead = true;
                return true; // socket is dead either way; nothing more to do with this event
            };
            self.injected_ids.remember(id);
        }

        const data = jsonscan.extractField(msg, "data") orelse return true;
        const metadata = jsonscan.extractObject(msg, "metadata");
        const timestamp: f64 = blk: {
            const m = metadata orelse break :blk 0;
            const ts = jsonscan.extractField(m, "timestamp") orelse break :blk 0;
            break :blk std.fmt.parseFloat(f64, ts) catch 0;
        };
        const device_width: u32 = blk: {
            const m = metadata orelse break :blk 0;
            const w = jsonscan.extractField(m, "deviceWidth") orelse break :blk 0;
            break :blk std.fmt.parseInt(u32, w, 10) catch 0;
        };
        const device_height: u32 = blk: {
            const m = metadata orelse break :blk 0;
            const h = jsonscan.extractField(m, "deviceHeight") orelse break :blk 0;
            break :blk std.fmt.parseInt(u32, h, 10) catch 0;
        };
        const session_id: i64 = blk: {
            const sid = jsonscan.extractField(msg, "sessionId") orelse break :blk 0;
            break :blk std.fmt.parseInt(i64, sid, 10) catch 0;
        };

        const owned_data = self.allocator.dupe(u8, data) catch return true;
        self.collectors.screencast.push(.{
            .data_b64 = owned_data,
            .timestamp = timestamp,
            .device_width = device_width,
            .device_height = device_height,
            .session_id = session_id,
        });
        return true;
    }

    /// `Runtime.bindingCalled` -> record only. Nothing else in this
    /// codebase consumes this event, so it's always fully handled.
    fn collectBindingCalled(self: *CdpClient, _: std.mem.Allocator, msg: []const u8, _: *WebSocketClient) bool {
        const name = jsonscan.extractField(msg, "name") orelse return true;
        const payload = jsonscan.extractField(msg, "payload") orelse "";

        const name_truncated = name.len > BindingCallRecord.MAX_NAME;
        const capped_name = if (name_truncated) name[0..BindingCallRecord.MAX_NAME] else name;
        const payload_truncated = payload.len > BindingCallRecord.MAX_PAYLOAD;
        const capped_payload = if (payload_truncated) payload[0..BindingCallRecord.MAX_PAYLOAD] else payload;
        if (payload_truncated) {
            std.log.warn("cdp collector: truncating Runtime.bindingCalled payload for \"{s}\" ({d} bytes > {d} cap)", .{ capped_name, payload.len, BindingCallRecord.MAX_PAYLOAD });
        }

        const owned_name = self.allocator.dupe(u8, capped_name) catch return true;
        const owned_payload = self.allocator.dupe(u8, capped_payload) catch {
            self.allocator.free(owned_name);
            return true;
        };
        self.collectors.bindings.push(.{
            .name = owned_name,
            .payload = owned_payload,
            .truncated = payload_truncated,
            .timestamp = compat.milliTimestamp(),
        });
        return true;
    }

    /// `Network.requestWillBeSent` -> record only, then ALWAYS falls
    /// through (returns false) so `event_buf`/`HarRecorder.handleCdpEvent`
    /// still see it — this collector observes, it must never consume
    /// Network events.
    fn collectNetworkRequestWillBeSent(self: *CdpClient, _: std.mem.Allocator, msg: []const u8, _: *WebSocketClient) bool {
        const request_id = jsonscan.extractField(msg, "requestId") orelse return false;
        const request_obj = jsonscan.extractObject(msg, "request") orelse return false;
        const url = jsonscan.extractField(request_obj, "url") orelse return false;
        const method = jsonscan.extractField(request_obj, "method") orelse "GET";

        const url_truncated = url.len > NetworkRecord.MAX_URL;
        const capped_url = if (url_truncated) url[0..NetworkRecord.MAX_URL] else url;
        if (url_truncated) {
            std.log.warn("cdp collector: truncating Network.requestWillBeSent url for requestId \"{s}\" ({d} bytes > {d} cap)", .{ request_id, url.len, NetworkRecord.MAX_URL });
        }

        const owned_id = self.allocator.dupe(u8, request_id) catch return false;
        const owned_url = self.allocator.dupe(u8, capped_url) catch {
            self.allocator.free(owned_id);
            return false;
        };
        const owned_method = self.allocator.dupe(u8, method) catch {
            self.allocator.free(owned_id);
            self.allocator.free(owned_url);
            return false;
        };
        self.collectors.network.push(.{
            .request_id = owned_id,
            .url = owned_url,
            .url_truncated = url_truncated,
            .method = owned_method,
            .mime_type = "",
            .timestamp = compat.milliTimestamp(),
        });
        return false;
    }

    /// `Network.responseReceived` -> attach mimeType to the matching
    /// request record, if it's still held. Always returns false (observe
    /// only) for the same reason as `collectNetworkRequestWillBeSent`.
    fn collectNetworkResponseReceived(self: *CdpClient, _: std.mem.Allocator, msg: []const u8, _: *WebSocketClient) bool {
        const request_id = jsonscan.extractField(msg, "requestId") orelse return false;
        const response_obj = jsonscan.extractObject(msg, "response") orelse return false;
        const mime = jsonscan.extractField(response_obj, "mimeType") orelse return false;

        const owned_mime = self.allocator.dupe(u8, mime) catch return false;
        if (!self.collectors.network.updateMimeType(request_id, owned_mime)) {
            // Request already evicted from the 200-record ring (or never
            // recorded, e.g. observed mid-stream) -- nothing to attach to.
            self.allocator.free(owned_mime);
        }
        return false;
    }

    /// `Tracing.tracingComplete` -> dupe only the (short) stream handle;
    /// never the trace bytes themselves -- see `TraceStreamRecord`'s doc
    /// comment. Always fully consumed: nothing else in this codebase
    /// reads this event, and even a missing `stream` field (Tracing.start
    /// wasn't called with `transferMode: ReturnAsStream`) leaves nothing
    /// useful to forward.
    fn collectTracingComplete(self: *CdpClient, _: std.mem.Allocator, msg: []const u8, _: *WebSocketClient) bool {
        const stream = jsonscan.extractField(msg, "stream") orelse return true;
        const data_loss_str = jsonscan.extractField(msg, "dataLoss");
        const data_loss = if (data_loss_str) |d| std.mem.eql(u8, d, "true") else false;
        const trace_format = jsonscan.extractField(msg, "traceFormat") orelse "";

        const owned_stream = self.allocator.dupe(u8, stream) catch return true;
        const owned_format = if (trace_format.len > 0) (self.allocator.dupe(u8, trace_format) catch "") else "";
        self.collectors.tracing.set(.{
            .stream_handle = owned_stream,
            .data_loss = data_loss,
            .trace_format = owned_format,
        });
        return true;
    }

    // ── Public accessors for router.zig (thread-safe: each takes self.mu) ──
    //
    // The same *CdpClient is handed out to concurrent HTTP-handler threads
    // by Bridge.getCdpClient, so anything touching `intercept`/`dialog_auto`
    // from outside the read-loop functions above must lock first.

    /// Replace the intercept rule set for this client. Existing rules (and
    /// their owned strings) are freed first.
    pub fn setInterceptRules(self: *CdpClient, rules: []const InterceptRule) !void {
        self.mu.lock();
        defer self.mu.unlock();
        self.intercept.clearRules();
        for (rules) |r| try self.intercept.addRule(r);
    }

    /// Append a single intercept rule without disturbing existing ones.
    pub fn addInterceptRule(self: *CdpClient, rule: InterceptRule) !void {
        self.mu.lock();
        defer self.mu.unlock();
        try self.intercept.addRule(rule);
    }

    /// Remove all intercept rules (subsequent paused requests default to continue).
    pub fn clearInterceptRules(self: *CdpClient) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.intercept.clearRules();
    }

    /// Snapshot of currently-configured intercept rules, in match order.
    /// Caller owns the returned slice and every owned string inside it
    /// (all duped into `allocator` — pass a per-request arena and nothing
    /// further needs freeing).
    pub fn snapshotInterceptRules(self: *CdpClient, allocator: std.mem.Allocator) ![]InterceptRule {
        self.mu.lock();
        defer self.mu.unlock();
        const out = try allocator.alloc(InterceptRule, self.intercept.rules.items.len);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |r| {
                allocator.free(r.url_substring);
                allocator.free(r.body);
                allocator.free(r.content_type);
                allocator.free(r.error_reason);
            }
            allocator.free(out);
        }
        for (self.intercept.rules.items) |r| {
            const url_substring = try allocator.dupe(u8, r.url_substring);
            errdefer allocator.free(url_substring);
            const body = try allocator.dupe(u8, r.body);
            errdefer allocator.free(body);
            const content_type = try allocator.dupe(u8, r.content_type);
            errdefer allocator.free(content_type);
            const error_reason = try allocator.dupe(u8, r.error_reason);

            out[filled] = .{
                .url_substring = url_substring,
                .action = r.action,
                .status = r.status,
                .body = body,
                .content_type = content_type,
                .error_reason = error_reason,
            };
            filled += 1;
        }
        return out;
    }

    /// Snapshot of currently-recorded paused-request records, oldest first.
    /// Caller owns the returned slice AND every string inside it (all duped
    /// into `allocator` — pass a per-request arena and nothing further needs
    /// freeing). Duping is required for safety, not convenience: see
    /// `RequestRing.snapshot`.
    pub fn snapshotPausedRequests(self: *CdpClient, allocator: std.mem.Allocator) ![]PausedRequestRecord {
        self.mu.lock();
        defer self.mu.unlock();
        return self.intercept.requests.snapshot(allocator);
    }

    /// Number of paused-request records currently held (<= 200), without allocating.
    pub fn pausedRequestCount(self: *CdpClient) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.intercept.requests.len();
    }

    /// Drop all recorded paused-request history. Rules are untouched — see
    /// `clearInterceptRules` for that.
    pub fn clearPausedRequests(self: *CdpClient) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.intercept.requests.clear();
    }

    /// Enable/disable dialog auto-response and set the answer to give.
    /// `prompt_text` is duped; pass "" if the dialog isn't a prompt().
    pub fn setDialogAuto(self: *CdpClient, enabled: bool, accept: bool, prompt_text: []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();
        try self.dialog_auto.set(self.allocator, enabled, accept, prompt_text);
    }

    /// Record whether Fetch interception is currently enabled for this tab
    /// (set by the router around its own Fetch.enable/Fetch.disable calls).
    /// Purely bookkeeping — does not itself send any CDP command.
    pub fn setInterceptActive(self: *CdpClient, active: bool) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.intercept.active = active;
    }

    /// Whether interception was last set active via `setInterceptActive`.
    pub fn interceptActive(self: *CdpClient) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.intercept.active;
    }

    // ── Case 1: screencast/video frames ──────────────────────────────────

    /// Snapshot of currently-held screencast frames, oldest first. Same
    /// dupe-on-snapshot contract as `snapshotPausedRequests`.
    pub fn snapshotScreencastFrames(self: *CdpClient, allocator: std.mem.Allocator) ![]ScreencastFrameRecord {
        self.mu.lock();
        defer self.mu.unlock();
        return self.collectors.screencast.snapshot(allocator);
    }

    /// The single most recent screencast frame, if any. Same dupe contract.
    pub fn latestScreencastFrame(self: *CdpClient, allocator: std.mem.Allocator) !?ScreencastFrameRecord {
        self.mu.lock();
        defer self.mu.unlock();
        return self.collectors.screencast.latest(allocator);
    }

    pub fn screencastFrameCount(self: *CdpClient) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.collectors.screencast.len();
    }

    /// Number of frames dropped outright for being individually larger
    /// than `ScreencastRing.MAX_BYTES` -- expose rather than silently
    /// swallow (see hard requirement: log/expose what was dropped).
    pub fn droppedScreencastFrameCount(self: *CdpClient) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.collectors.screencast.dropped_oversize;
    }

    /// Call from `/screencast/stop` (`handleScreencastStop`) so a later
    /// `/screencast/start` doesn't return stale frames from a prior session.
    pub fn clearScreencastFrames(self: *CdpClient) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.collectors.screencast.clear();
    }

    // ── Case 2: Runtime.bindingCalled ────────────────────────────────────

    /// Snapshot of currently-held binding-call records, oldest first.
    pub fn snapshotBindingCalls(self: *CdpClient, allocator: std.mem.Allocator) ![]BindingCallRecord {
        self.mu.lock();
        defer self.mu.unlock();
        return self.collectors.bindings.snapshot(allocator);
    }

    pub fn bindingCallCount(self: *CdpClient) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.collectors.bindings.len();
    }

    pub fn clearBindingCalls(self: *CdpClient) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.collectors.bindings.clear();
    }

    // ── Case 3: Network ───────────────────────────────────────────────────

    /// Snapshot of currently-held network request records, oldest first.
    pub fn snapshotNetworkRequests(self: *CdpClient, allocator: std.mem.Allocator) ![]NetworkRecord {
        self.mu.lock();
        defer self.mu.unlock();
        return self.collectors.network.snapshot(allocator);
    }

    /// Last-match-wins scan for the most recent request whose URL contains
    /// `url_substring` -- gives `/response/body` (`handleResponseBody`) a
    /// real `requestId` instead of the `runtime_evaluate(fetch(...))`
    /// workaround it uses today.
    pub fn findNetworkRequestByUrl(self: *CdpClient, allocator: std.mem.Allocator, url_substring: []const u8) !?NetworkRecord {
        self.mu.lock();
        defer self.mu.unlock();
        return self.collectors.network.findByUrlSubstring(allocator, url_substring);
    }

    pub fn networkRequestCount(self: *CdpClient) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.collectors.network.len();
    }

    /// Call from `handleNetwork` when `mode == "disable"`.
    pub fn clearNetworkRequests(self: *CdpClient) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.collectors.network.clear();
    }

    // ── Case 4: Tracing ───────────────────────────────────────────────────

    /// Destructive: dupes the current stream handle (if any) into
    /// `allocator`, then clears it. See `TraceStreamState.take`'s doc
    /// comment for why this one accessor is a "take" rather than a "peek"
    /// like every other accessor above.
    pub fn takeTraceStream(self: *CdpClient, allocator: std.mem.Allocator) !?TraceStreamRecord {
        self.mu.lock();
        defer self.mu.unlock();
        return self.collectors.tracing.take(allocator);
    }

    pub fn deinit(self: *CdpClient) void {
        self.event_buf.deinit();
        self.intercept.deinit();
        self.dialog_auto.deinit(self.allocator);
        self.collectors.deinit();
        self.disconnect();
    }
};

fn eventMatchesMethod(event_json: []const u8, method: []const u8) bool {
    var match_buf: [256]u8 = undefined;
    const match_pattern = std.fmt.bufPrint(&match_buf, "\"method\":\"{s}\"", .{method}) catch {
        return false;
    };
    return std.mem.indexOf(u8, event_json, match_pattern) != null;
}

test "CdpClient message building" {
    var client = CdpClient.init(std.testing.allocator, "ws://localhost:9222");
    defer client.deinit();

    const msg = try client.buildMessage(std.testing.allocator, "Page.navigate", "{\"url\":\"https://example.com\"}");
    defer std.testing.allocator.free(msg);

    try std.testing.expect(std.mem.indexOf(u8, msg, "Page.navigate") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "https://example.com") != null);
}

test "CdpClient id increments" {
    var client = CdpClient.init(std.testing.allocator, "ws://localhost:9222");
    defer client.deinit();

    const id1 = client.nextId();
    const id2 = client.nextId();
    try std.testing.expect(id2 == id1 + 1);
}

test "matchesResponseId" {
    // Matches exact id
    try std.testing.expect(CdpClient.matchesResponseId("{\"id\":5,\"result\":{}}", 5));
    try std.testing.expect(CdpClient.matchesResponseId("{\"id\":42,\"result\":{}}", 42));
    // Doesn't match wrong id
    try std.testing.expect(!CdpClient.matchesResponseId("{\"id\":5,\"result\":{}}", 6));
    // Doesn't match events (no id field at start)
    try std.testing.expect(!CdpClient.matchesResponseId("{\"method\":\"Page.loadEventFired\",\"params\":{}}", 1));
    // Handles id with spaces
    try std.testing.expect(CdpClient.matchesResponseId("{\"id\": 10, \"result\":{}}", 10));
}

test "EventBuffer push and hasEvent" {
    var buf = EventBuffer.init(std.testing.allocator);
    defer buf.deinit();

    const event = try std.testing.allocator.dupe(u8, "{\"method\":\"Page.loadEventFired\",\"params\":{}}");
    buf.push(std.testing.allocator, event);
    try std.testing.expectEqual(@as(usize, 1), buf.len());
    try std.testing.expect(buf.hasEvent("Page.loadEventFired"));
    try std.testing.expect(!buf.hasEvent("Network.responseReceived"));
}

test "EventBuffer consumeEvent removes matched event" {
    var buf = EventBuffer.init(std.testing.allocator);
    defer buf.deinit();

    const e1 = try std.testing.allocator.dupe(u8, "{\"method\":\"Page.loadEventFired\",\"params\":{}}");
    const e2 = try std.testing.allocator.dupe(u8, "{\"method\":\"Network.responseReceived\",\"params\":{}}");
    buf.push(std.testing.allocator, e1);
    buf.push(std.testing.allocator, e2);

    try std.testing.expect(buf.consumeEvent("Page.loadEventFired"));
    try std.testing.expectEqual(@as(usize, 1), buf.len());
    try std.testing.expect(!buf.hasEvent("Page.loadEventFired"));
    try std.testing.expect(buf.hasEvent("Network.responseReceived"));
    try std.testing.expect(!buf.consumeEvent("Page.loadEventFired"));
}

test "waitForEvent consumes buffered match" {
    var client = CdpClient.init(std.testing.allocator, "ws://localhost:9222");
    defer client.deinit();

    const event = try std.testing.allocator.dupe(u8, "{\"method\":\"Page.loadEventFired\",\"params\":{}}");
    client.event_buf.push(std.testing.allocator, event);

    try std.testing.expect(client.waitForEvent(std.testing.allocator, "Page.loadEventFired", 1));
    try std.testing.expectEqual(@as(usize, 0), client.event_buf.len());
    try std.testing.expect(!client.waitForEvent(std.testing.allocator, "Page.loadEventFired", 1));
}

test "EventBuffer drain frees all" {
    var buf = EventBuffer.init(std.testing.allocator);
    defer buf.deinit();

    const e1 = try std.testing.allocator.dupe(u8, "event1");
    const e2 = try std.testing.allocator.dupe(u8, "event2");
    buf.push(std.testing.allocator, e1);
    buf.push(std.testing.allocator, e2);
    try std.testing.expectEqual(@as(usize, 2), buf.len());
    buf.drain();
    try std.testing.expectEqual(@as(usize, 0), buf.len());
}

// ── InjectedIds ──────────────────────────────────────────────────────────

test "InjectedIds remembers and consumes a matching ack" {
    var ids = InjectedIds{};
    ids.remember(7);
    ids.remember(8);

    try std.testing.expect(ids.consumeIfMatch("{\"id\":7,\"result\":{}}"));
    try std.testing.expectEqual(@as(usize, 1), ids.len);
    // Not consumed twice
    try std.testing.expect(!ids.consumeIfMatch("{\"id\":7,\"result\":{}}"));
    // Still finds the other one
    try std.testing.expect(ids.consumeIfMatch("{\"id\":8,\"result\":{}}"));
    try std.testing.expectEqual(@as(usize, 0), ids.len);
}

test "InjectedIds does not match unrelated ids or real events" {
    var ids = InjectedIds{};
    ids.remember(1);
    try std.testing.expect(!ids.consumeIfMatch("{\"id\":2,\"result\":{}}"));
    try std.testing.expect(!ids.consumeIfMatch("{\"method\":\"Page.loadEventFired\",\"params\":{}}"));
}

test "InjectedIds drops oldest on overflow without corrupting the ring" {
    var ids = InjectedIds{};
    var i: u32 = 0;
    while (i < InjectedIds.CAP + 5) : (i += 1) {
        ids.remember(i);
    }
    // Ring is full; oldest 5 ids (0..4) were evicted.
    try std.testing.expectEqual(@as(usize, InjectedIds.CAP), ids.len);
    try std.testing.expect(!ids.consumeIfMatch("{\"id\":0,\"result\":{}}"));
    try std.testing.expect(!ids.consumeIfMatch("{\"id\":4,\"result\":{}}"));
    // But the newest surviving one is still tracked correctly.
    try std.testing.expect(ids.consumeIfMatch("{\"id\":5,\"result\":{}}"));
    var last_buf: [32]u8 = undefined;
    const last_msg = std.fmt.bufPrint(&last_buf, "{{\"id\":{d},\"result\":{{}}}}", .{i - 1}) catch unreachable;
    try std.testing.expect(ids.consumeIfMatch(last_msg));
}

// ── InterceptState / rule matching ──────────────────────────────────────

test "InterceptState findMatch returns null (default continue) when no rules configured" {
    var state = InterceptState.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expect(state.findMatch("https://example.com/anything") == null);
}

test "InterceptState findMatch matches by url substring in order" {
    var state = InterceptState.init(std.testing.allocator);
    defer state.deinit();

    try state.addRule(.{ .url_substring = "/api/", .action = .abort, .error_reason = "Failed" });
    try state.addRule(.{ .url_substring = "/ads/", .action = .fulfill, .status = 204, .body = "" });

    const m1 = state.findMatch("https://example.com/api/users").?;
    try std.testing.expectEqual(InterceptRule.Action.abort, m1.action);

    const m2 = state.findMatch("https://example.com/ads/banner.js").?;
    try std.testing.expectEqual(InterceptRule.Action.fulfill, m2.action);
    try std.testing.expectEqual(@as(u16, 204), m2.status);

    try std.testing.expect(state.findMatch("https://example.com/home") == null);
}

test "InterceptState catch-all empty-substring rule matches everything" {
    var state = InterceptState.init(std.testing.allocator);
    defer state.deinit();

    try state.addRule(.{ .url_substring = "", .action = .abort });
    try std.testing.expect(state.findMatch("https://anything.example/whatever") != null);
}

test "InterceptState clearRules frees rules and resets matching to default-continue" {
    var state = InterceptState.init(std.testing.allocator);
    defer state.deinit();

    try state.addRule(.{ .url_substring = "x", .action = .abort });
    try std.testing.expect(state.findMatch("x") != null);

    state.clearRules();
    try std.testing.expect(state.findMatch("x") == null);
    try std.testing.expectEqual(@as(usize, 0), state.rules.items.len);
}

// ── RequestRing ──────────────────────────────────────────────────────────

fn makeTestRecord(allocator: std.mem.Allocator, tag: u32) !PausedRequestRecord {
    var buf: [32]u8 = undefined;
    const url = try std.fmt.bufPrint(&buf, "https://example.com/{d}", .{tag});
    return .{
        .request_id = try allocator.dupe(u8, "req"),
        .url = try allocator.dupe(u8, url),
        .method = try allocator.dupe(u8, "GET"),
        .resource_type = try allocator.dupe(u8, "Document"),
        .action_taken = .@"continue",
        .status = 0,
        .timestamp = @intCast(tag),
    };
}

test "RequestRing push and snapshot preserve chronological order" {
    var ring = RequestRing.init(std.testing.allocator);
    defer ring.deinit();

    ring.push(try makeTestRecord(std.testing.allocator, 1));
    ring.push(try makeTestRecord(std.testing.allocator, 2));
    ring.push(try makeTestRecord(std.testing.allocator, 3));

    try std.testing.expectEqual(@as(usize, 3), ring.len());

    const snap = try ring.snapshot(std.testing.allocator);
    defer freeRecordSnapshot(std.testing.allocator, snap);
    try std.testing.expectEqual(@as(usize, 3), snap.len);
    try std.testing.expectEqual(@as(i64, 1), snap[0].timestamp);
    try std.testing.expectEqual(@as(i64, 2), snap[1].timestamp);
    try std.testing.expectEqual(@as(i64, 3), snap[2].timestamp);
}

test "RequestRing overflow evicts oldest and keeps cap" {
    var ring = RequestRing.init(std.testing.allocator);
    defer ring.deinit();

    var i: u32 = 0;
    while (i < RequestRing.CAP + 10) : (i += 1) {
        ring.push(try makeTestRecord(std.testing.allocator, i));
    }

    try std.testing.expectEqual(@as(usize, RequestRing.CAP), ring.len());

    const snap = try ring.snapshot(std.testing.allocator);
    defer freeRecordSnapshot(std.testing.allocator, snap);
    try std.testing.expectEqual(@as(usize, RequestRing.CAP), snap.len);
    // Oldest surviving record should be tag 10 (0..9 evicted), newest CAP+9.
    try std.testing.expectEqual(@as(i64, 10), snap[0].timestamp);
    try std.testing.expectEqual(@as(i64, RequestRing.CAP + 9), snap[snap.len - 1].timestamp);
}

// ── DialogAutoState ──────────────────────────────────────────────────────

test "DialogAutoState set replaces prompt_text and frees the previous one" {
    var state = DialogAutoState{};
    defer state.deinit(std.testing.allocator);

    try state.set(std.testing.allocator, true, true, "first");
    try std.testing.expectEqualStrings("first", state.prompt_text);

    try state.set(std.testing.allocator, true, false, "second");
    try std.testing.expectEqualStrings("second", state.prompt_text);
    try std.testing.expect(!state.accept);
}

// ── CdpClient public accessors ──────────────────────────────────────────

test "CdpClient setInterceptRules / snapshotPausedRequests / setDialogAuto round-trip" {
    var client = CdpClient.init(std.testing.allocator, "ws://localhost:9222");
    defer client.deinit();

    try client.setInterceptRules(&[_]InterceptRule{
        .{ .url_substring = "/blocked", .action = .abort },
    });
    try std.testing.expectEqual(@as(usize, 1), client.intercept.rules.items.len);

    try client.addInterceptRule(.{ .url_substring = "/ads", .action = .fulfill, .status = 204 });
    try std.testing.expectEqual(@as(usize, 2), client.intercept.rules.items.len);

    client.clearInterceptRules();
    try std.testing.expectEqual(@as(usize, 0), client.intercept.rules.items.len);

    try std.testing.expectEqual(@as(usize, 0), client.pausedRequestCount());
    const empty_snap = try client.snapshotPausedRequests(std.testing.allocator);
    defer std.testing.allocator.free(empty_snap);
    try std.testing.expectEqual(@as(usize, 0), empty_snap.len);

    try client.setDialogAuto(true, false, "no thanks");
    try std.testing.expect(client.dialog_auto.enabled);
    try std.testing.expect(!client.dialog_auto.accept);
    try std.testing.expectEqualStrings("no thanks", client.dialog_auto.prompt_text);
}

// ── RequestRing.clear / snapshotInterceptRules / clearPausedRequests /
// setInterceptActive ────────────────────────────────────────────────────

test "RequestRing clear frees all records and resets for reuse" {
    var ring = RequestRing.init(std.testing.allocator);
    defer ring.deinit();

    ring.push(try makeTestRecord(std.testing.allocator, 1));
    ring.push(try makeTestRecord(std.testing.allocator, 2));
    try std.testing.expectEqual(@as(usize, 2), ring.len());

    ring.clear();
    try std.testing.expectEqual(@as(usize, 0), ring.len());

    // Still usable afterward.
    ring.push(try makeTestRecord(std.testing.allocator, 3));
    try std.testing.expectEqual(@as(usize, 1), ring.len());
    const snap = try ring.snapshot(std.testing.allocator);
    defer freeRecordSnapshot(std.testing.allocator, snap);
    try std.testing.expectEqual(@as(i64, 3), snap[0].timestamp);
}

fn freeRecordSnapshot(allocator: std.mem.Allocator, snap: []PausedRequestRecord) void {
    for (snap) |r| {
        allocator.free(r.request_id);
        allocator.free(r.url);
        allocator.free(r.method);
        allocator.free(r.resource_type);
    }
    allocator.free(snap);
}

test "RequestRing snapshot dupes record strings so rotation and clear can't free them underneath a reader" {
    var ring = RequestRing.init(std.testing.allocator);
    defer ring.deinit();

    ring.push(try makeTestRecord(std.testing.allocator, 1));
    ring.push(try makeTestRecord(std.testing.allocator, 2));

    const snap = try ring.snapshot(std.testing.allocator);
    defer freeRecordSnapshot(std.testing.allocator, snap);
    try std.testing.expectEqual(@as(usize, 2), snap.len);

    const url_before = try std.testing.allocator.dupe(u8, snap[0].url);
    defer std.testing.allocator.free(url_before);

    // Both paths that free the ring's own copies: rotation (push) and clear.
    // Either one running on the socket-draining thread while the router is
    // still serializing `snap` must not disturb the snapshot's strings.
    ring.push(try makeTestRecord(std.testing.allocator, 3));
    ring.clear();

    try std.testing.expectEqualStrings(url_before, snap[0].url);
    try std.testing.expectEqual(@as(i64, 1), snap[0].timestamp);
    try std.testing.expectEqual(@as(i64, 2), snap[1].timestamp);
}

test "CdpClient snapshotInterceptRules dupes rule fields independent of the client's own copies" {
    var client = CdpClient.init(std.testing.allocator, "ws://localhost:9222");
    defer client.deinit();

    try client.setInterceptRules(&[_]InterceptRule{
        .{ .url_substring = "/ads", .action = .fulfill, .status = 204, .body = "{}", .content_type = "application/json" },
        .{ .url_substring = "/blocked", .action = .abort, .error_reason = "BlockedByClient" },
    });

    const snap = try client.snapshotInterceptRules(std.testing.allocator);
    defer {
        for (snap) |r| {
            std.testing.allocator.free(r.url_substring);
            std.testing.allocator.free(r.body);
            std.testing.allocator.free(r.content_type);
            std.testing.allocator.free(r.error_reason);
        }
        std.testing.allocator.free(snap);
    }

    try std.testing.expectEqual(@as(usize, 2), snap.len);
    try std.testing.expectEqualStrings("/ads", snap[0].url_substring);
    try std.testing.expectEqual(InterceptRule.Action.fulfill, snap[0].action);
    try std.testing.expectEqual(@as(u16, 204), snap[0].status);
    try std.testing.expectEqualStrings("/blocked", snap[1].url_substring);
    try std.testing.expectEqualStrings("BlockedByClient", snap[1].error_reason);

    // Clearing the client's live rules must not invalidate the snapshot.
    client.clearInterceptRules();
    try std.testing.expectEqualStrings("/ads", snap[0].url_substring);
}

test "CdpClient clearPausedRequests empties the ring without touching rules" {
    var client = CdpClient.init(std.testing.allocator, "ws://localhost:9222");
    defer client.deinit();

    try client.addInterceptRule(.{ .url_substring = "/keep", .action = .@"continue" });
    client.intercept.requests.push(try makeTestRecord(std.testing.allocator, 1));
    try std.testing.expectEqual(@as(usize, 1), client.pausedRequestCount());

    client.clearPausedRequests();
    try std.testing.expectEqual(@as(usize, 0), client.pausedRequestCount());
    try std.testing.expectEqual(@as(usize, 1), client.intercept.rules.items.len);
}

test "CdpClient setInterceptActive / interceptActive round-trip" {
    var client = CdpClient.init(std.testing.allocator, "ws://localhost:9222");
    defer client.deinit();

    try std.testing.expect(!client.interceptActive());
    client.setInterceptActive(true);
    try std.testing.expect(client.interceptActive());
    client.setInterceptActive(false);
    try std.testing.expect(!client.interceptActive());
}

// ── autoRespondFetch: the critical default-continue property ───────────
// These exercise field extraction and the ring/injected-id bookkeeping
// directly. A full send-over-the-wire exercise of autoRespondFetch/Dialog
// needs a live Chrome CDP endpoint (covered instead by the pre-existing
// `zig build test` integration surface via the router layer once wired up).

test "extractRequestPausedFields parses the real Fetch.requestPaused shape" {
    const event =
        \\{"method":"Fetch.requestPaused","params":{"requestId":"interception-job-1.0","request":{"url":"https://example.com/api/data","method":"POST","headers":{}},"resourceType":"XHR"}}
    ;
    const fields = CdpClient.extractRequestPausedFields(event).?;
    try std.testing.expectEqualStrings("interception-job-1.0", fields.request_id);
    try std.testing.expectEqualStrings("https://example.com/api/data", fields.url);
    try std.testing.expectEqualStrings("POST", fields.method);
    try std.testing.expectEqualStrings("XHR", fields.resource_type);
}

test "extractRequestPausedFields returns null on malformed event" {
    try std.testing.expect(CdpClient.extractRequestPausedFields("{\"method\":\"Fetch.requestPaused\",\"params\":{}}") == null);
}

test "eventMatchesMethod recognizes Fetch.requestPaused and dialog events" {
    try std.testing.expect(eventMatchesMethod("{\"method\":\"Fetch.requestPaused\",\"params\":{}}", "Fetch.requestPaused"));
    try std.testing.expect(eventMatchesMethod("{\"method\":\"Page.javascriptDialogOpening\",\"params\":{}}", "Page.javascriptDialogOpening"));
    try std.testing.expect(!eventMatchesMethod("{\"method\":\"Page.loadEventFired\",\"params\":{}}", "Fetch.requestPaused"));
}

// ── Generic CDP event collector: ScreencastRing ─────────────────────────

fn makeScreencastFrame(allocator: std.mem.Allocator, size: usize, tag: u8) !ScreencastFrameRecord {
    const data = try allocator.alloc(u8, size);
    @memset(data, tag);
    return .{ .data_b64 = data, .timestamp = 0, .device_width = 0, .device_height = 0, .session_id = 0 };
}

test "ScreencastRing evicts oldest by count when frames are individually small" {
    var ring = ScreencastRing.init(std.testing.allocator);
    defer ring.deinit();

    var i: u32 = 0;
    while (i < ScreencastRing.MAX_COUNT + 5) : (i += 1) {
        ring.push(try makeScreencastFrame(std.testing.allocator, 16, @intCast(i % 256)));
    }
    try std.testing.expectEqual(@as(usize, ScreencastRing.MAX_COUNT), ring.len());
}

test "ScreencastRing evicts oldest frames to satisfy the byte cap, well before the count cap is hit" {
    var ring = ScreencastRing.init(std.testing.allocator);
    defer ring.deinit();

    const frame_size = 12 * 1024 * 1024; // 12 MiB
    ring.push(try makeScreencastFrame(std.testing.allocator, frame_size, 1));
    ring.push(try makeScreencastFrame(std.testing.allocator, frame_size, 2));
    try std.testing.expectEqual(@as(usize, 2), ring.len());

    // A third 12 MiB frame would put total_bytes at ~36 MiB, over the 32
    // MiB cap, while count sits at only 3 (nowhere near MAX_COUNT=30) --
    // the oldest frame must be evicted to make room.
    ring.push(try makeScreencastFrame(std.testing.allocator, frame_size, 3));
    try std.testing.expectEqual(@as(usize, 2), ring.len());
    try std.testing.expect(ring.total_bytes <= ScreencastRing.MAX_BYTES);

    const snap = try ring.snapshot(std.testing.allocator);
    defer {
        for (snap) |f| std.testing.allocator.free(f.data_b64);
        std.testing.allocator.free(snap);
    }
    try std.testing.expectEqual(@as(u8, 2), snap[0].data_b64[0]);
    try std.testing.expectEqual(@as(u8, 3), snap[1].data_b64[0]);
}

test "ScreencastRing drops a single frame that alone exceeds the byte cap, without touching existing frames" {
    var ring = ScreencastRing.init(std.testing.allocator);
    defer ring.deinit();

    ring.push(try makeScreencastFrame(std.testing.allocator, 1024, 1));
    try std.testing.expectEqual(@as(usize, 1), ring.len());

    ring.push(try makeScreencastFrame(std.testing.allocator, ScreencastRing.MAX_BYTES + 1, 9));
    try std.testing.expectEqual(@as(usize, 1), ring.len());
    try std.testing.expectEqual(@as(usize, 1), ring.dropped_oversize);

    const snap = try ring.snapshot(std.testing.allocator);
    defer {
        for (snap) |f| std.testing.allocator.free(f.data_b64);
        std.testing.allocator.free(snap);
    }
    try std.testing.expectEqual(@as(u8, 1), snap[0].data_b64[0]);
}

test "ScreencastRing snapshot dupes survive a later clear" {
    var ring = ScreencastRing.init(std.testing.allocator);
    defer ring.deinit();
    ring.push(try makeScreencastFrame(std.testing.allocator, 8, 7));

    const snap = try ring.snapshot(std.testing.allocator);
    defer {
        for (snap) |f| std.testing.allocator.free(f.data_b64);
        std.testing.allocator.free(snap);
    }
    ring.clear();

    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqual(@as(u8, 7), snap[0].data_b64[0]);
    try std.testing.expectEqual(@as(usize, 0), ring.len());
}

// ── Generic CDP event collector: NetworkRing / BindingCallRing ──────────

test "NetworkRing updateMimeType attaches to the matching record and findByUrlSubstring is last-match-wins" {
    var ring = NetworkRing.init(std.testing.allocator);
    defer ring.deinit();

    ring.push(.{ .request_id = try std.testing.allocator.dupe(u8, "r1"), .url = try std.testing.allocator.dupe(u8, "https://example.com/a"), .url_truncated = false, .method = try std.testing.allocator.dupe(u8, "GET"), .mime_type = "", .timestamp = 1 });
    ring.push(.{ .request_id = try std.testing.allocator.dupe(u8, "r2"), .url = try std.testing.allocator.dupe(u8, "https://example.com/api/b"), .url_truncated = false, .method = try std.testing.allocator.dupe(u8, "POST"), .mime_type = "", .timestamp = 2 });

    const mime = try std.testing.allocator.dupe(u8, "application/json");
    try std.testing.expect(ring.updateMimeType("r2", mime));
    // Unknown request id: caller keeps ownership of the mime it tried to attach.
    const orphan_mime = try std.testing.allocator.dupe(u8, "text/plain");
    try std.testing.expect(!ring.updateMimeType("nope", orphan_mime));
    std.testing.allocator.free(orphan_mime);

    const found = try ring.findByUrlSubstring(std.testing.allocator, "/api/");
    try std.testing.expect(found != null);
    defer {
        std.testing.allocator.free(found.?.request_id);
        std.testing.allocator.free(found.?.url);
        std.testing.allocator.free(found.?.method);
        if (found.?.mime_type.len > 0) std.testing.allocator.free(found.?.mime_type);
    }
    try std.testing.expectEqualStrings("r2", found.?.request_id);
    try std.testing.expectEqualStrings("application/json", found.?.mime_type);

    try std.testing.expect(try ring.findByUrlSubstring(std.testing.allocator, "/nonexistent/") == null);
}

test "NetworkRing snapshot dupes survive a later clear (dupe-independence)" {
    var ring = NetworkRing.init(std.testing.allocator);
    defer ring.deinit();
    ring.push(.{ .request_id = try std.testing.allocator.dupe(u8, "r1"), .url = try std.testing.allocator.dupe(u8, "https://example.com/x"), .url_truncated = false, .method = try std.testing.allocator.dupe(u8, "GET"), .mime_type = "", .timestamp = 5 });

    const snap = try ring.snapshot(std.testing.allocator);
    defer {
        for (snap) |r| {
            std.testing.allocator.free(r.request_id);
            std.testing.allocator.free(r.url);
            std.testing.allocator.free(r.method);
            if (r.mime_type.len > 0) std.testing.allocator.free(r.mime_type);
        }
        std.testing.allocator.free(snap);
    }
    ring.clear();

    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqualStrings("https://example.com/x", snap[0].url);
    try std.testing.expectEqual(@as(usize, 0), ring.len());
}

test "BindingCallRing overflow evicts oldest and keeps cap" {
    var ring = BindingCallRing.init(std.testing.allocator);
    defer ring.deinit();

    var i: u32 = 0;
    while (i < BindingCallRing.CAP + 3) : (i += 1) {
        ring.push(.{
            .name = try std.testing.allocator.dupe(u8, "onMsg"),
            .payload = try std.testing.allocator.dupe(u8, "x"),
            .truncated = false,
            .timestamp = @intCast(i),
        });
    }
    try std.testing.expectEqual(@as(usize, BindingCallRing.CAP), ring.len());

    const snap = try ring.snapshot(std.testing.allocator);
    defer {
        for (snap) |r| {
            std.testing.allocator.free(r.name);
            std.testing.allocator.free(r.payload);
        }
        std.testing.allocator.free(snap);
    }
    try std.testing.expectEqual(@as(i64, 3), snap[0].timestamp);
}

// ── Generic CDP event collector: TraceStreamState ───────────────────────

test "TraceStreamState take is destructive: a second take sees nothing" {
    var state = TraceStreamState.init(std.testing.allocator);
    defer state.deinit();

    state.set(.{
        .stream_handle = try std.testing.allocator.dupe(u8, "42"),
        .data_loss = false,
        .trace_format = try std.testing.allocator.dupe(u8, "proto"),
    });

    const first = try state.take(std.testing.allocator);
    try std.testing.expect(first != null);
    defer {
        std.testing.allocator.free(first.?.stream_handle);
        if (first.?.trace_format.len > 0) std.testing.allocator.free(first.?.trace_format);
    }
    try std.testing.expectEqualStrings("42", first.?.stream_handle);

    try std.testing.expect(try state.take(std.testing.allocator) == null);
}

// ── Generic CDP event collector: `collect` dispatch via CdpClient ──────

fn makeDummyWs(read_buf: []u8) WebSocketClient {
    return .{ .allocator = std.testing.allocator, .fd = -1, .connected = false, .read_buf = read_buf };
}

test "collect dispatches Runtime.bindingCalled to the registered handler and truncates oversized payloads" {
    var client = CdpClient.init(std.testing.allocator, "ws://localhost:9222");
    defer client.deinit();
    var read_buf: [64]u8 = undefined;
    var ws = makeDummyWs(&read_buf);

    const big_payload = try std.testing.allocator.alloc(u8, BindingCallRecord.MAX_PAYLOAD + 500);
    defer std.testing.allocator.free(big_payload);
    @memset(big_payload, 'z');

    const event = try std.fmt.allocPrint(std.testing.allocator, "{{\"method\":\"Runtime.bindingCalled\",\"params\":{{\"name\":\"onMsg\",\"payload\":\"{s}\"}}}}", .{big_payload});
    const handled = client.collect(std.testing.allocator, event, &ws);
    std.testing.allocator.free(event);

    try std.testing.expect(handled);
    try std.testing.expectEqual(@as(usize, 1), client.bindingCallCount());

    const snap = try client.snapshotBindingCalls(std.testing.allocator);
    defer {
        for (snap) |r| {
            std.testing.allocator.free(r.name);
            std.testing.allocator.free(r.payload);
        }
        std.testing.allocator.free(snap);
    }
    try std.testing.expectEqualStrings("onMsg", snap[0].name);
    try std.testing.expect(snap[0].truncated);
    try std.testing.expectEqual(@as(usize, BindingCallRecord.MAX_PAYLOAD), snap[0].payload.len);
}

test "collect observes (never consumes) Network.requestWillBeSent/responseReceived so HAR still sees them" {
    var client = CdpClient.init(std.testing.allocator, "ws://localhost:9222");
    defer client.deinit();
    var read_buf: [64]u8 = undefined;
    var ws = makeDummyWs(&read_buf);

    const req_event = try std.testing.allocator.dupe(u8, "{\"method\":\"Network.requestWillBeSent\",\"params\":{\"requestId\":\"42.1\",\"request\":{\"url\":\"https://example.com/api/data\",\"method\":\"POST\"}}}");
    const handled1 = client.collect(std.testing.allocator, req_event, &ws);
    std.testing.allocator.free(req_event);
    try std.testing.expect(!handled1);
    try std.testing.expectEqual(@as(usize, 1), client.networkRequestCount());

    const resp_event = try std.testing.allocator.dupe(u8, "{\"method\":\"Network.responseReceived\",\"params\":{\"requestId\":\"42.1\",\"response\":{\"status\":200,\"mimeType\":\"application/json\"}}}");
    const handled2 = client.collect(std.testing.allocator, resp_event, &ws);
    std.testing.allocator.free(resp_event);
    try std.testing.expect(!handled2);

    const found = try client.findNetworkRequestByUrl(std.testing.allocator, "/api/data");
    try std.testing.expect(found != null);
    defer {
        std.testing.allocator.free(found.?.request_id);
        std.testing.allocator.free(found.?.url);
        std.testing.allocator.free(found.?.method);
        if (found.?.mime_type.len > 0) std.testing.allocator.free(found.?.mime_type);
    }
    try std.testing.expectEqualStrings("42.1", found.?.request_id);
    try std.testing.expectEqualStrings("application/json", found.?.mime_type);
}

test "collect fully consumes Tracing.tracingComplete and feeds takeTraceStream" {
    var client = CdpClient.init(std.testing.allocator, "ws://localhost:9222");
    defer client.deinit();
    var read_buf: [64]u8 = undefined;
    var ws = makeDummyWs(&read_buf);

    const event = try std.testing.allocator.dupe(u8, "{\"method\":\"Tracing.tracingComplete\",\"params\":{\"dataLoss\":false,\"stream\":\"42\",\"traceFormat\":\"proto\"}}");
    const handled = client.collect(std.testing.allocator, event, &ws);
    std.testing.allocator.free(event);
    try std.testing.expect(handled);

    const first = try client.takeTraceStream(std.testing.allocator);
    try std.testing.expect(first != null);
    defer {
        std.testing.allocator.free(first.?.stream_handle);
        if (first.?.trace_format.len > 0) std.testing.allocator.free(first.?.trace_format);
    }
    try std.testing.expectEqualStrings("42", first.?.stream_handle);
    try std.testing.expectEqualStrings("proto", first.?.trace_format);
    try std.testing.expect(!first.?.data_loss);

    try std.testing.expect(try client.takeTraceStream(std.testing.allocator) == null);
}

test "waitForEvent runs collect on the exact matching event so collectTracingComplete isn't skipped" {
    // Regression test: `waitForEvent`'s own fast path used to match the
    // awaited event by method name and free it immediately, never routing
    // it through `collect` -- so the ONE call site that both waits for
    // Tracing.tracingComplete AND needs its payload (/trace/stop) always
    // saw takeTraceStream() return null, even though Chrome's event
    // genuinely carried a `stream` handle. This exercises the real
    // `waitForEvent` -> socket-read -> match path end to end (a real
    // WebSocket text frame over a socketpair), not just `collect` called
    // directly, since that's exactly the integration path the bug lived in.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const c_socketpair = @extern(*const fn (c_int, c_int, c_int, *[2]c_int) callconv(.c) c_int, .{ .name = "socketpair" });
    var fds: [2]c_int = undefined;
    try std.testing.expect(c_socketpair(@intCast(std.posix.AF.UNIX), @intCast(std.posix.SOCK.STREAM), 0, &fds) == 0);
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var read_buf: [4096]u8 = undefined;
    var client = CdpClient.init(std.testing.allocator, "ws://localhost:9222");
    defer client.deinit();
    client.ws = WebSocketClient{
        .allocator = std.testing.allocator,
        .fd = fds[0],
        .connected = true,
        .read_buf = &read_buf,
    };

    // Write a real, unmasked WebSocket text frame (servers never mask, per
    // RFC 6455) carrying Tracing.tracingComplete with a stream handle --
    // exactly what Chrome sends after Tracing.end when /trace/start asked
    // for transferMode: ReturnAsStream.
    const payload = "{\"method\":\"Tracing.tracingComplete\",\"params\":{\"dataLoss\":false,\"stream\":\"7\",\"traceFormat\":\"json\"}}";
    var frame: [2 + payload.len]u8 = undefined;
    frame[0] = 0x81; // FIN=1, opcode=1 (text)
    frame[1] = @intCast(payload.len); // MASK bit unset, len < 126
    @memcpy(frame[2..], payload);
    try std.testing.expect(std.c.write(fds[1], &frame, frame.len) == frame.len);

    try std.testing.expect(client.waitForEvent(std.testing.allocator, "Tracing.tracingComplete", 1));

    const stream_rec = try client.takeTraceStream(std.testing.allocator);
    try std.testing.expect(stream_rec != null);
    defer {
        std.testing.allocator.free(stream_rec.?.stream_handle);
        if (stream_rec.?.trace_format.len > 0) std.testing.allocator.free(stream_rec.?.trace_format);
    }
    try std.testing.expectEqualStrings("7", stream_rec.?.stream_handle);
    try std.testing.expectEqualStrings("json", stream_rec.?.trace_format);
    try std.testing.expect(!stream_rec.?.data_loss);
}

test "collectScreencastFrame always acks inline via Page.screencastFrameAck and records the frame" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const c_socketpair = @extern(*const fn (c_int, c_int, c_int, *[2]c_int) callconv(.c) c_int, .{ .name = "socketpair" });
    var fds: [2]c_int = undefined;
    try std.testing.expect(c_socketpair(@intCast(std.posix.AF.UNIX), @intCast(std.posix.SOCK.STREAM), 0, &fds) == 0);
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var read_buf: [4096]u8 = undefined;
    var ws = WebSocketClient{
        .allocator = std.testing.allocator,
        .fd = fds[0],
        .connected = true,
        .read_buf = &read_buf,
    };

    var client = CdpClient.init(std.testing.allocator, "ws://localhost:9222");
    defer client.deinit();

    const event = try std.testing.allocator.dupe(u8, "{\"method\":\"Page.screencastFrame\",\"params\":{\"data\":\"ZmFrZWpwZWc=\",\"metadata\":{\"timestamp\":123.5,\"deviceWidth\":800,\"deviceHeight\":600},\"sessionId\":42}}");
    const handled = client.collect(std.testing.allocator, event, &ws);
    std.testing.allocator.free(event);
    try std.testing.expect(handled);

    try std.testing.expectEqual(@as(usize, 1), client.screencastFrameCount());
    const snap = try client.snapshotScreencastFrames(std.testing.allocator);
    defer {
        for (snap) |f| std.testing.allocator.free(f.data_b64);
        std.testing.allocator.free(snap);
    }
    try std.testing.expectEqualStrings("ZmFrZWpwZWc=", snap[0].data_b64);
    try std.testing.expectEqual(@as(u32, 800), snap[0].device_width);
    try std.testing.expectEqual(@as(u32, 600), snap[0].device_height);

    // An ack frame was written to the peer end of the socketpair over the
    // real (masked) WebSocket wire format -- unmask it by hand to confirm
    // it names the right method and sessionId.
    var recv_buf: [512]u8 = undefined;
    const n: usize = try std.posix.read(fds[1], &recv_buf);
    try std.testing.expect(n >= 6);
    try std.testing.expectEqual(@as(u8, 0x81), recv_buf[0]); // FIN=1, opcode=1 (text)
    try std.testing.expect((recv_buf[1] & 0x80) != 0); // client frames are always masked
    const payload_len: usize = recv_buf[1] & 0x7F;
    try std.testing.expect(payload_len <= 125); // small ack payload, no extended length needed
    try std.testing.expect(n >= 6 + payload_len);
    const mask = recv_buf[2..6];
    var decoded: [256]u8 = undefined;
    for (0..payload_len) |i| decoded[i] = recv_buf[6 + i] ^ mask[i % 4];
    const decoded_slice = decoded[0..payload_len];
    try std.testing.expect(std.mem.indexOf(u8, decoded_slice, "Page.screencastFrameAck") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded_slice, "\"sessionId\":42") != null);
}

test "CollectorState init/deinit round trip" {
    var state = CollectorState.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 0), state.screencast.len());
    try std.testing.expectEqual(@as(usize, 0), state.bindings.len());
    try std.testing.expectEqual(@as(usize, 0), state.network.len());
    try std.testing.expect(state.tracing.current == null);
}
