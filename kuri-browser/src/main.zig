const std = @import("std");
const runtime = @import("runtime.zig");

const version = "0.0.0";

const CommandTag = enum {
    help,
    version,
    status,
    roadmap,
    render,
};

const Command = union(CommandTag) {
    help,
    version,
    status,
    roadmap,
    render: []const u8,
};

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();

    var arena_impl = std.heap.ArenaAllocator.init(gpa_impl.allocator());
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const args = try init.args.toSlice(arena);
    const cmd = parseCommand(args) catch |err| switch (err) {
        error.UnknownCommand => {
            if (args.len > 1) {
                std.debug.print("error: unknown command '{s}'\n", .{args[1]});
            } else {
                std.debug.print("error: missing command\n", .{});
            }
            std.debug.print("Run 'kuri-browser --help' for usage.\n", .{});
            std.process.exit(1);
        },
        error.MissingUrl => {
            std.debug.print("error: render requires a URL\n", .{});
            std.debug.print("Run 'kuri-browser --help' for usage.\n", .{});
            std.process.exit(1);
        },
    };

    switch (cmd) {
        .help => printUsage(),
        .version => std.debug.print("kuri-browser {s}\n", .{version}),
        .status => {
            const text = try runtime.statusText(arena);
            std.debug.print("{s}", .{text});
        },
        .roadmap => {
            const text = try runtime.roadmapText(arena);
            std.debug.print("{s}", .{text});
        },
        .render => |url| {
            const text = try runtime.renderUrlText(arena, url);
            std.debug.print("{s}", .{text});
        },
    }
}

fn parseCommand(args: []const []const u8) !Command {
    if (args.len <= 1) return .help;

    if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) return .help;
    if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-V")) return .version;
    if (std.mem.eql(u8, args[1], "status")) return .status;
    if (std.mem.eql(u8, args[1], "roadmap")) return .roadmap;
    if (std.mem.eql(u8, args[1], "render")) {
        if (args.len < 3) return error.MissingUrl;
        return .{ .render = args[2] };
    }

    return error.UnknownCommand;
}

fn printUsage() void {
    std.debug.print(
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
    , .{});
}

test "parseCommand defaults to help" {
    try std.testing.expectEqual(CommandTag.help, std.meta.activeTag(try parseCommand(&.{"kuri-browser"})));
}

test "parseCommand handles standard flags" {
    try std.testing.expectEqual(CommandTag.help, std.meta.activeTag(try parseCommand(&.{ "kuri-browser", "--help" })));
    try std.testing.expectEqual(CommandTag.version, std.meta.activeTag(try parseCommand(&.{ "kuri-browser", "--version" })));
    try std.testing.expectEqual(CommandTag.status, std.meta.activeTag(try parseCommand(&.{ "kuri-browser", "status" })));
    try std.testing.expectEqual(CommandTag.roadmap, std.meta.activeTag(try parseCommand(&.{ "kuri-browser", "roadmap" })));
    const render_cmd = try parseCommand(&.{ "kuri-browser", "render", "https://example.com" });
    try std.testing.expectEqual(CommandTag.render, std.meta.activeTag(render_cmd));
    try std.testing.expectEqualStrings("https://example.com", render_cmd.render);
}

test "parseCommand rejects unknown input" {
    try std.testing.expectError(error.UnknownCommand, parseCommand(&.{ "kuri-browser", "wat" }));
    try std.testing.expectError(error.MissingUrl, parseCommand(&.{ "kuri-browser", "render" }));
}
