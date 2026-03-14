const std = @import("std");
const quickjs = @import("quickjs");

/// Minimal JS engine wrapper around QuickJS for evaluating scripts in fetched HTML.
pub const JsEngine = struct {
    rt: *quickjs.Runtime,
    ctx: *quickjs.Context,

    pub fn init() !JsEngine {
        const rt = try quickjs.Runtime.init();
        const ctx = quickjs.Context.init(rt) catch {
            rt.deinit();
            return error.JsContextInit;
        };
        return .{ .rt = rt, .ctx = ctx };
    }

    pub fn deinit(self: *JsEngine) void {
        self.ctx.deinit();
        self.rt.deinit();
    }

    /// Evaluate a JavaScript string, discarding the result. Returns null on exception.
    pub fn exec(self: *JsEngine, code: []const u8) bool {
        const result = self.ctx.eval(code, "<eval>", .{});
        const ok = !result.isException();
        result.deinit(self.ctx);
        return ok;
    }

    /// Evaluate a JS string, return the result as a Zig-owned copy (safe across calls).
    /// Returns null on exception or if result is not convertible to string.
    pub fn evalAlloc(self: *JsEngine, allocator: std.mem.Allocator, code: []const u8) ?[]const u8 {
        const result = self.ctx.eval(code, "<eval>", .{});
        if (result.isException()) {
            result.deinit(self.ctx);
            return null;
        }
        const str = result.toCString(self.ctx) orelse {
            result.deinit(self.ctx);
            return null;
        };
        // Dupe BEFORE freeing the JS value, since toCString points into JS heap
        const duped = allocator.dupe(u8, std.mem.span(str)) catch null;
        result.deinit(self.ctx);
        return duped;
    }
};

/// Extract inline <script> tag contents from HTML.
/// Returns a slice of script body strings.
pub fn extractInlineScripts(html: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    var scripts: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;

    while (i < html.len) {
        // Find <script> or <script ...>
        const tag_pos = findScriptOpen(html, i) orelse break;
        const tag_end = std.mem.indexOfScalarPos(u8, html, tag_pos, '>') orelse break;

        // Check if it has a src= attribute (skip external scripts)
        const tag_content = html[tag_pos..tag_end];
        if (std.mem.indexOf(u8, tag_content, "src=") != null or
            std.mem.indexOf(u8, tag_content, "src =") != null)
        {
            i = tag_end + 1;
            continue;
        }

        const body_start = tag_end + 1;
        const close = std.mem.indexOfPos(u8, html, body_start, "</script>") orelse
            std.mem.indexOfPos(u8, html, body_start, "</SCRIPT>") orelse break;

        const body = std.mem.trim(u8, html[body_start..close], " \t\n\r");
        if (body.len > 0) {
            try scripts.append(allocator, body);
        }
        i = close + 9; // len("</script>")
    }

    return scripts.toOwnedSlice(allocator);
}

fn findScriptOpen(html: []const u8, start: usize) ?usize {
    const patterns = [_][]const u8{ "<script>", "<script ", "<SCRIPT>", "<SCRIPT " };
    var best: ?usize = null;
    for (patterns) |pat| {
        if (std.mem.indexOfPos(u8, html, start, pat)) |pos| {
            if (best == null or pos < best.?) best = pos;
        }
    }
    return best;
}

