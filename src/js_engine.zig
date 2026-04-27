const std = @import("std");
const quickjs = @import("quickjs");

/// Minimal JS engine wrapper around QuickJS for evaluating scripts in fetched HTML.
pub const JsEngine = struct {
    rt: *quickjs.Runtime,
    ctx: *quickjs.Context,

    pub fn init() !JsEngine {
        const rt = try quickjs.Runtime.init();
        const ctx = quickjs.Context.init(rt) catch {
            rt.deinit();
            return error.JsContextInit;
        };
        return .{ .rt = rt, .ctx = ctx };
    }

    pub fn deinit(self: *JsEngine) void {
        self.ctx.deinit();
        self.rt.deinit();
    }

    /// Evaluate a JavaScript string, discarding the result. Returns null on exception.
    pub fn exec(self: *JsEngine, code: []const u8) bool {
        const result = self.ctx.eval(code, "<eval>", .{});
        const ok = !result.isException();
        result.deinit(self.ctx);
        return ok;
    }

    /// Evaluate a JS string, return the result as a Zig-owned copy (safe across calls).
    /// Returns null on exception or if result is not convertible to string.
    pub fn evalAlloc(self: *JsEngine, allocator: std.mem.Allocator, code: []const u8) ?[]const u8 {
        const result = self.ctx.eval(code, "<eval>", .{});
        if (result.isException()) {
            result.deinit(self.ctx);
            return null;
        }
        const str = result.toCString(self.ctx) orelse {
            result.deinit(self.ctx);
            return null;
        };
        // Dupe BEFORE freeing the JS value, since toCString points into JS heap
        const duped = allocator.dupe(u8, std.mem.span(str)) catch null;
        result.deinit(self.ctx);
        return duped;
    }
};

/// Extract inline <script> tag contents from HTML.
/// Returns a slice of script body strings.
pub fn extractInlineScripts(html: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    var scripts: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;

    while (i < html.len) {
        // Find <script> or <script ...>
        const tag_pos = findScriptOpen(html, i) orelse break;
        const tag_end = std.mem.indexOfScalarPos(u8, html, tag_pos, '>') orelse break;

        // Check if it has a src= attribute (skip external scripts)
        const tag_content = html[tag_pos..tag_end];
        if (std.mem.indexOf(u8, tag_content, "src=") != null or
            std.mem.indexOf(u8, tag_content, "src =") != null)
        {
            i = tag_end + 1;
            continue;
        }

        const body_start = tag_end + 1;
        const close = std.mem.indexOfPos(u8, html, body_start, "</script>") orelse
            std.mem.indexOfPos(u8, html, body_start, "</SCRIPT>") orelse break;

        const body = std.mem.trim(u8, html[body_start..close], " \t\n\r");
        if (body.len > 0) {
            try scripts.append(allocator, body);
        }
        i = close + 9; // len("</script>")
    }

    return scripts.toOwnedSlice(allocator);
}

fn findScriptOpen(html: []const u8, start: usize) ?usize {
    const patterns = [_][]const u8{ "<script>", "<script ", "<SCRIPT>", "<SCRIPT " };
    var best: ?usize = null;
    for (patterns) |pat| {
        if (std.mem.indexOfPos(u8, html, start, pat)) |pos| {
            if (best == null or pos < best.?) best = pos;
        }
    }
    return best;
}

/// Run all inline scripts through QuickJS and return combined output.
/// Scripts that call document.write() or similar will have their output captured.
pub fn evalHtmlScripts(html: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    return evalHtmlScriptsWithUrl(html, null, allocator);
}

/// Like evalHtmlScripts but also sets window.location from the given URL.
pub fn evalHtmlScriptsWithUrl(html: []const u8, url: ?[]const u8, allocator: std.mem.Allocator) !?[]const u8 {
    const scripts = try extractInlineScripts(html, allocator);
    defer allocator.free(scripts);
    if (scripts.len == 0) return null;

    var engine = JsEngine.init() catch return null;
    defer engine.deinit();

    // Use a temporary arena for DOM stub string building (freed after injection)
    var stub_arena = std.heap.ArenaAllocator.init(allocator);
    defer stub_arena.deinit();

    // Inject DOM stubs (Layer 3) — must come before user scripts
    injectDomStubs(&engine, html, url, stub_arena.allocator());

    for (scripts) |script| {
        // QuickJS requires null-terminated input; dupe with sentinel
        const duped = allocator.dupeZ(u8, script) catch continue;
        defer allocator.free(duped);
        _ = engine.exec(duped);
    }

    return engine.evalAlloc(allocator, "globalThis.__browdie_output");
}

/// Prepare an existing QuickJS engine with the current page HTML and URL.
/// This exposes the same DOM/window shims used by evalHtmlScriptsWithUrl.
pub fn prepareDomEngine(engine: *JsEngine, html: []const u8, url: ?[]const u8, allocator: std.mem.Allocator) void {
    injectDomStubs(engine, html, url, allocator);
}

/// Return the current captured document.write-style output from an existing engine.
pub fn outputAlloc(engine: *JsEngine, allocator: std.mem.Allocator) ?[]const u8 {
    return engine.evalAlloc(allocator, "globalThis.__browdie_output");
}

/// Inject Layer 3 DOM stubs into a JsEngine context.
/// Provides: document.querySelector/All, getElementById, title, body,
///           window.location, console.log, document.write/writeln.
fn injectDomStubs(engine: *JsEngine, html: []const u8, url: ?[]const u8, allocator: std.mem.Allocator) void {
    // 1. Output capture + basic document/window objects
    _ = engine.exec("globalThis.__browdie_output = '';");

    // 2. Inject HTML source as a JS string for DOM query shims to search
    //    Escape backslashes, quotes, and newlines for safe embedding.
    //    Must null-terminate dynamic strings (QuickJS requires it).
    const escaped_html = escapeForJs(html, allocator) orelse "";
    const html_inject = std.fmt.allocPrint(allocator, "globalThis.__browdie_html = \"{s}\";", .{escaped_html}) catch return;
    const html_inject_z = allocator.dupeZ(u8, html_inject) catch return;
    _ = engine.exec(html_inject_z);

    // 3. Build window.location from URL
    if (url) |u| {
        const escaped_url = escapeForJs(u, allocator) orelse "";
        const loc_js = std.fmt.allocPrint(allocator, dom_location_template, .{
            escaped_url, escaped_url, escaped_url,
        }) catch return;
        const loc_js_z = allocator.dupeZ(u8, loc_js) catch return;
        _ = engine.exec(loc_js_z);
    } else {
        _ = engine.exec("globalThis.window = { location: { href: '', protocol: '', host: '', pathname: '/', search: '', hash: '', hostname: '', port: '', origin: '', toString: function() { return ''; } } };");
    }

    // 4. Inject the full DOM shim (pure JS)
    _ = engine.exec(dom_shim_js);
    _ = engine.exec(dom_runtime_enhancement_js);
}

/// Escape a string for embedding inside a double-quoted string literal (JS/JSON).
pub fn escapeForJs(input: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (input) |c| {
        switch (c) {
            '\\' => buf.appendSlice(allocator, "\\\\") catch return null,
            '"' => buf.appendSlice(allocator, "\\\"") catch return null,
            '\n' => buf.appendSlice(allocator, "\\n") catch return null,
            '\r' => buf.appendSlice(allocator, "\\r") catch return null,
            '\t' => buf.appendSlice(allocator, "\\t") catch return null,
            else => buf.append(allocator, c) catch return null,
        }
    }
    return buf.toOwnedSlice(allocator) catch null;
}

const dom_location_template =
    \\globalThis.window = (function() {{
    \\  var href = "{s}";
    \\  var a = href.indexOf("://");
    \\  var protocol = a > 0 ? href.substring(0, a + 1) : "";
    \\  var rest = a > 0 ? href.substring(a + 3) : href;
    \\  var pathStart = rest.indexOf("/");
    \\  var host = pathStart >= 0 ? rest.substring(0, pathStart) : rest;
    \\  var afterHost = pathStart >= 0 ? rest.substring(pathStart) : "/";
    \\  var hashIdx = afterHost.indexOf("#");
    \\  var hash = hashIdx >= 0 ? afterHost.substring(hashIdx) : "";
    \\  var beforeHash = hashIdx >= 0 ? afterHost.substring(0, hashIdx) : afterHost;
    \\  var searchIdx = beforeHash.indexOf("?");
    \\  var search = searchIdx >= 0 ? beforeHash.substring(searchIdx) : "";
    \\  var pathname = searchIdx >= 0 ? beforeHash.substring(0, searchIdx) : beforeHash;
    \\  var colonIdx = host.indexOf(":");
    \\  var hostname = colonIdx >= 0 ? host.substring(0, colonIdx) : host;
    \\  var port = colonIdx >= 0 ? host.substring(colonIdx + 1) : "";
    \\  var origin = protocol + "//" + host;
    \\  return {{
    \\    location: {{
    \\      href: "{s}", protocol: protocol, host: host, hostname: hostname,
    \\      port: port, pathname: pathname, search: search, hash: hash,
    \\      origin: origin,
    \\      toString: function() {{ return "{s}"; }},
    \\      assign: function() {{}},
    \\      replace: function() {{}},
    \\      reload: function() {{}}
    \\    }},
    \\    innerWidth: 1280, innerHeight: 720,
    \\    setTimeout: function(fn, ms) {{ if (typeof fn === 'function') fn(); return 0; }},
    \\    setInterval: function() {{ return 0; }},
    \\    clearTimeout: function() {{}},
    \\    clearInterval: function() {{}},
    \\    addEventListener: function() {{}},
    \\    removeEventListener: function() {{}},
    \\    dispatchEvent: function() {{ return true; }},
    \\    getComputedStyle: function() {{ return {{}}; }},
    \\    matchMedia: function(query) {{ return {{ media: String(query || ''), matches: false, onchange: null, addListener: function() {{}}, removeListener: function() {{}}, addEventListener: function() {{}}, removeEventListener: function() {{}}, dispatchEvent: function() {{ return true; }} }}; }},
    \\    requestAnimationFrame: function(fn) {{ if (typeof fn === 'function') fn(0); return 0; }},
    \\    cancelAnimationFrame: function() {{}}
    \\  }};
    \\}})();
    \\globalThis.location = globalThis.window.location;
;

