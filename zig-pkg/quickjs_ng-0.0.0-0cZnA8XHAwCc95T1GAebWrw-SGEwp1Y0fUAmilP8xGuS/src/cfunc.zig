const std = @import("std");
const testing = std.testing;
const c = @import("quickjs_c");
const Context = @import("context.zig").Context;
const Value = @import("value.zig").Value;
const opaquepkg = @import("opaque.zig");
const Opaque = opaquepkg.Opaque;

/// C function prototype type.
///
/// C: `JSCFunctionEnum`
pub const Proto = enum(c_uint) {
    generic = c.JS_CFUNC_generic,
    generic_magic = c.JS_CFUNC_generic_magic,
    constructor = c.JS_CFUNC_constructor,
    constructor_magic = c.JS_CFUNC_constructor_magic,
    constructor_or_func = c.JS_CFUNC_constructor_or_func,
    constructor_or_func_magic = c.JS_CFUNC_constructor_or_func_magic,
    f_f = c.JS_CFUNC_f_f,
    f_f_f = c.JS_CFUNC_f_f_f,
    getter = c.JS_CFUNC_getter,
    setter = c.JS_CFUNC_setter,
    getter_magic = c.JS_CFUNC_getter_magic,
    setter_magic = c.JS_CFUNC_setter_magic,
    iterator_next = c.JS_CFUNC_iterator_next,
};

/// C function signature for simple functions.
///
/// C: `JSCFunction`
pub const Func = *const fn (
    ?*Context,
    Value,
    []const c.JSValue,
) Value;

/// Wraps a Zig-friendly Func into a C-callable function.
pub fn wrapFunc(comptime func: Func) c.JSCFunction {
    return struct {
        fn callback(
            ctx: ?*c.JSContext,
            this_val: c.JSValue,
            argc: c_int,
            argv: [*c]c.JSValue,
        ) callconv(.c) c.JSValue {
            const args: []const c.JSValue = if (argc > 0)
                argv[0..@intCast(argc)]
            else
                &.{};
            return @call(.always_inline, func, .{
                @as(?*Context, @ptrCast(ctx)),
                @as(Value, @bitCast(this_val)),
                args,
            }).cval();
        }
    }.callback;
}

/// C function signature for functions with magic value.
///
/// C: `JSCFunctionMagic`
pub const FuncMagic = *const fn (
    ?*Context,
    Value,
    []const c.JSValue,
    c_int,
) Value;

/// Wraps a Zig-friendly FuncMagic into a C-callable function.
pub fn wrapFuncMagic(comptime func: FuncMagic) c.JSCFunctionMagic {
    return struct {
        fn callback(
            ctx: ?*c.JSContext,
            this_val: c.JSValue,
            argc: c_int,
            argv: [*c]c.JSValue,
            magic: c_int,
        ) callconv(.c) c.JSValue {
            const args: []const c.JSValue = if (argc > 0)
                argv[0..@intCast(argc)]
            else
                &.{};
            return @call(.always_inline, func, .{
                @as(?*Context, @ptrCast(ctx)),
                @as(Value, @bitCast(this_val)),
                args,
                magic,
            }).cval();
        }
    }.callback;
}

/// C function signature for functions with closure data.
///
/// The magic parameter is the magic value passed at construction.
/// The func_data pointer points to the array of data values passed at construction.
///
/// C: `JSCFunctionData`
pub const FuncData = *const fn (
    ?*Context,
    Value,
    []const c.JSValue,
    c_int,
    [*c]c.JSValue,
) Value;

/// Wraps a Zig-friendly FuncData into a C-callable function.
pub fn wrapFuncData(comptime func: FuncData) c.JSCFunctionData {
    return struct {
        fn callback(
            ctx: ?*c.JSContext,
            this_val: c.JSValue,
            argc: c_int,
            argv: [*c]c.JSValue,
            magic: c_int,
            data: [*c]c.JSValue,
        ) callconv(.c) c.JSValue {
            const args: []const c.JSValue = if (argc > 0)
                argv[0..@intCast(argc)]
            else
                &.{};
            return @call(.always_inline, func, .{
                @as(?*Context, @ptrCast(ctx)),
                @as(Value, @bitCast(this_val)),
                args,
                magic,
                data,
            }).cval();
        }
    }.callback;
}

