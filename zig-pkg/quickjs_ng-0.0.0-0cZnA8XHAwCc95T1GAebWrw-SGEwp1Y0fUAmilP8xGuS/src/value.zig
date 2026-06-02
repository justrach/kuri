const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;
const c = @import("quickjs_c");
const Atom = @import("atom.zig").Atom;
const cfunc = @import("cfunc.zig");
const Context = @import("context.zig").Context;
const ModuleDef = @import("module.zig").ModuleDef;
const Runtime = @import("runtime.zig").Runtime;
const typed_array = @import("typed_array.zig");
const class = @import("class.zig");
const opaquepkg = @import("opaque.zig");
const Opaque = opaquepkg.Opaque;

/// Wrapper for the QuickJS `JSValue`.
///
/// A value represents any JavaScript value (number, string, object, etc.).
/// Values are reference-counted and must be freed with `deinit` when no
/// longer needed.
///
/// C: `JSValue`
pub const Value = extern struct {
    // If this is true then we are in nan-boxing mode which changes
    // our Value representation.
    pub const is_nan_boxed = builtin.target.ptrBitWidth() < 64;

    // Non-nan-boxed layout
    u: if (!is_nan_boxed) c.JSValueUnion else void = if (!is_nan_boxed) .{ .int32 = 0 } else {},
    tag: if (!is_nan_boxed) Tag else void = if (!is_nan_boxed) .undefined else {},

    // NaN-boxed layout
    val: if (is_nan_boxed) u64 else void = if (is_nan_boxed) mkval(.undefined, 0) else {},

    /// JavaScript value type tag.
    ///
    /// C: anonymous enum in quickjs.h
    pub const Tag = enum(i64) {
        big_int = c.JS_TAG_BIG_INT,
        symbol = c.JS_TAG_SYMBOL,
        string = c.JS_TAG_STRING,
        module = c.JS_TAG_MODULE,
        function_bytecode = c.JS_TAG_FUNCTION_BYTECODE,
        object = c.JS_TAG_OBJECT,
        int = c.JS_TAG_INT,
        bool = c.JS_TAG_BOOL,
        null = c.JS_TAG_NULL,
        undefined = c.JS_TAG_UNDEFINED,
        uninitialized = c.JS_TAG_UNINITIALIZED,
        catch_offset = c.JS_TAG_CATCH_OFFSET,
        exception = c.JS_TAG_EXCEPTION,
        short_big_int = c.JS_TAG_SHORT_BIG_INT,
        float64 = c.JS_TAG_FLOAT64,
        _,
    };

    pub const @"null": Value = if (is_nan_boxed)
        .{ .val = mkval(.null, 0) }
    else
        .{ .u = .{ .int32 = 0 }, .tag = .null };

    pub const @"undefined": Value = if (is_nan_boxed)
        .{ .val = mkval(.undefined, 0) }
    else
        .{ .u = .{ .int32 = 0 }, .tag = .undefined };

    pub const @"false": Value = if (is_nan_boxed)
        .{ .val = mkval(.bool, 0) }
    else
        .{ .u = .{ .int32 = 0 }, .tag = .bool };

    pub const @"true": Value = if (is_nan_boxed)
        .{ .val = mkval(.bool, 1) }
    else
        .{ .u = .{ .int32 = 1 }, .tag = .bool };

    pub const exception: Value = if (is_nan_boxed)
        .{ .val = mkval(.exception, 0) }
    else
        .{ .u = .{ .int32 = 0 }, .tag = .exception };

    pub const uninitialized: Value = if (is_nan_boxed)
        .{ .val = mkval(.uninitialized, 0) }
    else
        .{ .u = .{ .int32 = 0 }, .tag = .uninitialized };

    /// Initialize a Value from a Zig type.
    ///
    /// If the value is already a `Value`, it is returned directly.
    /// Otherwise, this function attempts to convert the Zig value to a
    /// JavaScript Value. If conversion fails, an exception is thrown and
    /// the exception Value is returned.
    ///
    /// Supported types:
    /// - `Value` (returned as-is)
    /// - `bool` → JavaScript boolean
    /// - `void` → JavaScript null
    /// - `@TypeOf(null)` → JavaScript null
    /// - Optional types → unwrapped value or null
    /// - Integers (≤32 bits) → JavaScript int32/uint32
    /// - Integers (≤64 bits) → JavaScript int64 (may become float64)
    /// - `comptime_int` → JavaScript int64
    /// - Floats (≤64 bits) → JavaScript float64
    /// - `comptime_float` → JavaScript float64
    /// - `[]const u8` slices → JavaScript string
    /// - `*const [N]u8` → JavaScript string
    pub fn init(ctx: *Context, val: anytype) Value {
        return switch (@TypeOf(val)) {
            Value => val,
            bool => initBool(val),
            void => @"null",

            else => |T| switch (@typeInfo(T)) {
                .null => @"null",
                .optional => if (val) |v| init(ctx, v) else @"null",

                .int => |info| if (info.bits <= 32) switch (info.signedness) {
                    .signed => initInt32(@intCast(val)),
                    .unsigned => initUint32(@intCast(val)),
                } else if (info.bits <= 63 or
                    (val >= std.math.minInt(i63) and val <= std.math.maxInt(i63)))
                    initInt64(@intCast(val))
                else if (info.bits == 64)
                    initFloat64(@floatFromInt(val))
                else
                    initConversionError(ctx),

                .comptime_int => initInt64(val),

                .float => |info| if (info.bits <= 64)
                    initFloat64(@floatCast(val))
                else
                    initConversionError(ctx),
                .comptime_float => initFloat64(val),

                .pointer => |ptr| switch (ptr.size) {
                    .slice => if (ptr.child == u8)
                        initStringLen(ctx, val)
                    else
                        initConversionError(ctx),

                    .one => if (@typeInfo(ptr.child) == .array and
                        @typeInfo(ptr.child).array.child == u8)
                        initStringLen(ctx, val)
                    else
                        initConversionError(ctx),

                    else => initConversionError(ctx),
                },

                else => initConversionError(ctx),
            },
        };
    }

    fn initConversionError(ctx: *Context) Value {
        return initString(ctx, "failed to convert Zig value to JS Value").throw(ctx);
    }

    /// Creates a JavaScript boolean value.
    ///
    /// C: `JS_NewBool`
    pub fn initBool(val: bool) Value {
        return if (is_nan_boxed)
            .{ .val = mkval(.bool, @intFromBool(val)) }
        else
            .{ .u = .{ .int32 = @intFromBool(val) }, .tag = .bool };
    }

    /// Creates a JavaScript 32-bit integer value.
    ///
    /// C: `JS_NewInt32`
    pub fn initInt32(val: i32) Value {
        return if (is_nan_boxed)
            .{ .val = mkval(.int, val) }
        else
            .{ .u = .{ .int32 = val }, .tag = .int };
    }

    /// Creates a JavaScript 64-bit integer value.
    ///
    /// If the value fits in an i32, creates an int value. Otherwise creates a float64.
    ///
    /// C: `JS_NewInt64`
    pub fn initInt64(val: i64) Value {
        return if (val >= std.math.minInt(i32) and val <= std.math.maxInt(i32))
            initInt32(@intCast(val))
        else
            initFloat64(@floatFromInt(val));
    }

    /// Creates a JavaScript unsigned 32-bit integer value.
    ///
    /// If the value fits in an i32, creates an int value. Otherwise creates a float64.
    ///
    /// C: `JS_NewUint32`
    pub fn initUint32(val: u32) Value {
        return if (val <= std.math.maxInt(i32))
            initInt32(@intCast(val))
        else
            initFloat64(@floatFromInt(val));
    }

    /// Creates a JavaScript floating-point number value.
    ///
    /// C: `JS_NewFloat64`
    pub fn initFloat64(val: f64) Value {
        return if (is_nan_boxed)
            .{ .val = mkfloat64(val) }
        else
            .{ .u = .{ .float64 = val }, .tag = .float64 };
    }

    /// Creates a JavaScript number value from a double.
    ///
    /// May return an integer if the value is a whole number that fits in i32.
    ///
    /// C: `JS_NewNumber`
    pub fn initNumber(ctx: *Context, val: f64) Value {
        return fromCVal(c.JS_NewNumber(ctx.cval(), val));
    }

    /// Creates a JavaScript BigInt value from a signed 64-bit integer.
    ///
    /// C: `JS_NewBigInt64`
    pub fn initBigInt64(ctx: *Context, val: i64) Value {
        return fromCVal(c.JS_NewBigInt64(ctx.cval(), val));
    }

    /// Creates a JavaScript BigInt value from an unsigned 64-bit integer.
    ///
    /// C: `JS_NewBigUint64`
    pub fn initBigUint64(ctx: *Context, val: u64) Value {
        return fromCVal(c.JS_NewBigUint64(ctx.cval(), val));
    }

    /// Creates a JavaScript string value from a null-terminated string.
    ///
    /// C: `JS_NewString`
    pub fn initString(ctx: *Context, str: [*:0]const u8) Value {
        return fromCVal(c.JS_NewString(ctx.cval(), str));
    }

    /// Creates a JavaScript string value from a byte slice.
    ///
    /// C: `JS_NewStringLen`
    pub fn initStringLen(ctx: *Context, str: []const u8) Value {
        return fromCVal(c.JS_NewStringLen(ctx.cval(), str.ptr, str.len));
    }

    /// Creates an empty JavaScript object.
    ///
    /// C: `JS_NewObject`
    pub fn initObject(ctx: *Context) Value {
        return fromCVal(c.JS_NewObject(ctx.cval()));
    }

    /// Creates a JavaScript object with a specific prototype.
    ///
    /// C: `JS_NewObjectProto`
    pub fn initObjectProto(ctx: *Context, proto: Value) Value {
        return fromCVal(c.JS_NewObjectProto(ctx.cval(), proto.cval()));
    }

    /// Creates a JavaScript object with a specific class ID.
    ///
    /// The object will have the prototype associated with the class (set via
    /// Context.setClassProto) and can store opaque data via setOpaque.
    ///
    /// C: `JS_NewObjectClass`
    pub fn initObjectClass(ctx: *Context, class_id: class.Id) Value {
        return fromCVal(c.JS_NewObjectClass(ctx.cval(), @intFromEnum(class_id)));
    }

    /// Creates an empty JavaScript array.
    ///
    /// C: `JS_NewArray`
    pub fn initArray(ctx: *Context) Value {
        return fromCVal(c.JS_NewArray(ctx.cval()));
    }

    /// Creates a JavaScript array from a slice of values.
    ///
    /// Takes ownership of the values.
    ///
    /// C: `JS_NewArrayFrom`
    pub fn initArrayFrom(ctx: *Context, values: []const Value) Value {
        return fromCVal(c.JS_NewArrayFrom(
            ctx.cval(),
            @intCast(values.len),
            @ptrCast(values.ptr),
        ));
    }

    /// Creates a JavaScript Date object from epoch milliseconds.
    ///
    /// C: `JS_NewDate`
    pub fn initDate(ctx: *Context, epoch_ms: f64) Value {
        return fromCVal(c.JS_NewDate(ctx.cval(), epoch_ms));
    }

    /// Creates a JavaScript Symbol.
    ///
    /// C: `JS_NewSymbol`
    pub fn initSymbol(ctx: *Context, description: [*:0]const u8, is_global: bool) Value {
        return fromCVal(c.JS_NewSymbol(ctx.cval(), description, is_global));
    }

    /// Creates a JavaScript Error object.
    ///
    /// C: `JS_NewError`
    pub fn initError(ctx: *Context) Value {
        return fromCVal(c.JS_NewError(ctx.cval()));
    }

    // -----------------------------------------------------------------------
    // C Function Constructors
    // -----------------------------------------------------------------------

    /// Creates a JavaScript function from a C function.
    ///
    /// C: `JS_NewCFunction`
    pub fn initCFunction(
        ctx: *Context,
        comptime func: cfunc.Func,
        name: [:0]const u8,
        length: i32,
    ) Value {
        return fromCVal(c.JS_NewCFunction(
            ctx.cval(),
            cfunc.wrapFunc(func),
            name.ptr,
            length,
        ));
    }

    /// Creates a JavaScript function from a C function with prototype and magic.
    ///
    /// C: `JS_NewCFunction2`
    pub fn initCFunction2(
        ctx: *Context,
        comptime func: cfunc.Func,
        name: [:0]const u8,
        length: i32,
        cproto: cfunc.Proto,
        magic: i32,
    ) Value {
        return fromCVal(c.JS_NewCFunction2(
            ctx.cval(),
            cfunc.wrapFunc(func),
            name.ptr,
            length,
            @intFromEnum(cproto),
            magic,
        ));
    }

    /// Creates a JavaScript function from a C function with prototype, magic and custom prototype object.
    ///
    /// C: `JS_NewCFunction3`
    pub fn initCFunction3(
        ctx: *Context,
        comptime func: cfunc.Func,
        name: [:0]const u8,
        length: i32,
        cproto: cfunc.Proto,
        magic: i32,
        proto_val: Value,
    ) Value {
        return fromCVal(c.JS_NewCFunction3(
            ctx.cval(),
            cfunc.wrapFunc(func),
            name.ptr,
            length,
            @intFromEnum(cproto),
            magic,
            proto_val.cval(),
        ));
    }

    /// Creates a JavaScript function from a C function with closure data.
    ///
    /// The data values are copied and can be accessed in the function via func_data parameter.
    ///
    /// C: `JS_NewCFunctionData`
    pub fn initCFunctionData(
        ctx: *Context,
        comptime func: cfunc.FuncData,
        length: i32,
        magic: i32,
        data: []const Value,
    ) Value {
        return fromCVal(c.JS_NewCFunctionData(
            ctx.cval(),
            cfunc.wrapFuncData(func),
            length,
            magic,
            @intCast(data.len),
            @ptrCast(@constCast(data.ptr)),
        ));
    }

    /// Creates a named JavaScript function from a C function with closure data.
    ///
    /// C: `JS_NewCFunctionData2`
    pub fn initCFunctionData2(
        ctx: *Context,
        comptime func: cfunc.FuncData,
        name: [:0]const u8,
        length: i32,
        magic: i32,
        data: []const Value,
    ) Value {
        return fromCVal(c.JS_NewCFunctionData2(
            ctx.cval(),
            cfunc.wrapFuncData(func),
            name.ptr,
            length,
            magic,
            @intCast(data.len),
            @ptrCast(@constCast(data.ptr)),
        ));
    }

    /// Creates a JavaScript function from a C closure with opaque data.
    ///
    /// The opaque pointer is passed directly to the function and finalizer.
    ///
    /// C: `JS_NewCClosure`
    pub fn initCClosure(
        ctx: *Context,
        comptime T: type,
        comptime func: cfunc.Closure(T),
        name: [:0]const u8,
        comptime finalizer: ?cfunc.ClosureFinalizer(T),
        length: i32,
        magic: i32,
        userdata: Opaque(T),
    ) Value {
        return fromCVal(c.JS_NewCClosure(
            ctx.cval(),
            cfunc.wrapClosure(T, func),
            name.ptr,
            if (finalizer) |f| cfunc.wrapClosureFinalizer(T, f) else null,
            length,
            magic,
            opaquepkg.toC(T, userdata),
        ));
    }

    // -----------------------------------------------------------------------
    // ArrayBuffer & TypedArray Constructors
    // -----------------------------------------------------------------------

    /// Creates an ArrayBuffer with the given data.
    ///
    /// The buffer takes ownership of the data. When the buffer is garbage
    /// collected, free_func will be called (if provided) to free the data.
    ///
    /// C: `JS_NewArrayBuffer`
    pub fn initArrayBuffer(
        ctx: *Context,
        comptime T: type,
        buf: []u8,
        comptime free_func: ?typed_array.FreeBufferDataFunc(T),
        userdata: Opaque(T),
        is_shared: bool,
    ) Value {
        return fromCVal(c.JS_NewArrayBuffer(
            ctx.cval(),
            buf.ptr,
            buf.len,
            if (free_func) |f| typed_array.wrapFreeBufferDataFunc(T, f) else null,
            opaquepkg.toC(T, userdata),
            is_shared,
        ));
    }

    /// Creates an ArrayBuffer by copying the given data.
    ///
    /// C: `JS_NewArrayBufferCopy`
    pub fn initArrayBufferCopy(ctx: *Context, buf: []const u8) Value {
        return fromCVal(c.JS_NewArrayBufferCopy(ctx.cval(), buf.ptr, buf.len));
    }

    /// Creates a typed array of the specified type.
    ///
    /// The args should contain constructor arguments (e.g., length or ArrayBuffer).
    ///
    /// C: `JS_NewTypedArray`
    pub fn initTypedArray(
        ctx: *Context,
        args: []const Value,
        array_type: typed_array.Type,
    ) Value {
        return fromCVal(c.JS_NewTypedArray(
            ctx.cval(),
            @intCast(args.len),
            @ptrCast(@constCast(args.ptr)),
            @intFromEnum(array_type),
        ));
    }

    /// Creates a Uint8Array with the given data.
    ///
    /// The buffer takes ownership of the data. When the array is garbage
    /// collected, free_func will be called (if provided) to free the data.
    ///
    /// C: `JS_NewUint8Array`
    pub fn initUint8Array(
        ctx: *Context,
        buf: []u8,
        free_func: ?typed_array.FreeBufferDataFunc,
        opaque_ptr: ?*anyopaque,
        is_shared: bool,
    ) Value {
        return fromCVal(c.JS_NewUint8Array(
            ctx.cval(),
            buf.ptr,
            buf.len,
            @ptrCast(free_func),
            opaque_ptr,
            is_shared,
        ));
    }

    /// Creates a Uint8Array by copying the given data.
    ///
    /// C: `JS_NewUint8ArrayCopy`
    pub fn initUint8ArrayCopy(ctx: *Context, buf: []const u8) Value {
        return fromCVal(c.JS_NewUint8ArrayCopy(ctx.cval(), buf.ptr, buf.len));
    }

    // -----------------------------------------------------------------------
    // Reference Counting
    // -----------------------------------------------------------------------

    /// Duplicates the value, incrementing its reference count.
    ///
    /// The returned value must also be freed with `deinit`.
    ///
    /// C: `JS_DupValue`
    pub fn dup(self: Value, ctx: *Context) Value {
        return fromCVal(c.JS_DupValue(ctx.cval(), self.cval()));
    }

    /// Duplicates the value using the runtime, incrementing its reference count.
    ///
    /// The returned value must also be freed with `deinitRT`.
    ///
    /// C: `JS_DupValueRT`
    pub fn dupRT(self: Value, rt: *Runtime) Value {
        return fromCVal(c.JS_DupValueRT(rt.cval(), self.cval()));
    }

    /// Frees the JavaScript value.
    ///
    /// This decrements the reference count and frees the value if it
    /// reaches zero. Must be called for values returned from `eval`,
    /// property getters, and other functions that return owned values.
    ///
    /// C: `JS_FreeValue`
    pub fn deinit(self: Value, ctx: *Context) void {
        c.JS_FreeValue(ctx.cval(), self.cval());
    }

    /// Frees the JavaScript value using the runtime.
    ///
    /// C: `JS_FreeValueRT`
    pub fn deinitRT(self: Value, rt: *Runtime) void {
        c.JS_FreeValueRT(rt.cval(), self.cval());
    }

    // -----------------------------------------------------------------------
    // Type Predicates - Check JavaScript value types
    // -----------------------------------------------------------------------

    /// Checks if the value is `null`.
    ///
    /// C: `JS_IsNull`
    pub fn isNull(self: Value) bool {
        return c.JS_IsNull(self.cval());
    }

    /// Checks if the value is `undefined`.
    ///
    /// C: `JS_IsUndefined`
    pub fn isUndefined(self: Value) bool {
        return c.JS_IsUndefined(self.cval());
    }

    /// Checks if the value is a boolean.
    ///
    /// C: `JS_IsBool`
    pub fn isBool(self: Value) bool {
        return c.JS_IsBool(self.cval());
    }

    /// Checks if the value is a number (integer or float).
    ///
    /// C: `JS_IsNumber`
    pub fn isNumber(self: Value) bool {
        return c.JS_IsNumber(self.cval());
    }

    /// Checks if the value is a BigInt.
    ///
    /// C: `JS_IsBigInt`
    pub fn isBigInt(self: Value) bool {
        return c.JS_IsBigInt(self.cval());
    }

    /// Checks if the value is a string.
    ///
    /// C: `JS_IsString`
    pub fn isString(self: Value) bool {
        return c.JS_IsString(self.cval());
    }

    /// Checks if the value is a symbol.
    ///
    /// C: `JS_IsSymbol`
    pub fn isSymbol(self: Value) bool {
        return c.JS_IsSymbol(self.cval());
    }

    /// Checks if the value is an object.
    ///
    /// C: `JS_IsObject`
    pub fn isObject(self: Value) bool {
        return c.JS_IsObject(self.cval());
    }

    /// Checks if the value is an exception.
    ///
    /// C: `JS_IsException`
    pub fn isException(self: Value) bool {
        return c.JS_IsException(self.cval());
    }

    /// Checks if the value is uninitialized.
    ///
    /// C: `JS_IsUninitialized`
    pub fn isUninitialized(self: Value) bool {
        return c.JS_IsUninitialized(self.cval());
    }

    /// Checks if the value is a module.
    ///
    /// C: `JS_IsModule`
    pub fn isModule(self: Value) bool {
        return c.JS_IsModule(self.cval());
    }

    /// Resolves module dependencies.
    ///
    /// Call this after reading a module with `JS_ReadObject` to load its
    /// dependencies before evaluation.
    ///
    /// Returns error if resolution fails.
    ///
    /// C: `JS_ResolveModule`
    pub fn resolveModule(self: Value, ctx: *Context) !void {
        if (c.JS_ResolveModule(ctx.cval(), self.cval()) < 0) {
            return error.ModuleResolutionFailed;
        }
    }

    /// Checks if the value is an array.
    ///
    /// C: `JS_IsArray`
    pub fn isArray(self: Value) bool {
        return c.JS_IsArray(self.cval());
    }

    /// Checks if the value is a Proxy.
    ///
    /// C: `JS_IsProxy`
    pub fn isProxy(self: Value) bool {
        return c.JS_IsProxy(self.cval());
    }

    /// Checks if the value is a Date.
    ///
    /// C: `JS_IsDate`
    pub fn isDate(self: Value) bool {
        return c.JS_IsDate(self.cval());
    }

    /// Checks if the value is a Promise.
    ///
    /// C: `JS_IsPromise`
    pub fn isPromise(self: Value) bool {
        return c.JS_IsPromise(self.cval());
    }

    /// Checks if the value is an Error object.
    ///
    /// C: `JS_IsError`
    pub fn isError(self: Value) bool {
        return c.JS_IsError(self.cval());
    }

    /// Checks if the value is an uncatchable error.
    ///
    /// C: `JS_IsUncatchableError`
    pub fn isUncatchableError(self: Value) bool {
        return c.JS_IsUncatchableError(self.cval());
    }

    /// Checks if the value is an ArrayBuffer.
    ///
    /// C: `JS_IsArrayBuffer`
    pub fn isArrayBuffer(self: Value) bool {
        return c.JS_IsArrayBuffer(self.cval());
    }

    /// Checks if the value is a RegExp.
    ///
    /// C: `JS_IsRegExp`
    pub fn isRegExp(self: Value) bool {
        return c.JS_IsRegExp(self.cval());
    }

    /// Checks if the value is a Map.
    ///
    /// C: `JS_IsMap`
    pub fn isMap(self: Value) bool {
        return c.JS_IsMap(self.cval());
    }

    /// Checks if the value is a Set.
    ///
    /// C: `JS_IsSet`
    pub fn isSet(self: Value) bool {
        return c.JS_IsSet(self.cval());
    }

    /// Checks if the value is a WeakRef.
    ///
    /// C: `JS_IsWeakRef`
    pub fn isWeakRef(self: Value) bool {
        return c.JS_IsWeakRef(self.cval());
    }

    /// Checks if the value is a WeakSet.
    ///
    /// C: `JS_IsWeakSet`
    pub fn isWeakSet(self: Value) bool {
        return c.JS_IsWeakSet(self.cval());
    }

    /// Checks if the value is a WeakMap.
    ///
    /// C: `JS_IsWeakMap`
    pub fn isWeakMap(self: Value) bool {
        return c.JS_IsWeakMap(self.cval());
    }

    /// Checks if the value is a DataView.
    ///
    /// C: `JS_IsDataView`
    pub fn isDataView(self: Value) bool {
        return c.JS_IsDataView(self.cval());
    }

    /// Checks if the value is a function.
    ///
    /// Requires context because this checks internal object state.
    ///
    /// C: `JS_IsFunction`
    pub fn isFunction(self: Value, ctx: *Context) bool {
        return c.JS_IsFunction(ctx.cval(), self.cval());
    }

    /// Checks if the value is a constructor.
    ///
    /// Requires context because this checks internal object state.
    ///
    /// C: `JS_IsConstructor`
    pub fn isConstructor(self: Value, ctx: *Context) bool {
        return c.JS_IsConstructor(ctx.cval(), self.cval());
    }

    // -----------------------------------------------------------------------
    // ArrayBuffer & TypedArray Operations
    // -----------------------------------------------------------------------

    /// Detaches the ArrayBuffer, making it unusable.
    ///
    /// After detaching, the buffer's byteLength becomes 0 and any views
    /// on it become unusable.
    ///
    /// C: `JS_DetachArrayBuffer`
    pub fn detachArrayBuffer(self: Value, ctx: *Context) void {
        c.JS_DetachArrayBuffer(ctx.cval(), self.cval());
    }

    /// Gets the underlying data of an ArrayBuffer.
    ///
    /// Returns null if the value is not an ArrayBuffer or is detached.
    ///
    /// C: `JS_GetArrayBuffer`
    pub fn getArrayBuffer(self: Value, ctx: *Context) ?[]u8 {
        var size: usize = 0;
        const ptr = c.JS_GetArrayBuffer(ctx.cval(), &size, self.cval());
        if (ptr == null) return null;
        return ptr[0..size];
    }

    /// Gets the underlying data of a Uint8Array.
    ///
    /// Returns null if the value is not a Uint8Array or its buffer is detached.
    ///
    /// C: `JS_GetUint8Array`
    pub fn getUint8Array(self: Value, ctx: *Context) ?[]u8 {
        var size: usize = 0;
        const ptr = c.JS_GetUint8Array(ctx.cval(), &size, self.cval());
        if (ptr == null) return null;
        return ptr[0..size];
    }

    /// Gets the underlying ArrayBuffer of a typed array.
    ///
    /// Returns the buffer value along with offset, length, and element size info.
    /// The returned buffer value must be freed with deinit.
    ///
    /// C: `JS_GetTypedArrayBuffer`
    pub fn getTypedArrayBuffer(self: Value, ctx: *Context) ?typed_array.Buffer {
        var byte_offset: usize = 0;
        var byte_length: usize = 0;
        var bytes_per_element: usize = 0;
        const buffer = fromCVal(c.JS_GetTypedArrayBuffer(
            ctx.cval(),
            self.cval(),
            &byte_offset,
            &byte_length,
            &bytes_per_element,
        ));
        if (buffer.isException()) return null;
        return .{
            .value = buffer,
            .byte_offset = byte_offset,
            .byte_length = byte_length,
            .bytes_per_element = bytes_per_element,
        };
    }

    /// Gets the type of a typed array.
    ///
    /// Returns null if the value is not a typed array.
    ///
    /// C: `JS_GetTypedArrayType`
    pub fn getTypedArrayType(self: Value) ?typed_array.Type {
        const result = c.JS_GetTypedArrayType(self.cval());
        if (result < 0) return null;
        return @enumFromInt(@as(c_uint, @intCast(result)));
    }

    // -----------------------------------------------------------------------
    // Type Conversions - Convert JavaScript values to native types
    // -----------------------------------------------------------------------

    /// Converts the value to a boolean.
    ///
    /// C: `JS_ToBool`
    pub fn toBool(self: Value, ctx: *Context) error{JSError}!bool {
        const result = c.JS_ToBool(ctx.cval(), self.cval());
        if (result < 0) return error.JSError;
        return result != 0;
    }

    /// Converts the value to a 32-bit integer.
    ///
    /// Returns an error if the value cannot be converted to an integer.
    ///
    /// C: `JS_ToInt32`
    pub fn toInt32(self: Value, ctx: *Context) error{JSError}!i32 {
        var result: i32 = undefined;
        const ret = c.JS_ToInt32(ctx.cval(), &result, self.cval());
        if (ret != 0) return error.JSError;
        return result;
    }

    /// Converts the value to an unsigned 32-bit integer.
    ///
    /// Returns an error if the value cannot be converted.
    ///
    /// C: `JS_ToUint32`
    pub fn toUint32(self: Value, ctx: *Context) error{JSError}!u32 {
        var result: u32 = undefined;
        const ret = c.JS_ToUint32(ctx.cval(), &result, self.cval());
        if (ret != 0) return error.JSError;
        return result;
    }

    /// Converts the value to a 64-bit integer.
    ///
    /// C: `JS_ToInt64`
    pub fn toInt64(self: Value, ctx: *Context) error{JSError}!i64 {
        var result: i64 = undefined;
        const ret = c.JS_ToInt64(ctx.cval(), &result, self.cval());
        if (ret != 0) return error.JSError;
        return result;
    }

    /// Converts the value to an array/string index.
    ///
    /// C: `JS_ToIndex`
    pub fn toIndex(self: Value, ctx: *Context) error{JSError}!u64 {
        var result: u64 = undefined;
        const ret = c.JS_ToIndex(ctx.cval(), &result, self.cval());
        if (ret != 0) return error.JSError;
        return result;
    }

    /// Converts the value to a 64-bit float.
    ///
    /// C: `JS_ToFloat64`
    pub fn toFloat64(self: Value, ctx: *Context) error{JSError}!f64 {
        var result: f64 = undefined;
        const ret = c.JS_ToFloat64(ctx.cval(), &result, self.cval());
        if (ret != 0) return error.JSError;
        return result;
    }

    /// Converts the value to a BigInt as i64.
    ///
    /// Returns an error if the value is not a BigInt.
    ///
    /// C: `JS_ToBigInt64`
    pub fn toBigInt64(self: Value, ctx: *Context) error{JSError}!i64 {
        var result: i64 = undefined;
        const ret = c.JS_ToBigInt64(ctx.cval(), &result, self.cval());
        if (ret != 0) return error.JSError;
        return result;
    }

    /// Converts the value to a BigInt as u64.
    ///
    /// Returns an error if the value is not a BigInt.
    ///
    /// C: `JS_ToBigUint64`
    pub fn toBigUint64(self: Value, ctx: *Context) error{JSError}!u64 {
        var result: u64 = undefined;
        const ret = c.JS_ToBigUint64(ctx.cval(), &result, self.cval());
        if (ret != 0) return error.JSError;
        return result;
    }

    /// Converts the value to a JavaScript Number.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_ToNumber`
    pub fn toNumber(self: Value, ctx: *Context) Value {
        return fromCVal(c.JS_ToNumber(ctx.cval(), self.cval()));
    }

    /// Converts the value to a JavaScript String.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_ToString`
    pub fn toStringValue(self: Value, ctx: *Context) Value {
        return fromCVal(c.JS_ToString(ctx.cval(), self.cval()));
    }

    /// Converts the value to a JavaScript Object.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_ToObject`
    pub fn toObject(self: Value, ctx: *Context) Value {
        return fromCVal(c.JS_ToObject(ctx.cval(), self.cval()));
    }

    /// Converts the value to a property key.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_ToPropertyKey`
    pub fn toPropertyKey(self: Value, ctx: *Context) Value {
        return fromCVal(c.JS_ToPropertyKey(ctx.cval(), self.cval()));
    }

    /// Converts the value to a Zig string slice.
    ///
    /// Returns null if the conversion fails. The returned slice must be
    /// freed by passing the pointer to `Context.freeCString`.
    ///
    /// C: `JS_ToCStringLen`
    pub fn toZigSlice(self: Value, ctx: *Context) ?[:0]const u8 {
        const result = self.toCStringLen(ctx) orelse return null;
        return result.ptr[0..result.len :0];
    }

    /// Converts the value to a C string with length.
    ///
    /// Returns null if the conversion fails. The returned pointer must be
    /// freed with `Context.freeCString`.
    ///
    /// C: `JS_ToCStringLen`
    pub fn toCStringLen(self: Value, ctx: *Context) ?struct { ptr: [*:0]const u8, len: usize } {
        var len: usize = 0;
        const ptr = c.JS_ToCStringLen(ctx.cval(), &len, self.cval());
        if (ptr == null) return null;
        return .{ .ptr = ptr, .len = len };
    }

    /// Converts the value to a null-terminated C string.
    ///
    /// Returns null if the conversion fails. The returned pointer must be
    /// freed with `Context.freeCString`.
    ///
    /// C: `JS_ToCString`
    pub fn toCString(self: Value, ctx: *Context) ?[*:0]const u8 {
        return c.JS_ToCString(ctx.cval(), self.cval());
    }

    // -----------------------------------------------------------------------
    // Property Access
    // -----------------------------------------------------------------------

    /// Gets a property by atom.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_GetProperty`
    pub fn getProperty(self: Value, ctx: *Context, prop: Atom) Value {
        return fromCVal(c.JS_GetProperty(ctx.cval(), self.cval(), @intFromEnum(prop)));
    }

    /// Gets a property by string name.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_GetPropertyStr`
    pub fn getPropertyStr(self: Value, ctx: *Context, name: [*:0]const u8) Value {
        return fromCVal(c.JS_GetPropertyStr(ctx.cval(), self.cval(), name));
    }

    /// Gets a property by integer index.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_GetPropertyUint32`
    pub fn getPropertyUint32(self: Value, ctx: *Context, idx: u32) Value {
        return fromCVal(c.JS_GetPropertyUint32(ctx.cval(), self.cval(), idx));
    }

    /// Gets a property by 64-bit integer index.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_GetPropertyInt64`
    pub fn getPropertyInt64(self: Value, ctx: *Context, idx: i64) Value {
        return fromCVal(c.JS_GetPropertyInt64(ctx.cval(), self.cval(), idx));
    }

    /// Sets a property by atom.
    ///
    /// Takes ownership of the value.
    ///
    /// C: `JS_SetProperty`
    pub fn setProperty(self: Value, ctx: *Context, prop: Atom, val: Value) error{JSError}!void {
        const ret = c.JS_SetProperty(ctx.cval(), self.cval(), @intFromEnum(prop), val.cval());
        if (ret < 0) return error.JSError;
    }

    /// Sets a property by string name.
    ///
    /// Takes ownership of the value.
    ///
    /// C: `JS_SetPropertyStr`
    pub fn setPropertyStr(self: Value, ctx: *Context, name: [*:0]const u8, val: Value) error{JSError}!void {
        const ret = c.JS_SetPropertyStr(ctx.cval(), self.cval(), name, val.cval());
        if (ret < 0) return error.JSError;
    }

    /// Sets a property by integer index.
    ///
    /// Takes ownership of the value.
    ///
    /// C: `JS_SetPropertyUint32`
    pub fn setPropertyUint32(self: Value, ctx: *Context, idx: u32, val: Value) error{JSError}!void {
        const ret = c.JS_SetPropertyUint32(ctx.cval(), self.cval(), idx, val.cval());
        if (ret < 0) return error.JSError;
    }

    /// Sets a property by 64-bit integer index.
    ///
    /// Takes ownership of the value.
    ///
    /// C: `JS_SetPropertyInt64`
    pub fn setPropertyInt64(self: Value, ctx: *Context, idx: i64, val: Value) error{JSError}!void {
        const ret = c.JS_SetPropertyInt64(ctx.cval(), self.cval(), idx, val.cval());
        if (ret < 0) return error.JSError;
    }

    /// Checks if the object has the specified property.
    ///
    /// C: `JS_HasProperty` (via string)
    pub fn hasPropertyStr(self: Value, ctx: *Context, name: [*:0]const u8) error{JSError}!bool {
        const atom = c.JS_NewAtom(ctx.cval(), name);
        defer c.JS_FreeAtom(ctx.cval(), atom);
        const ret = c.JS_HasProperty(ctx.cval(), self.cval(), atom);
        if (ret < 0) return error.JSError;
        return ret != 0;
    }

    /// Deletes a property by string name.
    ///
    /// C: `JS_DeleteProperty`
    pub fn deletePropertyStr(self: Value, ctx: *Context, name: [*:0]const u8) error{JSError}!bool {
        const atom = c.JS_NewAtom(ctx.cval(), name);
        defer c.JS_FreeAtom(ctx.cval(), atom);
        const ret = c.JS_DeleteProperty(ctx.cval(), self.cval(), atom, 0);
        if (ret < 0) return error.JSError;
        return ret != 0;
    }

    /// Gets the prototype of an object.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_GetPrototype`
    pub fn getPrototype(self: Value, ctx: *Context) Value {
        return fromCVal(c.JS_GetPrototype(ctx.cval(), self.cval()));
    }

    /// Sets the prototype of an object.
    ///
    /// C: `JS_SetPrototype`
    pub fn setPrototype(self: Value, ctx: *Context, proto: Value) error{JSError}!void {
        const ret = c.JS_SetPrototype(ctx.cval(), self.cval(), proto.cval());
        if (ret < 0) return error.JSError;
    }

    /// Sets the constructor for a function object.
    ///
    /// This links a constructor function with its prototype object.
    /// After calling this, instances created with `new func()` will have
    /// `proto` as their prototype, and `proto.constructor` will be set to `func`.
    ///
    /// C: `JS_SetConstructor`
    pub fn setConstructor(self: Value, ctx: *Context, proto: Value) void {
        c.JS_SetConstructor(ctx.cval(), self.cval(), proto.cval());
    }

    /// Sets the constructor bit on a function object.
    ///
    /// This controls whether the function can be used as a constructor with `new`.
    ///
    /// C: `JS_SetConstructorBit`
    pub fn setConstructorBit(self: Value, ctx: *Context, val: bool) bool {
        return c.JS_SetConstructorBit(ctx.cval(), self.cval(), val);
    }

    /// Defines multiple properties on an object from a function list.
    ///
    /// This is efficient for defining many properties at once (functions, getters/setters, constants).
    ///
    /// C: `JS_SetPropertyFunctionList`
    pub fn setPropertyFunctionList(
        self: Value,
        ctx: *Context,
        list: []const cfunc.FunctionListEntry,
    ) error{JSError}!void {
        const ret = c.JS_SetPropertyFunctionList(
            ctx.cval(),
            self.cval(),
            @ptrCast(list.ptr),
            @intCast(list.len),
        );
        if (ret < 0) return error.JSError;
    }

    /// Gets the length property of an array or array-like object.
    ///
    /// C: `JS_GetLength`
    pub fn getLength(self: Value, ctx: *Context) error{JSError}!i64 {
        var result: i64 = undefined;
        const ret = c.JS_GetLength(ctx.cval(), self.cval(), &result);
        if (ret < 0) return error.JSError;
        return result;
    }

    /// Sets the length property of an array or array-like object.
    ///
    /// C: `JS_SetLength`
    pub fn setLength(self: Value, ctx: *Context, len: i64) error{JSError}!void {
        const ret = c.JS_SetLength(ctx.cval(), self.cval(), len);
        if (ret < 0) return error.JSError;
    }

    /// Checks if the object is extensible.
    ///
    /// C: `JS_IsExtensible`
    pub fn isExtensible(self: Value, ctx: *Context) error{JSError}!bool {
        const ret = c.JS_IsExtensible(ctx.cval(), self.cval());
        if (ret < 0) return error.JSError;
        return ret != 0;
    }

    /// Prevents any extensions to the object.
    ///
    /// C: `JS_PreventExtensions`
    pub fn preventExtensions(self: Value, ctx: *Context) error{JSError}!void {
        const ret = c.JS_PreventExtensions(ctx.cval(), self.cval());
        if (ret < 0) return error.JSError;
    }

    /// Seals the object (prevents adding new properties and marks existing ones non-configurable).
    ///
    /// C: `JS_SealObject`
    pub fn seal(self: Value, ctx: *Context) error{JSError}!void {
        const ret = c.JS_SealObject(ctx.cval(), self.cval());
        if (ret < 0) return error.JSError;
    }

    /// Freezes the object (seals it and makes all properties non-writable).
    ///
    /// C: `JS_FreezeObject`
    pub fn freeze(self: Value, ctx: *Context) error{JSError}!void {
        const ret = c.JS_FreezeObject(ctx.cval(), self.cval());
        if (ret < 0) return error.JSError;
    }

    // -----------------------------------------------------------------------
    // Property Definition
    // -----------------------------------------------------------------------

    /// Defines a property with full control over attributes.
    ///
    /// This is the most general form of property definition. Use the simpler
    /// definePropertyValue or definePropertyGetSet for common cases.
    ///
    /// C: `JS_DefineProperty`
    pub fn defineProperty(
        self: Value,
        ctx: *Context,
        prop: Atom,
        val: Value,
        getter: Value,
        setter: Value,
        flags: PropertyFlags,
    ) error{JSError}!bool {
        const ret = c.JS_DefineProperty(
            ctx.cval(),
            self.cval(),
            @intFromEnum(prop),
            val.cval(),
            getter.cval(),
            setter.cval(),
            flags.toInt(),
        );
        if (ret < 0) return error.JSError;
        return ret != 0;
    }

    /// Defines a data property with the given value and flags.
    ///
    /// Takes ownership of the value.
    ///
    /// C: `JS_DefinePropertyValue`
    pub fn definePropertyValue(
        self: Value,
        ctx: *Context,
        prop: Atom,
        val: Value,
        flags: PropertyFlags,
    ) error{JSError}!bool {
        const ret = c.JS_DefinePropertyValue(
            ctx.cval(),
            self.cval(),
            @intFromEnum(prop),
            val.cval(),
            flags.toInt(),
        );
        if (ret < 0) return error.JSError;
        return ret != 0;
    }

    /// Defines a data property at an integer index with the given value and flags.
    ///
    /// Takes ownership of the value.
    ///
    /// C: `JS_DefinePropertyValueUint32`
    pub fn definePropertyValueUint32(
        self: Value,
        ctx: *Context,
        idx: u32,
        val: Value,
        flags: PropertyFlags,
    ) error{JSError}!bool {
        const ret = c.JS_DefinePropertyValueUint32(
            ctx.cval(),
            self.cval(),
            idx,
            val.cval(),
            flags.toInt(),
        );
        if (ret < 0) return error.JSError;
        return ret != 0;
    }

    /// Defines a data property by string name with the given value and flags.
    ///
    /// Takes ownership of the value.
    ///
    /// C: `JS_DefinePropertyValueStr`
    pub fn definePropertyValueStr(
        self: Value,
        ctx: *Context,
        name: [*:0]const u8,
        val: Value,
        flags: PropertyFlags,
    ) error{JSError}!bool {
        const ret = c.JS_DefinePropertyValueStr(
            ctx.cval(),
            self.cval(),
            name,
            val.cval(),
            flags.toInt(),
        );
        if (ret < 0) return error.JSError;
        return ret != 0;
    }

    /// Defines an accessor property with getter and/or setter.
    ///
    /// Takes ownership of getter and setter values.
    ///
    /// C: `JS_DefinePropertyGetSet`
    pub fn definePropertyGetSet(
        self: Value,
        ctx: *Context,
        prop: Atom,
        getter: Value,
        setter: Value,
        flags: PropertyFlags,
    ) error{JSError}!bool {
        const ret = c.JS_DefinePropertyGetSet(
            ctx.cval(),
            self.cval(),
            @intFromEnum(prop),
            getter.cval(),
            setter.cval(),
            flags.toInt(),
        );
        if (ret < 0) return error.JSError;
        return ret != 0;
    }

    /// Gets the own property names of an object.
    ///
    /// Returns an iterator over the property names. The iterator must be
    /// freed with `freePropertyEnum` when done.
    ///
    /// C: `JS_GetOwnPropertyNames`
    pub fn getOwnPropertyNames(
        self: Value,
        ctx: *Context,
        flags: GetPropertyNamesFlags,
    ) error{JSError}![]const PropertyEnum {
        var tab: [*]PropertyEnum = undefined;
        var len: u32 = 0;
        const ret = c.JS_GetOwnPropertyNames(
            ctx.cval(),
            @ptrCast(&tab),
            &len,
            self.cval(),
            flags.toInt(),
        );
        if (ret < 0) return error.JSError;
        return tab[0..len];
    }

    /// Frees a property enum slice returned by `getOwnPropertyNames`.
    ///
    /// C: `JS_FreePropertyEnum`
    pub fn freePropertyEnum(ctx: *Context, props: []const PropertyEnum) void {
        c.JS_FreePropertyEnum(ctx.cval(), @ptrCast(@constCast(props.ptr)), @intCast(props.len));
    }

    /// Gets the own property descriptor for a property.
    ///
    /// Returns null if the property does not exist.
    /// The returned descriptor's values must be freed with deinit.
    ///
    /// C: `JS_GetOwnProperty`
    pub fn getOwnProperty(
        self: Value,
        ctx: *Context,
        prop: Atom,
    ) error{JSError}!?PropertyDescriptor {
        var desc: PropertyDescriptor = undefined;
        const ret = c.JS_GetOwnProperty(ctx.cval(), @ptrCast(&desc), self.cval(), @intFromEnum(prop));
        if (ret < 0) return error.JSError;
        if (ret == 0) return null;
        return desc;
    }

    // -----------------------------------------------------------------------
    // Comparison
    // -----------------------------------------------------------------------

    /// Checks if two values are equal (using JavaScript `==`).
    ///
    /// C: `JS_IsEqual`
    pub fn isEqual(self: Value, ctx: *Context, other: Value) error{JSError}!bool {
        const ret = c.JS_IsEqual(ctx.cval(), self.cval(), other.cval());
        if (ret < 0) return error.JSError;
        return ret != 0;
    }

    /// Checks if two values are strictly equal (using JavaScript `===`).
    ///
    /// C: `JS_IsStrictEqual`
    pub fn isStrictEqual(self: Value, ctx: *Context, other: Value) bool {
        return c.JS_IsStrictEqual(ctx.cval(), self.cval(), other.cval());
    }

    /// Checks if two values are the same value (Object.is semantics).
    ///
    /// C: `JS_IsSameValue`
    pub fn isSameValue(self: Value, ctx: *Context, other: Value) bool {
        return c.JS_IsSameValue(ctx.cval(), self.cval(), other.cval());
    }

    /// Checks if two values are the same value, treating +0 and -0 as equal.
    ///
    /// C: `JS_IsSameValueZero`
    pub fn isSameValueZero(self: Value, ctx: *Context, other: Value) bool {
        return c.JS_IsSameValueZero(ctx.cval(), self.cval(), other.cval());
    }

    /// Checks if this value is an instance of a constructor.
    ///
    /// C: `JS_IsInstanceOf`
    pub fn isInstanceOf(self: Value, ctx: *Context, obj: Value) error{JSError}!bool {
        const ret = c.JS_IsInstanceOf(ctx.cval(), self.cval(), obj.cval());
        if (ret < 0) return error.JSError;
        return ret != 0;
    }

    // -----------------------------------------------------------------------
    // Function Calls
    // -----------------------------------------------------------------------

    /// Calls a function with the given this value and arguments.
    ///
    /// Returns a new Value that must be freed. Check `isException` for errors.
    ///
    /// C: `JS_Call`
    pub fn call(self: Value, ctx: *Context, this: Value, args: []const Value) Value {
        return fromCVal(c.JS_Call(
            ctx.cval(),
            self.cval(),
            this.cval(),
            @intCast(args.len),
            @ptrCast(@constCast(args.ptr)),
        ));
    }

    /// Calls a constructor function with the given arguments.
    ///
    /// Returns a new Value that must be freed. Check `isException` for errors.
    ///
    /// C: `JS_CallConstructor`
    pub fn callConstructor(self: Value, ctx: *Context, args: []const Value) Value {
        return fromCVal(c.JS_CallConstructor(
            ctx.cval(),
            self.cval(),
            @intCast(args.len),
            @ptrCast(args.ptr),
        ));
    }

    /// Calls a constructor function with a custom `new.target`.
    ///
    /// This allows specifying a different `new.target` value than the
    /// constructor function itself.
    ///
    /// Returns a new Value that must be freed. Check `isException` for errors.
    ///
    /// C: `JS_CallConstructor2`
    pub fn callConstructor2(self: Value, ctx: *Context, new_target: Value, args: []const Value) Value {
        return fromCVal(c.JS_CallConstructor2(
            ctx.cval(),
            self.cval(),
            new_target.cval(),
            @intCast(args.len),
            @ptrCast(@constCast(args.ptr)),
        ));
    }

    /// Invokes a method on this value by atom.
    ///
    /// This is equivalent to `this[method_name](...args)` in JavaScript.
    ///
    /// Returns a new Value that must be freed. Check `isException` for errors.
    ///
    /// C: `JS_Invoke`
    pub fn invoke(self: Value, ctx: *Context, method: Atom, args: []const Value) Value {
        return fromCVal(c.JS_Invoke(
            ctx.cval(),
            self.cval(),
            @intFromEnum(method),
            @intCast(args.len),
            @ptrCast(@constCast(args.ptr)),
        ));
    }

    // -----------------------------------------------------------------------
    // JSON
    // -----------------------------------------------------------------------

    /// Parses a JSON string into a JavaScript value.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_ParseJSON`
    pub fn parseJSON(ctx: *Context, buf: []const u8, filename: [*:0]const u8) Value {
        return fromCVal(c.JS_ParseJSON(ctx.cval(), buf.ptr, buf.len, filename));
    }

    /// Converts a JavaScript value to a JSON string.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_JSONStringify`
    pub fn jsonStringify(self: Value, ctx: *Context, replacer: Value, space: Value) Value {
        return fromCVal(c.JS_JSONStringify(ctx.cval(), self.cval(), replacer.cval(), space.cval()));
    }

    // -----------------------------------------------------------------------
    // Proxy
    // -----------------------------------------------------------------------

    /// Creates a new Proxy object.
    ///
    /// C: `JS_NewProxy`
    pub fn initProxy(ctx: *Context, target: Value, handler: Value) Value {
        return fromCVal(c.JS_NewProxy(ctx.cval(), target.cval(), handler.cval()));
    }

    /// Gets the target of a Proxy object.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_GetProxyTarget`
    pub fn getProxyTarget(self: Value, ctx: *Context) Value {
        return fromCVal(c.JS_GetProxyTarget(ctx.cval(), self.cval()));
    }

    /// Gets the handler of a Proxy object.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_GetProxyHandler`
    pub fn getProxyHandler(self: Value, ctx: *Context) Value {
        return fromCVal(c.JS_GetProxyHandler(ctx.cval(), self.cval()));
    }

    // -----------------------------------------------------------------------
    // Exceptions
    // -----------------------------------------------------------------------

    /// Throws this value as an exception.
    ///
    /// Takes ownership of the value.
    ///
    /// C: `JS_Throw`
    pub fn throw(self: Value, ctx: *Context) Value {
        return fromCVal(c.JS_Throw(ctx.cval(), self.cval()));
    }

    /// Marks this error as uncatchable.
    ///
    /// C: `JS_SetUncatchableError`
    pub fn setUncatchableError(self: Value, ctx: *Context) void {
        c.JS_SetUncatchableError(ctx.cval(), self.cval());
    }

    /// Clears the uncatchable flag on this error.
    ///
    /// C: `JS_ClearUncatchableError`
    pub fn clearUncatchableError(self: Value, ctx: *Context) void {
        c.JS_ClearUncatchableError(ctx.cval(), self.cval());
    }

    // -----------------------------------------------------------------------
    // Promise
    // -----------------------------------------------------------------------

    /// Gets the state of a promise.
    ///
    /// C: `JS_PromiseState`
    pub fn promiseState(self: Value, ctx: *Context) PromiseState {
        return @enumFromInt(c.JS_PromiseState(ctx.cval(), self.cval()));
    }

    /// Gets the result of a fulfilled or rejected promise.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_PromiseResult`
    pub fn promiseResult(self: Value, ctx: *Context) Value {
        return fromCVal(c.JS_PromiseResult(ctx.cval(), self.cval()));
    }

    /// A promise with its resolve/reject capability functions.
    pub const Promise = struct {
        value: Value,
        resolve: Value,
        reject: Value,

        /// Deinitializes all three values.
        pub fn deinit(self: Promise, ctx: *Context) void {
            self.value.deinit(ctx);
            self.resolve.deinit(ctx);
            self.reject.deinit(ctx);
        }
    };

    /// Creates a new Promise with its resolve/reject functions.
    ///
    /// Returns a Promise struct containing the promise value and its
    /// resolve/reject functions. All three values must be freed when
    /// no longer needed (or call `Promise.deinit` to free all at once).
    ///
    /// C: `JS_NewPromiseCapability`
    pub fn initPromiseCapability(ctx: *Context) Promise {
        var resolving_funcs: [2]Value = undefined;
        const promise = fromCVal(c.JS_NewPromiseCapability(ctx.cval(), @ptrCast(&resolving_funcs)));
        return .{
            .value = promise,
            .resolve = resolving_funcs[0],
            .reject = resolving_funcs[1],
        };
    }

    // -----------------------------------------------------------------------
    // Class / Opaque data
    // -----------------------------------------------------------------------

    /// Gets the class ID of an object.
    ///
    /// Returns `class.Id.invalid` if not an object.
    ///
    /// C: `JS_GetClassID`
    pub fn getClassId(self: Value) class.Id {
        return @enumFromInt(c.JS_GetClassID(self.cval()));
    }

    /// Sets opaque data on an object.
    ///
    /// Only works for custom class objects. Returns true on success.
    ///
    /// C: `JS_SetOpaque`
    pub fn setOpaque(self: Value, opaque_ptr: ?*anyopaque) bool {
        return c.JS_SetOpaque(self.cval(), opaque_ptr) == 0;
    }

    /// Gets opaque data from an object.
    ///
    /// Returns null if the object is not of the expected class or has no opaque data.
    ///
    /// C: `JS_GetOpaque`
    pub fn getOpaque(self: Value, comptime T: type, class_id: class.Id) ?*T {
        return @ptrCast(@alignCast(c.JS_GetOpaque(self.cval(), @intFromEnum(class_id))));
    }

    /// Gets opaque data from an object with context validation.
    ///
    /// Throws a JavaScript exception if the object is not of the expected class.
    ///
    /// C: `JS_GetOpaque2`
    pub fn getOpaque2(self: Value, ctx: *Context, comptime T: type, class_id: class.Id) ?*T {
        return @ptrCast(@alignCast(c.JS_GetOpaque2(ctx.cval(), self.cval(), @intFromEnum(class_id))));
    }

    /// Gets opaque data from an object without knowing the class ID.
    ///
    /// Returns both the opaque pointer and the class ID of the object.
    ///
    /// C: `JS_GetAnyOpaque`
    pub fn getAnyOpaque(self: Value, comptime T: type) struct { ptr: ?*T, class_id: class.Id } {
        var raw_class_id: u32 = 0;
        const ptr = c.JS_GetAnyOpaque(self.cval(), &raw_class_id);
        return .{
            .ptr = @ptrCast(@alignCast(ptr)),
            .class_id = @enumFromInt(raw_class_id),
        };
    }

    // -----------------------------------------------------------------------
    // C Interop
    // -----------------------------------------------------------------------

    /// Initialize a Value from a C JSValue.
    pub inline fn fromCVal(val: c.JSValue) Value {
        return @bitCast(val);
    }

    /// Get the underlying C JSValue representation.
    pub inline fn cval(self: Value) c.JSValue {
        return @bitCast(self);
    }

    // -----------------------------------------------------------------------
    // NaN-boxing helpers (implementation details)
    //
    // On 32-bit platforms, QuickJS uses NaN-boxing to pack values into a u64:
    // - Upper 32 bits: tag
    // - Lower 32 bits: int32/bool value or pointer
    // - Floats use a special encoding with JS_FLOAT64_TAG_ADDEND
    //
    // See quickjs.h under `#if defined(JS_NAN_BOXING)` for the C implementation.
    // -----------------------------------------------------------------------

    /// Constructs a nan-boxed value from a tag and 32-bit payload.
    ///
    /// C: `JS_MKVAL(tag, val)` macro in quickjs.h
    fn mkval(t: Tag, val: i32) u64 {
        const tag: u64 = @bitCast(@as(i64, @intFromEnum(t)));
        return (tag << 32) | @as(u32, @bitCast(val));
    }

    /// Addend used for encoding floats in nan-boxed representation.
    /// Floats are stored with their bits adjusted by this value to avoid
    /// colliding with the tag space.
    ///
    /// C: `JS_FLOAT64_TAG_ADDEND` macro in quickjs.h
    const float64_tag_addend: u64 = 0x7ff80000 -% @as(u64, @bitCast(@as(i64, c.JS_TAG_FIRST))) +% 1;

    /// Constructs a nan-boxed float64 value, normalizing NaN to a canonical form.
    ///
    /// C: `__JS_NewFloat64(double d)` function in quickjs.h
    fn mkfloat64(val: f64) u64 {
        const u: u64 = @bitCast(val);
        const nan_val = 0x7ff8000000000000 -% (float64_tag_addend << 32);
        if ((u & 0x7fffffffffffffff) > 0x7ff0000000000000) {
            return nan_val;
        }
        return u -% (float64_tag_addend << 32);
    }
};

