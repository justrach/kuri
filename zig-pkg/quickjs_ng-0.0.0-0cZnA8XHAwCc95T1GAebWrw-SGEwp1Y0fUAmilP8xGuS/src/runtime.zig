const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("quickjs_c");
const Context = @import("context.zig").Context;
const ModuleDef = @import("module.zig").ModuleDef;
const typed_array = @import("typed_array.zig");
const Value = @import("value.zig").Value;
const class = @import("class.zig");
const Atom = @import("atom.zig").Atom;
const opaquepkg = @import("opaque.zig");
const Opaque = opaquepkg.Opaque;

/// Custom malloc functions for runtime memory allocation.
///
/// Note: A Zig `std.mem.Allocator` cannot be directly wrapped because
/// Zig allocators require the original allocation size for `free` and
/// `realloc`, but this C-style interface does not provide it. Use
/// allocators that internally track sizes (e.g., libc malloc via
/// `std.c.malloc`/`std.c.free`).
///
/// C: `JSMallocFunctions`
pub const MallocFunctions = extern struct {
    calloc: *const fn (?*anyopaque, usize, usize) callconv(.c) ?*anyopaque,
    malloc: *const fn (?*anyopaque, usize) callconv(.c) ?*anyopaque,
    free: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
    realloc: *const fn (?*anyopaque, ?*anyopaque, usize) callconv(.c) ?*anyopaque,
    malloc_usable_size: ?*const fn (?*const anyopaque) callconv(.c) usize = null,

    comptime {
        if (@sizeOf(MallocFunctions) != @sizeOf(c.JSMallocFunctions))
            @compileError("MallocFunctions size mismatch");
        if (@alignOf(MallocFunctions) != @alignOf(c.JSMallocFunctions))
            @compileError("MallocFunctions alignment mismatch");
    }
};

