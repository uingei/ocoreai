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
# stderr: every rung asked, with what its scan saw (`rung: swiftpm-product · 4 716 496 bytes ·
# scanned 5 payload file(s)`), so a miss and an empty tree are different sentences. exit 1 + remedy
# when nothing is usable.
#
# Rungs, in provenance order: the explicit override, then the scratch's own SwiftPM product
# (compiled against the pinned mlx), then an Xcode product for this project, then a pip wheel
# (a different release entirely — last resort, and said out loud when it wins).
#
# Rung 1 is where a route that compiles `.metal` itself puts the payload — upstream's route does
# (mlx-swift-lm .github/workflows/pull_request.yml:216-237 asserts `Status: installed` and downloads the
# component otherwise), and this host's SwiftPM 6.4 does too (38 `.air` intermediates, 4 716 496 bytes).
# A macos-26 runner has NOT done it since 10-31 even with a compiler it can spawn, so the packaging lanes
# produce and stage the payload explicitly (scripts/ci-materialize-metallib.sh) and rung 1 then hits on the
# staged file — which is why the rung is a path contract, not a promise about who compiled the bytes.
# The freshest bundle wins, because a scratch tree keeps stale layouts from
# earlier toolchains, and the path printed is absolute: the runner's cwd is not the repo root.
#
# Each tree is SEARCHED for the bundle by name, not globbed at a remembered depth (11-06). This is
# not hypothetical here: five payloads sit under this repo's own `.build` across three products
# layouts — `out/Products/Release/`, inside the built `.xctest`'s Resources, and a doubled
# `out/out/Products/Release/` an older SwiftPM left behind. A glob that misses the newest one does
# not fail, it quietly returns an older payload or none, and the caller cannot tell the two apart.
# The packaging lane has been red since 10-31 with the payload among its unpublished premises (the leg never
# said which rung it got); a name-shaped search retires one of the two live hypotheses outright and
# the scanned count retires the other's ambiguity. The walk costs ~1 s over a 9.7 GB `.build` and
# ~1.3 s on a miss with DerivedData bounded to this project's trees (measured 11-06), once per gate.
set -uo pipefail

SCRATCH="${1:-.build}"
MIN_BYTES=4096

say() { printf '%s\n' "$*" >&2; }

usable() {
  [ -n "${1:-}" ] && [ -f "$1" ] && [ "$(wc -c < "$1" | tr -d ' ')" -ge "$MIN_BYTES" ]
}

PAYLOAD_PATH='*/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib'
SCAN_DEPTH=12

# search_for <dir> — every payload-shaped file under <dir>, newest first. Matched on the path
# suffix, never on a remembered depth: `-name` ignores slashes, so this is `-path`, and `-maxdepth`
# only bounds the walk.
search_for() {
  [ -d "$1" ] || return 0
  find "$1" -maxdepth "$SCAN_DEPTH" -type f -path "$PAYLOAD_PATH" 2>/dev/null \
    | head -40 | tr '\n' '\0' | xargs -0 ls -t 2>/dev/null
}

# Canonical path: a scratch tree's `debug` symlink and its products dir are the same file, and a gate
# log that names two spellings for one payload is read as two payloads.
canonical() {
  [ -n "$1" ] || return 0
  printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"
}

if usable "${OCOREAI_METALLIB:-}"; then
  say "rung: environment (\$OCOREAI_METALLIB) · $(wc -c < "$OCOREAI_METALLIB" | tr -d ' ') bytes"
  printf '%s\n' "$OCOREAI_METALLIB"
  exit 0
fi

# search_rung <label> <dir>… — one rung of the ladder: search each named tree, newest payload wins.
# The scanned count is the floor AGENTS.md § Testing Quality asks a scan to print, and it separates
# the two answers a reader acts on: `scanned 0` under a scratch that was just built means the route
# compiled no `.metal` at all, while `scanned 4` means a payload exists and the ladder picked the
# freshest of them. Different remedy, and the packaging leg had no way to tell them apart.
search_rung() {
  local label="$1"; shift
  local dir found scanned hit
  hit=""
  scanned=0
  for dir in "$@"; do
    found="$(search_for "$dir")"
    [ -n "$found" ] || continue
    scanned=$(( scanned + $(printf '%s\n' "$found" | grep -c .) ))
    [ -n "$hit" ] || hit="$(canonical "$(printf '%s\n' "$found" | head -1)")"
  done
  if usable "$hit"; then
    say "rung: $label · $(wc -c < "$hit" | tr -d ' ') bytes · scanned $scanned payload file(s)"
    printf '%s\n' "$hit"
    return 0
  fi
  say "rung: $label · nothing usable (scanned $scanned)"
  return 1
}

if search_rung swiftpm-product "$SCRATCH"; then exit 0; fi

# Bounded to this project's own trees on purpose: DerivedData here is 7.8 GB and most of it is other
# projects' module caches, which a whole-tree walk would read for nothing.
DERIVED=( $(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/ocoreai-* 2>/dev/null || true) )
if [ ${#DERIVED[@]} -gt 0 ] && search_rung xcode-derived-data "${DERIVED[@]}"; then exit 0; fi

WHEEL="/opt/homebrew/lib/python3.11/site-packages/mlx/lib/mlx.metallib"
if usable "$WHEEL"; then
  say "⚠️  rung: pip-mlx-wheel — a different mlx release than the pin; read a missing-kernel"
  say "    failure as a payload mismatch before reading it as a code regression."
  printf '%s\n' "$WHEEL"
  exit 0
fi

say "❌ no usable MLX shader payload (looked in $SCRATCH, Xcode DerivedData, the pip wheel)."
say "   A test process without one dies at the first Metal allocation:"
say "   'Failed to load the default metallib' (Cmlx mlx-c/memory.cpp), and the run never reports."
say "   Remedy, in order:"
say "     1. xcodebuild -showComponent MetalToolchain   # Status: installed → build again, .metal compiles"
say "     2. xcodebuild -downloadComponent MetalToolchain   # the upstream CI remedy"
say "     3. export OCOREAI_METALLIB=/path/to/default.metallib   # name a payload you already have"
exit 1
