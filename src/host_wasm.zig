///! Platform host for the wasm32 target, backed by workers-zig.
///!
///! Unlike `host.zig` there is no `main(argc, argv)`: the JS shim calls the
///! exported `fetch` below, handing over opaque handles that workers-zig wraps
///! into `Request`/`Response` objects. This file's job is to translate between
///! those and the Roc `Request`/`Response` the app sees.
///!
///! The corresponding role in a plain workers-zig project is played by the
///! SDK's own `src/entry.zig`. We do not use it, because it is written to be
///! the root of an executable that imports a user module, and here Roc owns the
///! final link. Only the `fetch` handler is needed, so it is spelled out.
const std = @import("std");
const builtin = @import("builtin");
const workers = @import("workers-zig");
const abi = @import("roc_platform_abi.zig");
const payload = @import("roc_payload.zig");

pub const std_options: std.Options = .{
    .allow_stack_tracing = false,
};

// =============================================================================
// Host environment
// =============================================================================

const HostEnv = struct {
    roc_env: abi.RocEnv,
};

/// The Env for the request currently being handled. Bindings only exist inside
/// a request, so hosted functions that need one fail when this is null.
var g_env: ?workers.Env = null;

var g_host_env: HostEnv = undefined;
var g_roc_host: ?*abi.RocHost = null;
var g_roc_host_storage: abi.RocHost = undefined;