/// C closure function signature.
///
/// C: `JSCClosure`
pub fn Closure(comptime T: type) type {
    return *const fn (
        ?*Context,
        Value,
        []const c.JSValue,
        c_int,
        Opaque(T),
    ) Value;
}

/// Wraps a Zig-friendly Closure into a C-callable function.
pub fn wrapClosure(comptime T: type, comptime func: Closure(T)) c.JSCClosure {
    return struct {
        fn callback(
            ctx: ?*c.JSContext,
            this_val: c.JSValue,
            argc: c_int,
            argv: [*c]c.JSValue,
            magic: c_int,
            opaque_ptr: ?*anyopaque,
        ) callconv(.c) c.JSValue {
            const args: []const c.JSValue = if (argc > 0)
                argv[0..@intCast(argc)]
            else
                &.{};
            return @call(.always_inline, func, .{
                @as(?*Context, @ptrCast(ctx)),
                @as(Value, @bitCast(this_val)),
                args,
                magic,
                opaquepkg.fromC(T, opaque_ptr),
            }).cval();
        }
    }.callback;
}

/// Finalizer function for C closures.
///
/// C: `JSCClosureFinalizerFunc`
pub fn ClosureFinalizer(comptime T: type) type {
    return *const fn (Opaque(T)) void;
}

/// Wraps a Zig-friendly ClosureFinalizer into a C-callable function.
pub fn wrapClosureFinalizer(comptime T: type, comptime func: ClosureFinalizer(T)) c.JSCClosureFinalizerFunc {
    return struct {
        fn callback(opaque_ptr: ?*anyopaque) callconv(.c) void {
            @call(.always_inline, func, .{opaquepkg.fromC(T, opaque_ptr)});
        }
    }.callback;
}

/// Getter function signature.
///
/// C: getter in `JSCFunctionType`
pub const Getter = *const fn (?*Context, Value) Value;

const CGetterFn = ?*const fn (?*c.JSContext, c.JSValue) callconv(.c) c.JSValue;

/// Wraps a Zig-friendly Getter into a C-callable function.
pub fn wrapGetter(comptime func: Getter) CGetterFn {
    return struct {
        fn callback(
            ctx: ?*c.JSContext,
            this_val: c.JSValue,
        ) callconv(.c) c.JSValue {
            return @call(.always_inline, func, .{
                @as(?*Context, @ptrCast(ctx)),
                @as(Value, @bitCast(this_val)),
            }).cval();
        }
    }.callback;
}

/// Setter function signature.
///
/// C: setter in `JSCFunctionType`
pub const Setter = *const fn (?*Context, Value, Value) Value;

const CSetterFn = ?*const fn (?*c.JSContext, c.JSValue, c.JSValue) callconv(.c) c.JSValue;

/// Wraps a Zig-friendly Setter into a C-callable function.
pub fn wrapSetter(comptime func: Setter) CSetterFn {
    return struct {
        fn callback(
            ctx: ?*c.JSContext,
            this_val: c.JSValue,
            val: c.JSValue,
        ) callconv(.c) c.JSValue {
            return @call(.always_inline, func, .{
                @as(?*Context, @ptrCast(ctx)),
                @as(Value, @bitCast(this_val)),
                @as(Value, @bitCast(val)),
            }).cval();
        }
    }.callback;
}

/// Getter function signature with magic value.
///
/// C: getter_magic in `JSCFunctionType`
pub const GetterMagic = *const fn (?*Context, Value, c_int) Value;

const CGetterMagicFn = ?*const fn (?*c.JSContext, c.JSValue, c_int) callconv(.c) c.JSValue;

