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
    submit,
};

const Command = union(CommandTag) {
    help,
    version,
    status,
    roadmap,
    render: RenderCommand,
    submit: SubmitCommand,
};

const RenderCommand = struct {
    url: []const u8,
    dump: model.DumpFormat = .summary,
    selector: ?[]const u8 = null,
    js_enabled: bool = false,
    eval_expression: ?[]const u8 = null,
    har_path: ?[]const u8 = null,
};

const SubmitCommand = struct {
    url: []const u8,
    form_index: usize = 1,
    fields: []const model.FieldInput = &.{},
    dump: model.DumpFormat = .summary,
    selector: ?[]const u8 = null,
    js_enabled: bool = false,
    eval_expression: ?[]const u8 = null,
    har_path: ?[]const u8 = null,
};

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();

    var arena_impl = std.heap.ArenaAllocator.init(gpa_impl.allocator());
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const args = try init.args.toSlice(arena);
    const cmd = parseCommand(arena, args) catch |err| switch (err) {
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
            std.debug.print("error: command requires a URL\n", .{});
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
        error.MissingFieldValue => {
            std.debug.print("error: --field requires name=value\n", .{});
            std.debug.print("{s}", .{shell.usageText()});
            std.process.exit(1);
        },
        error.InvalidFieldSyntax => {
            std.debug.print("error: invalid field syntax, expected name=value\n", .{});
            std.debug.print("{s}", .{shell.usageText()});
            std.process.exit(1);
        },
        error.MissingFormIndexValue => {
            std.debug.print("error: --form-index requires a value\n", .{});
            std.debug.print("{s}", .{shell.usageText()});
            std.process.exit(1);
        },
        error.InvalidFormIndex => {
            std.debug.print("error: invalid form index\n", .{});
            std.debug.print("{s}", .{shell.usageText()});
            std.process.exit(1);
        },
        error.MissingHarPathValue => {
            std.debug.print("error: --har requires a file path\n", .{});
            std.debug.print("{s}", .{shell.usageText()});
            std.process.exit(1);
        },
        error.MissingEvalValue => {
            std.debug.print("error: --eval requires an expression\n", .{});
            std.debug.print("{s}", .{shell.usageText()});
            std.process.exit(1);
        },
        else => return err,
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
            const output = try runtime.renderUrlOutput(arena, render_cmd.url, render_cmd.dump, render_cmd.selector, render_cmd.har_path != null, .{
                .enabled = render_cmd.js_enabled,
                .eval_expression = render_cmd.eval_expression,
            });
            if (render_cmd.har_path) |path| {
                try writeFile(path, output.har_json.?);
            }
            std.debug.print("{s}", .{output.text});
        },
        .submit => |submit_cmd| {
            const output = runtime.submitFormOutput(arena, submit_cmd.url, submit_cmd.form_index, submit_cmd.fields, submit_cmd.dump, submit_cmd.selector, submit_cmd.har_path != null, .{
                .enabled = submit_cmd.js_enabled,
                .eval_expression = submit_cmd.eval_expression,
            }) catch |err| switch (err) {
                error.FormNotFound => {
                    std.debug.print("error: form index {d} not found on page\n", .{submit_cmd.form_index});
                    std.process.exit(1);
                },
                error.UnsupportedFormMethod => {
                    std.debug.print("error: unsupported form method\n", .{});
                    std.process.exit(1);
                },
                error.UnsupportedFormEncoding => {
                    std.debug.print("error: unsupported form encoding\n", .{});
                    std.process.exit(1);
                },
                else => return err,
            };
            if (submit_cmd.har_path) |path| {
                try writeFile(path, output.har_json.?);
            }
            std.debug.print("{s}", .{output.text});
        },
    }
}

