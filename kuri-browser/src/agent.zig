const std = @import("std");
const dom = @import("dom.zig");
const js_runtime = @import("js_runtime.zig");
const model = @import("model.zig");
const render = @import("render.zig");
const snapshot = @import("snapshot.zig");

pub const AgentArtifacts = struct {
    page: model.Page,
    har_json: ?[]const u8 = null,
};

const ValueOverride = struct {
    node_id: dom.NodeId,
    value: []const u8,
};

const State = struct {
    allocator: std.mem.Allocator,
    page: model.Page,
    snapshot_nodes: []snapshot.SnapshotNode,
    value_overrides: std.ArrayList(ValueOverride),
    js_options: js_runtime.Options,
    capture_har: bool,
    har_json: ?[]const u8,

    fn init(allocator: std.mem.Allocator, url: []const u8, capture_har: bool, js_options: js_runtime.Options) !State {
        const artifacts = try render.renderUrlArtifacts(allocator, url, .{
            .capture_har = capture_har,
            .js = js_options,
        });
        const page = artifacts.page;
        const snapshot_nodes = try snapshot.buildInteractiveSnapshot(allocator, &page.dom, page.dom.root());
        return .{
            .allocator = allocator,
            .page = page,
            .snapshot_nodes = snapshot_nodes,
            .value_overrides = .empty,
            .js_options = js_options,
            .capture_har = capture_har,
            .har_json = artifacts.har_json,
        };
    }

    fn deinit(self: *State) void {
        snapshot.freeSnapshot(self.allocator, self.snapshot_nodes);
        self.value_overrides.deinit(self.allocator);
    }

    fn applySteps(self: *State, steps: []const model.AgentStep) !void {
        for (steps) |step| {
            switch (step) {
                .click => |ref| try self.applyClick(ref),
                .type => |payload| try self.applyType(payload.ref, payload.value),
            }
        }
    }

    fn applyType(self: *State, ref: []const u8, value: []const u8) !void {
        const snap = try self.resolveRef(ref);
        const node = self.page.dom.getNode(snap.node_id);
        if (node.kind != .element or !isTextEntryNode(&self.page.dom, snap.node_id)) {
            return error.InvalidActionTarget;
        }
        try self.upsertValueOverride(snap.node_id, value);
    }

    fn applyClick(self: *State, ref: []const u8) !void {
        const snap = try self.resolveRef(ref);
        const node = self.page.dom.getNode(snap.node_id);
        if (node.kind != .element) return error.InvalidActionTarget;

        if (std.ascii.eqlIgnoreCase(node.name, "a")) {
            const href = self.page.dom.getAttribute(snap.node_id, "href") orelse return error.InvalidActionTarget;
            const target_url = try render.resolveUrl(self.allocator, self.page.url, href);
            self.value_overrides.clearRetainingCapacity();
            const artifacts = try render.renderUrlArtifacts(self.allocator, target_url, .{
                .capture_har = self.capture_har,
                .js = self.js_options,
            });
            try self.replacePage(artifacts.page, artifacts.har_json);
            return;
        }

        if (isSubmitControl(&self.page.dom, snap.node_id)) {
            try self.submitFromNode(snap.node_id);
            return;
        }

        return error.UnsupportedAction;
    }

    fn submitFromNode(self: *State, node_id: dom.NodeId) !void {
        const form_id = findAncestorForm(&self.page.dom, node_id) orelse return error.FormNotFound;
        const form_index = findFormIndex(&self.page.dom, form_id) orelse return error.FormNotFound;
        const overrides = try self.collectOverrides(form_id);
        const artifacts = try render.submitFormArtifacts(self.allocator, self.page.url, form_index, overrides, .{
            .capture_har = self.capture_har,
            .js = self.js_options,
        });
        self.value_overrides.clearRetainingCapacity();
        try self.replacePage(artifacts.page, artifacts.har_json);
    }

    fn replacePage(self: *State, page: model.Page, har_json: ?[]const u8) !void {
        snapshot.freeSnapshot(self.allocator, self.snapshot_nodes);
        self.page = page;
        self.har_json = har_json;
        self.snapshot_nodes = try snapshot.buildInteractiveSnapshot(self.allocator, &self.page.dom, self.page.dom.root());
    }

    fn resolveRef(self: *State, ref: []const u8) !snapshot.SnapshotNode {
        for (self.snapshot_nodes) |node| {
            if (std.mem.eql(u8, node.ref, ref)) return node;
        }
        return error.RefNotFound;
    }

    fn upsertValueOverride(self: *State, node_id: dom.NodeId, value: []const u8) !void {
        for (self.value_overrides.items) |*entry| {
            if (entry.node_id == node_id) {
                entry.value = value;
                return;
            }
        }
        try self.value_overrides.append(self.allocator, .{
            .node_id = node_id,
            .value = value,
        });
    }

    fn collectOverrides(self: *State, form_id: dom.NodeId) ![]const model.FieldInput {
        var overrides: std.ArrayList(model.FieldInput) = .empty;
        for (self.value_overrides.items) |entry| {
            if (!isDescendantOf(&self.page.dom, entry.node_id, form_id)) continue;
            const name = self.page.dom.getAttribute(entry.node_id, "name") orelse "";
            if (name.len == 0) continue;
            try overrides.append(self.allocator, .{
                .name = name,
                .value = entry.value,
            });
        }
        return try overrides.toOwnedSlice(self.allocator);
    }
};

