const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("quickjs_c");
const Atom = @import("atom.zig").Atom;
const ModuleDef = @import("module.zig").ModuleDef;
const Runtime = @import("runtime.zig").Runtime;
const Value = @import("value.zig").Value;
const class = @import("class.zig");

/// Wrapper for the QuickJS `JSContext`.
///
/// A context represents an isolated JavaScript execution environment
/// with its own global object and set of built-in objects. Multiple
/// contexts can be created from the same runtime and share atoms
/// and certain resources, but have separate global states.
pub const Context = opaque {
    /// Creates a new JavaScript context within the given runtime.
    ///
    /// The context must be freed with `deinit` when no longer needed.
    /// Contexts must be freed before freeing the runtime they belong to.
    ///
    /// C: `JS_NewContext`
    pub fn init(rt: *Runtime) Allocator.Error!*Context {
        const ctx = c.JS_NewContext(rt.cval());
        if (ctx == null) return error.OutOfMemory;
        return @ptrCast(ctx);
    }

    /// Creates a raw JavaScript context without any intrinsic objects.
    ///
    /// Use this to create a minimal context, then add only the intrinsics
    /// you need with the `addIntrinsic*` methods.
    ///
    /// C: `JS_NewContextRaw`
    pub fn initRaw(rt: *Runtime) Allocator.Error!*Context {
        const ctx = c.JS_NewContextRaw(rt.cval());
        if (ctx == null) return error.OutOfMemory;
        return @ptrCast(ctx);
    }

    /// Frees the JavaScript context and all associated resources.
    ///
    /// All values created in this context should be freed before
    /// calling this function.
    ///
    /// C: `JS_FreeContext`
    pub fn deinit(self: *Context) void {
        c.JS_FreeContext(self.cval());
    }

    pub inline fn cval(self: *Context) *c.JSContext {
        return @ptrCast(self);
    }

    /// Gets the runtime associated with this context.
    ///
    /// C: `JS_GetRuntime`
    pub fn getRuntime(self: *Context) *Runtime {
        return @ptrCast(c.JS_GetRuntime(self.cval()));
    }

    /// Gets the global object for this context.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_GetGlobalObject`
    pub fn getGlobalObject(self: *Context) Value {
        return Value.fromCVal(c.JS_GetGlobalObject(self.cval()));
    }

    /// Gets the current exception, if any.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_GetException`
    pub fn getException(self: *Context) Value {
        return Value.fromCVal(c.JS_GetException(self.cval()));
    }

    /// Checks if there is a pending exception.
    ///
    /// C: `JS_HasException`
    pub fn hasException(self: *Context) bool {
        return c.JS_HasException(self.cval());
    }

    /// Resets the uncatchable error flag on the current exception.
    ///
    /// C: `JS_ResetUncatchableError`
    pub fn resetUncatchableError(self: *Context) void {
        c.JS_ResetUncatchableError(self.cval());
    }

    /// Frees a C string allocated by QuickJS.
    ///
    /// C: `JS_FreeCString`
    pub fn freeCString(self: *Context, ptr: [*:0]const u8) void {
        c.JS_FreeCString(self.cval(), ptr);
    }

    /// Throws an out of memory exception.
    ///
    /// C: `JS_ThrowOutOfMemory`
    pub fn throwOutOfMemory(self: *Context) Value {
        return Value.fromCVal(c.JS_ThrowOutOfMemory(self.cval()));
    }

    /// Evaluates JavaScript code and returns the result.
    ///
    /// The input is evaluated as a script (not a module) by default.
    /// Use `flags` to customize evaluation behavior.
    ///
    /// The returned value must be freed with `Value.deinit` when no
    /// longer needed. Check `Value.isException` to detect errors.
    ///
    /// C: `JS_Eval`
    pub fn eval(self: *Context, input: []const u8, filename: [:0]const u8, flags: EvalFlags) Value {
        return Value.fromCVal(c.JS_Eval(
            self.cval(),
            input.ptr,
            input.len,
            filename.ptr,
            @bitCast(flags),
        ));
    }

    /// Evaluates JavaScript code with extended options.
    ///
    /// This is an extended version of `eval` that accepts an `EvalOptions`
    /// struct for more control over evaluation, including line number offset.
    ///
    /// The returned value must be freed with `Value.deinit` when no
    /// longer needed. Check `Value.isException` to detect errors.
    ///
    /// C: `JS_Eval2`
    pub fn eval2(self: *Context, input: []const u8, options: *EvalOptions) Value {
        return Value.fromCVal(c.JS_Eval2(
            self.cval(),
            input.ptr,
            input.len,
            @ptrCast(options),
        ));
    }

    /// Evaluates JavaScript code with a custom `this` object.
    ///
    /// The returned value must be freed with `Value.deinit` when no
    /// longer needed. Check `Value.isException` to detect errors.
    ///
    /// C: `JS_EvalThis`
    pub fn evalThis(self: *Context, this_obj: Value, input: []const u8, filename: [:0]const u8, flags: EvalFlags) Value {
        return Value.fromCVal(c.JS_EvalThis(
            self.cval(),
            this_obj.cval(),
            input.ptr,
            input.len,
            filename.ptr,
            @bitCast(flags),
        ));
    }

    /// Evaluates JavaScript code with a custom `this` object and extended options.
    ///
    /// This combines the functionality of `evalThis` and `eval2`.
    ///
    /// The returned value must be freed with `Value.deinit` when no
    /// longer needed. Check `Value.isException` to detect errors.
    ///
    /// C: `JS_EvalThis2`
    pub fn evalThis2(self: *Context, this_obj: Value, input: []const u8, options: *EvalOptions) Value {
        return Value.fromCVal(c.JS_EvalThis2(
            self.cval(),
            this_obj.cval(),
            input.ptr,
            input.len,
            @ptrCast(options),
        ));
    }

    /// Executes a compiled bytecode function.
    ///
    /// The function object must be a bytecode function created with
    /// `EvalFlags.compile_only = true`. Takes ownership of the function
    /// object.
    ///
    /// The returned value must be freed with `Value.deinit` when no
    /// longer needed. Check `Value.isException` to detect errors.
    ///
    /// C: `JS_EvalFunction`
    pub fn evalFunction(self: *Context, func_obj: Value) Value {
        return Value.fromCVal(c.JS_EvalFunction(self.cval(), func_obj.cval()));
    }

    // =========================================================================
    // Module Loading
    // =========================================================================

    /// Loads a module by filename.
    ///
    /// Uses the module loader function set on the runtime. The basename
    /// is used for resolving relative imports within the module.
    ///
    /// Returns the module value or an exception on error.
    ///
    /// C: `JS_LoadModule`
    pub fn loadModule(self: *Context, basename: [*:0]const u8, filename: [*:0]const u8) Value {
        return Value.fromCVal(c.JS_LoadModule(self.cval(), basename, filename));
    }

    /// Gets the name of the current script or module.
    ///
    /// The `n_stack_levels` parameter specifies how many stack levels to
    /// go up (0 = current function).
    ///
    /// Returns the script/module name as an atom, or `Atom.null` if not available.
    /// The returned atom must be freed with `Atom.deinit`.
    ///
    /// C: `JS_GetScriptOrModuleName`
    pub fn getScriptOrModuleName(self: *Context, n_stack_levels: i32) Atom {
        return @enumFromInt(c.JS_GetScriptOrModuleName(self.cval(), n_stack_levels));
    }

    // =========================================================================
    // Job Queue
    // =========================================================================

    /// Enqueues a job to be executed later.
    ///
    /// The job function will be called with the provided arguments when
    /// `Runtime.executePendingJob` is called. The arguments are duplicated
    /// (reference count incremented) when enqueued and freed after the job runs.
    ///
    /// Returns an error if the job could not be enqueued.
    ///
    /// C: `JS_EnqueueJob`
    pub fn enqueueJob(
        self: *Context,
        comptime job_func: *const fn (*Context, []const Value) Value,
        args: []const Value,
    ) Allocator.Error!void {
        const Wrapper = struct {
            fn callback(
                ctx: ?*c.JSContext,
                argc: c_int,
                argv: [*c]c.JSValue,
            ) callconv(.c) c.JSValue {
                const zig_ctx: *Context = @ptrCast(ctx);
                const zig_args: []const Value = if (argc > 0)
                    @ptrCast(argv[0..@intCast(argc)])
                else
                    &.{};
                return @call(.always_inline, job_func, .{ zig_ctx, zig_args }).cval();
            }
        };
        const result = c.JS_EnqueueJob(
            self.cval(),
            &Wrapper.callback,
            @intCast(args.len),
            @ptrCast(@constCast(args.ptr)),
        );
        if (result < 0) return error.OutOfMemory;
    }

    // =========================================================================
    // Context Duplication
    // =========================================================================

    /// Duplicates the context, incrementing its reference count.
    ///
    /// The returned context must also be freed with `deinit`.
    ///
    /// C: `JS_DupContext`
    pub fn dup(self: *Context) *Context {
        return @ptrCast(c.JS_DupContext(self.cval()));
    }

    // =========================================================================
    // Opaque Data
    // =========================================================================

    /// Gets the opaque pointer associated with this context.
    ///
    /// C: `JS_GetContextOpaque`
    pub fn getOpaque(self: *Context, comptime T: type) ?*T {
        return @ptrCast(@alignCast(c.JS_GetContextOpaque(self.cval())));
    }

    /// Sets the opaque pointer for this context.
    ///
    /// C: `JS_SetContextOpaque`
    pub fn setOpaque(self: *Context, comptime T: type, ptr: ?*T) void {
        c.JS_SetContextOpaque(self.cval(), ptr);
    }

    // =========================================================================
    // Intrinsics
    // =========================================================================

    /// Adds base objects (Object, Function, Array, etc.).
    ///
    /// C: `JS_AddIntrinsicBaseObjects`
    pub fn addIntrinsicBaseObjects(self: *Context) void {
        c.JS_AddIntrinsicBaseObjects(self.cval());
    }

    /// Adds the Date constructor and prototype.
    ///
    /// C: `JS_AddIntrinsicDate`
    pub fn addIntrinsicDate(self: *Context) void {
        c.JS_AddIntrinsicDate(self.cval());
    }

    /// Adds eval() function.
    ///
    /// C: `JS_AddIntrinsicEval`
    pub fn addIntrinsicEval(self: *Context) void {
        c.JS_AddIntrinsicEval(self.cval());
    }

    /// Adds RegExp compiler (needed for literal regexp support).
    ///
    /// C: `JS_AddIntrinsicRegExpCompiler`
    pub fn addIntrinsicRegExpCompiler(self: *Context) void {
        c.JS_AddIntrinsicRegExpCompiler(self.cval());
    }

    /// Adds the RegExp constructor and prototype.
    ///
    /// C: `JS_AddIntrinsicRegExp`
    pub fn addIntrinsicRegExp(self: *Context) void {
        c.JS_AddIntrinsicRegExp(self.cval());
    }

    /// Adds JSON object with parse() and stringify().
    ///
    /// C: `JS_AddIntrinsicJSON`
    pub fn addIntrinsicJSON(self: *Context) void {
        c.JS_AddIntrinsicJSON(self.cval());
    }

    /// Adds the Proxy constructor and Reflect object.
    ///
    /// C: `JS_AddIntrinsicProxy`
    pub fn addIntrinsicProxy(self: *Context) void {
        c.JS_AddIntrinsicProxy(self.cval());
    }

    /// Adds Map and Set constructors and prototypes.
    ///
    /// C: `JS_AddIntrinsicMapSet`
    pub fn addIntrinsicMapSet(self: *Context) void {
        c.JS_AddIntrinsicMapSet(self.cval());
    }

    /// Adds TypedArray and ArrayBuffer constructors.
    ///
    /// C: `JS_AddIntrinsicTypedArrays`
    pub fn addIntrinsicTypedArrays(self: *Context) void {
        c.JS_AddIntrinsicTypedArrays(self.cval());
    }

    /// Adds Promise constructor and related functions.
    ///
    /// C: `JS_AddIntrinsicPromise`
    pub fn addIntrinsicPromise(self: *Context) void {
        c.JS_AddIntrinsicPromise(self.cval());
    }

    /// Adds BigInt constructor and prototype.
    ///
    /// C: `JS_AddIntrinsicBigInt`
    pub fn addIntrinsicBigInt(self: *Context) void {
        c.JS_AddIntrinsicBigInt(self.cval());
    }

    /// Adds WeakRef and FinalizationRegistry.
    ///
    /// C: `JS_AddIntrinsicWeakRef`
    pub fn addIntrinsicWeakRef(self: *Context) void {
        c.JS_AddIntrinsicWeakRef(self.cval());
    }

    /// Adds performance object with now().
    ///
    /// C: `JS_AddPerformance`
    pub fn addPerformance(self: *Context) void {
        c.JS_AddPerformance(self.cval());
    }

    /// Adds DOMException constructor.
    ///
    /// C: `JS_AddIntrinsicDOMException`
    pub fn addIntrinsicDOMException(self: *Context) void {
        c.JS_AddIntrinsicDOMException(self.cval());
    }

    // =========================================================================
    // Class Prototypes
    // =========================================================================

    /// Gets the prototype for a class ID.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_GetClassProto`
    pub fn getClassProto(self: *Context, class_id: class.Id) Value {
        return Value.fromCVal(c.JS_GetClassProto(self.cval(), @intFromEnum(class_id)));
    }

    /// Sets the prototype for a class ID.
    ///
    /// Takes ownership of the prototype value.
    ///
    /// C: `JS_SetClassProto`
    pub fn setClassProto(self: *Context, class_id: class.Id, proto: Value) void {
        c.JS_SetClassProto(self.cval(), @intFromEnum(class_id), proto.cval());
    }

    /// Gets the Function prototype object.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_GetFunctionProto`
    pub fn getFunctionProto(self: *Context) Value {
        return Value.fromCVal(c.JS_GetFunctionProto(self.cval()));
    }

    // =========================================================================
    // Error Factories
    // =========================================================================

    /// Creates a new TypeError object (does not throw).
    ///
    /// C: `JS_NewTypeError`
    pub fn newTypeError(self: *Context, msg: [:0]const u8) Value {
        return Value.fromCVal(c.JS_NewTypeError(self.cval(), "%s", msg.ptr));
    }

    /// Creates a new SyntaxError object (does not throw).
    ///
    /// C: `JS_NewSyntaxError`
    pub fn newSyntaxError(self: *Context, msg: [:0]const u8) Value {
        return Value.fromCVal(c.JS_NewSyntaxError(self.cval(), "%s", msg.ptr));
    }

    /// Creates a new ReferenceError object (does not throw).
    ///
    /// C: `JS_NewReferenceError`
    pub fn newReferenceError(self: *Context, msg: [:0]const u8) Value {
        return Value.fromCVal(c.JS_NewReferenceError(self.cval(), "%s", msg.ptr));
    }

    /// Creates a new RangeError object (does not throw).
    ///
    /// C: `JS_NewRangeError`
    pub fn newRangeError(self: *Context, msg: [:0]const u8) Value {
        return Value.fromCVal(c.JS_NewRangeError(self.cval(), "%s", msg.ptr));
    }

    /// Creates a new InternalError object (does not throw).
    ///
    /// C: `JS_NewInternalError`
    pub fn newInternalError(self: *Context, msg: [:0]const u8) Value {
        return Value.fromCVal(c.JS_NewInternalError(self.cval(), "%s", msg.ptr));
    }

    /// Throws a TypeError and returns the exception value.
    ///
    /// C: `JS_ThrowTypeError`
    pub fn throwTypeError(self: *Context, msg: [:0]const u8) Value {
        return Value.fromCVal(c.JS_ThrowTypeError(self.cval(), "%s", msg.ptr));
    }

    /// Throws a SyntaxError and returns the exception value.
    ///
    /// C: `JS_ThrowSyntaxError`
    pub fn throwSyntaxError(self: *Context, msg: [:0]const u8) Value {
        return Value.fromCVal(c.JS_ThrowSyntaxError(self.cval(), "%s", msg.ptr));
    }

    /// Throws a ReferenceError and returns the exception value.
    ///
    /// C: `JS_ThrowReferenceError`
    pub fn throwReferenceError(self: *Context, msg: [:0]const u8) Value {
        return Value.fromCVal(c.JS_ThrowReferenceError(self.cval(), "%s", msg.ptr));
    }

    /// Throws a RangeError and returns the exception value.
    ///
    /// C: `JS_ThrowRangeError`
    pub fn throwRangeError(self: *Context, msg: [:0]const u8) Value {
        return Value.fromCVal(c.JS_ThrowRangeError(self.cval(), "%s", msg.ptr));
    }

    /// Throws an InternalError and returns the exception value.
    ///
    /// C: `JS_ThrowInternalError`
    pub fn throwInternalError(self: *Context, msg: [:0]const u8) Value {
        return Value.fromCVal(c.JS_ThrowInternalError(self.cval(), "%s", msg.ptr));
    }
};