fn parseCommand(allocator: std.mem.Allocator, args: []const []const u8) !Command {
    if (args.len <= 1) return .help;

    if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) return .help;
    if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-V")) return .version;
    if (std.mem.eql(u8, args[1], "status")) return .status;
    if (std.mem.eql(u8, args[1], "roadmap")) return .roadmap;
    if (std.mem.eql(u8, args[1], "render")) {
        return .{ .render = try parseRenderCommand(args[2..]) };
    }
    if (std.mem.eql(u8, args[1], "submit")) {
        return .{ .submit = try parseSubmitCommand(allocator, args[2..]) };
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
        if (std.mem.eql(u8, arg, "--js")) {
            render_cmd.js_enabled = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--eval")) {
            if (i + 1 >= args.len) return error.MissingEvalValue;
            render_cmd.js_enabled = true;
            render_cmd.eval_expression = args[i + 1];
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--har")) {
            if (i + 1 >= args.len) return error.MissingHarPathValue;
            render_cmd.har_path = args[i + 1];
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

fn parseSubmitCommand(allocator: std.mem.Allocator, args: []const []const u8) !SubmitCommand {
    if (args.len == 0) return error.MissingUrl;

    var submit_cmd: SubmitCommand = .{ .url = "" };
    var fields: std.ArrayList(model.FieldInput) = .empty;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dump")) {
            if (i + 1 >= args.len) return error.MissingDumpValue;
            submit_cmd.dump = model.DumpFormat.parse(args[i + 1]) orelse return error.InvalidDump;
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--selector")) {
            if (i + 1 >= args.len) return error.MissingSelectorValue;
            submit_cmd.selector = args[i + 1];
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--js")) {
            submit_cmd.js_enabled = true;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--eval")) {
            if (i + 1 >= args.len) return error.MissingEvalValue;
            submit_cmd.js_enabled = true;
            submit_cmd.eval_expression = args[i + 1];
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--har")) {
            if (i + 1 >= args.len) return error.MissingHarPathValue;
            submit_cmd.har_path = args[i + 1];
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--field")) {
            if (i + 1 >= args.len) return error.MissingFieldValue;
            try fields.append(allocator, try parseFieldInput(args[i + 1]));
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--form-index")) {
            if (i + 1 >= args.len) return error.MissingFormIndexValue;
            submit_cmd.form_index = std.fmt.parseInt(usize, args[i + 1], 10) catch return error.InvalidFormIndex;
            if (submit_cmd.form_index == 0) return error.InvalidFormIndex;
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.UnknownCommand;
        if (submit_cmd.url.len != 0) return error.UnknownCommand;
        submit_cmd.url = arg;
        i += 1;
    }

    if (submit_cmd.url.len == 0) return error.MissingUrl;
    submit_cmd.fields = try fields.toOwnedSlice(allocator);
    return submit_cmd;
}

fn parseFieldInput(arg: []const u8) !model.FieldInput {
    const eq_index = std.mem.indexOfScalar(u8, arg, '=') orelse return error.InvalidFieldSyntax;
    const name = arg[0..eq_index];
    const value = arg[eq_index + 1 ..];
    if (name.len == 0) return error.InvalidFieldSyntax;
    return .{
        .name = name,
        .value = value,
    };
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data,
    });
}

test "parseCommand defaults to help" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    try std.testing.expectEqual(CommandTag.help, std.meta.activeTag(try parseCommand(arena_impl.allocator(), &.{"kuri-browser"})));
}