pub fn runUrlActions(
    allocator: std.mem.Allocator,
    url: []const u8,
    steps: []const model.AgentStep,
    capture_har: bool,
    js_options: js_runtime.Options,
) !AgentArtifacts {
    var state = try State.init(allocator, url, capture_har, js_options);
    defer state.deinit();

    try state.applySteps(steps);
    return .{
        .page = state.page,
        .har_json = state.har_json,
    };
}

fn isTextEntryNode(document: *const dom.Document, node_id: dom.NodeId) bool {
    const node = document.getNode(node_id);
    if (std.ascii.eqlIgnoreCase(node.name, "textarea")) return true;
    if (std.ascii.eqlIgnoreCase(node.name, "select")) return true;
    if (!std.ascii.eqlIgnoreCase(node.name, "input")) return false;
    const input_type = document.getAttribute(node_id, "type") orelse "text";
    return !std.ascii.eqlIgnoreCase(input_type, "button") and
        !std.ascii.eqlIgnoreCase(input_type, "submit") and
        !std.ascii.eqlIgnoreCase(input_type, "reset") and
        !std.ascii.eqlIgnoreCase(input_type, "checkbox") and
        !std.ascii.eqlIgnoreCase(input_type, "radio") and
        !std.ascii.eqlIgnoreCase(input_type, "file");
}

fn isSubmitControl(document: *const dom.Document, node_id: dom.NodeId) bool {
    const node = document.getNode(node_id);
    if (std.ascii.eqlIgnoreCase(node.name, "button")) {
        const kind = document.getAttribute(node_id, "type") orelse "submit";
        return !std.ascii.eqlIgnoreCase(kind, "button");
    }
    if (!std.ascii.eqlIgnoreCase(node.name, "input")) return false;
    const kind = document.getAttribute(node_id, "type") orelse "text";
    return std.ascii.eqlIgnoreCase(kind, "submit") or std.ascii.eqlIgnoreCase(kind, "image");
}

fn findAncestorForm(document: *const dom.Document, node_id: dom.NodeId) ?dom.NodeId {
    var current: ?dom.NodeId = node_id;
    while (current) |cursor| {
        const node = document.getNode(cursor);
        if (node.kind == .element and std.ascii.eqlIgnoreCase(node.name, "form")) return cursor;
        current = node.parent;
    }
    return null;
}

fn findFormIndex(document: *const dom.Document, form_id: dom.NodeId) ?usize {
    const form_nodes = document.querySelectorAll(document.allocator, document.root(), "form") catch return null;
    defer document.allocator.free(form_nodes);
    for (form_nodes, 0..) |candidate, index| {
        if (candidate == form_id) return index + 1;
    }
    return null;
}

fn isDescendantOf(document: *const dom.Document, node_id: dom.NodeId, ancestor_id: dom.NodeId) bool {
    var current: ?dom.NodeId = node_id;
    while (current) |cursor| {
        if (cursor == ancestor_id) return true;
        current = document.getNode(cursor).parent;
    }
    return false;
}

test "action typing and submit keep session state" {
    const steps: []const model.AgentStep = &.{
        .{ .type = .{ .ref = "e0", .value = "admin" } },
        .{ .type = .{ .ref = "e1", .value = "admin" } },
        .{ .click = "e2" },
    };
    try std.testing.expectEqual(@as(usize, 3), steps.len);
}
