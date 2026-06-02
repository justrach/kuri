const std = @import("std");
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

    pub fn init(allocator: std.mem.Allocator) RefCache {
        return .{
            .refs = std.StringHashMap(u32).init(allocator),
            .node_count = 0,
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
            .mu = .{},
        };
    }

    pub fn deinit(self: *Bridge) void {
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

        var snap_it = self.snapshots.valueIterator();
        while (snap_it.next()) |cache| {
            cache.deinit();
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
            if (self.snapshots.getPtr(tab_id)) |cache| cache.deinit();
            _ = self.snapshots.remove(tab_id);
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

        if (self.snapshots.getPtr(tab_id)) |cache| cache.deinit();
        _ = self.snapshots.remove(tab_id);
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

    /// Get or create a CDP client for a tab.
    /// Returns a stable heap-allocated pointer that survives HashMap resizes.
    pub fn getCdpClient(self: *Bridge, tab_id: []const u8) ?*CdpClient {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.cdp_clients.get(tab_id)) |client| {
            return client;
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
