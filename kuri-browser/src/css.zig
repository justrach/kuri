const std = @import("std");
const dom = @import("dom.zig");

pub const Origin = enum(u8) {
    user_agent = 0,
    author = 1,
    inline_style = 2,
};

pub const Combinator = enum {
    descendant,
    child,
    adjacent_sibling,
    general_sibling,
};

pub const SelectorStep = struct {
    relation: Combinator = .descendant,
    tag: ?[]const u8 = null,
    any_tag: bool = false,
    id: ?[]const u8 = null,
    classes: []const []const u8 = &.{},
};

pub const Selector = struct {
    text: []const u8,
    steps: []const SelectorStep,
    specificity: u32,
};

pub const Declaration = struct {
    name: []const u8,
    value: []const u8,
    important: bool = false,
};

pub const Rule = struct {
    selectors: []const Selector,
    declarations: []const Declaration,
    source_start: usize = 0,
    source_end: usize = 0,
};

pub const Stylesheet = struct {
    arena: std.heap.ArenaAllocator,
    text: []const u8,
    rules: []Rule,
    origin: Origin = .author,

    pub fn deinit(self: *Stylesheet) void {
        self.arena.deinit();
    }

    pub fn empty(parent_allocator: std.mem.Allocator) Stylesheet {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .text = "",
            .rules = &.{},
        };
    }

    pub fn fromText(parent_allocator: std.mem.Allocator, text: []const u8, origin: Origin) !Stylesheet {
        var arena = std.heap.ArenaAllocator.init(parent_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const owned_text = try allocator.dupe(u8, text);
        const rules = try parseRules(allocator, owned_text);
        return .{
            .arena = arena,
            .text = owned_text,
            .rules = rules,
            .origin = origin,
        };
    }
};

pub const ComputedProperty = struct {
    name: []const u8,
    value: []const u8,
    important: bool,
    origin: Origin,
    specificity: u32,
    rule_index: usize,
};

pub const ComputedStyle = struct {
    properties: []const Declaration,

    pub fn get(self: ComputedStyle, name: []const u8) ?[]const u8 {
        for (self.properties) |prop| {
            if (std.ascii.eqlIgnoreCase(prop.name, name)) return prop.value;
        }
        return null;
    }
};

pub const MatchedRule = struct {
    selector: Selector,
    declarations: []const Declaration,
    origin: Origin,
    rule_index: usize,
};

// ---------------- Parser ----------------

fn parseRules(allocator: std.mem.Allocator, text: []const u8) ![]Rule {
    var out: std.ArrayList(Rule) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        i = skipWhitespaceAndComments(text, i);
        if (i >= text.len) break;
        // Skip @-rules cheaply: read until matching brace block ends.
        if (text[i] == '@') {
            i = skipAtRule(text, i);
            continue;
        }
        const rule_start = i;
        const selector_end = std.mem.indexOfScalarPos(u8, text, i, '{') orelse break;
        const selector_slice = text[i..selector_end];
        const block_open = selector_end + 1;
        const block_end = findMatchingBraceEnd(text, block_open) orelse break;
        const decl_slice = text[block_open..block_end];

        const selectors = try parseSelectorList(allocator, selector_slice);
        const decls = try parseDeclarations(allocator, decl_slice);
        if (selectors.len > 0) {
            try out.append(allocator, .{
                .selectors = selectors,
                .declarations = decls,
                .source_start = rule_start,
                .source_end = block_end + 1,
            });
        }
        i = block_end + 1;
    }
    return out.toOwnedSlice(allocator);
}

fn skipWhitespaceAndComments(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) {
        if (std.ascii.isWhitespace(text[i])) {
            i += 1;
            continue;
        }
        if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, text, i + 2, "*/") orelse return text.len;
            i = close + 2;
            continue;
        }
        break;
    }
    return i;
}

fn skipAtRule(text: []const u8, start: usize) usize {
    // Either ends with ';' (e.g., @import ...;) or with a balanced { ... }.
    var i = start;
    while (i < text.len) : (i += 1) {
        if (text[i] == ';') return i + 1;
        if (text[i] == '{') {
            const end = findMatchingBraceEnd(text, i + 1) orelse return text.len;
            return end + 1;
        }
    }
    return text.len;
}

fn findMatchingBraceEnd(text: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '/' and i + 1 < text.len and text[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, text, i + 2, "*/") orelse return null;
            i = close + 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            const close = std.mem.indexOfScalarPos(u8, text, i + 1, c) orelse return null;
            i = close;
            continue;
        }
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn parseSelectorList(allocator: std.mem.Allocator, text: []const u8) ![]Selector {
    var out: std.ArrayList(Selector) = .empty;
    var rest = text;
    while (rest.len > 0) {
        const comma = nextToplevelComma(rest);
        const piece_raw = if (comma) |idx| rest[0..idx] else rest;
        const piece = std.mem.trim(u8, piece_raw, " \t\r\n");
        if (piece.len > 0) {
            if (parseOneSelector(allocator, piece) catch null) |sel| {
                try out.append(allocator, sel);
            }
        }
        if (comma) |idx| {
            rest = rest[idx + 1 ..];
        } else break;
    }
    return out.toOwnedSlice(allocator);
}

fn nextToplevelComma(text: []const u8) ?usize {
    var i: usize = 0;
    var paren_depth: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '(') paren_depth += 1;
        if (c == ')' and paren_depth > 0) paren_depth -= 1;
        if (c == ',' and paren_depth == 0) return i;
    }
    return null;
}