/// Run all inline scripts through QuickJS and return combined output.
/// Scripts that call document.write() or similar will have their output captured.
pub fn evalHtmlScripts(html: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    const scripts = try extractInlineScripts(html, allocator);
    defer allocator.free(scripts);
    if (scripts.len == 0) return null;

    var engine = JsEngine.init() catch return null;
    defer engine.deinit();

    // Set up a minimal capture for document.write output
    _ = engine.exec("globalThis.__browdie_output = '';");
    _ = engine.exec("globalThis.document = {};");
    _ = engine.exec("globalThis.document.write = function(s) { globalThis.__browdie_output += String(s); };");
    _ = engine.exec("globalThis.document.writeln = function(s) { globalThis.__browdie_output += String(s) + '\\n'; };");
    _ = engine.exec("globalThis.window = {};");
    _ = engine.exec("globalThis.navigator = { userAgent: 'browdie-fetch/0.1' };");

    for (scripts) |script| {
        // QuickJS may need null-terminated input; dupe with sentinel
        const duped = allocator.dupeZ(u8, script) catch continue;
        defer allocator.free(duped);
        _ = engine.exec(duped);
    }

    return engine.evalAlloc(allocator, "globalThis.__browdie_output");
}

// --- Tests ---

test "extractInlineScripts finds script bodies" {
    const html = "<html><script>var x = 1;</script><p>text</p><script>var y = 2;</script></html>";
    const scripts = try extractInlineScripts(html, std.testing.allocator);
    defer std.testing.allocator.free(scripts);
    try std.testing.expectEqual(@as(usize, 2), scripts.len);
    try std.testing.expectEqualStrings("var x = 1;", scripts[0]);
    try std.testing.expectEqualStrings("var y = 2;", scripts[1]);
}

test "extractInlineScripts skips external scripts" {
    const html = "<script src=\"app.js\"></script><script>var x = 1;</script>";
    const scripts = try extractInlineScripts(html, std.testing.allocator);
    defer std.testing.allocator.free(scripts);
    try std.testing.expectEqual(@as(usize, 1), scripts.len);
    try std.testing.expectEqualStrings("var x = 1;", scripts[0]);
}

test "extractInlineScripts empty HTML" {
    const scripts = try extractInlineScripts("<p>no scripts</p>", std.testing.allocator);
    defer std.testing.allocator.free(scripts);
    try std.testing.expectEqual(@as(usize, 0), scripts.len);
}

test "JsEngine evalAlloc arithmetic" {
    var engine = try JsEngine.init();
    defer engine.deinit();

    const result = engine.evalAlloc(std.testing.allocator, "'hello ' + 'world'");
    defer if (result) |r| std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("hello world", result.?);
}

test "JsEngine evalAlloc number to string" {
    var engine = try JsEngine.init();
    defer engine.deinit();

    const result = engine.evalAlloc(std.testing.allocator, "String(40 + 2)");
    defer if (result) |r| std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("42", result.?);
}

test "JsEngine evalAlloc syntax error returns null" {
    var engine = try JsEngine.init();
    defer engine.deinit();

    const result = engine.evalAlloc(std.testing.allocator, "this is not valid js {{{{");
    try std.testing.expect(result == null);
}

test "JsEngine document.write capture" {
    var engine = try JsEngine.init();
    defer engine.deinit();

    _ = engine.exec("var __browdie_output = '';");
    _ = engine.exec("var document = {};");
    _ = engine.exec("document.write = function(s) { __browdie_output += String(s); };");
    _ = engine.exec("document.write('hello');");
    const result = engine.evalAlloc(std.testing.allocator, "__browdie_output");
    defer if (result) |r| std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("hello", result.?);
}

test "evalHtmlScripts simple var" {
    // Test with simplest possible script — no document.write dependency
    const html = "<script>globalThis.__browdie_output = 'direct';</script>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("direct", output.?);
}

test "evalHtmlScripts runs inline scripts" {
    const html = "<html><script>document.write('hello');</script></html>";

    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    // QuickJS should execute document.write and capture output
    try std.testing.expect(output != null);
    try std.testing.expect(output.?.len > 0);
    try std.testing.expectEqualStrings("hello", output.?);
}

test "evalHtmlScripts arithmetic" {
    const html = "<script>document.write(String(40 + 2));</script>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("42", output.?);
}

test "evalHtmlScripts no scripts returns null" {
    const output = try evalHtmlScripts("<p>plain</p>", std.testing.allocator);
    try std.testing.expect(output == null);
}
