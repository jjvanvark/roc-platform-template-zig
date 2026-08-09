///! Native platform host.
///!
///! There is no HTTP server here: it synthesizes a Request from argv and
///! prints the Response, so the platform can be exercised locally without
///! wrangler in the loop.
const std = @import("std");
const builtin = @import("builtin");
const abi = @import("roc_platform_abi.zig");
const payload = @import("roc_payload.zig");

pub const std_options: std.Options = .{
    .allow_stack_tracing = false,
};

/// Host environment. Embeds `abi.RocEnv` so the Roc runtime sees a pointer
/// to a standard `RocEnv` while hosted functions can recover the full
/// `HostEnv` via `@fieldParentPtr`.
const HostEnv = struct {
    gpa: std.heap.DebugAllocator(.{}),
    roc_env: abi.RocEnv,
};

/// Roc entrypoint exported by the app under `provides { "roc_main": main_for_host! }`.
extern fn roc_main(request: abi.Request) callconv(.c) abi.Response;

/// Private RocHost used by host helpers and exported runtime symbols.
var g_roc_host: ?*abi.RocHost = null;

// OS-specific entry point handling (not exported during tests)
comptime {
    if (!builtin.is_test) {
        // Export main for all platforms
        @export(&main, .{ .name = "main" });

        // Windows MinGW/MSVCRT compatibility: export __main stub
        if (@import("builtin").os.tag == .windows) {
            @export(&__main, .{ .name = "__main" });
        }
    }
}

// Windows MinGW/MSVCRT compatibility stub
// The C runtime on Windows calls __main from main for constructor initialization
fn __main() callconv(.c) void {}

// C compatible main for runtime
fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    return platform_main(@intCast(argc), argv);
}

fn stderrLineOk() abi.HostStderr_lineResult {
    var result = std.mem.zeroes(abi.HostStderr_lineResult);
    result.tag = .Ok;
    return result;
}

fn stderrLineErr(err: anyerror, roc_host: *abi.RocHost) abi.HostStderr_lineResult {
    var result = std.mem.zeroes(abi.HostStderr_lineResult);
    result.payload = .{ .err = abi.RocStr.fromSlice(@errorName(err), roc_host) };
    result.tag = .Err;
    return result;
}

fn stdoutLineOk() abi.HostStdout_lineResult {
    var result = std.mem.zeroes(abi.HostStdout_lineResult);
    result.tag = .Ok;
    return result;
}

fn stdoutLineErr(err: anyerror, roc_host: *abi.RocHost) abi.HostStdout_lineResult {
    var result = std.mem.zeroes(abi.HostStdout_lineResult);
    result.payload = .{ .err = abi.RocStr.fromSlice(@errorName(err), roc_host) };
    result.tag = .Err;
    return result;
}

/// Hosted function: Host.stderr_line!
fn hostedStderrLine(str: abi.RocStr) callconv(.c) abi.HostStderr_lineResult {
    const roc_host = g_roc_host.?;
    var owned = str;
    defer owned.decref(roc_host);

    const message = owned.asSlice();
    const io = std.Io.Threaded.global_single_threaded.io();
    const stderr = std.Io.File.stderr();
    stderr.writeStreamingAll(io, message) catch |err| return stderrLineErr(err, roc_host);
    stderr.writeStreamingAll(io, "\n") catch |err| return stderrLineErr(err, roc_host);
    return stderrLineOk();
}

// =============================================================================
// KV
//
// There is no Workers KV natively, so this is an in-memory store that lives for
// one process. It exists so KV-using apps can be exercised locally and under
// `zig build test`; anything about durability or eventual consistency has to be
// checked against the real thing.
// =============================================================================

var kv_store: ?std.StringHashMap([]u8) = null;
var kv_allocator: std.mem.Allocator = undefined;

fn kvStore() *std.StringHashMap([]u8) {
    if (kv_store == null) {
        kv_store = std.StringHashMap([]u8).init(kv_allocator);
    }
    return &kv_store.?;
}

/// Free every key and value, then the map itself.
fn kvDeinit() void {
    if (kv_store) |*store| {
        var it = store.iterator();
        while (it.next()) |entry| {
            kv_allocator.free(entry.key_ptr.*);
            kv_allocator.free(entry.value_ptr.*);
        }
        store.deinit();
        kv_store = null;
    }
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
///
/// The binding name is part of the key, so two bindings cannot see each
/// other's entries, matching how real namespaces behave.
fn hostedKvGet(binding: abi.RocStr, key: abi.RocStr) callconv(.c) abi.HostKv_getResult {
    const roc_host = g_roc_host.?;
    var owned_binding = binding;
    var owned_key = key;
    defer owned_binding.decref(roc_host);
    defer owned_key.decref(roc_host);

    const scoped = std.fmt.allocPrint(kv_allocator, "{s}\x00{s}", .{ owned_binding.asSlice(), owned_key.asSlice() }) catch {
        return kvGetErr("out of memory", roc_host);
    };
    defer kv_allocator.free(scoped);

    if (kvStore().get(scoped)) |value| {
        var result = std.mem.zeroes(abi.HostKv_getResult);
        payload.set(&result, "ok", abi.RocStr.fromSlice(value, roc_host));
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
    const roc_host = g_roc_host.?;
    var owned_binding = binding;
    var owned_key = key;
    var owned_value = value;
    defer owned_binding.decref(roc_host);
    defer owned_key.decref(roc_host);
    defer owned_value.decref(roc_host);

    const scoped = std.fmt.allocPrint(kv_allocator, "{s}\x00{s}", .{ owned_binding.asSlice(), owned_key.asSlice() }) catch {
        return kvPutErr("out of memory", roc_host);
    };
    const stored_value = kv_allocator.dupe(u8, owned_value.asSlice()) catch {
        kv_allocator.free(scoped);
        return kvPutErr("out of memory", roc_host);
    };

    const store = kvStore();
    if (store.fetchRemove(scoped)) |old| {
        kv_allocator.free(old.key);
        kv_allocator.free(old.value);
    }
    store.put(scoped, stored_value) catch {
        kv_allocator.free(scoped);
        kv_allocator.free(stored_value);
        return kvPutErr("out of memory", roc_host);
    };

    var result = std.mem.zeroes(abi.HostKv_putResult);
    result.tag = .Ok;
    return result;
}

/// Hosted function: Host.stdout_line!
fn hostedStdoutLine(str: abi.RocStr) callconv(.c) abi.HostStdout_lineResult {
    const roc_host = g_roc_host.?;
    var owned = str;
    defer owned.decref(roc_host);

    const message = owned.asSlice();
    const io = std.Io.Threaded.global_single_threaded.io();
    const stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(io, message) catch |err| return stdoutLineErr(err, roc_host);
    stdout.writeStreamingAll(io, "\n") catch |err| return stdoutLineErr(err, roc_host);
    return stdoutLineOk();
}

fn hostAlloc(length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return abi.DefaultAllocators.rocAlloc(g_roc_host.?, length, alignment);
}

fn hostDealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    abi.DefaultAllocators.rocDealloc(g_roc_host.?, ptr, alignment);
}

fn hostRealloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    return abi.DefaultAllocators.rocRealloc(g_roc_host.?, ptr, new_length, alignment);
}

