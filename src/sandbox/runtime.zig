// runtime.zig — sandboxed JS runtime for bundle replay
//
// Wraps QuickJS with a Web API shim (shim.js) and native bridges for fetch,
// crypto, time, and cookie jar access. Designed to run captured anti-bot /
// signed-URL / HMAC bundles outside of Chrome at ~50ms cold start.
//
// Lifecycle:
//   var sb = try Sandbox.init(allocator, .{ .fingerprint = fp, .target_origin = "..." });
//   defer sb.deinit();
//   try sb.installShim();
//   try sb.evalBundle(bundle_js);
//   const cookies = try sb.getCookies(allocator);
//
// All outbound HTTP from the sandbox goes through network.zig (curl-impersonate).
// All set-cookie responses flow into the shared CookieJar.

const std = @import("std");
const quickjs = @import("quickjs");
const network = @import("network.zig");
const fingerprint_mod = @import("fingerprint.zig");
const compat = @import("../compat.zig");

pub const Fingerprint = fingerprint_mod.Fingerprint;

pub const shim_source = @embedFile("shim.js");

pub const SandboxOptions = struct {
    fingerprint: Fingerprint,
    target_origin: []const u8,
    target_href: ?[]const u8 = null,
    referrer: []const u8 = "",
    /// Maximum wall-clock the bundle is allowed to run, in ms.
    timeout_ms: u32 = 5_000,
    /// Maximum cumulative outbound bytes (defense against runaway bundle).
    max_egress_bytes: usize = 4 * 1024 * 1024,
    /// curl-impersonate target profile ("chrome116", "chrome131", etc.).
    impersonate_profile: []const u8 = "chrome131",
};

/// One observed network call from a sandbox bundle. Surfaced in the response
/// so Node-side can feed through extractEndpoints + publish to marketplace.
pub const RouteRecord = struct {
    url: []u8,
    method: []u8,
    status: u16,
    final_url: []u8,
    content_type: []u8,
    body_excerpt: []u8, // first 4KB of body for extractEndpoints
    body_size: usize,
    redirected: bool,
};

pub const SandboxError = error{
    RuntimeInitFailed,
    ContextInitFailed,
    ShimEvalFailed,
    BundleEvalFailed,
    JsonStringifyFailed,
    Timeout,
    EgressLimitExceeded,
    OutOfMemory,
};

