# ocoreai — Development Makefile
# Usage: make [target]
#
# Build:      build, release
# Test:       test, test-verbose, test-coverage
# Quality:    format, format-check, audit
# Dev:        clean, metallib, help
# CI:         ci-local (full local pipeline)

SHELL := /bin/bash
.PHONY: all build release test test-verbose test-coverage format format-check audit clean metallib help ci-local

all: build

## ── Build ──────────────────────────────────────────────────────────

build:
	@echo "🔨 Building debug..."
	swift build

release:
	@echo "🔨 Building release..."
	swift build -c release

## ── Test ───────────────────────────────────────────────────────────

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
	  git diff --name-only -- Sources/ Tests/; \
	  echo "Restored originals — run 'make format' to accept."; \
	  git checkout -- Sources/ Tests/; \
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

ci-local: clean format-check audit build test
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
	@echo "  make ci-local       Full local CI pipeline (clean → format → audit → build → test)"
