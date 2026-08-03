const std = @import("std");

pub const A11yNode = struct {
    ref: []const u8,
    role: []const u8,
    name: []const u8,
    value: []const u8,
    description: []const u8 = "",
    state: []const u8 = "",
    backend_node_id: ?u32,
    depth: u16,
};

pub const SnapshotOpts = struct {
    filter_interactive: bool = false,
    filter_semantic: bool = false,
    max_depth: ?u16 = null,
    format_text: bool = false,
    compact: bool = false,
    json_output: bool = false,
    diff: bool = false,
    hierarchy: bool = false,
    scope_backend_id: ?u32 = null,
    limit: ?usize = null,
    /// Bumped on navigation (see bridge RefCache.generation). Folded into ref
    /// strings only once nonzero so a same-document snapshot pays no extra
    /// bytes; a ref minted before a generation bump can't collide with one
    /// minted after, even if the CDP backend node id gets reused.
    ref_generation: u32 = 0,
};

/// Roles with no semantic meaning — skip in semantic/compact mode.
const noise_roles = std.StaticStringMap(void).initComptime(.{
    .{ "none", {} },
    .{ "generic", {} },
    .{ "presentation", {} },
    .{ "ignored", {} },
    .{ "InlineTextBox", {} },
    .{ "LineBreak", {} },
});

/// Interactive roles — always kept, ref saved to session.
const interactive_roles = std.StaticStringMap(void).initComptime(.{
    .{ "button", {} },
    .{ "link", {} },
    .{ "textbox", {} },
    .{ "checkbox", {} },
    .{ "radio", {} },
    .{ "combobox", {} },
    .{ "listbox", {} },
    .{ "menuitem", {} },
    .{ "tab", {} },
    .{ "slider", {} },
    .{ "spinbutton", {} },
    .{ "switch", {} },
    .{ "searchbox", {} },
    .{ "option", {} },
    .{ "menuitemcheckbox", {} },
    .{ "menuitemradio", {} },
});

/// Semantic roles kept in full/semantic mode (structure + content).
const semantic_roles = std.StaticStringMap(void).initComptime(.{
    .{ "button", {} },
    .{ "link", {} },
    .{ "textbox", {} },
    .{ "checkbox", {} },
    .{ "radio", {} },
    .{ "combobox", {} },
    .{ "listbox", {} },
    .{ "menuitem", {} },
    .{ "tab", {} },
    .{ "slider", {} },
    .{ "spinbutton", {} },
    .{ "switch", {} },
    .{ "searchbox", {} },
    .{ "option", {} },
    .{ "menuitemcheckbox", {} },
    .{ "menuitemradio", {} },
    .{ "heading", {} },
    .{ "img", {} },
    .{ "figure", {} },
    .{ "article", {} },
    .{ "main", {} },
    .{ "navigation", {} },
    .{ "banner", {} },
    .{ "contentinfo", {} },
    .{ "complementary", {} },
    .{ "search", {} },
    .{ "form", {} },
    .{ "region", {} },
    .{ "list", {} },
    .{ "listitem", {} },
    .{ "table", {} },
    .{ "row", {} },
    .{ "cell", {} },
    .{ "columnheader", {} },
    .{ "rowheader", {} },
    .{ "grid", {} },
    .{ "gridcell", {} },
    .{ "dialog", {} },
    .{ "alertdialog", {} },
    .{ "alert", {} },
    .{ "status", {} },
    .{ "log", {} },
    .{ "progressbar", {} },
    .{ "tablist", {} },
    .{ "tabpanel", {} },
    .{ "tree", {} },
    .{ "treeitem", {} },
    .{ "group", {} },
    .{ "toolbar", {} },
    .{ "menubar", {} },
    .{ "paragraph", {} },
    .{ "blockquote", {} },
    .{ "separator", {} },
    .{ "StaticText", {} },
});

pub fn isInteractive(role: []const u8) bool {
    return interactive_roles.has(role);
}

pub fn isSemantic(role: []const u8) bool {
    return semantic_roles.has(role);
}

pub fn isNoise(role: []const u8) bool {
    return noise_roles.has(role);
}