/// Wrapper for the QuickJS `JSRuntime`.
///
/// The runtime represents a JavaScript execution environment. It manages
/// memory allocation, garbage collection, and atom (interned string) tables
/// shared by all contexts created from it.
pub const Runtime = opaque {
    /// Creates a new JavaScript runtime.
    ///
    /// The runtime must be freed with `deinit` when no longer needed.
    /// All contexts created from this runtime must be freed before
    /// freeing the runtime itself.
    ///
    /// C: `JS_NewRuntime`
    pub fn init() Allocator.Error!*Runtime {
        const rt = c.JS_NewRuntime();
        if (rt == null) return error.OutOfMemory;
        return @ptrCast(rt);
    }

    /// Creates a new JavaScript runtime with custom malloc functions.
    ///
    /// This allows using a custom allocator for all runtime memory operations.
    /// The opaque pointer is passed to all malloc function callbacks.
    ///
    /// C: `JS_NewRuntime2`
    pub fn initWithMallocFunctions(mf: *const MallocFunctions, opaque_ptr: ?*anyopaque) Allocator.Error!*Runtime {
        const rt = c.JS_NewRuntime2(@ptrCast(mf), opaque_ptr);
        if (rt == null) return error.OutOfMemory;
        return @ptrCast(rt);
    }

    /// Frees the JavaScript runtime and all associated resources.
    ///
    /// All contexts created from this runtime must be freed before
    /// calling this function. If `JS_DUMP_LEAKS` or similar dump flags
    /// were set, this will output diagnostic information about leaked
    /// objects, strings, atoms, or memory.
    ///
    /// C: `JS_FreeRuntime`
    pub fn deinit(self: *Runtime) void {
        c.JS_FreeRuntime(self.cval());
    }

    /// Creates a new JavaScript context within this runtime.
    ///
    /// The context must be freed with `Context.deinit` when no longer needed.
    /// Contexts must be freed before freeing the runtime they belong to.
    ///
    /// C: `JS_NewContext`
    pub fn newContext(self: *Runtime) Allocator.Error!*Context {
        return Context.init(self);
    }

    /// Creates a raw JavaScript context without any intrinsic objects.
    ///
    /// Use this to create a minimal context, then add only the intrinsics
    /// you need with `addIntrinsic*` methods.
    ///
    /// C: `JS_NewContextRaw`
    pub fn newContextRaw(self: *Runtime) Allocator.Error!*Context {
        return Context.initRaw(self);
    }

    // =========================================================================
    // Runtime Configuration
    // =========================================================================

    /// Sets runtime description for debugging purposes.
    ///
    /// The info string lifetime must exceed that of the runtime.
    ///
    /// C: `JS_SetRuntimeInfo`
    pub fn setInfo(self: *Runtime, info: [:0]const u8) void {
        c.JS_SetRuntimeInfo(self.cval(), info.ptr);
    }

    /// Sets the memory limit for the runtime.
    ///
    /// Use 0 to disable the memory limit.
    ///
    /// C: `JS_SetMemoryLimit`
    pub fn setMemoryLimit(self: *Runtime, limit: usize) void {
        c.JS_SetMemoryLimit(self.cval(), limit);
    }

    /// Sets the maximum stack size for the runtime.
    ///
    /// Use 0 to disable the stack size check.
    ///
    /// C: `JS_SetMaxStackSize`
    pub fn setMaxStackSize(self: *Runtime, size: usize) void {
        c.JS_SetMaxStackSize(self.cval(), size);
    }

    /// Updates the stack top value used to check stack overflow.
    ///
    /// Should be called when changing threads.
    ///
    /// C: `JS_UpdateStackTop`
    pub fn updateStackTop(self: *Runtime) void {
        c.JS_UpdateStackTop(self.cval());
    }

    // =========================================================================
    // Garbage Collection
    // =========================================================================

    /// Sets the GC threshold.
    ///
    /// The threshold determines when automatic garbage collection is triggered.
    ///
    /// C: `JS_SetGCThreshold`
    pub fn setGCThreshold(self: *Runtime, threshold: usize) void {
        c.JS_SetGCThreshold(self.cval(), threshold);
    }

    /// Gets the current GC threshold.
    ///
    /// C: `JS_GetGCThreshold`
    pub fn getGCThreshold(self: *Runtime) usize {
        return c.JS_GetGCThreshold(self.cval());
    }

    /// Runs the garbage collector.
    ///
    /// C: `JS_RunGC`
    pub fn runGC(self: *Runtime) void {
        c.JS_RunGC(self.cval());
    }

    /// Checks if a value is a live object in this runtime.
    ///
    /// C: `JS_IsLiveObject`
    pub fn isLiveObject(self: *Runtime, obj: Value) bool {
        return c.JS_IsLiveObject(self.cval(), obj.cval());
    }

    // =========================================================================
    // Opaque Data
    // =========================================================================

    /// Gets the opaque pointer associated with this runtime.
    ///
    /// C: `JS_GetRuntimeOpaque`
    pub fn getOpaque(self: *Runtime, comptime T: type) ?*T {
        return @ptrCast(@alignCast(c.JS_GetRuntimeOpaque(self.cval())));
    }

    /// Sets the opaque pointer for this runtime.
    ///
    /// C: `JS_SetRuntimeOpaque`
    pub fn setOpaque(self: *Runtime, comptime T: type, ptr: ?*T) void {
        c.JS_SetRuntimeOpaque(self.cval(), ptr);
    }

    // =========================================================================
    // Dump Flags (Debugging)
    // =========================================================================

    /// Sets the dump flags for debugging output.
    ///
    /// C: `JS_SetDumpFlags`
    pub fn setDumpFlags(self: *Runtime, flags: DumpFlags) void {
        c.JS_SetDumpFlags(self.cval(), @bitCast(flags));
    }

    /// Gets the current dump flags.
    ///
    /// C: `JS_GetDumpFlags`
    pub fn getDumpFlags(self: *Runtime) DumpFlags {
        return @bitCast(c.JS_GetDumpFlags(self.cval()));
    }

    // =========================================================================
    // Interrupt Handler
    // =========================================================================

    /// Interrupt handler callback type.
    ///
    /// Called periodically during JavaScript execution.
    /// - userdata: The opaque pointer passed to setInterruptHandler
    /// - runtime: The runtime
    /// Return true to interrupt execution, false to continue.
    pub fn InterruptHandler(comptime T: type) type {
        return *const fn (Opaque(T), *Runtime) bool;
    }

    /// Sets the interrupt handler for this runtime.
    ///
    /// The interrupt handler is called periodically during JavaScript execution
    /// and can be used to implement timeouts or cancellation.
    ///
    /// C: `JS_SetInterruptHandler`
    pub fn setInterruptHandler(
        self: *Runtime,
        comptime T: type,
        userdata: Opaque(T),
        comptime handler: ?InterruptHandler(T),
    ) void {
        const h = handler orelse {
            c.JS_SetInterruptHandler(self.cval(), null, null);
            return;
        };

        const Wrapper = struct {
            fn callback(
                runtime: *Runtime,
                inner_userdata: ?*anyopaque,
            ) callconv(.c) c_int {
                const should_interrupt = @call(.always_inline, h, .{
                    opaquepkg.fromC(T, inner_userdata),
                    runtime,
                });
                return if (should_interrupt) 1 else 0;
            }
        };

        c.JS_SetInterruptHandler(
            self.cval(),
            @ptrCast(&Wrapper.callback),
            opaquepkg.toC(T, userdata),
        );
    }

    // =========================================================================
    // Atomics Support
    // =========================================================================

    /// Sets whether Atomics.wait() can be used.
    ///
    /// If can_block is true, Atomics.wait() can be used.
    ///
    /// C: `JS_SetCanBlock`
    pub fn setCanBlock(self: *Runtime, can_block: bool) void {
        c.JS_SetCanBlock(self.cval(), can_block);
    }

    /// Sets the SharedArrayBuffer functions for this runtime.
    ///
    /// These functions are used to allocate, free, and duplicate SharedArrayBuffer memory.
    ///
    /// C: `JS_SetSharedArrayBufferFunctions`
    pub fn setSharedArrayBufferFunctions(self: *Runtime, sf: typed_array.SharedBufferFunctions) void {
        var c_sf = sf.toCStruct();
        c.JS_SetSharedArrayBufferFunctions(self.cval(), &c_sf);
    }

    // =========================================================================
    // Module Loader
    // =========================================================================

    /// Module name normalization function type.
    ///
    /// Called to normalize a module specifier.
    /// - userdata: The opaque pointer passed to setModuleLoaderFunc
    /// - ctx: The context
    /// - module_base_name: The base name (requester) of the module
    /// - module_name: The specifier being requested
    ///
    /// Returns the normalized module specifier (allocated with js_malloc) or null on exception.
    pub fn ModuleNormalizeFunc(comptime T: type) type {
        return *const fn (Opaque(T), *Context, [:0]const u8, [:0]const u8) ?[*:0]u8;
    }

    /// Module loader function type.
    ///
    /// Called to load a module.
    /// - userdata: The opaque pointer passed to setModuleLoaderFunc
    /// - ctx: The context
    /// - module_name: The normalized module specifier
    ///
    /// Returns the module definition or null on error.
    pub fn ModuleLoaderFunc(comptime T: type) type {
        return *const fn (Opaque(T), *Context, [:0]const u8) ?*ModuleDef;
    }

    /// Sets the module loader functions.
    ///
    /// module_normalize can be null to use the default normalizer.
    /// module_loader can be null to disable module loading.
    ///
    /// C: `JS_SetModuleLoaderFunc`
    pub fn setModuleLoaderFunc(
        self: *Runtime,
        comptime T: type,
        userdata: Opaque(T),
        comptime module_normalize: ?ModuleNormalizeFunc(T),
        comptime module_loader: ?ModuleLoaderFunc(T),
    ) void {
        const Wrapper = struct {
            fn normCallback(
                ctx: *Context,
                module_base_name: [*:0]const u8,
                module_name: [*:0]const u8,
                inner_userdata: ?*anyopaque,
            ) callconv(.c) ?[*:0]u8 {
                const norm = module_normalize orelse return null;
                return @call(.always_inline, norm, .{
                    opaquepkg.fromC(T, inner_userdata),
                    ctx,
                    std.mem.span(module_base_name),
                    std.mem.span(module_name),
                });
            }

            fn loadCallback(
                ctx: *Context,
                module_name: [*:0]const u8,
                inner_userdata: ?*anyopaque,
            ) callconv(.c) ?*ModuleDef {
                const loader = module_loader orelse return null;
                return @call(.always_inline, loader, .{
                    opaquepkg.fromC(T, inner_userdata),
                    ctx,
                    std.mem.span(module_name),
                });
            }
        };

        c.JS_SetModuleLoaderFunc(
            self.cval(),
            if (module_normalize != null) @ptrCast(&Wrapper.normCallback) else null,
            if (module_loader != null) @ptrCast(&Wrapper.loadCallback) else null,
            opaquepkg.toC(T, userdata),
        );
    }

    // =========================================================================
    // Class Definition
    // =========================================================================

    /// Registers a new class with this runtime.
    ///
    /// The class ID must be obtained from `class.Id.new`. Once registered,
    /// objects of this class can be created with `Value.initObjectClass`.
    ///
    /// C: `JS_NewClass`
    pub fn newClass(self: *Runtime, class_id: class.Id, def: *const class.Def) !void {
        const result = c.JS_NewClass(self.cval(), @intFromEnum(class_id), @ptrCast(def));
        if (result < 0) return error.ClassRegistrationFailed;
    }

    /// Checks if a class ID is registered with this runtime.
    ///
    /// C: `JS_IsRegisteredClass`
    pub fn isRegisteredClass(self: *Runtime, class_id: class.Id) bool {
        return c.JS_IsRegisteredClass(self.cval(), @intFromEnum(class_id));
    }

    /// Gets the name of a registered class.
    ///
    /// Returns the class name as an atom, or `Atom.null` if the class is not registered.
    /// The returned atom must be freed with `Atom.deinit`.
    ///
    /// C: `JS_GetClassName`
    pub fn getClassName(self: *Runtime, class_id: class.Id) Atom {
        return @enumFromInt(c.JS_GetClassName(self.cval(), @intFromEnum(class_id)));
    }

    // =========================================================================
    // Job Queue (Microtasks)
    // =========================================================================

    /// Checks if there are pending jobs in the job queue.
    ///
    /// C: `JS_IsJobPending`
    pub fn isJobPending(self: *Runtime) bool {
        return c.JS_IsJobPending(self.cval());
    }

    /// Executes a pending job from the job queue.
    ///
    /// Returns the context in which the job was executed, or null if no job was pending.
    /// Returns error.Exception if the job threw an exception.
    ///
    /// C: `JS_ExecutePendingJob`
    pub fn executePendingJob(self: *Runtime) !?*Context {
        var ctx: ?*c.JSContext = null;
        const result = c.JS_ExecutePendingJob(self.cval(), &ctx);
        if (result < 0) return error.Exception;
        if (result == 0) return null;
        return @ptrCast(ctx);
    }

    // =========================================================================
    // Memory Usage
    // =========================================================================

    /// Computes memory usage statistics for this runtime.
    ///
    /// C: `JS_ComputeMemoryUsage`
    pub fn computeMemoryUsage(self: *Runtime) c.JSMemoryUsage {
        var usage: c.JSMemoryUsage = undefined;
        c.JS_ComputeMemoryUsage(self.cval(), &usage);
        return usage;
    }

    // =========================================================================
    // Runtime Finalizers
    // =========================================================================

    /// Adds a finalizer to be called when the runtime is freed.
    ///
    /// Multiple finalizers can be added and will be called in reverse order
    /// of registration when `deinit` is called.
    ///
    /// C: `JS_AddRuntimeFinalizer`
    pub fn addFinalizer(
        self: *Runtime,
        comptime T: type,
        userdata: Opaque(T),
        comptime finalizer: *const fn (
            Opaque(T),
            *Runtime,
        ) void,
    ) Allocator.Error!void {
        const result = c.JS_AddRuntimeFinalizer(
            self.cval(),
            @ptrCast(&(struct {
                fn callback(
                    runtime: *Runtime,
                    inner_userdata: ?*anyopaque,
                ) callconv(.c) void {
                    @call(.always_inline, finalizer, .{
                        opaquepkg.fromC(T, inner_userdata),
                        runtime,
                    });
                }
            }).callback),
            opaquepkg.toC(T, userdata),
        );
        if (result < 0) return error.OutOfMemory;
    }

    // =========================================================================
    // Promise Hooks
    // =========================================================================

    /// Promise hook type for tracking promise lifecycle.
    pub const PromiseHookType = enum(c_uint) {
        /// Promise was created
        init = c.JS_PROMISE_HOOK_INIT,
        /// About to execute promise reaction
        before = c.JS_PROMISE_HOOK_BEFORE,
        /// Finished executing promise reaction
        after = c.JS_PROMISE_HOOK_AFTER,
        /// Promise was resolved or rejected
        resolve = c.JS_PROMISE_HOOK_RESOLVE,
    };

    /// Promise hook callback type.
    ///
    /// Called at various points in a promise's lifecycle.
    /// - userdata: The opaque pointer passed to setPromiseHook
    /// - ctx: The context
    /// - hook_type: The type of hook event
    /// - promise: The promise object
    /// - parent_or_value: For init, the parent promise; for resolve, the resolution value
    pub fn PromiseHook(comptime T: type) type {
        return *const fn (Opaque(T), *Context, PromiseHookType, Value, Value) void;
    }

    /// Sets the promise hook for debugging/tracing promise lifecycle.
    ///
    /// The hook is called when promises are created, before/after reactions,
    /// and when resolved/rejected.
    ///
    /// C: `JS_SetPromiseHook`
    pub fn setPromiseHook(
        self: *Runtime,
        comptime T: type,
        userdata: Opaque(T),
        comptime hook: ?PromiseHook(T),
    ) void {
        const h = hook orelse {
            c.JS_SetPromiseHook(self.cval(), null, null);
            return;
        };

        const Wrapper = struct {
            fn callback(
                ctx: ?*c.JSContext,
                hook_type: c.JSPromiseHookType,
                promise: c.JSValue,
                parent_or_value: c.JSValue,
                inner_userdata: ?*anyopaque,
            ) callconv(.c) void {
                @call(.always_inline, h, .{
                    opaquepkg.fromC(T, inner_userdata),
                    @as(*Context, @ptrCast(ctx)),
                    @as(PromiseHookType, @enumFromInt(hook_type)),
                    @as(Value, @bitCast(promise)),
                    @as(Value, @bitCast(parent_or_value)),
                });
            }
        };
        c.JS_SetPromiseHook(self.cval(), &Wrapper.callback, opaquepkg.toC(T, userdata));
    }

    /// Promise rejection tracker callback type.
    ///
    /// Called when a promise is rejected without a handler, or when a handler
    /// is added to a previously unhandled rejection.
    /// - userdata: The opaque pointer passed to setHostPromiseRejectionTracker
    /// - ctx: The context
    /// - promise: The promise object
    /// - reason: The rejection reason
    /// - is_handled: true if the rejection now has a handler, false if unhandled
    pub fn HostPromiseRejectionTracker(comptime T: type) type {
        return *const fn (Opaque(T), *Context, Value, Value, bool) void;
    }

    /// Sets the host promise rejection tracker.
    ///
    /// This is called when a promise rejection is unhandled, allowing the host
    /// to log or report the unhandled rejection.
    ///
    /// C: `JS_SetHostPromiseRejectionTracker`
    pub fn setHostPromiseRejectionTracker(
        self: *Runtime,
        comptime T: type,
        userdata: Opaque(T),
        comptime tracker: ?HostPromiseRejectionTracker(T),
    ) void {
        const t = tracker orelse {
            c.JS_SetHostPromiseRejectionTracker(self.cval(), null, null);
            return;
        };

        const Wrapper = struct {
            fn callback(
                ctx: ?*c.JSContext,
                promise: c.JSValue,
                reason: c.JSValue,
                is_handled: bool,
                inner_userdata: ?*anyopaque,
            ) callconv(.c) void {
                @call(.always_inline, t, .{
                    opaquepkg.fromC(T, inner_userdata),
                    @as(*Context, @ptrCast(ctx)),
                    @as(Value, @bitCast(promise)),
                    @as(Value, @bitCast(reason)),
                    is_handled,
                });
            }
        };
        c.JS_SetHostPromiseRejectionTracker(self.cval(), &Wrapper.callback, opaquepkg.toC(T, userdata));
    }

    // =========================================================================
    // Internal
    // =========================================================================

    pub inline fn cval(self: *Runtime) *c.JSRuntime {
        return @ptrCast(self);
    }
};

