///! Platform host for the wasm32 target.
///!
///! Unlike `host.zig`, there is no POSIX stdio, no `main(argc, argv)` and no
///! process to exit. Everything the host cannot do itself is delegated to the
///! embedder through the `env` import namespace, and the Roc entrypoint is
///! exposed as an exported wasm function the embedder calls directly.
const std = @import("std");
const builtin = @import("builtin");
const abi = @import("roc_platform_abi.zig");

pub const std_options: std.Options = .{
    .allow_stack_tracing = false,
};

// =============================================================================
// Imports provided by the embedder (JavaScript)
// =============================================================================

/// Write a line to the embedder's log. `stream` is 1 for stdout, 2 for stderr.
extern "env" fn host_log(stream: u32, ptr: [*]const u8, len: usize) void;

// =============================================================================
// Host environment
// =============================================================================

const HostEnv = struct {
    roc_env: abi.RocEnv,
};

var g_host_env: HostEnv = undefined;
var g_roc_host: ?*abi.RocHost = null;
var g_roc_host_storage: abi.RocHost = undefined;

/// `RocIo` backend that routes stderr through the embedder and traps on fatal
/// errors (a wasm trap surfaces to the embedder as an exception).
fn ioWriteStderr(_: ?*anyopaque, data: []const u8) void {
    host_log(2, data.ptr, data.len);
}

fn ioOnFatal(_: ?*anyopaque) noreturn {
    @trap();
}

const io_vtable: abi.RocIo.VTable = .{
    .writeStderr = &ioWriteStderr,
    .onFatal = &ioOnFatal,
};

fn initHost() *abi.RocHost {
    if (g_roc_host) |host| return host;

    g_host_env = .{
        .roc_env = .{
            .allocator = std.heap.wasm_allocator,
            .roc_io = .{ .ctx = null, .vtable = &io_vtable },
        },
    };
    g_roc_host_storage = abi.makeRocHost(&g_host_env.roc_env);
    g_roc_host = &g_roc_host_storage;
    return &g_roc_host_storage;
}

// =============================================================================
// Hosted functions
// =============================================================================

/// Store a `RocStr` in a `Try` payload.
///
/// On 32-bit targets the generated ABI represents the payload as a raw `[12]u8`
/// rather than a union, because Zig cannot express the packing Roc uses there.
/// `host.zig` never hits this branch, since every native target is 64-bit.
fn setPayloadStr(result: anytype, str: abi.RocStr) void {
    const Payload = @TypeOf(result.payload);
    if (comptime @typeInfo(Payload) == .array) {
        const ptr: *abi.RocStr = @ptrCast(@alignCast(&result.payload));
        ptr.* = str;
    } else {
        result.payload = .{ .err = str };
    }
}

/// Hosted function: Host.stdout_line!
fn hostedStdoutLine(str: abi.RocStr) callconv(.c) abi.HostStdout_lineResult {
    const roc_host = initHost();
    var owned = str;
    defer owned.decref(roc_host);

    const message = owned.asSlice();
    host_log(1, message.ptr, message.len);

    var result = std.mem.zeroes(abi.HostStdout_lineResult);
    result.tag = .Ok;
    return result;
}

/// Hosted function: Host.stderr_line!
fn hostedStderrLine(str: abi.RocStr) callconv(.c) abi.HostStderr_lineResult {
    const roc_host = initHost();
    var owned = str;
    defer owned.decref(roc_host);

    const message = owned.asSlice();
    host_log(2, message.ptr, message.len);

    var result = std.mem.zeroes(abi.HostStderr_lineResult);
    result.tag = .Ok;
    return result;
}

// =============================================================================
// Roc runtime symbols
// =============================================================================

fn hostAlloc(length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return abi.DefaultAllocators.rocAlloc(initHost(), length, alignment);
}

fn hostDealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    abi.DefaultAllocators.rocDealloc(initHost(), ptr, alignment);
}

fn hostRealloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return abi.DefaultAllocators.rocRealloc(initHost(), ptr, new_length, alignment);
}

fn hostDbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    abi.DefaultHandlers.rocDbg(initHost(), bytes, len);
}

fn hostExpectFailed(bytes: [*]const u8, len: usize) callconv(.c) void {
    abi.DefaultHandlers.rocExpectFailed(initHost(), bytes, len);
}

