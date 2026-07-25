//! Single source of truth for the `ios` command surface.
//!
//! Both the human help text and the machine-readable `ios tools` output are
//! rendered from this one table. Keeping them derived from the same data is
//! the point: a command that gains a flag but not a help line is the usual
//! way a CLI's documentation goes quietly stale, and an agent reading
//! `ios tools --json` to decide what it can call cannot afford that drift.

const std = @import("std");

/// Where a command can actually run. Agents use this to avoid attempting
/// things that are structurally impossible rather than merely unconfigured.
pub const Scope = enum {
    /// iOS Simulator only — needs the host-side Simulator.app window or a
    /// simctl verb that has no real-device equivalent.
    sim,
    /// Works against a physical device (usually via devicectl/usbmuxd).
    device,
    /// Both simulator and real device.
    both,

    pub fn text(self: Scope) []const u8 {
        return switch (self) {
            .sim => "simulator",
            .device => "device",
            .both => "simulator+device",
        };
    }
};

pub const Tool = struct {
    name: []const u8,
    /// Accepted alternative spellings, dispatched identically.
    aliases: []const []const u8 = &.{},
    /// Positional argument shape, for help rendering.
    args: []const u8 = "",
    /// Flags this command reads beyond the global ones.
    flags: []const []const u8 = &.{},
    summary: []const u8,
    category: []const u8,
    scope: Scope = .sim,
};

