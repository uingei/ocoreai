#!/bin/bash
# Build mlx.metallib for SwiftPM (workaround for upstream issue #430)
# Run after `swift build` or as part of CI
# Usage: ./scripts/build-metallib.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MLX_ROOT="$PROJECT_DIR/.build/checkouts/mlx-swift/Source/Cmlx/mlx"
BUILD_DIR="$PROJECT_DIR/.build/arm64-apple-macosx/debug"
METAL_DIR="$MLX_ROOT/mlx/backend/metal/kernels"
OUTPUT="$BUILD_DIR/mlx.metallib"

if [ -f "$OUTPUT" ]; then
  echo "mlx.metallib already exists — skipping"
  exit 0
fi

if [ ! -d "$METAL_DIR" ]; then
  echo "ERROR: MLX metal kernels not found at $METAL_DIR. Run `swift package resolve` first."
  exit 1
fi

mkdir -p "$BUILD_DIR"
echo "Building mlx.metallib..."
TEMPDIR=$(mktemp -d)
trap 'rm -rf "$TEMPDIR"' EXIT

failed=0
total=0
for f in "$METAL_DIR"/*.metal; do
  bn=$(basename "$f" .metal)
  # Skip NAX tensor core kernels — requires Metal 4.0+ (not yet available on macOS < 26)
  case "$bn" in
    fp_quantized_nax|quantized_nax)
      echo "  skip: $bn (requires Metal 4.0 NAX)"
      continue
      ;;
  esac
  total=$((total+1))
  if ! xcrun -sdk macosx metal \
    -x metal -Wall -fno-fast-math \
    -Wno-c++17-extensions -Wno-c++20-extensions \
    -mmacosx-version-min=15.0 \
    -c "$f" -I "$MLX_ROOT" -o "$TEMPDIR/$bn.air" 2>/dev/null; then
    echo "  FAIL: $bn"
    failed=$((failed+1))
  fi
done

air_count=$(ls "$TEMPDIR"/*.air 2>/dev/null | wc -l | tr -d ' ')
if [ "$air_count" -lt 20 ]; then
  echo "ERROR: only $air_count air files compiled (need >= 20). $failed failed out of $total."
  exit 1
fi

xcrun -sdk macosx metallib "$TEMPDIR"/*.air -o "$OUTPUT"
echo "OK: mlx.metallib ($air_count kernels, $(du -h "$OUTPUT" | awk '{print $1}')) at $OUTPUT"