/// Per-sandbox state, attached to the JS Context via setOpaque so native
/// bridges can locate it from inside the C callback.
pub const Sandbox = struct {
    allocator: std.mem.Allocator,
    rt: *quickjs.Runtime,
    ctx: *quickjs.Context,
    options: SandboxOptions,
    network: *network.Client,
    cookie_jar: *network.CookieJar,
    egress_bytes: usize = 0,
    start_ms: i64 = 0,
    /// Every __nativeFetch call appends here so the handler can return a
    /// `routes_observed` list. Caller (Node side) feeds these through
    /// extractEndpoints + publishes to the marketplace — turns every
    /// authenticated agent fetch into flywheel input.
    routes_observed: std.ArrayList(RouteRecord),

    pub fn init(allocator: std.mem.Allocator, options: SandboxOptions) SandboxError!*Sandbox {
        const rt = quickjs.Runtime.init() catch return SandboxError.RuntimeInitFailed;
        const ctx = quickjs.Context.init(rt) catch {
            rt.deinit();
            return SandboxError.ContextInitFailed;
        };

        const net = try allocator.create(network.Client);
        errdefer allocator.destroy(net);
        net.* = network.Client.init(allocator, .{
            .impersonate_profile = options.impersonate_profile,
            .target_origin = options.target_origin,
        });

        const jar = try allocator.create(network.CookieJar);
        errdefer allocator.destroy(jar);
        jar.* = network.CookieJar.init(allocator);

        const self = try allocator.create(Sandbox);
        self.* = .{
            .allocator = allocator,
            .rt = rt,
            .ctx = ctx,
            .options = options,
            .network = net,
            .cookie_jar = jar,
            .start_ms = compat.milliTimestamp(),
            .routes_observed = .empty,
        };

        // Attach self to the context so native callbacks can find it.
        ctx.setOpaque(Sandbox, self);
        return self;
    }

    pub fn deinit(self: *Sandbox) void {
        self.ctx.deinit();
        self.rt.deinit();
        self.cookie_jar.deinit();
        self.network.deinit();
        for (self.routes_observed.items) |r| {
            self.allocator.free(r.url);
            self.allocator.free(r.method);
            self.allocator.free(r.final_url);
            self.allocator.free(r.content_type);
            self.allocator.free(r.body_excerpt);
        }
        self.routes_observed.deinit(self.allocator);
        self.allocator.destroy(self.cookie_jar);
        self.allocator.destroy(self.network);
        const a = self.allocator;
        a.destroy(self);
    }

    /// Build the `__fingerprint` global (as a JSON-deserialised JS object),
    /// register native bridges, then evaluate shim.js.
    pub fn installShim(self: *Sandbox) SandboxError!void {
        const global = self.ctx.getGlobalObject();
        defer global.deinit(self.ctx);

        // 1. Register native bridges (attached BEFORE shim.js so it can wire them up).
        try self.bindNative(global, "__nativeFetch",       jsNativeFetch,       4);
        try self.bindNative(global, "__nativeNowMs",       jsNativeNowMs,       0);
        try self.bindNative(global, "__nativeRandomBytes", jsNativeRandomBytes, 1);
        try self.bindNative(global, "__nativeSubtleDigest",jsNativeSubtleDigest,2);
        try self.bindNative(global, "__cookieJarGet",      jsCookieJarGet,      1);
        try self.bindNative(global, "__cookieJarSet",      jsCookieJarSet,      2);

        // 2. Build the __fingerprint object via JSON eval (cheaper than walking
        //    the entire struct field-by-field through the C API). Merge in
        //    target_origin / target_href / referrer from SandboxOptions so the
        //    shim's location.* gets the right URL.
        var fp_with_target = self.options.fingerprint;
        if (fp_with_target.target_origin.len == 0) fp_with_target.target_origin = self.options.target_origin;
        if (fp_with_target.target_href.len == 0) fp_with_target.target_href = self.options.target_href orelse self.options.target_origin;
        if (fp_with_target.referrer.len == 0) fp_with_target.referrer = self.options.referrer;
        const fp_json = try fp_with_target.serialize(self.allocator);
        defer self.allocator.free(fp_json);

        const fp_setter = try std.fmt.allocPrintSentinel(
            self.allocator,
            "globalThis.__fingerprint = {s};",
            .{fp_json},
            0,
        );
        defer self.allocator.free(fp_setter);

        const fp_result = self.ctx.eval(fp_setter, "<fingerprint>", .{});
        if (fp_result.isException()) {
            self.dumpException("fingerprint setter");
            fp_result.deinit(self.ctx);
            return SandboxError.ShimEvalFailed;
        }
        fp_result.deinit(self.ctx);

        // 3. Evaluate shim.js.
        const shim_result = self.ctx.eval(shim_source, "<shim.js>", .{});
        if (shim_result.isException()) {
            self.dumpException("shim.js");
            shim_result.deinit(self.ctx);
            return SandboxError.ShimEvalFailed;
        }
        shim_result.deinit(self.ctx);
    }

    pub fn evalBundle(self: *Sandbox, source: []const u8, source_name: [:0]const u8) SandboxError!void {
        if (compat.milliTimestamp() - self.start_ms > self.options.timeout_ms) {
            return SandboxError.Timeout;
        }
        // QuickJS-NG's parser may read one byte past input.len for numeric
        // literal lookahead. Copy to a 0-terminated buffer so the trailing
        // read is always defined (zero byte cleanly ends any token).
        const buf = self.allocator.allocSentinel(u8, source.len, 0) catch return SandboxError.OutOfMemory;
        defer self.allocator.free(buf);
        @memcpy(buf, source);
        const result = self.ctx.eval(buf, source_name, .{});
        defer result.deinit(self.ctx);
        if (result.isException()) {
            self.dumpException(source_name);
            return SandboxError.BundleEvalFailed;
        }
    }

    pub fn evalJson(self: *Sandbox, expression: []const u8) SandboxError![]u8 {
        // Wrap the expression so its result becomes a JSON string.
        const wrapped = try std.fmt.allocPrintSentinel(
            self.allocator,
            "JSON.stringify(({s}))",
            .{expression},
            0,
        );
        defer self.allocator.free(wrapped);

        const result = self.ctx.eval(wrapped, "<eval-json>", .{});
        if (result.isException()) {
            self.dumpException("eval-json");
            result.deinit(self.ctx);
            return SandboxError.JsonStringifyFailed;
        }
        defer result.deinit(self.ctx);

        const str = result.toCString(self.ctx) orelse return SandboxError.JsonStringifyFailed;
        defer self.ctx.freeCString(str);
        return self.allocator.dupe(u8, std.mem.span(str));
    }

    pub fn getCookies(self: *Sandbox, allocator: std.mem.Allocator) ![]network.Cookie {
        return self.cookie_jar.snapshot(allocator);
    }

    fn bindNative(
        self: *Sandbox,
        global: quickjs.Value,
        comptime name: [:0]const u8,
        comptime func: quickjs.cfunc.Func,
        length: i32,
    ) !void {
        const fn_val = quickjs.Value.initCFunction(self.ctx, func, name, length);
        global.setPropertyStr(self.ctx, name.ptr, fn_val) catch return SandboxError.ShimEvalFailed;
    }

    fn dumpException(self: *Sandbox, where: []const u8) void {
        const ex = self.ctx.getException();
        defer ex.deinit(self.ctx);
        if (ex.toCString(self.ctx)) |msg| {
            defer self.ctx.freeCString(msg);
            std.log.warn("[sandbox] exception in {s}: {s}", .{ where, std.mem.span(msg) });
        } else {
            std.log.warn("[sandbox] unreadable exception in {s}", .{where});
        }
    }
};