/// Evaluation flags for `Context.eval`.
///
/// C: `JS_EVAL_TYPE_*` and `JS_EVAL_FLAG_*`
pub const EvalFlags = packed struct(c_int) {
    /// Evaluation type (2 bits).
    /// - global (0): evaluate in global scope
    /// - module (1): evaluate as ES module
    /// - direct (2): direct call to eval
    /// - indirect (3): indirect call to eval
    type: Type = .global,
    _reserved: u1 = 0,
    /// Force strict mode.
    strict: bool = false,
    _unused: u1 = 0,
    /// Compile but don't run (returns bytecode).
    compile_only: bool = false,
    /// Don't include stack frames in Error objects.
    backtrace_barrier: bool = false,
    /// Evaluate as async module.
    async_module: bool = false,
    _padding: u24 = 0,

    pub const Type = enum(u2) {
        global = 0,
        module = 1,
        direct = 2,
        indirect = 3,
    };
};

/// Extended evaluation options for `eval2` and `evalThis2`.
///
/// C: `JSEvalOptions`
pub const EvalOptions = extern struct {
    /// Version field for ABI compatibility.
    version: c_int = c.JS_EVAL_OPTIONS_VERSION,
    /// Evaluation flags (type and behavior modifiers).
    flags: EvalFlags = .{},
    /// Source filename for error messages.
    filename: [*:0]const u8 = "<eval>",
    /// Starting line number for error messages (1-based).
    line_num: c_int = 1,
};

