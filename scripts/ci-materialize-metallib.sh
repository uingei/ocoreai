#!/usr/bin/env bash
# ci-materialize-metallib.sh — produce MLX's shader payload on a clean runner and stage it where
# scripts/build-app.sh looks first.
#
# ### Why this is one script and not a step in a workflow
# The premise that made this script: on 2026-09-27 a clean runner had no `metal` compiler, so
# `swift build -c release` linked 382/382 and emitted no default.metallib, and the release leg died on
# build-app.sh's "default.metallib not found" after local builds passed on a stale DerivedData product.
# What that log actually showed was a missing compiler, not a SwiftPM limit: measured 10-29 on a macos-26
# runner holding the MetalToolchain component, `swift build -c release --traits appStore` put a 2 389 928 B
# default.metallib at the SwiftPM product path (`rung: swiftpm-product`) with no xcodebuild in the job.
# That measurement is why this file was deleted on 10-29, and it no longer reproduces: package.yml's run 23
# had no `metal` reachable by name, and run 24 — after the delivery route began exporting the PATH rung —
# reported `metal=ok`, `metal_on_path=yes` and a compile-probed kernel, built green, and emitted no payload
# anywhere in the workspace (`scanned 0`, an empty workspace-wide find); the appStore leg on the same image
# prints the same `scanned 0` after its own green build. So the shipping artefact's shader bytes come from
# a producer this repo runs, and the route's SwiftPM metal support is a cost question the appStore leg keeps
# printing as a notice — the day it prints a payload, this script can leave again with evidence.
# Three decisions are involved — produce it
# (xcodebuild), find it (scripts/resolve-metallib.sh, the one ladder: it floors the size and names
# the rung that won), stage it (build-app.sh's first candidate path) — and a workflow step that
# re-implements the middle one is how a release leg drifts from every gate on the same host.
#
# Both packaging lanes call this: the tag-gated `release` job in ci.yml and its rehearsal
# (`.github/workflows/package.yml`, no publish, every packaging change + nightly), which is where a
# producer that stops working reaches main — tag day must never be the first day it runs.
#
# Usage: ci-materialize-metallib.sh [scratch-dir]     (default: .build)
# stdout: the staged path, nothing else. stderr: progress. exit 1 names the remedy.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SCRATCH="${1:-.build}"
BUNDLE="mlx-swift_Cmlx"
DEST="$SCRATCH/out/Products/Release/$BUNDLE.bundle/Contents/Resources/default.metallib"
LOG="$(mktemp -t ocoreai-metallib-xcodebuild-XXXXXX).log"

export SWIFTC_SCAN_FOR_DEPS=0
echo "resolving packages (xcodebuild needs .build/checkouts populated)..." >&2
swift package resolve

# The producer, verbatim the shape the 09-27 log proved on a runner (MetalLink default.metallib,
# 9 kernels). Trait-independent: pure Metal shaders, shared by every Swift target, so a
# default-trait product is the right payload for an appStore-trait artefact.
#
# `|| RC=$?`, not `if ! …; then RC=$?`: the `!` leaves `$?` at 0 inside the branch, so the shape this
# script was restored in printed "xcodebuild failed (exit 0)" and then exited 0 itself — measured
# 11-06 on this host, where the Xcode route's stub refuses and the producer correctly reds. A
# producer whose failure exits 0 is a gate that cannot go red: the caller would stage nothing and
# ship nothing, and only build-app.sh 3b would notice, naming the wrong subject.
# Diagnostics go to stderr, because stdout is the staged path and nothing else.
RC=0
xcodebuild build \
  -workspace ocoreai.xcworkspace \
  -scheme ocoreai \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  ONLY_ACTIVE_ARCH=YES > "$LOG" 2>&1 || RC=$?
if [ "$RC" -ne 0 ]; then
  grep -E "error:" "$LOG" | sort -u | head -15 >&2 || true
  echo "❌ xcodebuild failed (exit $RC) — $LOG tail:" >&2
  # The premise this step buys one workflow step earlier, named where it broke: the component is
  # per-developer-dir, and `cannot execute tool 'metal'` means the route xcodebuild chose has no
  # Metal Toolchain installed — a different remedy from a compiler that exists and fails.
  bash scripts/toolchain-contract.sh report 2>/dev/null | grep -E '^metal|^developer_dir' >&2 || true
  tail -25 "$LOG" >&2
  exit "$RC"
fi

# One ladder for where the payload ended up: env override → this scratch's SwiftPM product →
# Xcode DerivedData → pip wheel, with a 4 KiB floor and the winning rung named on stderr.
METAL="$(bash scripts/resolve-metallib.sh "$SCRATCH")"

if [ "$METAL" = "$DEST" ] || { [ -e "$DEST" ] && [ "$METAL" -ef "$DEST" ]; }; then
  echo "already staged by the build: $DEST ($(wc -c < "$DEST" | tr -d ' ') bytes)"
  printf '%s\n' "$DEST"
  exit 0
fi

mkdir -p "$(dirname "$DEST")"
cp "$METAL" "$DEST"
echo "staged $DEST ($(wc -c < "$DEST" | tr -d ' ') bytes) from $METAL"
printf '%s\n' "$DEST"