/// Debug dump flags for runtime diagnostics.
///
/// C: `JS_DUMP_*`
pub const DumpFlags = packed struct(u64) {
    bytecode_final: bool = false,
    bytecode_pass2: bool = false,
    bytecode_pass1: bool = false,
    _reserved1: bool = false,
    bytecode_hex: bool = false,
    bytecode_pc2line: bool = false,
    bytecode_stack: bool = false,
    bytecode_step: bool = false,
    read_object: bool = false,
    free: bool = false,
    gc: bool = false,
    gc_free: bool = false,
    module_resolve: bool = false,
    promise: bool = false,
    leaks: bool = false,
    atom_leaks: bool = false,
    mem: bool = false,
    objects: bool = false,
    atoms: bool = false,
    shapes: bool = false,
    _padding: u44 = 0,
};

test "Runtime init and deinit" {
    const rt: *Runtime = try .init();
    defer rt.deinit();
}

test "Runtime newContext" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx = try rt.newContext();
    defer ctx.deinit();

    // Verify the context is properly linked to the runtime
    try std.testing.expectEqual(rt, ctx.getRuntime());
}

test "Runtime setMemoryLimit" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    // Set a memory limit
    rt.setMemoryLimit(1024 * 1024);

    const ctx = try rt.newContext();
    defer ctx.deinit();

    // Allocate something very large that exceeds the limit
    const result = ctx.eval(
        \\let arr = [];
        \\for (let i = 0; i < 1000000; i++) arr.push(new Array(1000));
        \\arr.length
    , "<test>", .{});
    defer result.deinit(ctx);

    // Should fail with out of memory
    try std.testing.expect(result.isException());

    // Disable limit
    rt.setMemoryLimit(0);
}

