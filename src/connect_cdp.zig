//! connect_cdp.zig — shared CDP capture/restore for the `connect` feature.
//!
//! Used by both kuri-agent (in-process fallback) and kuri-connect-broker (the
//! key-holding daemon). Captures a tab's session (cookies + localStorage +
//! sessionStorage) into the canonical payload JSON, and restores a payload back
//! into a tab. Self-contained: it only touches a `CdpClient`, never the vault.

const std = @import("std");
const compat = @import("compat.zig");
const protocol = @import("cdp/protocol.zig");
const CdpClient = @import("cdp/client.zig").CdpClient;

fn escapeJson(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        else => try out.append(arena, c),
    };
    return out.items;
}

fn extractString(json: []const u8, start: usize, field: []const u8) ?[]const u8 {
    const field_pos = std.mem.indexOfPos(u8, json, start, field) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, json, field_pos + field.len, ':') orelse return null;
    var i = colon + 1;
    while (i < json.len and (json[i] == ' ' or json[i] == '\n' or json[i] == '\r')) : (i += 1) {}
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const end = std.mem.indexOfScalarPos(u8, json, i, '"') orelse return null;
    return json[i..end];
}

/// Balanced {…} or […] span immediately after `key`, respecting string literals.
fn extractBalancedAfter(s: []const u8, key: []const u8) ?[]const u8 {
    const kpos = std.mem.indexOf(u8, s, key) orelse return null;
    var i = kpos + key.len;
    while (i < s.len and s[i] != '{' and s[i] != '[') : (i += 1) {}
    if (i >= s.len) return null;
    const open = s[i];
    const close: u8 = if (open == '{') '}' else ']';
    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    var j = i;
    while (j < s.len) : (j += 1) {
        const c = s[j];
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
        } else if (c == '"') {
            in_str = true;
        } else if (c == open) {
            depth += 1;
        } else if (c == close) {
            depth -= 1;
            if (depth == 0) return s[i .. j + 1];
        }
    }
    return null;
}

fn evalParams(arena: std.mem.Allocator, expr: []const u8) []const u8 {
    const escaped = escapeJson(arena, expr) catch expr;
    return std.fmt.allocPrint(arena, "{{\"expression\":\"{s}\",\"returnByValue\":true}}", .{escaped}) catch "{}";
}

fn evalStringValue(arena: std.mem.Allocator, client: *CdpClient, expr: []const u8) ?[]const u8 {
    const resp = client.send(arena, protocol.Methods.runtime_evaluate, evalParams(arena, expr)) catch return null;
    return extractString(resp, 0, "\"value\"");
}

fn restoreStorageSnapshot(arena: std.mem.Allocator, client: *CdpClient, which: []const u8, obj_json: []const u8) void {
    const js = std.fmt.allocPrint(
        arena,
        "(()=>{{const o={s};Object.keys(o).forEach(k=>{s}.setItem(k,o[k]));}})()",
        .{ obj_json, which },
    ) catch return;
    _ = client.send(arena, protocol.Methods.runtime_evaluate, evalParams(arena, js)) catch {};
}

/// Capture the tab's current session into the canonical payload JSON. Caller owns it.
pub fn capturePayload(arena: std.mem.Allocator, client: *CdpClient, name: []const u8) ![]u8 {
    const origin = evalStringValue(arena, client, "location.origin") orelse "";
    const cookies_resp = try client.send(arena, protocol.Methods.network_get_cookies, null);
    const cookies = extractBalancedAfter(cookies_resp, "\"cookies\"") orelse "[]";
    const ls_resp = client.send(arena, protocol.Methods.runtime_evaluate, evalParams(arena, "Object.fromEntries(Object.entries(localStorage))")) catch "";
    const local_storage = extractBalancedAfter(ls_resp, "\"value\"") orelse "{}";
    const ss_resp = client.send(arena, protocol.Methods.runtime_evaluate, evalParams(arena, "Object.fromEntries(Object.entries(sessionStorage))")) catch "";
    const session_storage = extractBalancedAfter(ss_resp, "\"value\"") orelse "{}";
    const esc_name = try escapeJson(arena, name);
    const esc_origin = try escapeJson(arena, origin);
    return std.fmt.allocPrint(
        arena,
        "{{\"version\":1,\"name\":\"{s}\",\"origin\":\"{s}\",\"saved_at\":{d},\"cookies\":{s},\"local_storage\":{s},\"session_storage\":{s}}}",
        .{ esc_name, esc_origin, compat.timestampSeconds(), cookies, local_storage, session_storage },
    );
}

/// Origin recorded in a captured payload ("" if absent).
pub fn originOf(payload: []const u8) []const u8 {
    return extractString(payload, 0, "\"origin\"") orelse "";
}

/// Restore a captured payload into the tab: navigate to origin, set cookies, restore storage.
pub fn restorePayload(arena: std.mem.Allocator, client: *CdpClient, payload: []const u8) void {
    const origin = extractString(payload, 0, "\"origin\"") orelse "";
    const cookies = extractBalancedAfter(payload, "\"cookies\"") orelse "[]";
    const local_storage = extractBalancedAfter(payload, "\"local_storage\"") orelse "{}";
    const session_storage = extractBalancedAfter(payload, "\"session_storage\"") orelse "{}";

    if (origin.len > 0) {
        const esc = escapeJson(arena, origin) catch origin;
        const nav = std.fmt.allocPrint(arena, "{{\"url\":\"{s}\"}}", .{esc}) catch return;
        _ = client.send(arena, protocol.Methods.page_navigate, nav) catch {};
        compat.threadSleep(1_000_000_000);
    }
    const set_params = std.fmt.allocPrint(arena, "{{\"cookies\":{s}}}", .{cookies}) catch return;
    _ = client.send(arena, protocol.Methods.network_set_cookies, set_params) catch {};
    restoreStorageSnapshot(arena, client, "localStorage", local_storage);
    restoreStorageSnapshot(arena, client, "sessionStorage", session_storage);
}
