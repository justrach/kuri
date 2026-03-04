const std = @import("std");
const protocol = @import("protocol.zig");
const CdpClient = @import("client.zig").CdpClient;

/// Action kinds supported by the /action endpoint
pub const ActionKind = enum {
    click,
    @"type",
    fill,
    press,
    focus,
    hover,
    select,
    scroll,

    pub fn fromString(s: []const u8) ?ActionKind {
        const map = std.StaticStringMap(ActionKind).initComptime(.{
            .{ "click", .click },
            .{ "type", .@"type" },
            .{ "fill", .fill },
            .{ "press", .press },
            .{ "focus", .focus },
            .{ "hover", .hover },
            .{ "select", .select },
            .{ "scroll", .scroll },
        });
        return map.get(s);
    }
};

test "ActionKind fromString" {
    try std.testing.expectEqual(ActionKind.click, ActionKind.fromString("click").?);
    try std.testing.expectEqual(ActionKind.scroll, ActionKind.fromString("scroll").?);
    try std.testing.expectEqual(@as(?ActionKind, null), ActionKind.fromString("invalid"));
}