test "Runtime setMaxStackSize" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    // Set a small stack size
    rt.setMaxStackSize(32 * 1024);

    const ctx = try rt.newContext();
    defer ctx.deinit();

    // Deep recursion should hit stack limit
    const result = ctx.eval(
        \\function recurse(n) { return recurse(n + 1); }
        \\recurse(0);
    , "<test>", .{});
    defer result.deinit(ctx);

    try std.testing.expect(result.isException());
}

test "Runtime GC threshold" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    // Get default threshold
    const default_threshold = rt.getGCThreshold();
    try std.testing.expect(default_threshold > 0);

    // Set a new threshold
    rt.setGCThreshold(1024);
    try std.testing.expectEqual(@as(usize, 1024), rt.getGCThreshold());

    // Restore
    rt.setGCThreshold(default_threshold);
    try std.testing.expectEqual(default_threshold, rt.getGCThreshold());
}

test "Runtime runGC" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx = try rt.newContext();
    defer ctx.deinit();

    // Create some garbage
    const result = ctx.eval(
        \\for (let i = 0; i < 1000; i++) { let x = {a: i, b: [1,2,3]}; }
        \\true
    , "<test>", .{});
    defer result.deinit(ctx);

    // Run GC - should not crash
    rt.runGC();

    try std.testing.expect(!result.isException());
}

