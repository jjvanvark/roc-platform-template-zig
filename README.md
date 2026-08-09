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
main! = |request|
    Response.text(
        200,
        [{ name: "content-type", value: "text/plain" }],
        "Hello from ${request.url}\n",
    )
```

`Request` carries `method`, `url`, `headers` and `body`; `Response` carries `status`, `headers` and `body`. A `Header` is `{ name, value }`.

Cloudflare lowercases incoming header names and joins repeated headers into one comma-separated value, so look them up in lower case. When a response sets no `content-type`, the embedder defaults it to `text/plain`.

### Bodies are bytes

`body` is a `List(U8)` on both `Request` and `Response`, so a worker can handle
an image, a zip or a protobuf, not just UTF-8. Bytes travel unchanged from the
client through to the Roc app and back — nothing decodes them on the way.

Text is the common case, so it has helpers rather than manual encoding:

```roc
request.text()        # Try(Str, [BadUtf8(...)]) — decode the body as UTF-8
request.text_lossy()  # Str — same, with U+FFFD for malformed bytes

Response.text(200, [], "Hello\n")   # build a response from a Str
```

`text` returns a `Try` because a body that should be text but isn't is a client
error: answer 400 rather than crash. Use `text_lossy` where a mangled body beats
no body, such as logging. To pass bytes straight through, use `body` directly:

```roc
match R2.get!("BUCKET", key) {
    Ok(body) => { status: 200, headers: [], body }
    ...
}
```

`Stdout.line!` and `Stderr.line!` write to the Worker log, visible in `wrangler tail`.

### Environment variables and secrets

```roc
import pf.Env

Env.get!("GREETING")                      # Ok(value) | Err(EnvNotFound) | Err(EnvErr(msg))
Env.get_or!("GREETING", "a default")      # Str
```

Variables come from `vars` in your `wrangler.jsonc` (see
`wrangler.example.jsonc`); secrets are set with `wrangler secret put NAME` and
read exactly the same way — Roc cannot tell them apart, which is the point.

Asking for a binding that exists but is not text, such as a KV namespace, gives
`EnvNotFound` rather than an error. Use `Kv`, `R2`, `D1` or `Queue` for those.

Natively these read the real process environment, so `GREETING=hi ./app` works
the same way. Windows is the exception: the native host reads libc's `environ`,
which msvcrt does not provide under that name, so it reports `EnvErr` there.

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

### R2, D1, Postgres and Queues

```roc
import pf.R2
import pf.D1
import pf.Pg
import pf.Queue

R2.get!("BUCKET", key)                       # Ok(bytes) | Err(R2NotFound) | Err(R2Err(msg))
R2.put!("BUCKET", key, bytes)
R2.get_text!("BUCKET", key)                  # same, decoded as UTF-8
R2.put_text!("BUCKET", key, "some text")
R2.delete!("BUCKET", key)

D1.query!("DB", "SELECT name FROM users WHERE age > ?", "[21]")   # Ok(rows_as_json)
D1.execute!("DB", "INSERT INTO users (name) VALUES (?)", "[\"alice\"]")  # Ok(rows_written)

Pg.query!("PG", "SELECT name FROM users WHERE age > $1::int", "[\"21\"]")  # Ok(rows_as_json)
Pg.execute!("PG", "INSERT INTO users (name) VALUES ($1)", "[\"alice\"]")   # Ok(rows_written)

