const std = @import("std");

pub const desktop_user_agent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36";

pub const Options = struct {
    kuri_base: []const u8 = "http://127.0.0.1:8080",
    out_path: ?[]const u8 = null,
    format: []const u8 = "png",
    quality: u8 = 80,
    full: bool = false,
    compress: bool = false,
    close_tab: bool = true,
    wait_ms: u64 = 0,
    wait_selector: ?[]const u8 = null,
    wait_timeout_ms: u64 = 10_000,
    user_agent: ?[]const u8 = null,
};

pub const Result = struct {
    path: []const u8,
    bytes: usize,
    tab_id: []const u8,
    format: []const u8,
    quality: u8,
    original_bytes: ?usize = null,
    saved_bytes: i64 = 0,
    saved_percent: i64 = 0,
    backend: []const u8 = "kuri-cdp-fallback",
};

const Capture = struct {
    format: []const u8,
    quality: u8,
    bytes: []const u8,
};

const QueryParam = struct {
    key: []const u8,
    value: []const u8,
};

pub fn captureUrl(allocator: std.mem.Allocator, url: []const u8, options: Options) !Result {
    const initial_url = if (options.user_agent != null) "about:blank" else url;
    const tab_url = try buildUrl(allocator, options.kuri_base, "/tab/new", &.{
        .{ .key = "url", .value = initial_url },
        .{ .key = "wait", .value = "true" },
    });
    const tab_body = httpGet(allocator, tab_url) catch return error.OpenTabFailed;
    const tab_id = try jsonStringField(allocator, tab_body, "tab_id");
    errdefer allocator.free(tab_id);

    if (options.close_tab) {
        errdefer closeTab(allocator, options.kuri_base, tab_id);
    }

    if (options.user_agent) |user_agent| {
        setTabUserAgent(allocator, options.kuri_base, tab_id, user_agent) catch return error.SetUserAgentFailed;
        navigateTab(allocator, options.kuri_base, tab_id, url) catch return error.NavigateTabFailed;
        waitTabReady(allocator, options.kuri_base, tab_id, options.wait_timeout_ms) catch return error.WaitTabReadyFailed;
    }
    if (options.wait_selector) |selector| {
        waitTabSelector(allocator, options.kuri_base, tab_id, selector, options.wait_timeout_ms) catch return error.WaitSelectorFailed;
    }
    if (options.wait_ms > 0) {
        sleepMs(options.wait_ms);
    }

    var original_bytes: ?usize = null;
    const capture = if (options.compress) blk: {
        const png = captureTabScreenshotWithRetry(allocator, options.kuri_base, tab_id, "png", 80, options.full) catch return error.CaptureScreenshotFailed;
        const jpeg = captureTabScreenshotWithRetry(allocator, options.kuri_base, tab_id, "jpeg", options.quality, options.full) catch return error.CaptureScreenshotFailed;
        original_bytes = png.bytes.len;
        break :blk if (jpeg.bytes.len < png.bytes.len) jpeg else png;
    } else captureTabScreenshotWithRetry(allocator, options.kuri_base, tab_id, options.format, options.quality, options.full) catch return error.CaptureScreenshotFailed;

    const path = try outputPathForCapture(allocator, options.out_path, capture.format, options.compress);
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = capture.bytes,
    });

    if (options.close_tab) closeTab(allocator, options.kuri_base, tab_id);

    const saved = if (original_bytes) |original| @as(i64, @intCast(original)) - @as(i64, @intCast(capture.bytes.len)) else 0;
    return .{
        .path = path,
        .bytes = capture.bytes.len,
        .tab_id = tab_id,
        .format = capture.format,
        .quality = capture.quality,
        .original_bytes = original_bytes,
        .saved_bytes = saved,
        .saved_percent = if (original_bytes) |original| percentSigned(saved, original) else 0,
    };
}

fn captureTabScreenshotWithRetry(
    allocator: std.mem.Allocator,
    kuri_base: []const u8,
    tab_id: []const u8,
    format: []const u8,
    quality: u8,
    full: bool,
) !Capture {
    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        return captureTabScreenshot(allocator, kuri_base, tab_id, format, quality, full) catch |err| {
            if (attempt == 2) return err;
            sleepMs(5_000);
            continue;
        };
    }
    return error.CaptureScreenshotFailed;
}