/// Promise state enumeration.
pub const PromiseState = enum(c_int) {
    not_a_promise = -1,
    pending = 0,
    fulfilled = 1,
    rejected = 2,
};

/// Property type, encoded in the `tmask` field of `PropertyFlags`.
///
/// C: `JS_PROP_NORMAL`, `JS_PROP_GETSET`, `JS_PROP_VARREF`, `JS_PROP_AUTOINIT`
pub const PropertyType = enum(u2) {
    /// Regular data property with a value.
    normal = 0,
    /// Accessor property with getter and/or setter functions.
    getset = 1,
    /// Internal: references a closure variable.
    varref = 2,
    /// Internal: lazy-initialized property.
    autoinit = 3,
};

/// Property attribute flags for defining and querying object properties.
///
/// These flags correspond to the `JS_PROP_*` C constants in QuickJS.
/// Used with defineProperty* methods to control property attributes.
///
/// ## Attribute Flags vs. HAS Flags
///
/// The `has_*` flags indicate **whether an attribute is being specified**, while the base
/// flags contain the **actual value**. This mirrors `Object.defineProperty` behavior where
/// omitting an attribute leaves the existing value intact. For example, without
/// `has_configurable`, the engine doesn't know if you want `configurable: false` or if you
/// simply didn't specify it.
pub const PropertyFlags = packed struct(c_int) {
    /// Property can be deleted and its attributes can be changed.
    configurable: bool = false,
    /// Property value can be modified (data properties only).
    writable: bool = false,
    /// Property appears in `for...in` loops and `Object.keys()`.
    enumerable: bool = false,
    /// Internal flag for Array `length` property (special setter behavior).
    length: bool = false,
    /// The property type (normal, getset, varref, or autoinit).
    property_type: PropertyType = .normal,
    _reserved1: u2 = 0,
    /// When set, the `configurable` field value should be applied.
    has_configurable: bool = false,
    /// When set, the `writable` field value should be applied.
    has_writable: bool = false,
    /// When set, the `enumerable` field value should be applied.
    has_enumerable: bool = false,
    /// When set, a getter function is being provided.
    has_get: bool = false,
    /// When set, a setter function is being provided.
    has_set: bool = false,
    /// When set, a value is being provided.
    has_value: bool = false,
    /// Throw an exception instead of returning false on failure.
    throw_flag: bool = false,
    /// Throw an exception on failure only in strict mode.
    throw_strict: bool = false,
    /// Internal: don't add the property if it doesn't exist.
    no_add: bool = false,
    /// Internal: skip exotic object behavior.
    no_exotic: bool = false,
    /// Internal: called from `Object.defineProperty`.
    define_property: bool = false,
    /// Internal: called from `Reflect.defineProperty`.
    reflect_define_property: bool = false,
    _reserved2: u12 = 0,

    /// Standard data property flags (configurable, writable, enumerable).
    ///
    /// C: `JS_PROP_C_W_E`
    pub const default: PropertyFlags = .{
        .configurable = true,
        .writable = true,
        .enumerable = true,
    };

    pub fn toInt(self: PropertyFlags) c_int {
        return @bitCast(self);
    }
};

