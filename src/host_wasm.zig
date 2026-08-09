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

/// Hosted function: Host.stdin_line!
///
/// There is no stdin in a wasm embedding, so this always fails.
fn hostedStdinLine() callconv(.c) abi.HostStdin_lineResult {
    const roc_host = initHost();
    var result = std.mem.zeroes(abi.HostStdin_lineResult);
    setPayloadStr(&result, abi.RocStr.fromSlice("stdin is not available on wasm32", roc_host));
    result.tag = .Err;
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
extern fn roc_main(args: abi.RocList(abi.RocStr)) callconv(.c) i32;

/// Scratch buffer the embedder writes the request URL into before calling
/// `roc_entry`. A fixed buffer keeps the embedder from having to drive the Roc
/// allocator; this goes away once Request/Response marshalling lands.
var url_buf: [4096]u8 = undefined;

/// Returns a pointer to `url_buf` so the embedder can write into it.
fn rocUrlBuffer() callconv(.c) [*]u8 {
    return &url_buf;
}

/// Size of `url_buf`, so the embedder can reject oversized URLs.
fn rocUrlBufferLen() callconv(.c) usize {
    return url_buf.len;
}

/// Entrypoint the embedder calls. Mirrors `platform_main` in `host.zig`, but
/// takes the request URL from `url_buf` instead of argv and returns the app's
/// exit code instead of exiting.
fn rocEntry(url_len: usize) callconv(.c) i32 {
    const roc_host = initHost();

    const len = @min(url_len, url_buf.len);
    const args = abi.RocList(abi.RocStr).allocate(1, roc_host);
    const args_ptr: [*]abi.RocStr = args.elements_ptr.?;
    args_ptr[0] = abi.RocStr.fromSlice(url_buf[0..len], roc_host);

    return roc_main(args);
}

comptime {
    if (!builtin.is_test) {
        @export(&rocEntry, .{ .name = "roc_entry" });
        @export(&rocUrlBuffer, .{ .name = "roc_url_buffer" });
        @export(&rocUrlBufferLen, .{ .name = "roc_url_buffer_len" });

        @export(&hostedStderrLine, .{ .name = "roc_stderr_line", .visibility = .hidden });
        @export(&hostedStdinLine, .{ .name = "roc_stdin_line", .visibility = .hidden });
        @export(&hostedStdoutLine, .{ .name = "roc_stdout_line", .visibility = .hidden });

        @export(&hostAlloc, .{ .name = "roc_alloc", .visibility = .hidden });
        @export(&hostDealloc, .{ .name = "roc_dealloc", .visibility = .hidden });
        @export(&hostRealloc, .{ .name = "roc_realloc", .visibility = .hidden });
        @export(&hostDbg, .{ .name = "roc_dbg", .visibility = .hidden });
        @export(&hostExpectFailed, .{ .name = "roc_expect_failed", .visibility = .hidden });
        @export(&hostCrashed, .{ .name = "roc_crashed", .visibility = .hidden });
    }
}
