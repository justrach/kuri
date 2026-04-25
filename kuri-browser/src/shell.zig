const std = @import("std");
const core = @import("core.zig");
const dom = @import("dom.zig");
const model = @import("model.zig");
const render = @import("render.zig");

pub fn usageText() []const u8 {
    return
        \\kuri-browser
        \\
        \\Standalone experimental browser-runtime workspace.
        \\This build is intentionally separate from Kuri's main build.
        \\
        \\USAGE
        \\  kuri-browser --help
        \\  kuri-browser --version
        \\  kuri-browser status
        \\  kuri-browser roadmap
        \\  kuri-browser render <url> [--dump summary|html|text|links|forms] [--selector <css>] [--har <file>]
        \\  kuri-browser submit <url> [--form-index <n>] [--field name=value ...] [--dump summary|html|text|links|forms] [--selector <css>] [--har <file>]
        \\
        \\EXAMPLES
        \\  zig build run -- --help
        \\  zig build run -- status
        \\  zig build run -- roadmap
        \\  zig build run -- render https://news.ycombinator.com
        \\  zig build run -- render https://example.com --dump html
        \\  zig build run -- render https://example.com --har example.har
        \\  zig build run -- render https://quotes.toscrape.com/login --dump forms
        \\  zig build run -- submit https://quotes.toscrape.com/login --field username=admin --field password=admin --dump text --har login.har
        \\  zig build run -- render https://news.ycombinator.com --selector ".titleline a" --dump text
        \\
    ;
}

pub fn renderStatusText(allocator: std.mem.Allocator, shape: core.RuntimeShape) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        \\kuri-browser
        \\
        \\mode: {s}
        \\shell: {s}
        \\transport: {s}
        \\dom: {s}
        \\js: {s}
        \\automation: {s}
        \\fallback: {s}
        \\
        \\intent: isolate a Zig-native browser runtime experiment from Kuri's main Chrome/CDP build
        \\
    , .{
        shape.mode,
        shape.shell,
        shape.transport,
        shape.dom,
        shape.js,
        shape.automation_surface,
        shape.fallback_strategy,
    });
}

pub fn renderRoadmapText(allocator: std.mem.Allocator) ![]const u8 {
    const stages = [_]core.RuntimeStage{
        .scaffold,
        .network,
        .dom,
        .js,
        .agent_api,
        .cdp,
    };

    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(allocator, "kuri-browser roadmap\n\n");
    for (stages) |stage| {
        const line = try std.fmt.allocPrint(allocator, "- {s}\n", .{core.stageLabel(stage)});
        try list.appendSlice(allocator, line);
    }
    return try list.toOwnedSlice(allocator);
}

pub fn renderPageText(allocator: std.mem.Allocator, page: model.Page) ![]const u8 {
    return renderPageWithFormat(allocator, page, .summary, null);
}

pub fn renderPageWithFormat(allocator: std.mem.Allocator, page: model.Page, format: model.DumpFormat, selector: ?[]const u8) ![]const u8 {
    if (selector) |sel| {
        return renderSelectorView(allocator, page, format, sel);
    }

    return switch (format) {
        .summary => renderSummaryPageText(allocator, page),
        .html => allocator.dupe(u8, page.html),
        .text => allocator.dupe(u8, page.text),
        .links => renderLinksOnlyText(allocator, page.links),
        .forms => renderFormsText(allocator, page.forms),
    };
}

fn renderSummaryPageText(allocator: std.mem.Allocator, page: model.Page) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    try out.appendSlice(allocator, "kuri-browser render\n\n");
    try out.print(allocator, "url: {s}\n", .{page.url});
    if (!std.mem.eql(u8, page.requested_url, page.url)) {
        try out.print(allocator, "requested-url: {s}\n", .{page.requested_url});
    }
    try out.print(allocator, "status: {d}\n", .{page.status_code});
    try out.print(allocator, "content-type: {s}\n", .{page.content_type});
    try out.print(allocator, "title: {s}\n", .{page.title});
    try out.print(allocator, "pipeline: {s}\n", .{page.pipeline});
    try out.print(allocator, "fallback: {s}\n", .{page.fallback_mode.label()});
    try out.print(allocator, "redirects: {d}\n", .{page.redirect_chain.len});
    try out.print(allocator, "cookies: {d}\n", .{page.cookie_count});
    try out.print(allocator, "nodes: {d}\n", .{page.dom.nodeCount()});
    try out.print(allocator, "links: {d}\n", .{page.links.len});
    try out.print(allocator, "forms: {d}\n\n", .{page.forms.len});

    try out.appendSlice(allocator, "--- text ---\n");
    const preview = previewText(page.text, 2500);
    try out.appendSlice(allocator, preview);
    if (preview.len < page.text.len) {
        try out.appendSlice(allocator, "\n\n[truncated]\n");
    }

    if (page.links.len > 0) {
        try out.appendSlice(allocator, "\n--- links ---\n");
        const limit = @min(page.links.len, 12);
        for (page.links[0..limit], 0..) |link, i| {
            const label = if (link.text.len == 0) "(no text)" else link.text;
            try out.print(allocator, "[{d}] {s}\n    {s}\n", .{ i + 1, label, link.href });
        }
        if (limit < page.links.len) {
            try out.print(allocator, "\n... {d} more links\n", .{page.links.len - limit});
        }
    }

    if (page.redirect_chain.len > 0) {
        try out.appendSlice(allocator, "\n--- redirects ---\n");
        for (page.redirect_chain, 0..) |redirect_url, i| {
            try out.print(allocator, "[{d}] {s}\n", .{ i + 1, redirect_url });
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn renderSelectorView(allocator: std.mem.Allocator, page: model.Page, format: model.DumpFormat, selector: []const u8) ![]const u8 {
    const matches = try page.dom.querySelectorAll(allocator, page.dom.root(), selector);
    if (matches.len == 0) {
        return std.fmt.allocPrint(allocator, "No matches for selector: {s}\n", .{selector});
    }

    return switch (format) {
        .summary => renderSelectorSummary(allocator, page, selector, matches),
        .html => renderSelectedHtml(allocator, page, matches),
        .text => renderSelectedText(allocator, page, matches),
        .links => renderSelectedLinks(allocator, page, matches),
        .forms => std.fmt.allocPrint(allocator, "Selector-scoped form rendering is not supported for: {s}\n", .{selector}),
    };
}

fn renderSelectorSummary(allocator: std.mem.Allocator, page: model.Page, selector: []const u8, matches: []const dom.NodeId) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "kuri-browser selector\n\n");
    try out.print(allocator, "url: {s}\n", .{page.url});
    try out.print(allocator, "selector: {s}\n", .{selector});
    try out.print(allocator, "matches: {d}\n\n", .{matches.len});

    const preview_limit = @min(matches.len, 5);
    for (matches[0..preview_limit], 0..) |node_id, i| {
        const node = page.dom.getNode(node_id);
        const text = try page.dom.textContent(allocator, node_id);
        try out.print(allocator, "[{d}] <{s}>\n", .{ i + 1, node.name });
        if (text.len > 0) {
            try out.print(allocator, "    {s}\n", .{previewText(text, 180)});
        } else {
            try out.appendSlice(allocator, "    (no text)\n");
        }
    }

    if (preview_limit < matches.len) {
        try out.print(allocator, "\n... {d} more matches\n", .{matches.len - preview_limit});
    }

    return try out.toOwnedSlice(allocator);
}