comptime {
    std.debug.assert(c.JS_EVAL_OPTIONS_VERSION == 1);
    std.debug.assert(@sizeOf(EvalOptions) == @sizeOf(c.JSEvalOptions));
    std.debug.assert(@alignOf(EvalOptions) == @alignOf(c.JSEvalOptions));
}

test "Context init and deinit" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();
}

test "EvalFlags bit layout matches C header" {
    const testing = std.testing;

    // Type values (bits 0-1)
    try testing.expectEqual(c.JS_EVAL_TYPE_GLOBAL, @as(c_int, @bitCast(EvalFlags{ .type = .global })));
    try testing.expectEqual(c.JS_EVAL_TYPE_MODULE, @as(c_int, @bitCast(EvalFlags{ .type = .module })));
    try testing.expectEqual(c.JS_EVAL_TYPE_DIRECT, @as(c_int, @bitCast(EvalFlags{ .type = .direct })));
    try testing.expectEqual(c.JS_EVAL_TYPE_INDIRECT, @as(c_int, @bitCast(EvalFlags{ .type = .indirect })));

    // Flag values (bits 3, 5-7)
    try testing.expectEqual(c.JS_EVAL_FLAG_STRICT, @as(c_int, @bitCast(EvalFlags{ .strict = true })));
    try testing.expectEqual(c.JS_EVAL_FLAG_COMPILE_ONLY, @as(c_int, @bitCast(EvalFlags{ .compile_only = true })));
    try testing.expectEqual(c.JS_EVAL_FLAG_BACKTRACE_BARRIER, @as(c_int, @bitCast(EvalFlags{ .backtrace_barrier = true })));
    try testing.expectEqual(c.JS_EVAL_FLAG_ASYNC, @as(c_int, @bitCast(EvalFlags{ .async_module = true })));

    // Combined flags
    try testing.expectEqual(
        c.JS_EVAL_TYPE_MODULE | c.JS_EVAL_FLAG_STRICT,
        @as(c_int, @bitCast(EvalFlags{ .type = .module, .strict = true })),
    );
}

