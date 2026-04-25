const std = @import("std");
const js_runtime = @import("js_runtime.zig");
const model = @import("model.zig");
const render = @import("render.zig");

pub const RuntimeStage = enum {
    scaffold,
    network,
    dom,
    js,
    agent_api,
    cdp,
};

pub const RuntimeShape = struct {
    mode: []const u8,
    shell: []const u8,
    transport: []const u8,
    dom: []const u8,
    js: []const u8,
    automation_surface: []const u8,
    fallback_strategy: []const u8,
};

pub const BrowserRuntime = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BrowserRuntime {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BrowserRuntime) void {
        _ = self;
    }

    pub fn shape(self: *const BrowserRuntime) RuntimeShape {
        _ = self;
        return .{
            .mode = "standalone experiment",
            .shell = "CLI shell with text-first views",
            .transport = "stateful fetcher with redirects, cookies, subresource loading, and curl fallback",
            .dom = "parsed HTML tree with basic selector queries",
            .js = "QuickJS evaluation with DOM shims for inline and external scripts",
            .automation_surface = "DOM queries, resource inspection, JS eval, and basic form submission",
            .fallback_strategy = "native_static -> native_js_later -> external_browser",
        };
    }

    pub fn loadPage(self: *const BrowserRuntime, url: []const u8) !model.Page {
        return self.loadPageWithOptions(url, .{});
    }

    pub fn loadPageWithOptions(self: *const BrowserRuntime, url: []const u8, js_options: js_runtime.Options) !model.Page {
        return (try render.renderUrlArtifacts(self.allocator, url, .{ .js = js_options })).page;
    }

    pub fn submitForm(self: *const BrowserRuntime, url: []const u8, form_index: usize, overrides: []const model.FieldInput) !model.Page {
        return self.submitFormWithOptions(url, form_index, overrides, .{});
    }

    pub fn submitFormWithOptions(
        self: *const BrowserRuntime,
        url: []const u8,
        form_index: usize,
        overrides: []const model.FieldInput,
        js_options: js_runtime.Options,
    ) !model.Page {
        return (try render.submitFormArtifacts(self.allocator, url, form_index, overrides, .{ .js = js_options })).page;
    }
};

pub fn stageLabel(stage: RuntimeStage) []const u8 {
    return switch (stage) {
        .scaffold => "scaffold: separate build, CLI, and experiment boundaries",
        .network => "network: HTTP navigation, redirects, cookies, and resource loading",
        .dom => "dom: parsed tree, selector queries, and stable page snapshots",
        .js => "js: embedded runtime and browser API shims",
        .agent_api => "agent_api: evaluate, snapshot, refs, and action primitives",
        .cdp => "cdp: optional compatibility layer after the core runtime is stable",
    };
}

test "shape reflects layered experiment" {
    const runtime = BrowserRuntime.init(std.testing.allocator);
    const shape = runtime.shape();
    try std.testing.expectEqualStrings("standalone experiment", shape.mode);
    try std.testing.expectEqualStrings("CLI shell with text-first views", shape.shell);
}
