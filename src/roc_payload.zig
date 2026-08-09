///! Helper for writing into generated `Try`/tag-union payloads.
///!
///! On 32-bit targets the generated ABI represents payloads as a raw byte array
///! rather than a union, because Zig cannot express the packing Roc uses there.
///! Both hosts go through here so the wasm32 and native builds stay in step.
const std = @import("std");

/// Store `value` in `result.payload`, under union field `field` on 64-bit
/// targets and by direct write on 32-bit ones.
pub fn set(result: anytype, comptime field: []const u8, value: anytype) void {
    const Payload = @TypeOf(result.payload);
    if (comptime @typeInfo(Payload) == .array) {
        const ptr: *@TypeOf(value) = @ptrCast(@alignCast(&result.payload));
        ptr.* = value;
    } else {
        result.payload = @unionInit(Payload, field, value);
    }
}
