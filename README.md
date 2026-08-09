[![Roc-Lang][roc_badge]][roc_link]

[roc_badge]: https://img.shields.io/endpoint?url=https%3A%2F%2Fpastebin.com%2Fraw%2FcFzuCCd7
[roc_link]: https://github.com/roc-lang/roc

# Roc platform for Cloudflare Workers

A [Roc platform](https://www.roc-lang.org/platforms) for [Cloudflare Workers](https://workers.cloudflare.com), with a [Zig](https://ziglang.org) host compiled to `wasm32`.

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
    { status: 200, body: "Hello from ${request.url}\n" }
}
```

`Request` carries `method`, `url` and `body`; `Response` carries `status` and `body`. Headers are not modelled yet.

`Stdout.line!` and `Stderr.line!` write to the Worker log, visible in `wrangler tail`.

## Running

```bash
npm install
npm run dev      # build the wasm and serve it with wrangler
npm run deploy   # build and publish
```

The examples also build as native executables, which is the fastest way to iterate without wrangler in the loop. The native host synthesizes a request from the command line and prints the response body:

```bash
roc build examples/echo.roc --output=echo
./echo https://example.com/submit POST 'a body'
```

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
All test stages passed (check: 4, build: 4, run: 6)
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

`wasm32` is the target Cloudflare Workers use, and is the only one built from `src/host_wasm.zig` rather than `src/host.zig`. Build it alone with `zig build wasm`.