test "Runtime opaque data" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const TestData = struct {
        value: i32,
    };

    var data: TestData = .{ .value = 42 };

    // Initially null
    try std.testing.expectEqual(@as(?*TestData, null), rt.getOpaque(TestData));

    // Set opaque
    rt.setOpaque(TestData, &data);

    // Get opaque
    const retrieved = rt.getOpaque(TestData);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(i32, 42), retrieved.?.value);

    // Modify through pointer
    retrieved.?.value = 100;
    try std.testing.expectEqual(@as(i32, 100), data.value);

    // Clear
    rt.setOpaque(TestData, null);
    try std.testing.expectEqual(@as(?*TestData, null), rt.getOpaque(TestData));
}

test "Runtime dump flags" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    // Get default flags
    const default_flags = rt.getDumpFlags();

    // Set some flags
    rt.setDumpFlags(.{ .leaks = true, .gc = true });
    const new_flags = rt.getDumpFlags();
    try std.testing.expect(new_flags.leaks);
    try std.testing.expect(new_flags.gc);
    try std.testing.expect(!new_flags.promise);

    // Restore defaults
    rt.setDumpFlags(default_flags);
}

test "Runtime setInterruptHandler" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx = try rt.newContext();
    defer ctx.deinit();

    const State = struct {
        call_count: i32 = 0,

        fn handler(self: ?*@This(), _: *Runtime) bool {
            self.?.call_count += 1;
            // Interrupt after 100 calls
            return self.?.call_count > 100;
        }
    };

    var state: State = .{};

    rt.setInterruptHandler(State, &state, State.handler);

    // Run an infinite loop - should be interrupted
    const result = ctx.eval("while(true) {}", "<test>", .{});
    defer result.deinit(ctx);

    try std.testing.expect(result.isException());
    try std.testing.expect(state.call_count > 100);

    // Clear handler
    rt.setInterruptHandler(State, null, null);
}

