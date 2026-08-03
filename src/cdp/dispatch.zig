const std = @import("std");
const CdpClient = @import("client.zig").CdpClient;
const protocol = @import("protocol.zig");
const ActionKind = @import("actions.zig").ActionKind;

/// Result of dispatching one action. `label` is a normalized action name
/// ("clicked", "focused", "filled", ...) safe for any caller to build a
/// response from. `raw_response` is the raw CDP Runtime.callFunctionOn
/// response body, present for every kind except click/check/uncheck (which
/// never calls callFunctionOn as its final step) -- handleAction forwards it
/// as-is to preserve its exact current external response shape; callers that
/// don't care (handleBatch, replay) just use `label`.
pub const ActionOutcome = struct {
    label: []const u8,
    raw_response: ?[]const u8 = null,
};

pub const DispatchError = struct { status: u10, message: []const u8 };

pub const DispatchResult = union(enum) {
    outcome: ActionOutcome,
    err: DispatchError,
};

const internal_error = DispatchResult{ .err = .{ .status = 500, .message = "Internal Server Error" } };

fn jsonEscapeAlloc(allocator: std.mem.Allocator, input: []const u8) ?[]const u8 {
    var out_len: usize = 0;
    for (input) |c| {
        out_len += switch (c) {
            '"', '\\' => 2,
            '\n', '\r', '\t' => 2,
            else => if (c < 0x20) @as(usize, 6) else 1,
        };
    }
    if (out_len == input.len) return input;
    const buf = allocator.alloc(u8, out_len) catch return null;
    var i: usize = 0;
    for (input) |c| {
        switch (c) {
            '"' => {
                buf[i] = '\\';
                buf[i + 1] = '"';
                i += 2;
            },
            '\\' => {
                buf[i] = '\\';
                buf[i + 1] = '\\';
                i += 2;
            },
            '\n' => {
                buf[i] = '\\';
                buf[i + 1] = 'n';
                i += 2;
            },
            '\r' => {
                buf[i] = '\\';
                buf[i + 1] = 'r';
                i += 2;
            },
            '\t' => {
                buf[i] = '\\';
                buf[i + 1] = 't';
                i += 2;
            },
            else => if (c < 0x20) {
                const hex = "0123456789abcdef";
                buf[i] = '\\';
                buf[i + 1] = 'u';
                buf[i + 2] = '0';
                buf[i + 3] = '0';
                buf[i + 4] = hex[c >> 4];
                buf[i + 5] = hex[c & 0x0f];
                i += 6;
            } else {
                buf[i] = c;
                i += 1;
            },
        }
    }
    return buf;
}

fn extractSimpleJsonString(json: []const u8, start: usize, field: []const u8) ?[]const u8 {
    const field_pos = std.mem.indexOfPos(u8, json, start, field) orelse return null;
    if (field_pos - start > 1000) return null;
    const colon = std.mem.indexOfScalarPos(u8, json, field_pos + field.len, ':') orelse return null;
    var i = colon + 1;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    if (i >= json.len or json[i] != '"') return null;
    const val_start = i + 1;
    const val_end = std.mem.indexOfScalarPos(u8, json, val_start, '"') orelse return null;
    return json[val_start..val_end];
}

const value_action_fn =
    \\function(value, append) {
    \\  const target = (() => {
    \\    if (!this) return null;
    \\    if (this instanceof HTMLLabelElement && this.control) return this.control;
    \\    if (this instanceof HTMLInputElement || this instanceof HTMLTextAreaElement || this instanceof HTMLSelectElement) return this;
    \\    if (this.isContentEditable) return this;
    \\    if (typeof this.querySelector === "function") {
    \\      const nested = this.querySelector("input,textarea,select,[contenteditable=\"true\"],[contenteditable=\"\"],[role=\"textbox\"]");
    \\      if (nested) return nested;
    \\    }
    \\    return this;
    \\  })();
    \\  if (!target) return "missing-target";
    \\  target.focus?.();
    \\  if (target.isContentEditable) {
    \\    const existing = typeof target.textContent === "string" ? target.textContent : "";
    \\    target.textContent = append ? (existing + value) : value;
    \\  } else if ("value" in target) {
    \\    const existing = typeof target.value === "string" ? target.value : "";
    \\    target.value = append ? (existing + value) : value;
    \\  }
    \\  target.dispatchEvent(new Event("input", {bubbles:true}));
    \\  target.dispatchEvent(new Event("change", {bubbles:true}));
    \\  return "filled";
    \\}
;

