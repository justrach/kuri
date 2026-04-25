const std = @import("std");
const core = @import("core.zig");
const render = @import("render.zig");
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

pub fn submitFormText(
    allocator: std.mem.Allocator,
    url: []const u8,
    form_index: usize,
    overrides: []const model.FieldInput,
    format: model.DumpFormat,
    selector: ?[]const u8,
) ![]const u8 {
    const runtime = BrowserRuntime.init(allocator);
    const page = try runtime.submitForm(url, form_index, overrides);
    return shell.renderPageWithFormat(allocator, page, format, selector);
}

pub const CommandOutput = struct {
    text: []const u8,
    har_json: ?[]const u8 = null,
};

pub fn renderUrlOutput(
    allocator: std.mem.Allocator,
    url: []const u8,
    format: model.DumpFormat,
    selector: ?[]const u8,
    capture_har: bool,
) !CommandOutput {
    if (!capture_har) {
        return .{ .text = try renderUrlText(allocator, url, format, selector) };
    }
    const artifacts = try render.renderUrlArtifacts(allocator, url, true);
    return .{
        .text = try shell.renderPageWithFormat(allocator, artifacts.page, format, selector),
        .har_json = artifacts.har_json,
    };
}

pub fn submitFormOutput(
    allocator: std.mem.Allocator,
    url: []const u8,
    form_index: usize,
    overrides: []const model.FieldInput,
    format: model.DumpFormat,
    selector: ?[]const u8,
    capture_har: bool,
) !CommandOutput {
    if (!capture_har) {
        return .{ .text = try submitFormText(allocator, url, form_index, overrides, format, selector) };
    }
    const artifacts = try render.submitFormArtifacts(allocator, url, form_index, overrides, true);
    return .{
        .text = try shell.renderPageWithFormat(allocator, artifacts.page, format, selector),
        .har_json = artifacts.har_json,
    };
}

const model = @import("model.zig");

test "shape reports scaffold defaults" {
    const runtime = BrowserRuntime.init(std.testing.allocator);
    const shape = runtime.shape();
    try std.testing.expectEqualStrings("standalone experiment", shape.mode);
    try std.testing.expectEqualStrings("stateful fetcher with redirects, cookies, and curl fallback", shape.transport);
}