fn parseOneSelector(allocator: std.mem.Allocator, text: []const u8) !Selector {
    var steps: std.ArrayList(SelectorStep) = .empty;
    var classes_buf: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    var pending_relation: Combinator = .descendant;
    var have_pending_relation = false;
    var specificity_id: u32 = 0;
    var specificity_class: u32 = 0;
    var specificity_tag: u32 = 0;

    while (i < text.len) {
        // Skip whitespace, but treat it as a descendant relation if we already have a step.
        while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {
            if (steps.items.len > 0 and !have_pending_relation) {
                pending_relation = .descendant;
                have_pending_relation = true;
            }
        }
        if (i >= text.len) break;
        const c = text[i];
        if (c == '>' or c == '+' or c == '~') {
            pending_relation = switch (c) {
                '>' => .child,
                '+' => .adjacent_sibling,
                '~' => .general_sibling,
                else => .descendant,
            };
            have_pending_relation = true;
            i += 1;
            continue;
        }
        // Build a step.
        var step: SelectorStep = .{
            .relation = if (have_pending_relation) pending_relation else .descendant,
        };
        classes_buf.clearRetainingCapacity();

        if (c == '*') {
            step.any_tag = true;
            i += 1;
        } else if (isIdentStart(c)) {
            const start = i;
            while (i < text.len and isIdentChar(text[i])) i += 1;
            step.tag = text[start..i];
            specificity_tag += 1;
        }

        while (i < text.len) {
            const cc = text[i];
            if (cc == '.') {
                i += 1;
                const start = i;
                while (i < text.len and isIdentChar(text[i])) i += 1;
                if (i > start) {
                    try classes_buf.append(allocator, text[start..i]);
                    specificity_class += 1;
                }
            } else if (cc == '#') {
                i += 1;
                const start = i;
                while (i < text.len and isIdentChar(text[i])) i += 1;
                if (i > start) {
                    step.id = text[start..i];
                    specificity_id += 1;
                }
            } else if (cc == '[') {
                // Skip attribute selectors entirely (treat as +0 specificity match-anything).
                const close = std.mem.indexOfScalarPos(u8, text, i + 1, ']') orelse text.len;
                i = if (close < text.len) close + 1 else text.len;
            } else if (cc == ':') {
                // Pseudo-class or pseudo-element: skip identifier and any (...) block.
                i += 1;
                if (i < text.len and text[i] == ':') i += 1;
                while (i < text.len and isIdentChar(text[i])) i += 1;
                if (i < text.len and text[i] == '(') {
                    var depth: usize = 1;
                    i += 1;
                    while (i < text.len and depth > 0) : (i += 1) {
                        if (text[i] == '(') depth += 1;
                        if (text[i] == ')') depth -= 1;
                    }
                }
            } else {
                break;
            }
        }

        if (classes_buf.items.len > 0) {
            const owned_classes = try allocator.alloc([]const u8, classes_buf.items.len);
            std.mem.copyForwards([]const u8, owned_classes, classes_buf.items);
            step.classes = owned_classes;
        }
        try steps.append(allocator, step);
        have_pending_relation = false;
    }

    classes_buf.deinit(allocator);

    const owned_steps = try steps.toOwnedSlice(allocator);
    const specificity = (specificity_id << 16) | (specificity_class << 8) | specificity_tag;
    return .{
        .text = text,
        .steps = owned_steps,
        .specificity = specificity,
    };
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '-';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

pub fn parseDeclarations(allocator: std.mem.Allocator, text: []const u8) ![]Declaration {
    var out: std.ArrayList(Declaration) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        i = skipWhitespaceAndComments(text, i);
        if (i >= text.len) break;
        const semi = nextDeclarationEnd(text, i);
        const piece = std.mem.trim(u8, text[i..semi], " \t\r\n");
        if (piece.len > 0) {
            if (parseDeclaration(piece)) |decl| {
                try out.append(allocator, decl);
            }
        }
        i = if (semi < text.len) semi + 1 else text.len;
    }
    return out.toOwnedSlice(allocator);
}

fn nextDeclarationEnd(text: []const u8, start: usize) usize {
    var i = start;
    var paren_depth: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '/' and i + 1 < text.len and text[i + 1] == '*') {
            const close = std.mem.indexOfPos(u8, text, i + 2, "*/") orelse return text.len;
            i = close + 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            const close = std.mem.indexOfScalarPos(u8, text, i + 1, c) orelse return text.len;
            i = close;
            continue;
        }
        if (c == '(') paren_depth += 1;
        if (c == ')' and paren_depth > 0) paren_depth -= 1;
        if (c == ';' and paren_depth == 0) return i;
    }
    return text.len;
}

fn parseDeclaration(piece: []const u8) ?Declaration {
    const colon = std.mem.indexOfScalar(u8, piece, ':') orelse return null;
    const name = std.mem.trim(u8, piece[0..colon], " \t\r\n");
    var value = std.mem.trim(u8, piece[colon + 1 ..], " \t\r\n");
    var important = false;
    if (std.mem.endsWith(u8, value, "!important")) {
        value = std.mem.trimEnd(u8, value[0 .. value.len - "!important".len], " \t\r\n");
        important = true;
    } else if (std.mem.endsWith(u8, value, "! important")) {
        value = std.mem.trimEnd(u8, value[0 .. value.len - "! important".len], " \t\r\n");
        important = true;
    }
    if (name.len == 0) return null;
    return .{ .name = name, .value = value, .important = important };
}

// ---------------- Selector matching ----------------

pub fn selectorMatchesNode(doc: *const dom.Document, node_id: dom.NodeId, selector: Selector) bool {
    if (selector.steps.len == 0) return false;
    return matchSelectorStep(doc, node_id, selector.steps, selector.steps.len - 1);
}

