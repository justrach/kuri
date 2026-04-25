const std = @import("std");
const core = @import("core.zig");
const shell = @import("shell.zig");

pub const BrowserRuntime = core.BrowserRuntime;
pub const RuntimeShape = core.RuntimeShape;
pub const RuntimeStage = core.RuntimeStage;

pub fn statusText(allocator: std.mem.Allocator) ![]const u8 {
    const runtime = BrowserRuntime.init(allocator);
    return shell.renderStatusText(allocator, runtime.shape());
}

pub fn roadmapText(allocator: std.mem.Allocator) ![]const u8 {
    return shell.renderRoadmapText(allocator);
}

pub fn renderUrlText(allocator: std.mem.Allocator, url: []const u8, format: model.DumpFormat, selector: ?[]const u8) ![]const u8 {
    const runtime = BrowserRuntime.init(allocator);
    const page = try runtime.loadPage(url);
    return shell.renderPageWithFormat(allocator, page, format, selector);
}

const model = @import("model.zig");

test "shape reports scaffold defaults" {
    const runtime = BrowserRuntime.init(std.testing.allocator);
    const shape = runtime.shape();
    try std.testing.expectEqualStrings("standalone experiment", shape.mode);
    try std.testing.expectEqualStrings("stateful fetcher with redirects, cookies, and curl fallback", shape.transport);
}