test "Context dup" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const ctx2 = ctx.dup();
    defer ctx2.deinit();

    // Both contexts should work and share the same runtime
    try std.testing.expectEqual(rt, ctx2.getRuntime());

    // Both should be able to evaluate
    const result = ctx2.eval("1 + 1", "<test>", .{});
    defer result.deinit(ctx2);
    try std.testing.expectEqual(@as(i32, 2), try result.toInt32(ctx2));
}

test "Context opaque data" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const TestData = struct {
        value: i32,
    };

    var data: TestData = .{ .value = 42 };

    // Initially null
    try std.testing.expectEqual(@as(?*TestData, null), ctx.getOpaque(TestData));

    // Set opaque
    ctx.setOpaque(TestData, &data);

    // Get opaque
    const retrieved = ctx.getOpaque(TestData);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(i32, 42), retrieved.?.value);

    // Modify through pointer
    retrieved.?.value = 100;
    try std.testing.expectEqual(@as(i32, 100), data.value);

    // Clear
    ctx.setOpaque(TestData, null);
    try std.testing.expectEqual(@as(?*TestData, null), ctx.getOpaque(TestData));
}

test "Context initRaw" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .initRaw(rt);
    defer ctx.deinit();

    // Just test that raw context can be created
    try std.testing.expectEqual(rt, ctx.getRuntime());
}