/// Pure-JS DOM shim injected into QuickJS before user scripts.
/// Provides querySelector/All, getElementById, title, body, console, etc.
const dom_shim_js =
    \\(function() {
    \\  var html = globalThis.__browdie_html || '';
    \\
    \\  // --- Minimal Element prototype ---
    \\  function Element(tag, attrs, inner) {
    \\    this.tagName = tag.toUpperCase();
    \\    this.nodeName = this.tagName;
    \\    this.nodeType = 1;
    \\    this._attrs = attrs || {};
    \\    this.innerHTML = inner || '';
    \\    this.textContent = inner ? inner.replace(/<[^>]*>/g, '') : '';
    \\    this.innerText = this.textContent;
    \\    this.children = [];
    \\    this.childNodes = [];
    \\    this.style = {};
    \\    this.classList = { add: function(){}, remove: function(){}, toggle: function(){}, contains: function(){ return false; } };
    \\    this.dataset = {};
    \\  }
    \\  Element.prototype.getAttribute = function(n) { return this._attrs[n] || null; };
    \\  Element.prototype.setAttribute = function(n, v) { this._attrs[n] = v; };
    \\  Element.prototype.removeAttribute = function(n) { delete this._attrs[n]; };
    \\  Element.prototype.hasAttribute = function(n) { return n in this._attrs; };
    \\  Element.prototype.querySelector = function() { return null; };
    \\  Element.prototype.querySelectorAll = function() { return []; };
    \\  Element.prototype.getElementsByTagName = function() { return []; };
    \\  Element.prototype.getElementsByClassName = function() { return []; };
    \\  Element.prototype.appendChild = function(c) { return c; };
    \\  Element.prototype.append = function() {};
    \\  Element.prototype.prepend = function() {};
    \\  Element.prototype.removeChild = function(c) { return c; };
    \\  Element.prototype.remove = function() {};
    \\  Element.prototype.addEventListener = function() {};
    \\  Element.prototype.removeEventListener = function() {};
    \\  Element.prototype.dispatchEvent = function() { return true; };
    \\  Element.prototype.getBoundingClientRect = function() { return {top:0,left:0,right:0,bottom:0,width:0,height:0}; };
    \\  Element.prototype.cloneNode = function() { return new Element(this.tagName, this._attrs, this.innerHTML); };
    \\  Element.prototype.closest = function() { return null; };
    \\  Element.prototype.matches = function() { return false; };
    \\  Element.prototype.focus = function() {};
    \\  Element.prototype.blur = function() {};
    \\  Element.prototype.click = function() {};
    \\
    \\  // --- HTML parser: extract elements matching simple selectors ---
    \\  function findTags(src, tagName) {
    \\    var results = [];
    \\    var lower = tagName.toLowerCase();
    \\    var re = new RegExp('<' + lower + '(\\s[^>]*)?>([\\s\\S]*?)(<\\/' + lower + '>)', 'gi');
    \\    var m;
    \\    while ((m = re.exec(src)) !== null) {
    \\      var attrs = {};
    \\      if (m[1]) {
    \\        var ar = new RegExp('(\\w[\\w-]*)\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|(\\S+))', 'g');
    \\        var am;
    \\        while ((am = ar.exec(m[1])) !== null) {
    \\          attrs[am[1].toLowerCase()] = am[2] || am[3] || am[4] || '';
    \\        }
    \\      }
    \\      results.push(new Element(lower, attrs, m[2]));
    \\    }
    \\    return results;
    \\  }
    \\
    \\  function findById(src, id) {
    \\    var re = new RegExp('<(\\w+)([^>]*\\sid\\s*=\\s*["\']' + id + '["\'][^>]*)>([\\s\\S]*?)(<\\/\\1>)', 'i');
    \\    var m = re.exec(src);
    \\    if (!m) return null;
    \\    var attrs = { id: id };
    \\    var ar = new RegExp('(\\w[\\w-]*)\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')', 'g');
    \\    var am;
    \\    while ((am = ar.exec(m[2])) !== null) {
    \\      attrs[am[1].toLowerCase()] = am[2] || am[3] || '';
    \\    }
    \\    return new Element(m[1], attrs, m[3]);
    \\  }
    \\
    \\  function simpleQuery(src, selector) {
    \\    if (!selector) return [];
    \\    selector = selector.trim();
    \\    // #id
    \\    if (selector.charAt(0) === '#') {
    \\      var el = findById(src, selector.substring(1));
    \\      return el ? [el] : [];
    \\    }
    \\    // .class
    \\    if (selector.charAt(0) === '.') {
    \\      var cls = selector.substring(1);
    \\      var all = [];
    \\      var re = /<(\w+)(\s[^>]*)?>[\s\S]*?<\/\1>/gi;
    \\      var m;
    \\      while ((m = re.exec(src)) !== null) {
    \\        if (m[2] && m[2].indexOf(cls) >= 0) {
    \\          var attrs = {};
    \\          var ar = new RegExp('(\\w[\\w-]*)\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')', 'g');
    \\          var am;
    \\          while ((am = ar.exec(m[2])) !== null) attrs[am[1].toLowerCase()] = am[2] || am[3] || '';
    \\          all.push(new Element(m[1], attrs, ''));
    \\        }
    \\      }
    \\      return all;
    \\    }
    \\    // tag name
    \\    return findTags(src, selector);
    \\  }
    \\
    \\  // --- Extract <title> ---
    \\  var titleMatch = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html);
    \\  var pageTitle = titleMatch ? titleMatch[1].replace(/^\s+|\s+$/g, '') : '';
    \\
    \\  // --- Extract body text ---
    \\  var bodyMatch = /<body[^>]*>([\s\S]*?)<\/body>/i.exec(html);
    \\  var bodyHtml = bodyMatch ? bodyMatch[1] : html;
    \\  var bodyText = bodyHtml.replace(/<script[\s\S]*?<\/script>/gi, '').replace(/<style[\s\S]*?<\/style>/gi, '').replace(/<[^>]*>/g, '').replace(/\s+/g, ' ').replace(/^\s+|\s+$/g, '');
    \\
    \\  // --- document object ---
    \\  var bodyEl = new Element('body', {}, bodyHtml);
    \\  bodyEl.innerText = bodyText;
    \\  bodyEl.textContent = bodyText;
    \\
    \\  var headEl = new Element('head', {}, '');
    \\  var docEl = new Element('html', {}, html);
    \\
    \\  globalThis.document = {
    \\    title: pageTitle,
    \\    body: bodyEl,
    \\    head: headEl,
    \\    documentElement: docEl,
    \\    readyState: 'complete',
    \\    nodeType: 9,
    \\    contentType: 'text/html',
    \\    characterSet: 'UTF-8',
    \\    charset: 'UTF-8',
    \\    URL: (globalThis.window && globalThis.window.location) ? globalThis.window.location.href : '',
    \\    domain: (globalThis.window && globalThis.window.location) ? globalThis.window.location.hostname : '',
    \\    referrer: '',
    \\    cookie: '',
    \\    write: function(s) { globalThis.__browdie_output += String(s); },
    \\    writeln: function(s) { globalThis.__browdie_output += String(s) + '\n'; },
    \\    getElementById: function(id) { return findById(html, id); },
    \\    querySelector: function(sel) { var r = simpleQuery(html, sel); return r.length > 0 ? r[0] : null; },
    \\    querySelectorAll: function(sel) { return simpleQuery(html, sel); },
    \\    getElementsByTagName: function(tag) { return findTags(html, tag); },
    \\    getElementsByClassName: function(cls) { return simpleQuery(html, '.' + cls); },
    \\    getElementsByName: function() { return []; },
    \\    createElement: function(tag) { return new Element(tag, {}, ''); },
    \\    createTextNode: function(t) { return { nodeType: 3, textContent: String(t), data: String(t) }; },
    \\    createDocumentFragment: function() { return new Element('fragment', {}, ''); },
    \\    createComment: function() { return { nodeType: 8 }; },
    \\    addEventListener: function() {},
    \\    removeEventListener: function() {},
    \\    dispatchEvent: function() { return true; },
    \\    createEvent: function() { return { initEvent: function(){} }; },
    \\    implementation: { hasFeature: function() { return false; } }
    \\  };
    \\
    \\  // --- console ---
    \\  globalThis.console = globalThis.console || {
    \\    log: function() {},
    \\    warn: function() {},
    \\    error: function() {},
    \\    info: function() {},
    \\    debug: function() {},
    \\    dir: function() {},
    \\    trace: function() {},
    \\    assert: function() {},
    \\    time: function() {},
    \\    timeEnd: function() {},
    \\    group: function() {},
    \\    groupEnd: function() {},
    \\    table: function() {}
    \\  };
    \\
    \\  // --- navigator ---
    \\  globalThis.navigator = {
    \\    userAgent: 'kuri-fetch/0.1',
    \\    language: 'en-US',
    \\    languages: ['en-US', 'en'],
    \\    platform: 'kuri',
    \\    cookieEnabled: false,
    \\    onLine: true,
    \\    hardwareConcurrency: 1,
    \\    maxTouchPoints: 0,
    \\    vendor: '',
    \\    appName: 'kuri',
    \\    appVersion: '0.1',
    \\    product: 'Gecko',
    \\    productSub: '20030107',
    \\    sendBeacon: function() { return false; }
    \\  };
    \\
    \\  // Timer stubs (execute synchronously for SSR)
    \\  if (!globalThis.setTimeout) globalThis.setTimeout = function(fn) { if (typeof fn === 'function') fn(); return 0; };
    \\  if (!globalThis.setInterval) globalThis.setInterval = function() { return 0; };
    \\  if (!globalThis.clearTimeout) globalThis.clearTimeout = function() {};
    \\  if (!globalThis.clearInterval) globalThis.clearInterval = function() {};
    \\  if (!globalThis.requestAnimationFrame) globalThis.requestAnimationFrame = function(fn) { if (typeof fn === 'function') fn(0); return 0; };
    \\  if (!globalThis.cancelAnimationFrame) globalThis.cancelAnimationFrame = function() {};
    \\
    \\  // Alias window properties to globalThis
    \\  globalThis.self = globalThis.window || globalThis;
    \\  if (globalThis.window) {
    \\    globalThis.window.document = globalThis.document;
    \\    globalThis.window.navigator = globalThis.navigator;
    \\    globalThis.window.console = globalThis.console;
    \\    globalThis.window.self = globalThis.window;
    \\    globalThis.window.setTimeout = globalThis.setTimeout;
    \\    globalThis.window.setInterval = globalThis.setInterval;
    \\    globalThis.window.clearTimeout = globalThis.clearTimeout;
    \\    globalThis.window.clearInterval = globalThis.clearInterval;
    \\  }
    \\})();
