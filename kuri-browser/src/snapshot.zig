const std = @import("std");
const dom = @import("dom.zig");

pub const SnapshotNode = struct {
    node_id: dom.NodeId,
    ref: []const u8,
    role: []const u8,
    name: []const u8,
    value: []const u8,
    state: []const u8,
    description: []const u8,
    depth: u16,
};

pub fn buildInteractiveSnapshot(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    root_id: dom.NodeId,
) ![]SnapshotNode {
    var nodes: std.ArrayList(SnapshotNode) = .empty;
    var ref_index: usize = 0;

    const root = document.getNode(root_id);
    if (root.kind == .element) {
        try collectSnapshotNodes(allocator, document, root_id, 0, &ref_index, &nodes);
    } else {
        var child = root.first_child;
        while (child) |child_id| : (child = document.getNode(child_id).next_sibling) {
            try collectSnapshotNodes(allocator, document, child_id, 0, &ref_index, &nodes);
        }
    }

    return try nodes.toOwnedSlice(allocator);
}

pub fn formatCompact(allocator: std.mem.Allocator, nodes: []const SnapshotNode) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (nodes) |node| {
        for (0..node.depth) |_| {
            try buf.appendSlice(allocator, "  ");
        }
        try buf.appendSlice(allocator, node.role);
        if (node.name.len > 0) {
            try buf.print(allocator, " \"{s}\"", .{node.name});
        }
        try buf.print(allocator, " @{s}", .{node.ref});
        if (node.value.len > 0) {
            try buf.print(allocator, " = {s}", .{node.value});
        }
        if (node.state.len > 0) {
            try buf.print(allocator, " [{s}]", .{node.state});
        }
        if (node.description.len > 0) {
            try buf.print(allocator, " desc=\"{s}\"", .{node.description});
        }
        try buf.append(allocator, '\n');
    }
    return try buf.toOwnedSlice(allocator);
}

pub fn freeSnapshot(allocator: std.mem.Allocator, nodes: []const SnapshotNode) void {
    for (nodes) |node| {
        allocator.free(node.ref);
        allocator.free(node.role);
        allocator.free(node.name);
        allocator.free(node.value);
        allocator.free(node.state);
        allocator.free(node.description);
    }
    allocator.free(nodes);
}

fn collectSnapshotNodes(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    node_id: dom.NodeId,
    depth: u16,
    ref_index: *usize,
    nodes: *std.ArrayList(SnapshotNode),
) !void {
    const node = document.getNode(node_id);
    if (node.kind != .element) return;

    if (try snapshotNodeFor(allocator, document, node_id, depth, ref_index.*)) |snap| {
        try nodes.append(allocator, snap);
        ref_index.* += 1;
    }

    var child = node.first_child;
    while (child) |child_id| : (child = document.getNode(child_id).next_sibling) {
        try collectSnapshotNodes(allocator, document, child_id, depth + 1, ref_index, nodes);
    }
}

fn snapshotNodeFor(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    node_id: dom.NodeId,
    depth: u16,
    ref_index: usize,
) !?SnapshotNode {
    const role = try roleForNode(allocator, document, node_id) orelse return null;
    errdefer allocator.free(role);

    const name = try nameForNode(allocator, document, node_id, role);
    errdefer allocator.free(name);

    const value = try valueForNode(allocator, document, node_id, role);
    errdefer allocator.free(value);

    const state = try stateForNode(allocator, document, node_id, role);
    errdefer allocator.free(state);

    const description = try descriptionForNode(allocator, document, node_id, role);
    errdefer allocator.free(description);

    return .{
        .node_id = node_id,
        .ref = try std.fmt.allocPrint(allocator, "e{d}", .{ref_index}),
        .role = role,
        .name = name,
        .value = value,
        .state = state,
        .description = description,
        .depth = depth,
    };
}