fn matchSelectorStep(doc: *const dom.Document, node_id: dom.NodeId, steps: []const SelectorStep, step_index: usize) bool {
    if (!matchSingleStep(doc, node_id, steps[step_index])) return false;
    if (step_index == 0) return true;
    const relation = steps[step_index].relation;
    switch (relation) {
        .descendant => {
            var ancestor = parentElement(doc, node_id);
            while (ancestor) |aid| : (ancestor = parentElement(doc, aid)) {
                if (matchSelectorStep(doc, aid, steps, step_index - 1)) return true;
            }
            return false;
        },
        .child => {
            const parent = parentElement(doc, node_id) orelse return false;
            return matchSelectorStep(doc, parent, steps, step_index - 1);
        },
        .adjacent_sibling => {
            const sibling = previousElementSibling(doc, node_id) orelse return false;
            return matchSelectorStep(doc, sibling, steps, step_index - 1);
        },
        .general_sibling => {
            var sibling = previousElementSibling(doc, node_id);
            while (sibling) |sid| : (sibling = previousElementSibling(doc, sid)) {
                if (matchSelectorStep(doc, sid, steps, step_index - 1)) return true;
            }
            return false;
        },
    }
}

fn matchSingleStep(doc: *const dom.Document, node_id: dom.NodeId, step: SelectorStep) bool {
    const node = doc.getNode(node_id);
    if (node.kind != .element) return false;
    if (step.tag) |tag| {
        if (!std.ascii.eqlIgnoreCase(node.name, tag)) return false;
    }
    if (step.id) |id_value| {
        const attr = doc.getAttribute(node_id, "id") orelse return false;
        if (!std.mem.eql(u8, attr, id_value)) return false;
    }
    if (step.classes.len > 0) {
        const attr = doc.getAttribute(node_id, "class") orelse return false;
        for (step.classes) |class_name| {
            if (!classListContains(attr, class_name)) return false;
        }
    }
    return true;
}

fn parentElement(doc: *const dom.Document, node_id: dom.NodeId) ?dom.NodeId {
    var current = doc.nodes[node_id].parent;
    while (current) |pid| : (current = doc.nodes[pid].parent) {
        if (doc.nodes[pid].kind == .element) return pid;
    }
    return null;
}

fn previousElementSibling(doc: *const dom.Document, node_id: dom.NodeId) ?dom.NodeId {
    var current = doc.nodes[node_id].prev_sibling;
    while (current) |pid| : (current = doc.nodes[pid].prev_sibling) {
        if (doc.nodes[pid].kind == .element) return pid;
    }
    return null;
}

fn classListContains(attr: []const u8, class_name: []const u8) bool {
    var iter = std.mem.tokenizeAny(u8, attr, " \t\r\n");
    while (iter.next()) |token| {
        if (std.mem.eql(u8, token, class_name)) return true;
    }
    return false;
}

// ---------------- Cascade / Computed style ----------------

pub fn matchedRulesForNode(
    allocator: std.mem.Allocator,
    sheets: []const *const Stylesheet,
    doc: *const dom.Document,
    node_id: dom.NodeId,
) ![]MatchedRule {
    var out: std.ArrayList(MatchedRule) = .empty;
    for (sheets) |sheet| {
        for (sheet.rules, 0..) |rule, idx| {
            for (rule.selectors) |selector| {
                if (selectorMatchesNode(doc, node_id, selector)) {
                    try out.append(allocator, .{
                        .selector = selector,
                        .declarations = rule.declarations,
                        .origin = sheet.origin,
                        .rule_index = idx,
                    });
                    break;
                }
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn parseInlineStyle(allocator: std.mem.Allocator, attr: []const u8) ![]Declaration {
    return parseDeclarations(allocator, attr);
}

const SortKey = struct {
    origin_rank: u8,
    important: bool,
    specificity: u32,
    rule_index: usize,
    decl_index: usize,
};

fn sortKeyLessThan(_: void, a: SortKey, b: SortKey) bool {
    // Cascade priority (lowest first; later wins):
    // 1. !important author/inline beats normal everything; we handle by separate buckets implicitly.
    // 2. origin_rank (user_agent < author < inline_style).
    // 3. specificity (higher wins).
    // 4. order in the source (later wins).
    if (a.important != b.important) return !a.important; // important entries come last
    if (a.origin_rank != b.origin_rank) return a.origin_rank < b.origin_rank;
    if (a.specificity != b.specificity) return a.specificity < b.specificity;
    if (a.rule_index != b.rule_index) return a.rule_index < b.rule_index;
    return a.decl_index < b.decl_index;
}
// ---------------- Shorthand expansion helpers ----------------
//
// These helpers turn a CSS shorthand value into its longhand `(name, value)`
// pairs. The returned `value` slices point into the input `value` string —
// no allocation happens for the value strings themselves. Names are static
// string literals.
//
// Callers (computeStyleForNode) push each expanded pair into the cascade
// alongside the original shorthand, with the same SortKey priority. That way
// an author shorthand like `body { font: 14px Verdana }` properly overrides
// a UA `body { font-family: Times }` longhand instead of being masked by it.

const LonghandPair = struct {
    name: []const u8,
    value: []const u8,
};

fn isLengthOrPercentToken(token: []const u8) bool {
    if (token.len == 0) return false;
    var i: usize = 0;
    if (token[0] == '+' or token[0] == '-') i += 1;
    var saw_digit = false;
    while (i < token.len and (std.ascii.isDigit(token[i]) or token[i] == '.')) : (i += 1) {
        if (std.ascii.isDigit(token[i])) saw_digit = true;
    }
    if (!saw_digit) return false;
    // Trailing unit (px, em, rem, %, vh, vw, etc.) — we only require a non-empty unit
    // OR no unit at all (bare number, e.g. line-height factor) is rejected by this
    // helper; callers that want bare numbers handle them separately.
    return i < token.len;
}

fn isBareNumberToken(token: []const u8) bool {
    if (token.len == 0) return false;
    var i: usize = 0;
    if (token[0] == '+' or token[0] == '-') i += 1;
    var saw_digit = false;
    while (i < token.len) : (i += 1) {
        const c = token[i];
        if (std.ascii.isDigit(c)) {
            saw_digit = true;
        } else if (c == '.') {
            // ok
        } else {
            return false;
        }
    }
    return saw_digit;
}

fn isFontStyleKeyword(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "italic") or
        std.ascii.eqlIgnoreCase(token, "oblique");
}

fn isFontWeightKeyword(token: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(token, "bold")) return true;
    if (std.ascii.eqlIgnoreCase(token, "bolder")) return true;
    if (std.ascii.eqlIgnoreCase(token, "lighter")) return true;
    // numeric weights like 100, 200, ..., 900
    if (isBareNumberToken(token)) {
        const n = std.fmt.parseFloat(f64, token) catch return false;
        if (n >= 1 and n <= 1000) return true;
    }
    return false;
}

fn isFontVariantKeyword(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "small-caps");
}

fn isBorderStyleKeyword(token: []const u8) bool {
    const styles = [_][]const u8{
        "none",   "hidden", "dotted", "dashed", "solid",
        "double", "groove", "ridge",  "inset",  "outset",
    };
    for (styles) |s| {
        if (std.ascii.eqlIgnoreCase(token, s)) return true;
    }
    return false;
}

fn isBorderWidthKeyword(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "thin") or
        std.ascii.eqlIgnoreCase(token, "medium") or
        std.ascii.eqlIgnoreCase(token, "thick");
}

