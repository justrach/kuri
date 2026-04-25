const std = @import("std");

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

pub const Page = struct {
    url: []const u8,
    title: []const u8,
    text: []const u8,
    links: []Link,
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