/// Wraps a Zig-friendly GetterMagic into a C-callable function.
pub fn wrapGetterMagic(comptime func: GetterMagic) CGetterMagicFn {
    return struct {
        fn callback(
            ctx: ?*c.JSContext,
            this_val: c.JSValue,
            magic: c_int,
        ) callconv(.c) c.JSValue {
            return @call(.always_inline, func, .{
                @as(?*Context, @ptrCast(ctx)),
                @as(Value, @bitCast(this_val)),
                magic,
            }).cval();
        }
    }.callback;
}

/// Setter function signature with magic value.
///
/// C: setter_magic in `JSCFunctionType`
pub const SetterMagic = *const fn (?*Context, Value, Value, c_int) Value;

const CSetterMagicFn = ?*const fn (?*c.JSContext, c.JSValue, c.JSValue, c_int) callconv(.c) c.JSValue;

/// Wraps a Zig-friendly SetterMagic into a C-callable function.
pub fn wrapSetterMagic(comptime func: SetterMagic) CSetterMagicFn {
    return struct {
        fn callback(
            ctx: ?*c.JSContext,
            this_val: c.JSValue,
            val: c.JSValue,
            magic: c_int,
        ) callconv(.c) c.JSValue {
            return @call(.always_inline, func, .{
                @as(?*Context, @ptrCast(ctx)),
                @as(Value, @bitCast(this_val)),
                @as(Value, @bitCast(val)),
                magic,
            }).cval();
        }
    }.callback;
}

/// Definition type for function list entries.
pub const DefType = enum(u8) {
    cfunc = c.JS_DEF_CFUNC,
    cgetset = c.JS_DEF_CGETSET,
    cgetset_magic = c.JS_DEF_CGETSET_MAGIC,
    prop_string = c.JS_DEF_PROP_STRING,
    prop_int32 = c.JS_DEF_PROP_INT32,
    prop_int64 = c.JS_DEF_PROP_INT64,
    prop_double = c.JS_DEF_PROP_DOUBLE,
    prop_undefined = c.JS_DEF_PROP_UNDEFINED,
    object = c.JS_DEF_OBJECT,
    alias = c.JS_DEF_ALIAS,
};

/// Property flags for function list entries.
pub const PropFlags = packed struct(u8) {
    configurable: bool = false,
    writable: bool = false,
    enumerable: bool = false,
    _padding: u5 = 0,

    pub const default: PropFlags = .{ .writable = true, .configurable = true };
};

/// Function list entry for bulk property definition.
///
/// C: `JSCFunctionListEntry`
pub const FunctionListEntry = c.JSCFunctionListEntry;

