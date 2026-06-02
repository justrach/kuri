const std = @import("std");
const testing = std.testing;
const c = @import("quickjs_c");
const Atom = @import("atom.zig").Atom;
const Context = @import("context.zig").Context;
const Runtime = @import("runtime.zig").Runtime;
const Value = @import("value.zig").Value;

/// Wrapper for the QuickJS `JSModuleDef`.
///
/// A module definition represents a JavaScript module created from native code.
/// Use `init` to create a new C module, then add exports before the module is
/// instantiated.
///
/// C: `JSModuleDef`
pub const ModuleDef = opaque {
    /// Module initialization function type.
    ///
    /// Called when the module is instantiated. Use this to set module exports.
    /// Return true on success, false on error.
    ///
    /// C: `JSModuleInitFunc`
    pub const InitFunc = *const fn (*Context, *ModuleDef) bool;

    /// Creates a new C module with the given name.
    ///
    /// The `func` is called when the module is instantiated and should set
    /// the module exports using `setExport`.
    ///
    /// Returns null on allocation failure.
    ///
    /// C: `JS_NewCModule`
    pub fn init(ctx: *Context, name: [:0]const u8, comptime func: InitFunc) ?*ModuleDef {
        const Wrapper = struct {
            fn callback(inner_ctx: *Context, m: *ModuleDef) callconv(.c) c_int {
                return @intFromBool(!@call(.always_inline, func, .{ inner_ctx, m }));
            }
        };
        return @ptrCast(c.JS_NewCModule(ctx.cval(), name.ptr, @ptrCast(&Wrapper.callback)));
    }

    /// Declares an export for this module.
    ///
    /// Must be called before the module is instantiated. The actual value
    /// is set later with `setExport` in the init function.
    ///
    /// Returns true on success.
    ///
    /// C: `JS_AddModuleExport`
    pub fn addExport(self: *ModuleDef, ctx: *Context, name: [:0]const u8) bool {
        return c.JS_AddModuleExport(ctx.cval(), @ptrCast(self), name.ptr) == 0;
    }

    /// Sets the value of a module export.
    ///
    /// Must be called after the module is instantiated, typically in the
    /// init function. The value's ownership is transferred to the module.
    ///
    /// Returns true on success.
    ///
    /// C: `JS_SetModuleExport`
    pub fn setExport(self: *ModuleDef, ctx: *Context, name: [:0]const u8, val: Value) bool {
        return c.JS_SetModuleExport(ctx.cval(), @ptrCast(self), name.ptr, val.cval()) == 0;
    }

    /// Gets the import.meta object for this module.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_GetImportMeta`
    pub fn getImportMeta(self: *ModuleDef, ctx: *Context) Value {
        return Value.fromCVal(c.JS_GetImportMeta(ctx.cval(), @ptrCast(self)));
    }

    /// Gets the module name as an atom.
    ///
    /// The returned atom must be freed with `Atom.deinit`.
    ///
    /// C: `JS_GetModuleName`
    pub fn getName(self: *ModuleDef, ctx: *Context) Atom {
        return @enumFromInt(c.JS_GetModuleName(ctx.cval(), @ptrCast(self)));
    }

    /// Gets the module namespace object.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_GetModuleNamespace`
    pub fn getNamespace(self: *ModuleDef, ctx: *Context) Value {
        return Value.fromCVal(c.JS_GetModuleNamespace(ctx.cval(), @ptrCast(self)));
    }

    pub inline fn cval(self: *ModuleDef) *c.JSModuleDef {
        return @ptrCast(self);
    }
};

// =============================================================================
// Tests
// =============================================================================

fn testModuleInit(ctx: *Context, m: *ModuleDef) bool {
    if (!m.setExport(ctx, "value", Value.initInt32(42))) return false;
    if (!m.setExport(ctx, "greeting", Value.initString(ctx, "hello"))) return false;
    return true;
}

test "ModuleDef init and addExport" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const m = ModuleDef.init(ctx, "test_module", testModuleInit);
    try testing.expect(m != null);

    try testing.expect(m.?.addExport(ctx, "value"));
    try testing.expect(m.?.addExport(ctx, "greeting"));
}

test "ModuleDef getName" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const m = ModuleDef.init(ctx, "my_module", testModuleInit).?;
    _ = m.addExport(ctx, "value");
    _ = m.addExport(ctx, "greeting");

    const name_atom = m.getName(ctx);
    defer name_atom.deinit(ctx);

    const name_str = name_atom.toCString(ctx).?;
    defer ctx.freeCString(name_str);

    try testing.expectEqualStrings("my_module", std.mem.span(name_str));
}