test "Runtime isJobPending with promises" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx = try rt.newContext();
    defer ctx.deinit();

    // No jobs initially
    try std.testing.expect(!rt.isJobPending());

    // Create a resolved promise - this schedules a job
    const result = ctx.eval("Promise.resolve(42).then(x => x * 2)", "<test>", .{});
    defer result.deinit(ctx);
    try std.testing.expect(!result.isException());

    // Now there should be a pending job
    try std.testing.expect(rt.isJobPending());
}

test "Runtime executePendingJob" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx = try rt.newContext();
    defer ctx.deinit();

    // Track promise resolution through a global
    _ = ctx.eval("globalThis.result = 0", "<test>", .{});

    // Create a promise that modifies global state
    const promise_result = ctx.eval(
        \\Promise.resolve(42).then(x => { globalThis.result = x * 2; });
    , "<test>", .{});
    defer promise_result.deinit(ctx);

    // Execute the pending job
    while (rt.isJobPending()) {
        const job_ctx = try rt.executePendingJob();
        try std.testing.expect(job_ctx != null);
    }

    // Check that the promise callback ran
    const check = ctx.eval("globalThis.result", "<test>", .{});
    defer check.deinit(ctx);

    try std.testing.expectEqual(@as(i32, 84), try check.toInt32(ctx));
}

