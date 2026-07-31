const std = @import("std");
const a11y = @import("a11y.zig");
const A11yNode = a11y.A11yNode;

/// An element identity captured at record time. role+name is the primary
/// match key; nearby_text disambiguates repeated same-role/same-name elements
/// (e.g. a "Delete" button in every row of a table). dom_path is captured for
/// future use but deliberately NOT consulted by resolveSignature in v1:
/// comparing it would need a second per-candidate CDP round trip to compute a
/// comparable current-DOM path, which this module avoids (see the "differing
/// dom_path does not affect the outcome" test below -- don't half-wire it in
/// silently later without deciding to pay that cost).
pub const Signature = struct {
    role: []const u8,
    name: []const u8,
    nearby_text: []const u8 = "",
    dom_path: []const u8 = "",
};

pub const Resolution = union(enum) {
    unique: struct { node: A11yNode, healed: bool },
    ambiguous: []const A11yNode,
    none,
};

const min_fuzzy_len: usize = 3;
const nearby_max_len: usize = 160;

fn appendWithSpace(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    if (out.items.len > 0) try out.append(allocator, ' ');
    try out.appendSlice(allocator, s);
}

/// Collapses whitespace runs to a single space and trims ends. Chrome's real
/// accessible-name computation does this; a name captured client-side from
/// innerText/textContent generally does not, so both sides must be
/// normalized before exact comparison or a multi-line label never matches.
fn normalizeName(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t\n\r");
    while (it.next()) |word| {
        try appendWithSpace(allocator, &out, word);
    }
    return out.items;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

/// Approximates "surrounding page text" for nodes[idx] using only the
/// pre-order-DFS-with-depth ordering buildSnapshot already produces -- no
/// second DOM/CDP round trip. Walks outward from idx in both directions,
/// collecting names of same-depth siblings, and stops each direction at the
/// first shallower node (the immediate parent boundary), including that
/// parent's own name once if present. This keeps context scoped to "this
/// row/group" rather than the whole page or the candidate's own descendants
/// (which are always deeper, so they're never visited by this scan).
const NearbyDirection = enum { backward, forward };

/// Walks outward from idx in one direction across up to two "shallower"
/// boundary crossings: same-depth siblings within the immediate parent, the
/// parent's own name, then the parent's siblings within ITS parent (reaches
/// an adjacent cell in the same row/group, e.g. a row label next to an
/// action button). This second level matters because a `<td>` wrapping a
/// lone `<button>Delete</button>` inherits the button's own accessible name
/// too (confirmed against a live table) -- stopping at the immediate parent
/// alone would surface "Delete" as the only "context", which disambiguates
/// nothing. Nodes deeper than the current boundary are skipped without
/// stopping the scan (they belong to some other branch, not a sibling).
fn scanNearbyDirection(nodes: []const A11yNode, idx: usize, target_depth: u16, direction: NearbyDirection, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    var boundary_depth = target_depth;
    var levels: u8 = 0;
    var i = idx;
    while (levels < 2) {
        const has_next = switch (direction) {
            .backward => i > 0,
            .forward => i + 1 < nodes.len,
        };
        if (!has_next) break;
        i = switch (direction) {
            .backward => i - 1,
            .forward => i + 1,
        };
        const d = nodes[i].depth;
        if (d < boundary_depth) {
            if (nodes[i].name.len > 0) try appendWithSpace(allocator, out, nodes[i].name);
            boundary_depth = d;
            levels += 1;
        } else if (d == boundary_depth and nodes[i].name.len > 0) {
            try appendWithSpace(allocator, out, nodes[i].name);
        }
    }
}

/// Approximates "surrounding page text" for nodes[idx] using only the
/// pre-order-DFS-with-depth ordering buildSnapshot already produces -- no
/// second DOM/CDP round trip.
fn approximateNearbyText(nodes: []const A11yNode, idx: usize, allocator: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const target_depth = nodes[idx].depth;

    try scanNearbyDirection(nodes, idx, target_depth, .backward, &out, allocator);
    try scanNearbyDirection(nodes, idx, target_depth, .forward, &out, allocator);

    return if (out.items.len > nearby_max_len) out.items[0..nearby_max_len] else out.items;
}

/// Filters `candidates` (indices into `nodes`) to those whose approximated
/// nearby text contains `want`. A no-op when `want` is empty -- there's no
/// signal to narrow with, so don't pretend to.
fn narrowByNearbyText(nodes: []const A11yNode, candidates: []const usize, want: []const u8, allocator: std.mem.Allocator) ![]const usize {
    if (want.len == 0) return candidates;
    var kept: std.ArrayList(usize) = .empty;
    for (candidates) |idx| {
        const ctx = try approximateNearbyText(nodes, idx, allocator);
        if (containsIgnoreCase(ctx, want)) try kept.append(allocator, idx);
    }
    return kept.items;
}

fn materialize(nodes: []const A11yNode, indices: []const usize, allocator: std.mem.Allocator) ![]const A11yNode {
    const out = try allocator.alloc(A11yNode, indices.len);
    for (indices, 0..) |idx, i| out[i] = nodes[idx];
    return out;
}

/// Narrows a >1 candidate set by nearby_text; resolves to `.unique` if that
/// narrows to exactly one, otherwise `.ambiguous` -- using the narrowed set
/// if nonempty, else falling back to the pre-narrowing set (an over-eager
/// nearby_text miss shouldn't manufacture a `.none` out of real candidates).
fn oneOrAmbiguous(nodes: []const A11yNode, narrowed: []const usize, original: []const usize, healed: bool, allocator: std.mem.Allocator) !Resolution {
    if (narrowed.len == 1) return .{ .unique = .{ .node = nodes[narrowed[0]], .healed = healed } };
    const final_set = if (narrowed.len > 0) narrowed else original;
    return .{ .ambiguous = try materialize(nodes, final_set, allocator) };
}

/// Resolves a recorded Signature against a freshly-fetched node list. Staged:
/// exact role+name match first; if that's ambiguous (>1), narrow by
/// nearby_text. If there's no exact match, fall back to a fuzzy
/// (substring, case-insensitive) name match under the same role, again
/// narrowed by nearby_text. An empty or very short signature name is
/// deliberately excluded from fuzzy matching -- otherwise it would trivially
/// "match" every node of that role (an empty name) or false-positive on
/// unrelated names that happen to contain it (e.g. "OK" inside "Cookies").
pub fn resolveSignature(nodes: []const A11yNode, sig: Signature, allocator: std.mem.Allocator) !Resolution {
    if (nodes.len == 0) return .none;

    const norm_sig_name = try normalizeName(allocator, sig.name);

    var exact: std.ArrayList(usize) = .empty;
    for (nodes, 0..) |n, i| {
        if (!std.mem.eql(u8, n.role, sig.role)) continue;
        const norm_node_name = try normalizeName(allocator, n.name);
        if (std.mem.eql(u8, norm_node_name, norm_sig_name)) try exact.append(allocator, i);
    }

    if (exact.items.len == 1) return .{ .unique = .{ .node = nodes[exact.items[0]], .healed = false } };
    if (exact.items.len > 1) {
        const narrowed = try narrowByNearbyText(nodes, exact.items, sig.nearby_text, allocator);
        return oneOrAmbiguous(nodes, narrowed, exact.items, false, allocator);
    }

    if (norm_sig_name.len >= min_fuzzy_len) {
        var fuzzy: std.ArrayList(usize) = .empty;
        for (nodes, 0..) |n, i| {
            if (!std.mem.eql(u8, n.role, sig.role)) continue;
            const norm_node_name = try normalizeName(allocator, n.name);
            if (norm_node_name.len < min_fuzzy_len) continue;
            if (containsIgnoreCase(norm_node_name, norm_sig_name) or containsIgnoreCase(norm_sig_name, norm_node_name)) {
                try fuzzy.append(allocator, i);
            }
        }
        if (fuzzy.items.len == 1) return .{ .unique = .{ .node = nodes[fuzzy.items[0]], .healed = true } };
        if (fuzzy.items.len > 1) {
            const narrowed = try narrowByNearbyText(nodes, fuzzy.items, sig.nearby_text, allocator);
            return oneOrAmbiguous(nodes, narrowed, fuzzy.items, true, allocator);
        }
    }

    if (sig.nearby_text.len > 0) {
        var by_context: std.ArrayList(usize) = .empty;
        for (nodes, 0..) |n, i| {
            if (!std.mem.eql(u8, n.role, sig.role)) continue;
            const ctx = try approximateNearbyText(nodes, i, allocator);
            if (containsIgnoreCase(ctx, sig.nearby_text)) try by_context.append(allocator, i);
        }
        if (by_context.items.len == 1) return .{ .unique = .{ .node = nodes[by_context.items[0]], .healed = true } };
        if (by_context.items.len > 1) return .{ .ambiguous = try materialize(nodes, by_context.items, allocator) };
    }

    return .none;
}

test "resolveSignature: exact role+name match resolves uniquely" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const nodes = [_]A11yNode{
        .{ .ref = "e1", .role = "button", .name = "Sign in", .value = "", .backend_node_id = 1, .depth = 0 },
        .{ .ref = "e2", .role = "link", .name = "Help", .value = "", .backend_node_id = 2, .depth = 0 },
    };
    const res = try resolveSignature(&nodes, .{ .role = "button", .name = "Sign in" }, alloc);
    switch (res) {
        .unique => |u| {
            try std.testing.expectEqual(@as(?u32, 1), u.node.backend_node_id);
            try std.testing.expect(!u.healed);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "resolveSignature: exact match normalizes whitespace before comparing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const nodes = [_]A11yNode{
        .{ .ref = "e1", .role = "button", .name = "Submit Now", .value = "", .backend_node_id = 1, .depth = 0 },
    };
    const res = try resolveSignature(&nodes, .{ .role = "button", .name = "Submit\n  Now" }, alloc);
    switch (res) {
        .unique => |u| try std.testing.expectEqual(@as(?u32, 1), u.node.backend_node_id),
        else => return error.TestUnexpectedResult,
    }
}

test "resolveSignature: no exact match falls back to fuzzy substring match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const nodes = [_]A11yNode{
        .{ .ref = "e1", .role = "button", .name = "Submit Order Now", .value = "", .backend_node_id = 1, .depth = 0 },
    };
    const res = try resolveSignature(&nodes, .{ .role = "button", .name = "Submit Order" }, alloc);
    switch (res) {
        .unique => |u| {
            try std.testing.expectEqual(@as(?u32, 1), u.node.backend_node_id);
            try std.testing.expect(u.healed);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "resolveSignature: short names do not participate in fuzzy substring matching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const nodes = [_]A11yNode{
        .{ .ref = "e1", .role = "button", .name = "Cookies", .value = "", .backend_node_id = 1, .depth = 0 },
    };
    // "OK" is a substring of "cOOKies" -- must NOT match; too short to trust for fuzzy matching.
    const res = try resolveSignature(&nodes, .{ .role = "button", .name = "OK" }, alloc);
    try std.testing.expect(std.meta.activeTag(res) == .none);
}