Queue.send!("JOBS", body)
```

Each takes its binding name first, the same as `Kv`.

Some rough edges worth knowing:

- **R2 objects are bytes**, so images and archives round-trip intact. `get_text!` and `put_text!` cover UTF-8; an object that is not valid UTF-8 comes back from `get_text!` as `R2Err`, keeping its error union the same as `get!`.
- **KV values are still `Str`**, so binary values need R2 for now.
- **D1 has no row type.** Rows come back as a JSON array string and parameters go in as a JSON array string; use `"[]"` when there are none.
- **Pg goes through Hyperdrive.** The binding name is a `hyperdrive` entry in the wrangler config; locally its `localConnectionString` points at any Postgres you run yourself. Rows and parameters are JSON array strings like D1, but placeholders are `$1, $2, ...` and every parameter travels as a string — cast in the SQL (`$1::uuid`, `$2::int`) where another type is needed. The queries run in the shim with [postgres.js](https://github.com/porsager/postgres), so the consuming project needs `postgres` in its `package.json`.
- **Queues are producer-only.** Consuming needs a `queue` handler alongside `fetch`, which the platform does not expose yet.

### Running bindings natively

None of these exist outside Workers, so the native host approximates them well enough to run examples under `zig build test`:

| Binding | Native behaviour |
|---------|------------------|
| Env vars and secrets | The real process environment (not on Windows) |
| KV, R2 | In-memory store scoped by binding name, for the lifetime of one process |
| D1 | Reports that it is unavailable, rather than pretending |
| Pg | Reports that it is unavailable, rather than pretending |
| Queues | Writes the message to stderr |

Durability, eventual consistency and real query behaviour have to be checked against the real thing.

## Running

```bash
npm install
npm run dev      # build the wasm and serve it with wrangler
npm run deploy   # build and publish
```

### Wrangler config

There are two configs in this repo:

- **`wrangler.jsonc`** configures this repo's own demo Worker (`worker/app.roc`,
  a KV hit counter). It declares only the one binding that demo uses.
- **`wrangler.example.jsonc`** is the reference for your own Worker: every
  binding the platform supports, commented out, with the command that creates
  each resource. Copy it to `wrangler.jsonc` in your project and delete what you
  do not need.

Neither ships with the platform — `bundle.sh` publishes only `platform/*.roc`
and the prebuilt host libraries, so an app built on the platform brings its own.

Two settings are required whatever your Worker does:

- `compatibility_flags: ["nodejs_compat"]`, because `shim.js` imports
  `node:fs`, `node:path` and `node:stream`
- the `rules` `CompiledWasm` block, which is what loads `worker.wasm` as a
  module for the shim to instantiate

### Bindings and deploying

`wrangler dev` **simulates** every binding and accepts any id, so a config that
works locally can still fail on deploy:

```
KV namespace 'roc_cloudflare_counter' is not valid. [code: 10042]
```

Before deploying, each binding in your `wrangler.jsonc` has to name a resource
that exists in your account. `binding` is the only field you choose freely — it
is the string the Roc app passes, e.g. `Kv.get!("COUNTER", "hits")`.

| Binding | Create it with | Goes in |
|---------|----------------|---------|
| KV | `wrangler kv namespace create COUNTER` | `id` — a 32-char hex id, not a name |
| R2 | `wrangler r2 bucket create <name>` | `bucket_name` — no id involved |
| D1 | `wrangler d1 create <name>` | `database_id` (UUID) and matching `database_name` |
| Pg (Hyperdrive) | `wrangler hyperdrive create <name> --connection-string=...` | `id`; add `localConnectionString` for local dev |
| Queues | `wrangler queues create <name>` | `queue` — the queue name |

Each `create` command prints the snippet to paste back. Declare only the
bindings you actually use: an unused binding still has to resolve on deploy, so
a stray block is one more resource that has to exist. `vars` are the exception —
they are inline text and need nothing in the account. R2 and Queues need a paid
Workers plan; KV and D1 work on the free tier.

`npm run build` runs four steps:

1. `zig build wasm` compiles `src/host_wasm.zig` (plus workers-zig) to `platform/targets/wasm32/libhost.a`
2. `zig build worker-tools` installs workers-zig's `gen_entry`
3. `roc build --target=wasm32` links the host with the app into `worker/worker.wasm`
4. `gen_entry` reads that wasm and writes `worker/entry.js`

`worker/shim.js` is a platform-owned fork of workers-zig's shim: it carries the "Postgres over Hyperdrive" imports that back `Host.pg_query!`/`Host.pg_execute!`, so it is no longer copied from the dependency (the old `worker-tools` copy step was removed). Upgrading workers-zig means re-merging its shim changes into `worker/shim.js` by hand — the added sections are marked.

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
All test stages passed (check: 10, build: 10, run: 15)
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