/// Helper functions for creating FunctionListEntry values.
pub const FunctionListEntryHelpers = struct {
    /// Creates a function definition entry.
    pub fn func(
        name: [:0]const u8,
        length: u8,
        comptime cfunc_ptr: Func,
    ) FunctionListEntry {
        return funcWithFlags(name, length, wrapFunc(cfunc_ptr), PropFlags.default);
    }

    /// Creates a function definition entry with custom flags.
    pub fn funcWithFlags(
        name: [:0]const u8,
        length: u8,
        cfunc_ptr: c.JSCFunction,
        flags: PropFlags,
    ) FunctionListEntry {
        var entry: FunctionListEntry = std.mem.zeroes(FunctionListEntry);
        entry.name = name.ptr;
        entry.prop_flags = @bitCast(flags);
        entry.def_type = @intFromEnum(DefType.cfunc);
        entry.magic = 0;
        entry.u.func.length = length;
        entry.u.func.cproto = @intFromEnum(Proto.generic);
        entry.u.func.cfunc.generic = cfunc_ptr;
        return entry;
    }

    /// Creates a function definition with magic value.
    pub fn funcMagic(
        name: [:0]const u8,
        length: u8,
        comptime cfunc_ptr: FuncMagic,
        magic: i16,
    ) FunctionListEntry {
        var entry: FunctionListEntry = std.mem.zeroes(FunctionListEntry);
        entry.name = name.ptr;
        entry.prop_flags = @bitCast(PropFlags.default);
        entry.def_type = @intFromEnum(DefType.cfunc);
        entry.magic = magic;
        entry.u.func.length = length;
        entry.u.func.cproto = @intFromEnum(Proto.generic_magic);
        entry.u.func.cfunc.generic_magic = wrapFuncMagic(cfunc_ptr);
        return entry;
    }

    /// Creates a getter/setter property definition.
    pub fn getset(
        name: [:0]const u8,
        comptime getter_fn: ?Getter,
        comptime setter_fn: ?Setter,
    ) FunctionListEntry {
        var entry: FunctionListEntry = std.mem.zeroes(FunctionListEntry);
        entry.name = name.ptr;
        entry.prop_flags = c.JS_PROP_CONFIGURABLE;
        entry.def_type = @intFromEnum(DefType.cgetset);
        entry.magic = 0;
        entry.u.getset.get.getter = if (getter_fn) |g| wrapGetter(g) else null;
        entry.u.getset.set.setter = if (setter_fn) |s| wrapSetter(s) else null;
        return entry;
    }

    /// Creates a getter/setter property definition with magic value.
    pub fn getsetMagic(
        name: [:0]const u8,
        comptime getter_fn: ?GetterMagic,
        comptime setter_fn: ?SetterMagic,
        magic: i16,
    ) FunctionListEntry {
        var entry: FunctionListEntry = std.mem.zeroes(FunctionListEntry);
        entry.name = name.ptr;
        entry.prop_flags = c.JS_PROP_CONFIGURABLE;
        entry.def_type = @intFromEnum(DefType.cgetset_magic);
        entry.magic = magic;
        entry.u.getset.get.getter_magic = if (getter_fn) |g| wrapGetterMagic(g) else null;
        entry.u.getset.set.setter_magic = if (setter_fn) |s| wrapSetterMagic(s) else null;
        return entry;
    }

    /// Creates a string property definition.
    pub fn propString(
        name: [:0]const u8,
        value: [:0]const u8,
        flags: PropFlags,
    ) FunctionListEntry {
        var entry: FunctionListEntry = std.mem.zeroes(FunctionListEntry);
        entry.name = name.ptr;
        entry.prop_flags = @bitCast(flags);
        entry.def_type = @intFromEnum(DefType.prop_string);
        entry.magic = 0;
        entry.u.str = value.ptr;
        return entry;
    }

    /// Creates an i32 property definition.
    pub fn propInt32(
        name: [:0]const u8,
        value: i32,
        flags: PropFlags,
    ) FunctionListEntry {
        var entry: FunctionListEntry = std.mem.zeroes(FunctionListEntry);
        entry.name = name.ptr;
        entry.prop_flags = @bitCast(flags);
        entry.def_type = @intFromEnum(DefType.prop_int32);
        entry.magic = 0;
        entry.u.i32 = value;
        return entry;
    }

    /// Creates an i64 property definition.
    pub fn propInt64(
        name: [:0]const u8,
        value: i64,
        flags: PropFlags,
    ) FunctionListEntry {
        var entry: FunctionListEntry = std.mem.zeroes(FunctionListEntry);
        entry.name = name.ptr;
        entry.prop_flags = @bitCast(flags);
        entry.def_type = @intFromEnum(DefType.prop_int64);
        entry.magic = 0;
        entry.u.i64 = value;
        return entry;
    }

    /// Creates a double property definition.
    pub fn propDouble(
        name: [:0]const u8,
        value: f64,
        flags: PropFlags,
    ) FunctionListEntry {
        var entry: FunctionListEntry = std.mem.zeroes(FunctionListEntry);
        entry.name = name.ptr;
        entry.prop_flags = @bitCast(flags);
        entry.def_type = @intFromEnum(DefType.prop_double);
        entry.magic = 0;
        entry.u.f64 = value;
        return entry;
    }

    /// Creates an undefined property definition.
    pub fn propUndefined(
        name: [:0]const u8,
        flags: PropFlags,
    ) FunctionListEntry {
        var entry: FunctionListEntry = std.mem.zeroes(FunctionListEntry);
        entry.name = name.ptr;
        entry.prop_flags = @bitCast(flags);
        entry.def_type = @intFromEnum(DefType.prop_undefined);
        entry.magic = 0;
        entry.u.i32 = 0;
        return entry;
    }
};

