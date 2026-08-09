[![Roc-Lang][roc_badge]][roc_link]

[roc_badge]: https://img.shields.io/endpoint?url=https%3A%2F%2Fpastebin.com%2Fraw%2FcFzuCCd7
[roc_link]: https://github.com/roc-lang/roc

# Roc platform for Cloudflare Workers

A [Roc platform](https://www.roc-lang.org/platforms) for [Cloudflare Workers](https://workers.cloudflare.com), with a [Zig](https://ziglang.org) host compiled to `wasm32` on top of [workers-zig](https://github.com/nilslice/workers-zig).

Forked from [roc-platform-template-zig](https://github.com/lukewilliamboswell/roc-platform-template-zig).

## Requirements

- [Zig](https://ziglang.org/download/) 0.16.0 or later
- [Roc](https://www.roc-lang.org/) — see `.roc-version` for the nightly this tracks
- Node.js, for `wrangler`

## Writing a worker

An app handles one request and returns one response:

```roc
app [main!] { pf: platform "../platform/main.roc" }

import pf.Request exposing [Request]
import pf.Response exposing [Response]

main! : Request => Response
main! = |request| {
    {
        status: 200,
        headers: [{ name: "content-type", value: "text/plain" }],
        body: "Hello from ${request.url}\n",
    }
}
```

`Request` carries `method`, `url`, `headers` and `body`; `Response` carries `status`, `headers` and `body`. A `Header` is `{ name, value }`.

Cloudflare lowercases incoming header names and joins repeated headers into one comma-separated value, so look them up in lower case. When a response sets no `content-type`, the embedder defaults it to `text/plain`.

`Stdout.line!` and `Stderr.line!` write to the Worker log, visible in `wrangler tail`.

### Workers KV

```roc
import pf.Kv

match Kv.get!("COUNTER", "hits") {
    Ok(value) => ...
    Err(KvNotFound) => ...
    Err(KvErr(message)) => ...
}
```

The first argument is the **binding name** from `kv_namespaces` in your wrangler config, not the namespace id. Getting it wrong surfaces as `KvErr` naming the binding.

KV is eventually consistent: a read straight after a write can still return the old value. Don't reach for it where you need read-after-write.

### R2, D1 and Queues

```roc
import pf.R2
import pf.D1
import pf.Queue

R2.get!("BUCKET", key)                       # Ok(body) | Err(R2NotFound) | Err(R2Err(msg))
R2.put!("BUCKET", key, body)
R2.delete!("BUCKET", key)

D1.query!("DB", "SELECT name FROM users WHERE age > ?", "[21]")   # Ok(rows_as_json)
D1.execute!("DB", "INSERT INTO users (name) VALUES (?)", "[\"alice\"]")  # Ok(rows_written)

Queue.send!("JOBS", body)
```

Each takes its binding name first, the same as `Kv`.

Some rough edges worth knowing:

- **R2 bodies are `Str`**, so only UTF-8 objects work. Binary objects need a `List(U8)` API that does not exist yet.
- **D1 has no row type.** Rows come back as a JSON array string and parameters go in as a JSON array string; use `"[]"` when there are none.
- **Queues are producer-only.** Consuming needs a `queue` handler alongside `fetch`, which the platform does not expose yet.

### Running bindings natively

None of these exist outside Workers, so the native host approximates them well enough to run examples under `zig build test`:

| Binding | Native behaviour |
|---------|------------------|
| KV, R2 | In-memory store scoped by binding name, for the lifetime of one process |
| D1 | Reports that it is unavailable, rather than pretending |
| Queues | Writes the message to stderr |

Durability, eventual consistency and real query behaviour have to be checked against the real thing.

## Running

```bash
npm install
npm run dev      # build the wasm and serve it with wrangler
npm run deploy   # build and publish
```

`npm run build` runs four steps:

1. `zig build wasm` compiles `src/host_wasm.zig` (plus workers-zig) to `platform/targets/wasm32/libhost.a`
2. `zig build worker-tools` installs workers-zig's `gen_entry` and copies its `shim.js` into `worker/`
3. `roc build --target=wasm32` links the host with the app into `worker/worker.wasm`
4. `gen_entry` reads that wasm and writes `worker/entry.js`

Step 3 is why workers-zig's own `addWorker()` is not used: it expects to produce the final wasm itself, and here Roc owns that link. `src/host_wasm.zig` therefore plays the role of the SDK's `src/entry.zig`, exporting `fetch` directly.

The examples also build as native executables, which is the fastest way to iterate without wrangler in the loop. There is no standalone wasm harness: outside the shim, the exported `fetch` has nothing to resolve its handles against. The native host synthesizes a request from the command line and prints the response body:

```bash
roc build examples/echo.roc --output=echo
./echo https://example.com/submit POST 'a body' accept:application/json
```

Arguments are `[url] [method] [body] [name:value ...]`. Response headers print as `name: value` lines followed by a blank line, then the body.

## Documentation

Generate docs locally:

```bash
zig build docs
```

## Testing

`zig build test` runs the examples against the local `platform/main.roc` as native executables, driving them through the command-line request interface described above.

[`scripts/test_spec.json`](scripts/test_spec.json) is the source of truth for example coverage. Every example has one entry and can define any number of named cases. A case can provide command-line arguments, environment variables, an expected exit code, and combined or stream-specific output assertions. The runner builds each example once and reuses that binary for all of its cases on Linux, macOS, and Windows.

```
$ zig build test
All test stages passed (check: 9, build: 9, run: 13)
```

Run the spec directly against another examples directory or only selected stages:

```bash
python3 scripts/test.py --examples-dir examples
python3 scripts/test.py --operation validate
python3 scripts/test.py --operation run
```

## Building

```bash
# Build for all supported targets (cross-compilation)
zig build -Doptimize=ReleaseSafe

# Build for native platform only
zig build native -Doptimize=ReleaseSafe
```

## Regenerating Glue

When the platform API changes (e.g. adding or modifying hosted functions in `platform/main.roc`), regenerate the Zig glue:

```bash
roc glue <path-to-roc>/src/glue/src/ZigGlue.roc ./src/ ./platform/main.roc
```

This updates `src/roc_platform_abi.zig` with the ABI types and dispatch table matching the platform's hosted functions.

Check the glue spec out at the same commit as the compiler in `.roc-version`, since the generated ABI tracks the compiler:

```bash
git clone --filter=blob:none --no-checkout https://github.com/roc-lang/roc /tmp/rocsrc
cd /tmp/rocsrc && git sparse-checkout set --cone src/glue && git checkout <commit-from-.roc-version>
```

### macOS: `roc glue` fails to link

On macOS a distributed Roc nightly cannot link the glue plugin dylib, and fails with:

```
ld64.lld: error: library not found for -lSystem
ld64.lld: error: undefined symbol: _memcpy
```

`roc build` is unaffected. The two code paths resolve the Darwin sysroot differently: `src/cli/linker.zig` calls `findDarwinSysroot()`, which finds the `darwin/` directory shipped next to the `roc` executable, while `src/llvm_compile/compile.zig` uses the compile-time `build_options.darwin_sysroot` — the path on the machine that built the binary, which on a nightly is the CI runner's checkout and does not exist locally.

Until that is fixed upstream, recreate the baked path locally:

```bash
sudo ./scripts/fix-macos-glue-sysroot.sh
```

Reverse it with `sudo rm -rf /Users/runner`.

## Bundling

```bash
./bundle.sh
```

This creates a `.tar.zst` bundle containing all `.roc` files and prebuilt host libraries.

## Supported Targets

| Target | Library |
|--------|---------|
| x64mac | `platform/targets/x64mac/libhost.a` |
| x64win | `platform/targets/x64win/host.lib` |
| x64musl | `platform/targets/x64musl/libhost.a` |
| x64v1musl | `platform/targets/x64v1musl/libhost.a` |
| arm64mac | `platform/targets/arm64mac/libhost.a` |
| arm64win | `platform/targets/arm64win/host.lib` |
| arm64musl | `platform/targets/arm64musl/libhost.a` |
| arm64v1musl | `platform/targets/arm64v1musl/libhost.a` |
| wasm32 | `platform/targets/wasm32/libhost.a` |

Linux musl targets include statically linked C runtime files (`crt1.o`, `libc.a`) for standalone executables. The `v1` targets use each architecture's baseline instruction set for CPUs without the features required by the default targets.

`wasm32` is the target Cloudflare Workers use, and is the only one built from `src/host_wasm.zig` rather than `src/host.zig`. Build it alone with `zig build wasm`. It targets `wasm32-wasi` rather than freestanding because that is what workers-zig expects; the shim implements `wasi_snapshot_preview1`. In practice the linked worker imports nothing from it — only the 14 `env` functions workers-zig uses.

The Worker needs the `nodejs_compat` compatibility flag, because `shim.js` imports `node:fs`, `node:path` and `node:stream`.

One consequence of the shim worth knowing: it instantiates the wasm module **once** and reuses that instance across requests, so Roc's allocator state persists between them. Roc is refcounted and frees as it goes, so this holds up — 1600 requests carrying 20KB bodies (32MB cumulative, well past the 16MB initial linear memory) all returned correctly with no degradation.
