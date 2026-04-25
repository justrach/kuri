const std = @import("std");
const model = @import("model.zig");
const runtime = @import("runtime.zig");
const shell = @import("shell.zig");

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
    render: RenderCommand,
};

const RenderCommand = struct {
    url: []const u8,
    dump: model.DumpFormat = .summary,
    selector: ?[]const u8 = null,
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
            std.debug.print("{s}", .{shell.usageText()});
            std.process.exit(1);
        },
        error.MissingUrl => {
            std.debug.print("error: render requires a URL\n", .{});
            std.debug.print("{s}", .{shell.usageText()});
            std.process.exit(1);
        },
        error.MissingDumpValue => {
            std.debug.print("error: --dump requires a value\n", .{});
            std.debug.print("{s}", .{shell.usageText()});
            std.process.exit(1);
        },
        error.InvalidDump => {
            std.debug.print("error: invalid dump format\n", .{});
            std.debug.print("{s}", .{shell.usageText()});
            std.process.exit(1);
        },
        error.MissingSelectorValue => {
            std.debug.print("error: --selector requires a value\n", .{});
            std.debug.print("{s}", .{shell.usageText()});
            std.process.exit(1);
        },
    };

    switch (cmd) {
        .help => std.debug.print("{s}", .{shell.usageText()}),
        .version => std.debug.print("kuri-browser {s}\n", .{version}),
        .status => {
            const text = try runtime.statusText(arena);
            std.debug.print("{s}", .{text});
        },
        .roadmap => {
            const text = try runtime.roadmapText(arena);
            std.debug.print("{s}", .{text});
        },
        .render => |render_cmd| {
            const text = try runtime.renderUrlText(arena, render_cmd.url, render_cmd.dump, render_cmd.selector);
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
        return .{ .render = try parseRenderCommand(args[2..]) };
    }

    return error.UnknownCommand;
}

fn parseRenderCommand(args: []const []const u8) !RenderCommand {
    if (args.len == 0) return error.MissingUrl;

    var render_cmd: RenderCommand = .{ .url = "" };
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dump")) {
            if (i + 1 >= args.len) return error.MissingDumpValue;
            render_cmd.dump = model.DumpFormat.parse(args[i + 1]) orelse return error.InvalidDump;
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--selector")) {
            if (i + 1 >= args.len) return error.MissingSelectorValue;
            render_cmd.selector = args[i + 1];
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.UnknownCommand;
        if (render_cmd.url.len != 0) return error.UnknownCommand;
        render_cmd.url = arg;
        i += 1;
    }

    if (render_cmd.url.len == 0) return error.MissingUrl;
    return render_cmd;
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
    try std.testing.expectEqualStrings("https://example.com", render_cmd.render.url);
    try std.testing.expectEqual(model.DumpFormat.summary, render_cmd.render.dump);

    const links_cmd = try parseCommand(&.{ "kuri-browser", "render", "https://example.com", "--dump", "links" });
    try std.testing.expectEqual(model.DumpFormat.links, links_cmd.render.dump);

    const forms_cmd = try parseCommand(&.{ "kuri-browser", "render", "https://example.com", "--dump", "forms" });
    try std.testing.expectEqual(model.DumpFormat.forms, forms_cmd.render.dump);

    const selector_cmd = try parseCommand(&.{ "kuri-browser", "render", "https://example.com", "--selector", ".titleline a" });
    try std.testing.expectEqualStrings(".titleline a", selector_cmd.render.selector.?);
}

test "parseCommand rejects unknown input" {
    try std.testing.expectError(error.UnknownCommand, parseCommand(&.{ "kuri-browser", "wat" }));
    try std.testing.expectError(error.MissingUrl, parseCommand(&.{ "kuri-browser", "render" }));
    try std.testing.expectError(error.MissingDumpValue, parseCommand(&.{ "kuri-browser", "render", "https://example.com", "--dump" }));
    try std.testing.expectError(error.InvalidDump, parseCommand(&.{ "kuri-browser", "render", "https://example.com", "--dump", "wat" }));
    try std.testing.expectError(error.MissingSelectorValue, parseCommand(&.{ "kuri-browser", "render", "https://example.com", "--selector" }));
}
