const atom = @import("atom.zig");
const class = @import("class.zig");
const context = @import("context.zig");
const module = @import("module.zig");
const runtime = @import("runtime.zig");
const value = @import("value.zig");

pub const c = @import("quickjs_c");
pub const cfunc = @import("cfunc.zig");
pub const typed_array = @import("typed_array.zig");

pub const Atom = atom.Atom;
pub const Context = context.Context;
pub const EvalFlags = context.EvalFlags;
pub const ModuleDef = module.ModuleDef;
pub const Runtime = runtime.Runtime;
pub const DumpFlags = runtime.DumpFlags;
pub const Value = value.Value;
pub const Promise = value.Value.Promise;
pub const PromiseState = value.PromiseState;
pub const ClassId = class.Id;
pub const ClassDef = class.Def;
pub const ClassExoticMethods = class.ExoticMethods;

pub fn version() [*:0]const u8 {
    return c.JS_GetVersion();
}

/// Detects if input looks like an ES module.
///
/// Returns true if the input contains `import` or `export` statements
/// at the top level.
///
/// C: `JS_DetectModule`
pub fn detectModule(input: []const u8) bool {
    return c.JS_DetectModule(input.ptr, input.len);
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "detectModule" {
    const testing = @import("std").testing;
    try testing.expect(detectModule("import { foo } from 'bar';"));
    try testing.expect(detectModule("export const x = 1;"));
    try testing.expect(detectModule("export default function() {}"));
}
