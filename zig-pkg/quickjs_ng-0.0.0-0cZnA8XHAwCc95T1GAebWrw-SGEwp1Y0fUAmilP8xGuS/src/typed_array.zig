const std = @import("std");
const testing = std.testing;
const c = @import("quickjs_c");
const Context = @import("context.zig").Context;
const Runtime = @import("runtime.zig").Runtime;
const Value = @import("value.zig").Value;
const opaquepkg = @import("opaque.zig");
const Opaque = opaquepkg.Opaque;

/// TypedArray element type.
///
/// C: `JSTypedArrayEnum`
pub const Type = enum(c_uint) {
    uint8_clamped = c.JS_TYPED_ARRAY_UINT8C,
    int8 = c.JS_TYPED_ARRAY_INT8,
    uint8 = c.JS_TYPED_ARRAY_UINT8,
    int16 = c.JS_TYPED_ARRAY_INT16,
    uint16 = c.JS_TYPED_ARRAY_UINT16,
    int32 = c.JS_TYPED_ARRAY_INT32,
    uint32 = c.JS_TYPED_ARRAY_UINT32,
    big_int64 = c.JS_TYPED_ARRAY_BIG_INT64,
    big_uint64 = c.JS_TYPED_ARRAY_BIG_UINT64,
    float16 = c.JS_TYPED_ARRAY_FLOAT16,
    float32 = c.JS_TYPED_ARRAY_FLOAT32,
    float64 = c.JS_TYPED_ARRAY_FLOAT64,
};

/// Information about a typed array's underlying buffer.
pub const Buffer = struct {
    value: Value,
    byte_offset: usize,
    byte_length: usize,
    bytes_per_element: usize,
};

/// Callback for freeing ArrayBuffer data.
///
/// C: `JSFreeArrayBufferDataFunc`
pub fn FreeBufferDataFunc(comptime T: type) type {
    return *const fn (
        rt: *Runtime,
        userdata: Opaque(T),
        ptr: ?*anyopaque,
    ) void;
}

/// Wraps a Zig-friendly FreeBufferDataFunc into a C-callable function.
pub fn wrapFreeBufferDataFunc(comptime T: type, comptime func: FreeBufferDataFunc(T)) c.JSFreeArrayBufferDataFunc {
    return struct {
        fn callback(
            rt: ?*c.JSRuntime,
            opaque_ptr: ?*anyopaque,
            ptr: ?*anyopaque,
        ) callconv(.c) void {
            @call(.always_inline, func, .{
                @as(*Runtime, @ptrCast(rt)),
                opaquepkg.fromC(T, opaque_ptr),
                ptr,
            });
        }
    }.callback;
}

/// Functions for SharedArrayBuffer support.
///
/// C: `JSSharedArrayBufferFunctions`
pub const SharedBufferFunctions = struct {
    alloc: ?*const fn (userdata: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque = null,
    free: ?*const fn (userdata: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void = null,
    dup: ?*const fn (userdata: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void = null,
    userdata: ?*anyopaque = null,

    fn toCStruct(self: SharedBufferFunctions) c.JSSharedArrayBufferFunctions {
        return .{
            .sab_alloc = self.alloc,
            .sab_free = self.free,
            .sab_dup = self.dup,
            .sab_opaque = self.userdata,
        };
    }
};

test "Type matches C constants" {
    try testing.expectEqual(@as(c_uint, 0), @intFromEnum(Type.uint8_clamped));
    try testing.expectEqual(@as(c_uint, 1), @intFromEnum(Type.int8));
    try testing.expectEqual(@as(c_uint, 2), @intFromEnum(Type.uint8));
    try testing.expectEqual(@as(c_uint, 3), @intFromEnum(Type.int16));
    try testing.expectEqual(@as(c_uint, 4), @intFromEnum(Type.uint16));
    try testing.expectEqual(@as(c_uint, 5), @intFromEnum(Type.int32));
    try testing.expectEqual(@as(c_uint, 6), @intFromEnum(Type.uint32));
    try testing.expectEqual(@as(c_uint, 7), @intFromEnum(Type.big_int64));
    try testing.expectEqual(@as(c_uint, 8), @intFromEnum(Type.big_uint64));
    try testing.expectEqual(@as(c_uint, 9), @intFromEnum(Type.float16));
    try testing.expectEqual(@as(c_uint, 10), @intFromEnum(Type.float32));
    try testing.expectEqual(@as(c_uint, 11), @intFromEnum(Type.float64));
}
