// Helpers for userdata handling.

/// Given an opaque type T, returns the expected type T that the user
/// should pass in. This is necessary because if the user provides `void`,
/// then we don't want a `void` pointer, we just want void.
pub fn Opaque(comptime T: type) type {
    // Void as-is so the function signature is cleaner.
    if (T == void) return void;

    // Optional pointer to the type.
    return ?*T;
}

pub fn toC(comptime T: type, value: Opaque(T)) ?*anyopaque {
    if (T == void) return null;
    return @ptrCast(value);
}

pub fn fromC(comptime T: type, ud: ?*anyopaque) Opaque(T) {
    if (T == void) return;
    return @alignCast(@ptrCast(ud));
}
