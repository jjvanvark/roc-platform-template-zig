[![Roc-Lang][roc_badge]][roc_link]

[roc_badge]: https://img.shields.io/endpoint?url=https%3A%2F%2Fpastebin.com%2Fraw%2FcFzuCCd7
[roc_link]: https://github.com/roc-lang/roc

# Roc platform template for Zig

A template for building [Roc platforms](https://www.roc-lang.org/platforms) using [Zig](https://ziglang.org).

## Requirements

- [Zig](https://ziglang.org/download/) 0.16.0 or later
- [Roc](https://www.roc-lang.org/) (for bundling)

## Examples

Use the current release bundle as the platform dependency:

```roc
app [main!] { pf: platform "https://github.com/lukewilliamboswell/roc-platform-template-zig/releases/download/1.0.0/AnZoxzoGPtSGQ15EQh6pBeeaHJ7aizP9MQhK81dES3Uq.tar.zst" }
```

Run examples with interpreter: `roc examples/<name>.roc`

Build standalone executable: `roc build examples/<name>.roc`

## Documentation

Platform API docs are published at <https://lukewilliamboswell.github.io/roc-platform-template-zig/>.

Generate docs locally:

```bash
zig build docs
```

## Testing

The checked-in examples use the latest release bundle so they can be copied directly. `zig build test` rewrites temporary copies to use the local `platform/main.roc` before running them.

[`scripts/test_spec.json`](scripts/test_spec.json) is the source of truth for example coverage. Every example has one entry and can define any number of named cases. A case can provide command-line arguments, stdin, environment variables, an expected exit code, and combined or stream-specific output assertions. The runner builds each example once and reuses that binary for all of its cases on Linux, macOS, and Windows.

```
$ zig build test
All test stages passed (check: 12, test: 2, build: 12, run: 17)
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

Linux musl targets include statically linked C runtime files (`crt1.o`, `libc.a`) for standalone executables. The `v1` targets use each architecture's baseline instruction set for CPUs without the features required by the default targets.