fn isListStylePositionKeyword(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "inside") or
        std.ascii.eqlIgnoreCase(token, "outside");
}

fn isListStyleTypeKeyword(token: []const u8) bool {
    const types = [_][]const u8{
        "disc",                 "circle",       "square",
        "decimal",              "decimal-leading-zero",
        "lower-roman",          "upper-roman",
        "lower-greek",          "lower-alpha",  "lower-latin",
        "upper-alpha",          "upper-latin",
        "armenian",             "georgian",
        "none",
    };
    for (types) |t| {
        if (std.ascii.eqlIgnoreCase(token, t)) return true;
    }
    return false;
}

/// Expand `padding` / `margin` 1/2/3/4-token shorthand into four longhand
/// pairs. `prefix` is "padding" or "margin". Returns the number of pairs
/// written (always 4 on success, 0 if input has no tokens).
fn expandEdgeShorthand(prefix_top: []const u8, prefix_right: []const u8, prefix_bottom: []const u8, prefix_left: []const u8, value: []const u8, out: *[4]LonghandPair) usize {
    var iter = std.mem.tokenizeAny(u8, value, " \t\r\n");
    var tokens: [4][]const u8 = .{ "", "", "", "" };
    var n: usize = 0;
    while (iter.next()) |t| : (n += 1) {
        if (n >= 4) break;
        tokens[n] = t;
    }
    if (n == 0) return 0;
    const t0 = tokens[0];
    const t1 = if (n >= 2) tokens[1] else t0;
    const t2 = if (n >= 3) tokens[2] else t0;
    const t3 = if (n >= 4) tokens[3] else t1;
    out[0] = .{ .name = prefix_top, .value = t0 };
    out[1] = .{ .name = prefix_right, .value = t1 };
    out[2] = .{ .name = prefix_bottom, .value = t2 };
    out[3] = .{ .name = prefix_left, .value = t3 };
    return 4;
}

/// Expand `border: <width> <style> <color>` (in any order) into up to three
/// longhand pairs. Returns the number of pairs written. Tokens that do not
/// match any classification are silently dropped — but we keep going so that
/// e.g. `border: solid red` still produces border-style + border-color.
fn expandBorderShorthand(value: []const u8, out: *[3]LonghandPair) usize {
    var n: usize = 0;
    var have_width = false;
    var have_style = false;
    var have_color = false;
    var iter = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (iter.next()) |t| {
        if (!have_width and (isLengthOrPercentToken(t) or isBorderWidthKeyword(t))) {
            out[n] = .{ .name = "border-width", .value = t };
            n += 1;
            have_width = true;
            continue;
        }
        if (!have_style and isBorderStyleKeyword(t)) {
            out[n] = .{ .name = "border-style", .value = t };
            n += 1;
            have_style = true;
            continue;
        }
        if (!have_color) {
            // Anything else is treated as a color (named, hex, rgb(), etc.).
            // For multi-token color values like `rgb(0, 0, 0)`, this naive
            // tokenizer would split — but kuri's tokenizer uses whitespace
            // only, so `rgb(0,0,0)` (no spaces) survives as one token.
            // Spaces inside parens would break this; we skip such cases.
            out[n] = .{ .name = "border-color", .value = t };
            n += 1;
            have_color = true;
            continue;
        }
        if (n >= 3) break;
    }
    return n;
}

