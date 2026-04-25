const std = @import("std");

pub const NodeId = u32;

pub const NodeKind = enum {
    document,
    element,
    text,
};

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

pub const Node = struct {
    kind: NodeKind,
    name: []const u8 = "",
    text: []const u8 = "",
    attrs: []const Attribute = &.{},
    parent: ?NodeId = null,
    first_child: ?NodeId = null,
    last_child: ?NodeId = null,
    next_sibling: ?NodeId = null,
    prev_sibling: ?NodeId = null,
    source_start: usize = 0,
    source_end: usize = 0,
};

const Combinator = enum {
    descendant,
    child,
};

const SelectorStep = struct {
    relation_to_prev: ?Combinator = null,
    tag: ?[]const u8 = null,
    any_tag: bool = false,
    id: ?[]const u8 = null,
    classes: []const []const u8 = &.{},
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    html: []const u8,
    nodes: []Node,
    root_id: NodeId,

    pub fn parse(allocator: std.mem.Allocator, html: []const u8) !Document {
        var nodes: std.ArrayList(Node) = .empty;
        errdefer nodes.deinit(allocator);

        try nodes.append(allocator, .{
            .kind = .document,
            .source_start = 0,
            .source_end = html.len,
        });

        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(allocator);
        try stack.append(allocator, 0);

        var i: usize = 0;
        while (i < html.len) {
            if (html[i] != '<') {
                const text_end = std.mem.indexOfScalarPos(u8, html, i, '<') orelse html.len;
                if (text_end > i) {
                    const node_id = try appendNode(&nodes, .{
                        .kind = .text,
                        .text = html[i..text_end],
                        .source_start = i,
                        .source_end = text_end,
                    }, allocator);
                    attachChild(nodes.items, stack.items[stack.items.len - 1], node_id);
                }
                i = text_end;
                continue;
            }

            if (std.mem.startsWith(u8, html[i..], "<!--")) {
                const end_idx = std.mem.indexOfPos(u8, html, i + 4, "-->") orelse html.len;
                i = @min(end_idx + 3, html.len);
                continue;
            }

            if (std.mem.startsWith(u8, html[i..], "</")) {
                const tag_end = findTagEnd(html, i + 2) orelse html.len - 1;
                const close_name = parseTagName(html[i + 2 .. tag_end]);
                if (close_name.len > 0) {
                    var found_index: ?usize = null;
                    var idx = stack.items.len;
                    while (idx > 1) {
                        idx -= 1;
                        const candidate = &nodes.items[stack.items[idx]];
                        if (candidate.kind == .element and std.ascii.eqlIgnoreCase(candidate.name, close_name)) {
                            found_index = idx;
                            break;
                        }
                    }

                    if (found_index) |match_index| {
                        const close_end = @min(tag_end + 1, html.len);
                        while (stack.items.len > match_index) {
                            const open_id = stack.pop().?;
                            nodes.items[open_id].source_end = close_end;
                        }
                    }
                }

                i = @min(tag_end + 1, html.len);
                continue;
            }

            if (std.mem.startsWith(u8, html[i..], "<!") or std.mem.startsWith(u8, html[i..], "<?")) {
                const tag_end = findTagEnd(html, i + 1) orelse html.len - 1;
                i = @min(tag_end + 1, html.len);
                continue;
            }

            const tag_end = findTagEnd(html, i + 1) orelse html.len - 1;
            const tag_inner = html[i + 1 .. tag_end];
            const trimmed_inner = std.mem.trim(u8, tag_inner, " \t\r\n");
            const tag_name = parseTagName(trimmed_inner);
            if (tag_name.len == 0) {
                i = @min(tag_end + 1, html.len);
                continue;
            }

            const attrs = try parseAttributes(allocator, trimmed_inner[tag_name.len..]);
            const node_id = try appendNode(&nodes, .{
                .kind = .element,
                .name = tag_name,
                .attrs = attrs,
                .source_start = i,
                .source_end = @min(tag_end + 1, html.len),
            }, allocator);
            attachChild(nodes.items, stack.items[stack.items.len - 1], node_id);

            const self_closing = isSelfClosing(trimmed_inner) or isVoidTag(tag_name);
            const after_open = @min(tag_end + 1, html.len);

            if (isRawTextTag(tag_name)) {
                if (findMatchingCloseTag(html, after_open, tag_name)) |close| {
                    if (close.start > after_open) {
                        const text_id = try appendNode(&nodes, .{
                            .kind = .text,
                            .text = html[after_open..close.start],
                            .source_start = after_open,
                            .source_end = close.start,
                        }, allocator);
                        attachChild(nodes.items, node_id, text_id);
                    }
                    nodes.items[node_id].source_end = close.end;
                    i = close.end;
                    continue;
                }

                if (after_open < html.len) {
                    const text_id = try appendNode(&nodes, .{
                        .kind = .text,
                        .text = html[after_open..],
                        .source_start = after_open,
                        .source_end = html.len,
                    }, allocator);
                    attachChild(nodes.items, node_id, text_id);
                }
                nodes.items[node_id].source_end = html.len;
                i = html.len;
                continue;
            }

            if (!self_closing) {
                try stack.append(allocator, node_id);
            }
            i = after_open;
        }

        while (stack.items.len > 1) {
            const open_id = stack.pop().?;
            nodes.items[open_id].source_end = html.len;
        }

        return .{
            .allocator = allocator,
            .html = html,
            .nodes = try nodes.toOwnedSlice(allocator),
            .root_id = 0,
        };
    }

    pub fn deinit(self: *Document) void {
        for (self.nodes) |node| {
            if (node.kind == .element and node.attrs.len > 0) {
                self.allocator.free(node.attrs);
            }
        }
        self.allocator.free(self.nodes);
    }

    pub fn nodeCount(self: *const Document) usize {
        return self.nodes.len;
    }

    pub fn root(self: *const Document) NodeId {
        return self.root_id;
    }

    pub fn getNode(self: *const Document, node_id: NodeId) *const Node {
        return &self.nodes[node_id];
    }

    pub fn outerHtml(self: *const Document, node_id: NodeId) []const u8 {
        const node = self.getNode(node_id);
        return self.html[node.source_start..node.source_end];
    }

    pub fn getAttribute(self: *const Document, node_id: NodeId, name: []const u8) ?[]const u8 {
        const node = self.getNode(node_id);
        if (node.kind != .element) return null;
        for (node.attrs) |attr| {
            if (std.ascii.eqlIgnoreCase(attr.name, name)) return attr.value;
        }
        return null;
    }

    pub fn querySelector(self: *const Document, allocator: std.mem.Allocator, selector: []const u8) !?NodeId {
        const matches = try self.querySelectorAll(allocator, self.root_id, selector);
        if (matches.len == 0) return null;
        return matches[0];
    }

    pub fn querySelectorAll(self: *const Document, allocator: std.mem.Allocator, root_id: NodeId, selector: []const u8) ![]const NodeId {
        var selector_arena = std.heap.ArenaAllocator.init(allocator);
        defer selector_arena.deinit();

        const steps = try parseSelector(selector_arena.allocator(), selector);
        if (steps.len == 0) return allocator.dupe(NodeId, &.{});

        var matches: std.ArrayList(NodeId) = .empty;
        try self.collectQueryMatches(allocator, root_id, steps, &matches);
        return try matches.toOwnedSlice(allocator);
    }

    pub fn textContent(self: *const Document, allocator: std.mem.Allocator, node_id: NodeId) ![]const u8 {
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(allocator);
        try self.appendTextRecursive(allocator, node_id, &raw);
        return normalizeText(allocator, raw.items);
    }

    fn collectQueryMatches(self: *const Document, allocator: std.mem.Allocator, node_id: NodeId, steps: []const SelectorStep, matches: *std.ArrayList(NodeId)) !void {
        const node = self.getNode(node_id);
        var child = node.first_child;
        while (child) |child_id| : (child = self.nodes[child_id].next_sibling) {
            const child_node = self.getNode(child_id);
            if (child_node.kind == .element and self.matchesSelector(child_id, steps, steps.len - 1)) {
                try matches.append(allocator, child_id);
            }
            try self.collectQueryMatches(allocator, child_id, steps, matches);
        }
    }

    fn matchesSelector(self: *const Document, node_id: NodeId, steps: []const SelectorStep, step_index: usize) bool {
        if (!self.matchesStep(node_id, steps[step_index])) return false;
        if (step_index == 0) return true;

        const relation = steps[step_index].relation_to_prev orelse return false;
        switch (relation) {
            .child => {
                const parent_id = self.parentElement(node_id) orelse return false;
                return self.matchesSelector(parent_id, steps, step_index - 1);
            },
            .descendant => {
                var ancestor = self.parentElement(node_id);
                while (ancestor) |ancestor_id| : (ancestor = self.parentElement(ancestor_id)) {
                    if (self.matchesSelector(ancestor_id, steps, step_index - 1)) return true;
                }
                return false;
            },
        }
    }

    fn matchesStep(self: *const Document, node_id: NodeId, step: SelectorStep) bool {
        const node = self.getNode(node_id);
        if (node.kind != .element) return false;

        if (step.tag) |tag| {
            if (!std.ascii.eqlIgnoreCase(node.name, tag)) return false;
        } else if (!step.any_tag and step.id == null and step.classes.len == 0) {
            return false;
        }

        if (step.id) |id_value| {
            const attr = self.getAttribute(node_id, "id") orelse return false;
            if (!std.mem.eql(u8, attr, id_value)) return false;
        }

        if (step.classes.len > 0) {
            const attr = self.getAttribute(node_id, "class") orelse return false;
            for (step.classes) |class_name| {
                if (!classListContains(attr, class_name)) return false;
            }
        }

        return true;
    }

    fn parentElement(self: *const Document, node_id: NodeId) ?NodeId {
        var parent_id = self.nodes[node_id].parent;
        while (parent_id) |pid| : (parent_id = self.nodes[pid].parent) {
            if (self.nodes[pid].kind == .element) return pid;
        }
        return null;
    }

    fn appendTextRecursive(self: *const Document, allocator: std.mem.Allocator, node_id: NodeId, out: *std.ArrayList(u8)) !void {
        const node = self.getNode(node_id);
        switch (node.kind) {
            .document => {
                var child = node.first_child;
                while (child) |child_id| : (child = self.nodes[child_id].next_sibling) {
                    try self.appendTextRecursive(allocator, child_id, out);
                }
            },
            .text => try out.appendSlice(allocator, node.text),
            .element => {
                if (std.ascii.eqlIgnoreCase(node.name, "script") or std.ascii.eqlIgnoreCase(node.name, "style")) {
                    return;
                }

                if (isBlockTag(node.name) or std.ascii.eqlIgnoreCase(node.name, "br")) {
                    try appendNewlineIfNeeded(allocator, out);
                }

                var child = node.first_child;
                while (child) |child_id| : (child = self.nodes[child_id].next_sibling) {
                    try self.appendTextRecursive(allocator, child_id, out);
                }

                if (isBlockTag(node.name)) {
                    try appendNewlineIfNeeded(allocator, out);
                }
            },
        }
    }
};

