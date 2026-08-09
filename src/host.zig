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
// Bindings
//
// None of the Cloudflare bindings exist natively. KV and R2 get an in-memory
// store that lives for one process, so apps using them can be exercised
// locally and under `zig build test`. D1 would need a SQL engine, so it
// reports that it is unavailable rather than pretending. Queue sends are
// written to stderr, which is enough to assert on.
//
// Anything about durability, eventual consistency or real query behaviour has
// to be checked against the real thing.
// =============================================================================

var store: ?std.StringHashMap([]u8) = null;
var store_allocator: std.mem.Allocator = undefined;

fn bindingStore() *std.StringHashMap([]u8) {
    if (store == null) {
        store = std.StringHashMap([]u8).init(store_allocator);
    }
    return &store.?;
}

/// Free every key and value, then the map itself.
fn storeDeinit() void {
    if (store) |*s| {
        var it = s.iterator();
        while (it.next()) |entry| {
            store_allocator.free(entry.key_ptr.*);
            store_allocator.free(entry.value_ptr.*);
        }
        s.deinit();
        store = null;
    }
}

/// Scope a key by binding kind and name, so two bindings cannot see each
/// other's entries the way two real namespaces cannot.
fn scopedKey(comptime kind: []const u8, binding: []const u8, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(store_allocator, kind ++ "\x00{s}\x00{s}", .{ binding, key });
}

fn storeGet(comptime kind: []const u8, binding: []const u8, key: []const u8) !?[]const u8 {
    const scoped = try scopedKey(kind, binding, key);
    defer store_allocator.free(scoped);
    return bindingStore().get(scoped);
}

fn storePut(comptime kind: []const u8, binding: []const u8, key: []const u8, value: []const u8) !void {
    const scoped = try scopedKey(kind, binding, key);
    errdefer store_allocator.free(scoped);
    const stored = try store_allocator.dupe(u8, value);
    errdefer store_allocator.free(stored);

    const s = bindingStore();
    if (s.fetchRemove(scoped)) |old| {
        store_allocator.free(old.key);
        store_allocator.free(old.value);
    }
    try s.put(scoped, stored);
}

fn storeDelete(comptime kind: []const u8, binding: []const u8, key: []const u8) !void {
    const scoped = try scopedKey(kind, binding, key);
    defer store_allocator.free(scoped);
    if (bindingStore().fetchRemove(scoped)) |old| {
        store_allocator.free(old.key);
        store_allocator.free(old.value);
    }
}

/// libc's `environ`, declared here rather than reached through `std.c`.
///
/// Both `std.c` and an `extern "c"` declaration make Zig demand `link_libc` at
/// *compile* time, which the musl targets cannot satisfy: this is a static
/// archive, and libc only joins at the final link, when Roc pulls in `crt1.o`
/// and `libc.a` alongside `libhost.a`. A plain `extern` needs no such promise
/// and resolves to the same symbol — `environ` on ELF, `_environ` on Mach-O —
/// at the link where it was always going to be resolved.
extern var environ: [*:null]?[*:0]u8;