fn roleForNode(allocator: std.mem.Allocator, document: *const dom.Document, node_id: dom.NodeId) !?[]const u8 {
    if (document.getAttribute(node_id, "role")) |explicit| {
        const lowered = try lowerDuped(allocator, explicit);
        if (isInteractiveRole(lowered)) return lowered;
        allocator.free(lowered);
    }

    const node = document.getNode(node_id);
    const tag = node.name;
    if (std.ascii.eqlIgnoreCase(tag, "a")) {
        if (document.getAttribute(node_id, "href") != null) return try dupConst(allocator, "link");
        return null;
    }
    if (std.ascii.eqlIgnoreCase(tag, "button")) return try dupConst(allocator, "button");
    if (std.ascii.eqlIgnoreCase(tag, "textarea")) return try dupConst(allocator, "textbox");
    if (std.ascii.eqlIgnoreCase(tag, "select")) return try dupConst(allocator, "combobox");
    if (std.ascii.eqlIgnoreCase(tag, "summary")) return try dupConst(allocator, "button");

    if (std.ascii.eqlIgnoreCase(tag, "input")) {
        const input_type = document.getAttribute(node_id, "type") orelse "text";
        if (std.ascii.eqlIgnoreCase(input_type, "hidden")) return null;
        if (std.ascii.eqlIgnoreCase(input_type, "checkbox")) return try dupConst(allocator, "checkbox");
        if (std.ascii.eqlIgnoreCase(input_type, "radio")) return try dupConst(allocator, "radio");
        if (std.ascii.eqlIgnoreCase(input_type, "range")) return try dupConst(allocator, "slider");
        if (std.ascii.eqlIgnoreCase(input_type, "number")) return try dupConst(allocator, "spinbutton");
        if (std.ascii.eqlIgnoreCase(input_type, "search")) return try dupConst(allocator, "searchbox");
        if (std.ascii.eqlIgnoreCase(input_type, "submit") or
            std.ascii.eqlIgnoreCase(input_type, "button") or
            std.ascii.eqlIgnoreCase(input_type, "reset") or
            std.ascii.eqlIgnoreCase(input_type, "file"))
        {
            return try dupConst(allocator, "button");
        }
        return try dupConst(allocator, "textbox");
    }

    if (document.getAttribute(node_id, "tabindex")) |tabindex| {
        const trimmed = std.mem.trim(u8, tabindex, " \t\r\n");
        if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "-1")) {
            return try dupConst(allocator, "generic");
        }
    }
    if (document.getAttribute(node_id, "contenteditable")) |editable| {
        if (!std.mem.eql(u8, std.mem.trim(u8, editable, " \t\r\n"), "false")) {
            return try dupConst(allocator, "textbox");
        }
    }

    return null;
}

fn nameForNode(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    node_id: dom.NodeId,
    role: []const u8,
) ![]const u8 {
    if (document.getAttribute(node_id, "aria-label")) |value| {
        return normalizeDuped(allocator, value);
    }
    if (document.getAttribute(node_id, "alt")) |value| {
        return normalizeDuped(allocator, value);
    }
    if (try associatedLabelText(allocator, document, node_id)) |label| {
        return label;
    }

    if (std.mem.eql(u8, role, "button")) {
        if (document.getAttribute(node_id, "value")) |value| {
            const normalized = try normalizeDuped(allocator, value);
            if (normalized.len > 0) return normalized;
            allocator.free(normalized);
        }
    }

    const text = try document.textContent(allocator, node_id);
    if (text.len > 0) return text;
    allocator.free(text);

    if (document.getAttribute(node_id, "placeholder")) |value| {
        return normalizeDuped(allocator, value);
    }
    if (document.getAttribute(node_id, "title")) |value| {
        return normalizeDuped(allocator, value);
    }
    if (document.getAttribute(node_id, "name")) |value| {
        return normalizeDuped(allocator, value);
    }

    return allocator.dupe(u8, "");
}