// ───────────────────────────────────────────────────────────────────────────
// Native bridges (C-callable). All retrieve their Sandbox via ctx.getOpaque.
// ───────────────────────────────────────────────────────────────────────────

fn sandboxFromCtx(ctx_opt: ?*quickjs.Context) ?*Sandbox {
    const ctx = ctx_opt orelse return null;
    return ctx.getOpaque(Sandbox);
}

fn throwTypeError(ctx: *quickjs.Context, comptime msg: []const u8) quickjs.Value {
    const err = quickjs.Value.initError(ctx);
    err.setPropertyStr(ctx, "message", quickjs.Value.initStringLen(ctx, msg)) catch {};
    return err.throw(ctx);
}


fn appendRouteRecord(sb: *Sandbox, method: []const u8, url: []const u8, response: *network.Response) !void {
    const a = sb.allocator;

    // Find the content-type header (case-insensitive).
    var content_type: []const u8 = "";
    for (response.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
            content_type = h.value;
            break;
        }
    }

    // Sample first 4KB of body — enough for extractEndpoints to detect
    // JSON shapes / API patterns without bloating the response.
    const body_bytes = response.body;
    const sample_len = @min(body_bytes.len, 4096);

    const record: RouteRecord = .{
        .url = try a.dupe(u8, url),
        .method = try a.dupe(u8, method),
        .status = response.status,
        .final_url = try a.dupe(u8, response.final_url),
        .content_type = try a.dupe(u8, content_type),
        .body_excerpt = try a.dupe(u8, body_bytes[0..sample_len]),
        .body_size = body_bytes.len,
        .redirected = response.redirected,
    };
    try sb.routes_observed.append(a, record);
}
/// __nativeFetch(method: string, url: string, headers: object, body: string|null)
///   -> { status, statusText, url, headers, body }
fn jsNativeFetch(ctx_opt: ?*quickjs.Context, _: quickjs.Value, args: []const quickjs.c.JSValue) quickjs.Value {
    const ctx = ctx_opt orelse return quickjs.Value.@"undefined";
    const sb = sandboxFromCtx(ctx) orelse return quickjs.Value.@"undefined";

    if (args.len < 2) {
        return throwTypeError(ctx, "__nativeFetch requires (method, url, headers, body)");
    }

    const method_v: quickjs.Value = @bitCast(args[0]);
    const url_v: quickjs.Value = @bitCast(args[1]);
    const headers_v: quickjs.Value = if (args.len > 2) @bitCast(args[2]) else quickjs.Value.@"undefined";
    const body_v: quickjs.Value = if (args.len > 3) @bitCast(args[3]) else quickjs.Value.@"null";

    const method_cstr = method_v.toCString(ctx) orelse return throwTypeError(ctx, "method must be a string");
    defer ctx.freeCString(method_cstr);
    const url_cstr = url_v.toCString(ctx) orelse return throwTypeError(ctx, "url must be a string");
    defer ctx.freeCString(url_cstr);

    const method = std.mem.span(method_cstr);
    const url = std.mem.span(url_cstr);

    // Headers as a plain object: walk known keys via JS_GetOwnPropertyNames in
    // network.zig once we wire that up. For Phase 1, we accept an
    // already-flattened header object via JSON.stringify in the shim path.
    var headers_buf = std.ArrayList(u8).empty;
    defer headers_buf.deinit(sb.allocator);

    if (!headers_v.isUndefined() and !headers_v.isNull()) {
        // Stringify headers via JSON for consumption by network.zig's parser.
        // (cheap + avoids reimplementing property iteration here).
        const stringify_args = [_]quickjs.Value{headers_v};
        const json_global = ctx.getGlobalObject();
        defer json_global.deinit(ctx);
        const json_obj = json_global.getPropertyStr(ctx, "JSON");
        defer json_obj.deinit(ctx);
        const stringify_fn = json_obj.getPropertyStr(ctx, "stringify");
        defer stringify_fn.deinit(ctx);
        const json_str_v = stringify_fn.call(ctx, json_obj, &stringify_args);
        defer json_str_v.deinit(ctx);
        if (!json_str_v.isException()) {
            if (json_str_v.toCString(ctx)) |jstr| {
                defer ctx.freeCString(jstr);
                headers_buf.appendSlice(sb.allocator, std.mem.span(jstr)) catch {};
            }
        }
    }

    var body_bytes: ?[]const u8 = null;
    var body_owned: ?[*:0]const u8 = null;
    if (!body_v.isNull() and !body_v.isUndefined()) {
        if (body_v.toCString(ctx)) |bp| {
            body_owned = bp;
            body_bytes = std.mem.span(bp);
        }
    }
    defer if (body_owned) |bp| ctx.freeCString(bp);

    // Egress accounting.
    const out_estimate = url.len + headers_buf.items.len + (if (body_bytes) |bb| bb.len else 0);
    sb.egress_bytes += out_estimate;
    if (sb.egress_bytes > sb.options.max_egress_bytes) {
        return throwTypeError(ctx, "egress limit exceeded");
    }

    var response = sb.network.send(.{
        .method = method,
        .url = url,
        .headers_json = headers_buf.items,
        .body = body_bytes,
        .cookie_jar = sb.cookie_jar,
    }) catch |e| {
        std.log.warn("[sandbox] network.send failed: {s}", .{@errorName(e)});
        return throwTypeError(ctx, "network error");
    };
    defer response.deinit();

    // Append RouteRecord for the marketplace flywheel. Best-effort: alloc
    // failures here just skip the record (the user-visible call still succeeds).
    appendRouteRecord(sb, method, url, &response) catch {};

    // Build the JS response object.
    const obj = quickjs.Value.initObject(ctx);
    obj.setPropertyStr(ctx, "status", quickjs.Value.initInt32(@intCast(response.status))) catch {};
    obj.setPropertyStr(ctx, "statusText", quickjs.Value.initStringLen(ctx, response.status_text)) catch {};
    obj.setPropertyStr(ctx, "url", quickjs.Value.initStringLen(ctx, response.final_url)) catch {};
    obj.setPropertyStr(ctx, "redirected", quickjs.Value.initBool(response.redirected)) catch {};
    obj.setPropertyStr(ctx, "body", quickjs.Value.initStringLen(ctx, response.body)) catch {};

    // Headers as a plain object {name: value}.
    const hdrs_obj = quickjs.Value.initObject(ctx);
    for (response.headers) |h| {
        const name_z = std.mem.Allocator.dupeZ(sb.allocator, u8, h.name) catch continue;
        defer sb.allocator.free(name_z);
        hdrs_obj.setPropertyStr(ctx, name_z.ptr, quickjs.Value.initStringLen(ctx, h.value)) catch {};
    }
    obj.setPropertyStr(ctx, "headers", hdrs_obj) catch {};
    return obj;
}

