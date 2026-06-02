const std = @import("std");
const testing = std.testing;
const c = @import("quickjs_c");
const Context = @import("context.zig").Context;
const Runtime = @import("runtime.zig").Runtime;
const Value = @import("value.zig").Value;

/// Wrapper for the QuickJS `JSAtom`.
///
/// Atoms are interned strings used for property names and symbols.
/// They are reference-counted and must be freed with `deinit` when no
/// longer needed.
///
/// C: `JSAtom`
pub const Atom = enum(u32) {
    null = 0,
    _,

    /// Creates an atom from a null-terminated string.
    ///
    /// C: `JS_NewAtom`
    pub fn init(ctx: *Context, str: [:0]const u8) Atom {
        return @enumFromInt(c.JS_NewAtom(ctx.cval(), str.ptr));
    }

    /// Creates an atom from a string slice.
    ///
    /// C: `JS_NewAtomLen`
    pub fn initLen(ctx: *Context, str: []const u8) Atom {
        return @enumFromInt(c.JS_NewAtomLen(ctx.cval(), str.ptr, str.len));
    }

    /// Creates an atom from an unsigned 32-bit integer.
    ///
    /// C: `JS_NewAtomUInt32`
    pub fn initUint32(ctx: *Context, n: u32) Atom {
        return @enumFromInt(c.JS_NewAtomUInt32(ctx.cval(), n));
    }

    /// Creates an atom from a JavaScript value.
    ///
    /// The value is converted to a string and interned as an atom.
    ///
    /// C: `JS_ValueToAtom`
    pub fn fromValue(ctx: *Context, val: Value) Atom {
        return @enumFromInt(c.JS_ValueToAtom(ctx.cval(), val.cval()));
    }

    /// Duplicates the atom, incrementing its reference count.
    ///
    /// The returned atom must also be freed with `deinit`.
    ///
    /// C: `JS_DupAtom`
    pub fn dup(self: Atom, ctx: *Context) Atom {
        return @enumFromInt(c.JS_DupAtom(ctx.cval(), @intFromEnum(self)));
    }

    /// Duplicates the atom using the runtime, incrementing its reference count.
    ///
    /// The returned atom must also be freed with `deinitRT`.
    ///
    /// C: `JS_DupAtomRT`
    pub fn dupRT(self: Atom, rt: *Runtime) Atom {
        return @enumFromInt(c.JS_DupAtomRT(rt.cval(), @intFromEnum(self)));
    }

    /// Frees the atom, decrementing its reference count.
    ///
    /// C: `JS_FreeAtom`
    pub fn deinit(self: Atom, ctx: *Context) void {
        c.JS_FreeAtom(ctx.cval(), @intFromEnum(self));
    }

    /// Frees the atom using the runtime, decrementing its reference count.
    ///
    /// C: `JS_FreeAtomRT`
    pub fn deinitRT(self: Atom, rt: *Runtime) void {
        c.JS_FreeAtomRT(rt.cval(), @intFromEnum(self));
    }

    /// Converts the atom to a JavaScript value (symbol).
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_AtomToValue`
    pub fn toValue(self: Atom, ctx: *Context) Value {
        return Value.fromCVal(c.JS_AtomToValue(ctx.cval(), @intFromEnum(self)));
    }

    /// Converts the atom to a JavaScript string value.
    ///
    /// Returns a new Value that must be freed.
    ///
    /// C: `JS_AtomToString`
    pub fn toString(self: Atom, ctx: *Context) Value {
        return Value.fromCVal(c.JS_AtomToString(ctx.cval(), @intFromEnum(self)));
    }

    /// Converts the atom to a C string.
    ///
    /// Returns null if the atom is invalid. The returned string must be
    /// freed with `Context.freeCString`.
    ///
    /// C: `JS_AtomToCString`
    pub fn toCString(self: Atom, ctx: *Context) ?[*:0]const u8 {
        const ptr = c.JS_AtomToCString(ctx.cval(), @intFromEnum(self));
        return @ptrCast(ptr);
    }

    /// Converts the atom to a C string with length.
    ///
    /// Returns null if the atom is invalid. The returned pointer must be
    /// freed with `Context.freeCString`.
    ///
    /// C: `JS_AtomToCStringLen`
    pub fn toCStringLen(self: Atom, ctx: *Context) ?struct { ptr: [*:0]const u8, len: usize } {
        var len: usize = 0;
        const ptr = c.JS_AtomToCStringLen(ctx.cval(), &len, @intFromEnum(self));
        if (ptr == null) return null;
        return .{ .ptr = @ptrCast(ptr), .len = len };
    }

    /// Converts the atom to a Zig string slice.
    ///
    /// Returns null if the atom is invalid. The returned slice must be
    /// freed by passing the pointer to `Context.freeCString`.
    ///
    /// C: `JS_AtomToCStringLen`
    pub fn toZigSlice(self: Atom, ctx: *Context) ?[:0]const u8 {
        const result = self.toCStringLen(ctx) orelse return null;
        return result.ptr[0..result.len :0];
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Atom init and deinit" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const atom = Atom.init(ctx, "testProperty");
    defer atom.deinit(ctx);

    try testing.expect(atom != .null);
}

test "Atom initLen" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const str = "helloWorld";
    const atom = Atom.initLen(ctx, str[0..5]);
    defer atom.deinit(ctx);

    const cstr = atom.toCString(ctx).?;
    defer ctx.freeCString(cstr);

    try testing.expectEqualStrings("hello", std.mem.span(cstr));
}

test "Atom initUint32" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const atom = Atom.initUint32(ctx, 42);
    defer atom.deinit(ctx);

    const cstr = atom.toCString(ctx).?;
    defer ctx.freeCString(cstr);

    try testing.expectEqualStrings("42", std.mem.span(cstr));
}

test "Atom fromValue" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const str_val = Value.initString(ctx, "myProperty");
    defer str_val.deinit(ctx);

    const atom = Atom.fromValue(ctx, str_val);
    defer atom.deinit(ctx);

    const cstr = atom.toCString(ctx).?;
    defer ctx.freeCString(cstr);

    try testing.expectEqualStrings("myProperty", std.mem.span(cstr));
}

test "Atom dup" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const atom1 = Atom.init(ctx, "shared");
    defer atom1.deinit(ctx);

    const atom2 = atom1.dup(ctx);
    defer atom2.deinit(ctx);

    try testing.expectEqual(@intFromEnum(atom1), @intFromEnum(atom2));
}

test "Atom dupRT and deinitRT" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const atom1 = Atom.init(ctx, "runtimeAtom");
    defer atom1.deinit(ctx);

    const atom2 = atom1.dupRT(rt);
    defer atom2.deinitRT(rt);

    try testing.expectEqual(@intFromEnum(atom1), @intFromEnum(atom2));
}

test "Atom toValue" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const atom = Atom.init(ctx, "symbolName");
    defer atom.deinit(ctx);

    const val = atom.toValue(ctx);
    defer val.deinit(ctx);

    try testing.expect(!val.isException());
}

test "Atom toString" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const atom = Atom.init(ctx, "stringAtom");
    defer atom.deinit(ctx);

    const str_val = atom.toString(ctx);
    defer str_val.deinit(ctx);

    try testing.expect(str_val.isString());

    const cstr = str_val.toCString(ctx).?;
    defer ctx.freeCString(cstr);

    try testing.expectEqualStrings("stringAtom", std.mem.span(cstr));
}

test "Atom toCString" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const atom = Atom.init(ctx, "cstringTest");
    defer atom.deinit(ctx);

    const cstr = atom.toCString(ctx).?;
    defer ctx.freeCString(cstr);

    try testing.expectEqualStrings("cstringTest", std.mem.span(cstr));
}

test "Atom toCStringLen" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const atom = Atom.init(ctx, "lengthTest");
    defer atom.deinit(ctx);

    const result = atom.toCStringLen(ctx).?;
    defer ctx.freeCString(result.ptr);

    try testing.expectEqualStrings("lengthTest", result.ptr[0..result.len]);
    try testing.expectEqual(@as(usize, 10), result.len);
}

test "Atom toZigSlice" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const atom = Atom.init(ctx, "sliceTest");
    defer atom.deinit(ctx);

    const slice = atom.toZigSlice(ctx).?;
    defer ctx.freeCString(slice.ptr);

    try testing.expectEqualStrings("sliceTest", slice);
    try testing.expectEqual(@as(usize, 9), slice.len);
}

test "Atom used as property name in JavaScript" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const obj = Value.initObject(ctx);
    defer obj.deinit(ctx);

    const atom = Atom.init(ctx, "myProp");
    defer atom.deinit(ctx);

    const val = Value.initInt32(42);
    try obj.setProperty(ctx, atom, val);

    const retrieved = obj.getProperty(ctx, atom);
    defer retrieved.deinit(ctx);

    try testing.expectEqual(@as(i32, 42), try retrieved.toInt32(ctx));
}

test "Atom integer property access" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const arr = ctx.eval("[10, 20, 30]", "<test>", .{});
    defer arr.deinit(ctx);

    const atom = Atom.initUint32(ctx, 1);
    defer atom.deinit(ctx);

    const val = arr.getProperty(ctx, atom);
    defer val.deinit(ctx);

    try testing.expectEqual(@as(i32, 20), try val.toInt32(ctx));
}

test "Atom same strings share same atom" {
    const rt: *Runtime = try .init();
    defer rt.deinit();

    const ctx: *Context = try .init(rt);
    defer ctx.deinit();

    const atom1 = Atom.init(ctx, "sharedString");
    defer atom1.deinit(ctx);

    const atom2 = Atom.init(ctx, "sharedString");
    defer atom2.deinit(ctx);

    try testing.expectEqual(@intFromEnum(atom1), @intFromEnum(atom2));
}