/// Slice `s` to at most `max` bytes without splitting a UTF-8 sequence:
/// if the cut lands mid-codepoint, back off past the continuation bytes.
fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and s[end] & 0xC0 == 0x80) end -= 1;
    return s[0..end];
}

/// Format a ref string keyed on the node's stable CDP backendNodeId rather
/// than its position in the emitted list, so the same element keeps the same
/// ref across snapshots even when unrelated siblings are added or removed.
/// `generation` (bumped on navigation) is folded in only once nonzero, so the
/// common single-document case pays no extra bytes — a pre-bump ref then
/// simply misses the fresh ref cache instead of silently resolving to an
/// unrelated node that happens to reuse the same backend id post-navigation.
fn formatRef(allocator: std.mem.Allocator, generation: u32, backend_node_id: ?u32, fallback_index: usize) ![]const u8 {
    if (backend_node_id) |bid| {
        if (generation == 0) return std.fmt.allocPrint(allocator, "e{d}", .{bid});
        return std.fmt.allocPrint(allocator, "e{d}_{d}", .{ generation, bid });
    }
    if (generation == 0) return std.fmt.allocPrint(allocator, "ei{d}", .{fallback_index});
    return std.fmt.allocPrint(allocator, "e{d}_i{d}", .{ generation, fallback_index });
}
/// Map each node's real tree depth to a rendered depth: flat (0) by default so
/// the compact snapshot pays no indentation tokens, or renormalized to count
/// only kept ancestors under `hierarchy` (no gaps where noise wrappers were
/// dropped). Mutates in place.
fn finalizeDepth(nodes: []A11yNode, hierarchy: bool) void {
    if (!hierarchy) {
        for (nodes) |*n| n.depth = 0;
        return;
    }
    var stack: [256]u16 = undefined;
    var sp: usize = 0;
    for (nodes) |*n| {
        const real = n.depth;
        while (sp > 0 and stack[sp - 1] >= real) sp -= 1;
        n.depth = @intCast(sp);
        if (sp < stack.len) {
            stack[sp] = real;
            sp += 1;
        }
    }
}

