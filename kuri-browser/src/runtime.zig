const std = @import("std");
const render = @import("render.zig");

pub const RuntimeStage = enum {
    scaffold,
    network,
    dom,
    js,
    agent_api,
    cdp,
};

pub const RuntimeShape = struct {
    mode: []const u8,
    transport: []const u8,
    dom: []const u8,
    js: []const u8,
    automation_surface: []const u8,
};

pub const BrowserRuntime = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BrowserRuntime {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BrowserRuntime) void {
        _ = self;
    }

    pub fn shape(self: *const BrowserRuntime) RuntimeShape {
        _ = self;
        return .{
            .mode = "standalone experiment",
            .transport = "not implemented yet",
            .dom = "not implemented yet",
            .js = "not implemented yet",
            .automation_surface = "not implemented yet",
        };
    }
};

pub fn statusText(allocator: std.mem.Allocator) ![]const u8 {
    const runtime = BrowserRuntime.init(std.heap.page_allocator);
    const shape = runtime.shape();

    return std.fmt.allocPrint(
        allocator,
        \\kuri-browser
        \\
        \\mode: {s}
        \\transport: {s}
        \\dom: {s}
        \\js: {s}
        \\automation: {s}
        \\
        \\intent: isolate a Zig-native browser runtime experiment from Kuri's main Chrome/CDP build
        \\
    , .{
        shape.mode,
        shape.transport,
        shape.dom,
        shape.js,
        shape.automation_surface,
    });
}

pub fn roadmapText(allocator: std.mem.Allocator) ![]const u8 {
    const stages = [_]RuntimeStage{
        .scaffold,
        .network,
        .dom,
        .js,
        .agent_api,
        .cdp,
    };

    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(allocator, "kuri-browser roadmap\n\n");
    for (stages) |stage| {
        const line = try std.fmt.allocPrint(allocator, "- {s}\n", .{stageLabel(stage)});
        try list.appendSlice(allocator, line);
    }
    return try list.toOwnedSlice(allocator);
}

pub fn renderUrlText(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const page = try render.renderUrl(allocator, url);
    return render.renderText(allocator, page);
}

fn stageLabel(stage: RuntimeStage) []const u8 {
    return switch (stage) {
        .scaffold => "scaffold: separate build, CLI, and experiment boundaries",
        .network => "network: HTTP navigation, redirects, cookies, resource loading",
        .dom => "dom: parsed tree, selector queries, serialization",
        .js => "js: embedded runtime and browser API shims",
        .agent_api => "agent_api: evaluate, snapshot, refs, action primitives",
        .cdp => "cdp: optional compatibility layer after core runtime is stable",
    };
}

test "shape reports scaffold defaults" {
    const runtime = BrowserRuntime.init(std.testing.allocator);
    const shape = runtime.shape();
    try std.testing.expectEqualStrings("standalone experiment", shape.mode);
    try std.testing.expectEqualStrings("not implemented yet", shape.transport);
}