test "Context addIntrinsicBaseObjects" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .initRaw(rt);
    defer ctx.deinit();

    // Just test that the method doesn't crash
    ctx.addIntrinsicBaseObjects();
}

test "Context addIntrinsicDate" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // Date should already be available in normal context
    const result = ctx.eval("new Date(0).getTime()", "<test>", .{});
    defer result.deinit(ctx);
    try std.testing.expectEqual(@as(i64, 0), try result.toInt64(ctx));
}

test "Context addIntrinsicEval" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .initRaw(rt);
    defer ctx.deinit();

    ctx.addIntrinsicBaseObjects();
    ctx.addIntrinsicEval();

    // eval() should work now
    const result = ctx.eval("eval('2 + 3')", "<test>", .{});
    defer result.deinit(ctx);
    try std.testing.expectEqual(@as(i32, 5), try result.toInt32(ctx));
}

test "Context addIntrinsicJSON" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // JSON should work
    const result = ctx.eval("JSON.parse('{\"a\": 42}').a", "<test>", .{});
    defer result.deinit(ctx);
    try std.testing.expectEqual(@as(i32, 42), try result.toInt32(ctx));
}

test "Context addIntrinsicMapSet" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // Map and Set should work
    const result = ctx.eval(
        \\const m = new Map();
        \\m.set('key', 123);
        \\m.get('key')
    , "<test>", .{});
    defer result.deinit(ctx);
    try std.testing.expectEqual(@as(i32, 123), try result.toInt32(ctx));
}

