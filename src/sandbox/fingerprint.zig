// fingerprint.zig — browser fingerprint pool for sandboxed bundle replay.
//
// A Fingerprint is the bundle of values an anti-bot bundle reads from the
// browser to decide whether the runtime "looks real": navigator.userAgent,
// screen geometry, canvas/WebGL hash, audio context hash, font list, etc.
//
// Phase 1 ships ONE entry sampled from a real Apple Silicon Chrome 131 install.
// Coherence matters more than diversity at this stage — vendors check that
// the userAgent, platform, screen, and webgl-renderer are mutually consistent.

const std = @import("std");

pub const Screen = struct {
    width: u32 = 1920,
    height: u32 = 1080,
    avail_width: u32 = 1920,
    avail_height: u32 = 1055,
    color_depth: u8 = 24,
    pixel_depth: u8 = 24,
};

pub const Fingerprint = struct {
    ua: []const u8,
    platform: []const u8,
    vendor: []const u8 = "Google Inc.",
    language: []const u8 = "en-US",
    languages: []const []const u8 = &.{ "en-US", "en" },
    hardware_concurrency: u32 = 8,
    device_memory: u32 = 8,
    max_touch_points: u32 = 0,
    timezone: []const u8 = "America/Los_Angeles",
    device_pixel_ratio: f32 = 2.0,
    screen: Screen = .{},
    canvas_hash: []const u8 = "",
    webgl_vendor: []const u8 = "Google Inc. (Apple)",
    webgl_renderer: []const u8 = "ANGLE (Apple, Apple M1 Pro, OpenGL 4.1)",
    audio_ctx_hash: u64 = 124013,
    fonts: []const []const u8 = &.{ "Arial", "Helvetica", "Times", "Courier", "Monaco" },
    plugins: []const PluginEntry = &.{},
    referrer: []const u8 = "",
    target_origin: []const u8 = "",
    target_href: []const u8 = "",

    pub const PluginEntry = struct {
        name: []const u8,
        filename: []const u8,
        description: []const u8,
    };

    pub fn builtinChromeMacARM() Fingerprint {
        return .{
            .ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            .platform = "MacIntel",
            .canvas_hash = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAen63NgAAAAASUVORK5CYII=",
        };
    }

    pub fn builtinChromeWindows() Fingerprint {
        return .{
            .ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            .platform = "Win32",
            .timezone = "America/New_York",
            .webgl_vendor = "Google Inc. (NVIDIA)",
            .webgl_renderer = "ANGLE (NVIDIA, NVIDIA GeForce RTX 3070 Direct3D11 vs_5_0 ps_5_0, D3D11)",
            .canvas_hash = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAen63NgAAAAASUVORK5CYII=",
        };
    }

    /// Serialize this fingerprint as a JSON object literal suitable for
    /// `globalThis.__fingerprint = <json>`.
    pub fn serialize(self: Fingerprint, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        try buf.append(allocator, '{');
        try writeKvStr(allocator, &buf, "ua", self.ua, false);
        try writeKvStr(allocator, &buf, "platform", self.platform, true);
        try writeKvStr(allocator, &buf, "vendor", self.vendor, true);
        try writeKvStr(allocator, &buf, "language", self.language, true);

        try buf.appendSlice(allocator, ",\"languages\":[");
        for (self.languages, 0..) |l, i| {
            if (i > 0) try buf.append(allocator, ',');
            try writeStringValue(allocator, &buf, l);
        }
        try buf.append(allocator, ']');

        try writeKvU32(allocator, &buf, "hardwareConcurrency", self.hardware_concurrency);
        try writeKvU32(allocator, &buf, "deviceMemory", self.device_memory);
        try writeKvU32(allocator, &buf, "maxTouchPoints", self.max_touch_points);
        try writeKvStr(allocator, &buf, "timezone", self.timezone, true);
        try writeKvF64(allocator, &buf, "devicePixelRatio", @floatCast(self.device_pixel_ratio));

        try buf.print(allocator, ",\"screen\":{{\"width\":{d},\"height\":{d},\"availWidth\":{d},\"availHeight\":{d},\"colorDepth\":{d},\"pixelDepth\":{d}}}", .{
            self.screen.width,    self.screen.height,
            self.screen.avail_width, self.screen.avail_height,
            self.screen.color_depth, self.screen.pixel_depth,
        });

        try writeKvStr(allocator, &buf, "canvasHash", self.canvas_hash, true);
        try writeKvStr(allocator, &buf, "webglVendor", self.webgl_vendor, true);
        try writeKvStr(allocator, &buf, "webglRenderer", self.webgl_renderer, true);
        try writeKvU64(allocator, &buf, "audioCtxHash", self.audio_ctx_hash);

        try buf.appendSlice(allocator, ",\"fonts\":[");
        for (self.fonts, 0..) |f, i| {
            if (i > 0) try buf.append(allocator, ',');
            try writeStringValue(allocator, &buf, f);
        }
        try buf.append(allocator, ']');

        try buf.appendSlice(allocator, ",\"plugins\":[");
        for (self.plugins, 0..) |p, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.append(allocator, '{');
            try writeKvStr(allocator, &buf, "name", p.name, false);
            try writeKvStr(allocator, &buf, "filename", p.filename, true);
            try writeKvStr(allocator, &buf, "description", p.description, true);
            try buf.append(allocator, '}');
        }
        try buf.append(allocator, ']');

        try writeKvStr(allocator, &buf, "referrer", self.referrer, true);
        try writeKvStr(allocator, &buf, "targetOrigin", self.target_origin, true);
        try writeKvStr(allocator, &buf, "targetHref", self.target_href, true);
        try buf.append(allocator, '}');

        return buf.toOwnedSlice(allocator);
    }
};

fn writeKvStr(a: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: []const u8, prefix_comma: bool) !void {
    if (prefix_comma) try buf.append(a, ',');
    try buf.append(a, '"');
    try buf.appendSlice(a, key);
    try buf.appendSlice(a, "\":");
    try writeStringValue(a, buf, value);
}

fn writeKvU32(a: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: u32) !void {
    try buf.append(a, ',');
    try buf.append(a, '"');
    try buf.appendSlice(a, key);
    try buf.appendSlice(a, "\":");
    try buf.print(a, "{d}", .{value});
}

fn writeKvU64(a: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: u64) !void {
    try buf.append(a, ',');
    try buf.append(a, '"');
    try buf.appendSlice(a, key);
    try buf.appendSlice(a, "\":");
    try buf.print(a, "{d}", .{value});
}

fn writeKvF64(a: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: f64) !void {
    try buf.append(a, ',');
    try buf.append(a, '"');
    try buf.appendSlice(a, key);
    try buf.appendSlice(a, "\":");
    try buf.print(a, "{d}", .{value});
}

fn writeStringValue(a: std.mem.Allocator, buf: *std.ArrayList(u8), value: []const u8) !void {
    try buf.append(a, '"');
    for (value) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try buf.print(a, "\\u{x:0>4}", .{c}),
            else => try buf.append(a, c),
        }
    }
    try buf.append(a, '"');
}

test "serialize fingerprint produces valid JSON" {
    const a = std.testing.allocator;
    var fp = Fingerprint.builtinChromeMacARM();
    fp.target_origin = "https://example.com";
    fp.target_href = "https://example.com/";

    const json = try fp.serialize(a);
    defer a.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;
    try std.testing.expect(obj.contains("ua"));
    try std.testing.expect(obj.contains("screen"));
    try std.testing.expect(obj.get("screen").?.object.get("width").?.integer == 1920);
}