fn captureTabScreenshot(
    allocator: std.mem.Allocator,
    kuri_base: []const u8,
    tab_id: []const u8,
    format: []const u8,
    quality: u8,
    full: bool,
) !Capture {
    const quality_text = try std.fmt.allocPrint(allocator, "{d}", .{quality});
    const screenshot_url = try buildUrl(allocator, kuri_base, "/screenshot", &.{
        .{ .key = "tab_id", .value = tab_id },
        .{ .key = "format", .value = format },
        .{ .key = "quality", .value = quality_text },
        .{ .key = "full", .value = if (full) "true" else "false" },
    });
    const screenshot_body = try httpGet(allocator, screenshot_url);
    const encoded = try jsonStringField(allocator, screenshot_body, "data");
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, decoded_len);
    try std.base64.standard.Decoder.decode(decoded, encoded);

    return .{
        .format = format,
        .quality = quality,
        .bytes = decoded,
    };
}

fn setTabUserAgent(allocator: std.mem.Allocator, kuri_base: []const u8, tab_id: []const u8, user_agent: []const u8) !void {
    const set_url = try buildUrl(allocator, kuri_base, "/set/useragent", &.{
        .{ .key = "tab_id", .value = tab_id },
        .{ .key = "ua", .value = user_agent },
    });
    _ = try httpGet(allocator, set_url);
}

fn navigateTab(allocator: std.mem.Allocator, kuri_base: []const u8, tab_id: []const u8, url: []const u8) !void {
    const navigate_url = try buildUrl(allocator, kuri_base, "/navigate", &.{
        .{ .key = "tab_id", .value = tab_id },
        .{ .key = "url", .value = url },
        .{ .key = "bot_detect", .value = "false" },
    });
    _ = try httpGet(allocator, navigate_url);
}

fn waitTabReady(allocator: std.mem.Allocator, kuri_base: []const u8, tab_id: []const u8, timeout_ms: u64) !void {
    const timeout_text = try std.fmt.allocPrint(allocator, "{d}", .{timeout_ms});
    const wait_url = try buildUrl(allocator, kuri_base, "/wait", &.{
        .{ .key = "tab_id", .value = tab_id },
        .{ .key = "timeout", .value = timeout_text },
    });
    _ = try httpGet(allocator, wait_url);
}

fn waitTabSelector(
    allocator: std.mem.Allocator,
    kuri_base: []const u8,
    tab_id: []const u8,
    selector: []const u8,
    timeout_ms: u64,
) !void {
    const timeout_text = try std.fmt.allocPrint(allocator, "{d}", .{timeout_ms});
    const wait_url = try buildUrl(allocator, kuri_base, "/wait", &.{
        .{ .key = "tab_id", .value = tab_id },
        .{ .key = "selector", .value = selector },
        .{ .key = "timeout", .value = timeout_text },
    });
    _ = try httpGet(allocator, wait_url);
}

fn sleepMs(ms: u64) void {
    const ns = ms * std.time.ns_per_ms;
    const ts = std.c.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&ts, null);
}

fn closeTab(allocator: std.mem.Allocator, kuri_base: []const u8, tab_id: []const u8) void {
    const close_url = buildUrl(allocator, kuri_base, "/tab/close", &.{
        .{ .key = "tab_id", .value = tab_id },
    }) catch return;
    _ = httpGet(allocator, close_url) catch {};
}

fn httpGet(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
    };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();
    var response = try req.receiveHead(&.{});
    if (response.head.status != .ok) return error.UnexpectedHttpStatus;

    var body: std.ArrayList(u8) = .empty;
    var transfer_buf: [8192]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);
    try reader.appendRemainingUnlimited(allocator, &body);
    return body.items;
}

fn buildUrl(allocator: std.mem.Allocator, base_url: []const u8, path: []const u8, params: []const QueryParam) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, std.mem.trimEnd(u8, base_url, "/"));
    try out.appendSlice(allocator, path);

    if (params.len > 0) {
        try out.append(allocator, '?');
        for (params, 0..) |param, index| {
            if (index > 0) try out.append(allocator, '&');
            try appendUrlEncoded(allocator, &out, param.key);
            try out.append(allocator, '=');
            try appendUrlEncoded(allocator, &out, param.value);
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn appendUrlEncoded(allocator: std.mem.Allocator, out: *std.ArrayList(u8), input: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0x0F]);
        }
    }
}