test "Context addIntrinsicPromise" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // Promise should work
    const result = ctx.eval("new Promise((r) => r(42))", "<test>", .{});
    defer result.deinit(ctx);
    try std.testing.expect(result.isPromise());
}

test "Context addIntrinsicBigInt" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // BigInt should work
    const result = ctx.eval("BigInt(9007199254740991)", "<test>", .{});
    defer result.deinit(ctx);
    try std.testing.expect(result.isBigInt());
}

test "Context addIntrinsicRegExp" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // RegExp should work
    const result = ctx.eval("/test/.test('test')", "<test>", .{});
    defer result.deinit(ctx);
    try std.testing.expect(try result.toBool(ctx));
}

test "Context addIntrinsicProxy" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // Proxy should work
    const result = ctx.eval(
        \\const target = { a: 1 };
        \\const p = new Proxy(target, {});
        \\p.a
    , "<test>", .{});
    defer result.deinit(ctx);
    try std.testing.expectEqual(@as(i32, 1), try result.toInt32(ctx));
}

test "Context addIntrinsicTypedArrays" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // TypedArray should work
    const result = ctx.eval(
        \\const arr = new Uint8Array([1, 2, 3]);
        \\arr[1]
    , "<test>", .{});
    defer result.deinit(ctx);
    try std.testing.expectEqual(@as(i32, 2), try result.toInt32(ctx));
}

test "Context addPerformance" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    // Use a full context since performance depends on other intrinsics
    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // performance object should exist (added by default)
    const result = ctx.eval("typeof performance", "<test>", .{});
    defer result.deinit(ctx);
    const str = result.toCString(ctx).?;
    defer ctx.freeCString(str);
    try std.testing.expectEqualStrings("object", std.mem.span(str));

    // performance.now() should return a number
    const result2 = ctx.eval("typeof performance.now()", "<test>", .{});
    defer result2.deinit(ctx);
    const str2 = result2.toCString(ctx).?;
    defer ctx.freeCString(str2);
    try std.testing.expectEqualStrings("number", std.mem.span(str2));
}

test "Context getFunctionProto" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const func_proto = ctx.getFunctionProto();
    defer func_proto.deinit(ctx);

    try std.testing.expect(func_proto.isObject());

    // Verify it's the actual Function.prototype
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);
    const func_ctor = global.getPropertyStr(ctx, "Function");
    defer func_ctor.deinit(ctx);
    const expected_proto = func_ctor.getPropertyStr(ctx, "prototype");
    defer expected_proto.deinit(ctx);

    try std.testing.expect(func_proto.isStrictEqual(ctx, expected_proto));
}

test "Context newTypeError" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const err = ctx.newTypeError("test type error");
    defer err.deinit(ctx);

    try std.testing.expect(err.isError());

    // Verify it's a TypeError by checking constructor name
    const ctor = err.getPropertyStr(ctx, "constructor");
    defer ctor.deinit(ctx);
    const name = ctor.getPropertyStr(ctx, "name");
    defer name.deinit(ctx);
    const str = name.toCString(ctx).?;
    defer ctx.freeCString(str);
    try std.testing.expectEqualStrings("TypeError", std.mem.span(str));
}

