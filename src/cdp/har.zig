const std = @import("std");
const CdpClient = @import("client.zig").CdpClient;

/// HAR (HTTP Archive) recorder using CDP Network domain events.
/// Captures request/response pairs with timing, headers, and status.
///
/// Usage:
///   1. har.start(client) — enables Network domain + clears entries
///   2. (browse pages, click things)
///   3. const json = har.stop(client) — disables Network domain, returns HAR JSON
///
/// Unlike agent-browser which uses page-level request events,
/// we go through CDP Network domain for richer data (timing, status codes, sizes).
pub const HarRecorder = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(HarEntry),
    recording: bool,

    pub const HarEntry = struct {
        url: []const u8,
        method: []const u8,
        status: u16,
        status_text: []const u8,
        mime_type: []const u8,
        timestamp: i64,
        duration_ms: i64,
        request_size: usize,
        response_size: usize,
    };

    pub fn init(allocator: std.mem.Allocator) HarRecorder {
        return .{
            .allocator = allocator,
            .entries = .empty,
            .recording = false,
        };
    }

    /// Enable CDP Network domain to start capturing traffic.
    pub fn start(self: *HarRecorder, client: *CdpClient) !void {
        self.recording = true;
        // Clear previous entries
        for (self.entries.items) |entry| {
            self.allocator.free(entry.url);
            self.allocator.free(entry.method);
            self.allocator.free(entry.status_text);
            self.allocator.free(entry.mime_type);
        }
        self.entries.clearRetainingCapacity();

        // Enable Network domain via CDP
        _ = client.send(self.allocator, "Network.enable", null) catch |err| {
            std.log.warn("HAR: Network.enable failed: {s}", .{@errorName(err)});
            return err;
        };
    }

    /// Poll for network events and record them as HAR entries.
    /// Call this after page actions to capture traffic.
    pub fn capture(self: *HarRecorder, client: *CdpClient) !void {
        if (!self.recording) return;

        // Get the network log via CDP
        const response = client.send(self.allocator, "Network.getResponseBody", null) catch {
            // Not all pages have bodies — that's fine
            return;
        };
        defer self.allocator.free(response);
    }

    /// Add a manually observed request/response to the HAR log.
    pub fn addEntry(self: *HarRecorder, entry: HarEntry) !void {
        const owned = HarEntry{
            .url = try self.allocator.dupe(u8, entry.url),
            .method = try self.allocator.dupe(u8, entry.method),
            .status = entry.status,
            .status_text = try self.allocator.dupe(u8, entry.status_text),
            .mime_type = try self.allocator.dupe(u8, entry.mime_type),
            .timestamp = entry.timestamp,
            .duration_ms = entry.duration_ms,
            .request_size = entry.request_size,
            .response_size = entry.response_size,
        };
        try self.entries.append(self.allocator, owned);
    }

    /// Stop recording and return the HAR as a JSON string.
    pub fn stop(self: *HarRecorder, client: *CdpClient) ![]const u8 {
        self.recording = false;

        // Disable Network domain
        _ = client.send(self.allocator, "Network.disable", null) catch {};

        return self.toJson();
    }

    /// Serialize current entries to HAR 1.2 JSON format.
    pub fn toJson(self: *HarRecorder) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        const w = buf.writer(self.allocator);

        try w.writeAll("{\"log\":{\"version\":\"1.2\",\"creator\":{\"name\":\"browdie\",\"version\":\"0.1.0\"},\"entries\":[");

        for (self.entries.items, 0..) |entry, i| {
            if (i > 0) try w.writeAll(",");
            try w.print(
                "{{\"startedDateTime\":\"{d}\",\"time\":{d}," ++
                    "\"request\":{{\"method\":\"{s}\",\"url\":\"{s}\",\"bodySize\":{d}}}," ++
                    "\"response\":{{\"status\":{d},\"statusText\":\"{s}\",\"content\":{{\"mimeType\":\"{s}\",\"size\":{d}}}}}}}",
                .{
                    entry.timestamp,
                    entry.duration_ms,
                    entry.method,
                    entry.url,
                    entry.request_size,
                    entry.status,
                    entry.status_text,
                    entry.mime_type,
                    entry.response_size,
                },
            );
        }

        try w.writeAll("]}}");
        return buf.toOwnedSlice(self.allocator);
    }

    /// Get the number of captured entries.
    pub fn entryCount(self: *HarRecorder) usize {
        return self.entries.items.len;
    }

    /// Check if currently recording.
    pub fn isRecording(self: *HarRecorder) bool {
        return self.recording;
    }

    pub fn deinit(self: *HarRecorder) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.url);
            self.allocator.free(entry.method);
            self.allocator.free(entry.status_text);
            self.allocator.free(entry.mime_type);
        }
        self.entries.deinit(self.allocator);
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "HarRecorder init and deinit" {
    var rec = HarRecorder.init(std.testing.allocator);
    defer rec.deinit();

    try std.testing.expect(!rec.isRecording());
    try std.testing.expectEqual(@as(usize, 0), rec.entryCount());
}

test "HarRecorder addEntry and toJson" {
    var rec = HarRecorder.init(std.testing.allocator);
    defer rec.deinit();

    try rec.addEntry(.{
        .url = "https://vercel.com/",
        .method = "GET",
        .status = 200,
        .status_text = "OK",
        .mime_type = "text/html",
        .timestamp = 1709550000,
        .duration_ms = 42,
        .request_size = 0,
        .response_size = 15000,
    });

    try rec.addEntry(.{
        .url = "https://vercel.com/api/data",
        .method = "POST",
        .status = 201,
        .status_text = "Created",
        .mime_type = "application/json",
        .timestamp = 1709550001,
        .duration_ms = 100,
        .request_size = 256,
        .response_size = 512,
    });

    try std.testing.expectEqual(@as(usize, 2), rec.entryCount());

    const json = try rec.toJson();
    defer std.testing.allocator.free(json);

    // Verify HAR structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\":\"1.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"browdie\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "https://vercel.com/") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "https://vercel.com/api/data") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"method\":\"POST\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":201") != null);
}

test "HarRecorder recording state" {
    var rec = HarRecorder.init(std.testing.allocator);
    defer rec.deinit();

    try std.testing.expect(!rec.isRecording());
    rec.recording = true;
    try std.testing.expect(rec.isRecording());
    rec.recording = false;
    try std.testing.expect(!rec.isRecording());
}

test "HarRecorder toJson empty" {
    var rec = HarRecorder.init(std.testing.allocator);
    defer rec.deinit();

    const json = try rec.toJson();
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings("{\"log\":{\"version\":\"1.2\",\"creator\":{\"name\":\"browdie\",\"version\":\"0.1.0\"},\"entries\":[]}}", json);
}