const select_action_fn =
    \\function(value) {
    \\  const target = (() => {
    \\    if (!this) return null;
    \\    if (this instanceof HTMLLabelElement && this.control) return this.control;
    \\    if (this instanceof HTMLSelectElement) return this;
    \\    if (typeof this.querySelector === "function") {
    \\      const nested = this.querySelector("select");
    \\      if (nested) return nested;
    \\    }
    \\    return this;
    \\  })();
    \\  if (!target) return "missing-target";
    \\  let next = value;
    \\  if ("options" in target && target.options) {
    \\    for (const opt of target.options) {
    \\      const text = (opt.textContent || "").trim();
    \\      const label = (opt.label || "").trim();
    \\      if (opt.value === value || text === value || label === value) {
    \\        next = opt.value;
    \\        break;
    \\      }
    \\    }
    \\  }
    \\  if ("value" in target) target.value = next;
    \\  target.dispatchEvent(new Event("input", {bubbles:true}));
    \\  target.dispatchEvent(new Event("change", {bubbles:true}));
    \\  return "selected";
    \\}
;

const focus_fn =
    \\function() {
    \\  const target = (() => {
    \\    if (!this) return null;
    \\    if (this instanceof HTMLLabelElement && this.control) return this.control;
    \\    if (this instanceof HTMLInputElement || this instanceof HTMLTextAreaElement || this.isContentEditable) return this;
    \\    if (typeof this.querySelector === "function") {
    \\      const nested = this.querySelector("input,textarea,[contenteditable=\"true\"],[contenteditable=\"\"],[role=\"textbox\"]");
    \\      if (nested) return nested;
    \\    }
    \\    return this;
    \\  })();
    \\  if (!target) return "missing-target";
    \\  target.focus?.();
    \\  if (target.isContentEditable) {
    \\    target.textContent = "";
    \\  } else if ("value" in target) {
    \\    target.value = "";
    \\  }
    \\  target.dispatchEvent(new Event("focus", {bubbles:true}));
    \\  return "focused";
    \\}
;

const change_fn =
    \\function() {
    \\  const target = (() => {
    \\    if (!this) return null;
    \\    if (this instanceof HTMLLabelElement && this.control) return this.control;
    \\    if (this instanceof HTMLInputElement || this instanceof HTMLTextAreaElement || this.isContentEditable) return this;
    \\    if (typeof this.querySelector === "function") {
    \\      const nested = this.querySelector("input,textarea,[contenteditable=\"true\"],[contenteditable=\"\"],[role=\"textbox\"]");
    \\      if (nested) return nested;
    \\    }
    \\    return this;
    \\  })();
    \\  if (!target) return "missing-target";
    \\  target.dispatchEvent(new Event("input", {bubbles:true}));
    \\  target.dispatchEvent(new Event("change", {bubbles:true}));
    \\  target.dispatchEvent(new Event("blur", {bubbles:true}));
    \\  return "filled";
    \\}
;