test "Context newSyntaxError" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const err = ctx.newSyntaxError("test syntax error");
    defer err.deinit(ctx);

    try std.testing.expect(err.isError());

    const ctor = err.getPropertyStr(ctx, "constructor");
    defer ctor.deinit(ctx);
    const name = ctor.getPropertyStr(ctx, "name");
    defer name.deinit(ctx);
    const str = name.toCString(ctx).?;
    defer ctx.freeCString(str);
    try std.testing.expectEqualStrings("SyntaxError", std.mem.span(str));
}

test "Context newReferenceError" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const err = ctx.newReferenceError("test reference error");
    defer err.deinit(ctx);

    try std.testing.expect(err.isError());

    const ctor = err.getPropertyStr(ctx, "constructor");
    defer ctor.deinit(ctx);
    const name = ctor.getPropertyStr(ctx, "name");
    defer name.deinit(ctx);
    const str = name.toCString(ctx).?;
    defer ctx.freeCString(str);
    try std.testing.expectEqualStrings("ReferenceError", std.mem.span(str));
}

test "Context newRangeError" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const err = ctx.newRangeError("test range error");
    defer err.deinit(ctx);

    try std.testing.expect(err.isError());

    const ctor = err.getPropertyStr(ctx, "constructor");
    defer ctor.deinit(ctx);
    const name = ctor.getPropertyStr(ctx, "name");
    defer name.deinit(ctx);
    const str = name.toCString(ctx).?;
    defer ctx.freeCString(str);
    try std.testing.expectEqualStrings("RangeError", std.mem.span(str));
}

test "Context newInternalError" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const err = ctx.newInternalError("test internal error");
    defer err.deinit(ctx);

    try std.testing.expect(err.isError());

    const ctor = err.getPropertyStr(ctx, "constructor");
    defer ctor.deinit(ctx);
    const name = ctor.getPropertyStr(ctx, "name");
    defer name.deinit(ctx);
    const str = name.toCString(ctx).?;
    defer ctx.freeCString(str);
    try std.testing.expectEqualStrings("InternalError", std.mem.span(str));
}

test "Context throwTypeError" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const result = ctx.throwTypeError("expected a number");
    defer result.deinit(ctx);

    try std.testing.expect(result.isException());
    try std.testing.expect(ctx.hasException());

    const exc = ctx.getException();
    defer exc.deinit(ctx);
    try std.testing.expect(exc.isError());

    const msg = exc.getPropertyStr(ctx, "message");
    defer msg.deinit(ctx);
    const str = msg.toCString(ctx).?;
    defer ctx.freeCString(str);
    try std.testing.expectEqualStrings("expected a number", std.mem.span(str));
}

test "Context throwSyntaxError" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const result = ctx.throwSyntaxError("unexpected token");
    defer result.deinit(ctx);

    try std.testing.expect(result.isException());
    try std.testing.expect(ctx.hasException());

    const exc = ctx.getException();
    defer exc.deinit(ctx);
    try std.testing.expect(exc.isError());
}

test "Context throwReferenceError" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const result = ctx.throwReferenceError("x is not defined");
    defer result.deinit(ctx);

    try std.testing.expect(result.isException());
    try std.testing.expect(ctx.hasException());

    const exc = ctx.getException();
    defer exc.deinit(ctx);
    try std.testing.expect(exc.isError());
}

test "Context throwRangeError" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const result = ctx.throwRangeError("value out of range");
    defer result.deinit(ctx);

    try std.testing.expect(result.isException());
    try std.testing.expect(ctx.hasException());

    const exc = ctx.getException();
    defer exc.deinit(ctx);
    try std.testing.expect(exc.isError());
}

test "Context throwInternalError" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const result = ctx.throwInternalError("internal failure");
    defer result.deinit(ctx);

    try std.testing.expect(result.isException());
    try std.testing.expect(ctx.hasException());

    const exc = ctx.getException();
    defer exc.deinit(ctx);
    try std.testing.expect(exc.isError());
}

test "Context error message preserved in JavaScript" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    // Throw a TypeError
    _ = ctx.throwTypeError("custom error message");

    // Get the exception and verify message
    const exc = ctx.getException();
    defer exc.deinit(ctx);

    const msg = exc.getPropertyStr(ctx, "message");
    defer msg.deinit(ctx);
    const str = msg.toCString(ctx).?;
    defer ctx.freeCString(str);
    try std.testing.expectEqualStrings("custom error message", std.mem.span(str));

    // Verify stack trace exists
    const stack = exc.getPropertyStr(ctx, "stack");
    defer stack.deinit(ctx);
    try std.testing.expect(stack.isString());
}