/// Flags for `getOwnPropertyNames` to control which property keys are returned.
///
/// These flags correspond to the `JS_GPN_*` C constants in QuickJS.
///
/// ## Common Patterns
///
/// - `Object.keys()`: `.enum_strings` (enumerable string keys only)
/// - `Object.getOwnPropertyNames()`: `.strings` (all string keys)
/// - `Object.getOwnPropertySymbols()`: `.symbols` (all symbol keys)
/// - `Reflect.ownKeys()`: `.all` (all keys: strings + symbols)
pub const GetPropertyNamesFlags = packed struct(c_int) {
    /// Include string-keyed properties (normal property names).
    string_mask: bool = false,
    /// Include symbol-keyed properties.
    symbol_mask: bool = false,
    /// Include private class fields (internal use).
    private_mask: bool = false,
    _reserved1: u1 = 0,
    /// Only include enumerable properties.
    enum_only: bool = false,
    /// Populate the `is_enumerable` field in returned `PropertyEnum` structs.
    set_enum: bool = false,
    _reserved2: u26 = 0,

    /// All string property keys. Equivalent to `Object.getOwnPropertyNames()`.
    pub const strings: GetPropertyNamesFlags = .{ .string_mask = true };

    /// All symbol property keys. Equivalent to `Object.getOwnPropertySymbols()`.
    pub const symbols: GetPropertyNamesFlags = .{ .symbol_mask = true };

    /// All property keys (strings and symbols). Equivalent to `Reflect.ownKeys()`.
    pub const all: GetPropertyNamesFlags = .{ .string_mask = true, .symbol_mask = true };

    /// Enumerable string keys only. Equivalent to `Object.keys()`.
    pub const enum_strings: GetPropertyNamesFlags = .{ .string_mask = true, .enum_only = true };

    pub fn toInt(self: GetPropertyNamesFlags) c_int {
        return @bitCast(self);
    }
};