/// Cap repetitive sibling runs to `limit`. A run is the siblings that share a
/// parent and role (e.g. 50 `article` rows), even when each nests descendants
/// between them in the DFS-flat list (article, link, article, link, …). The
/// first `limit` survive with their subtrees; the rest are dropped (subtree and
/// all) and replaced by one `… +K more <role>` node at the run's depth. Consumes
/// `nodes` (frees its backing array and every dropped ref). Requires DFS order +
/// real depth. Nodes deeper than `max_tracked` bypass truncation untouched.
fn truncateRuns(nodes: []A11yNode, limit: usize, allocator: std.mem.Allocator) ![]A11yNode {
    defer allocator.free(nodes);
    var out: std.ArrayList(A11yNode) = .empty;
    errdefer {
        for (out.items) |n| if (n.ref.len != 0) allocator.free(n.ref);
        out.deinit(allocator);
    }

    const max_tracked = 128;
    var run_role: [max_tracked][]const u8 = undefined;
    var run_count = std.mem.zeroes([max_tracked]usize);
    var hidden = std.mem.zeroes([max_tracked]usize);
    var skip_deeper_than: ?u16 = null;

    const flush = struct {
        fn call(o: *std.ArrayList(A11yNode), a: std.mem.Allocator, role: []const u8, depth: u16, h: *usize) !void {
            if (h.* == 0) return;
            const name = try std.fmt.allocPrint(a, "+{d} more {s}", .{ h.*, role });
            try o.append(a, .{ .ref = "", .role = "…", .name = name, .value = "", .description = "", .state = "", .backend_node_id = null, .depth = depth });
            h.* = 0;
        }
    }.call;

    for (nodes) |node| {
        if (skip_deeper_than) |sd| {
            // Inside a dropped sibling's subtree — discard until we surface back.
            if (node.depth > sd) {
                if (node.ref.len != 0) allocator.free(node.ref);
                continue;
            }
            skip_deeper_than = null;
        }

        const d = node.depth;
        if (d >= max_tracked) {
            try out.append(allocator, node);
            continue;
        }

        // Surfacing to depth d ends every run deeper than d; flush their summaries.
        var k: usize = d + 1;
        while (k < max_tracked) : (k += 1) {
            if (run_count[k] == 0 and hidden[k] == 0) continue;
            try flush(&out, allocator, run_role[k], @intCast(k), &hidden[k]);
            run_count[k] = 0;
        }

        if (run_count[d] > 0 and std.mem.eql(u8, node.role, run_role[d])) {
            run_count[d] += 1;
            if (run_count[d] > limit) {
                hidden[d] += 1;
                skip_deeper_than = d; // drop this sibling's whole subtree
                if (node.ref.len != 0) allocator.free(node.ref);
                continue;
            }
        } else {
            try flush(&out, allocator, run_role[d], @intCast(d), &hidden[d]);
            run_role[d] = node.role;
            run_count[d] = 1;
        }
        try out.append(allocator, node);
    }

    var d2: usize = max_tracked;
    while (d2 > 0) {
        d2 -= 1;
        try flush(&out, allocator, run_role[d2], @intCast(d2), &hidden[d2]);
    }
    return out.toOwnedSlice(allocator);
}
/// Build a filtered/flattened snapshot from raw a11y nodes.
/// Build a filtered/flattened snapshot from raw a11y nodes. Nodes are expected
/// in pre-order DFS with real tree depth (parseA11yNodes produces this), which
/// is what makes `scope`, `limit`, and `hierarchy` correct. The rendered depth
/// is finalized at the end: flat (0) by default so the compact snapshot pays no
/// indentation tokens; renormalized only when `hierarchy` is requested.
pub fn buildSnapshot(
    nodes: []const A11yNode,
    opts: SnapshotOpts,
    allocator: std.mem.Allocator,
) ![]A11yNode {
    var result: std.ArrayList(A11yNode) = .empty;
    errdefer {
        for (result.items) |node| allocator.free(node.ref);
        result.deinit(allocator);
    }

    // Scope: restrict to one element's subtree. In DFS order a subtree is the
    // node plus the contiguous run of strictly-deeper nodes that follow it.
    var input = nodes;
    if (opts.scope_backend_id) |sid| {
        input = &[_]A11yNode{};
        for (nodes, 0..) |n, i| {
            if (n.backend_node_id == null or n.backend_node_id.? != sid) continue;
            var j = i + 1;
            while (j < nodes.len and nodes[j].depth > n.depth) j += 1;
            input = nodes[i..j];
            break;
        }
    }

    for (input) |node| {
        if (opts.max_depth) |max| {
            if (node.depth > max) continue;
        }
        if (opts.filter_interactive and !isInteractive(node.role)) continue;

        // Semantic filter: skip noise roles; also skip nameless non-semantic nodes
        if (opts.filter_semantic and !opts.filter_interactive) {
            if (isNoise(node.role)) continue;
            if (!isSemantic(node.role) and node.name.len == 0) continue;
        }

        // Compact mode: skip noise + deduplicate StaticText
        if (opts.compact and !opts.filter_interactive) {
            if (isNoise(node.role)) continue;
            if (node.name.len == 0 and !isInteractive(node.role)) continue;
        }

        const ref = try formatRef(allocator, opts.ref_generation, node.backend_node_id, result.items.len);

        // Truncate long fields — byte budgets that capture the useful info;
        // truncateUtf8 backs the cut off so a multibyte char is never split.
        const name = truncateUtf8(node.name, 70);
        const value = truncateUtf8(node.value, 80);
        const description = truncateUtf8(node.description, 100);
        const state = truncateUtf8(node.state, 120);

        try result.append(allocator, .{
            .ref = ref,
            .role = node.role,
            .name = name,
            .value = value,
            .description = description,
            .state = state,
            .backend_node_id = node.backend_node_id,
            .depth = node.depth, // real depth; finalized before return
        });
    }

    // Compact mode: drop StaticText whose name already appears in a non-StaticText node
    if (opts.compact) {
        var name_set: std.StringHashMap(void) = .init(allocator);
        defer name_set.deinit();
        for (result.items) |node| {
            if (!std.mem.eql(u8, node.role, "StaticText") and node.name.len > 2) {
                try name_set.put(node.name, {});
            }
        }
        var filtered: std.ArrayList(A11yNode) = .empty;
        errdefer {
            for (filtered.items) |node| {
                if (node.ref.len != 0) allocator.free(node.ref);
            }
            filtered.deinit(allocator);
        }
        var ref_idx: usize = 0;
        for (result.items) |node| {
            if (std.mem.eql(u8, node.role, "StaticText")) {
                // Drop whitespace-only
                const trimmed = std.mem.trim(u8, node.name, " \t\n\r");
                if (trimmed.len <= 1) continue;
                // Drop if text appears in a non-StaticText node's name
                if (name_set.contains(node.name)) continue;
                // Drop if mostly non-ASCII (unicode separators, bullets, etc.)
                var ascii_count: usize = 0;
                for (trimmed) |c| {
                    if (c >= 0x20 and c < 0x7f) ascii_count += 1;
                }
                if (trimmed.len > 2 and ascii_count * 3 < trimmed.len) continue;
            }
            // Only assign refs to interactive elements — agents only click/type those
            const is_act = isInteractive(node.role);
            const new_ref = if (is_act) try formatRef(allocator, opts.ref_generation, node.backend_node_id, ref_idx) else "";
            if (is_act) ref_idx += 1;
            try filtered.append(allocator, .{
                .ref = new_ref,
                .role = node.role,
                .name = node.name,
                .value = node.value,
                .description = node.description,
                .state = node.state,
                .backend_node_id = node.backend_node_id,
                .depth = node.depth,
            });
        }
        for (result.items) |node| allocator.free(node.ref);
        result.deinit(allocator);

        // Optional per-parent sibling-run truncation (libretto-style). Requires
        // real tree depth, which is why it runs after the DFS parser + dedup.
        if (opts.limit) |lim| {
            const owned = try filtered.toOwnedSlice(allocator);
            const capped = try truncateRuns(owned, lim, allocator);
            finalizeDepth(capped, opts.hierarchy);
            return capped;
        }
        const out = try filtered.toOwnedSlice(allocator);
        finalizeDepth(out, opts.hierarchy);
        return out;
    }

    const out = try result.toOwnedSlice(allocator);
    finalizeDepth(out, opts.hierarchy);
    return out;
}