/// Expand `font` shorthand. Common forms supported:
///   font: 14px sans-serif
///   font: bold 14px/1.2 Helvetica, Arial, sans-serif
///   font: italic bold 16px Georgia
/// Returns the number of pairs written.
fn expandFontShorthand(value: []const u8, out: *[5]LonghandPair) usize {
    var n: usize = 0;
    var size_idx_in_value: ?usize = null;
    var size_token_end_in_value: usize = 0;

    // Walk tokens, classifying pre-size keywords until we hit the size token.
    var have_style = false;
    var have_weight = false;
    var have_variant = false;

    // Track byte offsets inside `value` so we can preserve the family slice
    // (which may contain commas + spaces) verbatim.
    var i: usize = 0;
    while (i < value.len) {
        // Skip whitespace
        while (i < value.len and (value[i] == ' ' or value[i] == '\t' or value[i] == '\r' or value[i] == '\n')) i += 1;
        if (i >= value.len) break;
        const tok_start = i;
        while (i < value.len and value[i] != ' ' and value[i] != '\t' and value[i] != '\r' and value[i] != '\n') i += 1;
        const tok = value[tok_start..i];
        if (tok.len == 0) continue;

        // Is this the size token? It either contains '/' (e.g. "14px/1.2") or
        // is a length (e.g. "14px", "1.2em").
        const slash = std.mem.indexOfScalar(u8, tok, '/');
        if (slash != null or isLengthOrPercentToken(tok)) {
            // Split out font-size and possibly line-height.
            if (slash) |s| {
                const size_part = tok[0..s];
                const lh_part = tok[s + 1 ..];
                if (size_part.len > 0 and (isLengthOrPercentToken(size_part) or isBareNumberToken(size_part))) {
                    out[n] = .{ .name = "font-size", .value = size_part };
                    n += 1;
                }
                if (lh_part.len > 0) {
                    out[n] = .{ .name = "line-height", .value = lh_part };
                    n += 1;
                }
            } else {
                out[n] = .{ .name = "font-size", .value = tok };
                n += 1;
            }
            size_idx_in_value = tok_start;
            size_token_end_in_value = i;
            break;
        }

        // Pre-size keyword
        if (!have_style and isFontStyleKeyword(tok)) {
            out[n] = .{ .name = "font-style", .value = tok };
            n += 1;
            have_style = true;
            continue;
        }
        if (!have_weight and isFontWeightKeyword(tok)) {
            out[n] = .{ .name = "font-weight", .value = tok };
            n += 1;
            have_weight = true;
            continue;
        }
        if (!have_variant and isFontVariantKeyword(tok)) {
            out[n] = .{ .name = "font-variant", .value = tok };
            n += 1;
            have_variant = true;
            continue;
        }
        // Unknown pre-size token — bail. Without a size we can't reliably split.
        return 0;
    }

    if (size_idx_in_value == null) {
        // No size found — malformed shorthand; do not synthesize anything.
        return 0;
    }

    // Family is everything after the size token, trimmed.
    if (size_token_end_in_value < value.len) {
        const family = std.mem.trim(u8, value[size_token_end_in_value..], " \t\r\n");
        if (family.len > 0) {
            out[n] = .{ .name = "font-family", .value = family };
            n += 1;
        }
    }

    return n;
}

/// Expand `list-style: <type> <position> <image>`. Just classifies known
/// keywords. `none` is ambiguous (could be type or image) — we map it to
/// list-style-type.
fn expandListStyleShorthand(value: []const u8, out: *[3]LonghandPair) usize {
    var n: usize = 0;
    var have_type = false;
    var have_position = false;
    var have_image = false;
    var iter = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (iter.next()) |t| {
        if (!have_position and isListStylePositionKeyword(t)) {
            out[n] = .{ .name = "list-style-position", .value = t };
            n += 1;
            have_position = true;
            continue;
        }
        if (!have_type and isListStyleTypeKeyword(t)) {
            out[n] = .{ .name = "list-style-type", .value = t };
            n += 1;
            have_type = true;
            continue;
        }
        if (!have_image and (std.mem.startsWith(u8, t, "url(") or std.mem.startsWith(u8, t, "URL("))) {
            out[n] = .{ .name = "list-style-image", .value = t };
            n += 1;
            have_image = true;
            continue;
        }
        if (n >= 3) break;
    }
    return n;
}

/// Dispatch on the shorthand `name`. Writes up to `out.len` longhand pairs
/// into `out` and returns the number written. `out` must be at least 5 wide.
fn expandShorthand(name: []const u8, value: []const u8, out: *[5]LonghandPair) usize {
    if (std.ascii.eqlIgnoreCase(name, "background")) {
        out[0] = .{ .name = "background-color", .value = value };
        return 1;
    }
    if (std.ascii.eqlIgnoreCase(name, "padding")) {
        var buf: [4]LonghandPair = undefined;
        const k = expandEdgeShorthand("padding-top", "padding-right", "padding-bottom", "padding-left", value, &buf);
        for (0..k) |i| out[i] = buf[i];
        return k;
    }
    if (std.ascii.eqlIgnoreCase(name, "margin")) {
        var buf: [4]LonghandPair = undefined;
        const k = expandEdgeShorthand("margin-top", "margin-right", "margin-bottom", "margin-left", value, &buf);
        for (0..k) |i| out[i] = buf[i];
        return k;
    }
    if (std.ascii.eqlIgnoreCase(name, "border")) {
        var buf: [3]LonghandPair = undefined;
        const k = expandBorderShorthand(value, &buf);
        for (0..k) |i| out[i] = buf[i];
        return k;
    }
    if (std.ascii.eqlIgnoreCase(name, "font")) {
        return expandFontShorthand(value, out);
    }
    if (std.ascii.eqlIgnoreCase(name, "list-style")) {
        var buf: [3]LonghandPair = undefined;
        const k = expandListStyleShorthand(value, &buf);
        for (0..k) |i| out[i] = buf[i];
        return k;
    }
    return 0;
}