/// Property descriptor returned by getOwnProperty.
///
/// C: `JSPropertyDescriptor`
pub const PropertyDescriptor = extern struct {
    flags: PropertyFlags,
    value: Value,
    getter: Value,
    setter: Value,

    /// Frees all values in the descriptor.
    pub fn deinit(self: *PropertyDescriptor, ctx: *Context) void {
        self.value.deinit(ctx);
        self.getter.deinit(ctx);
        self.setter.deinit(ctx);
    }
};

/// Property name entry returned by getOwnPropertyNames.
///
/// C: `JSPropertyEnum`
pub const PropertyEnum = extern struct {
    is_enumerable: bool,
    atom: Atom,
};

comptime {
    assert(@sizeOf(Value) == @sizeOf(c.JSValue));
    assert(@alignOf(Value) == @alignOf(c.JSValue));
    assert(@sizeOf(PropertyDescriptor) == @sizeOf(c.JSPropertyDescriptor));
    assert(@alignOf(PropertyDescriptor) == @alignOf(c.JSPropertyDescriptor));
    assert(@sizeOf(PropertyEnum) == @sizeOf(c.JSPropertyEnum));
    assert(@alignOf(PropertyEnum) == @alignOf(c.JSPropertyEnum));
}

test "constants match JavaScript values" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // Test null
    const js_null = ctx.eval("null", "<test>", .{});
    defer js_null.deinit(ctx);
    try testing.expect(js_null.isNull());
    try testing.expect(Value.@"null".isNull());
    try testing.expect(js_null.isStrictEqual(ctx, Value.@"null"));

    // Test undefined
    const js_undefined = ctx.eval("undefined", "<test>", .{});
    defer js_undefined.deinit(ctx);
    try testing.expect(js_undefined.isUndefined());
    try testing.expect(Value.undefined.isUndefined());
    try testing.expect(js_undefined.isStrictEqual(ctx, Value.undefined));

    // Test true
    const js_true = ctx.eval("true", "<test>", .{});
    defer js_true.deinit(ctx);
    try testing.expect(js_true.isBool());
    try testing.expect(try js_true.toBool(ctx));
    try testing.expect(try Value.true.toBool(ctx));
    try testing.expect(js_true.isStrictEqual(ctx, Value.true));

    // Test false
    const js_false = ctx.eval("false", "<test>", .{});
    defer js_false.deinit(ctx);
    try testing.expect(js_false.isBool());
    try testing.expect(!try js_false.toBool(ctx));
    try testing.expect(!try Value.false.toBool(ctx));
    try testing.expect(js_false.isStrictEqual(ctx, Value.false));
}

