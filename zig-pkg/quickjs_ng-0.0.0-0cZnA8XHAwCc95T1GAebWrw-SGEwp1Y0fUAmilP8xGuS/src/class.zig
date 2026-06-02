const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const c = @import("quickjs_c");
const Atom = @import("atom.zig").Atom;
const Context = @import("context.zig").Context;
const Runtime = @import("runtime.zig").Runtime;
const Value = @import("value.zig").Value;

/// Class identifier for custom JavaScript classes.
///
/// Class IDs are used to register custom native-backed classes with QuickJS.
/// Each class has a unique ID that is used to associate objects with their
/// class definition, prototype, and opaque data.
///
/// C: `JSClassID`
pub const Id = enum(u32) {
    /// Invalid class ID (returned when object has no class).
    invalid = c.JS_INVALID_CLASS_ID,
    _,

    /// Creates a new unique class ID.
    ///
    /// C: `JS_NewClassID`
    pub fn new(rt: *Runtime) Id {
        var raw: u32 = 0;
        return @enumFromInt(c.JS_NewClassID(rt.cval(), &raw));
    }
};

/// Finalizer callback called when an object of this class is garbage collected.
///
/// C: `JSClassFinalizer`
pub const Finalizer = *const fn (*Runtime, Value) callconv(.c) void;

/// GC mark callback for marking references held by this class.
///
/// C: `JSClassGCMark`
pub const GCMark = *const fn (*Runtime, Value, c.JS_MarkFunc) callconv(.c) void;

/// Call callback for callable class objects.
///
/// If `flags & JS_CALL_FLAG_CONSTRUCTOR` is set, the object is being
/// called as a constructor and `this_val` is `new.target`.
///
/// C: `JSClassCall`
pub const Call = *const fn (
    *Context,
    Value,
    Value,
    c_int,
    [*]Value,
    c_int,
) callconv(.c) Value;

/// Exotic methods for customizing property access behavior.
///
/// These methods allow implementing Proxy-like behavior for custom classes.
///
/// C: `JSClassExoticMethods`
pub const ExoticMethods = extern struct {
    get_own_property: ?*const fn (
        ?*c.JSContext,
        [*c]c.JSPropertyDescriptor,
        c.JSValue,
        c.JSAtom,
    ) callconv(.c) c_int = null,
    get_own_property_names: ?*const fn (
        ?*c.JSContext,
        [*c][*c]c.JSPropertyEnum,
        [*c]u32,
        c.JSValue,
    ) callconv(.c) c_int = null,
    delete_property: ?*const fn (
        ?*c.JSContext,
        c.JSValue,
        c.JSAtom,
    ) callconv(.c) c_int = null,
    define_own_property: ?*const fn (
        ?*c.JSContext,
        c.JSValue,
        c.JSAtom,
        c.JSValue,
        c.JSValue,
        c.JSValue,
        c_int,
    ) callconv(.c) c_int = null,
    has_property: ?*const fn (
        ?*c.JSContext,
        c.JSValue,
        c.JSAtom,
    ) callconv(.c) c_int = null,
    get_property: ?*const fn (
        ?*c.JSContext,
        c.JSValue,
        c.JSAtom,
        c.JSValue,
    ) callconv(.c) c.JSValue = null,
    set_property: ?*const fn (
        ?*c.JSContext,
        c.JSValue,
        c.JSAtom,
        c.JSValue,
        c.JSValue,
        c_int,
    ) callconv(.c) c_int = null,
};

/// Definition for a custom JavaScript class.
///
/// Used with `Runtime.newClass` to register a custom class.
///
/// C: `JSClassDef`
pub const Def = extern struct {
    /// Class name (pure ASCII only).
    class_name: [*:0]const u8 = "",
    /// Finalizer called when objects of this class are garbage collected.
    finalizer: ?*const c.JSClassFinalizer = null,
    /// GC mark function for marking references.
    gc_mark: ?*const c.JSClassGCMark = null,
    /// Call function (makes instances of this class callable).
    call: ?*const c.JSClassCall = null,
    /// Exotic methods for custom property access.
    exotic: ?*ExoticMethods = null,
};

/// Flag indicating a constructor call.
pub const call_flag_constructor: c_int = 1 << 0;

comptime {
    assert(@intFromEnum(Id.invalid) == c.JS_INVALID_CLASS_ID);
    assert(@sizeOf(Def) == @sizeOf(c.JSClassDef));
    assert(@alignOf(Def) == @alignOf(c.JSClassDef));
    assert(@sizeOf(ExoticMethods) == @sizeOf(c.JSClassExoticMethods));
    assert(@alignOf(ExoticMethods) == @alignOf(c.JSClassExoticMethods));
}

test "Id.new allocates unique IDs" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const id1: Id = .new(rt);
    const id2: Id = .new(rt);

    try testing.expect(id1 != .invalid);
    try testing.expect(id2 != .invalid);
    try testing.expect(id1 != id2);
}

test "Runtime.newClass registers a class" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const class_id: Id = .new(rt);

    try testing.expect(!rt.isRegisteredClass(class_id));

    const def: Def = .{ .class_name = "TestClass" };
    try rt.newClass(class_id, &def);

    try testing.expect(rt.isRegisteredClass(class_id));
}