test "Proto enum matches C constants" {
    try testing.expectEqual(@as(c_uint, c.JS_CFUNC_generic), @intFromEnum(Proto.generic));
    try testing.expectEqual(@as(c_uint, c.JS_CFUNC_generic_magic), @intFromEnum(Proto.generic_magic));
    try testing.expectEqual(@as(c_uint, c.JS_CFUNC_constructor), @intFromEnum(Proto.constructor));
    try testing.expectEqual(@as(c_uint, c.JS_CFUNC_constructor_magic), @intFromEnum(Proto.constructor_magic));
    try testing.expectEqual(@as(c_uint, c.JS_CFUNC_constructor_or_func), @intFromEnum(Proto.constructor_or_func));
    try testing.expectEqual(@as(c_uint, c.JS_CFUNC_constructor_or_func_magic), @intFromEnum(Proto.constructor_or_func_magic));
    try testing.expectEqual(@as(c_uint, c.JS_CFUNC_f_f), @intFromEnum(Proto.f_f));
    try testing.expectEqual(@as(c_uint, c.JS_CFUNC_f_f_f), @intFromEnum(Proto.f_f_f));
    try testing.expectEqual(@as(c_uint, c.JS_CFUNC_getter), @intFromEnum(Proto.getter));
    try testing.expectEqual(@as(c_uint, c.JS_CFUNC_setter), @intFromEnum(Proto.setter));
    try testing.expectEqual(@as(c_uint, c.JS_CFUNC_getter_magic), @intFromEnum(Proto.getter_magic));
    try testing.expectEqual(@as(c_uint, c.JS_CFUNC_setter_magic), @intFromEnum(Proto.setter_magic));
    try testing.expectEqual(@as(c_uint, c.JS_CFUNC_iterator_next), @intFromEnum(Proto.iterator_next));
}

test "DefType enum matches C constants" {
    try testing.expectEqual(@as(u8, c.JS_DEF_CFUNC), @intFromEnum(DefType.cfunc));
    try testing.expectEqual(@as(u8, c.JS_DEF_CGETSET), @intFromEnum(DefType.cgetset));
    try testing.expectEqual(@as(u8, c.JS_DEF_CGETSET_MAGIC), @intFromEnum(DefType.cgetset_magic));
    try testing.expectEqual(@as(u8, c.JS_DEF_PROP_STRING), @intFromEnum(DefType.prop_string));
    try testing.expectEqual(@as(u8, c.JS_DEF_PROP_INT32), @intFromEnum(DefType.prop_int32));
    try testing.expectEqual(@as(u8, c.JS_DEF_PROP_INT64), @intFromEnum(DefType.prop_int64));
    try testing.expectEqual(@as(u8, c.JS_DEF_PROP_DOUBLE), @intFromEnum(DefType.prop_double));
    try testing.expectEqual(@as(u8, c.JS_DEF_PROP_UNDEFINED), @intFromEnum(DefType.prop_undefined));
    try testing.expectEqual(@as(u8, c.JS_DEF_OBJECT), @intFromEnum(DefType.object));
    try testing.expectEqual(@as(u8, c.JS_DEF_ALIAS), @intFromEnum(DefType.alias));
}

test "PropFlags matches C constants" {
    const configurable: PropFlags = .{ .configurable = true };
    try testing.expectEqual(@as(u8, c.JS_PROP_CONFIGURABLE), @as(u8, @bitCast(configurable)));

    const writable: PropFlags = .{ .writable = true };
    try testing.expectEqual(@as(u8, c.JS_PROP_WRITABLE), @as(u8, @bitCast(writable)));

    const enumerable: PropFlags = .{ .enumerable = true };
    try testing.expectEqual(@as(u8, c.JS_PROP_ENUMERABLE), @as(u8, @bitCast(enumerable)));

    const default_flags: PropFlags = PropFlags.default;
    try testing.expectEqual(@as(u8, c.JS_PROP_WRITABLE | c.JS_PROP_CONFIGURABLE), @as(u8, @bitCast(default_flags)));
}