test "type predicates with JavaScript values" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // isNumber
    const num = ctx.eval("42", "<test>", .{});
    defer num.deinit(ctx);
    try testing.expect(num.isNumber());

    const float = ctx.eval("3.14", "<test>", .{});
    defer float.deinit(ctx);
    try testing.expect(float.isNumber());

    // isString
    const str = ctx.eval("'hello'", "<test>", .{});
    defer str.deinit(ctx);
    try testing.expect(str.isString());

    // isArray
    const arr = ctx.eval("[1, 2, 3]", "<test>", .{});
    defer arr.deinit(ctx);
    try testing.expect(arr.isArray());

    // isObject (but not array)
    const obj = ctx.eval("({a: 1})", "<test>", .{});
    defer obj.deinit(ctx);
    try testing.expect(obj.isObject());
    try testing.expect(!obj.isArray());

    // isFunction
    const func = ctx.eval("(function() {})", "<test>", .{});
    defer func.deinit(ctx);
    try testing.expect(func.isFunction(ctx));

    // isBool
    const boolean = ctx.eval("true", "<test>", .{});
    defer boolean.deinit(ctx);
    try testing.expect(boolean.isBool());

    // isNull
    const null_val = ctx.eval("null", "<test>", .{});
    defer null_val.deinit(ctx);
    try testing.expect(null_val.isNull());

    // isUndefined
    const undef = ctx.eval("undefined", "<test>", .{});
    defer undef.deinit(ctx);
    try testing.expect(undef.isUndefined());

    // isDate
    const date = ctx.eval("new Date()", "<test>", .{});
    defer date.deinit(ctx);
    try testing.expect(date.isDate());

    // isRegExp
    const regex = ctx.eval("/test/g", "<test>", .{});
    defer regex.deinit(ctx);
    try testing.expect(regex.isRegExp());

    // isMap
    const map = ctx.eval("new Map()", "<test>", .{});
    defer map.deinit(ctx);
    try testing.expect(map.isMap());

    // isSet
    const set = ctx.eval("new Set()", "<test>", .{});
    defer set.deinit(ctx);
    try testing.expect(set.isSet());

    // isPromise
    const promise = ctx.eval("new Promise(() => {})", "<test>", .{});
    defer promise.deinit(ctx);
    try testing.expect(promise.isPromise());

    // isSymbol
    const symbol = ctx.eval("Symbol('test')", "<test>", .{});
    defer symbol.deinit(ctx);
    try testing.expect(symbol.isSymbol());

    // isBigInt
    const bigint = ctx.eval("BigInt(9007199254740991)", "<test>", .{});
    defer bigint.deinit(ctx);
    try testing.expect(bigint.isBigInt());

    // isError
    const err = ctx.eval("new Error('test')", "<test>", .{});
    defer err.deinit(ctx);
    try testing.expect(err.isError());
}

test "constructors create valid JavaScript values" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    // initBool
    const bool_val = Value.initBool(true);
    try testing.expect(bool_val.isBool());
    try testing.expect(try bool_val.toBool(ctx));

    // initInt32
    const int32_val = Value.initInt32(42);
    try testing.expect(int32_val.isNumber());
    try testing.expectEqual(@as(i32, 42), try int32_val.toInt32(ctx));

    // initFloat64
    const float_val = Value.initFloat64(3.14);
    try testing.expect(float_val.isNumber());
    try testing.expectApproxEqAbs(@as(f64, 3.14), try float_val.toFloat64(ctx), 0.001);

    // initInt64 - fits in i32
    const int64_small = Value.initInt64(100);
    try testing.expect(int64_small.isNumber());
    try testing.expectEqual(@as(i32, 100), try int64_small.toInt32(ctx));

    // initInt64 - too large for i32, becomes float
    const int64_large = Value.initInt64(std.math.maxInt(i32) + 1);
    try testing.expect(int64_large.isNumber());

    // initUint32 - fits in i32
    const uint32_small = Value.initUint32(100);
    try testing.expect(uint32_small.isNumber());
    try testing.expectEqual(@as(i32, 100), try uint32_small.toInt32(ctx));

    // initUint32 - too large for i32, becomes float
    const uint32_large = Value.initUint32(std.math.maxInt(i32) + 1);
    try testing.expect(uint32_large.isNumber());

    // initString
    const str_val = Value.initString(ctx, "hello");
    defer str_val.deinit(ctx);
    try testing.expect(str_val.isString());
    const cstr = str_val.toCString(ctx).?;
    defer ctx.freeCString(cstr);
    try testing.expectEqualStrings("hello", std.mem.span(cstr));

    // initStringLen
    const str_len_val = Value.initStringLen(ctx, "hello world");
    defer str_len_val.deinit(ctx);
    try testing.expect(str_len_val.isString());

    // initObject
    const obj = Value.initObject(ctx);
    defer obj.deinit(ctx);
    try testing.expect(obj.isObject());
    try testing.expect(!obj.isArray());

    // initArray
    const arr = Value.initArray(ctx);
    defer arr.deinit(ctx);
    try testing.expect(arr.isArray());

    // Verify values work in JavaScript by setting as global and reading back
    try global.setPropertyStr(ctx, "testInt", Value.initInt32(123));
    const read_back = ctx.eval("testInt", "<test>", .{});
    defer read_back.deinit(ctx);
    try testing.expectEqual(@as(i32, 123), try read_back.toInt32(ctx));
}