fn jsNativeNowMs(_: ?*quickjs.Context, _: quickjs.Value, _: []const quickjs.c.JSValue) quickjs.Value {
    const ms: f64 = @floatFromInt(compat.milliTimestamp());
    return quickjs.Value.initFloat64(ms);
}

fn jsNativeRandomBytes(ctx_opt: ?*quickjs.Context, _: quickjs.Value, args: []const quickjs.c.JSValue) quickjs.Value {
    const ctx = ctx_opt orelse return quickjs.Value.@"undefined";
    if (args.len < 1) return throwTypeError(ctx, "expected length");
    const n_v: quickjs.Value = @bitCast(args[0]);
    const n: u32 = blk: {
        if (n_v.isNumber()) {
            break :blk @intFromFloat(n_v.toFloat64(ctx) catch @as(f64, 0));
        }
        break :blk 0;
    };
    if (n == 0 or n > 65_536) return throwTypeError(ctx, "bad random length");
    const sb = sandboxFromCtx(ctx) orelse return throwTypeError(ctx, "no sandbox");
    const buf = sb.allocator.alloc(u8, n) catch return throwTypeError(ctx, "oom");
    defer sb.allocator.free(buf);
    compat.randomBytes(buf);
    return quickjs.Value.initUint8ArrayCopy(ctx, buf);
}