pub const all = [_]Tool{
    // --- discovery / lifecycle ---------------------------------------------
    .{
        .name = "tools",
        .args = "[--json]",
        .summary = "list every ios command, its arguments and where it can run",
        .category = "meta",
        .scope = .both,
    },
    .{
        .name = "list-devices",
        .aliases = &.{"devices"},
        .summary = "list simulators and physically attached devices",
        .category = "lifecycle",
        .scope = .both,
    },
    .{
        .name = "boot",
        .flags = &.{"--udid"},
        .summary = "boot a simulator",
        .category = "lifecycle",
    },
    .{
        .name = "shutdown",
        .flags = &.{"--udid"},
        .summary = "shut down a simulator",
        .category = "lifecycle",
    },
    .{
        .name = "erase",
        .flags = &.{"--udid"},
        .summary = "erase a simulator back to factory state (shuts it down first)",
        .category = "lifecycle",
    },
    .{
        .name = "open-sim",
        .summary = "launch Simulator.app and bring it to the front",
        .category = "lifecycle",
    },
    .{
        .name = "install",
        .args = "<path.app>",
        .summary = "install a built .app bundle onto the simulator",
        .category = "lifecycle",
    },
    .{
        .name = "uninstall",
        .args = "<bundle-id>",
        .summary = "remove an installed app",
        .category = "lifecycle",
    },
    .{
        .name = "launch",
        .args = "<bundle-id>",
        .flags = &.{ "--udid", "--simulator", "--device" },
        .summary = "launch an app by bundle id",
        .category = "lifecycle",
        .scope = .both,
    },
    .{
        .name = "terminate",
        .args = "<bundle-id>",
        .flags = &.{ "--udid", "--simulator", "--device" },
        .summary = "terminate a running app",
        .category = "lifecycle",
        .scope = .both,
    },
    .{
        .name = "list-apps",
        .flags = &.{"--udid"},
        .summary = "list installed apps and their bundle ids",
        .category = "lifecycle",
    },
    .{
        .name = "openurl",
        .aliases = &.{"navigate"},
        .args = "<url>",
        .summary = "open a URL in its default handler (https -> Safari)",
        .category = "lifecycle",
    },
    .{
        .name = "background",
        .args = "[bundle-id]",
        .flags = &.{"--for"},
        .summary = "press Home, wait, then re-foreground the app",
        .category = "lifecycle",
    },

    // --- observation --------------------------------------------------------
    .{
        .name = "screenshot",
        .args = "[path.png]",
        .flags = &.{"--udid"},
        .summary = "capture a PNG of the simulator screen",
        .category = "observe",
    },
    .{
        .name = "uitree",
        .summary = "dump the app's accessibility tree (role, id, label, device-pixel bounds)",
        .category = "observe",
    },
    .{
        .name = "find",
        .flags = &.{"--label"},
        .summary = "print elements matching a label/identifier, with tap-ready centroids",
        .category = "observe",
    },
    .{
        .name = "wait-for-ui",
        .flags = &.{ "--label", "--timeout", "--absent" },
        .summary = "block until an element appears (or disappears with --absent)",
        .category = "observe",
    },
    .{
        .name = "record-video",
        .args = "<path.mp4>",
        .flags = &.{"--for"},
        .summary = "record the screen for a bounded duration",
        .category = "observe",
    },
    .{
        .name = "log",
        .flags = &.{ "--last", "--predicate" },
        .summary = "bounded os_log query (terminates, so it can back an assertion)",
        .category = "observe",
    },

    // --- input --------------------------------------------------------------
    .{
        .name = "tap",
        .args = "<x> <y>",
        .flags = &.{"--label"},
        .summary = "tap a point, or an element by accessibility label",
        .category = "input",
    },
    .{
        .name = "doubletap",
        .aliases = &.{"dbltap"},
        .args = "<x> <y>",
        .flags = &.{"--label"},
        .summary = "double tap",
        .category = "input",
    },
    .{
        .name = "longpress",
        .aliases = &.{"long-press"},
        .args = "<x> <y> [hold_ms]",
        .flags = &.{"--label"},
        .summary = "press and hold (default 500ms)",
        .category = "input",
    },
    .{
        .name = "swipe",
        .aliases = &.{ "scroll", "pan" },
        .args = "<x1> <y1> <x2> <y2> [duration_ms]",
        .summary = "drag between two points",
        .category = "input",
    },
    .{
        .name = "gesture",
        .aliases = &.{"drag"},
        .args = "<x1,y1> <x2,y2> [x3,y3 ...]",
        .flags = &.{"--for"},
        .summary = "drag along a multi-point path (arcs, L-shapes, signatures)",
        .category = "input",
    },
    .{
        .name = "touch",
        .args = "<down|up|move> <x> <y>",
        .summary = "raw touch primitive; compose gestures the built-ins don't cover",
        .category = "input",
    },
    .{
        .name = "type",
        .args = "<text...>",
        .summary = "type Unicode text into the focused field",
        .category = "input",
    },
    .{
        .name = "key",
        .args = "<name>",
        .flags = &.{ "--cmd", "--shift", "--ctrl", "--opt" },
        .summary = "press a named key with optional modifiers (e.g. `key return --cmd`)",
        .category = "input",
    },
    .{
        .name = "key-sequence",
        .args = "<name> [name ...]",
        .summary = "press several named keys in order",
        .category = "input",
    },
    .{
        .name = "button",
        .args = "<home|lock|volup|voldown|action|rotate>",
        .summary = "press a hardware button via the Simulator's own a11y tree",
        .category = "input",
    },
    .{
        .name = "batch",
        .args = "<action> [action ...]",
        .summary = "run several actions in one process, e.g. tap:120,400 type:hi key:return",
        .category = "input",
    },

    // --- device state -------------------------------------------------------
    .{
        .name = "privacy",
        .args = "<grant|revoke|reset> <service> [bundle-id]",
        .summary = "set a TCC permission (camera is not exposed by simctl)",
        .category = "state",
    },
    .{
        .name = "ui",
        .args = "<appearance|content-size|increase-contrast> [value]",
        .summary = "appearance and Dynamic Type settings; prints current value if omitted",
        .category = "state",
    },
    .{
        .name = "status-bar",
        .aliases = &.{"status_bar"},
        .args = "override --time 9:41 ... | clear",
        .summary = "pin the status bar so screenshots are comparable across runs",
        .category = "state",
    },
    .{
        .name = "set-location",
        .args = "<lat> <lon>",
        .summary = "set the simulated GPS location",
        .category = "state",
    },
    .{
        .name = "reset-location",
        .summary = "clear the simulated GPS location",
        .category = "state",
    },
    .{
        .name = "keyboard",
        .args = "<on|off>",
        .summary = "connect/disconnect the hardware keyboard (affects whether the software keyboard shows)",
        .category = "state",
    },
};

/// Resolve a user-typed subcommand to its canonical tool, honouring aliases.
pub fn lookup(name: []const u8) ?Tool {
    for (all) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
        for (t.aliases) |a| {
            if (std.mem.eql(u8, a, name)) return t;
        }
    }
    return null;
}

const categories = [_]struct { key: []const u8, title: []const u8 }{
    .{ .key = "meta", .title = "Discovery" },
    .{ .key = "lifecycle", .title = "Device & app lifecycle" },
    .{ .key = "observe", .title = "Observation" },
    .{ .key = "input", .title = "Input (Simulator only, device-pixel coords matching screenshot)" },
    .{ .key = "state", .title = "Device state" },
};