pub fn computeStyleForNode(
    allocator: std.mem.Allocator,
    sheets: []const *const Stylesheet,
    doc: *const dom.Document,
    node_id: dom.NodeId,
    inline_style: []const u8,
) !ComputedStyle {
    var keys: std.ArrayList(SortKey) = .empty;
    defer keys.deinit(allocator);
    var values: std.ArrayList(Declaration) = .empty;
    defer values.deinit(allocator);

    for (sheets) |sheet| {
        for (sheet.rules, 0..) |rule, idx| {
            // Find best-matching selector specificity for this rule against this node.
            var best: ?u32 = null;
            for (rule.selectors) |selector| {
                if (selectorMatchesNode(doc, node_id, selector)) {
                    if (best == null or selector.specificity > best.?) best = selector.specificity;
                }
            }
            if (best) |spec| {
                for (rule.declarations, 0..) |decl, decl_idx| {
                    try values.append(allocator, decl);
                    try keys.append(allocator, .{
                        .origin_rank = @intFromEnum(sheet.origin),
                        .important = decl.important,
                        .specificity = spec,
                        .rule_index = idx,
                        .decl_index = decl_idx,
                    });
                    // Expand any known CSS shorthand into synthetic longhand
                    // declarations at the same priority. This lets author
                    // shorthands like `body { font: 14px Verdana }` properly
                    // override UA longhands like `body { font-family: Times }`
                    // instead of being masked by them.
                    var longhands: [5]LonghandPair = undefined;
                    const lh_count = expandShorthand(decl.name, decl.value, &longhands);
                    for (longhands[0..lh_count]) |lh| {
                        try values.append(allocator, .{
                            .name = lh.name,
                            .value = lh.value,
                            .important = decl.important,
                        });
                        try keys.append(allocator, .{
                            .origin_rank = @intFromEnum(sheet.origin),
                            .important = decl.important,
                            .specificity = spec,
                            .rule_index = idx,
                            .decl_index = decl_idx,
                        });
                    }
                }
            }
        }
    }

    if (inline_style.len > 0) {
        const inline_decls = try parseDeclarations(allocator, inline_style);
        defer allocator.free(inline_decls);
        for (inline_decls, 0..) |decl, idx| {
            try values.append(allocator, decl);
            try keys.append(allocator, .{
                .origin_rank = @intFromEnum(Origin.inline_style),
                .important = decl.important,
                .specificity = 0xFFFFFFFF,
                .rule_index = std.math.maxInt(usize),
                .decl_index = idx,
            });
            // Same shorthand expansion as for sheet rules above.
            var longhands: [5]LonghandPair = undefined;
            const lh_count = expandShorthand(decl.name, decl.value, &longhands);
            for (longhands[0..lh_count]) |lh| {
                try values.append(allocator, .{
                    .name = lh.name,
                    .value = lh.value,
                    .important = decl.important,
                });
                try keys.append(allocator, .{
                    .origin_rank = @intFromEnum(Origin.inline_style),
                    .important = decl.important,
                    .specificity = 0xFFFFFFFF,
                    .rule_index = std.math.maxInt(usize),
                    .decl_index = idx,
                });
            }
        }
    }

    if (values.items.len == 0) {
        return .{ .properties = &.{} };
    }

    // Sort indices by cascade priority.
    const indices = try allocator.alloc(usize, values.items.len);
    defer allocator.free(indices);
    for (indices, 0..) |*v, i| v.* = i;
    std.sort.block(usize, indices, IndicesContext{ .keys = keys.items }, indicesLessThan);

    // Walk in priority order; later values win, keep last per name.
    var name_to_index: std.StringHashMapUnmanaged(usize) = .empty;
    defer name_to_index.deinit(allocator);
    for (indices) |idx| {
        const decl = values.items[idx];
        try name_to_index.put(allocator, decl.name, idx);
    }

    var out: std.ArrayList(Declaration) = .empty;
    var iter = name_to_index.iterator();
    while (iter.next()) |entry| {
        try out.append(allocator, values.items[entry.value_ptr.*]);
    }

    return .{ .properties = try out.toOwnedSlice(allocator) };
}

const IndicesContext = struct { keys: []const SortKey };

fn indicesLessThan(ctx: IndicesContext, a: usize, b: usize) bool {
    return sortKeyLessThan({}, ctx.keys[a], ctx.keys[b]);
}

// ---------------- User-agent stylesheet ----------------

pub const default_user_agent_css =
    \\html, address, blockquote, body, dd, div, dl, dt, fieldset, form, frame, frameset, h1, h2, h3, h4, h5, h6, noframes, ol, p, ul, center, dir, hr, menu, pre { display: block; }
    \\h1 { font-size: 2em; margin: 0.67em 0; font-weight: bold; }
    \\h2 { font-size: 1.5em; margin: 0.83em 0; font-weight: bold; }
    \\h3 { font-size: 1.17em; margin: 1em 0; font-weight: bold; }
    \\h4 { font-size: 1em; margin: 1.33em 0; font-weight: bold; }
    \\h5 { font-size: 0.83em; margin: 1.67em 0; font-weight: bold; }
    \\h6 { font-size: 0.67em; margin: 2.33em 0; font-weight: bold; }
    \\b, strong { font-weight: bold; }
    \\i, cite, em, var, address, dfn { font-style: italic; }
    \\code, kbd, pre, samp, tt { font-family: monospace; }
    \\a:link { color: blue; text-decoration: underline; }
    \\a:visited { color: purple; }
    \\body { display: block; margin: 8px; font-family: sans-serif; font-size: 16px; color: black; background-color: white; }
    \\html { display: block; }
    \\head { display: none; }
    \\script, style { display: none; }
    \\img { display: inline-block; }
    \\table { border-collapse: separate; border-spacing: 2px; }
    \\td, th { padding: 1px; }
    \\th { font-weight: bold; text-align: center; }
    \\caption { text-align: center; }
    \\ul, menu, dir { list-style-type: disc; padding-left: 40px; }
    \\ol { list-style-type: decimal; padding-left: 40px; }
    \\input, textarea, select, button { font-family: inherit; font-size: inherit; }
    \\hr { border: 1px inset; margin: 0.5em auto; }