test "Runtime.getClassName returns class name" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const class_id: Id = .new(rt);

    try testing.expect(!rt.isRegisteredClass(class_id));

    const def: Def = .{ .class_name = "MyCustomClass" };
    try rt.newClass(class_id, &def);

    try testing.expect(rt.isRegisteredClass(class_id));

    const name_atom = rt.getClassName(class_id);
    defer name_atom.deinit(ctx);

    try testing.expect(name_atom != .null);
}

test "Value.initObjectClass creates class instance" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const class_id: Id = .new(rt);

    const def: Def = .{ .class_name = "InstanceTest" };
    try rt.newClass(class_id, &def);

    const proto = Value.initObject(ctx);
    defer proto.deinit(ctx);
    ctx.setClassProto(class_id, proto.dup(ctx));

    const obj = Value.initObjectClass(ctx, class_id);
    defer obj.deinit(ctx);

    try testing.expect(obj.isObject());
    try testing.expectEqual(class_id, obj.getClassId());
}

test "Value opaque data round-trip" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const class_id: Id = .new(rt);

    const def: Def = .{ .class_name = "OpaqueTest" };
    try rt.newClass(class_id, &def);

    const proto = Value.initObject(ctx);
    defer proto.deinit(ctx);
    ctx.setClassProto(class_id, proto.dup(ctx));

    const obj = Value.initObjectClass(ctx, class_id);
    defer obj.deinit(ctx);

    const TestData = struct { value: i32 };
    var data: TestData = .{ .value = 42 };

    try testing.expect(obj.setOpaque(&data));

    const retrieved = obj.getOpaque(TestData, class_id);
    try testing.expect(retrieved != null);
    try testing.expectEqual(@as(i32, 42), retrieved.?.value);

    const retrieved2 = obj.getOpaque2(ctx, TestData, class_id);
    try testing.expect(retrieved2 != null);
    try testing.expectEqual(@as(i32, 42), retrieved2.?.value);
}

test "Value.getAnyOpaque retrieves opaque with class ID" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const class_id: Id = .new(rt);

    const def: Def = .{ .class_name = "AnyOpaqueTest" };
    try rt.newClass(class_id, &def);

    const proto = Value.initObject(ctx);
    defer proto.deinit(ctx);
    ctx.setClassProto(class_id, proto.dup(ctx));

    const obj = Value.initObjectClass(ctx, class_id);
    defer obj.deinit(ctx);

    const TestData = struct { value: i32 };
    var data: TestData = .{ .value = 99 };
    try testing.expect(obj.setOpaque(&data));

    const result = obj.getAnyOpaque(TestData);
    try testing.expect(result.ptr != null);
    try testing.expectEqual(class_id, result.class_id);
    try testing.expectEqual(@as(i32, 99), result.ptr.?.value);
}

test "Value.getClassId returns class ID for class objects" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const class_id: Id = .new(rt);

    const def: Def = .{ .class_name = "ClassIdTest" };
    try rt.newClass(class_id, &def);

    const proto = Value.initObject(ctx);
    defer proto.deinit(ctx);
    ctx.setClassProto(class_id, proto.dup(ctx));

    const obj = Value.initObjectClass(ctx, class_id);
    defer obj.deinit(ctx);

    try testing.expectEqual(class_id, obj.getClassId());
}

test "Value.getClassId returns invalid for non-objects" {
    const num = Value.initInt32(42);
    try testing.expectEqual(Id.invalid, num.getClassId());
}

test "Context.setClassProto and getClassProto" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const class_id: Id = .new(rt);

    const def: Def = .{ .class_name = "ProtoTest" };
    try rt.newClass(class_id, &def);

    const proto = Value.initObject(ctx);
    try proto.setPropertyStr(ctx, "testProp", Value.initInt32(123));
    ctx.setClassProto(class_id, proto);

    const retrieved = ctx.getClassProto(class_id);
    defer retrieved.deinit(ctx);

    try testing.expect(retrieved.isObject());

    const prop = retrieved.getPropertyStr(ctx, "testProp");
    defer prop.deinit(ctx);
    try testing.expectEqual(@as(i32, 123), try prop.toInt32(ctx));
}

test "Value.setConstructorBit" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const func = ctx.eval("(function MyClass() {})", "<test>", .{});
    defer func.deinit(ctx);

    try testing.expect(func.isFunction(ctx));

    _ = func.setConstructorBit(ctx, false);

    const can_construct_before = ctx.eval("try { new MyClass(); true } catch(e) { false }", "<test>", .{});
    defer can_construct_before.deinit(ctx);

    _ = func.setConstructorBit(ctx, true);

    try testing.expect(!func.isException());
}

test "Class with finalizer" {
    const State = struct {
        var finalized: bool = false;
    };

    const rt: *Runtime = try .init();
    defer rt.deinit();

    const class_id: Id = .new(rt);

    const def = Def{
        .class_name = "FinalizerTest",
        .finalizer = &struct {
            fn finalize(_: ?*c.JSRuntime, _: c.JSValue) callconv(.c) void {
                State.finalized = true;
            }
        }.finalize,
    };
    try rt.newClass(class_id, &def);

    {
        const ctx: *Context = try .init(rt);
        defer ctx.deinit();

        const proto = Value.initObject(ctx);
        ctx.setClassProto(class_id, proto);

        const obj = Value.initObjectClass(ctx, class_id);
        obj.deinit(ctx);
    }

    rt.runGC();

    try testing.expect(State.finalized);
}
