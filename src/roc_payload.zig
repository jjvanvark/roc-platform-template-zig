///! Helpers for building the generated `Try` results hosted functions return.
///!
///! On 32-bit targets the generated ABI represents payloads as a raw byte array
///! rather than a union, because Zig cannot express the packing Roc uses there.
///! Both hosts go through here so the wasm32 and native builds stay in step.
const std = @import("std");
const abi = @import("roc_platform_abi.zig");

/// The list type the glue generates for `List(U8)`.
///
/// `U8` is not refcounted, so this is `elements_refcounted = false` — the
/// allocation header is one pointer wide rather than two, and getting it wrong
/// corrupts the heap. Spelled once here so the hosts cannot disagree, and so
/// regenerating `roc_platform_abi.zig` cannot silently change it underneath.
pub const RocBytes = abi.RocListWith(u8, false);

comptime {
    // Guard the assumption above: if glue ever emits a different list type for
    // Request.body, this fails the build instead of miscompiling the header.
    const generated = @FieldType(abi.Request, "body");
    if (generated != RocBytes) @compileError("List(U8) ABI changed: Request.body is no longer RocBytes");
}

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

/// `Ok({})` — a success carrying nothing.
pub fn okEmpty(comptime Result: type) Result {
    var result = std.mem.zeroes(Result);
    result.tag = .Ok;
    return result;
}

/// `Ok(value)` for a success carrying a payload.
pub fn ok(comptime Result: type, value: anytype) Result {
    var result = std.mem.zeroes(Result);
    set(&result, "ok", value);
    result.tag = .Ok;
    return result;
}

/// `Ok(text)` for a success carrying a `Str`.
pub fn okStr(comptime Result: type, text: []const u8, roc_host: *abi.RocHost) Result {
    return ok(Result, abi.RocStr.fromSlice(text, roc_host));
}

/// `Ok(bytes)` for a success carrying a `List(U8)`.
///
/// `U8` is not refcounted, so this is the `elements_refcounted = false` list
/// the glue generates for `List(U8)` — not `RocList(u8)`.
pub fn okBytes(comptime Result: type, bytes: []const u8, roc_host: *abi.RocHost) Result {
    return ok(Result, RocBytes.fromSlice(bytes, roc_host));
}

/// `Err(message)` where the error is a single tag carrying a `Str`, which Roc
/// collapses to a bare `RocStr` payload.
pub fn errStr(comptime Result: type, message: []const u8, roc_host: *abi.RocHost) Result {
    var result = std.mem.zeroes(Result);
    set(&result, "err", abi.RocStr.fromSlice(message, roc_host));
    result.tag = .Err;
    return result;
}

/// `Err(Tag(message))` where the error is a union of a message tag and a
/// payload-less one, e.g. `[KvNotFound, KvErr(Str)]`.
///
/// `field` and `tag` are passed separately because the generated names do not
/// line up: `KvErr` becomes field `kv_err`, but `R2Err` becomes field `r2err`.
pub fn errUnionStr(
    comptime Result: type,
    comptime Err: type,
    comptime field: []const u8,
    comptime tag: anytype,
    message: []const u8,
    roc_host: *abi.RocHost,
) Result {
    var err = std.mem.zeroes(Err);
    set(&err, field, abi.RocStr.fromSlice(message, roc_host));
    err.tag = tag;

    var result = std.mem.zeroes(Result);
    set(&result, "err", err);
    result.tag = .Err;
    return result;
}

/// `Err(Tag)` where the tag carries nothing, e.g. `KvNotFound`.
pub fn errUnionEmpty(
    comptime Result: type,
    comptime Err: type,
    comptime tag: anytype,
) Result {
    var err = std.mem.zeroes(Err);
    err.tag = tag;

    var result = std.mem.zeroes(Result);
    set(&result, "err", err);
    result.tag = .Err;
    return result;
}