/// Compact text-tree format: `role "name" @ref` — agent-browser style.
/// ~6x fewer tokens than JSON for the same data.
pub fn formatCompact(nodes: []const A11yNode, allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    for (nodes) |node| {
        // Indent by depth
        var d: u16 = 0;
        while (d < node.depth) : (d += 1) try buf.appendSlice(allocator, "  ");

        try buf.appendSlice(allocator, node.role);
        if (node.name.len > 0) {
            try buf.print(allocator, " \"{s}\"", .{node.name});
        }
        if (node.ref.len > 0) try buf.print(allocator, " @{s}", .{node.ref});
        if (node.value.len > 0) {
            try buf.print(allocator, " = {s}", .{node.value});
        }
        if (node.state.len > 0) {
            try buf.print(allocator, " [{s}]", .{node.state});
        }
        if (node.description.len > 0) {
            try buf.print(allocator, " desc=\"{s}\"", .{node.description});
        }
        try buf.appendSlice(allocator, "\n");
    }

    return buf.toOwnedSlice(allocator);
}

/// Legacy indented text format (kept for --text flag).
pub fn formatText(nodes: []const A11yNode, allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;

    for (nodes) |node| {
        for (0..node.depth) |_| {
            try buf.appendSlice(allocator, "  ");
        }
        try buf.print(allocator, "[{s}] {s}", .{ node.ref, node.role });
        if (node.name.len > 0) {
            try buf.print(allocator, " \"{s}\"", .{node.name});
        }
        if (node.value.len > 0) {
            try buf.print(allocator, " value=\"{s}\"", .{node.value});
        }
        if (node.state.len > 0) {
            try buf.print(allocator, " state=\"{s}\"", .{node.state});
        }
        if (node.description.len > 0) {
            try buf.print(allocator, " description=\"{s}\"", .{node.description});
        }
        try buf.appendSlice(allocator, "\n");
    }

    return buf.toOwnedSlice(allocator);
}