test "Runtime computeMemoryUsage" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx = try rt.newContext();
    defer ctx.deinit();

    // Create some objects
    const result = ctx.eval(
        \\let obj = {a: 1, b: 2, c: [1,2,3]};
        \\let str = "hello world";
        \\true
    , "<test>", .{});
    defer result.deinit(ctx);

    const usage = rt.computeMemoryUsage();

    // Basic sanity checks
    try std.testing.expect(usage.malloc_size > 0);
    try std.testing.expect(usage.memory_used_size > 0);
    try std.testing.expect(usage.atom_count > 0);
    try std.testing.expect(usage.obj_count > 0);
}

test "Runtime isLiveObject" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx = try rt.newContext();
    defer ctx.deinit();

    // Create an object
    const obj = ctx.eval("({a: 1})", "<test>", .{});
    defer obj.deinit(ctx);

    // Object should be live
    try std.testing.expect(rt.isLiveObject(obj));

    // Primitives are not "live objects" in QuickJS sense
    const num = Value.initInt32(42);
    try std.testing.expect(!rt.isLiveObject(num));
}

test "Runtime setCanBlock" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    // Just test that it doesn't crash
    rt.setCanBlock(true);
    rt.setCanBlock(false);
}

test "Runtime updateStackTop" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    // Just test that it doesn't crash
    rt.updateStackTop();
}

test "Runtime setInfo" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    // Just test that it doesn't crash
    rt.setInfo("test runtime");
}

test "DumpFlags bit layout matches C header" {
    const testing = std.testing;

    try testing.expectEqual(c.JS_DUMP_BYTECODE_FINAL, @as(u64, @bitCast(DumpFlags{ .bytecode_final = true })));
    try testing.expectEqual(c.JS_DUMP_BYTECODE_PASS2, @as(u64, @bitCast(DumpFlags{ .bytecode_pass2 = true })));
    try testing.expectEqual(c.JS_DUMP_BYTECODE_PASS1, @as(u64, @bitCast(DumpFlags{ .bytecode_pass1 = true })));
    try testing.expectEqual(c.JS_DUMP_BYTECODE_HEX, @as(u64, @bitCast(DumpFlags{ .bytecode_hex = true })));
    try testing.expectEqual(c.JS_DUMP_BYTECODE_PC2LINE, @as(u64, @bitCast(DumpFlags{ .bytecode_pc2line = true })));
    try testing.expectEqual(c.JS_DUMP_BYTECODE_STACK, @as(u64, @bitCast(DumpFlags{ .bytecode_stack = true })));
    try testing.expectEqual(c.JS_DUMP_BYTECODE_STEP, @as(u64, @bitCast(DumpFlags{ .bytecode_step = true })));
    try testing.expectEqual(c.JS_DUMP_READ_OBJECT, @as(u64, @bitCast(DumpFlags{ .read_object = true })));
    try testing.expectEqual(c.JS_DUMP_FREE, @as(u64, @bitCast(DumpFlags{ .free = true })));
    try testing.expectEqual(c.JS_DUMP_GC, @as(u64, @bitCast(DumpFlags{ .gc = true })));
    try testing.expectEqual(c.JS_DUMP_GC_FREE, @as(u64, @bitCast(DumpFlags{ .gc_free = true })));
    try testing.expectEqual(c.JS_DUMP_MODULE_RESOLVE, @as(u64, @bitCast(DumpFlags{ .module_resolve = true })));
    try testing.expectEqual(c.JS_DUMP_PROMISE, @as(u64, @bitCast(DumpFlags{ .promise = true })));
    try testing.expectEqual(c.JS_DUMP_LEAKS, @as(u64, @bitCast(DumpFlags{ .leaks = true })));
    try testing.expectEqual(c.JS_DUMP_ATOM_LEAKS, @as(u64, @bitCast(DumpFlags{ .atom_leaks = true })));
    try testing.expectEqual(c.JS_DUMP_MEM, @as(u64, @bitCast(DumpFlags{ .mem = true })));
    try testing.expectEqual(c.JS_DUMP_OBJECTS, @as(u64, @bitCast(DumpFlags{ .objects = true })));
    try testing.expectEqual(c.JS_DUMP_ATOMS, @as(u64, @bitCast(DumpFlags{ .atoms = true })));
    try testing.expectEqual(c.JS_DUMP_SHAPES, @as(u64, @bitCast(DumpFlags{ .shapes = true })));

    // Combined flags
    try testing.expectEqual(
        c.JS_DUMP_LEAKS | c.JS_DUMP_GC,
        @as(u64, @bitCast(DumpFlags{ .leaks = true, .gc = true })),
    );
}