pub fn decodeEntities(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '&') {
            if (std.mem.startsWith(u8, input[i..], "&amp;")) {
                try out.append(allocator, '&');
                i += 5;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&lt;")) {
                try out.append(allocator, '<');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&gt;")) {
                try out.append(allocator, '>');
                i += 4;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&quot;")) {
                try out.append(allocator, '"');
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&nbsp;")) {
                try out.append(allocator, ' ');
                i += 6;
                continue;
            }
            if (std.mem.startsWith(u8, input[i..], "&#")) {
                if (try appendNumericEntity(allocator, &out, input[i..])) |consumed| {
                    i += consumed;
                    continue;
                }
            }
        }

        try out.append(allocator, input[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

pub fn normalizeText(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const decoded = try decodeEntities(allocator, input);
    defer allocator.free(decoded);
    return trimAndCollapseWhitespace(allocator, decoded);
}

fn appendNode(nodes: *std.ArrayList(Node), node: Node, allocator: std.mem.Allocator) !NodeId {
    try nodes.append(allocator, node);
    return @intCast(nodes.items.len - 1);
}

fn attachChild(nodes: []Node, parent_id: NodeId, child_id: NodeId) void {
    nodes[child_id].parent = parent_id;
    if (nodes[parent_id].last_child) |last_id| {
        nodes[last_id].next_sibling = child_id;
        nodes[child_id].prev_sibling = last_id;
    } else {
        nodes[parent_id].first_child = child_id;
    }
    nodes[parent_id].last_child = child_id;
}

fn findTagEnd(html: []const u8, start: usize) ?usize {
    var i = start;
    var quote: ?u8 = null;
    while (i < html.len) : (i += 1) {
        const c = html[i];
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '>') return i;
    }
    return null;
}

fn parseTagName(tag: []const u8) []const u8 {
    var start: usize = 0;
    while (start < tag.len and (std.ascii.isWhitespace(tag[start]) or tag[start] == '/')) : (start += 1) {}
    const trimmed = tag[start..];
    var end: usize = 0;
    while (end < trimmed.len and isIdentChar(trimmed[end])) : (end += 1) {}
    return trimmed[0..end];
}

fn parseAttributes(allocator: std.mem.Allocator, input: []const u8) ![]const Attribute {
    var attrs: std.ArrayList(Attribute) = .empty;
    var i: usize = 0;

    while (i < input.len) {
        while (i < input.len and (std.ascii.isWhitespace(input[i]) or input[i] == '/')) : (i += 1) {}
        if (i >= input.len) break;

        const name_start = i;
        while (i < input.len and !std.ascii.isWhitespace(input[i]) and input[i] != '=' and input[i] != '/') : (i += 1) {}
        if (i == name_start) break;
        const name = input[name_start..i];

        while (i < input.len and std.ascii.isWhitespace(input[i])) : (i += 1) {}
        var value: []const u8 = "";
        if (i < input.len and input[i] == '=') {
            i += 1;
            while (i < input.len and std.ascii.isWhitespace(input[i])) : (i += 1) {}
            if (i < input.len and (input[i] == '"' or input[i] == '\'')) {
                const quote = input[i];
                i += 1;
                const value_start = i;
                while (i < input.len and input[i] != quote) : (i += 1) {}
                value = input[value_start..@min(i, input.len)];
                if (i < input.len) i += 1;
            } else {
                const value_start = i;
                while (i < input.len and !std.ascii.isWhitespace(input[i]) and input[i] != '/') : (i += 1) {}
                value = input[value_start..i];
            }
        }

        try attrs.append(allocator, .{
            .name = name,
            .value = value,
        });
    }

    return try attrs.toOwnedSlice(allocator);
}

fn isSelfClosing(tag_inner: []const u8) bool {
    var end = tag_inner.len;
    while (end > 0 and std.ascii.isWhitespace(tag_inner[end - 1])) : (end -= 1) {}
    const trimmed = tag_inner[0..end];
    return trimmed.len > 0 and trimmed[trimmed.len - 1] == '/';
}

fn isVoidTag(tag_name: []const u8) bool {
    const tags = [_][]const u8{
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    };
    for (tags) |tag| {
        if (std.ascii.eqlIgnoreCase(tag_name, tag)) return true;
    }
    return false;
}

fn isRawTextTag(tag_name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tag_name, "script") or std.ascii.eqlIgnoreCase(tag_name, "style");
}

