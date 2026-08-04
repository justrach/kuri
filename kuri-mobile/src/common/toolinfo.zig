//! Shared machinery for the per-platform tool registries.
//!
//! `ios/tools.zig` and `android/tools.zig` each own a table describing their
//! command surface; everything about *rendering* that table — the grouped help
//! text and the JSON an agent consumes — lives here so the two platforms
//! cannot drift into describing themselves differently.

const std = @import("std");

/// Where a command can actually run. Agents use this to avoid attempting
/// things that are structurally impossible rather than merely unconfigured.
pub const Scope = enum {
    /// Simulator / emulator only.
    virtual,
    /// Physical device only.
    device,
    /// Both.
    both,

    pub fn text(self: Scope, platform: Platform) []const u8 {
        return switch (self) {
            .virtual => switch (platform) {
                .ios => "simulator",
                .android => "emulator",
            },
            .device => "device",
            .both => switch (platform) {
                .ios => "simulator+device",
                .android => "emulator+device",
            },
        };
    }
};

pub const Platform = enum { ios, android };

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
    scope: Scope = .both,
};

pub const Category = struct { key: []const u8, title: []const u8 };

/// Resolve a user-typed subcommand to its canonical tool, honouring aliases.
pub fn lookup(table: []const Tool, name: []const u8) ?Tool {
    for (table) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
        for (t.aliases) |a| {
            if (std.mem.eql(u8, a, name)) return t;
        }
    }
    return null;
}

/// Human-readable listing, grouped by category.
pub fn renderText(
    gpa: std.mem.Allocator,
    table: []const Tool,
    cats: []const Category,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (cats) |c| {
        try out.appendSlice(gpa, c.title);
        try out.appendSlice(gpa, ":\n");
        for (table) |t| {
            if (!std.mem.eql(u8, t.category, c.key)) continue;
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(gpa);
            try line.appendSlice(gpa, "  ");
            try line.appendSlice(gpa, t.name);
            if (t.args.len != 0) {
                try line.append(gpa, ' ');
                try line.appendSlice(gpa, t.args);
            }
            // Pad so summaries line up without a comptime format width.
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

pub fn appendJsonString(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
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
/// what it may call, so every field needed to build an invocation is present.
pub fn renderJson(
    gpa: std.mem.Allocator,
    platform: Platform,
    table: []const Tool,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"platform\":");
    try appendJsonString(gpa, &out, @tagName(platform));
    try out.appendSlice(gpa, ",\"tools\":[");
    for (table, 0..) |t, i| {
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
        try appendJsonString(gpa, &out, t.scope.text(platform));
        try out.appendSlice(gpa, ",\"summary\":");
        try appendJsonString(gpa, &out, t.summary);
        try out.append(gpa, '}');
    }
    try out.appendSlice(gpa, "]}\n");
    return out.toOwnedSlice(gpa);
}

/// Shared invariants every platform table must satisfy. Called from each
/// platform's tests so a new entry is checked wherever it is added.
pub fn verifyTable(table: []const Tool, cats: []const Category) !void {
    for (table, 0..) |a, i| {
        try std.testing.expect(a.name.len != 0);
        try std.testing.expect(a.summary.len != 0);

        var known = false;
        for (cats) |c| {
            if (std.mem.eql(u8, c.key, a.category)) known = true;
        }
        try std.testing.expect(known);

        // Names and aliases must be globally unique, or dispatch is ambiguous.
        for (table, 0..) |b, j| {
            if (i == j) continue;
            try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
            for (b.aliases) |al| try std.testing.expect(!std.mem.eql(u8, a.name, al));
        }
    }
}

/// Every tool in the table must survive a JSON round-trip.
pub fn verifyJson(platform: Platform, table: []const Tool) !void {
    const gpa = std.testing.allocator;
    const json = try renderJson(gpa, platform, table);
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array;
    try std.testing.expectEqual(table.len, tools.items.len);
    for (tools.items) |t| {
        try std.testing.expect(t.object.get("name") != null);
        try std.testing.expect(t.object.get("scope") != null);
        try std.testing.expect(t.object.get("summary") != null);
    }
}