fn jsNativeSubtleDigest(ctx_opt: ?*quickjs.Context, _: quickjs.Value, args: []const quickjs.c.JSValue) quickjs.Value {
    const ctx = ctx_opt orelse return quickjs.Value.@"undefined";
    if (args.len < 2) return throwTypeError(ctx, "expected (alg, data)");
    const alg_v: quickjs.Value = @bitCast(args[0]);
    const data_v: quickjs.Value = @bitCast(args[1]);
    const alg_cstr = alg_v.toCString(ctx) orelse return throwTypeError(ctx, "alg must be string");
    defer ctx.freeCString(alg_cstr);
    const alg = std.mem.span(alg_cstr);

    const data = data_v.getUint8Array(ctx) orelse return throwTypeError(ctx, "data must be Uint8Array");

    if (std.mem.eql(u8, alg, "SHA256") or std.mem.eql(u8, alg, "SHA-256")) {
        var out: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
        return quickjs.Value.initUint8ArrayCopy(ctx, &out);
    }
    if (std.mem.eql(u8, alg, "SHA1") or std.mem.eql(u8, alg, "SHA-1")) {
        var out: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(data, &out, .{});
        return quickjs.Value.initUint8ArrayCopy(ctx, &out);
    }
    if (std.mem.eql(u8, alg, "SHA512") or std.mem.eql(u8, alg, "SHA-512")) {
        var out: [64]u8 = undefined;
        std.crypto.hash.sha2.Sha512.hash(data, &out, .{});
        return quickjs.Value.initUint8ArrayCopy(ctx, &out);
    }
    return throwTypeError(ctx, "unsupported digest algorithm");
}

fn jsCookieJarGet(ctx_opt: ?*quickjs.Context, _: quickjs.Value, args: []const quickjs.c.JSValue) quickjs.Value {
    const ctx = ctx_opt orelse return quickjs.Value.@"undefined";
    if (args.len < 1) return quickjs.Value.initStringLen(ctx, "");
    const sb = sandboxFromCtx(ctx) orelse return quickjs.Value.initStringLen(ctx, "");
    const host_v: quickjs.Value = @bitCast(args[0]);
    const host_cstr = host_v.toCString(ctx) orelse return quickjs.Value.initStringLen(ctx, "");
    defer ctx.freeCString(host_cstr);
    const host = std.mem.span(host_cstr);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(sb.allocator);
    sb.cookie_jar.formatHeaderValue(sb.allocator, host, &buf) catch return quickjs.Value.initStringLen(ctx, "");
    return quickjs.Value.initStringLen(ctx, buf.items);
}

fn jsCookieJarSet(ctx_opt: ?*quickjs.Context, _: quickjs.Value, args: []const quickjs.c.JSValue) quickjs.Value {
    const ctx = ctx_opt orelse return quickjs.Value.@"undefined";
    if (args.len < 2) return quickjs.Value.@"undefined";
    const sb = sandboxFromCtx(ctx) orelse return quickjs.Value.@"undefined";
    const host_v: quickjs.Value = @bitCast(args[0]);
    const cookie_v: quickjs.Value = @bitCast(args[1]);
    const host_cstr = host_v.toCString(ctx) orelse return quickjs.Value.@"undefined";
    defer ctx.freeCString(host_cstr);
    const cookie_cstr = cookie_v.toCString(ctx) orelse return quickjs.Value.@"undefined";
    defer ctx.freeCString(cookie_cstr);

    sb.cookie_jar.applySetCookie(std.mem.span(host_cstr), std.mem.span(cookie_cstr)) catch {};
    return quickjs.Value.@"undefined";
}

test "sandbox init + shim install" {
    const allocator = std.testing.allocator;
    const fp = Fingerprint.builtinChromeMacARM();
    const sb = try Sandbox.init(allocator, .{
        .fingerprint = fp,
        .target_origin = "https://example.com",
        .target_href = "https://example.com/",
    });
    defer sb.deinit();
    try sb.installShim();

    // Read back navigator.userAgent through evalJson.
    const ua = try sb.evalJson("navigator.userAgent");
    defer allocator.free(ua);
    try std.testing.expect(std.mem.indexOf(u8, ua, "Mozilla") != null);
}