test "isInteractive" {
    try std.testing.expect(isInteractive("button"));
    try std.testing.expect(isInteractive("link"));
    try std.testing.expect(isInteractive("textbox"));
    try std.testing.expect(!isInteractive("generic"));
    try std.testing.expect(!isInteractive("paragraph"));
    try std.testing.expect(!isInteractive("heading"));
}

test "isNoise" {
    try std.testing.expect(isNoise("none"));
    try std.testing.expect(isNoise("generic"));
    try std.testing.expect(isNoise("presentation"));
    try std.testing.expect(!isNoise("button"));
    try std.testing.expect(!isNoise("heading"));
}

test "buildSnapshot filters noise in compact mode" {
    const nodes = [_]A11yNode{
        .{ .ref = "", .role = "none", .name = "", .value = "", .backend_node_id = 1, .depth = 0 },
        .{ .ref = "", .role = "generic", .name = "", .value = "", .backend_node_id = 2, .depth = 0 },
        .{ .ref = "", .role = "button", .name = "Submit", .value = "", .backend_node_id = 3, .depth = 1 },
        .{ .ref = "", .role = "heading", .name = "Flights", .value = "", .backend_node_id = 4, .depth = 1 },
        .{ .ref = "", .role = "paragraph", .name = "", .value = "", .backend_node_id = 5, .depth = 1 },
    };

    const result = try buildSnapshot(&nodes, .{ .compact = true }, std.testing.allocator);
    defer {
        for (result) |n| std.testing.allocator.free(n.ref);
        std.testing.allocator.free(result);
    }

    // none, generic filtered; paragraph filtered (no name); button + heading kept
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("button", result[0].role);
    try std.testing.expectEqualStrings("heading", result[1].role);
}

test "buildSnapshot filters interactive" {
    const nodes = [_]A11yNode{
        .{ .ref = "", .role = "generic", .name = "div", .value = "", .backend_node_id = 1, .depth = 0 },
        .{ .ref = "", .role = "button", .name = "Submit", .value = "", .backend_node_id = 2, .depth = 1 },
        .{ .ref = "", .role = "paragraph", .name = "text", .value = "", .backend_node_id = 3, .depth = 1 },
        .{ .ref = "", .role = "link", .name = "Home", .value = "", .backend_node_id = 4, .depth = 1 },
    };

    const result = try buildSnapshot(&nodes, .{ .filter_interactive = true }, std.testing.allocator);
    defer {
        for (result) |n| std.testing.allocator.free(n.ref);
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("button", result[0].role);
}

test "formatCompact includes state and description" {
    const nodes = [_]A11yNode{
        .{
            .ref = "e0",
            .role = "checkbox",
            .name = "Email me",
            .value = "",
            .description = "Receives weekly updates",
            .state = "checked=false required",
            .backend_node_id = 1,
            .depth = 0,
        },
    };

    const text = try formatCompact(&nodes, std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "[checked=false required]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "desc=\"Receives weekly updates\"") != null);
}