;

pub fn extractAllStyleText(allocator: std.mem.Allocator, doc: *const dom.Document) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (doc.nodes) |node| {
        if (node.kind != .element) continue;
        if (!std.ascii.eqlIgnoreCase(node.name, "style")) continue;
        var child = node.first_child;
        while (child) |child_id| : (child = doc.getNode(child_id).next_sibling) {
            const child_node = doc.getNode(child_id);
            if (child_node.kind == .text) {
                try out.appendSlice(allocator, child_node.text);
                try out.append(allocator, '\n');
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn loadUserAgentSheet(allocator: std.mem.Allocator) !Stylesheet {
    return Stylesheet.fromText(allocator, default_user_agent_css, .user_agent);
}

// ---------------- Tests ----------------

test "parse simple rule" {
    const src = "body { color: red; font-size: 14px; }";
    var sheet = try Stylesheet.fromText(std.testing.allocator, src, .author);
    defer sheet.deinit();
    try std.testing.expectEqual(@as(usize, 1), sheet.rules.len);
    try std.testing.expectEqual(@as(usize, 1), sheet.rules[0].selectors.len);
    try std.testing.expect(std.mem.eql(u8, sheet.rules[0].selectors[0].steps[0].tag.?, "body"));
    try std.testing.expectEqual(@as(usize, 2), sheet.rules[0].declarations.len);
    try std.testing.expect(std.mem.eql(u8, sheet.rules[0].declarations[0].name, "color"));
    try std.testing.expect(std.mem.eql(u8, sheet.rules[0].declarations[0].value, "red"));
}

test "parse selector list and class/id" {
    const src = "div.note, #header > p { color: blue; }";
    var sheet = try Stylesheet.fromText(std.testing.allocator, src, .author);
    defer sheet.deinit();
    try std.testing.expectEqual(@as(usize, 1), sheet.rules.len);
    try std.testing.expectEqual(@as(usize, 2), sheet.rules[0].selectors.len);
    const sel0 = sheet.rules[0].selectors[0];
    try std.testing.expect(std.mem.eql(u8, sel0.steps[0].tag.?, "div"));
    try std.testing.expectEqual(@as(usize, 1), sel0.steps[0].classes.len);
    try std.testing.expect(std.mem.eql(u8, sel0.steps[0].classes[0], "note"));
    const sel1 = sheet.rules[0].selectors[1];
    try std.testing.expectEqual(@as(usize, 2), sel1.steps.len);
    try std.testing.expectEqual(Combinator.child, sel1.steps[1].relation);
    try std.testing.expect(std.mem.eql(u8, sel1.steps[0].id.?, "header"));
}

test "parse and skip @media" {
    const src = "@media (max-width: 600px) { body { color: red; } }\nh1 { font-size: 30px; }";
    var sheet = try Stylesheet.fromText(std.testing.allocator, src, .author);
    defer sheet.deinit();
    try std.testing.expectEqual(@as(usize, 1), sheet.rules.len);
    try std.testing.expect(std.mem.eql(u8, sheet.rules[0].selectors[0].steps[0].tag.?, "h1"));
}

test "important flag" {
    const src = "p { color: red !important; }";
    var sheet = try Stylesheet.fromText(std.testing.allocator, src, .author);
    defer sheet.deinit();
    try std.testing.expect(sheet.rules[0].declarations[0].important);
    try std.testing.expect(std.mem.eql(u8, sheet.rules[0].declarations[0].value, "red"));
}

test "computeStyle cascade and specificity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try dom.Document.parse(a, "<html><body><p class=\"note\" id=\"hello\">hi</p></body></html>");
    const p_id = (try doc.querySelector(a, "p")).?;

    var ua = try loadUserAgentSheet(a);
    var author = try Stylesheet.fromText(a, "p { color: red; } .note { color: green; } #hello { color: blue; }", .author);

    const sheets: []const *const Stylesheet = &.{ &ua, &author };
    const style = try computeStyleForNode(a, sheets, &doc, p_id, "");

    const color = style.get("color") orelse "";
    try std.testing.expect(std.mem.eql(u8, color, "blue"));
}

test "inline style overrides author" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try dom.Document.parse(a, "<p class=\"x\" style=\"color: orange\">hi</p>");
    const p_id = (try doc.querySelector(a, "p")).?;

    var author = try Stylesheet.fromText(a, ".x { color: green; }", .author);

    const sheets: []const *const Stylesheet = &.{&author};
    const style = try computeStyleForNode(a, sheets, &doc, p_id, "color: orange");

    try std.testing.expect(std.mem.eql(u8, style.get("color").?, "orange"));
}