fn jsonStringField(allocator: std.mem.Allocator, json: []const u8, field: []const u8) ![]const u8 {
    const needle = try std.fmt.allocPrint(allocator, "\"{s}\"", .{field});
    const field_pos = std.mem.indexOf(u8, json, needle) orelse return error.JsonFieldMissing;
    const colon = std.mem.indexOfScalarPos(u8, json, field_pos + needle.len, ':') orelse return error.JsonFieldMissing;
    const first_quote = std.mem.indexOfScalarPos(u8, json, colon + 1, '"') orelse return error.JsonFieldMissing;

    var out: std.ArrayList(u8) = .empty;
    var i = first_quote + 1;
    while (i < json.len) : (i += 1) {
        const c = json[i];
        if (c == '"') return try out.toOwnedSlice(allocator);
        if (c == '\\') {
            i += 1;
            if (i >= json.len) return error.InvalidJsonString;
            try out.append(allocator, switch (json[i]) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'b' => 0x08,
                'f' => 0x0c,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => json[i],
            });
        } else {
            try out.append(allocator, c);
        }
    }
    return error.InvalidJsonString;
}

fn defaultPath(allocator: std.mem.Allocator, format: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "kuri-browser-screenshot-{d}.{s}", .{ milliTimestamp(), extensionForFormat(format) });
}

fn outputPathForCapture(allocator: std.mem.Allocator, requested_path: ?[]const u8, format: []const u8, compress: bool) ![]const u8 {
    const requested = requested_path orelse return defaultPath(allocator, format);
    if (!compress or pathExtensionMatchesFormat(requested, format)) {
        return allocator.dupe(u8, requested);
    }
    return replaceExtension(allocator, requested, extensionForFormat(format));
}

fn extensionForFormat(format: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(format, "jpeg")) return "jpg";
    return "png";
}

fn pathExtensionMatchesFormat(path: []const u8, format: []const u8) bool {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    const start = if (slash == 0 and (path.len == 0 or path[0] != '/')) 0 else slash + 1;
    const dot = std.mem.lastIndexOfScalar(u8, path[start..], '.') orelse return false;
    const ext = path[start + dot + 1 ..];
    if (std.ascii.eqlIgnoreCase(format, "jpeg")) {
        return std.ascii.eqlIgnoreCase(ext, "jpg") or std.ascii.eqlIgnoreCase(ext, "jpeg");
    }
    return std.ascii.eqlIgnoreCase(ext, extensionForFormat(format));
}

fn replaceExtension(allocator: std.mem.Allocator, path: []const u8, extension: []const u8) ![]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    const start = if (slash == 0 and (path.len == 0 or path[0] != '/')) 0 else slash + 1;
    const dot = std.mem.lastIndexOfScalar(u8, path[start..], '.');
    const base_end = if (dot) |offset| start + offset else path.len;
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ path[0..base_end], extension });
}

fn percentSigned(saved_bytes: i64, original_bytes: usize) i64 {
    if (original_bytes == 0) return 0;
    const original: i64 = @intCast(original_bytes);
    const abs_saved = if (saved_bytes < 0) -saved_bytes else saved_bytes;
    const rounded = @divTrunc(abs_saved * 100 + @divTrunc(original, 2), original);
    return if (saved_bytes < 0) -rounded else rounded;
}

fn milliTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

test "buildUrl encodes query values" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const url = try buildUrl(arena_impl.allocator(), "http://127.0.0.1:8080/", "/tab/new", &.{
        .{ .key = "url", .value = "https://example.com/a b?x=1&y=2" },
    });
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/tab/new?url=https%3A%2F%2Fexample.com%2Fa%20b%3Fx%3D1%26y%3D2", url);
}

test "jsonStringField extracts escaped values" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const value = try jsonStringField(arena_impl.allocator(), "{\"result\":{\"data\":\"a\\/b\\n\"}}", "data");
    try std.testing.expectEqualStrings("a/b\n", value);
}

test "percentSigned rounds compression savings" {
    try std.testing.expectEqual(@as(i64, 25), percentSigned(25, 100));
    try std.testing.expectEqual(@as(i64, -25), percentSigned(-25, 100));
}

test "compressed output path follows selected format" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    try std.testing.expectEqualStrings("shot.jpg", try outputPathForCapture(arena, "shot.png", "jpeg", true));
    try std.testing.expectEqualStrings("shot.png", try outputPathForCapture(arena, "shot.png", "png", true));
    try std.testing.expectEqualStrings("dir/shot.jpg", try outputPathForCapture(arena, "dir/shot.png", "jpeg", true));
    try std.testing.expectEqualStrings("shot.png", try outputPathForCapture(arena, "shot.png", "jpeg", false));
}