test "parseCommand handles standard flags" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    try std.testing.expectEqual(CommandTag.help, std.meta.activeTag(try parseCommand(arena, &.{ "kuri-browser", "--help" })));
    try std.testing.expectEqual(CommandTag.version, std.meta.activeTag(try parseCommand(arena, &.{ "kuri-browser", "--version" })));
    try std.testing.expectEqual(CommandTag.status, std.meta.activeTag(try parseCommand(arena, &.{ "kuri-browser", "status" })));
    try std.testing.expectEqual(CommandTag.roadmap, std.meta.activeTag(try parseCommand(arena, &.{ "kuri-browser", "roadmap" })));

    const render_cmd = try parseCommand(arena, &.{ "kuri-browser", "render", "https://example.com" });
    try std.testing.expectEqual(CommandTag.render, std.meta.activeTag(render_cmd));
    try std.testing.expectEqualStrings("https://example.com", render_cmd.render.url);
    try std.testing.expectEqual(model.DumpFormat.summary, render_cmd.render.dump);

    const links_cmd = try parseCommand(arena, &.{ "kuri-browser", "render", "https://example.com", "--dump", "links" });
    try std.testing.expectEqual(model.DumpFormat.links, links_cmd.render.dump);

    const forms_cmd = try parseCommand(arena, &.{ "kuri-browser", "render", "https://example.com", "--dump", "forms" });
    try std.testing.expectEqual(model.DumpFormat.forms, forms_cmd.render.dump);

    const js_dump_cmd = try parseCommand(arena, &.{ "kuri-browser", "render", "https://example.com", "--dump", "js" });
    try std.testing.expectEqual(model.DumpFormat.js, js_dump_cmd.render.dump);

    const har_cmd = try parseCommand(arena, &.{ "kuri-browser", "render", "https://example.com", "--har", "tmp.har" });
    try std.testing.expectEqualStrings("tmp.har", har_cmd.render.har_path.?);

    const js_cmd = try parseCommand(arena, &.{ "kuri-browser", "render", "https://example.com", "--js", "--eval", "document.title" });
    try std.testing.expect(js_cmd.render.js_enabled);
    try std.testing.expectEqualStrings("document.title", js_cmd.render.eval_expression.?);

    const submit_cmd = try parseCommand(arena, &.{ "kuri-browser", "submit", "https://example.com/login", "--form-index", "2", "--field", "username=admin", "--field", "password=admin" });
    try std.testing.expectEqual(CommandTag.submit, std.meta.activeTag(submit_cmd));
    try std.testing.expectEqual(@as(usize, 2), submit_cmd.submit.form_index);
    try std.testing.expectEqual(@as(usize, 2), submit_cmd.submit.fields.len);
    try std.testing.expectEqualStrings("username", submit_cmd.submit.fields[0].name);
    try std.testing.expectEqualStrings("admin", submit_cmd.submit.fields[0].value);

    const submit_har_cmd = try parseCommand(arena, &.{ "kuri-browser", "submit", "https://example.com/login", "--field", "username=admin", "--har", "submit.har" });
    try std.testing.expectEqualStrings("submit.har", submit_har_cmd.submit.har_path.?);

    const submit_js_cmd = try parseCommand(arena, &.{ "kuri-browser", "submit", "https://example.com/login", "--field", "username=admin", "--js", "--eval", "document.title" });
    try std.testing.expect(submit_js_cmd.submit.js_enabled);
    try std.testing.expectEqualStrings("document.title", submit_js_cmd.submit.eval_expression.?);

    const selector_cmd = try parseCommand(arena, &.{ "kuri-browser", "render", "https://example.com", "--selector", ".titleline a" });
    try std.testing.expectEqualStrings(".titleline a", selector_cmd.render.selector.?);
}

test "parseCommand rejects unknown input" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    try std.testing.expectError(error.UnknownCommand, parseCommand(arena, &.{ "kuri-browser", "wat" }));
    try std.testing.expectError(error.MissingUrl, parseCommand(arena, &.{ "kuri-browser", "render" }));
    try std.testing.expectError(error.MissingDumpValue, parseCommand(arena, &.{ "kuri-browser", "render", "https://example.com", "--dump" }));
    try std.testing.expectError(error.InvalidDump, parseCommand(arena, &.{ "kuri-browser", "render", "https://example.com", "--dump", "wat" }));
    try std.testing.expectError(error.MissingSelectorValue, parseCommand(arena, &.{ "kuri-browser", "render", "https://example.com", "--selector" }));
    try std.testing.expectError(error.MissingEvalValue, parseCommand(arena, &.{ "kuri-browser", "render", "https://example.com", "--eval" }));
    try std.testing.expectError(error.MissingHarPathValue, parseCommand(arena, &.{ "kuri-browser", "render", "https://example.com", "--har" }));
    try std.testing.expectError(error.MissingFieldValue, parseCommand(arena, &.{ "kuri-browser", "submit", "https://example.com/login", "--field" }));
    try std.testing.expectError(error.InvalidFieldSyntax, parseCommand(arena, &.{ "kuri-browser", "submit", "https://example.com/login", "--field", "=admin" }));
    try std.testing.expectError(error.InvalidFormIndex, parseCommand(arena, &.{ "kuri-browser", "submit", "https://example.com/login", "--form-index", "0" }));
}