test "extractAllStyleText collects style blocks" {
    var doc = try dom.Document.parse(std.testing.allocator, "<style>body { color: red; }</style><style>p { font-size: 14px; }</style>");
    defer doc.deinit();
    const text = try extractAllStyleText(std.testing.allocator, &doc);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "color: red") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "font-size: 14px") != null);
}

test "font shorthand cascades to font-size and font-family" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try dom.Document.parse(a, "<html><body><p>hi</p></body></html>");
    const body_id = (try doc.querySelector(a, "body")).?;

    var ua = try Stylesheet.fromText(a, "body { font-family: Times; font-size: 16px; }", .user_agent);
    var author = try Stylesheet.fromText(a, "body { font: 14px Verdana }", .author);

    const sheets: []const *const Stylesheet = &.{ &ua, &author };
    const style = try computeStyleForNode(a, sheets, &doc, body_id, "");

    try std.testing.expect(std.mem.eql(u8, style.get("font-size").?, "14px"));
    try std.testing.expect(std.mem.eql(u8, style.get("font-family").?, "Verdana"));
}

test "border shorthand cascades to border-width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try dom.Document.parse(a, "<html><body><div>x</div></body></html>");
    const div_id = (try doc.querySelector(a, "div")).?;

    var author = try Stylesheet.fromText(a, "div { border: 2px solid red }", .author);

    const sheets: []const *const Stylesheet = &.{&author};
    const style = try computeStyleForNode(a, sheets, &doc, div_id, "");

    try std.testing.expect(std.mem.eql(u8, style.get("border-width").?, "2px"));
    try std.testing.expect(std.mem.eql(u8, style.get("border-style").?, "solid"));
    try std.testing.expect(std.mem.eql(u8, style.get("border-color").?, "red"));
}

test "padding shorthand expands to four longhands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try dom.Document.parse(a, "<html><body><p>hi</p></body></html>");
    const p_id = (try doc.querySelector(a, "p")).?;

    var author = try Stylesheet.fromText(a, "p { padding: 10px 20px }", .author);

    const sheets: []const *const Stylesheet = &.{&author};
    const style = try computeStyleForNode(a, sheets, &doc, p_id, "");

    try std.testing.expect(std.mem.eql(u8, style.get("padding-top").?, "10px"));
    try std.testing.expect(std.mem.eql(u8, style.get("padding-right").?, "20px"));
    try std.testing.expect(std.mem.eql(u8, style.get("padding-bottom").?, "10px"));
    try std.testing.expect(std.mem.eql(u8, style.get("padding-left").?, "20px"));
}

test "margin shorthand expands to four longhands with 4-token rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try dom.Document.parse(a, "<html><body><p>hi</p></body></html>");
    const p_id = (try doc.querySelector(a, "p")).?;

    var author = try Stylesheet.fromText(a, "p { margin: 1px 2px 3px 4px }", .author);

    const sheets: []const *const Stylesheet = &.{&author};
    const style = try computeStyleForNode(a, sheets, &doc, p_id, "");

    try std.testing.expect(std.mem.eql(u8, style.get("margin-top").?, "1px"));
    try std.testing.expect(std.mem.eql(u8, style.get("margin-right").?, "2px"));
    try std.testing.expect(std.mem.eql(u8, style.get("margin-bottom").?, "3px"));
    try std.testing.expect(std.mem.eql(u8, style.get("margin-left").?, "4px"));
}

test "font shorthand with line-height splits font-size and line-height" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try dom.Document.parse(a, "<html><body><p>hi</p></body></html>");
    const p_id = (try doc.querySelector(a, "p")).?;

    var author = try Stylesheet.fromText(a, "p { font: bold 14px/1.2 Helvetica, Arial, sans-serif }", .author);

    const sheets: []const *const Stylesheet = &.{&author};
    const style = try computeStyleForNode(a, sheets, &doc, p_id, "");

    try std.testing.expect(std.mem.eql(u8, style.get("font-weight").?, "bold"));
    try std.testing.expect(std.mem.eql(u8, style.get("font-size").?, "14px"));
    try std.testing.expect(std.mem.eql(u8, style.get("line-height").?, "1.2"));
    try std.testing.expect(std.mem.eql(u8, style.get("font-family").?, "Helvetica, Arial, sans-serif"));
}

test "list-style shorthand cascades to list-style-type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try dom.Document.parse(a, "<html><body><ul><li>x</li></ul></body></html>");
    const ul_id = (try doc.querySelector(a, "ul")).?;

    var ua = try Stylesheet.fromText(a, "ul { list-style-type: disc; }", .user_agent);
    var author = try Stylesheet.fromText(a, "ul { list-style: square inside }", .author);

    const sheets: []const *const Stylesheet = &.{ &ua, &author };
    const style = try computeStyleForNode(a, sheets, &doc, ul_id, "");

    try std.testing.expect(std.mem.eql(u8, style.get("list-style-type").?, "square"));
    try std.testing.expect(std.mem.eql(u8, style.get("list-style-position").?, "inside"));
}

test "background shorthand still synthesizes background-color" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = try dom.Document.parse(a, "<html><body><p>hi</p></body></html>");
    const body_id = (try doc.querySelector(a, "body")).?;

    var ua = try Stylesheet.fromText(a, "body { background-color: white; }", .user_agent);
    var author = try Stylesheet.fromText(a, "body { background: #f0f0f2 }", .author);

    const sheets: []const *const Stylesheet = &.{ &ua, &author };
    const style = try computeStyleForNode(a, sheets, &doc, body_id, "");

    try std.testing.expect(std.mem.eql(u8, style.get("background-color").?, "#f0f0f2"));
}