test "Context raw with selective intrinsics" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    // Create a minimal context with only what we need
    const ctx: *Context = try .initRaw(rt);
    defer ctx.deinit();

    // Test that we can add multiple intrinsics without crashing
    ctx.addIntrinsicBaseObjects();
    ctx.addIntrinsicJSON();
    ctx.addIntrinsicDate();
    ctx.addIntrinsicPromise();

    // The context should still be valid
    try std.testing.expectEqual(rt, ctx.getRuntime());
}

test "Context getScriptOrModuleName in module" {
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
            if (!std.mem.eql(u8, name, "name_test")) return null;

            const m = ModuleDef.init(load_ctx, name, initFn) orelse return null;
            _ = m.addExport(load_ctx, "dummy");
            return m;
        }

        fn initFn(init_ctx: *Context, m: *ModuleDef) bool {
            if (!m.setExport(init_ctx, "dummy", Value.initInt32(1))) return false;
            return true;
        }
    };

    rt.setModuleLoaderFunc(void, {}, null, loader.load);

    const result = ctx.eval(
        \\import { dummy } from "name_test";
        \\dummy
    , "test_script.js", .{ .type = .module });
    defer result.deinit(ctx);

    try std.testing.expect(!result.isException());
}

test "Context loadModule with loader" {
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
            if (!std.mem.eql(u8, name, "loaded_module")) return null;

            const m = ModuleDef.init(load_ctx, name, initFn) orelse return null;
            _ = m.addExport(load_ctx, "value");
            return m;
        }

        fn initFn(init_ctx: *Context, m: *ModuleDef) bool {
            if (!m.setExport(init_ctx, "value", Value.initInt32(999))) return false;
            return true;
        }
    };

    rt.setModuleLoaderFunc(void, {}, null, loader.load);

    const result = ctx.loadModule(".", "loaded_module");
    defer result.deinit(ctx);

    try std.testing.expect(!result.isException());
}

test "Context eval2" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    var options: EvalOptions = .{
        .filename = "test.js",
        .line_num = 10,
    };
    const result = ctx.eval2("1 + 2", &options);
    defer result.deinit(ctx);

    try std.testing.expect(!result.isException());
    try std.testing.expectEqual(@as(i32, 3), try result.toInt32(ctx));
}

test "Context evalThis" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const this_obj = Value.initObject(ctx);
    defer this_obj.deinit(ctx);
    try this_obj.setPropertyStr(ctx, "x", Value.initInt32(42));

    const result = ctx.evalThis(this_obj, "this.x", "<test>", .{});
    defer result.deinit(ctx);

    try std.testing.expect(!result.isException());
    try std.testing.expectEqual(@as(i32, 42), try result.toInt32(ctx));
}

test "Context evalThis2" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const this_obj = Value.initObject(ctx);
    defer this_obj.deinit(ctx);
    try this_obj.setPropertyStr(ctx, "value", Value.initInt32(100));

    var options: EvalOptions = .{
        .filename = "custom.js",
        .line_num = 5,
    };
    const result = ctx.evalThis2(this_obj, "this.value * 2", &options);
    defer result.deinit(ctx);

    try std.testing.expect(!result.isException());
    try std.testing.expectEqual(@as(i32, 200), try result.toInt32(ctx));
}

test "Context evalFunction" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const bytecode = ctx.eval("1 + 2", "<test>", .{ .compile_only = true });
    try std.testing.expect(!bytecode.isException());

    const result = ctx.evalFunction(bytecode);
    defer result.deinit(ctx);

    try std.testing.expect(!result.isException());
    try std.testing.expectEqual(@as(i32, 3), try result.toInt32(ctx));
}

test "Context enqueueJob" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    try global.setPropertyStr(ctx, "jobRan", Value.initBool(false));

    const job = struct {
        fn run(job_ctx: *Context, _: []const Value) Value {
            const g = job_ctx.getGlobalObject();
            defer g.deinit(job_ctx);
            g.setPropertyStr(job_ctx, "jobRan", Value.initBool(true)) catch {};
            return Value.undefined;
        }
    };

    try ctx.enqueueJob(job.run, &.{});

    try std.testing.expect(rt.isJobPending());

    _ = try rt.executePendingJob();

    const ran = global.getPropertyStr(ctx, "jobRan");
    defer ran.deinit(ctx);
    try std.testing.expect(try ran.toBool(ctx));
}