test "conversions" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // toInt32
    const int_val = ctx.eval("42", "<test>", .{});
    defer int_val.deinit(ctx);
    try testing.expectEqual(@as(i32, 42), try int_val.toInt32(ctx));

    // toInt32 from float truncates
    const float_to_int = ctx.eval("3.7", "<test>", .{});
    defer float_to_int.deinit(ctx);
    try testing.expectEqual(@as(i32, 3), try float_to_int.toInt32(ctx));

    // toInt64
    const int64_val = ctx.eval("9007199254740991", "<test>", .{});
    defer int64_val.deinit(ctx);
    try testing.expectEqual(@as(i64, 9007199254740991), try int64_val.toInt64(ctx));

    // toFloat64
    const float_val = ctx.eval("3.14159", "<test>", .{});
    defer float_val.deinit(ctx);
    try testing.expectApproxEqAbs(@as(f64, 3.14159), try float_val.toFloat64(ctx), 0.00001);

    // toBool
    const true_val = ctx.eval("true", "<test>", .{});
    defer true_val.deinit(ctx);
    try testing.expect(try true_val.toBool(ctx));

    const false_val = ctx.eval("false", "<test>", .{});
    defer false_val.deinit(ctx);
    try testing.expect(!try false_val.toBool(ctx));

    // toCString
    const str_val = ctx.eval("'test string'", "<test>", .{});
    defer str_val.deinit(ctx);
    const cstr = str_val.toCString(ctx).?;
    defer ctx.freeCString(cstr);
    try testing.expectEqualStrings("test string", std.mem.span(cstr));

    // toCStringLen
    const str_with_null = Value.initStringLen(ctx, "hello\x00world");
    defer str_with_null.deinit(ctx);
    const cstr_result = str_with_null.toCStringLen(ctx).?;
    defer ctx.freeCString(cstr_result.ptr);
    try testing.expectEqual(@as(usize, 11), cstr_result.len);

    // toZigSlice
    const str_val2 = ctx.eval("'zig slice test'", "<test>", .{});
    defer str_val2.deinit(ctx);
    const slice = str_val2.toZigSlice(ctx).?;
    defer ctx.freeCString(slice.ptr);
    try testing.expectEqualStrings("zig slice test", slice);

    // toZigSlice with embedded null
    const str_with_null2 = Value.initStringLen(ctx, "foo\x00bar");
    defer str_with_null2.deinit(ctx);
    const slice2 = str_with_null2.toZigSlice(ctx).?;
    defer ctx.freeCString(slice2.ptr);
    try testing.expectEqual(@as(usize, 7), slice2.len);
    try testing.expectEqualStrings("foo\x00bar", slice2);
}

test "property access" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // Create an object and set properties
    const obj = Value.initObject(ctx);
    defer obj.deinit(ctx);

    // setPropertyStr and getPropertyStr
    try obj.setPropertyStr(ctx, "foo", Value.initInt32(42));
    const foo = obj.getPropertyStr(ctx, "foo");
    defer foo.deinit(ctx);
    try testing.expectEqual(@as(i32, 42), try foo.toInt32(ctx));

    // hasPropertyStr
    try testing.expect(try obj.hasPropertyStr(ctx, "foo"));
    try testing.expect(!try obj.hasPropertyStr(ctx, "bar"));

    // deletePropertyStr
    try testing.expect(try obj.deletePropertyStr(ctx, "foo"));
    try testing.expect(!try obj.hasPropertyStr(ctx, "foo"));

    // getLength on arrays
    const arr = ctx.eval("[1, 2, 3, 4, 5]", "<test>", .{});
    defer arr.deinit(ctx);
    try testing.expectEqual(@as(i64, 5), try arr.getLength(ctx));

    // Property access via JavaScript
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const test_obj = Value.initObject(ctx);
    try test_obj.setPropertyStr(ctx, "x", Value.initInt32(100));
    try test_obj.setPropertyStr(ctx, "y", Value.initInt32(200));
    try global.setPropertyStr(ctx, "testObj", test_obj);

    const sum = ctx.eval("testObj.x + testObj.y", "<test>", .{});
    defer sum.deinit(ctx);
    try testing.expectEqual(@as(i32, 300), try sum.toInt32(ctx));
}

test "comparison functions" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // isEqual vs isStrictEqual: 1 == "1" is true, 1 === "1" is false
    const num_one = ctx.eval("1", "<test>", .{});
    defer num_one.deinit(ctx);
    const str_one = ctx.eval("'1'", "<test>", .{});
    defer str_one.deinit(ctx);

    try testing.expect(try num_one.isEqual(ctx, str_one)); // 1 == "1"
    try testing.expect(!num_one.isStrictEqual(ctx, str_one)); // 1 !== "1"

    // Same value comparison
    const num_a = ctx.eval("42", "<test>", .{});
    defer num_a.deinit(ctx);
    const num_b = ctx.eval("42", "<test>", .{});
    defer num_b.deinit(ctx);

    try testing.expect(try num_a.isEqual(ctx, num_b));
    try testing.expect(num_a.isStrictEqual(ctx, num_b));
    try testing.expect(num_a.isSameValue(ctx, num_b));

    // isSameValue: NaN === NaN is false, but Object.is(NaN, NaN) is true
    const nan_a = ctx.eval("NaN", "<test>", .{});
    defer nan_a.deinit(ctx);
    const nan_b = ctx.eval("NaN", "<test>", .{});
    defer nan_b.deinit(ctx);

    try testing.expect(!nan_a.isStrictEqual(ctx, nan_b)); // NaN !== NaN
    try testing.expect(nan_a.isSameValue(ctx, nan_b)); // Object.is(NaN, NaN) === true

    // isSameValueZero: +0 and -0
    const pos_zero = ctx.eval("+0", "<test>", .{});
    defer pos_zero.deinit(ctx);
    const neg_zero = ctx.eval("-0", "<test>", .{});
    defer neg_zero.deinit(ctx);

    try testing.expect(pos_zero.isStrictEqual(ctx, neg_zero)); // +0 === -0
    try testing.expect(!pos_zero.isSameValue(ctx, neg_zero)); // Object.is(+0, -0) === false
    try testing.expect(pos_zero.isSameValueZero(ctx, neg_zero)); // SameValueZero(+0, -0) === true
}

test "function calls" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    // Create a function via eval
    const add_func = ctx.eval("(function(a, b) { return a + b; })", "<test>", .{});
    defer add_func.deinit(ctx);
    try testing.expect(add_func.isFunction(ctx));

    // Call the function with arguments
    const arg1 = Value.initInt32(10);
    const arg2 = Value.initInt32(32);
    const result = add_func.call(ctx, Value.undefined, &.{ arg1, arg2 });
    defer result.deinit(ctx);

    try testing.expect(!result.isException());
    try testing.expectEqual(@as(i32, 42), try result.toInt32(ctx));

    // Function with string concatenation
    const concat_func = ctx.eval("(function(s1, s2) { return s1 + s2; })", "<test>", .{});
    defer concat_func.deinit(ctx);

    const s1 = Value.initString(ctx, "Hello, ");
    defer s1.deinit(ctx);
    const s2 = Value.initString(ctx, "World!");
    defer s2.deinit(ctx);
    const concat_result = concat_func.call(ctx, Value.undefined, &.{ s1.dup(ctx), s2.dup(ctx) });
    defer concat_result.deinit(ctx);

    const cstr = concat_result.toCString(ctx).?;
    defer ctx.freeCString(cstr);
    try testing.expectEqualStrings("Hello, World!", std.mem.span(cstr));

    // Function that uses 'this'
    const obj = Value.initObject(ctx);
    defer obj.deinit(ctx);
    try obj.setPropertyStr(ctx, "value", Value.initInt32(100));

    const method = ctx.eval("(function() { return this.value * 2; })", "<test>", .{});
    defer method.deinit(ctx);

    const method_result = method.call(ctx, obj, &.{});
    defer method_result.deinit(ctx);
    try testing.expectEqual(@as(i32, 200), try method_result.toInt32(ctx));
}

test "array operations" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // Create array and add elements via setPropertyUint32
    const arr = Value.initArray(ctx);
    defer arr.deinit(ctx);

    try arr.setPropertyUint32(ctx, 0, Value.initInt32(10));
    try arr.setPropertyUint32(ctx, 1, Value.initInt32(20));
    try arr.setPropertyUint32(ctx, 2, Value.initInt32(30));

    try testing.expectEqual(@as(i64, 3), try arr.getLength(ctx));

    // Read elements back via getPropertyUint32
    const elem0 = arr.getPropertyUint32(ctx, 0);
    defer elem0.deinit(ctx);
    try testing.expectEqual(@as(i32, 10), try elem0.toInt32(ctx));

    const elem2 = arr.getPropertyUint32(ctx, 2);
    defer elem2.deinit(ctx);
    try testing.expectEqual(@as(i32, 30), try elem2.toInt32(ctx));

    // initArrayFrom
    const values = [_]Value{
        Value.initInt32(1),
        Value.initInt32(2),
        Value.initInt32(3),
    };
    const arr2 = Value.initArrayFrom(ctx, &values);
    defer arr2.deinit(ctx);

    try testing.expect(arr2.isArray());
    try testing.expectEqual(@as(i64, 3), try arr2.getLength(ctx));
}

test "JSON operations" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // parseJSON
    const parsed = Value.parseJSON(ctx, "{\"a\": 1, \"b\": 2}", "<json>");
    defer parsed.deinit(ctx);

    try testing.expect(parsed.isObject());
    const a = parsed.getPropertyStr(ctx, "a");
    defer a.deinit(ctx);
    try testing.expectEqual(@as(i32, 1), try a.toInt32(ctx));

    // jsonStringify
    const obj = Value.initObject(ctx);
    defer obj.deinit(ctx);
    try obj.setPropertyStr(ctx, "x", Value.initInt32(42));

    const json_str = obj.jsonStringify(ctx, Value.undefined, Value.undefined);
    defer json_str.deinit(ctx);

    const cstr = json_str.toCString(ctx).?;
    defer ctx.freeCString(cstr);
    try testing.expectEqualStrings("{\"x\":42}", std.mem.span(cstr));
}

test "BigInt operations" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // initBigInt64
    const big1 = Value.initBigInt64(ctx, 9007199254740993);
    defer big1.deinit(ctx);
    try testing.expect(big1.isBigInt());

    // initBigUint64
    const big2 = Value.initBigUint64(ctx, 18446744073709551615);
    defer big2.deinit(ctx);
    try testing.expect(big2.isBigInt());

    // toBigInt64
    const big_val = ctx.eval("BigInt(12345)", "<test>", .{});
    defer big_val.deinit(ctx);
    try testing.expectEqual(@as(i64, 12345), try big_val.toBigInt64(ctx));
}

test "Date operations" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // initDate
    const epoch_ms: f64 = 1609459200000; // 2021-01-01 00:00:00 UTC
    const date = Value.initDate(ctx, epoch_ms);
    defer date.deinit(ctx);

    try testing.expect(date.isDate());

    // Verify via JavaScript
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);
    try global.setPropertyStr(ctx, "testDate", date.dup(ctx));

    const year = ctx.eval("testDate.getUTCFullYear()", "<test>", .{});
    defer year.deinit(ctx);
    try testing.expectEqual(@as(i32, 2021), try year.toInt32(ctx));
}

test "Symbol operations" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // initSymbol (local)
    const sym_local = Value.initSymbol(ctx, "mySymbol", false);
    defer sym_local.deinit(ctx);
    try testing.expect(sym_local.isSymbol());

    // initSymbol (global)
    const sym_global = Value.initSymbol(ctx, "globalSymbol", true);
    defer sym_global.deinit(ctx);
    try testing.expect(sym_global.isSymbol());

    // Two global symbols with same name should be equal
    const sym_global2 = Value.initSymbol(ctx, "globalSymbol", true);
    defer sym_global2.deinit(ctx);
    try testing.expect(sym_global.isStrictEqual(ctx, sym_global2));

    // Two local symbols with same name should NOT be equal
    const sym_local2 = Value.initSymbol(ctx, "mySymbol", false);
    defer sym_local2.deinit(ctx);
    try testing.expect(!sym_local.isStrictEqual(ctx, sym_local2));
}

test "Error operations" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // initError
    const err = Value.initError(ctx);
    defer err.deinit(ctx);
    try testing.expect(err.isError());

    // Exception handling via eval
    const result = ctx.eval("throw new Error('test error')", "<test>", .{});
    defer result.deinit(ctx);
    try testing.expect(result.isException());

    const exc = ctx.getException();
    defer exc.deinit(ctx);
    try testing.expect(exc.isError());
}

test "Promise state" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // Pending promise
    const pending = ctx.eval("new Promise(() => {})", "<test>", .{});
    defer pending.deinit(ctx);
    try testing.expect(pending.isPromise());
    try testing.expectEqual(PromiseState.pending, pending.promiseState(ctx));

    // Fulfilled promise
    const fulfilled = ctx.eval("Promise.resolve(42)", "<test>", .{});
    defer fulfilled.deinit(ctx);
    try testing.expectEqual(PromiseState.fulfilled, fulfilled.promiseState(ctx));

    const result = fulfilled.promiseResult(ctx);
    defer result.deinit(ctx);
    try testing.expectEqual(@as(i32, 42), try result.toInt32(ctx));

    // Non-promise value
    const num = ctx.eval("42", "<test>", .{});
    defer num.deinit(ctx);
    try testing.expectEqual(PromiseState.not_a_promise, num.promiseState(ctx));
}

test "initPromiseCapability" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const promise: Value.Promise = Value.initPromiseCapability(ctx);
    defer promise.resolve.deinit(ctx);
    defer promise.reject.deinit(ctx);
    defer promise.value.deinit(ctx);

    try testing.expect(promise.value.isPromise());
    try testing.expectEqual(PromiseState.pending, promise.value.promiseState(ctx));

    // Resolve the promise
    const val: Value = .initInt32(42);
    const resolve_result = promise.resolve.call(ctx, .undefined, &.{val});
    defer resolve_result.deinit(ctx);

    try testing.expectEqual(PromiseState.fulfilled, promise.value.promiseState(ctx));

    const result = promise.value.promiseResult(ctx);
    defer result.deinit(ctx);
    try testing.expectEqual(@as(i32, 42), try result.toInt32(ctx));
}

test "instanceof" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const arr = ctx.eval("[1, 2, 3]", "<test>", .{});
    defer arr.deinit(ctx);

    const array_ctor = ctx.eval("Array", "<test>", .{});
    defer array_ctor.deinit(ctx);

    const object_ctor = ctx.eval("Object", "<test>", .{});
    defer object_ctor.deinit(ctx);

    const map_ctor = ctx.eval("Map", "<test>", .{});
    defer map_ctor.deinit(ctx);

    try testing.expect(try arr.isInstanceOf(ctx, array_ctor));
    try testing.expect(try arr.isInstanceOf(ctx, object_ctor)); // Arrays are objects
    try testing.expect(!try arr.isInstanceOf(ctx, map_ctor));
}

