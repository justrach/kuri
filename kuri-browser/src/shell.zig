const std = @import("std");
const core = @import("core.zig");
const model = @import("model.zig");

pub fn usageText() []const u8 {
    return
        \\kuri-browser
        \\
        \\Standalone experimental browser-runtime workspace.
        \\This build is intentionally separate from Kuri's main build.
        \\
        \\USAGE
        \\  kuri-browser --help
        \\  kuri-browser --version
        \\  kuri-browser status
        \\  kuri-browser roadmap
        \\  kuri-browser render <url>
        \\
        \\EXAMPLES
        \\  zig build run -- --help
        \\  zig build run -- status
        \\  zig build run -- roadmap
        \\  zig build run -- render https://news.ycombinator.com
        \\
    ;
}

pub fn renderStatusText(allocator: std.mem.Allocator, shape: core.RuntimeShape) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        \\kuri-browser
        \\
        \\mode: {s}
        \\shell: {s}
        \\transport: {s}
        \\dom: {s}
        \\js: {s}
        \\automation: {s}
        \\fallback: {s}
        \\
        \\intent: isolate a Zig-native browser runtime experiment from Kuri's main Chrome/CDP build
        \\
    , .{
        shape.mode,
        shape.shell,
        shape.transport,
        shape.dom,
        shape.js,
        shape.automation_surface,
        shape.fallback_strategy,
    });
}

pub fn renderRoadmapText(allocator: std.mem.Allocator) ![]const u8 {
    const stages = [_]core.RuntimeStage{
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
        const line = try std.fmt.allocPrint(allocator, "- {s}\n", .{core.stageLabel(stage)});
        try list.appendSlice(allocator, line);
    }
    return try list.toOwnedSlice(allocator);
}

pub fn renderPageText(allocator: std.mem.Allocator, page: model.Page) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    try out.appendSlice(allocator, "kuri-browser render\n\n");
    try out.print(allocator, "url: {s}\n", .{page.url});
    try out.print(allocator, "status: {d}\n", .{page.status_code});
    try out.print(allocator, "content-type: {s}\n", .{page.content_type});
    try out.print(allocator, "title: {s}\n", .{page.title});
    try out.print(allocator, "pipeline: {s}\n", .{page.pipeline});
    try out.print(allocator, "fallback: {s}\n", .{page.fallback_mode.label()});
    try out.print(allocator, "links: {d}\n\n", .{page.links.len});

    try out.appendSlice(allocator, "--- text ---\n");
    const preview = previewText(page.text, 2500);
    try out.appendSlice(allocator, preview);
    if (preview.len < page.text.len) {
        try out.appendSlice(allocator, "\n\n[truncated]\n");
    }

    if (page.links.len > 0) {
        try out.appendSlice(allocator, "\n--- links ---\n");
        const limit = @min(page.links.len, 12);
        for (page.links[0..limit], 0..) |link, i| {
            const label = if (link.text.len == 0) "(no text)" else link.text;
            try out.print(allocator, "[{d}] {s}\n    {s}\n", .{ i + 1, label, link.href });
        }
        if (limit < page.links.len) {
            try out.print(allocator, "\n... {d} more links\n", .{page.links.len - limit});
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn previewText(text: []const u8, max_len: usize) []const u8 {
    if (text.len <= max_len) return text;
    return text[0..max_len];
}

test "usage mentions render command" {
    try std.testing.expect(std.mem.indexOf(u8, usageText(), "render <url>") != null);
}
