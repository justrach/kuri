const std = @import("std");

pub const Entry = struct {
    started_ms: i64,
    duration_ms: i64,
    method: []const u8,
    url: []const u8,
    status: u16,
    status_text: []const u8,
    mime_type: []const u8,
    request_body_size: usize,
    request_body_text: []const u8,
    response_body_size: usize,
    redirect_url: []const u8,
};

pub fn deinitEntry(allocator: std.mem.Allocator, entry: *Entry) void {
    allocator.free(entry.method);
    allocator.free(entry.url);
    allocator.free(entry.status_text);
    allocator.free(entry.mime_type);
    if (entry.request_body_text.len > 0) allocator.free(entry.request_body_text);
    if (entry.redirect_url.len > 0) allocator.free(entry.redirect_url);
}

pub fn toJson(allocator: std.mem.Allocator, entries: []const Entry) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "{\"log\":{\"version\":\"1.2\",\"creator\":{\"name\":\"kuri-browser\",\"version\":\"0.0.0\"},\"entries\":[");

    for (entries, 0..) |entry, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"startedDateTime\":");
        const iso_string = try formatIso8601(allocator, entry.started_ms);
        defer allocator.free(iso_string);
        try appendJsonString(allocator, &out, iso_string);
        try out.appendSlice(allocator, ",\"time\":");
        try out.print(allocator, "{d}", .{entry.duration_ms});
        try out.appendSlice(allocator, ",\"request\":{\"method\":");
        try appendJsonString(allocator, &out, entry.method);
        try out.appendSlice(allocator, ",\"url\":");
        try appendJsonString(allocator, &out, entry.url);
        try out.appendSlice(allocator, ",\"httpVersion\":\"HTTP/1.1\",\"headers\":[],\"queryString\":[],\"headersSize\":-1,\"bodySize\":");
        try out.print(allocator, "{d}", .{entry.request_body_size});
        if (entry.request_body_text.len > 0) {
            try out.appendSlice(allocator, ",\"postData\":{\"mimeType\":\"application/x-www-form-urlencoded\",\"text\":");
            try appendJsonString(allocator, &out, entry.request_body_text);
            try out.append(allocator, '}');
        }
        try out.appendSlice(allocator, "},\"response\":{\"status\":");
        try out.print(allocator, "{d}", .{entry.status});
        try out.appendSlice(allocator, ",\"statusText\":");
        try appendJsonString(allocator, &out, entry.status_text);
        try out.appendSlice(allocator, ",\"httpVersion\":\"HTTP/1.1\",\"headers\":[],\"redirectURL\":");
        try appendJsonString(allocator, &out, entry.redirect_url);
        try out.appendSlice(allocator, ",\"headersSize\":-1,\"bodySize\":");
        try out.print(allocator, "{d}", .{entry.response_body_size});
        try out.appendSlice(allocator, ",\"content\":{\"size\":");
        try out.print(allocator, "{d}", .{entry.response_body_size});
        try out.appendSlice(allocator, ",\"mimeType\":");
        try appendJsonString(allocator, &out, entry.mime_type);
        try out.appendSlice(allocator, "}},\"cache\":{},\"timings\":{\"send\":0,\"wait\":");
        try out.print(allocator, "{d}", .{entry.duration_ms});
        try out.appendSlice(allocator, ",\"receive\":0}}");
    }

    try out.appendSlice(allocator, "]}}");
    return try out.toOwnedSlice(allocator);
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => if (c < 0x20) {
                try out.print(allocator, "\\u{X:0>4}", .{c});
            } else {
                try out.append(allocator, c);
            },
        }
    }
    try out.append(allocator, '"');
}

fn formatIso8601(allocator: std.mem.Allocator, started_ms: i64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{started_ms});
}

test "toJson emits minimal har log" {
    const entries = [_]Entry{
        .{
            .started_ms = 1_700_000_000_000,
            .duration_ms = 42,
            .method = "GET",
            .url = "https://example.com",
            .status = 200,
            .status_text = "OK",
            .mime_type = "text/html",
            .request_body_size = 0,
            .request_body_text = "",
            .response_body_size = 1234,
            .redirect_url = "",
        },
    };

    const json = try toJson(std.testing.allocator, &entries);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\":\"1.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"url\":\"https://example.com\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":200") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mimeType\":\"text/html\"") != null);
}
