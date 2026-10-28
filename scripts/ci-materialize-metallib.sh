#!/usr/bin/env bash
# ci-materialize-metallib.sh — produce MLX's shader payload on a clean runner and stage it where
# scripts/build-app.sh looks first.
#
# ### Why this is one script and not a step in a workflow
# SwiftPM does not compile `.metal`: the sources live in the Xcode target mlx-swift_Cmlx, so
# `swift build -c release` links 382/382 and emits no default.metallib. The 2026-09-27 release leg
# died exactly there ("default.metallib not found" from build-app.sh) after local builds passed on a
# stale DerivedData product a clean runner does not have. Three decisions are involved — produce it
# (xcodebuild), find it (scripts/resolve-metallib.sh, the one ladder: it floors the size and names
# the rung that won), stage it (build-app.sh's first candidate path) — and a workflow step that
# re-implements the middle one is how a release leg drifts from every gate on the same host.
#
# Both packaging lanes call this, so the command that runs on tag day is the command that ran green
# on main the day before: `.github/workflows/package.yml` (no publish, every packaging change +
# nightly) and the tag-gated `release` job in ci.yml.
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
echo "resolving packages (xcodebuild needs .build/checkouts populated)..."
swift package resolve

# The producer, verbatim the shape the 09-27 log proved on a runner (MetalLink default.metallib,
# 9 kernels). Trait-independent: pure Metal shaders, shared by every Swift target, so a
# default-trait product is the right payload for an appStore-trait artefact.
if ! xcodebuild build \
  -workspace ocoreai.xcworkspace \
  -scheme ocoreai \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  ONLY_ACTIVE_ARCH=YES > "$LOG" 2>&1; then
  RC=$?
  grep -E "error:" "$LOG" | sort -u | head -15 || true
  echo "❌ xcodebuild failed (exit $RC) — $LOG tail:" >&2
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