test "truncateUtf8 never splits a multibyte character" {
    // 69 ASCII bytes then "▲" (3 bytes) — a 70-byte cut would land mid-char.
    const name = ("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"[0..69]) ++ "▲";
    const cut = truncateUtf8(name, 70);
    try std.testing.expectEqual(@as(usize, 69), cut.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
    try std.testing.expectEqualStrings("ab", truncateUtf8("abc", 2));
    try std.testing.expectEqualStrings("é", truncateUtf8("éa", 2));
    try std.testing.expectEqualStrings("ok", truncateUtf8("ok", 70));
}

test "buildSnapshot flat default renders depth 0 despite real input depths" {
    const nodes = [_]A11yNode{
        .{ .ref = "", .role = "main", .name = "M", .value = "", .backend_node_id = 1, .depth = 0 },
        .{ .ref = "", .role = "button", .name = "B", .value = "", .backend_node_id = 2, .depth = 3 },
    };
    const result = try buildSnapshot(&nodes, .{ .compact = true }, std.testing.allocator);
    defer {
        for (result) |n| if (n.ref.len != 0) std.testing.allocator.free(n.ref);
        std.testing.allocator.free(result);
    }
    for (result) |n| try std.testing.expectEqual(@as(u16, 0), n.depth);
}

test "buildSnapshot hierarchy renormalizes depth across filtered wrappers" {
    const nodes = [_]A11yNode{
        .{ .ref = "", .role = "main", .name = "M", .value = "", .backend_node_id = 1, .depth = 0 },
        .{ .ref = "", .role = "generic", .name = "", .value = "", .backend_node_id = 2, .depth = 1 },
        .{ .ref = "", .role = "button", .name = "Deep", .value = "", .backend_node_id = 3, .depth = 5 },
        .{ .ref = "", .role = "button", .name = "Next", .value = "", .backend_node_id = 4, .depth = 1 },
    };
    const result = try buildSnapshot(&nodes, .{ .compact = true, .hierarchy = true }, std.testing.allocator);
    defer {
        for (result) |n| if (n.ref.len != 0) std.testing.allocator.free(n.ref);
        std.testing.allocator.free(result);
    }
    // generic wrapper filtered; Deep sits directly under main despite the raw
    // depth gap (5), Next pops back to main's child level.
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(@as(u16, 0), result[0].depth);
    try std.testing.expectEqual(@as(u16, 1), result[1].depth);
    try std.testing.expectEqual(@as(u16, 1), result[2].depth);
}

test "buildSnapshot scopes to a subtree by backend id" {
    const nodes = [_]A11yNode{
        .{ .ref = "", .role = "main", .name = "Main", .value = "", .backend_node_id = 1, .depth = 0 },
        .{ .ref = "", .role = "form", .name = "Login", .value = "", .backend_node_id = 2, .depth = 1 },
        .{ .ref = "", .role = "textbox", .name = "User", .value = "", .backend_node_id = 3, .depth = 2 },
        .{ .ref = "", .role = "button", .name = "Go", .value = "", .backend_node_id = 4, .depth = 2 },
        .{ .ref = "", .role = "contentinfo", .name = "Footer", .value = "", .backend_node_id = 5, .depth = 1 },
    };
    const result = try buildSnapshot(&nodes, .{ .compact = true, .scope_backend_id = 2 }, std.testing.allocator);
    defer {
        for (result) |n| if (n.ref.len != 0) std.testing.allocator.free(n.ref);
        std.testing.allocator.free(result);
    }
    // form + its two children; main above and sibling footer are outside the subtree
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("form", result[0].role);
    try std.testing.expectEqualStrings("button", result[2].role);
}

test "buildSnapshot limit caps repetitive sibling runs with a summary" {
    // Feed: nav link, then 5 article rows each nesting a title link.
    var nodes: std.ArrayList(A11yNode) = .empty;
    defer nodes.deinit(std.testing.allocator);
    try nodes.append(std.testing.allocator, .{ .ref = "", .role = "navigation", .name = "Main", .value = "", .backend_node_id = 1, .depth = 0 });
    var bid: u32 = 10;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try nodes.append(std.testing.allocator, .{ .ref = "", .role = "article", .name = "Story", .value = "", .backend_node_id = bid, .depth = 1 });
        bid += 1;
        try nodes.append(std.testing.allocator, .{ .ref = "", .role = "link", .name = "Open", .value = "", .backend_node_id = bid, .depth = 2 });
        bid += 1;
    }
    const result = try buildSnapshot(nodes.items, .{ .compact = true, .hierarchy = true, .limit = 2 }, std.testing.allocator);
    defer {
        for (result) |n| if (n.ref.len != 0) std.testing.allocator.free(n.ref);
        for (result) |n| if (std.mem.eql(u8, n.role, "…")) std.testing.allocator.free(n.name);
        std.testing.allocator.free(result);
    }
    const text = try formatCompact(result, std.testing.allocator);
    defer std.testing.allocator.free(text);
    var articles: usize = 0;
    var links: usize = 0;
    for (result) |n| {
        if (std.mem.eql(u8, n.role, "article")) articles += 1;
        if (std.mem.eql(u8, n.role, "link")) links += 1;
    }
    // first 2 articles (with their links) kept; remaining 3 collapse to a summary
    try std.testing.expectEqual(@as(usize, 2), articles);
    try std.testing.expectEqual(@as(usize, 2), links);
    try std.testing.expect(std.mem.indexOf(u8, text, "+3 more article") != null);
}

