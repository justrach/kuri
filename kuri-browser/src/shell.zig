const std = @import("std");
const core = @import("core.zig");
const dom = @import("dom.zig");
const model = @import("model.zig");
const render = @import("render.zig");
const snapshot = @import("snapshot.zig");

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
        \\  kuri-browser parity [--kuri-base <url>] [--offline]
        \\  kuri-browser render <url> [--step click:eN|type:eN=value ...] [--dump summary|html|text|links|forms|resources|js|snapshot] [--selector <css>] [--js] [--eval <expr>] [--har <file>]
        \\  kuri-browser submit <url> [--form-index <n>] [--field name=value ...] [--dump summary|html|text|links|forms|resources|js|snapshot] [--selector <css>] [--js] [--eval <expr>] [--har <file>]
        \\
        \\EXAMPLES
        \\  zig build run -- --help
        \\  zig build run -- status
        \\  zig build run -- roadmap
        \\  zig build run -- parity --kuri-base http://127.0.0.1:8080
        \\  zig build run -- parity --offline
        \\  zig build run -- render https://news.ycombinator.com
        \\  zig build run -- render https://example.com --dump html
        \\  zig build run -- render https://example.com --har example.har
        \\  zig build run -- render https://news.ycombinator.com --js --eval "document.querySelectorAll('a').length" --dump js
        \\  zig build run -- render https://news.ycombinator.com --dump snapshot
        \\  zig build run -- render https://example.com --step click:e0 --dump summary
        \\  zig build run -- render https://quotes.toscrape.com/login --dump forms
        \\  zig build run -- render https://www.wikipedia.org/ --dump resources --har wiki.har
        \\  zig build run -- submit https://quotes.toscrape.com/login --field username=admin --field password=admin --js --dump text --har login.har
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
        .text => renderFullText(allocator, page),
        .links => renderLinksOnlyText(allocator, page.links),
        .forms => renderFormsText(allocator, page.forms),
        .resources => renderResourcesText(allocator, page.resources),
        .js => renderJsText(allocator, page.js),
        .snapshot => renderSnapshotText(allocator, page),
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
    try out.print(allocator, "forms: {d}\n", .{page.forms.len});
    try out.print(allocator, "resources: {d} total, {d} loaded\n\n", .{ page.resources.len, loadedResourceCount(page.resources) });
    if (page.js.enabled) {
        try out.print(allocator, "js: enabled\n", .{});
        try out.print(allocator, "js-scripts: {d} executed ({d} inline, {d} external, {d} failed)\n\n", .{
            page.js.executed_scripts,
            page.js.inline_scripts,
            page.js.external_scripts,
            page.js.failed_scripts,
        });
        if (page.js.fetch_requests > 0 or page.js.xhr_requests > 0) {
            try out.print(allocator, "js-network: {d} fetch, {d} xhr\n\n", .{
                page.js.fetch_requests,
                page.js.xhr_requests,
            });
        }
    } else {
        try out.appendSlice(allocator, "js: disabled\n\n");
    }

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

    if (page.resources.len > 0) {
        try out.appendSlice(allocator, "\n--- resources ---\n");
        const limit = @min(page.resources.len, 10);
        for (page.resources[0..limit], 0..) |resource, i| {
            try out.print(allocator, "[{d}] {s} status={d} type={s}\n    {s}\n", .{
                i + 1,
                resource.kind,
                resource.status_code,
                if (resource.content_type.len > 0) resource.content_type else "(unknown)",
                resource.url,
            });
            if (resource.error_message.len > 0) {
                try out.print(allocator, "    error: {s}\n", .{resource.error_message});
            }
        }
        if (limit < page.resources.len) {
            try out.print(allocator, "\n... {d} more resources\n", .{page.resources.len - limit});
        }
    }

    if (page.js.enabled and (page.js.output.len > 0 or page.js.eval_result.len > 0 or page.js.error_message.len > 0)) {
        try out.appendSlice(allocator, "\n--- js ---\n");
        if (page.js.eval_result.len > 0) {
            try out.print(allocator, "eval: {s}\n", .{page.js.eval_result});
        }
        if (page.js.output.len > 0) {
            try out.appendSlice(allocator, "output:\n");
            try out.appendSlice(allocator, page.js.output);
            try out.append(allocator, '\n');
        }
        if (page.js.error_message.len > 0) {
            try out.print(allocator, "error: {s}\n", .{page.js.error_message});
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
        .resources => std.fmt.allocPrint(allocator, "Selector-scoped resource rendering is not supported for: {s}\n", .{selector}),
        .js => std.fmt.allocPrint(allocator, "Selector-scoped JS rendering is not supported for: {s}\n", .{selector}),
        .snapshot => std.fmt.allocPrint(allocator, "Selector-scoped snapshot rendering is not supported for: {s}\n", .{selector}),
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

fn renderFullText(allocator: std.mem.Allocator, page: model.Page) ![]const u8 {
    if (!page.js.enabled or page.js.output.len == 0) return allocator.dupe(u8, page.text);
    return std.fmt.allocPrint(allocator, "{s}\n\n--- js-output ---\n{s}", .{ page.text, page.js.output });
}

fn renderResourcesText(allocator: std.mem.Allocator, resources: []const model.Resource) ![]const u8 {
    if (resources.len == 0) return allocator.dupe(u8, "No resources found.\n");

    var out: std.ArrayList(u8) = .empty;
    for (resources, 0..) |resource, i| {
        try out.print(allocator, "[resource {d}]\n", .{i + 1});
        try out.print(allocator, "kind: {s}\n", .{resource.kind});
        try out.print(allocator, "url: {s}\n", .{resource.url});
        try out.print(allocator, "loaded: {s}\n", .{if (resource.loaded) "yes" else "no"});
        try out.print(allocator, "status: {d}\n", .{resource.status_code});
        try out.print(allocator, "content-type: {s}\n", .{if (resource.content_type.len > 0) resource.content_type else "(unknown)"});
        try out.print(allocator, "body-size: {d}\n", .{resource.body_size});
        if (resource.error_message.len > 0) {
            try out.print(allocator, "error: {s}\n", .{resource.error_message});
        }
        if (i + 1 < resources.len) try out.appendSlice(allocator, "\n");
    }
    return try out.toOwnedSlice(allocator);
}

fn renderJsText(allocator: std.mem.Allocator, js: model.JsExecution) ![]const u8 {
    if (!js.enabled) return allocator.dupe(u8, "JavaScript evaluation is disabled.\n");

    var out: std.ArrayList(u8) = .empty;
    try out.print(allocator, "enabled: yes\n", .{});
    try out.print(allocator, "executed-scripts: {d}\n", .{js.executed_scripts});
    try out.print(allocator, "inline-scripts: {d}\n", .{js.inline_scripts});
    try out.print(allocator, "external-scripts: {d}\n", .{js.external_scripts});
    try out.print(allocator, "failed-scripts: {d}\n", .{js.failed_scripts});
    try out.print(allocator, "fetch-requests: {d}\n", .{js.fetch_requests});
    try out.print(allocator, "xhr-requests: {d}\n", .{js.xhr_requests});
    if (js.document_title.len > 0) {
        try out.print(allocator, "document-title: {s}\n", .{js.document_title});
    }
    if (js.eval_result.len > 0) {
        try out.print(allocator, "eval-result: {s}\n", .{js.eval_result});
    }
    if (js.error_message.len > 0) {
        try out.print(allocator, "error: {s}\n", .{js.error_message});
    }
    if (js.output.len > 0) {
        try out.appendSlice(allocator, "\n--- output ---\n");
        try out.appendSlice(allocator, js.output);
        try out.append(allocator, '\n');
    }
    return try out.toOwnedSlice(allocator);
}

fn renderSnapshotText(allocator: std.mem.Allocator, page: model.Page) ![]const u8 {
    const nodes = try snapshot.buildInteractiveSnapshot(allocator, &page.dom, page.dom.root());
    defer snapshot.freeSnapshot(allocator, nodes);
    return snapshot.formatCompact(allocator, nodes);
}

fn loadedResourceCount(resources: []const model.Resource) usize {
    var count: usize = 0;
    for (resources) |resource| {
        if (resource.loaded) count += 1;
    }
    return count;
}

fn previewText(text: []const u8, max_len: usize) []const u8 {
    if (text.len <= max_len) return text;
    return text[0..max_len];
}

test "usage mentions render command" {
    try std.testing.expect(std.mem.indexOf(u8, usageText(), "parity") != null);
    try std.testing.expect(std.mem.indexOf(u8, usageText(), "render <url>") != null);
    try std.testing.expect(std.mem.indexOf(u8, usageText(), "submit <url>") != null);
    try std.testing.expect(std.mem.indexOf(u8, usageText(), "--dump summary|html|text|links|forms|resources|js|snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, usageText(), "--step click:eN|type:eN=value") != null);
    try std.testing.expect(std.mem.indexOf(u8, usageText(), "--selector <css>") != null);
    try std.testing.expect(std.mem.indexOf(u8, usageText(), "--js") != null);
    try std.testing.expect(std.mem.indexOf(u8, usageText(), "--eval <expr>") != null);
    try std.testing.expect(std.mem.indexOf(u8, usageText(), "--har <file>") != null);
}