test "init with Value passthrough" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const original = Value.initInt32(42);
    const result = Value.init(ctx, original);

    if (Value.is_nan_boxed) {
        try testing.expectEqual(original.val, result.val);
    } else {
        try testing.expectEqual(original.tag, result.tag);
        try testing.expectEqual(original.u.int32, result.u.int32);
    }
}

test "init with bool" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const true_val = Value.init(ctx, true);
    try testing.expect(true_val.isBool());
    try testing.expect(try true_val.toBool(ctx));

    const false_val = Value.init(ctx, false);
    try testing.expect(false_val.isBool());
    try testing.expect(!try false_val.toBool(ctx));
}

test "init with void" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const result = Value.init(ctx, {});
    try testing.expect(result.isNull());
}

test "init with null" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const result = Value.init(ctx, null);
    try testing.expect(result.isNull());
}

test "init with optional" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const some_val: ?i32 = 42;
    const result = Value.init(ctx, some_val);
    try testing.expect(!result.isNull());
    try testing.expectEqual(@as(i32, 42), try result.toInt32(ctx));

    const none_val: ?i32 = null;
    const result_null = Value.init(ctx, none_val);
    try testing.expect(result_null.isNull());
}

test "init with signed integers" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // i8
    const i8_val: i8 = -42;
    const result_i8 = Value.init(ctx, i8_val);
    try testing.expectEqual(@as(i32, -42), try result_i8.toInt32(ctx));

    // i16
    const i16_val: i16 = -1000;
    const result_i16 = Value.init(ctx, i16_val);
    try testing.expectEqual(@as(i32, -1000), try result_i16.toInt32(ctx));

    // i32
    const i32_val: i32 = -100000;
    const result_i32 = Value.init(ctx, i32_val);
    try testing.expectEqual(@as(i32, -100000), try result_i32.toInt32(ctx));

    // i64 that fits in i32
    const i64_small: i64 = -50000;
    const result_i64_small = Value.init(ctx, i64_small);
    try testing.expectEqual(@as(i32, -50000), try result_i64_small.toInt32(ctx));

    // i64 that exceeds i32 range
    const i64_large: i64 = 9007199254740992;
    const result_i64_large = Value.init(ctx, i64_large);
    try testing.expectEqual(@as(f64, 9007199254740992), try result_i64_large.toFloat64(ctx));
}

test "init with unsigned integers" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // u8
    const u8_val: u8 = 200;
    const result_u8 = Value.init(ctx, u8_val);
    try testing.expectEqual(@as(u32, 200), try result_u8.toUint32(ctx));

    // u16
    const u16_val: u16 = 60000;
    const result_u16 = Value.init(ctx, u16_val);
    try testing.expectEqual(@as(u32, 60000), try result_u16.toUint32(ctx));

    // u32 within i32 range
    const u32_small: u32 = 1000000;
    const result_u32_small = Value.init(ctx, u32_small);
    try testing.expectEqual(@as(u32, 1000000), try result_u32_small.toUint32(ctx));

    // u32 exceeding i32 max (becomes float)
    const u32_large: u32 = 3000000000;
    const result_u32_large = Value.init(ctx, u32_large);
    try testing.expectEqual(@as(f64, 3000000000), try result_u32_large.toFloat64(ctx));
}

test "init with comptime_int" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const result = Value.init(ctx, 42);
    try testing.expectEqual(@as(i32, 42), try result.toInt32(ctx));

    const result_neg = Value.init(ctx, -100);
    try testing.expectEqual(@as(i32, -100), try result_neg.toInt32(ctx));
}

test "init with floats" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // f32
    const f32_val: f32 = 3.14;
    const result_f32 = Value.init(ctx, f32_val);
    try testing.expect(result_f32.isNumber());
    try testing.expectApproxEqAbs(@as(f64, 3.14), try result_f32.toFloat64(ctx), 0.001);

    // f64
    const f64_val: f64 = 2.71828;
    const result_f64 = Value.init(ctx, f64_val);
    try testing.expectApproxEqAbs(@as(f64, 2.71828), try result_f64.toFloat64(ctx), 0.00001);
}

test "init with comptime_float" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const result = Value.init(ctx, 3.14159);
    try testing.expectApproxEqAbs(@as(f64, 3.14159), try result.toFloat64(ctx), 0.00001);
}

test "init with string slice" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const str: []const u8 = "hello world";
    const result = Value.init(ctx, str);
    defer result.deinit(ctx);

    try testing.expect(result.isString());
    const cstr = result.toCString(ctx).?;
    defer ctx.freeCString(cstr);
    try testing.expectEqualStrings("hello world", std.mem.span(cstr));
}

test "init with string pointer to array" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const str: *const [5]u8 = "hello";
    const result = Value.init(ctx, str);
    defer result.deinit(ctx);

    try testing.expect(result.isString());
    const cstr = result.toCString(ctx).?;
    defer ctx.freeCString(cstr);
    try testing.expectEqualStrings("hello", std.mem.span(cstr));
}

test "init with string literal" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const result = Value.init(ctx, "test string");
    defer result.deinit(ctx);

    try testing.expect(result.isString());
    const cstr = result.toCString(ctx).?;
    defer ctx.freeCString(cstr);
    try testing.expectEqualStrings("test string", std.mem.span(cstr));
}

test "init with nested optional" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const optional_str: ?[]const u8 = "nested";
    const result = Value.init(ctx, optional_str);
    defer result.deinit(ctx);

    try testing.expect(result.isString());
    const cstr = result.toCString(ctx).?;
    defer ctx.freeCString(cstr);
    try testing.expectEqualStrings("nested", std.mem.span(cstr));
}

test "Value isModule" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const loader = struct {
        fn load(
            _: void,
            load_ctx: *Context,
            name: [:0]const u8,
        ) ?*ModuleDef {
            if (!std.mem.eql(u8, name, "mod_test")) return null;

            const m = ModuleDef.init(load_ctx, name, initFn) orelse return null;
            _ = m.addExport(load_ctx, "x");
            return m;
        }

        fn initFn(init_ctx: *Context, m: *ModuleDef) bool {
            if (!m.setExport(init_ctx, "x", Value.initInt32(1))) return false;
            return true;
        }
    };

    ctx.getRuntime().setModuleLoaderFunc(void, {}, null, loader.load);

    const result = ctx.eval(
        \\import { x } from "mod_test"; x
    , "<test>", .{ .type = .module });
    defer result.deinit(ctx);

    try testing.expect(!result.isException());

    const num = Value.initInt32(42);
    try testing.expect(!num.isModule());
}

test "ArrayBuffer operations" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // initArrayBufferCopy - creates a copy of the data
    const data = [_]u8{ 1, 2, 3, 4, 5 };
    const ab = Value.initArrayBufferCopy(ctx, &data);
    defer ab.deinit(ctx);

    try testing.expect(ab.isArrayBuffer());
    try testing.expect(!ab.isException());

    // getArrayBuffer - get the underlying data
    const buf = ab.getArrayBuffer(ctx);
    try testing.expect(buf != null);
    try testing.expectEqual(@as(usize, 5), buf.?.len);
    try testing.expectEqualSlices(u8, &data, buf.?);

    // Modify the buffer and verify it's the same underlying data
    buf.?[0] = 42;
    const buf2 = ab.getArrayBuffer(ctx);
    try testing.expectEqual(@as(u8, 42), buf2.?[0]);
}

test "ArrayBuffer from JavaScript" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // Create ArrayBuffer in JS
    const ab = ctx.eval("new ArrayBuffer(8)", "<test>", .{});
    defer ab.deinit(ctx);

    try testing.expect(!ab.isException());
    try testing.expect(ab.isArrayBuffer());

    const buf = ab.getArrayBuffer(ctx);
    try testing.expect(buf != null);
    try testing.expectEqual(@as(usize, 8), buf.?.len);
}

test "ArrayBuffer detach" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const data = [_]u8{ 1, 2, 3, 4 };
    const ab = Value.initArrayBufferCopy(ctx, &data);
    defer ab.deinit(ctx);

    // Should have data before detach
    try testing.expect(ab.getArrayBuffer(ctx) != null);

    // Detach the buffer
    ab.detachArrayBuffer(ctx);

    // After detach, getArrayBuffer returns null
    try testing.expect(ab.getArrayBuffer(ctx) == null);
}

test "Uint8Array operations" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // initUint8ArrayCopy - creates a Uint8Array with copied data
    const data = [_]u8{ 10, 20, 30, 40, 50 };
    const arr = Value.initUint8ArrayCopy(ctx, &data);
    defer arr.deinit(ctx);

    try testing.expect(!arr.isException());

    // getUint8Array - get the underlying data
    const buf = arr.getUint8Array(ctx);
    try testing.expect(buf != null);
    try testing.expectEqual(@as(usize, 5), buf.?.len);
    try testing.expectEqualSlices(u8, &data, buf.?);

    // getTypedArrayType
    const arr_type = arr.getTypedArrayType();
    try testing.expect(arr_type != null);
    try testing.expectEqual(typed_array.Type.uint8, arr_type.?);
}

test "Uint8Array from JavaScript" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // Create Uint8Array in JS
    const arr = ctx.eval("new Uint8Array([1, 2, 3, 4])", "<test>", .{});
    defer arr.deinit(ctx);

    try testing.expect(!arr.isException());

    const buf = arr.getUint8Array(ctx);
    try testing.expect(buf != null);
    try testing.expectEqual(@as(usize, 4), buf.?.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, buf.?);

    // Verify type
    const arr_type = arr.getTypedArrayType();
    try testing.expectEqual(typed_array.Type.uint8, arr_type.?);
}

test "TypedArray types" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const TestCase = struct {
        js_code: [:0]const u8,
        expected_type: typed_array.Type,
    };

    const test_cases = [_]TestCase{
        .{ .js_code = "new Int8Array(4)", .expected_type = .int8 },
        .{ .js_code = "new Uint8Array(4)", .expected_type = .uint8 },
        .{ .js_code = "new Uint8ClampedArray(4)", .expected_type = .uint8_clamped },
        .{ .js_code = "new Int16Array(4)", .expected_type = .int16 },
        .{ .js_code = "new Uint16Array(4)", .expected_type = .uint16 },
        .{ .js_code = "new Int32Array(4)", .expected_type = .int32 },
        .{ .js_code = "new Uint32Array(4)", .expected_type = .uint32 },
        .{ .js_code = "new Float32Array(4)", .expected_type = .float32 },
        .{ .js_code = "new Float64Array(4)", .expected_type = .float64 },
        .{ .js_code = "new BigInt64Array(4)", .expected_type = .big_int64 },
        .{ .js_code = "new BigUint64Array(4)", .expected_type = .big_uint64 },
    };

    for (test_cases) |tc| {
        const arr = ctx.eval(tc.js_code, "<test>", .{});
        defer arr.deinit(ctx);

        try testing.expect(!arr.isException());
        const arr_type = arr.getTypedArrayType();
        try testing.expect(arr_type != null);
        try testing.expectEqual(tc.expected_type, arr_type.?);
    }
}

test "getTypedArrayType returns null for non-typed-arrays" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // Regular array
    const arr = ctx.eval("[1, 2, 3]", "<test>", .{});
    defer arr.deinit(ctx);
    try testing.expect(arr.getTypedArrayType() == null);

    // Number
    const num = Value.initInt32(42);
    try testing.expect(num.getTypedArrayType() == null);

    // ArrayBuffer (not a TypedArray)
    const ab = ctx.eval("new ArrayBuffer(8)", "<test>", .{});
    defer ab.deinit(ctx);
    try testing.expect(ab.getTypedArrayType() == null);
}

test "getTypedArrayBuffer" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // Create a typed array with an offset and different element size
    const arr = ctx.eval(
        \\const buf = new ArrayBuffer(16);
        \\new Int32Array(buf, 4, 2);
    , "<test>", .{});
    defer arr.deinit(ctx);

    try testing.expect(!arr.isException());

    const info = arr.getTypedArrayBuffer(ctx);
    try testing.expect(info != null);
    defer info.?.value.deinit(ctx);

    try testing.expect(info.?.value.isArrayBuffer());
    try testing.expectEqual(@as(usize, 4), info.?.byte_offset);
    try testing.expectEqual(@as(usize, 8), info.?.byte_length); // 2 Int32s = 8 bytes
    try testing.expectEqual(@as(usize, 4), info.?.bytes_per_element);
}

test "initTypedArray with length" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // Create typed array with length argument
    const len = Value.initInt32(10);
    const args = [_]Value{len};
    const arr = Value.initTypedArray(ctx, &args, .float64);
    defer arr.deinit(ctx);

    try testing.expect(!arr.isException());
    try testing.expectEqual(typed_array.Type.float64, arr.getTypedArrayType().?);

    const info = arr.getTypedArrayBuffer(ctx);
    try testing.expect(info != null);
    defer info.?.value.deinit(ctx);

    try testing.expectEqual(@as(usize, 80), info.?.byte_length); // 10 Float64s = 80 bytes
    try testing.expectEqual(@as(usize, 8), info.?.bytes_per_element);
}

test "initCFunction basic" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const addFunc = Value.initCFunction(ctx, &testAddFunc, "add", 2);
    defer addFunc.deinit(ctx);

    try testing.expect(!addFunc.isException());
    try testing.expect(addFunc.isFunction(ctx));

    // Register as global and call from JS
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);
    try global.setPropertyStr(ctx, "add", addFunc.dup(ctx));

    const result = ctx.eval("add(3, 4)", "<test>", .{});
    defer result.deinit(ctx);
    try testing.expect(!result.isException());
    try testing.expectEqual(@as(i32, 7), try result.toInt32(ctx));
}

fn testAddFunc(
    ctx_opt: ?*Context,
    _: Value,
    args: []const c.JSValue,
) Value {
    if (args.len < 2) return Value.undefined;
    const ctx = ctx_opt.?;
    const a = Value.fromCVal(args[0]).toInt32(ctx) catch return Value.exception;
    const b = Value.fromCVal(args[1]).toInt32(ctx) catch return Value.exception;
    return Value.initInt32(a + b);
}

