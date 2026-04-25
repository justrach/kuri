const std = @import("std");
const dom = @import("dom.zig");

pub const FallbackMode = enum {
    native_static,
    native_js_later,
    external_browser,

    pub fn label(self: FallbackMode) []const u8 {
        return switch (self) {
            .native_static => "native_static",
            .native_js_later => "native_js_later",
            .external_browser => "external_browser",
        };
    }
};

pub const Link = struct {
    text: []const u8,
    href: []const u8,
};

pub const DumpFormat = enum {
    summary,
    html,
    text,
    links,

    pub fn parse(value: []const u8) ?DumpFormat {
        if (std.mem.eql(u8, value, "summary")) return .summary;
        if (std.mem.eql(u8, value, "html")) return .html;
        if (std.mem.eql(u8, value, "text")) return .text;
        if (std.mem.eql(u8, value, "links")) return .links;
        return null;
    }

    pub fn label(self: DumpFormat) []const u8 {
        return switch (self) {
            .summary => "summary",
            .html => "html",
            .text => "text",
            .links => "links",
        };
    }
};

pub const Page = struct {
    requested_url: []const u8,
    url: []const u8,
    html: []const u8,
    dom: dom.Document,
    title: []const u8,
    text: []const u8,
    links: []Link,
    redirect_chain: []const []const u8,
    cookie_count: usize,
    status_code: u16,
    content_type: []const u8,
    fallback_mode: FallbackMode,
    pipeline: []const u8,
};

test "fallback labels stay stable" {
    try std.testing.expectEqualStrings("native_static", FallbackMode.native_static.label());
    try std.testing.expectEqualStrings("native_js_later", FallbackMode.native_js_later.label());
    try std.testing.expectEqualStrings("external_browser", FallbackMode.external_browser.label());
}

test "dump formats parse and label" {
    try std.testing.expectEqual(DumpFormat.summary, DumpFormat.parse("summary").?);
    try std.testing.expectEqual(DumpFormat.html, DumpFormat.parse("html").?);
    try std.testing.expectEqual(DumpFormat.text, DumpFormat.parse("text").?);
    try std.testing.expectEqual(DumpFormat.links, DumpFormat.parse("links").?);
    try std.testing.expectEqual(@as(?DumpFormat, null), DumpFormat.parse("wat"));
    try std.testing.expectEqualStrings("links", DumpFormat.links.label());
}
