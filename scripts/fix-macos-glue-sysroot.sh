#!/usr/bin/env bash
#
# Work around a Roc bug that makes `roc glue` fail to link on macOS.
#
# `src/cli/linker.zig` resolves the Darwin sysroot at runtime via
# findDarwinSysroot(), which looks for a `darwin/` directory next to the roc
# executable. That is why `roc build` works from a distributed nightly.
#
# `src/llvm_compile/compile.zig` builds the glue plugin dylib and instead uses
# the *compile-time* `build_options.darwin_sysroot`, which is baked into the
# binary as the path on the machine that built it. On a nightly that is the CI
# runner's checkout, which does not exist locally, so `-lSystem` cannot be
# resolved and every `roc glue` invocation dies with:
#
#     ld64.lld: error: library not found for -lSystem
#     ld64.lld: error: undefined symbol: _memcpy
#
# Until that is fixed upstream, recreate the baked path locally and drop the
# nightly's own bundled libSystem.tbd into it.
#
# Reverse with:  sudo rm -rf /Users/runner
#
# Usage: sudo ./scripts/fix-macos-glue-sysroot.sh [path-to-roc]

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This workaround only applies to macOS." >&2
  exit 1
fi

if [[ "$(id -u)" != "0" ]]; then
  echo "Re-run with sudo: sudo $0 $*" >&2
  exit 1
fi

roc_bin="${1:-$(command -v roc || true)}"
if [[ -z "$roc_bin" || ! -x "$roc_bin" ]]; then
  echo "Could not find the roc executable. Pass it explicitly: sudo $0 /path/to/roc" >&2
  exit 1
fi

roc_dir="$(cd "$(dirname "$(readlink -f "$roc_bin" 2>/dev/null || echo "$roc_bin")")" && pwd)"
tbd="$roc_dir/darwin/usr/lib/libSystem.tbd"
if [[ ! -f "$tbd" ]]; then
  echo "No bundled libSystem.tbd next to roc (looked for $tbd)." >&2
  exit 1
fi

# Read the sysroot path baked into this specific binary rather than hardcoding
# it, so this keeps working when the nightly's build path changes.
baked="$(strings -a "$roc_bin" | grep -E 'src/cli/darwin$' | sort -u | head -n 1 || true)"
if [[ -z "$baked" ]]; then
  echo "Could not find a baked darwin_sysroot path in $roc_bin." >&2
  exit 1
fi

echo "roc binary:     $roc_bin"
echo "baked sysroot:  $baked"
echo "source tbd:     $tbd"

mkdir -p "$baked/usr/lib"
cp "$tbd" "$baked/usr/lib/libSystem.tbd"

echo "Done. Verify with: roc glue <roc-src>/src/glue/src/ZigGlue.roc ./src/ ./platform/main.roc"