test "initCFunctionData with closure data" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // Create a function with closure data (a multiplier)
    const multiplier = Value.initInt32(10);
    const data = [_]Value{multiplier};
    const multiplyFunc = Value.initCFunctionData(ctx, &testMultiplyFunc, 1, 0, &data);
    defer multiplyFunc.deinit(ctx);

    try testing.expect(!multiplyFunc.isException());
    try testing.expect(multiplyFunc.isFunction(ctx));

    // Register as global and call from JS
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);
    try global.setPropertyStr(ctx, "multiplyByTen", multiplyFunc.dup(ctx));

    const result = ctx.eval("multiplyByTen(5)", "<test>", .{});
    defer result.deinit(ctx);
    try testing.expect(!result.isException());
    try testing.expectEqual(@as(i32, 50), try result.toInt32(ctx));
}

fn testMultiplyFunc(ctx_opt: ?*Context, _: Value, args: []const c.JSValue, _: c_int, func_data: [*c]c.JSValue) Value {
    if (args.len < 1) return Value.undefined;
    const ctx = ctx_opt.?;
    const val = Value.fromCVal(args[0]).toInt32(ctx) catch return Value.exception;
    const multiplier = Value.fromCVal(func_data[0]).toInt32(ctx) catch return Value.exception;
    return Value.initInt32(val * multiplier);
}

test "setPropertyFunctionList" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const obj = Value.initObject(ctx);
    defer obj.deinit(ctx);

    const list = [_]cfunc.FunctionListEntry{
        cfunc.FunctionListEntryHelpers.func("square", 1, &testSquareFunc),
        cfunc.FunctionListEntryHelpers.propInt32("VERSION", 42, .{ .configurable = true }),
    };

    try obj.setPropertyFunctionList(ctx, &list);

    // Register object as global
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);
    try global.setPropertyStr(ctx, "myObj", obj.dup(ctx));

    // Test function
    const result1 = ctx.eval("myObj.square(7)", "<test>", .{});
    defer result1.deinit(ctx);
    try testing.expect(!result1.isException());
    try testing.expectEqual(@as(i32, 49), try result1.toInt32(ctx));

    // Test constant
    const result2 = ctx.eval("myObj.VERSION", "<test>", .{});
    defer result2.deinit(ctx);
    try testing.expect(!result2.isException());
    try testing.expectEqual(@as(i32, 42), try result2.toInt32(ctx));
}

fn testSquareFunc(ctx_opt: ?*Context, _: Value, args: []const c.JSValue) Value {
    if (args.len < 1) return Value.undefined;
    const ctx = ctx_opt.?;
    const val = Value.fromCVal(args[0]).toInt32(ctx) catch return Value.exception;
    return Value.initInt32(val * val);
}

test "getset property accessors" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const obj: Value = .initObject(ctx);
    defer obj.deinit(ctx);

    const list = [_]cfunc.FunctionListEntry{
        cfunc.FunctionListEntryHelpers.getset("readOnly", &testGetter, null),
        cfunc.FunctionListEntryHelpers.getset("readWrite", &testGetter, &testSetter),
        cfunc.FunctionListEntryHelpers.getsetMagic("magicProp", &testGetterMagic, &testSetterMagic, 42),
    };

    try obj.setPropertyFunctionList(ctx, &list);

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);
    try global.setPropertyStr(ctx, "testObj", obj.dup(ctx));

    // Test read-only getter
    const result1 = ctx.eval("testObj.readOnly", "<test>", .{});
    defer result1.deinit(ctx);
    try testing.expect(!result1.isException());
    try testing.expectEqual(@as(i32, 123), try result1.toInt32(ctx));

    // Test read-write getter
    const result2 = ctx.eval("testObj.readWrite", "<test>", .{});
    defer result2.deinit(ctx);
    try testing.expect(!result2.isException());
    try testing.expectEqual(@as(i32, 123), try result2.toInt32(ctx));

    // Test setter returns value
    const result3 = ctx.eval("testObj.readWrite = 999", "<test>", .{});
    defer result3.deinit(ctx);
    try testing.expect(!result3.isException());

    // Test magic getter (returns the magic value)
    const result4 = ctx.eval("testObj.magicProp", "<test>", .{});
    defer result4.deinit(ctx);
    try testing.expect(!result4.isException());
    try testing.expectEqual(@as(i32, 42), try result4.toInt32(ctx));

    // Test magic setter
    const result5 = ctx.eval("testObj.magicProp = 100", "<test>", .{});
    defer result5.deinit(ctx);
    try testing.expect(!result5.isException());
}

fn testGetter(_: ?*Context, _: Value) Value {
    return .initInt32(123);
}

fn testSetter(_: ?*Context, _: Value, _: Value) Value {
    return .undefined;
}

fn testGetterMagic(_: ?*Context, _: Value, magic: c_int) Value {
    return .initInt32(magic);
}

fn testSetterMagic(_: ?*Context, _: Value, _: Value, _: c_int) Value {
    return .undefined;
}

test "setConstructor" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // Create a constructor function using generic (constructor_or_func allows both new and call)
    const ctor = Value.initCFunction2(ctx, &testConstructor, "Point", 2, .constructor_or_func, 0);
    defer ctor.deinit(ctx);

    // Create prototype with method
    const proto = Value.initObject(ctx);
    defer proto.deinit(ctx);

    const protoList = [_]cfunc.FunctionListEntry{
        cfunc.FunctionListEntryHelpers.func("toString", 0, &testPointToString),
    };
    try proto.setPropertyFunctionList(ctx, &protoList);

    // Link constructor and prototype
    ctor.setConstructor(ctx, proto);

    // Register as global
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);
    try global.setPropertyStr(ctx, "Point", ctor.dup(ctx));

    // Test that function was registered and constructor link exists
    const protoCheck = ctx.eval("Point.prototype.toString !== undefined", "<test>", .{});
    defer protoCheck.deinit(ctx);
    try testing.expect(!protoCheck.isException());
    try testing.expect(try protoCheck.toBool(ctx));

    // Test that prototype.constructor points back to Point
    const ctorCheck = ctx.eval("Point.prototype.constructor === Point", "<test>", .{});
    defer ctorCheck.deinit(ctx);
    try testing.expect(!ctorCheck.isException());
    try testing.expect(try ctorCheck.toBool(ctx));
}

fn testConstructor(ctx_opt: ?*Context, this_val: Value, args: []const c.JSValue) Value {
    const ctx = ctx_opt.?;
    var this = this_val;

    if (args.len >= 1) {
        this.setPropertyStr(ctx, "x", Value.fromCVal(args[0]).dup(ctx)) catch return Value.exception;
    }
    if (args.len >= 2) {
        this.setPropertyStr(ctx, "y", Value.fromCVal(args[1]).dup(ctx)) catch return Value.exception;
    }

    return Value.undefined;
}

fn testPointToString(_: ?*Context, _: Value, _: []const c.JSValue) Value {
    return Value.initInt32(42);
}

test "PropertyFlags constants match C" {
    // Verify the packed struct matches C constants
    try testing.expectEqual(@as(c_int, 0x1), (PropertyFlags{ .configurable = true }).toInt());
    try testing.expectEqual(@as(c_int, 0x2), (PropertyFlags{ .writable = true }).toInt());
    try testing.expectEqual(@as(c_int, 0x4), (PropertyFlags{ .enumerable = true }).toInt());
    try testing.expectEqual(@as(c_int, 0x7), PropertyFlags.default.toInt());

    try testing.expectEqual(@as(c_int, c.JS_PROP_CONFIGURABLE), (PropertyFlags{ .configurable = true }).toInt());
    try testing.expectEqual(@as(c_int, c.JS_PROP_WRITABLE), (PropertyFlags{ .writable = true }).toInt());
    try testing.expectEqual(@as(c_int, c.JS_PROP_ENUMERABLE), (PropertyFlags{ .enumerable = true }).toInt());
    try testing.expectEqual(@as(c_int, c.JS_PROP_C_W_E), PropertyFlags.default.toInt());
}

test "GetPropertyNamesFlags constants match C" {
    try testing.expectEqual(@as(c_int, c.JS_GPN_STRING_MASK), GetPropertyNamesFlags.strings.toInt());
    try testing.expectEqual(@as(c_int, c.JS_GPN_SYMBOL_MASK), (GetPropertyNamesFlags{ .symbol_mask = true }).toInt());
    try testing.expectEqual(@as(c_int, c.JS_GPN_ENUM_ONLY), (GetPropertyNamesFlags{ .enum_only = true }).toInt());
}

test "definePropertyValueStr" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const obj = Value.initObject(ctx);
    defer obj.deinit(ctx);

    // Define a non-writable property
    _ = try obj.definePropertyValueStr(ctx, "readOnly", Value.initInt32(42), .{
        .configurable = true,
        .enumerable = true,
        .writable = false,
    });

    // Read the value
    const val = obj.getPropertyStr(ctx, "readOnly");
    defer val.deinit(ctx);
    try testing.expectEqual(@as(i32, 42), try val.toInt32(ctx));

    // Verify via JavaScript that it's not writable
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);
    try global.setPropertyStr(ctx, "testObj", obj.dup(ctx));

    // Attempt to write should fail silently (not in strict mode)
    const write_result = ctx.eval("testObj.readOnly = 100; testObj.readOnly", "<test>", .{});
    defer write_result.deinit(ctx);
    try testing.expectEqual(@as(i32, 42), try write_result.toInt32(ctx));
}

test "definePropertyValueUint32" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const arr = Value.initArray(ctx);
    defer arr.deinit(ctx);

    // Define array elements with specific flags
    _ = try arr.definePropertyValueUint32(ctx, 0, Value.initInt32(10), PropertyFlags.default);
    _ = try arr.definePropertyValueUint32(ctx, 1, Value.initInt32(20), PropertyFlags.default);
    _ = try arr.definePropertyValueUint32(ctx, 2, Value.initInt32(30), PropertyFlags.default);

    try testing.expectEqual(@as(i64, 3), try arr.getLength(ctx));

    const elem = arr.getPropertyUint32(ctx, 1);
    defer elem.deinit(ctx);
    try testing.expectEqual(@as(i32, 20), try elem.toInt32(ctx));
}

test "definePropertyGetSet" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // Create an object with a getter/setter via eval for simplicity
    const obj = ctx.eval(
        \\(function() {
        \\  var obj = { _value: 0 };
        \\  Object.defineProperty(obj, 'value', {
        \\    get: function() { return this._value * 2; },
        \\    set: function(v) { this._value = v; },
        \\    configurable: true,
        \\    enumerable: true
        \\  });
        \\  return obj;
        \\})()
    , "<test>", .{});
    defer obj.deinit(ctx);

    try testing.expect(!obj.isException());
    try testing.expect(obj.isObject());

    // Test setter
    try obj.setPropertyStr(ctx, "value", Value.initInt32(21));

    // Test getter (should return 42 = 21 * 2)
    const val = obj.getPropertyStr(ctx, "value");
    defer val.deinit(ctx);
    try testing.expectEqual(@as(i32, 42), try val.toInt32(ctx));
}

test "getOwnPropertyNames" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const obj = Value.initObject(ctx);
    defer obj.deinit(ctx);

    try obj.setPropertyStr(ctx, "a", Value.initInt32(1));
    try obj.setPropertyStr(ctx, "b", Value.initInt32(2));
    try obj.setPropertyStr(ctx, "c", Value.initInt32(3));

    const props = try obj.getOwnPropertyNames(ctx, GetPropertyNamesFlags.strings);
    defer Value.freePropertyEnum(ctx, props);

    try testing.expectEqual(@as(usize, 3), props.len);
}

test "getOwnProperty" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const obj = ctx.eval(
        \\(function() {
        \\  var obj = {};
        \\  Object.defineProperty(obj, 'prop', {
        \\    value: 42,
        \\    writable: false,
        \\    enumerable: true,
        \\    configurable: true
        \\  });
        \\  return obj;
        \\})()
    , "<test>", .{});
    defer obj.deinit(ctx);

    const atom = Atom.init(ctx, "prop");
    defer atom.deinit(ctx);

    var desc = (try obj.getOwnProperty(ctx, atom)).?;
    defer desc.deinit(ctx);

    try testing.expect(desc.flags.configurable);
    try testing.expect(desc.flags.enumerable);
    try testing.expect(!desc.flags.writable);
    try testing.expectEqual(@as(i32, 42), try desc.value.toInt32(ctx));
}

test "getOwnProperty nonexistent" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const obj = Value.initObject(ctx);
    defer obj.deinit(ctx);

    const atom = Atom.init(ctx, "nonexistent");
    defer atom.deinit(ctx);

    const desc = try obj.getOwnProperty(ctx, atom);
    try testing.expect(desc == null);
}

test "initObjectClass" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // Class ID 1 is JS_CLASS_OBJECT - creates a plain object
    const obj = Value.initObjectClass(ctx, @enumFromInt(1));
    defer obj.deinit(ctx);

    // Verify it's an object
    try testing.expect(obj.isObject());

    // Verify we can set properties on it
    try obj.setPropertyStr(ctx, "test", Value.initInt32(42));
    const val = obj.getPropertyStr(ctx, "test");
    defer val.deinit(ctx);
    try testing.expectEqual(@as(i32, 42), try val.toInt32(ctx));
}

test "invoke method by atom" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const obj = ctx.eval(
        \\({
        \\  value: 10,
        \\  add: function(x) { return this.value + x; }
        \\})
    , "<test>", .{});
    defer obj.deinit(ctx);

    const method_atom = Atom.init(ctx, "add");
    defer method_atom.deinit(ctx);

    const arg = Value.initInt32(5);
    const result = obj.invoke(ctx, method_atom, &.{arg});
    defer result.deinit(ctx);

    try testing.expect(!result.isException());
    try testing.expectEqual(@as(i32, 15), try result.toInt32(ctx));
}

test "callConstructor2 with custom new.target" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const ctor = ctx.eval(
        \\(function MyClass(value) {
        \\  this.value = value;
        \\})
    , "<test>", .{});
    defer ctor.deinit(ctx);

    const arg = Value.initInt32(42);
    const result = ctor.callConstructor2(ctx, ctor, &.{arg});
    defer result.deinit(ctx);

    try testing.expect(!result.isException());
    try testing.expect(result.isObject());

    const val = result.getPropertyStr(ctx, "value");
    defer val.deinit(ctx);
    try testing.expectEqual(@as(i32, 42), try val.toInt32(ctx));
}