/// Ported from the pre-extraction cdpClickHttp: rect-compute via a JS
/// Runtime.callFunctionOn, then a real Input.dispatchMouseEvent press+release
/// at the computed screen coordinates (kept for React/Vue compatibility --
/// see #164 in the original). check/uncheck skip the mouse event entirely
/// when the box is already in the target state, matching prior behavior.
fn dispatchClick(arena: std.mem.Allocator, client: *CdpClient, object_id: []const u8, kind: ActionKind) DispatchResult {
    const rect_js: []const u8 = switch (kind) {
        .check => "function() { this.scrollIntoViewIfNeeded(); if (this.checked) return 'skip'; const r = this.getBoundingClientRect(); return (r.x+r.width/2)+','+(r.y+r.height/2); }",
        .uncheck => "function() { this.scrollIntoViewIfNeeded(); if (!this.checked) return 'skip'; const r = this.getBoundingClientRect(); return (r.x+r.width/2)+','+(r.y+r.height/2); }",
        else => "function() { this.scrollIntoViewIfNeeded(); const r = this.getBoundingClientRect(); return (r.x+r.width/2)+','+(r.y+r.height/2); }",
    };

    const escaped_rect = jsonEscapeAlloc(arena, rect_js) orelse return internal_error;
    const rect_params = std.fmt.allocPrint(arena, "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"returnByValue\":true}}", .{ object_id, escaped_rect }) catch return internal_error;
    const rect_resp = client.send(arena, protocol.Methods.runtime_call_function_on, rect_params) catch {
        return .{ .err = .{ .status = 502, .message = "getBoundingClientRect failed" } };
    };
    const coords_str = extractSimpleJsonString(rect_resp, 0, "\"value\"") orelse {
        return .{ .err = .{ .status = 500, .message = "Could not parse element coordinates" } };
    };

    const label: []const u8 = switch (kind) {
        .check => "checked",
        .uncheck => "unchecked",
        else => "clicked",
    };

    if (std.mem.eql(u8, coords_str, "skip")) {
        return .{ .outcome = .{ .label = label } };
    }

    const comma = std.mem.indexOfScalar(u8, coords_str, ',') orelse {
        return .{ .err = .{ .status = 500, .message = "Could not parse element coordinates" } };
    };
    const x = std.fmt.parseFloat(f64, coords_str[0..comma]) catch {
        return .{ .err = .{ .status = 500, .message = "Could not parse element x coordinate" } };
    };
    const y = std.fmt.parseFloat(f64, coords_str[comma + 1 ..]) catch {
        return .{ .err = .{ .status = 500, .message = "Could not parse element y coordinate" } };
    };
    const x_int: i64 = @intFromFloat(@round(x));
    const y_int: i64 = @intFromFloat(@round(y));

    const down_params = std.fmt.allocPrint(arena, "{{\"type\":\"mousePressed\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"clickCount\":1}}", .{ x_int, y_int }) catch return internal_error;
    _ = client.send(arena, protocol.Methods.input_dispatch_mouse_event, down_params) catch {
        return .{ .err = .{ .status = 502, .message = "Input.dispatchMouseEvent(mousePressed) failed" } };
    };

    const up_params = std.fmt.allocPrint(arena, "{{\"type\":\"mouseReleased\",\"x\":{d},\"y\":{d},\"button\":\"left\",\"clickCount\":1}}", .{ x_int, y_int }) catch return internal_error;
    _ = client.send(arena, protocol.Methods.input_dispatch_mouse_event, up_params) catch {
        return .{ .err = .{ .status = 502, .message = "Input.dispatchMouseEvent(mouseReleased) failed" } };
    };

    return .{ .outcome = .{ .label = label } };
}

/// The default (realistic=true) fill/type path: focus the target via one
/// callFunctionOn, dispatch real Input.dispatchKeyEvent pairs per character
/// (for React/Vue compatibility -- #164), then a final callFunctionOn that
/// fires input/change/blur. Individual keystroke failures are swallowed
/// (`catch continue`) rather than aborting the whole fill, matching the
/// pre-extraction behavior exactly.
fn dispatchRealisticFill(arena: std.mem.Allocator, client: *CdpClient, object_id: []const u8, v: []const u8) DispatchResult {
    const escaped_focus_fn = jsonEscapeAlloc(arena, focus_fn) orelse return internal_error;
    const focus_params = std.fmt.allocPrint(arena, "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"returnByValue\":true}}", .{ object_id, escaped_focus_fn }) catch return internal_error;
    _ = client.send(arena, protocol.Methods.runtime_call_function_on, focus_params) catch {
        return .{ .err = .{ .status = 502, .message = "Runtime.callFunctionOn failed" } };
    };

    for (v) |ch| {
        const char_str = std.fmt.allocPrint(arena, "{c}", .{ch}) catch continue;
        const key_params = std.fmt.allocPrint(arena, "{{\"type\":\"keyDown\",\"text\":\"{s}\",\"key\":\"{s}\",\"unmodifiedText\":\"{s}\"}}", .{ char_str, char_str, char_str }) catch continue;
        _ = client.send(arena, protocol.Methods.input_dispatch_key_event, key_params) catch continue;
        const up_params = std.fmt.allocPrint(arena, "{{\"type\":\"keyUp\",\"key\":\"{s}\"}}", .{char_str}) catch continue;
        _ = client.send(arena, protocol.Methods.input_dispatch_key_event, up_params) catch continue;
    }

    const escaped_change_fn = jsonEscapeAlloc(arena, change_fn) orelse return internal_error;
    const change_params = std.fmt.allocPrint(arena, "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"returnByValue\":true}}", .{ object_id, escaped_change_fn }) catch return internal_error;
    const change_response = client.send(arena, protocol.Methods.runtime_call_function_on, change_params) catch {
        return .{ .err = .{ .status = 502, .message = "Runtime.callFunctionOn failed" } };
    };
    return .{ .outcome = .{ .label = "filled", .raw_response = change_response } };
}