const CloseTag = struct {
    start: usize,
    end: usize,
};

fn findMatchingCloseTag(html: []const u8, start: usize, tag_name: []const u8) ?CloseTag {
    var i = start;
    while (i < html.len) {
        const close_start = std.mem.indexOfPos(u8, html, i, "</") orelse return null;
        const tag_end = findTagEnd(html, close_start + 2) orelse return null;
        const candidate = parseTagName(html[close_start + 2 .. tag_end]);
        if (candidate.len > 0 and std.ascii.eqlIgnoreCase(candidate, tag_name)) {
            return .{
                .start = close_start,
                .end = @min(tag_end + 1, html.len),
            };
        }
        i = close_start + 2;
    }
    return null;
}

fn parseSelector(allocator: std.mem.Allocator, selector: []const u8) ![]const SelectorStep {
    var steps: std.ArrayList(SelectorStep) = .empty;
    var i: usize = 0;
    var pending_relation: ?Combinator = null;

    while (true) {
        var consumed_space = false;
        while (i < selector.len and std.ascii.isWhitespace(selector[i])) : (i += 1) {
            consumed_space = true;
        }

        if (i >= selector.len) break;
        if (steps.items.len > 0 and consumed_space and pending_relation == null) {
            pending_relation = .descendant;
        }

        if (selector[i] == '>') {
            pending_relation = .child;
            i += 1;
            continue;
        }

        var step = try parseSelectorStep(allocator, selector, &i);
        if (steps.items.len > 0) {
            step.relation_to_prev = pending_relation orelse .descendant;
        }
        pending_relation = null;
        try steps.append(allocator, step);
    }

    return try steps.toOwnedSlice(allocator);
}

