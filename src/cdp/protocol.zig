const std = @import("std");

/// CDP JSON-RPC message envelope
pub const CdpMessage = struct {
    id: u32,
    method: []const u8,
};

/// CDP response
pub const CdpResponse = struct {
    id: u32,
    result: ?std.json.Value = null,
    @"error": ?CdpError = null,
};

pub const CdpError = struct {
    code: i32,
    message: []const u8,
};

/// CDP Target info
pub const TargetInfo = struct {
    targetId: []const u8,
    type: []const u8,
    title: []const u8,
    url: []const u8,
    attached: bool = false,
};

/// Accessibility node from CDP
pub const RawA11yNode = struct {
    nodeId: []const u8,
    role: ?RoleValue = null,
    name: ?NameValue = null,
    backendDOMNodeId: ?u32 = null,
    childIds: ?[]const []const u8 = null,
    parentId: ?[]const u8 = null,
};

pub const RoleValue = struct {
    type: []const u8 = "role",
    value: []const u8 = "",
};

pub const NameValue = struct {
    type: []const u8 = "string",
    value: []const u8 = "",
};

/// CDP methods we use
pub const Methods = struct {
    pub const target_get_targets = "Target.getTargets";
    pub const target_create_target = "Target.createTarget";
    pub const target_close_target = "Target.closeTarget";
    pub const target_attach_to_target = "Target.attachToTarget";
    pub const page_navigate = "Page.navigate";
    pub const page_add_script = "Page.addScriptToEvaluateOnNewDocument";
    pub const runtime_evaluate = "Runtime.evaluate";
    pub const dom_get_document = "DOM.getDocument";
    pub const accessibility_get_full_tree = "Accessibility.getFullAXTree";
    pub const page_capture_screenshot = "Page.captureScreenshot";
};

test "methods are valid strings" {
    try std.testing.expectEqualStrings("Page.navigate", Methods.page_navigate);
    try std.testing.expectEqualStrings("Accessibility.getFullAXTree", Methods.accessibility_get_full_tree);
}
