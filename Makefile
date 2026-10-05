# ocoreai — Development Makefile
# Usage: make [target]
#
# Build:      build, release
# Test:       test, test-verbose, test-coverage
# Quality:    format, format-check, audit
# Dev:        clean, metallib, help
# CI:         ci-local (full local pipeline)

SHELL := /bin/bash

# ── Toolchain ─────────────────────────────────────────
# swift build/test needs the Metal framework; xcode-select may point at
# CommandLineTools which doesn't ship it. If the caller already pinned
# DEVELOPER_DIR we honour it (highest priority); otherwise, when the default
# toolchain is CommandLineTools, redirect to the known full Xcode.app.
XCODE_APP := /Applications/Xcode.app
ifdef DEVELOPER_DIR
# user-pinned: no override
else
  XSELECT := $(strip $(shell xcode-select -p 2>/dev/null))
  ifneq (,$(findstring CommandLineTools,$(XSELECT)))
    DEVELOPER_DIR := $(XCODE_APP)/Contents/Developer
    export DEVELOPER_DIR
  endif
endif

.PHONY: all build release app dmg test test-verbose test-coverage test-ci format format-check audit clean metallib help ci-local

all: build

## ── Build ──────────────────────────────────────────────────────────

build:
	@echo "🔨 Building debug..."
	swift build

release:
	@echo "🔨 Building release..."
	swift build -c release

## 开箱即用产物 (first-run ready)
app:
	bash scripts/build-app.sh

dmg:
	bash scripts/build-dmg.sh

## ── Test ───────────────────────────────────────────────────────────