fn hostCrashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    abi.DefaultHandlers.rocCrashed(initHost(), bytes, len);
}

/// Roc entrypoint exported by the app under `provides { "roc_main": main_for_host! }`.
extern fn roc_main(request: abi.Request) callconv(.c) abi.Response;

// =============================================================================
// Request/response marshalling
//
// The embedder cannot build Roc values itself, so the exchange is:
//
//   1. `roc_request_alloc(total_len)` -> pointer to write into
//   2. embedder writes method, then url, then body, back to back
//   3. `roc_handle(method_len, url_len, body_len)` runs the app
//   4. `roc_response_status` / `_body_ptr` / `_body_len` read the result
//   5. `roc_response_free()` releases both
//
// A length-prefixed buffer avoids a fixed size cap on the request body, and
// keeps the embedder from having to build Roc values itself.
// =============================================================================

var request_buf: []u8 = &.{};
var response: ?abi.Response = null;

/// Allocate a buffer for the embedder to write the request parts into.
/// Returns null if the allocation fails.
fn rocRequestAlloc(total_len: usize) callconv(.c) ?[*]u8 {
    _ = initHost();
    if (request_buf.len > 0) std.heap.wasm_allocator.free(request_buf);
    request_buf = std.heap.wasm_allocator.alloc(u8, total_len) catch {
        request_buf = &.{};
        return null;
    };
    return request_buf.ptr;
}

/// Run the app against the request written into the buffer from
/// `roc_request_alloc`. Returns 0 on success, or -1 if the lengths do not add
/// up to the buffer that was allocated.
fn rocHandle(method_len: usize, url_len: usize, body_len: usize) callconv(.c) i32 {
    const roc_host = initHost();

    if (method_len + url_len + body_len != request_buf.len) return -1;

    const method = request_buf[0..method_len];
    const url = request_buf[method_len..][0..url_len];
    const body = request_buf[method_len + url_len ..][0..body_len];

    // roc_main takes ownership of the Request, so these are not decref'd here.
    const request: abi.Request = .{
        .method = abi.RocStr.fromSlice(method, roc_host),
        .url = abi.RocStr.fromSlice(url, roc_host),
        .body = abi.RocStr.fromSlice(body, roc_host),
    };

    response = roc_main(request);
    return 0;
}

fn rocResponseStatus() callconv(.c) u32 {
    return if (response) |r| r.status else 0;
}

fn rocResponseBodyPtr() callconv(.c) [*]const u8 {
    if (response) |*r| return r.body.asSlice().ptr;
    return "";
}

fn rocResponseBodyLen() callconv(.c) usize {
    if (response) |*r| return r.body.asSlice().len;
    return 0;
}

/// Release the response and the request buffer, once the embedder has copied
/// the body out.
fn rocResponseFree() callconv(.c) void {
    if (response) |r| {
        r.decref(initHost());
        response = null;
    }
    if (request_buf.len > 0) {
        std.heap.wasm_allocator.free(request_buf);
        request_buf = &.{};
    }
}

comptime {
    if (!builtin.is_test) {
        @export(&rocRequestAlloc, .{ .name = "roc_request_alloc" });
        @export(&rocHandle, .{ .name = "roc_handle" });
        @export(&rocResponseStatus, .{ .name = "roc_response_status" });
        @export(&rocResponseBodyPtr, .{ .name = "roc_response_body_ptr" });
        @export(&rocResponseBodyLen, .{ .name = "roc_response_body_len" });
        @export(&rocResponseFree, .{ .name = "roc_response_free" });

        @export(&hostedStderrLine, .{ .name = "roc_stderr_line", .visibility = .hidden });
        @export(&hostedStdoutLine, .{ .name = "roc_stdout_line", .visibility = .hidden });

        @export(&hostAlloc, .{ .name = "roc_alloc", .visibility = .hidden });
        @export(&hostDealloc, .{ .name = "roc_dealloc", .visibility = .hidden });
        @export(&hostRealloc, .{ .name = "roc_realloc", .visibility = .hidden });
        @export(&hostDbg, .{ .name = "roc_dbg", .visibility = .hidden });
        @export(&hostExpectFailed, .{ .name = "roc_expect_failed", .visibility = .hidden });
        @export(&hostCrashed, .{ .name = "roc_crashed", .visibility = .hidden });
    }
}