test "ModuleDef full module import via eval" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const loader = struct {
        fn load(_: void, load_ctx: *Context, name: [:0]const u8) ?*ModuleDef {
            if (!std.mem.eql(u8, name, "test_module")) return null;

            const m = ModuleDef.init(load_ctx, name, initFn) orelse return null;
            _ = m.addExport(load_ctx, "value");
            return m;
        }

        fn initFn(init_ctx: *Context, m: *ModuleDef) bool {
            if (!m.setExport(init_ctx, "value", Value.initInt32(123))) return false;
            return true;
        }
    };

    rt.setModuleLoaderFunc(void, {}, null, loader.load);

    const result = ctx.eval(
        \\import { value } from "test_module";
        \\globalThis.testResult = value;
    , "<test>", .{ .type = .module });
    defer result.deinit(ctx);

    if (result.isException()) {
        const exc = ctx.getException();
        defer exc.deinit(ctx);
        if (exc.getPropertyStr(ctx, "message").toCString(ctx)) |msg| {
            defer ctx.freeCString(msg);
            std.debug.print("Exception: {s}\n", .{msg});
        }
        try testing.expect(false);
    }

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);
    const test_result = global.getPropertyStr(ctx, "testResult");
    defer test_result.deinit(ctx);

    try testing.expectEqual(@as(i32, 123), try test_result.toInt32(ctx));
}

test "ModuleDef getImportMeta" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const State = struct { captured_module: ?*ModuleDef = null };

    const loader = struct {
        fn load(
            state: ?*State,
            load_ctx: *Context,
            name: [:0]const u8,
        ) ?*ModuleDef {
            if (!std.mem.eql(u8, name, "meta_test")) return null;

            const m = ModuleDef.init(load_ctx, name, initFn) orelse return null;
            _ = m.addExport(load_ctx, "dummy");

            state.?.captured_module = m;

            return m;
        }

        fn initFn(init_ctx: *Context, m: *ModuleDef) bool {
            if (!m.setExport(init_ctx, "dummy", Value.initInt32(1))) return false;
            return true;
        }
    };

    var state: State = .{};
    rt.setModuleLoaderFunc(State, &state, null, loader.load);

    const result = ctx.eval(
        \\import { dummy } from "meta_test";
        \\dummy
    , "<test>", .{ .type = .module });
    defer result.deinit(ctx);

    try testing.expect(!result.isException());
    try testing.expect(state.captured_module != null);

    const meta = state.captured_module.?.getImportMeta(ctx);
    defer meta.deinit(ctx);

    try testing.expect(meta.isObject());
}

test "ModuleDef getNamespace" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const State = struct { captured_module: ?*ModuleDef = null };

    const loader = struct {
        fn load(
            state: ?*State,
            load_ctx: *Context,
            name: [:0]const u8,
        ) ?*ModuleDef {
            if (!std.mem.eql(u8, name, "ns_test")) return null;

            const m = ModuleDef.init(load_ctx, name, initFn) orelse return null;
            _ = m.addExport(load_ctx, "foo");
            _ = m.addExport(load_ctx, "bar");

            state.?.captured_module = m;

            return m;
        }

        fn initFn(init_ctx: *Context, m: *ModuleDef) bool {
            if (!m.setExport(init_ctx, "foo", Value.initInt32(10))) return false;
            if (!m.setExport(init_ctx, "bar", Value.initInt32(20))) return false;
            return true;
        }
    };

    var state: State = .{};
    rt.setModuleLoaderFunc(State, &state, null, loader.load);

    const result = ctx.eval(
        \\import * as ns from "ns_test";
        \\globalThis.nsResult = ns.foo + ns.bar;
    , "<test>", .{ .type = .module });
    defer result.deinit(ctx);

    try testing.expect(!result.isException());

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);
    const ns_result = global.getPropertyStr(ctx, "nsResult");
    defer ns_result.deinit(ctx);
    try testing.expectEqual(@as(i32, 30), try ns_result.toInt32(ctx));

    const ns = state.captured_module.?.getNamespace(ctx);
    defer ns.deinit(ctx);

    try testing.expect(ns.isObject());

    const foo = ns.getPropertyStr(ctx, "foo");
    defer foo.deinit(ctx);
    try testing.expectEqual(@as(i32, 10), try foo.toInt32(ctx));
}