# CLT route — the local gate on macOS < 27 while Xcode 27 is installed.
# Xcode 27 ships only SDK 27: its binaries weak-link CoreAI.framework, which
# is absent on macOS 26 → xctest dies in realizeAllClasses() BEFORE any test
# runs (--filter / #available cannot save it — both are post-realize).
# The CLT toolchain (SDK 26.5, canImport(CoreAI)=false) is the 26-native path:
# Testing 1902 + its lib_TestingInterop live under CommandLineTools, so the
# -F/-rpath must be injected HERE at the call site — Package.swift stays clean
# (hardcoded CLT paths there poisoned the Xcode route: cdba6a6).
# CLT cannot compile .metal, but MLX resolves prebuilt shaders at runtime
# (path ① <binary dir>/mlx.metallib) — staged below from an Xcode-built
# bundle → FULL suite on this host, no --skip (verified 10-05: 1988 tests).
CLT_DIR=/Library/Developer/CommandLineTools
CLT_F=$(CLT_DIR)/Library/Developer/Frameworks
CLT_L=$(CLT_DIR)/Library/Developer/usr/lib
test-clt:
	@echo "🧪 CLT-route test gate (macOS < 27 local; FULL suite, no skips)..."
	@DEVELOPER_DIR=$(CLT_DIR) swift build --build-tests --scratch-path .build-clt -Xswiftc -F$(CLT_F) -Xlinker -F$(CLT_F) >/dev/null
	@# Metal staging: CLT cannot compile .metal sources, but MLX resolves shaders
	@# at <binary dir>/mlx.metallib (path ①, build-app.sh:23). Stage the Xcode-
	@# built metallib next to the test binary → the wall that killed every local
	@# run before 10-05 is gone (verified: full run, 0 metallib errors, 1988 tests).
	@M=$$(ls -dt ~/Library/Developer/Xcode/DerivedData/ocoreai-*/Build/Products/*/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib 2>/dev/null | head -1); \
	P=/opt/homebrew/lib/python3.11/site-packages/mlx/lib/mlx.metallib; \
	for SRC in "$$M" "$$P"; do \
	  if [ -n "$$SRC" ] && [ -f "$$SRC" ]; then \
	    cp -f "$$SRC" .build-clt/arm64-apple-macosx/debug/mlx.metallib; \
	    cp -f "$$SRC" .build-clt/arm64-apple-macosx/debug/ocoreaiPackageTests.xctest/Contents/MacOS/mlx.metallib; \
	    echo "   metallib staged: $$SRC"; break; \
	  fi; \
	done; \
	[ -f .build-clt/arm64-apple-macosx/debug/ocoreaiPackageTests.xctest/Contents/MacOS/mlx.metallib ] \
	  || { echo "❌ no metallib source (need Xcode DerivedData product or pip install mlx)"; exit 1; }
	@DEVELOPER_DIR=/Library/Developer/CommandLineTools swift test \
	  --scratch-path .build-clt \
	  --no-parallel \
	  -Xswiftc -F$(CLT_F) \
	  -Xlinker -F$(CLT_F) \
	  -Xlinker -rpath -Xlinker $(CLT_F) \
	  -Xlinker -rpath -Xlinker $(CLT_L)

test:
	@echo "🧪 Running tests..."
	swift test

test-verbose:
	@echo "🧪 Running tests (verbose)..."
	swift test --enable-test-discovery -Xswiftc -Xfrontend -Xswiftc -enable-private-import

test-coverage:
	@echo "🧪 Running tests with coverage..."
	@rm -rf .build/coverage.dat
	swift test --enable-code-coverage
	@echo ""
	@echo "📊 Coverage report:"
	@swift test --show-codecov-path 2>/dev/null && \
		echo "→ Open the above path for detailed report" || \
		echo "→ Coverage data in .build/"

# Full test gate — CI-identical path (xcodebuild build-for-testing → xcrun xctest).
# NOTE (2026-10-05): on macOS < 27 hosts with Xcode 27 installed (SDK 27 only),
# the xcodebuild-built binary weak-links CoreAI.framework and xcrun xctest SEGVs
# in realizeAllClasses() before the first test (Error 139) — TEST BUILD SUCCEEDED
# is not test execution. Full test EXECUTION = CI until the host runs macOS 27
# (or an SDK-26 Xcode side-by-side). For the macOS-26-native partial gate: test-clt.
test-ci:
	@echo "🧪 Running the CI-identical full gate (xcodebuild → xctest)..."
	@export OCOREAI_BUILD=ci; \
	export SWIFTC_SCAN_FOR_DEPS=0; \
	xcodebuild build-for-testing \
	  -workspace ocoreai.xcworkspace \
	  -scheme ocoreaiTests \
	  -configuration Debug \
	  -destination 'platform=macOS,arch=arm64' \
	  -skipPackagePluginValidation \
	  -skipMacroValidation \
	  ONLY_ACTIVE_ARCH=YES; \
	XCB=$$(ls -dt ~/Library/Developer/Xcode/DerivedData/ocoreai-*/Build/Products/Debug/ocoreaiTests.xctest 2>/dev/null | head -1 || true); \
	[ -n "$$XCB" ] || { echo "❌ ocoreaiTests.xctest not found in DerivedData"; exit 1; }; \
	BIN="$$XCB/Contents/MacOS/ocoreaiTests"; \
	NEWEST=$$(ls -t Tests/ocoreaiTests/*.swift 2>/dev/null | head -1); \
	if [ -n "$$NEWEST" ] && [ "$$NEWEST" -nt "$$BIN" ]; then \
	  echo "⚠️  Test bundle binary is STALER than $$NEWEST — incremental relink bug, forcing rebuild"; \
	  rm -rf "$$XCB"; \
	  xcodebuild build-for-testing -workspace ocoreai.xcworkspace -scheme ocoreaiTests \
	    -configuration Debug -destination 'platform=macOS,arch=arm64' \
	    -skipPackagePluginValidation -skipMacroValidation ONLY_ACTIVE_ARCH=YES || exit 1; \
	fi; \
	echo "Running test bundle: $$XCB"; \
	xcrun xctest "$$XCB"

## ── Code Quality ───────────────────────────────────────────────────
# swift-format is the only style gate — aligned with upstream
# (mlx-swift-lm / coreai-models ship no swiftlint; .swift-format is
# the shared config surface).

format:
	@echo "✨ Formatting Swift files..."
	swift-format format --in-place --recursive --parallel --configuration .swift-format Sources/ Tests/
	@echo "Done. Reverted files by hand if you disagree: git diff / git checkout -- <path>"

format-check:
	@echo "🔍 Checking Swift format..."
	@swift-format format --in-place --recursive --parallel --configuration .swift-format Sources/ Tests/
	@CHANGED=$$(git diff --name-only -- Sources/ Tests/ | wc -l | tr -d ' '); \
	if [ "$$CHANGED" -eq 0 ]; then \
	  echo "✅ swift-format: zero files reformatted"; \
	else \
	  echo "❌ swift-format would reformat $$CHANGED file(s):"; \
	  git --no-pager diff --name-status -- Sources/ Tests/; \
	  echo; \
	  echo "Working tree KEEPS both your uncommitted changes and the reformat (CI-parity: no blind checkout)."; \
	  echo "Accept reformat:  make format   →  git add -A"; \
	  echo "Or inspect:       git diff -- Sources/ Tests/  (format lines vs. your feature lines)"; \
	  exit 1; \
	fi

audit:
	@echo "🔍 Running static audit..."
	bash scripts/audit.swift_patterns.sh

## ── Dev Tools ──────────────────────────────────────────────────────

clean:
	@echo "🧹 Cleaning build artifacts..."
	swift package clean
	@rm -rf .build
	@echo "✅ Clean complete"

metallib:
	@echo "🔧 Setting up MLX metallib..."
	bash scripts/setup-metallib.sh

## ── CI Pipeline (Local) ───────────────────────────────────────────

ci-local: clean format-check audit build test-ci
	@echo ""
	@echo "✅ Full CI pipeline passed locally"

## ── Help ───────────────────────────────────────────────────────────

help:
	@echo "ocoreai — Development commands"
	@echo ""
	@echo "Build:"
	@echo "  make build          Build debug target"
	@echo "  make release        Build release target"
	@echo ""
	@echo "Test:"
	@echo "  make test           Run test suite"
	@echo "  make test-verbose   Run tests with verbose output"
	@echo "  make test-coverage  Run tests with code coverage"
	@echo ""
	@echo "Quality:"
	@echo "  make format         Format all Swift files"
	@echo "  make format-check   Check format compliance (exit 1 if dirty)"
	@echo "  make audit          Run static audit (failure pattern check)"
	@echo ""
	@echo "Dev:"
	@echo "  make clean          Remove build artifacts"
	@echo "  make metallib       Setup MLX metallib for GPU acceleration"
	@echo "  make help           Show this help"
	@echo ""
	@echo "CI:"
	@echo "  make test-ci        CI 同款全量门 (xcodebuild build-for-testing → xcrun xctest; swift test 有 metallib 路径缺陷)"
	@echo "  make ci-local       Full local CI pipeline (clean → format → audit → build → test-ci)"