test "resolveSignature: empty signature name does not match every same-role node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const nodes = [_]A11yNode{
        .{ .ref = "e1", .role = "button", .name = "Sign in", .value = "", .backend_node_id = 1, .depth = 0 },
        .{ .ref = "e2", .role = "button", .name = "Cancel", .value = "", .backend_node_id = 2, .depth = 0 },
    };
    const res = try resolveSignature(&nodes, .{ .role = "button", .name = "" }, alloc);
    try std.testing.expect(std.meta.activeTag(res) == .none);
}

test "resolveSignature: nearby_text narrows repeated same-role/same-name candidates (row actions)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Realistic nesting (row > cell > button), matching a live <table>: the
    // cell wrapping a lone button inherits the button's own name too, so the
    // tiebreaker must reach one level further out to the sibling cell.
    const nodes = [_]A11yNode{
        .{ .ref = "e1", .role = "row", .name = "", .value = "", .backend_node_id = 1, .depth = 0 },
        .{ .ref = "e2", .role = "cell", .name = "Contract Alpha", .value = "", .backend_node_id = 2, .depth = 1 },
        .{ .ref = "e3", .role = "cell", .name = "Delete", .value = "", .backend_node_id = 3, .depth = 1 },
        .{ .ref = "e4", .role = "button", .name = "Delete", .value = "", .backend_node_id = 4, .depth = 2 },
        .{ .ref = "e5", .role = "row", .name = "", .value = "", .backend_node_id = 5, .depth = 0 },
        .{ .ref = "e6", .role = "cell", .name = "Contract Beta", .value = "", .backend_node_id = 6, .depth = 1 },
        .{ .ref = "e7", .role = "cell", .name = "Delete", .value = "", .backend_node_id = 7, .depth = 1 },
        .{ .ref = "e8", .role = "button", .name = "Delete", .value = "", .backend_node_id = 8, .depth = 2 },
    };
    const res = try resolveSignature(&nodes, .{ .role = "button", .name = "Delete", .nearby_text = "Contract Beta" }, alloc);
    switch (res) {
        .unique => |u| {
            try std.testing.expectEqual(@as(?u32, 8), u.node.backend_node_id);
            try std.testing.expect(!u.healed);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "resolveSignature: nearby_text narrowing to more than one candidate is still ambiguous" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const nodes = [_]A11yNode{
        .{ .ref = "e1", .role = "row", .name = "", .value = "", .backend_node_id = 1, .depth = 0 },
        .{ .ref = "e2", .role = "cell", .name = "Contract Alpha", .value = "", .backend_node_id = 2, .depth = 1 },
        .{ .ref = "e3", .role = "cell", .name = "Delete", .value = "", .backend_node_id = 3, .depth = 1 },
        .{ .ref = "e4", .role = "button", .name = "Delete", .value = "", .backend_node_id = 4, .depth = 2 },
        .{ .ref = "e5", .role = "row", .name = "", .value = "", .backend_node_id = 5, .depth = 0 },
        .{ .ref = "e6", .role = "cell", .name = "Contract Beta", .value = "", .backend_node_id = 6, .depth = 1 },
        .{ .ref = "e7", .role = "cell", .name = "Delete", .value = "", .backend_node_id = 7, .depth = 1 },
        .{ .ref = "e8", .role = "button", .name = "Delete", .value = "", .backend_node_id = 8, .depth = 2 },
    };
    const res = try resolveSignature(&nodes, .{ .role = "button", .name = "Delete", .nearby_text = "Contract" }, alloc);
    switch (res) {
        .ambiguous => |cands| try std.testing.expectEqual(@as(usize, 2), cands.len),
        else => return error.TestUnexpectedResult,
    }
}

test "resolveSignature: nearby_text matching nothing falls back to the pre-narrowing candidate set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const nodes = [_]A11yNode{
        .{ .ref = "e1", .role = "row", .name = "", .value = "", .backend_node_id = 1, .depth = 0 },
        .{ .ref = "e2", .role = "cell", .name = "Contract Alpha", .value = "", .backend_node_id = 2, .depth = 1 },
        .{ .ref = "e3", .role = "cell", .name = "Delete", .value = "", .backend_node_id = 3, .depth = 1 },
        .{ .ref = "e4", .role = "button", .name = "Delete", .value = "", .backend_node_id = 4, .depth = 2 },
        .{ .ref = "e5", .role = "row", .name = "", .value = "", .backend_node_id = 5, .depth = 0 },
        .{ .ref = "e6", .role = "cell", .name = "Contract Beta", .value = "", .backend_node_id = 6, .depth = 1 },
        .{ .ref = "e7", .role = "cell", .name = "Delete", .value = "", .backend_node_id = 7, .depth = 1 },
        .{ .ref = "e8", .role = "button", .name = "Delete", .value = "", .backend_node_id = 8, .depth = 2 },
    };
    const res = try resolveSignature(&nodes, .{ .role = "button", .name = "Delete", .nearby_text = "Nonexistent Row Label" }, alloc);
    switch (res) {
        .ambiguous => |cands| try std.testing.expectEqual(@as(usize, 2), cands.len),
        else => return error.TestUnexpectedResult,
    }
}

test "resolveSignature: no node with a matching role returns none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const nodes = [_]A11yNode{
        .{ .ref = "e1", .role = "link", .name = "Help", .value = "", .backend_node_id = 1, .depth = 0 },
    };
    const res = try resolveSignature(&nodes, .{ .role = "button", .name = "Sign in" }, alloc);
    try std.testing.expect(std.meta.activeTag(res) == .none);
}

test "resolveSignature: differing dom_path does not affect the outcome" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const nodes = [_]A11yNode{
        .{ .ref = "e1", .role = "button", .name = "Sign in", .value = "", .backend_node_id = 1, .depth = 0 },
    };
    const res = try resolveSignature(&nodes, .{ .role = "button", .name = "Sign in", .dom_path = "totally>different>path" }, alloc);
    switch (res) {
        .unique => |u| try std.testing.expectEqual(@as(?u32, 1), u.node.backend_node_id),
        else => return error.TestUnexpectedResult,
    }
}

test "resolveSignature: empty node list returns none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const nodes = [_]A11yNode{};
    const res = try resolveSignature(&nodes, .{ .role = "button", .name = "Sign in" }, alloc);
    try std.testing.expect(std.meta.activeTag(res) == .none);
}
