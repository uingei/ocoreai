#!/usr/bin/env bash
# resolve-metallib.sh — one ladder for "where is MLX's shader payload", shared by every gate.
#
# A test process cannot let MLX find this file itself: MLX's search is path-shaped and reaches
# neither a signed .xctest bundle's MacOS dir nor a SwiftPM 6.4 products dir (Engine/AGENTS.md
# § Metal; MetalShaderLibrary.swift's candidate order is pinned by MetalShaderLibraryTests).
# So the gate resolves the path and exports $OCOREAI_METALLIB. Duplicating that ladder per
# target is how one copy drifts, so the ladder lives here and the targets only stage.
#
# Usage: resolve-metallib.sh [scratch-dir]     (default: .build)
# stdout: the payload path, nothing else — command-substitutable.
# stderr: which rung won, and the size. exit 1 + remedy when nothing is usable.
#
# Rungs, in provenance order: the explicit override, then the scratch's own SwiftPM product
# (compiled against the pinned mlx), then an Xcode product for this project, then a pip wheel
# (a different release entirely — last resort, and said out loud when it wins).
#
# Rung 1 is the upstream approach, not a local invention: SwiftPM compiles .metal itself once the
# Metal Toolchain component is installed and stages no payload — mlx-swift-lm
# .github/workflows/pull_request.yml:216-237 asserts `Status: installed` and downloads the
# component otherwise. The freshest bundle wins, because a scratch tree keeps stale layouts from
# earlier toolchains, and the path printed is absolute: the runner's cwd is not the repo root.
set -uo pipefail

SCRATCH="${1:-.build}"
MIN_BYTES=4096

say() { printf '%s\n' "$*" >&2; }

usable() {
  [ -n "${1:-}" ] && [ -f "$1" ] && [ "$(wc -c < "$1" | tr -d ' ')" -ge "$MIN_BYTES" ]
}

freshest() {
  # Newest first: a scratch tree keeps stale layouts from earlier toolchains.
  local hit
  hit=$(ls -t $@ 2>/dev/null | head -1)
  # Print a canonical path: a scratch tree's `debug` symlink and its products dir are the same
  # file, and a gate log that names two spellings for one payload is read as two payloads.
  if [ -n "$hit" ]; then
    printf '%s/%s\n' "$(cd "$(dirname "$hit")" && pwd -P)" "$(basename "$hit")"
  fi
}

if usable "${OCOREAI_METALLIB:-}"; then
  say "rung: environment (\$OCOREAI_METALLIB) · $(wc -c < "$OCOREAI_METALLIB" | tr -d ' ') bytes"
  printf '%s\n' "$OCOREAI_METALLIB"
  exit 0
fi

CANDIDATES=()
CANDIDATES+=("$(freshest "$SCRATCH"/out/Products/*/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib \
                         "$SCRATCH"/*/Products/*/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib \
                         "$SCRATCH"/*/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib)")
CANDIDATES+=("$(freshest "$HOME"/Library/Developer/Xcode/DerivedData/ocoreai-*/Build/Products/*/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib)")
CANDIDATES+=("/opt/homebrew/lib/python3.11/site-packages/mlx/lib/mlx.metallib")
RUNGS=("swiftpm-product" "xcode-derived-data" "pip-mlx-wheel")

for i in "${!CANDIDATES[@]}"; do
  if usable "${CANDIDATES[$i]}"; then
    if [ "${RUNGS[$i]}" = "pip-mlx-wheel" ]; then
      say "⚠️  rung: ${RUNGS[$i]} — a different mlx release than the pin; read a missing-kernel"
      say "    failure as a payload mismatch before reading it as a code regression."
    else
      say "rung: ${RUNGS[$i]} · $(wc -c < "${CANDIDATES[$i]}" | tr -d ' ') bytes"
    fi
    printf '%s\n' "${CANDIDATES[$i]}"
    exit 0
  fi
done

say "❌ no usable MLX shader payload (looked in $SCRATCH, Xcode DerivedData, the pip wheel)."
say "   A test process without one dies at the first Metal allocation:"
say "   'Failed to load the default metallib' (Cmlx mlx-c/memory.cpp), and the run never reports."
say "   Remedy, in order:"
say "     1. xcodebuild -showComponent MetalToolchain   # Status: installed → build again, .metal compiles"
say "     2. xcodebuild -downloadComponent MetalToolchain   # the upstream CI remedy"
say "     3. export OCOREAI_METALLIB=/path/to/default.metallib   # name a payload you already have"
exit 1