test "Runtime initWithMallocFunctions" {
    const State = struct {
        var malloc_count: usize = 0;
        var free_count: usize = 0;

        fn jsMalloc(_: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
            malloc_count += 1;
            return std.c.malloc(size);
        }

        fn jsCalloc(_: ?*anyopaque, count: usize, size: usize) callconv(.c) ?*anyopaque {
            malloc_count += 1;
            return std.c.calloc(count, size);
        }

        fn jsFree(_: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
            if (ptr != null) free_count += 1;
            std.c.free(ptr);
        }

        fn jsRealloc(_: ?*anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
            return std.c.realloc(ptr, size);
        }

        fn jsMallocUsableSize(_: ?*const anyopaque) callconv(.c) usize {
            return 0;
        }
    };

    const mf = MallocFunctions{
        .malloc = State.jsMalloc,
        .calloc = State.jsCalloc,
        .free = State.jsFree,
        .realloc = State.jsRealloc,
        .malloc_usable_size = State.jsMallocUsableSize,
    };

    State.malloc_count = 0;
    State.free_count = 0;

    const rt = try Runtime.initWithMallocFunctions(&mf, null);
    defer rt.deinit();

    const ctx = try rt.newContext();
    defer ctx.deinit();

    // Verify custom allocator was used
    try std.testing.expect(State.malloc_count > 0);
}

test "Runtime addFinalizer" {
    const State = struct {
        called: bool = false,

        fn finalizer(self: ?*@This(), _: *Runtime) void {
            self.?.called = true;
        }
    };

    var state: State = .{};
    const rt: *Runtime = try .init();
    try rt.addFinalizer(State, &state, State.finalizer);
    rt.deinit();

    // Finalizer should have been called during deinit
    try std.testing.expect(state.called);
}

test "Runtime setPromiseHook" {
    const State = struct {
        hook_calls: usize = 0,
        last_hook_type: ?Runtime.PromiseHookType = null,

        fn hook(
            self: ?*@This(),
            _: *Context,
            hook_type: Runtime.PromiseHookType,
            _: Value,
            _: Value,
        ) void {
            self.?.hook_calls += 1;
            self.?.last_hook_type = hook_type;
        }
    };

    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx = try rt.newContext();
    defer ctx.deinit();

    var state: State = .{};

    rt.setPromiseHook(State, &state, State.hook);

    // Create a promise - should trigger the hook
    const result = ctx.eval("Promise.resolve(42)", "<test>", .{});
    defer result.deinit(ctx);

    try std.testing.expect(state.hook_calls > 0);
    try std.testing.expect(state.last_hook_type != null);

    // Clear the hook
    rt.setPromiseHook(State, null, null);
}

test "Runtime setHostPromiseRejectionTracker" {
    const State = struct {
        tracker_calls: usize = 0,
        was_handled: bool = false,

        fn tracker(
            self: ?*@This(),
            _: *Context,
            _: Value,
            _: Value,
            is_handled: bool,
        ) void {
            self.?.tracker_calls += 1;
            self.?.was_handled = is_handled;
        }
    };

    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx = try rt.newContext();
    defer ctx.deinit();

    var state: State = .{};

    rt.setHostPromiseRejectionTracker(State, &state, State.tracker);

    // Create an unhandled rejection
    const result = ctx.eval("Promise.reject(new Error('test'))", "<test>", .{});
    defer result.deinit(ctx);

    // Execute pending jobs to trigger rejection tracking
    while (rt.isJobPending()) {
        _ = rt.executePendingJob() catch break;
    }

    try std.testing.expect(state.tracker_calls > 0);

    // Clear the tracker
    rt.setHostPromiseRejectionTracker(State, null, null);
}

test "PromiseHookType matches C constants" {
    try std.testing.expectEqual(@as(c_uint, c.JS_PROMISE_HOOK_INIT), @intFromEnum(Runtime.PromiseHookType.init));
    try std.testing.expectEqual(@as(c_uint, c.JS_PROMISE_HOOK_BEFORE), @intFromEnum(Runtime.PromiseHookType.before));
    try std.testing.expectEqual(@as(c_uint, c.JS_PROMISE_HOOK_AFTER), @intFromEnum(Runtime.PromiseHookType.after));
    try std.testing.expectEqual(@as(c_uint, c.JS_PROMISE_HOOK_RESOLVE), @intFromEnum(Runtime.PromiseHookType.resolve));
}