fn parseSelectorStep(allocator: std.mem.Allocator, selector: []const u8, index: *usize) !SelectorStep {
    var classes: std.ArrayList([]const u8) = .empty;
    var tag: ?[]const u8 = null;
    var any_tag = false;
    var id_value: ?[]const u8 = null;

    while (index.* < selector.len and !std.ascii.isWhitespace(selector[index.*]) and selector[index.*] != '>') {
        const c = selector[index.*];
        if (c == '.') {
            index.* += 1;
            const class_name = parseIdentifier(selector, index);
            if (class_name.len == 0) return error.InvalidSelector;
            try classes.append(allocator, class_name);
            continue;
        }
        if (c == '#') {
            index.* += 1;
            const parsed_id = parseIdentifier(selector, index);
            if (parsed_id.len == 0) return error.InvalidSelector;
            id_value = parsed_id;
            continue;
        }
        if (c == '*') {
            any_tag = true;
            index.* += 1;
            continue;
        }

        const parsed_tag = parseIdentifier(selector, index);
        if (parsed_tag.len == 0 or tag != null or any_tag) return error.InvalidSelector;
        tag = parsed_tag;
    }

    return .{
        .tag = tag,
        .any_tag = any_tag,
        .id = id_value,
        .classes = try classes.toOwnedSlice(allocator),
    };
}