;

const dom_runtime_enhancement_js =
    \\(function() {
    \\  var source = globalThis.__browdie_html || '';
    \\  var HTML_NS = 'http://www.w3.org/1999/xhtml';
    \\  var SVG_NS = 'http://www.w3.org/2000/svg';
    \\  var VOID_TAGS = { area:1, base:1, br:1, col:1, embed:1, hr:1, img:1, input:1, link:1, meta:1, param:1, source:1, track:1, wbr:1 };
    \\  var documentRef = null;
    \\  var existingWindow = globalThis.window || globalThis;
    \\  var windowRef = globalThis;
    \\
    \\  function lower(value) { return String(value || '').toLowerCase(); }
    \\  function splitUrlParts(raw) {
    \\    raw = String(raw || '');
    \\    var match = /^([A-Za-z][A-Za-z0-9+.-]*:)?(?:\/\/([^\/?#]*))?([^?#]*)(\?[^#]*)?(#.*)?$/.exec(raw) || [];
    \\    var protocol = match[1] || '';
    \\    var host = match[2] || '';
    \\    var pathname = match[3] || '/';
    \\    var search = match[4] || '';
    \\    var hash = match[5] || '';
    \\    if (!pathname) pathname = '/';
    \\    return { protocol: protocol, host: host, pathname: pathname, search: search, hash: hash };
    \\  }
    \\  function originFromHref(href) {
    \\    var parts = splitUrlParts(href);
    \\    return (parts.protocol && parts.host) ? parts.protocol + '//' + parts.host : '';
    \\  }
    \\  function normalizePath(pathname) {
    \\    var absolute = String(pathname || '/').charAt(0) === '/';
    \\    var parts = String(pathname || '/').split('/');
    \\    var out = [];
    \\    for (var i = 0; i < parts.length; i += 1) {
    \\      var part = parts[i];
    \\      if (!part || part === '.') continue;
    \\      if (part === '..') {
    \\        if (out.length) out.pop();
    \\      } else {
    \\        out.push(part);
    \\      }
    \\    }
    \\    return (absolute ? '/' : '') + out.join('/') || '/';
    \\  }
    \\  function resolveUrlInput(input, base) {
    \\    var raw = String(input || '');
    \\    var baseHref = String(base || (windowRef.location && windowRef.location.href) || '');
    \\    if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(raw)) return raw;
    \\    var baseNoHash = baseHref.split('#')[0];
    \\    var baseNoQuery = baseNoHash.split('?')[0];
    \\    var origin = originFromHref(baseHref);
    \\    if (raw.charAt(0) === '/') return origin + raw;
    \\    if (raw.charAt(0) === '#') return baseNoHash + raw;
    \\    if (raw.charAt(0) === '?') return baseNoQuery + raw;
    \\    var slash = baseNoQuery.lastIndexOf('/');
    \\    var dir = slash >= 0 ? baseNoQuery.slice(0, slash + 1) : baseNoQuery + '/';
    \\    return dir + raw;
    \\  }
    \\  function URLShim(input, base) {
    \\    if (!(this instanceof URLShim)) return new URLShim(input, base);
    \\    var href = resolveUrlInput(input, base);
    \\    var parts = splitUrlParts(href);
    \\    this.protocol = parts.protocol;
    \\    this.host = parts.host;
    \\    this.hostname = parts.host.split(':')[0] || '';
    \\    this.port = parts.host.indexOf(':') >= 0 ? parts.host.split(':').slice(1).join(':') : '';
    \\    this.pathname = normalizePath(parts.pathname || '/');
    \\    this.search = parts.search;
    \\    this.hash = parts.hash;
    \\    this.origin = this.protocol && this.host ? this.protocol + '//' + this.host : '';
    \\    this.href = this.origin + this.pathname + this.search + this.hash;
    \\  }
    \\  URLShim.prototype.toString = function() { return this.href; };
    \\  URLShim.prototype.toJSON = function() { return this.href; };
    \\  if (typeof globalThis.URL === 'undefined') {
    \\    globalThis.URL = URLShim;
    \\    windowRef.URL = URLShim;
    \\  }
    \\  if (globalThis.window && !globalThis.window.URL) globalThis.window.URL = globalThis.URL;
    \\
    \\  Object.keys(existingWindow).forEach(function(key) {
    \\    if (windowRef[key] === undefined) windowRef[key] = existingWindow[key];
    \\  });
    \\
    \\  function createStorage() {
    \\    var store = Object.create(null);
    \\    return {
    \\      key: function(index) {
    \\        var keys = Object.keys(store);
    \\        return index >= 0 && index < keys.length ? keys[index] : null;
    \\      },
    \\      getItem: function(key) {
    \\        key = String(key);
    \\        return Object.prototype.hasOwnProperty.call(store, key) ? store[key] : null;
    \\      },
    \\      setItem: function(key, value) {
    \\        store[String(key)] = String(value);
    \\      },
    \\      removeItem: function(key) {
    \\        delete store[String(key)];
    \\      },
    \\      clear: function() {
    \\        store = Object.create(null);
    \\      }
    \\    };
    \\  }
    \\
    \\  function EventTarget() {
    \\    this._listeners = Object.create(null);
    \\  }
    \\
    \\  EventTarget.prototype.addEventListener = function(type, listener) {
    \\    if (!listener) return;
    \\    type = String(type || '');
    \\    if (!this._listeners[type]) this._listeners[type] = [];
    \\    this._listeners[type].push(listener);
    \\  };
    \\
    \\  EventTarget.prototype.removeEventListener = function(type, listener) {
    \\    type = String(type || '');
    \\    var list = this._listeners[type];
    \\    if (!list || !list.length) return;
    \\    this._listeners[type] = list.filter(function(entry) { return entry !== listener; });
    \\  };
    \\
    \\  EventTarget.prototype.dispatchEvent = function(event) {
    \\    if (!event || !event.type) return true;
    \\    if (!event.target) event.target = this;
    \\    event.currentTarget = this;
    \\    var list = (this._listeners[event.type] || []).slice();
    \\    for (var i = 0; i < list.length; i += 1) {
    \\      var listener = list[i];
    \\      if (typeof listener === 'function') {
    \\        listener.call(this, event);
    \\      } else if (listener && typeof listener.handleEvent === 'function') {
    \\        listener.handleEvent(event);
    \\      }
    \\      if (event._stopImmediate) break;
    \\    }
    \\    if (!event._stopImmediate) {
    \\      var handler = this['on' + event.type];
    \\      if (typeof handler === 'function') handler.call(this, event);
    \\    }
    \\    if (event.bubbles && !event._stop && this.parentNode) {
    \\      this.parentNode.dispatchEvent(event);
    \\    }
    \\    return !event.defaultPrevented;
    \\  };
    \\
    \\  function BaseEvent(type, init) {
    \\    init = init || {};
    \\    this.type = String(type || '');
    \\    this.bubbles = !!init.bubbles;
    \\    this.cancelable = !!init.cancelable;
    \\    this.defaultPrevented = false;
    \\    this.target = null;
    \\    this.currentTarget = null;
    \\    this.detail = init.detail !== undefined ? init.detail : null;
    \\    this.keyCode = init.keyCode || 0;
    \\    this.which = init.which || this.keyCode || 0;
    \\    this.button = init.button || 0;
    \\  }
    \\
    \\  BaseEvent.prototype.preventDefault = function() {
    \\    if (this.cancelable) this.defaultPrevented = true;
    \\  };
    \\  BaseEvent.prototype.stopPropagation = function() { this._stop = true; };
    \\  BaseEvent.prototype.stopImmediatePropagation = function() { this._stop = true; this._stopImmediate = true; };
    \\  BaseEvent.prototype.initEvent = function(type, bubbles, cancelable) {
    \\    this.type = String(type || '');
    \\    this.bubbles = !!bubbles;
    \\    this.cancelable = !!cancelable;
    \\  };
    \\
    \\  function CustomEvent(type, init) { BaseEvent.call(this, type, init); }
    \\  CustomEvent.prototype = Object.create(BaseEvent.prototype);
    \\  CustomEvent.prototype.constructor = CustomEvent;
    \\
    \\  function MouseEvent(type, init) { BaseEvent.call(this, type, init); }
    \\  MouseEvent.prototype = Object.create(BaseEvent.prototype);
    \\  MouseEvent.prototype.constructor = MouseEvent;
    \\
    \\  function StyleDeclaration() { this._props = Object.create(null); }
    \\  StyleDeclaration.prototype.setProperty = function(name, value) { this._props[String(name)] = String(value); };
    \\  StyleDeclaration.prototype.getPropertyValue = function(name) { return this._props[String(name)] || ''; };
    \\  StyleDeclaration.prototype.removeProperty = function(name) {
    \\    name = String(name);
    \\    var previous = this._props[name] || '';
    \\    delete this._props[name];
    \\    return previous;
    \\  };
    \\  Object.defineProperty(StyleDeclaration.prototype, 'cssText', {
    \\    get: function() {
    \\      var keys = Object.keys(this._props);
    \\      return keys.map(function(key) { return key + ': ' + this._props[key]; }, this).join('; ');
    \\    },
    \\    set: function(value) {
    \\      this._props = Object.create(null);
    \\      String(value || '').split(';').forEach(function(part) {
    \\        var bits = part.split(':');
    \\        if (bits.length >= 2) this.setProperty(bits[0].trim(), bits.slice(1).join(':').trim());
    \\      }, this);
    \\    }
    \\  });
    \\
    \\  function Node(nodeType, nodeName, ownerDocument) {
    \\    EventTarget.call(this);
    \\    this.nodeType = nodeType;
    \\    this.nodeName = nodeName;
    \\    this.ownerDocument = ownerDocument || null;
    \\    this.parentNode = null;
    \\    this.childNodes = [];
    \\  }
    \\  Node.ELEMENT_NODE = 1;
    \\  Node.TEXT_NODE = 3;
    \\  Node.COMMENT_NODE = 8;
    \\  Node.DOCUMENT_NODE = 9;
    \\  Node.DOCUMENT_FRAGMENT_NODE = 11;
    \\  Node.prototype = Object.create(EventTarget.prototype);
    \\  Node.prototype.constructor = Node;
    \\
    \\  Object.defineProperty(Node.prototype, 'firstChild', { get: function() { return this.childNodes.length ? this.childNodes[0] : null; } });
    \\  Object.defineProperty(Node.prototype, 'lastChild', { get: function() { return this.childNodes.length ? this.childNodes[this.childNodes.length - 1] : null; } });
    \\  Object.defineProperty(Node.prototype, 'nextSibling', { get: function() {
    \\    if (!this.parentNode) return null;
    \\    var siblings = this.parentNode.childNodes;
    \\    var index = siblings.indexOf(this);
    \\    return index >= 0 && index + 1 < siblings.length ? siblings[index + 1] : null;
    \\  } });
    \\  Object.defineProperty(Node.prototype, 'previousSibling', { get: function() {
    \\    if (!this.parentNode) return null;
    \\    var siblings = this.parentNode.childNodes;
    \\    var index = siblings.indexOf(this);
    \\    return index > 0 ? siblings[index - 1] : null;
    \\  } });
    \\  Object.defineProperty(Node.prototype, 'parentElement', { get: function() {
    \\    return this.parentNode && this.parentNode.nodeType === Node.ELEMENT_NODE ? this.parentNode : null;
    \\  } });
    \\  Object.defineProperty(Node.prototype, 'textContent', {
    \\    get: function() {
    \\      if (this.nodeType === Node.TEXT_NODE || this.nodeType === Node.COMMENT_NODE) return this.data || '';
    \\      return this.childNodes.map(function(child) { return child.textContent || ''; }).join('');
    \\    },
    \\    set: function(value) {
    \\      if (this.nodeType === Node.TEXT_NODE || this.nodeType === Node.COMMENT_NODE) {
    \\        this.data = String(value || '');
    \\        return;
    \\      }
    \\      this.childNodes = [];
    \\      if (value !== null && value !== undefined && String(value).length > 0) {
    \\        this.appendChild((this.ownerDocument || documentRef).createTextNode(String(value)));
    \\      }
    \\    }
    \\  });
    \\  Object.defineProperty(Node.prototype, 'nodeValue', {
    \\    get: function() {
    \\      return (this.nodeType === Node.TEXT_NODE || this.nodeType === Node.COMMENT_NODE) ? (this.data || '') : null;
    \\    },
    \\    set: function(value) {
    \\      if (this.nodeType === Node.TEXT_NODE || this.nodeType === Node.COMMENT_NODE) this.data = String(value || '');
    \\    }
    \\  });
    \\
    \\  Node.prototype.appendChild = function(child) {
    \\    if (!child) return child;
    \\    if (child.nodeType === Node.DOCUMENT_FRAGMENT_NODE) {
    \\      while (child.firstChild) this.appendChild(child.firstChild);
    \\      return child;
    \\    }
    \\    if (child.parentNode) child.parentNode.removeChild(child);
    \\    child.parentNode = this;
    \\    child.ownerDocument = this.nodeType === Node.DOCUMENT_NODE ? this : (this.ownerDocument || child.ownerDocument);
    \\    this.childNodes.push(child);
    \\    return child;
    \\  };
    \\
    \\  Node.prototype.removeChild = function(child) {
    \\    var index = this.childNodes.indexOf(child);
    \\    if (index >= 0) {
    \\      this.childNodes.splice(index, 1);
    \\      child.parentNode = null;
    \\    }
    \\    return child;
    \\  };
    \\
    \\  Node.prototype.append = function() {
    \\    for (var i = 0; i < arguments.length; i += 1) {
    \\      var child = arguments[i];
    \\      if (typeof child === 'string') child = (this.ownerDocument || documentRef).createTextNode(child);
    \\      this.appendChild(child);
    \\    }
    \\  };
    \\
    \\  Node.prototype.prepend = function() {
    \\    for (var i = arguments.length - 1; i >= 0; i -= 1) {
    \\      var child = arguments[i];
    \\      if (typeof child === 'string') child = (this.ownerDocument || documentRef).createTextNode(child);
    \\      this.insertBefore(child, this.firstChild);
    \\    }
    \\  };
    \\
    \\  Node.prototype.remove = function() {
    \\    if (this.parentNode) this.parentNode.removeChild(this);
    \\  };
    \\
    \\  Node.prototype.insertBefore = function(child, reference) {
    \\    if (!reference) return this.appendChild(child);
    \\    if (child.nodeType === Node.DOCUMENT_FRAGMENT_NODE) {
    \\      var nodes = child.childNodes.slice();
    \\      for (var i = 0; i < nodes.length; i += 1) this.insertBefore(nodes[i], reference);
    \\      return child;
    \\    }
    \\    if (child.parentNode) child.parentNode.removeChild(child);
    \\    var index = this.childNodes.indexOf(reference);
    \\    if (index < 0) return this.appendChild(child);
    \\    child.parentNode = this;
    \\    child.ownerDocument = this.nodeType === Node.DOCUMENT_NODE ? this : (this.ownerDocument || child.ownerDocument);
    \\    this.childNodes.splice(index, 0, child);
    \\    return child;
    \\  };
    \\
    \\  Node.prototype.replaceChild = function(newChild, oldChild) {
    \\    this.insertBefore(newChild, oldChild);
    \\    this.removeChild(oldChild);
    \\    return oldChild;
    \\  };
    \\
    \\  Node.prototype.contains = function(node) {
    \\    while (node) {
    \\      if (node === this) return true;
    \\      node = node.parentNode;
    \\    }
    \\    return false;
    \\  };
    \\
    \\  Node.prototype.cloneNode = function(deep) {
    \\    var clone;
    \\    if (this.nodeType === Node.TEXT_NODE) clone = new TextNode(this.data, this.ownerDocument);
    \\    else if (this.nodeType === Node.COMMENT_NODE) clone = new CommentNode(this.data, this.ownerDocument);
    \\    else if (this.nodeType === Node.DOCUMENT_FRAGMENT_NODE) clone = new DocumentFragment(this.ownerDocument);
    \\    else if (this.nodeType === Node.ELEMENT_NODE) {
    \\      clone = new Element(this.localName || this.nodeName.toLowerCase(), this._attrs, this.ownerDocument);
    \\      clone.style.cssText = this.style.cssText;
    \\      clone.value = this.value;
    \\      clone.checked = !!this.checked;
    \\      clone.disabled = !!this.disabled;
    \\      clone.selected = !!this.selected;
    \\      clone.multiple = !!this.multiple;
    \\    } else {
    \\      clone = new Node(this.nodeType, this.nodeName, this.ownerDocument);
    \\    }
    \\    if (deep) {
    \\      for (var i = 0; i < this.childNodes.length; i += 1) clone.appendChild(this.childNodes[i].cloneNode(true));
    \\    }
    \\    return clone;
    \\  };
    \\
    \\  function TextNode(data, ownerDocument) {
    \\    Node.call(this, Node.TEXT_NODE, '#text', ownerDocument);
    \\    this.data = String(data || '');
    \\  }
    \\  TextNode.prototype = Object.create(Node.prototype);
    \\  TextNode.prototype.constructor = TextNode;
    \\
    \\  function CommentNode(data, ownerDocument) {
    \\    Node.call(this, Node.COMMENT_NODE, '#comment', ownerDocument);
    \\    this.data = String(data || '');
    \\  }
    \\  CommentNode.prototype = Object.create(Node.prototype);
    \\  CommentNode.prototype.constructor = CommentNode;
    \\
    \\  function DocumentFragment(ownerDocument) {
    \\    Node.call(this, Node.DOCUMENT_FRAGMENT_NODE, '#document-fragment', ownerDocument);
    \\  }
    \\  DocumentFragment.prototype = Object.create(Node.prototype);
    \\  DocumentFragment.prototype.constructor = DocumentFragment;
    \\
    \\  function Element(tagName, attrs, ownerDocument, namespaceURI) {
    \\    Node.call(this, Node.ELEMENT_NODE, String(tagName || 'div').toUpperCase(), ownerDocument);
    \\    this.tagName = this.nodeName;
    \\    this.localName = this.tagName.toLowerCase();
    \\    this.namespaceURI = namespaceURI || HTML_NS;
    \\    this._attrs = Object.create(null);
    \\    this.style = new StyleDeclaration();
    \\    this.value = '';
    \\    this.checked = false;
    \\    this.disabled = false;
    \\    this.selected = false;
    \\    this.multiple = false;
    \\    if (attrs) {
    \\      var keys = Object.keys(attrs);
    \\      for (var i = 0; i < keys.length; i += 1) this.setAttribute(keys[i], attrs[keys[i]]);
    \\    }
    \\  }
    \\  Element.prototype = Object.create(Node.prototype);
    \\  Element.prototype.constructor = Element;
    \\  Object.defineProperty(Element.prototype, 'id', {
    \\    get: function() { return this.getAttribute('id') || ''; },
    \\    set: function(value) { this._attrs.id = String(value); }
    \\  });
    \\  Object.defineProperty(Element.prototype, 'className', {
    \\    get: function() { return this.getAttribute('class') || ''; },
    \\    set: function(value) { this._attrs['class'] = String(value); }
    \\  });
    \\  Object.defineProperty(Element.prototype, 'children', {
    \\    get: function() { return this.childNodes.filter(function(node) { return node.nodeType === Node.ELEMENT_NODE; }); }
    \\  });
    \\  Object.defineProperty(Element.prototype, 'childElementCount', {
    \\    get: function() { return this.children.length; }
    \\  });
    \\  Object.defineProperty(Element.prototype, 'firstElementChild', {
    \\    get: function() { return this.children.length ? this.children[0] : null; }
    \\  });
    \\  Object.defineProperty(Element.prototype, 'lastElementChild', {
    \\    get: function() { return this.children.length ? this.children[this.children.length - 1] : null; }
    \\  });
    \\  Object.defineProperty(Element.prototype, 'nextElementSibling', {
    \\    get: function() {
    \\      var node = this.nextSibling;
    \\      while (node && node.nodeType !== Node.ELEMENT_NODE) node = node.nextSibling;
    \\      return node;
    \\    }
    \\  });
    \\  Object.defineProperty(Element.prototype, 'previousElementSibling', {
    \\    get: function() {
    \\      var node = this.previousSibling;
    \\      while (node && node.nodeType !== Node.ELEMENT_NODE) node = node.previousSibling;
    \\      return node;
    \\    }
    \\  });
    \\  Object.defineProperty(Element.prototype, 'innerHTML', {
    \\    get: function() { return this.childNodes.map(serializeNode).join(''); },
    \\    set: function(value) {
    \\      this.childNodes = [];
    \\      var fragment = parseFragment(String(value || ''), this.ownerDocument || documentRef);
    \\      while (fragment.firstChild) this.appendChild(fragment.firstChild);
    \\    }
    \\  });
    \\  Object.defineProperty(Element.prototype, 'outerHTML', {
    \\    get: function() { return serializeNode(this); }
    \\  });
    \\  Object.defineProperty(Element.prototype, 'innerText', {
    \\    get: function() { return this.textContent; },
    \\    set: function(value) { this.textContent = value; }
    \\  });
    \\  Object.defineProperty(Element.prototype, 'dataset', {
    \\    get: function() {
    \\      var data = Object.create(null);
    \\      var keys = Object.keys(this._attrs);
    \\      for (var i = 0; i < keys.length; i += 1) {
    \\        var key = keys[i];
    \\        if (key.indexOf('data-') === 0) data[key.slice(5).replace(/-([a-z])/g, function(_, ch) { return ch.toUpperCase(); })] = this._attrs[key];
    \\      }
    \\      return data;
    \\    }
    \\  });
    \\  Object.defineProperty(Element.prototype, 'classList', {
    \\    get: function() {
    \\      var element = this;
    \\      function classes() { return String(element.getAttribute('class') || '').split(/\s+/).filter(Boolean); }
    \\      return {
    \\        add: function() {
    \\          var list = classes();
    \\          for (var i = 0; i < arguments.length; i += 1) if (list.indexOf(arguments[i]) < 0) list.push(arguments[i]);
    \\          element.setAttribute('class', list.join(' '));
    \\        },
    \\        remove: function() {
    \\          var list = classes();
    \\          for (var i = 0; i < arguments.length; i += 1) list = list.filter(function(name) { return name !== arguments[i]; }, arguments);
    \\          element.setAttribute('class', list.join(' '));
    \\        },
    \\        contains: function(name) { return classes().indexOf(String(name)) >= 0; },
    \\        toggle: function(name, force) {
    \\          var exists = this.contains(name);
    \\          if (force === true || (!exists && force !== false)) { this.add(name); return true; }
    \\          this.remove(name); return false;
    \\        },
    \\        item: function(index) { var list = classes(); return index >= 0 && index < list.length ? list[index] : null; },
    \\        get length() { return classes().length; },
    \\        toString: function() { return element.getAttribute('class') || ''; }
    \\      };
    \\    }
    \\  });
    \\
    \\  Element.prototype.getAttribute = function(name) {
    \\    name = lower(name);
    \\    return Object.prototype.hasOwnProperty.call(this._attrs, name) ? this._attrs[name] : null;
    \\  };
    \\  Element.prototype.setAttribute = function(name, value) {
    \\    name = lower(name);
    \\    value = String(value);
    \\    this._attrs[name] = value;
    \\    if (name === 'id') this.id = value;
    \\    if (name === 'class') this.className = value;
    \\    if (name === 'value') this.value = value;
    \\    if (name === 'style') this.style.cssText = value;
    \\    if (name === 'checked') this.checked = true;
    \\    if (name === 'disabled') this.disabled = true;
    \\    if (name === 'selected') this.selected = true;
    \\    if (name === 'multiple') this.multiple = true;
    \\  };
    \\  Element.prototype.setAttributeNS = function(_, name, value) { this.setAttribute(name, value); };
    \\  Element.prototype.removeAttribute = function(name) {
    \\    name = lower(name);
    \\    delete this._attrs[name];
    \\    if (name === 'checked') this.checked = false;
    \\    if (name === 'disabled') this.disabled = false;
    \\    if (name === 'selected') this.selected = false;
    \\    if (name === 'multiple') this.multiple = false;
    \\  };
    \\  Element.prototype.removeAttributeNS = function(_, name) { this.removeAttribute(name); };
    \\  Element.prototype.hasAttribute = function(name) { return Object.prototype.hasOwnProperty.call(this._attrs, lower(name)); };
    \\  Element.prototype.getElementsByTagName = function(selector) { return queryAll(this, String(selector || '*')); };
    \\  Element.prototype.getElementsByClassName = function(className) { return queryAll(this, '.' + String(className || '')); };
    \\  Element.prototype.querySelector = function(selector) {
    \\    var result = queryAll(this, selector);
    \\    return result.length ? result[0] : null;
    \\  };
    \\  Element.prototype.querySelectorAll = function(selector) { return queryAll(this, selector); };
    \\  Element.prototype.matches = function(selector) { return matchesSelector(this, selector); };
    \\  Element.prototype.closest = function(selector) {
    \\    var node = this;
    \\    while (node && node.nodeType === Node.ELEMENT_NODE) {
    \\      if (matchesSelector(node, selector)) return node;
    \\      node = node.parentElement;
    \\    }
    \\    return null;
    \\  };
    \\  Element.prototype.getBoundingClientRect = function() { return { top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 }; };
    \\  Element.prototype.focus = function() { if (documentRef) documentRef.activeElement = this; };
    \\  Element.prototype.blur = function() { if (documentRef && documentRef.activeElement === this) documentRef.activeElement = documentRef.body || null; };
    \\  Element.prototype.click = function() { this.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true })); };
    \\
    \\  function Document() {
    \\    Node.call(this, Node.DOCUMENT_NODE, '#document', null);
    \\    this.ownerDocument = this;
    \\    this.documentElement = null;
    \\    this.body = null;
    \\    this.head = null;
    \\    this.readyState = 'complete';
    \\    this.contentType = 'text/html';
    \\    this.characterSet = 'UTF-8';
    \\    this.charset = 'UTF-8';
    \\    this.referrer = '';
    \\    this.activeElement = null;
    \\    this.defaultView = windowRef;
    \\    this.implementation = { hasFeature: function() { return false; } };
    \\    this.location = windowRef.location;
    \\  }
    \\  Document.prototype = Object.create(Node.prototype);
    \\  Document.prototype.constructor = Document;
    \\  Document.prototype.createElement = function(tagName) { return new Element(tagName, {}, this); };
    \\  Document.prototype.createElementNS = function(namespaceURI, tagName) { return new Element(tagName, {}, this, namespaceURI || SVG_NS); };
    \\  Document.prototype.createTextNode = function(text) { return new TextNode(text, this); };
    \\  Document.prototype.createComment = function(text) { return new CommentNode(text, this); };
    \\  Document.prototype.createDocumentFragment = function() { return new DocumentFragment(this); };
    \\  Document.prototype.createEvent = function() { return new BaseEvent(''); };
    \\  Document.prototype.getElementById = function(id) {
    \\    var result = queryAll(this, '#' + String(id || ''));
    \\    return result.length ? result[0] : null;
    \\  };
    \\  Document.prototype.getElementsByTagName = function(selector) { return queryAll(this, String(selector || '*')); };
    \\  Document.prototype.getElementsByClassName = function(className) { return queryAll(this, '.' + String(className || '')); };
    \\  Document.prototype.querySelector = function(selector) {
    \\    var result = queryAll(this, selector);
    \\    return result.length ? result[0] : null;
    \\  };
    \\  Document.prototype.querySelectorAll = function(selector) { return queryAll(this, selector); };
    \\  Document.prototype.write = function(markup) {
    \\    markup = String(markup || '');
    \\    globalThis.__browdie_output += markup;
    \\    var target = this.body || this.documentElement || this;
    \\    var fragment = parseFragment(markup, this);
    \\    while (fragment.firstChild) target.appendChild(fragment.firstChild);
    \\  };
    \\  Document.prototype.writeln = function(markup) { this.write(String(markup || '') + '\n'); };
    \\  Document.prototype.open = function() { if (this.body) this.body.childNodes = []; globalThis.__browdie_output = ''; };
    \\  Document.prototype.close = function() {};
    \\  Object.defineProperty(Document.prototype, 'title', {
    \\    get: function() {
    \\      var titleNode = this.querySelector('title');
    \\      return titleNode ? titleNode.textContent : '';
    \\    },
    \\    set: function(value) {
    \\      value = String(value || '');
    \\      var titleNode = this.querySelector('title');
    \\      if (!titleNode) {
    \\        if (!this.head) {
    \\          this.head = this.createElement('head');
    \\          if (this.documentElement) this.documentElement.insertBefore(this.head, this.documentElement.firstChild);
    \\        }
    \\        titleNode = this.createElement('title');
    \\        this.head.appendChild(titleNode);
    \\      }
    \\      titleNode.textContent = value;
    \\    }
    \\  });
    \\
    \\  function serializeAttrs(node) {
    \\    var keys = Object.keys(node._attrs || {});
    \\    if (!keys.length) return '';
    \\    return keys.map(function(key) { return ' ' + key + '="' + String(node._attrs[key]).replace(/"/g, '&quot;') + '"'; }).join('');
    \\  }
    \\
    \\  function serializeNode(node) {
    \\    if (!node) return '';
    \\    if (node.nodeType === Node.TEXT_NODE) return String(node.data || '');
    \\    if (node.nodeType === Node.COMMENT_NODE) return '<!--' + String(node.data || '') + '-->';
    \\    if (node.nodeType === Node.DOCUMENT_FRAGMENT_NODE || node.nodeType === Node.DOCUMENT_NODE) {
    \\      return node.childNodes.map(serializeNode).join('');
    \\    }
    \\    var tag = node.localName || node.nodeName.toLowerCase();
    \\    var open = '<' + tag + serializeAttrs(node) + '>';
    \\    if (VOID_TAGS[tag]) return open;
    \\    return open + node.childNodes.map(serializeNode).join('') + '</' + tag + '>';
    \\  }
    \\
    \\  function parseAttributes(attrSource) {
    \\    var attrs = Object.create(null);
    \\    if (!attrSource) return attrs;
    \\    var attrRegex = /([A-Za-z_:][A-Za-z0-9_:\-\.]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
    \\    var match;
    \\    while ((match = attrRegex.exec(attrSource)) !== null) {
    \\      attrs[lower(match[1])] = match[2] || match[3] || match[4] || '';
    \\    }
    \\    return attrs;
    \\  }
    \\
    \\  function parseFragment(markup, ownerDocument) {
    \\    var fragment = new DocumentFragment(ownerDocument);
    \\    var stack = [fragment];
    \\    var i = 0;
    \\    while (i < markup.length) {
    \\      if (markup.slice(i, i + 4) === '<!--') {
    \\        var commentEnd = markup.indexOf('-->', i + 4);
    \\        if (commentEnd < 0) break;
    \\        stack[stack.length - 1].appendChild(new CommentNode(markup.slice(i + 4, commentEnd), ownerDocument));
    \\        i = commentEnd + 3;
    \\        continue;
    \\      }
    \\      if (markup.slice(i, i + 2) === '</') {
    \\        var closeEnd = markup.indexOf('>', i + 2);
    \\        if (closeEnd < 0) break;
    \\        var closingTag = lower(markup.slice(i + 2, closeEnd).trim().split(/\s+/)[0]);
    \\        while (stack.length > 1) {
    \\          var candidate = stack.pop();
    \\          if (candidate.localName === closingTag) break;
    \\        }
    \\        i = closeEnd + 1;
    \\        continue;
    \\      }
    \\      if (markup.charAt(i) === '<' && (markup.charAt(i + 1) === '!' || markup.charAt(i + 1) === '?')) {
    \\        var directiveEnd = markup.indexOf('>', i + 2);
    \\        if (directiveEnd < 0) break;
    \\        i = directiveEnd + 1;
    \\        continue;
    \\      }
    \\      if (markup.charAt(i) === '<') {
    \\        var openMatch = /^<([A-Za-z][A-Za-z0-9:_-]*)([\s\S]*?)>/.exec(markup.slice(i));
    \\        if (openMatch) {
    \\          var fullTag = openMatch[0];
    \\          var tagName = lower(openMatch[1]);
    \\          var attrSource = openMatch[2] || '';
    \\          var selfClosing = /\/\s*>$/.test(fullTag) || !!VOID_TAGS[tagName];
    \\          var element = new Element(tagName, parseAttributes(attrSource), ownerDocument, tagName === 'svg' ? SVG_NS : HTML_NS);
    \\          stack[stack.length - 1].appendChild(element);
    \\          i += fullTag.length;
    \\          if (!selfClosing) {
    \\            if (tagName === 'script' || tagName === 'style') {
    \\              var closeToken = '</' + tagName + '>';
    \\              var lowerMarkup = markup.toLowerCase();
    \\              var closeIndex = lowerMarkup.indexOf(closeToken, i);
    \\              var rawText = closeIndex >= 0 ? markup.slice(i, closeIndex) : markup.slice(i);
    \\              if (rawText.length) element.appendChild(new TextNode(rawText, ownerDocument));
    \\              i = closeIndex >= 0 ? closeIndex + closeToken.length : markup.length;
    \\            } else {
    \\              stack.push(element);
    \\            }
    \\          }
    \\          continue;
    \\        }
    \\      }
    \\      var nextTag = markup.indexOf('<', i);
    \\      var text = markup.slice(i, nextTag >= 0 ? nextTag : markup.length);
    \\      if (text.length) stack[stack.length - 1].appendChild(new TextNode(text, ownerDocument));
    \\      if (nextTag < 0) break;
    \\      if (nextTag === i) {
    \\        stack[stack.length - 1].appendChild(new TextNode('<', ownerDocument));
    \\        i += 1;
    \\        continue;
    \\      }
    \\      i = nextTag;
    \\    }
    \\    return fragment;
    \\  }
    \\
    \\  function traverse(root, visit) {
    \\    var nodes = root.childNodes ? root.childNodes.slice().reverse() : [];
    \\    while (nodes.length) {
    \\      var node = nodes.pop();
    \\      visit(node);
    \\      if (node.childNodes && node.childNodes.length) {
    \\        for (var i = node.childNodes.length - 1; i >= 0; i -= 1) nodes.push(node.childNodes[i]);
    \\      }
    \\    }
    \\  }
    \\
    \\  function splitSelectorGroups(selector) {
    \\    var groups = [];
    \\    var current = '';
    \\    var bracketDepth = 0;
    \\    var quote = '';
    \\    for (var i = 0; i < selector.length; i += 1) {
    \\      var ch = selector.charAt(i);
    \\      if (quote) {
    \\        current += ch;
    \\        if (ch === quote) quote = '';
    \\        continue;
    \\      }
    \\      if (ch === '"' || ch === '\'') { quote = ch; current += ch; continue; }
    \\      if (ch === '[') { bracketDepth += 1; current += ch; continue; }
    \\      if (ch === ']') { bracketDepth = Math.max(0, bracketDepth - 1); current += ch; continue; }
    \\      if (ch === ',' && bracketDepth === 0) {
    \\        if (current.trim()) groups.push(current.trim());
    \\        current = '';
    \\        continue;
    \\      }
    \\      current += ch;
    \\    }
    \\    if (current.trim()) groups.push(current.trim());
    \\    return groups;
    \\  }
    \\
    \\  function parseSimpleSelector(part) {
    \\    var selector = { tag: null, id: null, classes: [], attrs: [] };
    \\    var i = 0;
    \\    var tagMatch = /^[A-Za-z*][A-Za-z0-9:_-]*/.exec(part);
    \\    if (tagMatch) {
    \\      selector.tag = lower(tagMatch[0]);
    \\      i = tagMatch[0].length;
    \\    }
    \\    while (i < part.length) {
    \\      var ch = part.charAt(i);
    \\      if (ch === '#') {
    \\        var idMatch = /^#([A-Za-z0-9:_-]+)/.exec(part.slice(i));
    \\        if (idMatch) { selector.id = idMatch[1]; i += idMatch[0].length; continue; }
    \\      }
    \\      if (ch === '.') {
    \\        var classMatch = /^\.([A-Za-z0-9:_-]+)/.exec(part.slice(i));
    \\        if (classMatch) { selector.classes.push(classMatch[1]); i += classMatch[0].length; continue; }
    \\      }
    \\      if (ch === '[') {
    \\        var end = part.indexOf(']', i);
    \\        if (end < 0) break;
    \\        var body = part.slice(i + 1, end);
    \\        var attrMatch = /^([^\s=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|(.+)))?$/.exec(body.trim());
    \\        if (attrMatch) selector.attrs.push({ name: lower(attrMatch[1]), value: attrMatch[2] || attrMatch[3] || (attrMatch[4] ? attrMatch[4].trim() : null) });
    \\        i = end + 1;
    \\        continue;
    \\      }
    \\      i += 1;
    \\    }
    \\    return selector;
    \\  }
    \\
    \\  function parseSelectorChain(selector) {
    \\    var parts = [];
    \\    var current = '';
    \\    var bracketDepth = 0;
    \\    var quote = '';
    \\    var combinator = null;
    \\    for (var i = 0; i < selector.length; i += 1) {
    \\      var ch = selector.charAt(i);
    \\      if (quote) {
    \\        current += ch;
    \\        if (ch === quote) quote = '';
    \\        continue;
    \\      }
    \\      if (ch === '"' || ch === '\'') { quote = ch; current += ch; continue; }
    \\      if (ch === '[') { bracketDepth += 1; current += ch; continue; }
    \\      if (ch === ']') { bracketDepth = Math.max(0, bracketDepth - 1); current += ch; continue; }
    \\      if (bracketDepth === 0 && (ch === '>' || /\s/.test(ch))) {
    \\        if (current.trim()) {
    \\          parts.push({ selector: parseSimpleSelector(current.trim()), combinator: combinator });
    \\          current = '';
    \\          combinator = null;
    \\        }
    \\        if (ch === '>') combinator = '>';
    \\        else if (!combinator) combinator = ' ';
    \\        continue;
    \\      }
    \\      current += ch;
    \\    }
    \\    if (current.trim()) parts.push({ selector: parseSimpleSelector(current.trim()), combinator: combinator });
    \\    if (parts.length) parts[0].combinator = null;
    \\    return parts;
    \\  }
    \\
    \\  function matchesSimple(node, selector) {
    \\    if (!node || node.nodeType !== Node.ELEMENT_NODE) return false;
    \\    if (selector.tag && selector.tag !== '*' && node.localName !== selector.tag) return false;
    \\    if (selector.id && node.getAttribute('id') !== selector.id) return false;
    \\    for (var i = 0; i < selector.classes.length; i += 1) {
    \\      if (!node.classList.contains(selector.classes[i])) return false;
    \\    }
    \\    for (var j = 0; j < selector.attrs.length; j += 1) {
    \\      var attr = selector.attrs[j];
    \\      if (!node.hasAttribute(attr.name)) return false;
    \\      if (attr.value !== null && node.getAttribute(attr.name) !== attr.value) return false;
    \\    }
    \\    return true;
    \\  }
    \\
    \\  function matchesChain(node, parts, index) {
    \\    if (!matchesSimple(node, parts[index].selector)) return false;
    \\    if (index === 0) return true;
    \\    var combinator = parts[index].combinator || ' ';
    \\    if (combinator === '>') {
    \\      var parent = node.parentElement;
    \\      return !!parent && matchesChain(parent, parts, index - 1);
    \\    }
    \\    var current = node.parentElement;
    \\    while (current) {
    \\      if (matchesChain(current, parts, index - 1)) return true;
    \\      current = current.parentElement;
    \\    }
    \\    return false;
    \\  }
    \\
    \\  function queryAll(root, selector) {
    \\    selector = String(selector || '').trim();
    \\    if (!selector) return [];
    \\    var groups = splitSelectorGroups(selector).map(parseSelectorChain);
    \\    var results = [];
    \\    function maybeAdd(node) {
    \\      if (!node || node.nodeType !== Node.ELEMENT_NODE) return;
    \\      for (var i = 0; i < groups.length; i += 1) {
    \\        if (groups[i].length && matchesChain(node, groups[i], groups[i].length - 1)) {
    \\          if (results.indexOf(node) < 0) results.push(node);
    \\          return;
    \\        }
    \\      }
    \\    }
    \\    if (root.nodeType === Node.ELEMENT_NODE) maybeAdd(root);
    \\    traverse(root.nodeType === Node.DOCUMENT_NODE ? root : root, maybeAdd);
    \\    return results;
    \\  }
    \\
    \\  function matchesSelector(node, selector) {
    \\    selector = String(selector || '').trim();
    \\    if (!selector || !node || node.nodeType !== Node.ELEMENT_NODE) return false;
    \\    var groups = splitSelectorGroups(selector);
    \\    for (var i = 0; i < groups.length; i += 1) {
    \\      var chain = parseSelectorChain(groups[i]);
    \\      if (chain.length && matchesChain(node, chain, chain.length - 1)) return true;
    \\    }
    \\    return false;
    \\  }
    \\
    \\  function initializeDocument(doc) {
    \\    var htmlNode = null;
    \\    var headNode = null;
    \\    var bodyNode = null;
    \\    traverse(doc, function(node) {
    \\      if (node.nodeType !== Node.ELEMENT_NODE) return;
    \\      if (!htmlNode && node.localName === 'html') htmlNode = node;
    \\      if (!headNode && node.localName === 'head') headNode = node;
    \\      if (!bodyNode && node.localName === 'body') bodyNode = node;
    \\    });
    \\    if (!htmlNode) {
    \\      htmlNode = doc.createElement('html');
    \\      while (doc.firstChild) htmlNode.appendChild(doc.firstChild);
    \\      doc.appendChild(htmlNode);
    \\    }
    \\    if (!headNode) {
    \\      headNode = doc.createElement('head');
    \\      htmlNode.insertBefore(headNode, htmlNode.firstChild);
    \\    }
    \\    if (!bodyNode) {
    \\      bodyNode = doc.createElement('body');
    \\      htmlNode.appendChild(bodyNode);
    \\    }
    \\    doc.documentElement = htmlNode;
    \\    doc.head = headNode;
    \\    doc.body = bodyNode;
    \\    doc.activeElement = bodyNode;
    \\    doc.URL = windowRef.location ? windowRef.location.href : '';
    \\    doc.domain = windowRef.location ? windowRef.location.hostname : '';
    \\    doc.location = windowRef.location;
    \\    return doc;
    \\  }
    \\
    \\  function parseDocument(markup) {
    \\    var doc = new Document();
    \\    var fragment = parseFragment(markup, doc);
    \\    while (fragment.firstChild) doc.appendChild(fragment.firstChild);
    \\    return initializeDocument(doc);
    \\  }
    \\
    \\  function updateLocationParts(href) {
    \\    href = String(href || '');
    \\    var index = href.indexOf('://');
    \\    var protocol = index >= 0 ? href.slice(0, index + 1) : '';
    \\    var rest = index >= 0 ? href.slice(index + 3) : href;
    \\    var slash = rest.indexOf('/');
    \\    var host = slash >= 0 ? rest.slice(0, slash) : rest;
    \\    var path = slash >= 0 ? rest.slice(slash) : '/';
    \\    var hashIndex = path.indexOf('#');
    \\    var hash = hashIndex >= 0 ? path.slice(hashIndex) : '';
    \\    var beforeHash = hashIndex >= 0 ? path.slice(0, hashIndex) : path;
    \\    var searchIndex = beforeHash.indexOf('?');
    \\    var search = searchIndex >= 0 ? beforeHash.slice(searchIndex) : '';
    \\    var pathname = searchIndex >= 0 ? beforeHash.slice(0, searchIndex) : beforeHash;
    \\    var hostBits = host.split(':');
    \\    var hostname = hostBits[0] || '';
    \\    var port = hostBits.length > 1 ? hostBits.slice(1).join(':') : '';
    \\    windowRef.location.href = href;
    \\    windowRef.location.protocol = protocol;
    \\    windowRef.location.host = host;
    \\    windowRef.location.hostname = hostname;
    \\    windowRef.location.port = port;
    \\    windowRef.location.pathname = pathname || '/';
    \\    windowRef.location.search = search;
    \\    windowRef.location.hash = hash;
    \\    windowRef.location.origin = protocol ? protocol + '//' + host : '';
    \\    if (documentRef) {
    \\      documentRef.URL = href;
    \\      documentRef.domain = hostname;
    \\      documentRef.location = windowRef.location;
    \\    }
    \\  }
    \\
    \\  function navigateTo(nextHref, replace) {
    \\    var previousHash = windowRef.location.hash || '';
    \\    updateLocationParts(nextHref);
    \\    if ((windowRef.location.hash || '') !== previousHash) windowRef.dispatchEvent(new BaseEvent('hashchange'));
    \\    windowRef.dispatchEvent(new BaseEvent('popstate'));
    \\    if (replace) windowRef.history.state = windowRef.history.state || {};
    \\  }
    \\
    \\  if (!(windowRef instanceof EventTarget)) {
    \\    windowRef._listeners = Object.create(null);
    \\    windowRef.addEventListener = EventTarget.prototype.addEventListener;
    \\    windowRef.removeEventListener = EventTarget.prototype.removeEventListener;
    \\    windowRef.dispatchEvent = EventTarget.prototype.dispatchEvent;
    \\  }
    \\  windowRef.onhashchange = windowRef.onhashchange || null;
    \\  windowRef.onpopstate = windowRef.onpopstate || null;
    \\  windowRef.localStorage = windowRef.localStorage || createStorage();
    \\  windowRef.sessionStorage = windowRef.sessionStorage || createStorage();
    \\  windowRef.history = windowRef.history || {};
    \\  windowRef.history.state = windowRef.history.state || null;
    \\  windowRef.history.pushState = function(state, _, href) {
    \\    this.state = state;
    \\    if (href !== undefined && href !== null) navigateTo(String(href), false);
    \\  };
    \\  windowRef.history.replaceState = function(state, _, href) {
    \\    this.state = state;
    \\    if (href !== undefined && href !== null) navigateTo(String(href), true);
    \\  };
    \\  windowRef.history.back = function() {};
    \\  windowRef.history.forward = function() {};
    \\  windowRef.history.go = function() {};
    \\  windowRef.location.assign = function(href) { navigateTo(String(href), false); };
    \\  windowRef.location.replace = function(href) { navigateTo(String(href), true); };
    \\  windowRef.location.reload = function() {};
    \\  windowRef.location.toString = function() { return this.href || ''; };
    \\  updateLocationParts(windowRef.location && windowRef.location.href ? windowRef.location.href : '');
    \\
    \\  documentRef = parseDocument(source);
    \\  documentRef.defaultView = windowRef;
    \\  documentRef.referrer = '';
    \\  documentRef.implementation = { hasFeature: function() { return false; } };
    \\  documentRef.location = windowRef.location;
    \\  windowRef.document = documentRef;
    \\  windowRef.self = windowRef;
    \\  windowRef.window = windowRef;
    \\  windowRef.Node = Node;
    \\  windowRef.Element = Element;
    \\  windowRef.HTMLElement = Element;
    \\  windowRef.HTMLDocument = Document;
    \\  windowRef.Document = Document;
    \\  windowRef.DocumentFragment = DocumentFragment;
    \\  windowRef.Text = TextNode;
    \\  windowRef.Comment = CommentNode;
    \\  windowRef.NodeList = Array;
    \\  windowRef.HTMLCollection = Array;
    \\  windowRef.HTMLHtmlElement = Element;
    \\  windowRef.HTMLHeadElement = Element;
    \\  windowRef.HTMLBodyElement = Element;
    \\  windowRef.HTMLAnchorElement = Element;
    \\  windowRef.HTMLButtonElement = Element;
    \\  windowRef.HTMLFormElement = Element;
    \\  windowRef.HTMLIFrameElement = Element;
    \\  windowRef.HTMLImageElement = Element;
    \\  windowRef.HTMLInputElement = Element;
    \\  windowRef.HTMLLabelElement = Element;
    \\  windowRef.HTMLLinkElement = Element;
    \\  windowRef.HTMLMetaElement = Element;
    \\  windowRef.HTMLOptionElement = Element;
    \\  windowRef.HTMLScriptElement = Element;
    \\  windowRef.HTMLSelectElement = Element;
    \\  windowRef.HTMLSpanElement = Element;
    \\  windowRef.HTMLStyleElement = Element;
    \\  windowRef.HTMLTextAreaElement = Element;
    \\  windowRef.HTMLTitleElement = Element;
    \\  windowRef.SVGElement = Element;
    \\  windowRef.Event = BaseEvent;
    \\  windowRef.CustomEvent = CustomEvent;
    \\  windowRef.MouseEvent = MouseEvent;
    \\  windowRef.MutationObserver = windowRef.MutationObserver || function() { this.observe = function() {}; this.disconnect = function() {}; this.takeRecords = function() { return []; }; };
    \\  windowRef.getComputedStyle = function(node) { return node && node.style ? node.style : new StyleDeclaration(); };
    \\  windowRef.matchMedia = windowRef.matchMedia || function(query) { return { media: String(query || ''), matches: false, onchange: null, addListener: function() {}, removeListener: function() {}, addEventListener: function() {}, removeEventListener: function() {}, dispatchEvent: function() { return true; } }; };
    \\  windowRef.requestAnimationFrame = windowRef.requestAnimationFrame || function(fn) { if (typeof fn === 'function') fn(0); return 0; };
    \\  windowRef.cancelAnimationFrame = windowRef.cancelAnimationFrame || function() {};
    \\  globalThis.window = windowRef;
    \\  globalThis.self = windowRef;
    \\  globalThis.document = documentRef;
    \\  globalThis.Node = Node;
    \\  globalThis.Element = Element;
    \\  globalThis.HTMLElement = Element;
    \\  globalThis.HTMLDocument = Document;
    \\  globalThis.Document = Document;
    \\  globalThis.DocumentFragment = DocumentFragment;
    \\  globalThis.Text = TextNode;
    \\  globalThis.Comment = CommentNode;
    \\  globalThis.NodeList = Array;
    \\  globalThis.HTMLCollection = Array;
    \\  globalThis.HTMLHtmlElement = Element;
    \\  globalThis.HTMLHeadElement = Element;
    \\  globalThis.HTMLBodyElement = Element;
    \\  globalThis.HTMLAnchorElement = Element;
    \\  globalThis.HTMLButtonElement = Element;
    \\  globalThis.HTMLFormElement = Element;
    \\  globalThis.HTMLIFrameElement = Element;
    \\  globalThis.HTMLImageElement = Element;
    \\  globalThis.HTMLInputElement = Element;
    \\  globalThis.HTMLLabelElement = Element;
    \\  globalThis.HTMLLinkElement = Element;
    \\  globalThis.HTMLMetaElement = Element;
    \\  globalThis.HTMLOptionElement = Element;
    \\  globalThis.HTMLScriptElement = Element;
    \\  globalThis.HTMLSelectElement = Element;
    \\  globalThis.HTMLSpanElement = Element;
    \\  globalThis.HTMLStyleElement = Element;
    \\  globalThis.HTMLTextAreaElement = Element;
    \\  globalThis.HTMLTitleElement = Element;
    \\  globalThis.SVGElement = Element;
    \\  globalThis.Event = BaseEvent;
    \\  globalThis.CustomEvent = CustomEvent;
    \\  globalThis.MouseEvent = MouseEvent;
    \\  globalThis.localStorage = windowRef.localStorage;
    \\  globalThis.sessionStorage = windowRef.sessionStorage;
    \\  globalThis.history = windowRef.history;
    \\  globalThis.location = windowRef.location;
    \\})();
;

// --- Tests ---

test "extractInlineScripts finds script bodies" {
    const html = "<html><script>var x = 1;</script><p>text</p><script>var y = 2;</script></html>";
    const scripts = try extractInlineScripts(html, std.testing.allocator);
    defer std.testing.allocator.free(scripts);
    try std.testing.expectEqual(@as(usize, 2), scripts.len);
    try std.testing.expectEqualStrings("var x = 1;", scripts[0]);
    try std.testing.expectEqualStrings("var y = 2;", scripts[1]);
}

test "extractInlineScripts skips external scripts" {
    const html = "<script src=\"app.js\"></script><script>var x = 1;</script>";
    const scripts = try extractInlineScripts(html, std.testing.allocator);
    defer std.testing.allocator.free(scripts);
    try std.testing.expectEqual(@as(usize, 1), scripts.len);
    try std.testing.expectEqualStrings("var x = 1;", scripts[0]);
}

test "extractInlineScripts empty HTML" {
    const scripts = try extractInlineScripts("<p>no scripts</p>", std.testing.allocator);
    defer std.testing.allocator.free(scripts);
    try std.testing.expectEqual(@as(usize, 0), scripts.len);
}

test "JsEngine evalAlloc arithmetic" {
    var engine = try JsEngine.init();
    defer engine.deinit();

    const result = engine.evalAlloc(std.testing.allocator, "'hello ' + 'world'");
    defer if (result) |r| std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("hello world", result.?);
}

test "JsEngine evalAlloc number to string" {
    var engine = try JsEngine.init();
    defer engine.deinit();

    const result = engine.evalAlloc(std.testing.allocator, "String(40 + 2)");
    defer if (result) |r| std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("42", result.?);
}

test "JsEngine evalAlloc syntax error returns null" {
    var engine = try JsEngine.init();
    defer engine.deinit();

    const result = engine.evalAlloc(std.testing.allocator, "this is not valid js {{{{");
    try std.testing.expect(result == null);
}

test "JsEngine document.write capture" {
    var engine = try JsEngine.init();
    defer engine.deinit();

    _ = engine.exec("var __browdie_output = '';");
    _ = engine.exec("var document = {};");
    _ = engine.exec("document.write = function(s) { __browdie_output += String(s); };");
    _ = engine.exec("document.write('hello');");
    const result = engine.evalAlloc(std.testing.allocator, "__browdie_output");
    defer if (result) |r| std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("hello", result.?);
}

test "evalHtmlScripts simple var" {
    // Test with simplest possible script — no document.write dependency
    const html = "<script>globalThis.__browdie_output = 'direct';</script>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("direct", output.?);
}

test "evalHtmlScripts runs inline scripts" {
    const html = "<html><script>document.write('hello');</script></html>";

    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    // QuickJS should execute document.write and capture output
    try std.testing.expect(output != null);
    try std.testing.expect(output.?.len > 0);
    try std.testing.expectEqualStrings("hello", output.?);
}

test "evalHtmlScripts arithmetic" {
    const html = "<script>document.write(String(40 + 2));</script>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("42", output.?);
}

test "evalHtmlScripts no scripts returns null" {
    const output = try evalHtmlScripts("<p>plain</p>", std.testing.allocator);
    try std.testing.expect(output == null);
}

// --- Layer 3 DOM stub tests ---

test "DOM stubs: document.title" {
    const html = "<html><head><title>My Page</title></head><body><script>document.write(document.title);</script></body></html>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("My Page", output.?);
}

test "DOM stubs: document.getElementById" {
    const html = "<div id=\"main\">content</div><script>var el = document.getElementById('main'); document.write(el ? el.tagName : 'null');</script>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("DIV", output.?);
}

test "DOM stubs: document.getElementById returns null for missing" {
    const html = "<script>var el = document.getElementById('nope'); document.write(String(el));</script>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("null", output.?);
}

test "DOM stubs: document.querySelector by tag" {
    const html = "<p>hello</p><p>world</p><script>var el = document.querySelector('p'); document.write(el ? el.textContent : 'null');</script>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("hello", output.?);
}

test "DOM stubs: document.querySelectorAll by tag" {
    const html = "<p>a</p><p>b</p><script>document.write(String(document.querySelectorAll('p').length));</script>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("2", output.?);
}

test "DOM stubs: parses doctype and dynamic descendant selectors" {
    const html =
        "<!doctype html><html><body><script>" ++
        "var root = document.createElement('div');" ++
        "root.setAttribute('id', 'mount');" ++
        "root.innerHTML = '<span class=\"x\">hi</span>';" ++
        "document.body.appendChild(root);" ++
        "document.write(String(document.querySelectorAll('#mount .x').length));" ++
        "</script></body></html>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("1", output.?);
}

test "DOM stubs: id and className properties reflect selector attributes" {
    const html =
        "<html><body><script>" ++
        "var root = document.createElement('div');" ++
        "root.id = 'mount';" ++
        "var child = document.createElement('span');" ++
        "child.className = 'x';" ++
        "root.appendChild(child);" ++
        "document.body.appendChild(root);" ++
        "document.write(String(document.querySelectorAll('#mount .x').length));" ++
        "</script></body></html>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("1", output.?);
}

test "DOM stubs: append and remove mutate child lists" {
    const html =
        "<html><body><script>" ++
        "var root = document.createElement('div');" ++
        "var node = document.createElement('div');" ++
        "document.body.append(root);" ++
        "root.append(node);" ++
        "node.append('hello');" ++
        "var before = root.textContent;" ++
        "node.remove();" ++
        "document.write(before + '|' + root.textContent);" ++
        "</script></body></html>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("hello|", output.?);
}

test "DOM stubs: document.querySelector by id selector" {
    const html = "<span id=\"x\">found</span><script>var el = document.querySelector('#x'); document.write(el ? el.textContent : 'null');</script>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("found", output.?);
}

test "DOM stubs: document.getElementsByTagName" {
    const html = "<a href=\"/a\">A</a><a href=\"/b\">B</a><script>document.write(String(document.getElementsByTagName('a').length));</script>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("2", output.?);
}

test "DOM stubs: Element.getAttribute" {
    const html = "<a href=\"https://example.com\" id=\"link\">Ex</a><script>var el = document.getElementById('link'); document.write(el.getAttribute('href'));</script>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("https://example.com", output.?);
}

test "DOM stubs: document.body.innerText" {
    const html = "<html><body><p>Hello World</p><script>document.write(document.body.innerText);</script></body></html>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    // Body text should contain "Hello World" (stripped of tags)
    try std.testing.expect(std.mem.indexOf(u8, output.?, "Hello World") != null);
}

test "DOM stubs: window.location with URL" {
    const html = "<script>document.write(window.location.hostname);</script>";
    const output = try evalHtmlScriptsWithUrl(html, "https://example.com/path?q=1#frag", std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("example.com", output.?);
}

test "DOM stubs: window.location.pathname" {
    const html = "<script>document.write(window.location.pathname);</script>";
    const output = try evalHtmlScriptsWithUrl(html, "https://example.com/foo/bar", std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("/foo/bar", output.?);
}

test "DOM stubs: window.location.search and hash" {
    const html = "<script>document.write(window.location.search + '|' + window.location.hash);</script>";
    const output = try evalHtmlScriptsWithUrl(html, "https://example.com/p?q=1&r=2#sec", std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("?q=1&r=2|#sec", output.?);
}

test "DOM stubs: URL constructor resolves relative paths" {
    const html = "<script>var u = new URL('../next?q=1#s', window.location.href); document.write(u.pathname + '|' + u.search + '|' + u.hash);</script>";
    const output = try evalHtmlScriptsWithUrl(html, "https://example.com/a/b/c", std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("/a/next|?q=1|#s", output.?);
}

test "DOM stubs: matchMedia exposes media query list shape" {
    const html = "<script>var m = window.matchMedia('(prefers-color-scheme: dark)'); document.write(String(m.matches) + '|' + m.media);</script>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("false|(prefers-color-scheme: dark)", output.?);
}

test "DOM stubs: console.log does not crash" {
    const html = "<script>console.log('test'); console.warn('w'); console.error('e'); document.write('ok');</script>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("ok", output.?);
}

test "DOM stubs: navigator properties" {
    const html = "<script>document.write(navigator.userAgent);</script>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("kuri-fetch/0.1", output.?);
}

test "DOM stubs: document.createElement" {
    const html = "<script>var el = document.createElement('div'); el.setAttribute('id', 'new'); document.write(el.tagName + ':' + el.getAttribute('id'));</script>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("DIV:new", output.?);
}

test "DOM stubs: window properties resolve as globals" {
    const html = "<script>window.answer = 7; document.write(String(answer) + '|' + String(window.answer));</script>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("7|7", output.?);
}

test "DOM stubs: document.readyState" {
    const html = "<script>document.write(document.readyState);</script>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("complete", output.?);
}

test "DOM stubs: setTimeout executes synchronously" {
    const html = "<script>var x = ''; setTimeout(function() { x = 'fired'; }, 0); document.write(x);</script>";
    const output = try evalHtmlScripts(html, std.testing.allocator);
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("fired", output.?);
}

test "DOM stubs: direct shim check" {
    var engine = try JsEngine.init();
    defer engine.deinit();

    _ = engine.exec("globalThis.__browdie_output = '';");
    _ = engine.exec("globalThis.__browdie_html = '<title>Hi</title>';");
    _ = engine.exec("globalThis.window = { location: { href: '', protocol: '', host: '', pathname: '/', search: '', hash: '', hostname: '', port: '', origin: '', toString: function() { return ''; } } };");

    const ok = engine.exec(dom_shim_js);
    try std.testing.expect(ok);

    const title = engine.evalAlloc(std.testing.allocator, "document.title");
    defer if (title) |t| std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("Hi", title.?);

    // Now test document.write flow
    _ = engine.exec("document.write(document.title);");
    const output = engine.evalAlloc(std.testing.allocator, "globalThis.__browdie_output");
    defer if (output) |o| std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("Hi", output.?);
}

test "escapeForJs handles special characters" {
    const result = escapeForJs("hello \"world\"\nnew\\line", std.testing.allocator);
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\nnew\\\\line", result.?);
}