/// Look up a process environment variable.
///
/// The Workers analogue of a text binding is an environment variable, so the
/// native host reads the real process environment rather than stubbing this
/// out. Windows is the exception: msvcrt does not expose `environ` under this
/// name, so there is nothing to read.
fn processEnvGet(name: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;

    var i: usize = 0;
    while (environ[i]) |entry| : (i += 1) {
        const pair = std.mem.sliceTo(entry, 0);
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

/// Hosted function: Host.env_get!
fn hostedEnvGet(name: abi.RocStr) callconv(.c) abi.HostEnv_getResult {
    const Result = abi.HostEnv_getResult;
    const roc_host = g_roc_host.?;
    var owned_name = name;
    defer owned_name.decref(roc_host);

    if (builtin.os.tag == .windows) {
        return payload.errUnionStr(Result, abi.EnvErrOrEnvNotFound, "env_err", .EnvErr, "reading environment variables is not supported on Windows natively", roc_host);
    }

    if (processEnvGet(owned_name.asSlice())) |value| {
        return payload.okStr(Result, value, roc_host);
    }
    return payload.errUnionEmpty(Result, abi.EnvErrOrEnvNotFound, .EnvNotFound);
}

/// Hosted function: Host.kv_get!
fn hostedKvGet(binding: abi.RocStr, key: abi.RocStr) callconv(.c) abi.HostKv_getResult {
    const Result = abi.HostKv_getResult;
    const roc_host = g_roc_host.?;
    var owned_binding = binding;
    var owned_key = key;
    defer owned_binding.decref(roc_host);
    defer owned_key.decref(roc_host);

    const value = storeGet("kv", owned_binding.asSlice(), owned_key.asSlice()) catch {
        return payload.errUnionStr(Result, abi.KvErrOrKvNotFound, "kv_err", .KvErr, "out of memory", roc_host);
    };
    if (value) |v| return payload.okStr(Result, v, roc_host);
    return payload.errUnionEmpty(Result, abi.KvErrOrKvNotFound, .KvNotFound);
}

/// Hosted function: Host.kv_put!
fn hostedKvPut(binding: abi.RocStr, key: abi.RocStr, value: abi.RocStr) callconv(.c) abi.HostKv_putResult {
    const Result = abi.HostKv_putResult;
    const roc_host = g_roc_host.?;
    var owned_binding = binding;
    var owned_key = key;
    var owned_value = value;
    defer owned_binding.decref(roc_host);
    defer owned_key.decref(roc_host);
    defer owned_value.decref(roc_host);

    storePut("kv", owned_binding.asSlice(), owned_key.asSlice(), owned_value.asSlice()) catch {
        return payload.errStr(Result, "out of memory", roc_host);
    };
    return payload.okEmpty(Result);
}

/// Hosted function: Host.r2_get!
fn hostedR2Get(binding: abi.RocStr, key: abi.RocStr) callconv(.c) abi.HostR2_getResult {
    const Result = abi.HostR2_getResult;
    const roc_host = g_roc_host.?;
    var owned_binding = binding;
    var owned_key = key;
    defer owned_binding.decref(roc_host);
    defer owned_key.decref(roc_host);

    const value = storeGet("r2", owned_binding.asSlice(), owned_key.asSlice()) catch {
        return payload.errUnionStr(Result, abi.R2ErrOrR2NotFound, "r2err", .R2Err, "out of memory", roc_host);
    };
    if (value) |v| return payload.okBytes(Result, v, roc_host);
    return payload.errUnionEmpty(Result, abi.R2ErrOrR2NotFound, .R2NotFound);
}

/// Hosted function: Host.r2_put!
fn hostedR2Put(binding: abi.RocStr, key: abi.RocStr, body: payload.RocBytes) callconv(.c) abi.HostR2_putResult {
    const Result = abi.HostR2_putResult;
    const roc_host = g_roc_host.?;
    var owned_binding = binding;
    var owned_key = key;
    const owned_body = body;
    defer owned_binding.decref(roc_host);
    defer owned_key.decref(roc_host);
    defer owned_body.decref(roc_host);

    storePut("r2", owned_binding.asSlice(), owned_key.asSlice(), owned_body.items()) catch {
        return payload.errStr(Result, "out of memory", roc_host);
    };
    return payload.okEmpty(Result);
}

/// Hosted function: Host.r2_delete!
fn hostedR2Delete(binding: abi.RocStr, key: abi.RocStr) callconv(.c) abi.HostR2_deleteResult {
    const Result = abi.HostR2_deleteResult;
    const roc_host = g_roc_host.?;
    var owned_binding = binding;
    var owned_key = key;
    defer owned_binding.decref(roc_host);
    defer owned_key.decref(roc_host);

    storeDelete("r2", owned_binding.asSlice(), owned_key.asSlice()) catch {
        return payload.errStr(Result, "out of memory", roc_host);
    };
    return payload.okEmpty(Result);
}

const d1_unavailable = "D1 is not available in the native host — run this worker with wrangler";

/// Hosted function: Host.d1_query!
fn hostedD1Query(binding: abi.RocStr, sql: abi.RocStr, params: abi.RocStr) callconv(.c) abi.HostD1_queryResult {
    const roc_host = g_roc_host.?;
    var owned_binding = binding;
    var owned_sql = sql;
    var owned_params = params;
    defer owned_binding.decref(roc_host);
    defer owned_sql.decref(roc_host);
    defer owned_params.decref(roc_host);

    return payload.errStr(abi.HostD1_queryResult, d1_unavailable, roc_host);
}

/// Hosted function: Host.d1_execute!
fn hostedD1Execute(binding: abi.RocStr, sql: abi.RocStr, params: abi.RocStr) callconv(.c) abi.HostD1_executeResult {
    const roc_host = g_roc_host.?;
    var owned_binding = binding;
    var owned_sql = sql;
    var owned_params = params;
    defer owned_binding.decref(roc_host);
    defer owned_sql.decref(roc_host);
    defer owned_params.decref(roc_host);

    return payload.errStr(abi.HostD1_executeResult, d1_unavailable, roc_host);
}

const pg_unavailable = "Postgres is not available in the native host — run this worker with wrangler";

/// Hosted function: Host.pg_query!
fn hostedPgQuery(binding: abi.RocStr, sql: abi.RocStr, params: abi.RocStr) callconv(.c) abi.HostPg_queryResult {
    const roc_host = g_roc_host.?;
    var owned_binding = binding;
    var owned_sql = sql;
    var owned_params = params;
    defer owned_binding.decref(roc_host);
    defer owned_sql.decref(roc_host);
    defer owned_params.decref(roc_host);

    return payload.errStr(abi.HostPg_queryResult, pg_unavailable, roc_host);
}

/// Hosted function: Host.pg_execute!
fn hostedPgExecute(binding: abi.RocStr, sql: abi.RocStr, params: abi.RocStr) callconv(.c) abi.HostPg_executeResult {
    const roc_host = g_roc_host.?;
    var owned_binding = binding;
    var owned_sql = sql;
    var owned_params = params;
    defer owned_binding.decref(roc_host);
    defer owned_sql.decref(roc_host);
    defer owned_params.decref(roc_host);

    return payload.errStr(abi.HostPg_executeResult, pg_unavailable, roc_host);
}

/// Hosted function: Host.queue_send!
///
/// Writes to stderr rather than stdout, which carries the response body.
fn hostedQueueSend(binding: abi.RocStr, body: abi.RocStr) callconv(.c) abi.HostQueue_sendResult {
    const roc_host = g_roc_host.?;
    var owned_binding = binding;
    var owned_body = body;
    defer owned_binding.decref(roc_host);
    defer owned_body.decref(roc_host);

    const io = std.Io.Threaded.global_single_threaded.io();
    const stderr = std.Io.File.stderr();
    stderr.writeStreamingAll(io, "[queue ") catch {};
    stderr.writeStreamingAll(io, owned_binding.asSlice()) catch {};
    stderr.writeStreamingAll(io, "] ") catch {};
    stderr.writeStreamingAll(io, owned_body.asSlice()) catch {};
    stderr.writeStreamingAll(io, "\n") catch {};

    return payload.okEmpty(abi.HostQueue_sendResult);
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
        @export(&hostedEnvGet, .{ .name = "roc_env_get", .visibility = .hidden });
        @export(&hostedKvGet, .{ .name = "roc_kv_get", .visibility = .hidden });
        @export(&hostedKvPut, .{ .name = "roc_kv_put", .visibility = .hidden });
        @export(&hostedR2Get, .{ .name = "roc_r2_get", .visibility = .hidden });
        @export(&hostedR2Put, .{ .name = "roc_r2_put", .visibility = .hidden });
        @export(&hostedR2Delete, .{ .name = "roc_r2_delete", .visibility = .hidden });
        @export(&hostedD1Query, .{ .name = "roc_d1_query", .visibility = .hidden });
        @export(&hostedD1Execute, .{ .name = "roc_d1_execute", .visibility = .hidden });
        @export(&hostedPgQuery, .{ .name = "roc_pg_query", .visibility = .hidden });
        @export(&hostedPgExecute, .{ .name = "roc_pg_execute", .visibility = .hidden });
        @export(&hostedQueueSend, .{ .name = "roc_queue_send", .visibility = .hidden });

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
    store_allocator = host_env.gpa.allocator();

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
        .body = payload.RocBytes.fromSlice(body, &roc_host),
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
    stdout.writeStreamingAll(io, response.body.items()) catch {};

    // The host owns the returned Response.
    response.decref(&roc_host);

    // Must run before the leak check, or the store's own entries look like leaks.
    storeDeinit();

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