test "buildSnapshot refs are stable across snapshots despite sibling reorders" {
    // First snapshot: two buttons.
    const nodes1 = [_]A11yNode{
        .{ .ref = "", .role = "button", .name = "Save", .value = "", .backend_node_id = 42, .depth = 0 },
        .{ .ref = "", .role = "button", .name = "Cancel", .value = "", .backend_node_id = 43, .depth = 0 },
    };
    const result1 = try buildSnapshot(&nodes1, .{ .compact = true }, std.testing.allocator);
    defer {
        for (result1) |n| if (n.ref.len != 0) std.testing.allocator.free(n.ref);
        std.testing.allocator.free(result1);
    }

    // Second snapshot: a new button inserted before "Save"; Save/Cancel keep their backend ids.
    const nodes2 = [_]A11yNode{
        .{ .ref = "", .role = "button", .name = "New", .value = "", .backend_node_id = 99, .depth = 0 },
        .{ .ref = "", .role = "button", .name = "Save", .value = "", .backend_node_id = 42, .depth = 0 },
        .{ .ref = "", .role = "button", .name = "Cancel", .value = "", .backend_node_id = 43, .depth = 0 },
    };
    const result2 = try buildSnapshot(&nodes2, .{ .compact = true }, std.testing.allocator);
    defer {
        for (result2) |n| if (n.ref.len != 0) std.testing.allocator.free(n.ref);
        std.testing.allocator.free(result2);
    }

    // Positionally, "Save" was index 0 (ref "e0") in the first snapshot and is
    // index 1 in the second — a purely positional scheme would reassign its
    // ref to whatever "e0" now means (the new "New" button), silently
    // redirecting a stale action. Backend-id-keyed refs must not do that:
    // find "Save" in each result and confirm its ref is identical.
    var save1: ?[]const u8 = null;
    for (result1) |n| if (std.mem.eql(u8, n.name, "Save")) {
        save1 = n.ref;
    };
    var save2: ?[]const u8 = null;
    for (result2) |n| if (std.mem.eql(u8, n.name, "Save")) {
        save2 = n.ref;
    };
    try std.testing.expect(save1 != null and save2 != null);
    try std.testing.expectEqualStrings(save1.?, save2.?);

    // Guards against a degenerate formatRef that ignores backend_node_id and
    // returns a constant string (which the equality check above alone
    // wouldn't catch): the newly-inserted node must get its own distinct ref.
    var new_ref: ?[]const u8 = null;
    for (result2) |n| if (std.mem.eql(u8, n.name, "New")) {
        new_ref = n.ref;
    };
    try std.testing.expect(new_ref != null);
    try std.testing.expect(!std.mem.eql(u8, new_ref.?, save2.?));
}
test "formatRef folds generation in only once nonzero, so gen 0 costs no extra bytes" {
    const allocator = std.testing.allocator;

    const gen0 = try formatRef(allocator, 0, 42, 0);
    defer allocator.free(gen0);
    try std.testing.expectEqualStrings("e42", gen0);

    const gen1 = try formatRef(allocator, 1, 42, 0);
    defer allocator.free(gen1);
    try std.testing.expectEqualStrings("e1_42", gen1);

    // Same backend id, different generation → different ref strings, so a
    // ref minted before a navigation can never be mistaken for one minted
    // after, even if CDP reuses the numeric backend id post-navigation.
    try std.testing.expect(!std.mem.eql(u8, gen0, gen1));
}

test "formatRef falls back to an index-based ref when backend id is unavailable" {
    const allocator = std.testing.allocator;

    const gen0 = try formatRef(allocator, 0, null, 3);
    defer allocator.free(gen0);
    try std.testing.expectEqualStrings("ei3", gen0);

    const gen1 = try formatRef(allocator, 2, null, 3);
    defer allocator.free(gen1);
    try std.testing.expectEqualStrings("e2_i3", gen1);
}
