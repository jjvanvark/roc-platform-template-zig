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
//   1. `roc_request_alloc_lens(3 + 2 * header_count)` -> u32 array to fill with
//      the byte length of every segment
//   2. `roc_request_alloc_data(total_len)` -> byte buffer to fill with the
//      segments back to back, in the order
//      method, url, body, name0, value0, name1, value1, ...
//   3. `roc_handle(header_count)` runs the app
//   4. `roc_response_*` read the result
//   5. `roc_response_free()` releases everything
//
// Splitting lengths from bytes is what makes a variable number of headers work:
// wasm function signatures are fixed, so the counts have to travel in memory.
// Allocating both buffers rather than using fixed ones means no size cap.
// =============================================================================

/// Segments that are always present, before any headers: method, url, body.
const fixed_segments = 3;

var request_data: []u8 = &.{};
var request_lens: []u32 = &.{};
var response: ?abi.Response = null;

/// Allocate the segment-length array. `count` must be `3 + 2 * header_count`.
fn rocRequestAllocLens(count: usize) callconv(.c) ?[*]u32 {
    _ = initHost();
    freeRequestLens();
    request_lens = std.heap.wasm_allocator.alloc(u32, count) catch {
        request_lens = &.{};
        return null;
    };
    return request_lens.ptr;
}

/// Allocate the buffer the segments are written into.
fn rocRequestAllocData(total_len: usize) callconv(.c) ?[*]u8 {
    _ = initHost();
    freeRequestData();
    request_data = std.heap.wasm_allocator.alloc(u8, total_len) catch {
        request_data = &.{};
        return null;
    };
    return request_data.ptr;
}

/// Take the next `seg_len` bytes of the request data buffer, advancing `offset`.
fn takeSegment(offset: *usize, seg_len: u32) []const u8 {
    const slice = request_data[offset.*..][0..seg_len];
    offset.* += seg_len;
    return slice;
}

/// Run the app against the marshalled request. Returns 0 on success, or -1 if
/// the segment lengths do not describe exactly the data buffer that was
/// allocated.
fn rocHandle(header_count: usize) callconv(.c) i32 {
    const roc_host = initHost();

    if (request_lens.len != fixed_segments + 2 * header_count) return -1;

    var total: usize = 0;
    for (request_lens) |seg_len| total += seg_len;
    if (total != request_data.len) return -1;

    // Walks the data buffer in step with the length array.
    var offset: usize = 0;

    const method = takeSegment(&offset, request_lens[0]);
    const url = takeSegment(&offset, request_lens[1]);
    const body = takeSegment(&offset, request_lens[2]);

    const headers = abi.RocList(abi.Header).allocate(header_count, roc_host);
    if (header_count > 0) {
        const headers_ptr: [*]abi.Header = headers.elements_ptr.?;
        for (0..header_count) |i| {
            const name = takeSegment(&offset, request_lens[fixed_segments + 2 * i]);
            const value = takeSegment(&offset, request_lens[fixed_segments + 2 * i + 1]);
            headers_ptr[i] = .{
                .name = abi.RocStr.fromSlice(name, roc_host),
                .value = abi.RocStr.fromSlice(value, roc_host),
            };
        }
    }

    // roc_main takes ownership of the Request, so none of this is decref'd here.
    const request: abi.Request = .{
        .method = abi.RocStr.fromSlice(method, roc_host),
        .url = abi.RocStr.fromSlice(url, roc_host),
        .headers = headers,
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

fn rocResponseHeaderCount() callconv(.c) usize {
    if (response) |*r| return r.headers.len();
    return 0;
}

/// Return the name or value of response header `index`, or an empty slice when
/// the index is out of range.
fn responseHeaderField(index: usize, comptime field: []const u8) []const u8 {
    const r = &(response orelse return "");
    const items = r.headers.items();
    if (index >= items.len) return "";
    return @field(items[index], field).asSlice();
}

fn rocResponseHeaderNamePtr(index: usize) callconv(.c) [*]const u8 {
    return responseHeaderField(index, "name").ptr;
}

fn rocResponseHeaderNameLen(index: usize) callconv(.c) usize {
    return responseHeaderField(index, "name").len;
}

fn rocResponseHeaderValuePtr(index: usize) callconv(.c) [*]const u8 {
    return responseHeaderField(index, "value").ptr;
}

fn rocResponseHeaderValueLen(index: usize) callconv(.c) usize {
    return responseHeaderField(index, "value").len;
}

fn freeRequestData() void {
    if (request_data.len > 0) {
        std.heap.wasm_allocator.free(request_data);
        request_data = &.{};
    }
}

fn freeRequestLens() void {
    if (request_lens.len > 0) {
        std.heap.wasm_allocator.free(request_lens);
        request_lens = &.{};
    }
}

/// Release the response and the request buffers, once the embedder has copied
/// the response out.
fn rocResponseFree() callconv(.c) void {
    if (response) |r| {
        r.decref(initHost());
        response = null;
    }
    freeRequestData();
    freeRequestLens();
}

comptime {
    if (!builtin.is_test) {
        @export(&rocRequestAllocLens, .{ .name = "roc_request_alloc_lens" });
        @export(&rocRequestAllocData, .{ .name = "roc_request_alloc_data" });
        @export(&rocHandle, .{ .name = "roc_handle" });
        @export(&rocResponseStatus, .{ .name = "roc_response_status" });
        @export(&rocResponseBodyPtr, .{ .name = "roc_response_body_ptr" });
        @export(&rocResponseBodyLen, .{ .name = "roc_response_body_len" });
        @export(&rocResponseHeaderCount, .{ .name = "roc_response_header_count" });
        @export(&rocResponseHeaderNamePtr, .{ .name = "roc_response_header_name_ptr" });
        @export(&rocResponseHeaderNameLen, .{ .name = "roc_response_header_name_len" });
        @export(&rocResponseHeaderValuePtr, .{ .name = "roc_response_header_value_ptr" });
        @export(&rocResponseHeaderValueLen, .{ .name = "roc_response_header_value_len" });
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