fn parseIdentifier(input: []const u8, index: *usize) []const u8 {
    const start = index.*;
    while (index.* < input.len and isIdentChar(input[index.*])) : (index.* += 1) {}
    return input[start..index.*];
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':';
}

fn classListContains(class_value: []const u8, target: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, class_value, " \t\r\n");
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry, target)) return true;
    }
    return false;
}

fn appendNumericEntity(allocator: std.mem.Allocator, out: *std.ArrayList(u8), input: []const u8) !?usize {
    const semi = std.mem.indexOfScalar(u8, input, ';') orelse return null;
    if (semi < 4) return null;

    const body = input[2..semi];
    const is_hex = body.len > 1 and (body[0] == 'x' or body[0] == 'X');
    const digits = if (is_hex) body[1..] else body;
    if (digits.len == 0) return null;

    const base: u8 = if (is_hex) 16 else 10;
    const value = std.fmt.parseInt(u21, digits, base) catch return null;

    var buf: [4]u8 = undefined;
    const encoded = try std.unicode.utf8Encode(value, &buf);
    try out.appendSlice(allocator, buf[0..encoded]);
    return semi + 1;
}

fn trimAndCollapseWhitespace(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var previous_was_space = false;
    var previous_was_newline = false;

    for (input) |c| {
        if (c == '\n' or c == '\r') {
            if (!previous_was_newline and out.items.len > 0) {
                try out.append(allocator, '\n');
            }
            previous_was_space = false;
            previous_was_newline = true;
            continue;
        }

        if (std.ascii.isWhitespace(c)) {
            if (!previous_was_space and !previous_was_newline and out.items.len > 0) {
                try out.append(allocator, ' ');
            }
            previous_was_space = true;
            continue;
        }

        try out.append(allocator, c);
        previous_was_space = false;
        previous_was_newline = false;
    }

    return std.mem.trim(u8, out.items, " \n\t\r");
}

fn isBlockTag(tag_name: []const u8) bool {
    const tags = [_][]const u8{
        "p", "div", "section", "article", "header", "footer", "main",
        "aside", "nav", "ul", "ol", "li", "br", "tr", "table",
        "h1", "h2", "h3", "h4", "h5", "h6", "tbody", "thead", "tfoot",
        "blockquote", "pre", "form",
    };
    for (tags) |tag| {
        if (std.ascii.eqlIgnoreCase(tag_name, tag)) return true;
    }
    return false;
}

fn appendNewlineIfNeeded(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    if (out.items.len == 0) return;
    if (out.items[out.items.len - 1] != '\n') {
        try out.append(allocator, '\n');
    }
}

test "document parse builds element tree" {
    var doc = try Document.parse(std.testing.allocator, "<html><body><div id=\"main\"><p>Hello</p></div></body></html>");
    defer doc.deinit();
    try std.testing.expect(doc.nodeCount() >= 5);
    const div = (try doc.querySelector(std.testing.allocator, "#main")).?;
    try std.testing.expectEqualStrings("div", doc.getNode(div).name);
}

test "query selector handles descendant and child combinators" {
    var doc = try Document.parse(std.testing.allocator, "<div class=\"outer\"><span class=\"titleline\"><a href=\"/x\">Link</a></span></div>");
    defer doc.deinit();
    const descendant = (try doc.querySelector(std.testing.allocator, ".titleline a")).?;
    try std.testing.expectEqualStrings("a", doc.getNode(descendant).name);
    const child = (try doc.querySelector(std.testing.allocator, "span > a")).?;
    try std.testing.expectEqual(descendant, child);
}

test "textContent skips script and style content" {
    var doc = try Document.parse(std.testing.allocator, "<div>Hello<script>bad()</script><p>World</p><style>.x{}</style></div>");
    defer doc.deinit();
    const div = (try doc.querySelector(std.testing.allocator, "div")).?;
    const text = try doc.textContent(std.testing.allocator, div);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Hello\nWorld", text);
}