/// focus/hover/dblclick/blur (no-arg JS) and select/non-realistic-fill|type
/// (JS called with arguments) all resolve to exactly one
/// Runtime.callFunctionOn call -- built here to match the pre-extraction
/// per-kind argument shapes exactly.
fn dispatchCallFunction(arena: std.mem.Allocator, client: *CdpClient, object_id: []const u8, kind: ActionKind, value: ?[]const u8, realistic: bool) DispatchResult {
    if ((kind == .fill or kind == .type) and realistic) {
        const v = value orelse return .{ .err = .{ .status = 400, .message = "Missing value parameter for fill/type" } };
        return dispatchRealisticFill(arena, client, object_id, v);
    }

    const js_fn: []const u8 = switch (kind) {
        .focus => "function() { this.focus(); return 'focused'; }",
        .hover => "function() { this.dispatchEvent(new MouseEvent('mouseover', {bubbles:true})); return 'hovered'; }",
        .dblclick => "function() { this.scrollIntoViewIfNeeded(); this.dispatchEvent(new MouseEvent('dblclick', {bubbles:true,cancelable:true})); return 'dblclicked'; }",
        .blur => "function() { this.blur(); return 'blurred'; }",
        .fill, .type => value_action_fn,
        .select => select_action_fn,
        .click, .check, .uncheck, .scroll, .press => unreachable, // handled by the caller / dispatchClick before reaching here
    };
    const escaped_js_fn = jsonEscapeAlloc(arena, js_fn) orelse return internal_error;

    const call_params = switch (kind) {
        .fill, .type => blk: {
            const v = value orelse return .{ .err = .{ .status = 400, .message = "Missing value parameter for fill/type" } };
            const escaped_v = jsonEscapeAlloc(arena, v) orelse return internal_error;
            break :blk std.fmt.allocPrint(
                arena,
                "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"arguments\":[{{\"value\":\"{s}\"}},{{\"value\":{s}}}],\"returnByValue\":true}}",
                .{ object_id, escaped_js_fn, escaped_v, if (kind == .type) "true" else "false" },
            );
        },
        .select => blk: {
            const v = value orelse return .{ .err = .{ .status = 400, .message = "Missing value parameter for select" } };
            const escaped_v = jsonEscapeAlloc(arena, v) orelse return internal_error;
            break :blk std.fmt.allocPrint(
                arena,
                "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"arguments\":[{{\"value\":\"{s}\"}}],\"returnByValue\":true}}",
                .{ object_id, escaped_js_fn, escaped_v },
            );
        },
        else => std.fmt.allocPrint(
            arena,
            "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"{s}\",\"returnByValue\":true}}",
            .{ object_id, escaped_js_fn },
        ),
    } catch return internal_error;

    const call_response = client.send(arena, protocol.Methods.runtime_call_function_on, call_params) catch {
        return .{ .err = .{ .status = 502, .message = "Runtime.callFunctionOn failed" } };
    };

    const label: []const u8 = switch (kind) {
        .focus => "focused",
        .hover => "hovered",
        .dblclick => "dblclicked",
        .blur => "blurred",
        .fill, .type => "filled",
        .select => "selected",
        .click, .check, .uncheck, .scroll, .press => unreachable,
    };
    return .{ .outcome = .{ .label = label, .raw_response = call_response } };
}

/// Resolves `backend_node_id` to a CDP objectId and dispatches `kind` on it.
/// Requires an element-targeted kind: click/check/uncheck/focus/hover/blur/
/// dblclick/fill/type/select. `.scroll` and `.press` are document-scoped and
/// ref-less -- callers must special-case them themselves before calling this,
/// exactly as they already do today for the same reason.
pub fn dispatchActionOnBackendNode(
    arena: std.mem.Allocator,
    client: *CdpClient,
    backend_node_id: u32,
    kind: ActionKind,
    value: ?[]const u8,
    realistic: bool,
) DispatchResult {
    const resolve_params = std.fmt.allocPrint(arena, "{{\"backendNodeId\":{d}}}", .{backend_node_id}) catch return internal_error;
    const resolve_response = client.send(arena, protocol.Methods.dom_resolve_node, resolve_params) catch {
        return .{ .err = .{ .status = 502, .message = "DOM.resolveNode failed" } };
    };
    const object_id = extractSimpleJsonString(resolve_response, 0, "\"objectId\"") orelse {
        return .{ .err = .{ .status = 500, .message = "Could not resolve element objectId" } };
    };

    if (kind == .click or kind == .check or kind == .uncheck) {
        return dispatchClick(arena, client, object_id, kind);
    }
    return dispatchCallFunction(arena, client, object_id, kind, value, realistic);
}
