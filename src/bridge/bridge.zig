const std = @import("std");
const CdpClient = @import("../cdp/client.zig").CdpClient;

pub const TabEntry = struct {
    id: []const u8,
    url: []const u8,
    title: []const u8,
    ws_url: []const u8,
    created_at: i64,
    last_accessed: i64,
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

    pub fn deinit(self: *RefCache) void {
        self.refs.deinit();
    }
};

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    tabs: std.StringHashMap(TabEntry),
    snapshots: std.StringHashMap(RefCache),
    cdp_clients: std.StringHashMap(CdpClient),
    mu: std.Thread.RwLock,

    pub fn init(allocator: std.mem.Allocator) Bridge {
        return .{
            .allocator = allocator,
            .tabs = std.StringHashMap(TabEntry).init(allocator),
            .snapshots = std.StringHashMap(RefCache).init(allocator),
            .cdp_clients = std.StringHashMap(CdpClient).init(allocator),
            .mu = .{},
        };
    }

    pub fn deinit(self: *Bridge) void {
        var cdp_it = self.cdp_clients.valueIterator();
        while (cdp_it.next()) |client| {
            client.deinit();
        }
        self.cdp_clients.deinit();

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

        // Grab owned strings before removing from map
        const tab = self.tabs.get(tab_id) orelse {
            if (self.snapshots.getPtr(tab_id)) |cache| cache.deinit();
            _ = self.snapshots.remove(tab_id);
            if (self.cdp_clients.getPtr(tab_id)) |client| client.deinit();
            _ = self.cdp_clients.remove(tab_id);
            return;
        };

        _ = self.tabs.remove(tab_id);

        self.allocator.free(tab.id);
        self.allocator.free(tab.url);
        self.allocator.free(tab.title);
        self.allocator.free(tab.ws_url);

        if (self.snapshots.getPtr(tab_id)) |cache| cache.deinit();
        _ = self.snapshots.remove(tab_id);
        if (self.cdp_clients.getPtr(tab_id)) |client| client.deinit();
        _ = self.cdp_clients.remove(tab_id);
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

    /// Get or create a CDP client for a tab.
    pub fn getCdpClient(self: *Bridge, tab_id: []const u8) ?*CdpClient {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.cdp_clients.getPtr(tab_id)) |client| {
            return client;
        }

        const tab = self.tabs.get(tab_id) orelse return null;
        if (tab.ws_url.len == 0) return null;

        const client = CdpClient.init(self.allocator, tab.ws_url);
        self.cdp_clients.put(tab_id, client) catch return null;
        return self.cdp_clients.getPtr(tab_id);
    }
};

test "bridge init/deinit" {
    var bridge = Bridge.init(std.testing.allocator);
    defer bridge.deinit();
    try std.testing.expectEqual(@as(usize, 0), bridge.tabCount());
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