fn valueForNode(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    node_id: dom.NodeId,
    role: []const u8,
) ![]const u8 {
    if (std.mem.eql(u8, role, "textbox") or
        std.mem.eql(u8, role, "searchbox") or
        std.mem.eql(u8, role, "spinbutton") or
        std.mem.eql(u8, role, "slider"))
    {
        if (document.getAttribute(node_id, "value")) |value| {
            return normalizeDuped(allocator, value);
        }
        if (std.ascii.eqlIgnoreCase(document.getNode(node_id).name, "textarea")) {
            return document.textContent(allocator, node_id);
        }
    }

    if (std.mem.eql(u8, role, "combobox")) {
        if (try selectedOptionText(allocator, document, node_id)) |selected| return selected;
    }

    return allocator.dupe(u8, "");
}

fn stateForNode(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    node_id: dom.NodeId,
    role: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    try appendStateIfPresent(allocator, &out, document, node_id, "disabled", "disabled=true");
    try appendStateIfPresent(allocator, &out, document, node_id, "readonly", "readonly=true");
    try appendStateIfPresent(allocator, &out, document, node_id, "required", "required=true");
    try appendStateIfPresent(allocator, &out, document, node_id, "selected", "selected=true");
    try appendStateIfPresent(allocator, &out, document, node_id, "open", "expanded=true");

    if (std.mem.eql(u8, role, "checkbox") or std.mem.eql(u8, role, "radio")) {
        if (document.getAttribute(node_id, "checked") != null) {
            try appendStatePart(allocator, &out, "checked=true");
        } else {
            try appendStatePart(allocator, &out, "checked=false");
        }
    }

    if (std.mem.eql(u8, role, "combobox")) {
        if (document.getAttribute(node_id, "multiple") != null) {
            try appendStatePart(allocator, &out, "multiselect=true");
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn descriptionForNode(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    node_id: dom.NodeId,
    role: []const u8,
) ![]const u8 {
    if (document.getAttribute(node_id, "aria-description")) |value| {
        return normalizeDuped(allocator, value);
    }
    if (document.getAttribute(node_id, "title")) |value| {
        return normalizeDuped(allocator, value);
    }
    if (std.mem.eql(u8, role, "textbox") or std.mem.eql(u8, role, "searchbox")) {
        if (document.getAttribute(node_id, "placeholder")) |value| {
            return normalizeDuped(allocator, value);
        }
    }
    if (std.mem.eql(u8, role, "link")) {
        if (document.getAttribute(node_id, "href")) |value| {
            return normalizeDuped(allocator, value);
        }
    }
    return allocator.dupe(u8, "");
}

fn selectedOptionText(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    select_id: dom.NodeId,
) !?[]const u8 {
    const options = try document.querySelectorAll(allocator, select_id, "option");
    defer allocator.free(options);
    for (options) |option_id| {
        if (document.getAttribute(option_id, "selected") != null) {
            const text = try document.textContent(allocator, option_id);
            return text;
        }
    }
    if (options.len > 0) {
        const text = try document.textContent(allocator, options[0]);
        return text;
    }
    return null;
}

fn associatedLabelText(
    allocator: std.mem.Allocator,
    document: *const dom.Document,
    node_id: dom.NodeId,
) !?[]const u8 {
    var current = document.getNode(node_id).parent;
    while (current) |parent_id| : (current = document.getNode(parent_id).parent) {
        const parent = document.getNode(parent_id);
        if (parent.kind == .element and std.ascii.eqlIgnoreCase(parent.name, "label")) {
            const text = try document.textContent(allocator, parent_id);
            if (text.len > 0) return text;
            allocator.free(text);
        }
    }

    const id_value = document.getAttribute(node_id, "id") orelse return null;
    for (document.nodes, 0..) |candidate, idx| {
        if (candidate.kind != .element or !std.ascii.eqlIgnoreCase(candidate.name, "label")) continue;
        if (document.getAttribute(@intCast(idx), "for")) |for_attr| {
            if (std.mem.eql(u8, std.mem.trim(u8, for_attr, " \t\r\n"), id_value)) {
                const text = try document.textContent(allocator, @intCast(idx));
                if (text.len > 0) return text;
                allocator.free(text);
            }
        }
    }
    return null;
}

fn appendStateIfPresent(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    document: *const dom.Document,
    node_id: dom.NodeId,
    attr_name: []const u8,
    label: []const u8,
) !void {
    if (document.getAttribute(node_id, attr_name) != null) {
        try appendStatePart(allocator, out, label);
    }
}

fn appendStatePart(allocator: std.mem.Allocator, out: *std.ArrayList(u8), part: []const u8) !void {
    if (out.items.len > 0) try out.appendSlice(allocator, " ");
    try out.appendSlice(allocator, part);
}

fn lowerDuped(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const duped = try allocator.dupe(u8, trimmed);
    _ = std.ascii.lowerString(duped, duped);
    return duped;
}

fn normalizeDuped(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    var saw_space = false;
    for (trimmed) |c| {
        if (std.ascii.isWhitespace(c)) {
            saw_space = out.items.len > 0;
            continue;
        }
        if (saw_space) {
            try out.append(allocator, ' ');
            saw_space = false;
        }
        try out.append(allocator, c);
    }
    return try out.toOwnedSlice(allocator);
}

fn isInteractiveRole(role: []const u8) bool {
    const roles = [_][]const u8{
        "button",
        "link",
        "textbox",
        "searchbox",
        "combobox",
        "checkbox",
        "radio",
        "switch",
        "slider",
        "spinbutton",
        "option",
        "menuitem",
        "tab",
        "generic",
    };
    for (roles) |candidate| {
        if (std.mem.eql(u8, role, candidate)) return true;
    }
    return false;
}

fn dupConst(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    return allocator.dupe(u8, value);
}

test "build interactive snapshot captures refs, roles, and state" {
    const html =
        \\<!doctype html>
        \\<html><body>
        \\  <a href="/docs">Docs</a>
        \\  <button disabled>Save</button>
        \\  <label for="email">Email</label>
        \\  <input id="email" type="email" placeholder="name@example.com" value="hi@example.com">
        \\  <input type="checkbox" checked>
        \\</body></html>
    ;
    var document = try dom.Document.parse(std.testing.allocator, html);
    defer document.deinit();

    const nodes = try buildInteractiveSnapshot(std.testing.allocator, &document, document.root());
    defer freeSnapshot(std.testing.allocator, nodes);

    try std.testing.expectEqual(@as(usize, 4), nodes.len);
    try std.testing.expect(nodes[0].node_id != 0);
    try std.testing.expectEqualStrings("e0", nodes[0].ref);
    try std.testing.expectEqualStrings("link", nodes[0].role);
    try std.testing.expectEqualStrings("Docs", nodes[0].name);
    try std.testing.expectEqualStrings("button", nodes[1].role);
    try std.testing.expectEqualStrings("disabled=true", nodes[1].state);
    try std.testing.expectEqualStrings("textbox", nodes[2].role);
    try std.testing.expectEqualStrings("Email", nodes[2].name);
    try std.testing.expectEqualStrings("hi@example.com", nodes[2].value);
    try std.testing.expectEqualStrings("checkbox", nodes[3].role);
    try std.testing.expectEqualStrings("checked=true", nodes[3].state);
}

test "snapshot compact format is agent-friendly" {
    const html =
        \\<html><body>
        \\  <details open><summary>More</summary></details>
        \\  <a href="/pricing">Pricing</a>
        \\</body></html>
    ;
    var document = try dom.Document.parse(std.testing.allocator, html);
    defer document.deinit();

    const nodes = try buildInteractiveSnapshot(std.testing.allocator, &document, document.root());
    defer freeSnapshot(std.testing.allocator, nodes);

    const compact = try formatCompact(std.testing.allocator, nodes);
    defer std.testing.allocator.free(compact);

    try std.testing.expect(std.mem.indexOf(u8, compact, "button \"More\" @e0 [expanded=true]") != null);
    try std.testing.expect(std.mem.indexOf(u8, compact, "link \"Pricing\" @e1 desc=\"/pricing\"") != null);
}
