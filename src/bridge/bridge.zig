const std = @import("std");
const net = std.Io.net;
const compat = @import("../compat.zig");
const CdpClient = @import("../cdp/client.zig").CdpClient;
const HarRecorder = @import("../cdp/har.zig").HarRecorder;
const A11yNode = @import("../snapshot/a11y.zig").A11yNode;

pub const TabEntry = struct {
    id: []const u8,
    url: []const u8,
    title: []const u8,
    ws_url: []const u8,
    created_at: i64,
    last_accessed: i64,
};

const PersistedTab = struct {
    id: []const u8,
    url: []const u8 = "",
    title: []const u8 = "",
    ws_url: []const u8 = "",
};

pub const RefCache = struct {
    refs: std.StringHashMap(u32),
    node_count: usize,
    /// Bumped once per detected navigation (see router.zig's
    /// bumpGenerationLocked). NOT reset by clear() — clear() runs on every
    /// snapshot, generation must survive across it and only move forward
    /// when the underlying document actually changes.
    generation: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) RefCache {
        return .{
            .refs = std.StringHashMap(u32).init(allocator),
            .node_count = 0,
            .generation = 0,
        };
    }

    pub fn clear(self: *RefCache) void {
        var it = self.refs.keyIterator();
        while (it.next()) |key| {
            self.refs.allocator.free(key.*);
        }
        self.refs.clearRetainingCapacity();
        self.node_count = 0;
    }

    pub fn deinit(self: *RefCache) void {
        self.clear();
        self.refs.deinit();
    }
};

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    tabs: std.StringHashMap(TabEntry),
    current_tabs: std.StringHashMap([]const u8),
    snapshots: std.StringHashMap(RefCache),
    prev_snapshots: std.StringHashMap([]const A11yNode),
    cdp_clients: std.StringHashMap(*CdpClient),
    har_recorders: std.StringHashMap(*HarRecorder),
    debug_script_ids: std.StringHashMap([]const u8),
    cdp_host: []const u8,
    cdp_port: u16,
    mu: compat.PthreadRwLock,

    pub fn init(allocator: std.mem.Allocator) Bridge {
        return .{
            .allocator = allocator,
            .tabs = std.StringHashMap(TabEntry).init(allocator),
            .current_tabs = std.StringHashMap([]const u8).init(allocator),
            .snapshots = std.StringHashMap(RefCache).init(allocator),
            .prev_snapshots = std.StringHashMap([]const A11yNode).init(allocator),
            .cdp_clients = std.StringHashMap(*CdpClient).init(allocator),
            .har_recorders = std.StringHashMap(*HarRecorder).init(allocator),
            .debug_script_ids = std.StringHashMap([]const u8).init(allocator),
            .cdp_host = "127.0.0.1",
            .cdp_port = 9222,
            .mu = .{},
        };
    }

    pub fn deinit(self: *Bridge) void {
        // Serialize teardown against any still-live handler threads. Callers
        // should quiesce request threads before deinit, but take the lock so a
        // late locked accessor can't iterate a half-freed map.
        self.mu.lock();
        defer self.mu.unlock();

        var current_it = self.current_tabs.iterator();
        while (current_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.current_tabs.deinit();

        var debug_it = self.debug_script_ids.iterator();
        while (debug_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.debug_script_ids.deinit();

        var har_it = self.har_recorders.iterator();
        while (har_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.har_recorders.deinit();

        var cdp_it = self.cdp_clients.iterator();
        while (cdp_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.cdp_clients.deinit();

        var prev_it = self.prev_snapshots.iterator();
        while (prev_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeSnapshot(self.allocator, entry.value_ptr.*);
        }
        self.prev_snapshots.deinit();

        var snap_it = self.snapshots.iterator();
        while (snap_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.snapshots.deinit();

        var tab_it = self.tabs.valueIterator();
        while (tab_it.next()) |tab| {
            self.allocator.free(tab.id);
            self.allocator.free(tab.url);
            self.allocator.free(tab.title);
            self.allocator.free(tab.ws_url);
        }
        self.tabs.deinit();
    }

    pub fn tabCount(self: *Bridge) usize {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.tabs.count();
    }

    pub fn getTab(self: *Bridge, tab_id: []const u8) ?TabEntry {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.tabs.get(tab_id);
    }

    pub fn putTab(self: *Bridge, entry: TabEntry) !void {
        self.mu.lock();
        defer self.mu.unlock();

        // Dupe all strings into bridge allocator for ownership
        const owned = TabEntry{
            .id = try self.allocator.dupe(u8, entry.id),
            .url = try self.allocator.dupe(u8, entry.url),
            .title = try self.allocator.dupe(u8, entry.title),
            .ws_url = try self.allocator.dupe(u8, entry.ws_url),
            .created_at = entry.created_at,
            .last_accessed = entry.last_accessed,
        };
        errdefer {
            self.allocator.free(owned.id);
            self.allocator.free(owned.url);
            self.allocator.free(owned.title);
            self.allocator.free(owned.ws_url);
        }

        // Remove old entry first (frees old key from map)
        if (self.tabs.fetchRemove(entry.id)) |old_kv| {
            self.allocator.free(old_kv.key);
            self.allocator.free(old_kv.value.url);
            self.allocator.free(old_kv.value.title);
            self.allocator.free(old_kv.value.ws_url);
            // old_kv.key == old_kv.value.id, already freed above
        }

        try self.tabs.put(owned.id, owned);
    }

    pub fn removeTab(self: *Bridge, tab_id: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();

        while (true) {
            var session_to_clear: ?[]const u8 = null;
            var current_it = self.current_tabs.iterator();
            while (current_it.next()) |entry| {
                if (std.mem.eql(u8, entry.value_ptr.*, tab_id)) {
                    session_to_clear = entry.key_ptr.*;
                    break;
                }
            }
            const session_id = session_to_clear orelse break;
            if (self.current_tabs.fetchRemove(session_id)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }
        }

        // Grab owned strings before removing from map
        const tab = self.tabs.get(tab_id) orelse {
            if (self.snapshots.fetchRemove(tab_id)) |kv| {
                self.allocator.free(kv.key);
                var cache = kv.value;
                cache.deinit();
            }
            if (self.prev_snapshots.fetchRemove(tab_id)) |kv| {
                self.allocator.free(kv.key);
                freeSnapshot(self.allocator, kv.value);
            }
            if (self.cdp_clients.fetchRemove(tab_id)) |kv| {
                self.allocator.free(kv.key);
                kv.value.deinit();
                self.allocator.destroy(kv.value);
            }
            if (self.har_recorders.fetchRemove(tab_id)) |kv| {
                self.allocator.free(kv.key);
                kv.value.deinit();
                self.allocator.destroy(kv.value);
            }
            return;
        };

        _ = self.tabs.remove(tab_id);

        self.allocator.free(tab.id);
        self.allocator.free(tab.url);
        self.allocator.free(tab.title);
        self.allocator.free(tab.ws_url);

        if (self.snapshots.fetchRemove(tab_id)) |kv| {
            self.allocator.free(kv.key); // fetchRemove (not remove) so the owned key string is freed
            var cache = kv.value;
            cache.deinit();
        }
        if (self.prev_snapshots.fetchRemove(tab_id)) |kv| {
            self.allocator.free(kv.key);
            freeSnapshot(self.allocator, kv.value);
        }
        if (self.cdp_clients.fetchRemove(tab_id)) |kv| {
            self.allocator.free(kv.key);
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }
        if (self.har_recorders.fetchRemove(tab_id)) |kv| {
            self.allocator.free(kv.key);
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }
        if (self.debug_script_ids.fetchRemove(tab_id)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    pub fn listTabs(self: *Bridge, allocator: std.mem.Allocator) ![]TabEntry {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        var list: std.ArrayList(TabEntry) = .empty;
        var it = self.tabs.valueIterator();
        while (it.next()) |entry| {
            try list.append(allocator, entry.*);
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn setCurrentTab(self: *Bridge, session_id: []const u8, tab_id: []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.current_tabs.fetchRemove(session_id)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        try self.current_tabs.put(
            try self.allocator.dupe(u8, session_id),
            try self.allocator.dupe(u8, tab_id),
        );

        if (self.tabs.getPtr(tab_id)) |entry| {
            entry.last_accessed = compat.timestampSeconds();
        }
    }

    pub fn getCurrentTab(self: *Bridge, allocator: std.mem.Allocator, session_id: []const u8) ?[]u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        const tab_id = self.current_tabs.get(session_id) orelse return null;
        return allocator.dupe(u8, tab_id) catch null;
    }

    pub fn clearCurrentTab(self: *Bridge, session_id: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.current_tabs.fetchRemove(session_id)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    pub fn touchTab(self: *Bridge, tab_id: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        const entry = self.tabs.getPtr(tab_id) orelse return false;
        entry.last_accessed = compat.timestampSeconds();
        return true;
    }

    pub fn updateTabMetadata(self: *Bridge, tab_id: []const u8, url: []const u8, title: []const u8) !bool {
        self.mu.lock();
        defer self.mu.unlock();

        const entry = self.tabs.getPtr(tab_id) orelse return false;

        const owned_url = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(owned_url);
        const owned_title = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(owned_title);

        self.allocator.free(entry.url);
        self.allocator.free(entry.title);
        entry.url = owned_url;
        entry.title = owned_title;
        entry.last_accessed = compat.timestampSeconds();
        return true;
    }

    /// Set the Chrome CDP address so Bridge can refresh dead connections.
    /// Locked: `refreshTabWsUrl` reads these under `mu`, so the write must take
    /// the same lock or a concurrent reader can observe a torn host slice / port.
    pub fn setCdpAddress(self: *Bridge, host: []const u8, port: u16) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.cdp_host = host;
        self.cdp_port = port;
    }

    /// Get or create a CDP client for a tab.
    /// If the cached client is dead (target detached by Chrome), refreshes
    /// the tab's webSocketDebuggerUrl from /json/list and recreates it.
    pub fn getCdpClient(self: *Bridge, tab_id: []const u8) ?*CdpClient {
        // Phase 1: fast path + dead-client eviction under the lock.
        {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.cdp_clients.get(tab_id)) |client| {
                if (!client.dead) return client;
                evictDeadClientLocked(self, tab_id);
            }
        }

        // Phase 2: refresh the ws_url from Chrome's /json/list WITHOUT holding mu.
        // This is blocking network I/O; doing it under the lock serialized every
        // other tab's getCdpClient behind one slow request (see audit section 1).
        // refreshTabWsUrl locks internally only for its address read and tab write.
        self.refreshTabWsUrl(tab_id);

        // Phase 3: create + insert under the lock, re-checking for a client that
        // another thread may have created while we were unlocked in phase 2.
        self.mu.lock();
        defer self.mu.unlock();

        if (self.cdp_clients.get(tab_id)) |client| {
            if (!client.dead) return client;
            evictDeadClientLocked(self, tab_id);
        }

        const tab = self.tabs.get(tab_id) orelse return null;
        if (tab.ws_url.len == 0) return null;

        const client = self.allocator.create(CdpClient) catch return null;
        client.* = CdpClient.init(self.allocator, tab.ws_url);
        const owned_key = self.allocator.dupe(u8, tab_id) catch {
            self.allocator.destroy(client);
            return null;
        };
        self.cdp_clients.put(owned_key, client) catch {
            self.allocator.free(owned_key);
            self.allocator.destroy(client);
            return null;
        };
        return client;
    }

    /// Remove + free a dead CDP client. Caller MUST hold `mu`.
    /// NOTE (audit section 1, residual): destroying here can still race a thread
    /// that already holds the returned `*CdpClient` from a prior getCdpClient and
    /// is about to call send() -- a use-after-free. The complete fix is refcounting
    /// the client (increment under `mu` in getCdpClient, release at the ~125 call
    /// sites, free only at refcount 0). Tracked in docs/scaling/03-cdp-audit.md.
    fn evictDeadClientLocked(self: *Bridge, tab_id: []const u8) void {
        if (self.cdp_clients.fetchRemove(tab_id)) |kv| {
            self.allocator.free(kv.key);
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }
    }

    /// Re-fetch Chrome's /json/list to pick up a new webSocketDebuggerUrl for a tab.
    /// This handles the case where Chrome detached the old target (renderer swap)
    /// and assigned a fresh ws_url to the same target id.
    ///
    /// Self-locking: snapshots the CDP address under `mu` (phase 1), performs the
    /// blocking HTTP fetch WITHOUT the lock (phase 2), then applies the fresh
    /// ws_url under `mu` (phase 3). Callers must NOT hold `mu` (rwlock not recursive).
    fn refreshTabWsUrl(self: *Bridge, tab_id: []const u8) void {
        if (@import("builtin").os.tag == .windows) return;

        // Phase 1: snapshot the CDP address under the lock. Slices point at
        // process-lifetime storage; we only need the read atomic vs setCdpAddress.
        self.mu.lock();
        const host = self.cdp_host;
        const port = self.cdp_port;
        self.mu.unlock();

        // Phase 2: blocking /json/list fetch, no lock held.
        const io = std.Io.Threaded.global_single_threaded.io();
        const address = net.IpAddress.parseIp4(host, port) catch return;
        const stream = net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch return;
        defer stream.close(io);

        const timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
        std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

        const http_req = std.fmt.allocPrint(self.allocator, "GET /json/list HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ host, port }) catch return;
        defer self.allocator.free(http_req);

        var written: usize = 0;
        while (written < http_req.len) {
            const rc = std.c.write(stream.socket.handle, http_req.ptr + written, http_req.len - written);
            if (rc <= 0) return;
            written += @intCast(rc);
        }

        var response_buf: [65536]u8 = undefined;
        var total: usize = 0;
        while (total < response_buf.len) {
            const n = std.posix.read(stream.socket.handle, response_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
        if (total == 0) return;

        const raw_response = response_buf[0..total];
        const body_start = (std.mem.indexOf(u8, raw_response, "\r\n\r\n") orelse return) + 4;
        const body = raw_response[body_start..total];

        // Find our tab and extract its fresh ws_url (a slice into the stack
        // response_buf, valid until this function returns).
        var fresh_ws_url: ?[]const u8 = null;
        var pos: usize = 0;
        while (pos < body.len) {
            const id_start = std.mem.indexOfPos(u8, body, pos, "\"id\"") orelse break;
            const id_val = extractSimpleJsonString(body, id_start, "\"id\"") orelse {
                pos = id_start + 4;
                continue;
            };

            if (std.mem.eql(u8, id_val, tab_id)) {
                fresh_ws_url = extractSimpleJsonString(body, id_start, "\"webSocketDebuggerUrl\"");
                break;
            }

            const next_id = std.mem.indexOfPos(u8, body, id_start + 4, "\"id\"") orelse body.len;
            pos = next_id;
        }

        // Phase 3: apply the fresh ws_url under the lock (dup into owned memory).
        const fresh = fresh_ws_url orelse return;
        self.mu.lock();
        defer self.mu.unlock();
        if (self.tabs.getPtr(tab_id)) |tab| {
            const owned = self.allocator.dupe(u8, fresh) catch return;
            self.allocator.free(tab.ws_url);
            tab.ws_url = owned;
            std.log.info("refreshed ws_url for tab {s}: {s}", .{ tab_id, fresh });
        }
    }

    pub fn exportState(self: *Bridge, allocator: std.mem.Allocator) ![]const u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        const persisted_tabs = try allocator.alloc(PersistedTab, self.tabs.count());
        defer allocator.free(persisted_tabs);

        var it = self.tabs.valueIterator();
        var i: usize = 0;
        while (it.next()) |tab| : (i += 1) {
            persisted_tabs[i] = .{
                .id = tab.id,
                .url = tab.url,
                .title = tab.title,
                .ws_url = tab.ws_url,
            };
        }

        return std.json.Stringify.valueAlloc(allocator, persisted_tabs, .{});
    }

    pub fn importState(self: *Bridge, json: []const u8, allocator: std.mem.Allocator) !usize {
        var parse_arena = std.heap.ArenaAllocator.init(allocator);
        defer parse_arena.deinit();

        const persisted_tabs = try std.json.parseFromSliceLeaky([]PersistedTab, parse_arena.allocator(), json, .{
            .ignore_unknown_fields = true,
        });
        const now = compat.timestampSeconds();

        for (persisted_tabs) |tab| {
            try self.putTab(.{
                .id = tab.id,
                .url = tab.url,
                .title = tab.title,
                .ws_url = tab.ws_url,
                .created_at = now,
                .last_accessed = now,
            });
        }

        return persisted_tabs.len;
    }

    /// Get or create a HAR recorder for a tab.
    /// Returns a stable heap-allocated pointer that survives HashMap resizes.
    pub fn getHarRecorder(self: *Bridge, tab_id: []const u8) ?*HarRecorder {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.har_recorders.get(tab_id)) |rec| {
            return rec;
        }

        const rec = self.allocator.create(HarRecorder) catch return null;
        rec.* = HarRecorder.init(self.allocator);
        const owned_key = self.allocator.dupe(u8, tab_id) catch {
            self.allocator.destroy(rec);
            return null;
        };
        self.har_recorders.put(owned_key, rec) catch {
            self.allocator.free(owned_key);
            self.allocator.destroy(rec);
            return null;
        };
        return rec;
    }

    pub fn setDebugScriptId(self: *Bridge, tab_id: []const u8, script_id: []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.debug_script_ids.fetchRemove(tab_id)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        try self.debug_script_ids.put(
            try self.allocator.dupe(u8, tab_id),
            try self.allocator.dupe(u8, script_id),
        );
    }

    pub fn getDebugScriptId(self: *Bridge, tab_id: []const u8, allocator: std.mem.Allocator) ?[]u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        const value = self.debug_script_ids.get(tab_id) orelse return null;
        return allocator.dupe(u8, value) catch null;
    }

    pub fn clearDebugScriptId(self: *Bridge, tab_id: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.debug_script_ids.fetchRemove(tab_id)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    pub fn cloneSnapshot(self: *Bridge, snapshot: []const A11yNode) ![]A11yNode {
        const copy = try self.allocator.alloc(A11yNode, snapshot.len);
        errdefer self.allocator.free(copy);

        var initialized: usize = 0;
        errdefer {
            for (copy[0..initialized]) |node| {
                self.allocator.free(node.ref);
                self.allocator.free(node.role);
                self.allocator.free(node.name);
                self.allocator.free(node.value);
                self.allocator.free(node.description);
                self.allocator.free(node.state);
            }
        }

        for (snapshot, 0..) |node, i| {
            copy[i] = .{
                .ref = try self.allocator.dupe(u8, node.ref),
                .role = try self.allocator.dupe(u8, node.role),
                .name = try self.allocator.dupe(u8, node.name),
                .value = try self.allocator.dupe(u8, node.value),
                .description = try self.allocator.dupe(u8, node.description),
                .state = try self.allocator.dupe(u8, node.state),
                .backend_node_id = node.backend_node_id,
                .depth = node.depth,
            };
            initialized += 1;
        }

        return copy;
    }
};

fn freeSnapshot(allocator: std.mem.Allocator, snapshot: []const A11yNode) void {
    for (snapshot) |node| {
        allocator.free(node.ref);
        allocator.free(node.role);
        allocator.free(node.name);
        allocator.free(node.value);
        allocator.free(node.description);
        allocator.free(node.state);
    }
    allocator.free(snapshot);
}

test "bridge init/deinit" {
    var bridge = Bridge.init(std.testing.allocator);
    defer bridge.deinit();
    try std.testing.expectEqual(@as(usize, 0), bridge.tabCount());
}

test "exportState empty bridge" {
    var bridge = Bridge.init(std.testing.allocator);
    defer bridge.deinit();
    const json = try bridge.exportState(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("[]", json);
}

test "exportState with one tab" {
    var bridge = Bridge.init(std.testing.allocator);
    defer bridge.deinit();
    try bridge.putTab(.{
        .id = "t1",
        .url = "https://example.com",
        .title = "Example",
        .ws_url = "ws://localhost:9222/t1",
        .created_at = 1000,
        .last_accessed = 1000,
    });
    const json = try bridge.exportState(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "https://example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"t1\"") != null);
}

test "importState round-trip" {
    var bridge = Bridge.init(std.testing.allocator);
    defer bridge.deinit();
    const input = "[{\"id\":\"a1\",\"url\":\"https://a.com\",\"title\":\"A\",\"ws_url\":\"ws://x\"},{\"id\":\"b2\",\"url\":\"https://b.com\",\"title\":\"B\",\"ws_url\":\"\"}]";
    const count = try bridge.importState(input, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 2), bridge.tabCount());
    const tab = bridge.getTab("a1");
    try std.testing.expect(tab != null);
    try std.testing.expectEqualStrings("https://a.com", tab.?.url);
}

test "session persistence preserves escaped JSON values" {
    var source = Bridge.init(std.testing.allocator);
    defer source.deinit();

    try source.putTab(.{
        .id = "tab-escaped",
        .url = "data:text/html,{\"message\":\"hello\\\\world\"}",
        .title = "Brace } and quote \" and slash \\\\",
        .ws_url = "ws://localhost:9222/devtools/page/tab-escaped?label=\"quoted\"",
        .created_at = 1000,
        .last_accessed = 1000,
    });

    const json = try source.exportState(std.testing.allocator);
    defer std.testing.allocator.free(json);

    var target = Bridge.init(std.testing.allocator);
    defer target.deinit();

    const count = try target.importState(json, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), count);

    const tab = target.getTab("tab-escaped").?;
    try std.testing.expectEqualStrings("data:text/html,{\"message\":\"hello\\\\world\"}", tab.url);
    try std.testing.expectEqualStrings("Brace } and quote \" and slash \\\\", tab.title);
    try std.testing.expectEqualStrings("ws://localhost:9222/devtools/page/tab-escaped?label=\"quoted\"", tab.ws_url);
}

test "importState rejects malformed ws_url values" {
    var bridge = Bridge.init(std.testing.allocator);
    defer bridge.deinit();

    const input =
        \\[
        \\  {
        \\    "id": "tab-1",
        \\    "url": "https://example.com",
        \\    "title": "Example",
        \\    "ws_url": {"nested": "ws://unexpected"}
        \\  }
        \\]
    ;

    if (bridge.importState(input, std.testing.allocator)) |_| {
        return error.TestExpectedImportFailure;
    } else |_| {}

    try std.testing.expectEqual(@as(usize, 0), bridge.tabCount());
    try std.testing.expect(bridge.getTab("tab-1") == null);
}

test "bridge tab CRUD" {
    var bridge = Bridge.init(std.testing.allocator);
    defer bridge.deinit();

    const entry = TabEntry{
        .id = "tab-1",
        .url = "https://example.com",
        .title = "Example",
        .ws_url = "",
        .created_at = 1000,
        .last_accessed = 1000,
    };
    try bridge.putTab(entry);
    try std.testing.expectEqual(@as(usize, 1), bridge.tabCount());

    const got = bridge.getTab("tab-1");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("https://example.com", got.?.url);

    bridge.removeTab("tab-1");
    try std.testing.expectEqual(@as(usize, 0), bridge.tabCount());
}

test "bridge current tab session mapping" {
    var bridge = Bridge.init(std.testing.allocator);
    defer bridge.deinit();

    try bridge.putTab(.{
        .id = "tab-1",
        .url = "https://example.com",
        .title = "Example",
        .ws_url = "",
        .created_at = 1000,
        .last_accessed = 1000,
    });

    try bridge.setCurrentTab("session-a", "tab-1");
    const current = bridge.getCurrentTab(std.testing.allocator, "session-a").?;
    defer std.testing.allocator.free(current);
    try std.testing.expectEqualStrings("tab-1", current);

    bridge.clearCurrentTab("session-a");
    try std.testing.expect(bridge.getCurrentTab(std.testing.allocator, "session-a") == null);
}

test "bridge removeTab clears current-tab session mapping" {
    var bridge = Bridge.init(std.testing.allocator);
    defer bridge.deinit();

    try bridge.putTab(.{
        .id = "tab-1",
        .url = "https://example.com",
        .title = "Example",
        .ws_url = "",
        .created_at = 1000,
        .last_accessed = 1000,
    });
    try bridge.setCurrentTab("session-a", "tab-1");

    bridge.removeTab("tab-1");
    try std.testing.expect(bridge.getCurrentTab(std.testing.allocator, "session-a") == null);
}

test "refreshTabWsUrl updates stale ws_url from /json/list" {
    // Start a fake Chrome /json/list server using the Zig 0.16 Io API
    const io = std.Io.Threaded.global_single_threaded.io();
    const address = net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var tcp_server = try net.IpAddress.listen(&address, io, .{});
    defer tcp_server.deinit(io);

    // Extract the port the OS assigned
    // Listen on a fixed port for testing
    const server_port: u16 = 19876;
    tcp_server.deinit(io);
    const fixed_addr = net.IpAddress.parseIp4("127.0.0.1", server_port) catch unreachable;
    tcp_server = try net.IpAddress.listen(&fixed_addr, io, .{});

    const fresh_ws = "ws://127.0.0.1:9222/devtools/page/NEW_WS_URL";
    const json_body = try std.fmt.allocPrint(std.testing.allocator,
        \\[{{"id":"tab-1","type":"page","url":"https://www.instagram.com/","title":"Instagram","webSocketDebuggerUrl":"{s}"}}]
    , .{fresh_ws});
    defer std.testing.allocator.free(json_body);

    const response = try std.fmt.allocPrint(std.testing.allocator, "HTTP/1.1 200 OK\r\nContent-Length:{d}\r\nContent-Type:application/json\r\nConnection:close\r\n\r\n{s}", .{ json_body.len, json_body });
    defer std.testing.allocator.free(response);

    // Server thread: accept one connection and serve the JSON response
    const ServerCtx = struct {
        server: *net.Server,
        resp: []const u8,
        io_val: std.Io,

        fn handle(ctx: *@This()) void {
            var stream = ctx.server.accept(ctx.io_val) catch return;
            defer stream.close(ctx.io_val);
            // Write using raw syscall (same pattern as router.zig)
            var written: usize = 0;
            while (written < ctx.resp.len) {
                const rc = std.c.write(stream.socket.handle, ctx.resp.ptr + written, ctx.resp.len - written);
                if (rc <= 0) break;
                written += @intCast(rc);
            }
        }
    };
    var srv_ctx = ServerCtx{ .server = &tcp_server, .resp = response, .io_val = io };
    const server_thread = try std.Thread.spawn(.{}, ServerCtx.handle, .{&srv_ctx});

    // Set up Bridge
    var bridge = Bridge.init(std.testing.allocator);
    defer bridge.deinit();
    bridge.cdp_host = "127.0.0.1";
    bridge.cdp_port = server_port;

    // Put a tab with a stale ws_url
    try bridge.putTab(.{
        .id = "tab-1",
        .url = "https://www.instagram.com/",
        .title = "Instagram",
        .ws_url = "ws://127.0.0.1:9222/devtools/page/OLD_DEAD_WS_URL",
        .created_at = 1000,
        .last_accessed = 1000,
    });

    // Verify initial ws_url is stale
    const tab_before = bridge.getTab("tab-1").?;
    try std.testing.expectEqualStrings("ws://127.0.0.1:9222/devtools/page/OLD_DEAD_WS_URL", tab_before.ws_url);

    // Call refreshTabWsUrl — this should fetch /json/list and update the ws_url
    bridge.refreshTabWsUrl("tab-1");

    // Verify the tab entry was updated with the fresh ws_url
    const tab_after = bridge.getTab("tab-1").?;
    try std.testing.expectEqualStrings(fresh_ws, tab_after.ws_url);

    server_thread.join();
}

/// Extract a simple JSON string value for a given field key, starting at `start`.
/// Returns the content between the quotes after the field's colon.
fn extractSimpleJsonString(json: []const u8, start: usize, field: []const u8) ?[]const u8 {
    const field_pos = std.mem.indexOfPos(u8, json, start, field) orelse return null;
    if (field_pos - start > 1000) return null;
    const colon = std.mem.indexOfScalarPos(u8, json, field_pos + field.len, ':') orelse return null;
    var i = colon + 1;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    if (i >= json.len or json[i] != '"') return null;
    const val_start = i + 1;
    const val_end = std.mem.indexOfScalarPos(u8, json, val_start, '"') orelse return null;
    return json[val_start..val_end];
}