fn renderSelectedHtml(allocator: std.mem.Allocator, page: model.Page, matches: []const dom.NodeId) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (matches, 0..) |node_id, i| {
        if (i > 0) try out.appendSlice(allocator, "\n\n");
        try out.appendSlice(allocator, page.dom.outerHtml(node_id));
    }
    return try out.toOwnedSlice(allocator);
}

fn renderSelectedText(allocator: std.mem.Allocator, page: model.Page, matches: []const dom.NodeId) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (matches, 0..) |node_id, i| {
        if (i > 0) try out.appendSlice(allocator, "\n\n");
        const text = try page.dom.textContent(allocator, node_id);
        try out.appendSlice(allocator, text);
    }
    return try out.toOwnedSlice(allocator);
}

fn renderSelectedLinks(allocator: std.mem.Allocator, page: model.Page, matches: []const dom.NodeId) ![]const u8 {
    var all_links: std.ArrayList(model.Link) = .empty;
    for (matches) |node_id| {
        const links = try render.extractLinks(allocator, &page.dom, node_id);
        try all_links.appendSlice(allocator, links);
    }
    return renderLinksOnlyText(allocator, all_links.items);
}

fn renderLinksOnlyText(allocator: std.mem.Allocator, links: []const model.Link) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (links, 0..) |link, i| {
        const label = if (link.text.len == 0) "(no text)" else link.text;
        try out.print(allocator, "[{d}] {s}\n{s}\n\n", .{ i + 1, label, link.href });
    }
    return try out.toOwnedSlice(allocator);
}

fn renderFormsText(allocator: std.mem.Allocator, forms: []const model.Form) ![]const u8 {
    if (forms.len == 0) return allocator.dupe(u8, "No forms found.\n");

    var out: std.ArrayList(u8) = .empty;
    for (forms, 0..) |form, i| {
        try out.print(allocator, "[form {d}]\n", .{i + 1});
        try out.print(allocator, "method: {s}\n", .{form.method});
        try out.print(allocator, "action: {s}\n", .{form.action});
        try out.print(allocator, "enctype: {s}\n", .{form.enctype});
        if (form.id.len > 0) try out.print(allocator, "id: {s}\n", .{form.id});
        if (form.class_name.len > 0) try out.print(allocator, "class: {s}\n", .{form.class_name});
        try out.print(allocator, "fields: {d}\n", .{form.fields.len});

        for (form.fields, 0..) |field, field_index| {
            const field_name = if (field.name.len == 0) "(unnamed)" else field.name;
            const field_value = if (field.value.len == 0) "(empty)" else field.value;
            try out.print(allocator, "  [{d}] {s} name={s} value={s}\n", .{
                field_index + 1,
                field.kind,
                field_name,
                field_value,
            });
        }

        if (i + 1 < forms.len) try out.appendSlice(allocator, "\n");
    }
    return try out.toOwnedSlice(allocator);
}

fn previewText(text: []const u8, max_len: usize) []const u8 {
    if (text.len <= max_len) return text;
    return text[0..max_len];
}

test "usage mentions render command" {
    try std.testing.expect(std.mem.indexOf(u8, usageText(), "render <url>") != null);
    try std.testing.expect(std.mem.indexOf(u8, usageText(), "submit <url>") != null);
    try std.testing.expect(std.mem.indexOf(u8, usageText(), "--dump summary|html|text|links|forms") != null);
    try std.testing.expect(std.mem.indexOf(u8, usageText(), "--selector <css>") != null);
    try std.testing.expect(std.mem.indexOf(u8, usageText(), "--har <file>") != null);
}