fn hostDbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    abi.DefaultHandlers.rocDbg(g_roc_host.?, bytes, len);
}

fn hostExpectFailed(bytes: [*]const u8, len: usize) callconv(.c) void {
    abi.DefaultHandlers.rocExpectFailed(g_roc_host.?, bytes, len);
}

fn hostCrashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    abi.DefaultHandlers.rocCrashed(g_roc_host.?, bytes, len);
}

comptime {
    if (!builtin.is_test) {
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

/// Platform host entrypoint.
///
/// Synthesizes a Request from the command line so the platform can be run
/// locally:
///
///     ./app [url] [method] [body] [name:value ...]
///
/// Response headers are printed as `name: value` lines followed by a blank
/// line, then the body. The exit code is 0 for a status below 400, else 1.
fn platform_main(argc: usize, argv: [*][*:0]u8) c_int {
    const io = std.Io.Threaded.global_single_threaded.io();

    var host_env = HostEnv{
        .gpa = std.heap.DebugAllocator(.{}){},
        .roc_env = undefined,
    };
    host_env.roc_env = .{
        .allocator = host_env.gpa.allocator(),
        .roc_io = abi.RocIo.default(),
    };

    var roc_host = abi.makeRocHost(&host_env.roc_env);
    g_roc_host = &roc_host;
    kv_allocator = host_env.gpa.allocator();

    // argv[0] is the executable itself.
    const url = argAt(argc, argv, 1) orelse "http://localhost/";
    const method = argAt(argc, argv, 2) orelse "GET";
    const body = argAt(argc, argv, 3) orelse "";

    // Everything after the body is a `name:value` header.
    const first_header = @min(argc, 4);
    const header_count = argc - first_header;
    const headers = abi.RocList(abi.Header).allocate(header_count, &roc_host);
    if (header_count > 0) {
        const headers_ptr: [*]abi.Header = headers.elements_ptr.?;
        for (0..header_count) |i| {
            const arg = argAt(argc, argv, first_header + i).?;
            // A header with no colon is treated as a name with an empty value.
            const split = std.mem.indexOfScalar(u8, arg, ':') orelse arg.len;
            const name = arg[0..split];
            const value = if (split < arg.len) arg[split + 1 ..] else "";
            headers_ptr[i] = .{
                .name = abi.RocStr.fromSlice(name, &roc_host),
                .value = abi.RocStr.fromSlice(value, &roc_host),
            };
        }
    }

    // roc_main takes ownership of the Request, so none of this is decref'd here.
    const request: abi.Request = .{
        .method = abi.RocStr.fromSlice(method, &roc_host),
        .url = abi.RocStr.fromSlice(url, &roc_host),
        .headers = headers,
        .body = abi.RocStr.fromSlice(body, &roc_host),
    };

    const response = roc_main(request);
    const status = response.status;

    const stdout = std.Io.File.stdout();
    const response_headers = response.headers.items();
    for (response_headers) |header| {
        stdout.writeStreamingAll(io, header.name.asSlice()) catch {};
        stdout.writeStreamingAll(io, ": ") catch {};
        stdout.writeStreamingAll(io, header.value.asSlice()) catch {};
        stdout.writeStreamingAll(io, "\n") catch {};
    }
    if (response_headers.len > 0) {
        stdout.writeStreamingAll(io, "\n") catch {};
    }
    stdout.writeStreamingAll(io, response.body.asSlice()) catch {};

    // The host owns the returned Response.
    response.decref(&roc_host);

    // Must run before the leak check, or the store's own entries look like leaks.
    kvDeinit();

    const leak_status = host_env.gpa.deinit();
    if (leak_status == .leak) {
        std.log.err("\x1b[33mMemory leak detected!\x1b[0m", .{});
        std.process.exit(1);
    }

    return if (status < 400) 0 else 1;
}

/// Return argv[index] as a slice, or null when there are fewer arguments.
fn argAt(argc: usize, argv: [*][*:0]u8, index: usize) ?[]const u8 {
    if (index >= argc) return null;
    const cstr = argv[index];
    return cstr[0..std.mem.len(cstr)];
}
