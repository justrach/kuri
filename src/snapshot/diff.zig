const std = @import("std");
const A11yNode = @import("a11y.zig").A11yNode;

pub const DiffKind = enum {
    added,
    removed,
    changed,
};

pub const DiffEntry = struct {
    kind: DiffKind,
    node: A11yNode,
};

/// Compute delta between previous and current snapshots.
/// Returns only nodes that were added, removed, or changed.
pub fn diffSnapshots(
    prev: []const A11yNode,
    current: []const A11yNode,
    allocator: std.mem.Allocator,
) ![]DiffEntry {
    var result: std.ArrayList(DiffEntry) = .empty;

    var prev_map = std.AutoHashMap(u32, A11yNode).init(allocator);
    defer prev_map.deinit();
    for (prev) |node| {
        if (node.backend_node_id) |id| {
            try prev_map.put(id, node);
        }
    }

    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();

    for (current) |node| {
        if (node.backend_node_id) |id| {
            try seen.put(id, {});
            if (prev_map.get(id)) |prev_node| {
                if (!std.mem.eql(u8, node.name, prev_node.name) or
                    !std.mem.eql(u8, node.value, prev_node.value) or
                    !std.mem.eql(u8, node.role, prev_node.role))
                {
                    try result.append(allocator, .{ .kind = .changed, .node = node });
                }
            } else {
                try result.append(allocator, .{ .kind = .added, .node = node });
            }
        }
    }

    for (prev) |node| {
        if (node.backend_node_id) |id| {
            if (!seen.contains(id)) {
                try result.append(allocator, .{ .kind = .removed, .node = node });
            }
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Write one node as a compact-grammar line (same shape as a11y.formatCompact,
/// but flat — a diff only needs the changed elements, not the tree indentation).
fn writeNodeLine(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, prefix: []const u8, node: A11yNode) !void {
    try buf.appendSlice(allocator, prefix);
    try buf.appendSlice(allocator, node.role);
    if (node.name.len > 0) try buf.print(allocator, " \"{s}\"", .{node.name});
    if (node.ref.len > 0) try buf.print(allocator, " @{s}", .{node.ref});
    if (node.value.len > 0) try buf.print(allocator, " = {s}", .{node.value});
    if (node.state.len > 0) try buf.print(allocator, " [{s}]", .{node.state});
    if (node.description.len > 0) try buf.print(allocator, " desc=\"{s}\"", .{node.description});
    try buf.appendSlice(allocator, "\n");
}

/// Removed nodes render identity-only: `- role "name" @ref`. The agent saw
/// the full line while the node was alive; repeating value/state/description
/// on the way out re-bills tokens for data that no longer exists.
fn writeRemovedLine(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, node: A11yNode) !void {
    try buf.appendSlice(allocator, "- ");
    try buf.appendSlice(allocator, node.role);
    if (node.name.len > 0) try buf.print(allocator, " \"{s}\"", .{node.name});
    if (node.ref.len > 0) try buf.print(allocator, " @{s}", .{node.ref});
    try buf.appendSlice(allocator, "\n");
}

/// Compute a compact-grammar diff between two snapshots and render it directly
/// to an owned string. Lines are prefixed `+ ` (added), `- ` (removed), `~ `
/// (changed). Every byte the caller needs is copied into the returned buffer,
/// so `prev` may be freed the instant this returns — no retained node pointers.
///
/// Identity is the backend DOM node id; nodes without one are skipped (they
/// cannot be tracked across snapshots). A node counts as changed when its name,
/// value, state, or role differs — state is included so toggles (checkbox
/// checked=false -> true, aria-expanded, etc.) surface. Removed lines are
/// identity-only (`- role "name" @ref`): the agent already saw the full line
/// while the node was alive.
pub fn formatCompactDiff(
    prev: []const A11yNode,
    current: []const A11yNode,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var prev_map = std.AutoHashMap(u32, A11yNode).init(allocator);
    defer prev_map.deinit();
    for (prev) |node| {
        if (node.backend_node_id) |id| try prev_map.put(id, node);
    }

    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();

    for (current) |node| {
        const id = node.backend_node_id orelse continue;
        try seen.put(id, {});
        if (prev_map.get(id)) |p| {
            if (!std.mem.eql(u8, node.name, p.name) or
                !std.mem.eql(u8, node.value, p.value) or
                !std.mem.eql(u8, node.state, p.state) or
                !std.mem.eql(u8, node.role, p.role))
            {
                try writeNodeLine(&buf, allocator, "~ ", node);
            }
        } else {
            try writeNodeLine(&buf, allocator, "+ ", node);
        }
    }

    for (prev) |node| {
        const id = node.backend_node_id orelse continue;
        if (!seen.contains(id)) try writeRemovedLine(&buf, allocator, node);
    }

    return buf.toOwnedSlice(allocator);
}

test "diffSnapshots detects additions" {
    const prev = [_]A11yNode{
        .{ .ref = "e0", .role = "button", .name = "A", .value = "", .backend_node_id = 1, .depth = 0 },
    };
    const current = [_]A11yNode{
        .{ .ref = "e0", .role = "button", .name = "A", .value = "", .backend_node_id = 1, .depth = 0 },
        .{ .ref = "e1", .role = "link", .name = "B", .value = "", .backend_node_id = 2, .depth = 0 },
    };

    const diff = try diffSnapshots(&prev, &current, std.testing.allocator);
    defer std.testing.allocator.free(diff);

    try std.testing.expectEqual(@as(usize, 1), diff.len);
    try std.testing.expectEqual(DiffKind.added, diff[0].kind);
}

test "diffSnapshots detects removals" {
    const prev = [_]A11yNode{
        .{ .ref = "e0", .role = "button", .name = "A", .value = "", .backend_node_id = 1, .depth = 0 },
        .{ .ref = "e1", .role = "link", .name = "B", .value = "", .backend_node_id = 2, .depth = 0 },
    };
    const current = [_]A11yNode{
        .{ .ref = "e0", .role = "button", .name = "A", .value = "", .backend_node_id = 1, .depth = 0 },
    };

    const diff = try diffSnapshots(&prev, &current, std.testing.allocator);
    defer std.testing.allocator.free(diff);

    try std.testing.expectEqual(@as(usize, 1), diff.len);
    try std.testing.expectEqual(DiffKind.removed, diff[0].kind);
}

test "diffSnapshots detects changes" {
    const prev = [_]A11yNode{
        .{ .ref = "e0", .role = "button", .name = "Submit", .value = "", .backend_node_id = 1, .depth = 0 },
    };
    const current = [_]A11yNode{
        .{ .ref = "e0", .role = "button", .name = "Send", .value = "", .backend_node_id = 1, .depth = 0 },
    };

    const diff = try diffSnapshots(&prev, &current, std.testing.allocator);
    defer std.testing.allocator.free(diff);

    try std.testing.expectEqual(@as(usize, 1), diff.len);
    try std.testing.expectEqual(DiffKind.changed, diff[0].kind);
}

test "formatCompactDiff renders added, removed, changed with compact grammar" {
    const prev = [_]A11yNode{
        .{ .ref = "e0", .role = "button", .name = "Submit", .value = "", .backend_node_id = 1, .depth = 0 },
        .{ .ref = "e1", .role = "link", .name = "Gone", .value = "", .backend_node_id = 2, .depth = 0 },
        .{ .ref = "", .role = "checkbox", .name = "Agree", .value = "", .state = "checked=false", .backend_node_id = 3, .depth = 0 },
        .{ .ref = "e3", .role = "textbox", .name = "Bio", .value = "draft text", .state = "focused", .backend_node_id = 9, .depth = 0 },
    };
    const current = [_]A11yNode{
        .{ .ref = "e0", .role = "button", .name = "Send", .value = "", .backend_node_id = 1, .depth = 0 }, // changed name
        .{ .ref = "", .role = "checkbox", .name = "Agree", .value = "", .state = "checked=true", .backend_node_id = 3, .depth = 0 }, // changed state
        .{ .ref = "e2", .role = "textbox", .name = "Email", .value = "", .backend_node_id = 4, .depth = 0 }, // added
    };

    const text = try formatCompactDiff(&prev, &current, std.testing.allocator);
    defer std.testing.allocator.free(text);

    // changed button (name), changed checkbox (state), added textbox, removed link
    try std.testing.expect(std.mem.indexOf(u8, text, "~ button \"Send\" @e0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "~ checkbox \"Agree\" [checked=true]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "+ textbox \"Email\" @e2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "- link \"Gone\" @e1") != null);
    // Removed lines are identity-only: value/state of dead nodes are dropped.
    try std.testing.expect(std.mem.indexOf(u8, text, "- textbox \"Bio\" @e3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "draft text") == null);
}

test "formatCompactDiff with empty prev emits everything as additions" {
    const current = [_]A11yNode{
        .{ .ref = "e0", .role = "button", .name = "Go", .value = "", .backend_node_id = 1, .depth = 0 },
    };
    const text = try formatCompactDiff(&[_]A11yNode{}, &current, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("+ button \"Go\" @e0\n", text);
}

test "formatCompactDiff does not retain pointers into prev (safe to free prev after)" {
    // Regression for the handleDiffSnapshot use-after-free: build prev in a
    // scratch arena, compute the diff into the testing allocator, free the
    // arena, then read the diff text. If the formatter retained slices into
    // prev this would read freed memory under the leak detector.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    const a = arena_state.allocator();
    const prev = try a.dupe(A11yNode, &[_]A11yNode{
        .{ .ref = try a.dupe(u8, "e0"), .role = try a.dupe(u8, "link"), .name = try a.dupe(u8, "Old"), .value = "", .backend_node_id = 9, .depth = 0 },
    });
    const current = [_]A11yNode{
        .{ .ref = "e0", .role = "button", .name = "New", .value = "", .backend_node_id = 1, .depth = 0 },
    };
    const text = try formatCompactDiff(prev, &current, std.testing.allocator);
    defer std.testing.allocator.free(text);
    arena_state.deinit(); // free everything prev pointed at
    // text is still valid and mentions both the removed link and added button
    try std.testing.expect(std.mem.indexOf(u8, text, "- link \"Old\" @e0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "+ button \"New\" @e0") != null);
}