/// Human-readable listing, grouped by category.
pub fn renderText(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (categories) |c| {
        try out.appendSlice(gpa, c.title);
        try out.appendSlice(gpa, ":\n");
        for (all) |t| {
            if (!std.mem.eql(u8, t.category, c.key)) continue;
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(gpa);
            try line.appendSlice(gpa, "  ");
            try line.appendSlice(gpa, t.name);
            if (t.args.len != 0) {
                try line.append(gpa, ' ');
                try line.appendSlice(gpa, t.args);
            }
            // Pad so the summaries line up without a format-width literal.
            while (line.items.len < 48) try line.append(gpa, ' ');
            try out.appendSlice(gpa, line.items);
            try out.appendSlice(gpa, t.summary);
            try out.append(gpa, '\n');
            if (t.aliases.len != 0) {
                try out.appendSlice(gpa, "      aliases: ");
                for (t.aliases, 0..) |a, i| {
                    if (i != 0) try out.appendSlice(gpa, ", ");
                    try out.appendSlice(gpa, a);
                }
                try out.append(gpa, '\n');
            }
        }
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

fn appendJsonString(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => {
            if (ch < 0x20) {
                var buf: [6]u8 = undefined;
                const hex = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch});
                try out.appendSlice(gpa, hex);
            } else try out.append(gpa, ch);
        },
    };
    try out.append(gpa, '"');
}

fn appendJsonArray(gpa: std.mem.Allocator, out: *std.ArrayList(u8), items: []const []const u8) !void {
    try out.append(gpa, '[');
    for (items, 0..) |it, i| {
        if (i != 0) try out.append(gpa, ',');
        try appendJsonString(gpa, out, it);
    }
    try out.append(gpa, ']');
}

/// Machine-readable listing. This is the contract an agent reads to discover
/// what it may call, so every field a caller needs to build an invocation
/// (name, aliases, positional shape, flags, scope) is present.
pub fn renderJson(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"platform\":\"ios\",\"tools\":[");
    for (all, 0..) |t, i| {
        if (i != 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, "{\"name\":");
        try appendJsonString(gpa, &out, t.name);
        try out.appendSlice(gpa, ",\"aliases\":");
        try appendJsonArray(gpa, &out, t.aliases);
        try out.appendSlice(gpa, ",\"args\":");
        try appendJsonString(gpa, &out, t.args);
        try out.appendSlice(gpa, ",\"flags\":");
        try appendJsonArray(gpa, &out, t.flags);
        try out.appendSlice(gpa, ",\"category\":");
        try appendJsonString(gpa, &out, t.category);
        try out.appendSlice(gpa, ",\"scope\":");
        try appendJsonString(gpa, &out, t.scope.text());
        try out.appendSlice(gpa, ",\"summary\":");
        try appendJsonString(gpa, &out, t.summary);
        try out.append(gpa, '}');
    }
    try out.appendSlice(gpa, "]}\n");
    return out.toOwnedSlice(gpa);
}

test "lookup resolves canonical names and aliases" {
    try std.testing.expect(lookup("tap") != null);
    try std.testing.expectEqualStrings("swipe", lookup("scroll").?.name);
    try std.testing.expectEqualStrings("swipe", lookup("pan").?.name);
    try std.testing.expectEqualStrings("doubletap", lookup("dbltap").?.name);
    try std.testing.expectEqualStrings("gesture", lookup("drag").?.name);
    try std.testing.expect(lookup("definitely-not-a-command") == null);
}

test "every tool has a summary and a known category" {
    for (all) |t| {
        try std.testing.expect(t.name.len != 0);
        try std.testing.expect(t.summary.len != 0);
        var known = false;
        for (categories) |c| {
            if (std.mem.eql(u8, c.key, t.category)) known = true;
        }
        try std.testing.expect(known);
    }
}

test "tool names and aliases are unique across the table" {
    for (all, 0..) |a, i| {
        for (all, 0..) |b, j| {
            if (i == j) continue;
            try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
            for (b.aliases) |al| try std.testing.expect(!std.mem.eql(u8, a.name, al));
        }
    }
}

test "renderJson emits parseable JSON covering every tool" {
    const gpa = std.testing.allocator;
    const json = try renderJson(gpa);
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array;
    try std.testing.expectEqual(all.len, tools.items.len);
    try std.testing.expect(tools.items[0].object.get("name") != null);
    try std.testing.expect(tools.items[0].object.get("scope") != null);
}

test "renderText mentions every tool name" {
    const gpa = std.testing.allocator;
    const text = try renderText(gpa);
    defer gpa.free(text);
    for (all) |t| {
        try std.testing.expect(std.mem.indexOf(u8, text, t.name) != null);
    }
}
