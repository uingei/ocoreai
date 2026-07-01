# ocoreai — Development Makefile
# Usage: make [target]
#
# Build:      build, release
# Test:       test, test-verbose, test-coverage
# Quality:    format, format-check, lint, lint-fix, audit
# Dev:        clean, metallib, help
# CI:         ci-local (full local pipeline)

SHELL := /bin/bash
.PHONY: all build release test test-verbose test-coverage format format-check lint lint-fix audit clean metallib help ci-local

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

format:
	@echo "✨ Formatting Swift files..."
	swiftformat . --config .swiftformat

format-check:
	@echo "🔍 Checking Swift format..."
	swiftformat . --config .swiftformat --dryrun || \
	(echo ""; echo "❌ Format check failed. Run 'make format' to fix."; exit 1)

lint:
	@echo "🔍 Running SwiftLint..."
	@swiftlint lint --config .swiftlint.yml; \
	EXIT=$$?; \
	if [ $$EXIT -ne 0 ]; then \
		echo ""; \
		echo "❌ Lint failed (exit $$EXIT). Run 'make lint-fix' to auto-fix."; \
		exit $$EXIT; \
	fi

lint-fix:
	@echo "🔧 Auto-fixing lint issues..."
	@swiftlint lint --config .swiftlint.yml --fix

lint-report:
	@echo "📊 Lint summary..."
	@swiftlint lint --config .swiftlint.yml 2>&1 | grep "Found.*violations"

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

ci-local: clean format-check lint audit build test
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
	@echo "  make lint           Run SwiftLint (exit 1 on violations)"
	@echo "  make lint-fix       Auto-fix lint issues"
	@echo "  make audit          Run static audit (failure pattern check)"
	@echo ""
	@echo "Dev:"
	@echo "  make clean          Remove build artifacts"
	@echo "  make metallib       Setup MLX metallib for GPU acceleration"
	@echo "  make help           Show this help"
	@echo ""
	@echo "CI:"
	@echo "  make ci-local       Full local CI pipeline (clean → format → lint → audit → build → test)"