/// `RocIo` backend that routes stderr to the JS console and traps on fatal
/// errors (a wasm trap surfaces to the shim as an exception).
fn ioWriteStderr(_: ?*anyopaque, data: []const u8) void {
    workers.js.console_error(data.ptr, @intCast(data.len));
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
            .allocator = workers.allocator,
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

/// Hosted function: Host.stdout_line!
fn hostedStdoutLine(str: abi.RocStr) callconv(.c) abi.HostStdout_lineResult {
    const roc_host = initHost();
    var owned = str;
    defer owned.decref(roc_host);

    const message = owned.asSlice();
    workers.js.console_log(message.ptr, @intCast(message.len));

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
    workers.js.console_error(message.ptr, @intCast(message.len));

    var result = std.mem.zeroes(abi.HostStderr_lineResult);
    result.tag = .Ok;
    return result;
}

/// Format "no KV binding named 'X'" into a scratch buffer.
///
/// The message names the binding because getting it wrong is the most likely
/// mistake, and the wrangler config is the only place it can be fixed.
var binding_err_buf: [256]u8 = undefined;
fn missingBindingMessage(name: []const u8) []const u8 {
    return std.fmt.bufPrint(
        &binding_err_buf,
        "no KV binding named '{s}' — add it to kv_namespaces in your wrangler config",
        .{name},
    ) catch "no KV binding with that name in the wrangler config";
}

/// Look up a binding by name on the current request's Env.
fn lookupBinding(comptime T: type, name: []const u8) !T {
    const env = g_env orelse return error.NoRequestInFlight;
    const handle = workers.js.env_get_binding(env.handle, name.ptr, @intCast(name.len));
    if (handle == workers.js.null_handle) return error.BindingNotFound;
    return T.init(handle, env.allocator);
}

fn kvGetErr(message: []const u8, roc_host: *abi.RocHost) abi.HostKv_getResult {
    var err = std.mem.zeroes(abi.KvErrOrKvNotFound);
    payload.set(&err, "kv_err", abi.RocStr.fromSlice(message, roc_host));
    err.tag = .KvErr;

    var result = std.mem.zeroes(abi.HostKv_getResult);
    payload.set(&result, "err", err);
    result.tag = .Err;
    return result;
}

/// Hosted function: Host.kv_get!
fn hostedKvGet(binding: abi.RocStr, key: abi.RocStr) callconv(.c) abi.HostKv_getResult {
    const roc_host = initHost();
    var owned_binding = binding;
    var owned_key = key;
    defer owned_binding.decref(roc_host);
    defer owned_key.decref(roc_host);

    const kv = lookupBinding(workers.KvNamespace, owned_binding.asSlice()) catch |e| switch (e) {
        error.NoRequestInFlight => return kvGetErr("KV is only available while handling a request", roc_host),
        error.BindingNotFound => return kvGetErr(missingBindingMessage(owned_binding.asSlice()), roc_host),
    };

    const value = kv.getText(owned_key.asSlice()) catch |e| {
        return kvGetErr(@errorName(e), roc_host);
    };

    if (value) |v| {
        var result = std.mem.zeroes(abi.HostKv_getResult);
        payload.set(&result, "ok", abi.RocStr.fromSlice(v, roc_host));
        result.tag = .Ok;
        return result;
    }

    var not_found = std.mem.zeroes(abi.KvErrOrKvNotFound);
    not_found.tag = .KvNotFound;
    var result = std.mem.zeroes(abi.HostKv_getResult);
    payload.set(&result, "err", not_found);
    result.tag = .Err;
    return result;
}

fn kvPutErr(message: []const u8, roc_host: *abi.RocHost) abi.HostKv_putResult {
    var result = std.mem.zeroes(abi.HostKv_putResult);
    payload.set(&result, "err", abi.RocStr.fromSlice(message, roc_host));
    result.tag = .Err;
    return result;
}

/// Hosted function: Host.kv_put!
fn hostedKvPut(binding: abi.RocStr, key: abi.RocStr, value: abi.RocStr) callconv(.c) abi.HostKv_putResult {
    const roc_host = initHost();
    var owned_binding = binding;
    var owned_key = key;
    var owned_value = value;
    defer owned_binding.decref(roc_host);
    defer owned_key.decref(roc_host);
    defer owned_value.decref(roc_host);

    const kv = lookupBinding(workers.KvNamespace, owned_binding.asSlice()) catch |e| switch (e) {
        error.NoRequestInFlight => return kvPutErr("KV is only available while handling a request", roc_host),
        error.BindingNotFound => return kvPutErr(missingBindingMessage(owned_binding.asSlice()), roc_host),
    };

    kv.put(owned_key.asSlice(), owned_value.asSlice());

    var result = std.mem.zeroes(abi.HostKv_putResult);
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
// fetch handler
// =============================================================================

/// Build the Roc `Request` the app sees from the workers-zig one.
///
/// Every string is copied into Roc-owned memory, because `roc_main` takes
/// ownership of the whole Request while the workers-zig values live in a
/// per-request arena this host frees on the way out.
fn toRocRequest(request: *workers.Request, roc_host: *abi.RocHost) !abi.Request {
    const url = try request.url();
    const body = (try request.body()) orelse "";
    const header_entries = try request.headers();

    const headers = abi.RocList(abi.Header).allocate(header_entries.len, roc_host);
    if (header_entries.len > 0) {
        const headers_ptr: [*]abi.Header = headers.elements_ptr.?;
        for (header_entries, 0..) |entry, i| {
            headers_ptr[i] = .{
                .name = abi.RocStr.fromSlice(entry.name, roc_host),
                .value = abi.RocStr.fromSlice(entry.value, roc_host),
            };
        }
    }

    return .{
        .method = abi.RocStr.fromSlice(@tagName(request.method()), roc_host),
        .url = abi.RocStr.fromSlice(url, roc_host),
        .headers = headers,
        .body = abi.RocStr.fromSlice(body, roc_host),
    };
}

/// Turn the Roc `Response` into the workers-zig one the shim sends back.
fn toWorkersResponse(roc_response: abi.Response) workers.Response {
    var response = workers.Response.new();

    // Roc models the status as a plain U16, so an unrecognised code is passed
    // through as whatever the app asked for.
    response.setStatus(@enumFromInt(roc_response.status));

    var saw_content_type = false;
    for (roc_response.headers.items()) |header| {
        const name = header.name.asSlice();
        if (std.ascii.eqlIgnoreCase(name, "content-type")) saw_content_type = true;
        response.setHeader(name, header.value.asSlice());
    }
    if (!saw_content_type) {
        response.setHeader("content-type", "text/plain; charset=utf-8");
    }

    response.setBody(roc_response.body.asSlice());
    return response;
}

/// Entry point the JS shim calls. The arguments are opaque indices into the
/// shim's object table.
fn fetchHandler(req_handle: u32, env_handle: u32, ctx_handle: u32) callconv(.c) u32 {
    _ = ctx_handle;

    var arena = std.heap.ArenaAllocator.init(workers.allocator);
    defer arena.deinit();

    // Bindings are reachable from hosted functions for the duration of the call.
    g_env = workers.Env.init(env_handle, arena.allocator());
    defer g_env = null;

    const roc_host = initHost();
    var request = workers.Request.init(req_handle, arena.allocator());

    // roc_main takes ownership of the Request, so it is not decref'd here.
    const roc_request = toRocRequest(&request, roc_host) catch {
        return workers.Response.err(.internal_server_error, "Could not read the request\n").handle;
    };

    const roc_response = roc_main(roc_request);
    defer roc_response.decref(roc_host);

    return toWorkersResponse(roc_response).handle;
}

// =============================================================================
// Memory exports the JS shim uses to write into linear memory.
// =============================================================================

fn wasmAlloc(len: u32) callconv(.c) ?[*]u8 {
    const slice = workers.allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

fn wasmDealloc(ptr: [*]u8, len: u32) callconv(.c) void {
    workers.allocator.free(ptr[0..len]);
}

comptime {
    if (!builtin.is_test) {
        @export(&fetchHandler, .{ .name = "fetch" });
        @export(&wasmAlloc, .{ .name = "wasm_alloc" });
        @export(&wasmDealloc, .{ .name = "wasm_dealloc" });

        @export(&hostedStderrLine, .{ .name = "roc_stderr_line", .visibility = .hidden });
        @export(&hostedStdoutLine, .{ .name = "roc_stdout_line", .visibility = .hidden });
        @export(&hostedKvGet, .{ .name = "roc_kv_get", .visibility = .hidden });
        @export(&hostedKvPut, .{ .name = "roc_kv_put", .visibility = .hidden });

        @export(&hostAlloc, .{ .name = "roc_alloc", .visibility = .hidden });
        @export(&hostDealloc, .{ .name = "roc_dealloc", .visibility = .hidden });
        @export(&hostRealloc, .{ .name = "roc_realloc", .visibility = .hidden });
        @export(&hostDbg, .{ .name = "roc_dbg", .visibility = .hidden });
        @export(&hostExpectFailed, .{ .name = "roc_expect_failed", .visibility = .hidden });
        @export(&hostCrashed, .{ .name = "roc_crashed", .visibility = .hidden });
    }
}
