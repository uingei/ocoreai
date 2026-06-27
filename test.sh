#!/bin/bash
# Run swift test with CLT Testing framework bootstrap.
#
# CLT Swift toolchains do NOT include Testing.framework in the linker search
# path. This script:
#   1. Builds the test bundle via `swift build`
#   2. Injects @rpath entries so the test runner can find Testing.framework
#      and lib_TestingInterop.dylib at runtime
#   3. Launches `swift test --skip-build` to run tests

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DEBUG="$PROJ_DIR/.build/arm64-apple-macosx/debug"
TEST_BIN="$BUILD_DEBUG/ocoreaiPackageTests.xctest/Contents/MacOS/ocoreaiPackageTests"
RPATH_FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
RPATH_LI="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

cd "$PROJ_DIR"

# Step 1: Build everything including test targets
swift build --build-tests 2>&1

# Step 2: Inject rpaths if test binary exists
if [ -f "$TEST_BIN" ]; then
    # Only add rpaths if not already present
    otool -l "$TEST_BIN" | grep -q "$RPATH_FW" || \
        install_name_tool -add_rpath "$RPATH_FW" "$TEST_BIN"
    otool -l "$TEST_BIN" | grep -q "$RPATH_LI" || \
        install_name_tool -add_rpath "$RPATH_LI" "$TEST_BIN"
fi

# Step 3: Run tests (skip build, just execute)
swift test --enable-swift-testing --skip-build "$@"
