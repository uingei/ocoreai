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

.PHONY: all build release release-mac27 app dmg test test-verbose test-coverage test-ci probes format format-check audit docs-check anchor-check round-gates clean metallib help ci-local push-ready ci-status spell install-hooks

all: build

## ── Build ──────────────────────────────────────────────────────────

build:
	@echo "🔨 Building debug..."
	swift build

release:
	@echo "🔨 Building release — delivery shape (CoreAI-free SDK, pinned route)..."
	@# Judge the artifact, not the environment. `swift build -c release` on the ambient route
	@# is whatever SDK the host happens to have: on this host that is Xcode/SDK 27, which ships
	@# CoreAI.framework, so a "release" binary silently became the macOS-27 shape that R1 calls
	@# out-of-delivery — while the CI release leg, on an SDK-26 image, produced the other one.
	@# Same release name, two different products, nothing comparing them.
	@$(METAL_PATH_EXPORT)DEVELOPER_DIR=$(CLT_DIR) $(SDKROOT_CLT) swift build -c release \
	  -Xswiftc -F$(CLT_F) -Xlinker -F$(CLT_F) -Xlinker -rpath -Xlinker $(CLT_F) \
	  -Xlinker -rpath -Xlinker $(CLT_L)
	@bash scripts/release-artifact-check.sh delivery .build/release/ocoreai

## The deliberate macOS-27 route (OCOREAI_TARGET_SDK=macos27): CoreAI blocks compiled IN, so
## the artifact names it. Asserted, because a form nobody can tell apart from the delivery form
## is how an unverifiable code path gets shipped under the delivery name.
release-mac27:
	@echo "🔨 Building release — macOS-27 shape (CoreAI linked IN, NOT the delivery form)..."
	@# Own scratch: `.build/release` is where `release` leaves the delivery binary and where the
	@# probes and eval look for it. A second form written to the same path would leave a
	@# CoreAI-linked binary sitting at the delivery location after the target that named it had
	@# finished — the trap this whole split exists to close.
	@DEVELOPER_DIR=$${DEVELOPER_DIR:-$(XCODE_APP)/Contents/Developer} swift build -c release --scratch-path .build-mac27
	@bash scripts/release-artifact-check.sh macos27 .build-mac27/release/ocoreai

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

## SDK pin — never trust `MacOSX.sdk`. It is a symlink, and a toolchain update can
## repoint it under us: on 10-14 an Xcode/CLT update moved the CLT symlink from
## 26.5 to 27.0, and SDK 27 ships CoreAI.framework — so `DEVELOPER_DIR=$(CLT_DIR)`
## stopped selecting the macOS-26 shape this target is named after, and every
## `#if canImport(CoreAI)` block started compiling into the build. Resolve the newest
## CoreAI-free SDK once and pass it explicitly. scripts/toolchain-contract.sh asserts
## this and the shader-compiler requirement (strict in CI, advisory for local build).
CLT_SDK ?= $(shell DEVELOPER_DIR=$(CLT_DIR) bash scripts/toolchain-contract.sh print-sdk-root 2>/dev/null)
SDKROOT_CLT = $(if $(CLT_SDK),SDKROOT=$(CLT_SDK),)

# Metal injection — when the DEVELOPER_DIR stub says "missing Metal Toolchain" but
# the component is in fact installed, the real compiler sits on a cryptexd mount
# (suffix is session-specific; scripts/toolchain-contract.sh discovers it and
# `metal --version` answers ok from there — verified 10-14, swift build completed
# in 149s with this dir prepended). SwiftPM spawns `metal` by PATH lookup, so the
# prefix below is the difference between "unbuildable" and a green build.
CLT_METAL_BIN ?= $(shell bash scripts/toolchain-contract.sh print-metal-bin 2>/dev/null)
METAL_PATH_EXPORT = $(if $(CLT_METAL_BIN),export PATH="$(CLT_METAL_BIN):$$PATH";,)

.PHONY: toolchain-check
## ── Toolchain contract ─────────────────────────────────────────────
# Assert the platform premise the gates rest on (delivery SDK without CoreAI, metal
# reachable) instead of documenting it. Fails with the exact remedy.
#
# Both candidate routes are evaluated, because "this host cannot produce the delivery
# shape" was reported as fact on 10-14 by a check that only looked at the ambient
# DEVELOPER_DIR (Xcode, SDK 27 only) while the CLT route on the same host still had
# a CoreAI-free SDK 26.5. A gate that asks one route about a decision the build makes
# between two routes reports a premise it never verified. R2 is decided by compiling a
# kernel (--probe-metal), not by `metal --version`, whose answer follows whether
# cryptexd happens to have the asset mounted.
toolchain-check:
	@PASS=0; \
	for RT in "$${DEVELOPER_DIR:-$(XCODE_APP)/Contents/Developer}" "$(CLT_DIR)"; do \
	  SDK="$$(DEVELOPER_DIR=$$RT bash scripts/toolchain-contract.sh print-sdk-root 2>/dev/null)"; \
	  echo "── route: DEVELOPER_DIR=$$RT$${SDK:+ SDKROOT=$$SDK}"; \
	  if env DEVELOPER_DIR=$$RT $${SDK:+SDKROOT=$$SDK} bash scripts/toolchain-contract.sh check --require-metal --probe-metal; then \
	    PASS=1; \
	  else \
	    echo "   ↑ this route cannot produce the delivery shape"; \
	  fi; \
	done; \
	[ "$$PASS" -eq 1 ] || { echo "❌ no route on this host gives a CoreAI-free SDK AND a working shader compiler"; exit 1; }; \
	echo "✅ contract holds on at least one route — the build/test targets pin it explicitly"

## swift-format resolution — CI installs it on PATH via brew; an Xcode/CLT-only
## host ships it only under `xcrun`, so `make format`/`format-check` died with
## "swift-format: No such file or directory". The style gate reached CI unseen
## because it could not be run locally. Resolve once; the args stay identical.
SF_CACHE = $(HOME)/.cache/ocoreai-swift-format-$(SF_PIN)
SF_LOCAL = $(SF_CACHE)/repo/.build/release/swift-format
SWIFT_FORMAT ?= $(shell if [ -x "$(SF_LOCAL)" ]; then echo "$(SF_LOCAL)"; elif command -v swift-format >/dev/null 2>&1; then echo swift-format; else echo "xcrun swift-format"; fi)
## The resolved binary's VERSION is part of the gate: CI installs brew swift-format and hard-fails
## unless it reports 603.0.0, but an Xcode/CLT-only host falls back to `xcrun swift-format`, whose
## version string is "main" — a different ruleset that reformats committed files CI accepts. Name
## the version on every run, so a local reformat is read as drift or violation deliberately.
SF_PIN := 603.0.0
## FILTER=<Regex> narrows the run to one suite (swift-testing matches test IDs, so a suite type
## name is the reliable handle); omit it and the target stays the FULL-suite escalation gate.
test-clt:
	@echo "🧪 CLT-route test gate (macOS < 27 local; FULL suite unless FILTER is set)..."
	@# Check the route this target actually builds (CLT + pinned SDK), not the ambient
	@# DEVELOPER_DIR: reporting R1 against Xcode's SDK 27 while the build passes
	@# SDKROOT=…26.5 cries wolf every run, and a warning that always fires is a warning
	@# nobody reads when it becomes true.
	@DEVELOPER_DIR=$(CLT_DIR) $(SDKROOT_CLT) bash scripts/toolchain-contract.sh check --probe-metal || echo "⚠️  toolchain contract violated — see remedies above (CI is strict; local run proceeds)"
	@echo "   pinning SDK: $(or $(CLT_SDK),<none CoreAI-free — do not trust this route's shape>)"
	@echo "   metal: $(or $(CLT_METAL_BIN),as-resolved-by-toolchain-check)"
	@$(METAL_PATH_EXPORT)DEVELOPER_DIR=$(CLT_DIR) $(SDKROOT_CLT) swift build --build-tests --scratch-path .build-clt -Xswiftc -F$(CLT_F) -Xlinker -F$(CLT_F) >/dev/null
	@# Metal staging: CLT cannot compile .metal sources, so hand MLX a prebuilt payload.
	@#
	@# Stage OUTSIDE the bundle. The build signs the .xctest, and a .metallib under
	@# Contents/MacOS is a nested code object by the signing rules — the sign task then
	@# dies with "code object is not signed at all … mlx.metallib" (measured 10-14, after
	@# this target started writing into the bundle SwiftPM 6.4 actually produces:
	@# out/Products/Debug/ocoreaiTests.xctest, where the old hardcoded
	@# arm64-apple-macosx/debug/ocoreaiPackageTests.xctest was an Oct-11 symlink to a
	@# stale tree). The staged copy therefore lands in the PRODUCTS dir, and the test
	@# process points MLX at it via $$OCOREAI_METALLIB → MLX.GPU.metallib
	@# (MetalShaderLibrary.swift: MLX's own search is path-shaped and reaches neither
	@# location from inside a signed bundle).
	@# Which payload wins is one ladder with one home — scripts/resolve-metallib.sh prints it
	@# (provenance order: $OCOREAI_METALLIB, this scratch's SwiftPM product, an Xcode product,
	@# the pip wheel) and exits 1 with the remedy when nothing is usable. The target only
	@# stages the winner where the runner can reach it.
	@SRC=$$(bash scripts/resolve-metallib.sh .build-clt) || { echo "❌ no payload to stage — remedy above"; exit 1; }; \
	BUNDLES=$$(find .build-clt -path '*/Products/*' -name '*.xctest' -type d 2>/dev/null); \
	[ -n "$$BUNDLES" ] || { echo "❌ no .xctest under .build-clt — the test build produced nothing to stage beside"; exit 1; }; \
	for B in $$BUNDLES; do cp -f "$$SRC" "$$(dirname "$$B")/mlx.metallib" || true; done; \
	NEWEST_BUNDLE=$$(ls -dt $$BUNDLES 2>/dev/null | head -1); \
	[ -n "$$NEWEST_BUNDLE" ] || { echo "❌ could not resolve the freshest test bundle"; exit 1; }; \
	STAGED=$$(cd "$$(dirname "$$NEWEST_BUNDLE")" && pwd)/mlx.metallib; \
	[ -f "$$STAGED" ] || { echo "❌ staged payload missing at $$STAGED"; exit 1; }; \
	printf '%s' "$$STAGED" > .build-clt/.metallib-path; \
	echo "   metallib staged: $$SRC → $$STAGED (exported as \$$OCOREAI_METALLIB)"; \
	NEWEST_METAL=$$(ls -t .build-clt/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal/*.metal 2>/dev/null | head -1); \
	if [ -n "$$NEWEST_METAL" ] && [ "$$NEWEST_METAL" -nt "$$SRC" ]; then \
	  echo "⚠️  staged metallib predates $$NEWEST_METAL — it may lack kernels added by the"; \
	  echo "   pinned mlx bump. If a suite fails on a missing kernel, rebuild shaders here" ; \
	  echo "   (xcodebuild -downloadComponent MetalToolchain, or build in Xcode) before reading it as a code regression."; \
	fi
	@$(METAL_PATH_EXPORT)DEVELOPER_DIR=$(CLT_DIR) $(SDKROOT_CLT) OCOREAI_METALLIB=$$(cat .build-clt/.metallib-path 2>/dev/null) swift test \
	  --scratch-path .build-clt \
	  --no-parallel \
	  -Xswiftc -F$(CLT_F) \
	  -Xlinker -F$(CLT_F) \
	  -Xlinker -rpath -Xlinker $(CLT_F) \
	  -Xlinker -rpath -Xlinker $(CLT_L) \
	  $(if $(FILTER),--filter "$(FILTER)",)

test:
	@echo "🧪 Running tests..."
	@# Name the shader payload before the run: a test process that lets MLX search for it dies
	@# at the first Metal allocation ("Failed to load the default metallib", Cmlx memory.cpp) and
	@# the suite never reports — measured 10-26 on the Xcode route, 4k lines in, no summary.
	@#
	@# A red whose failing test name scrolls off the terminal is a red nobody can root-cause:
	@# measured 10-27, a 1-issue full run behind `| tail -12` lost its identity entirely. So the run is
	@# teed and the ✘ lines are re-printed on failure — the verdict survives its own pipe. The status
	@# travels through a file because PIPESTATUS is a bash-ism: this recipe runs under /bin/sh, where a
	@# failing pipeline reports `${PIPESTATUS[0]}` as 0 (measured), which would have made the tee swallow
	@# every red.
	@# The XCTest half is never run, filtered or not. It serves zero tests — `git grep -l
	@# "import XCTest" in Tests/` is the count, checked below before anything builds — and its
	@# runner dies before test #1 on any macOS < 27 host: objc_copyClassList → realizeAllClasses
	@# realizes CoreAIPipelinedEngine, whose @available(macOS 27) metadata needs the weak-linked
	@# CoreAI/FoundationModels class refs (`otool -L` reports "(weak)") that bind to NULL there,
	@# so an unfiltered `swift test` could never exit 0 whatever the suite did. The refusal is the
	@# gate: if Tests/ ever gains an XCTest file, --disable-xctest would be dropping tests, not
	@# noise, and that must be a red rather than a silently greener run.
	@XCT=$$(grep -rl "import XCTest" Tests 2>/dev/null | wc -l | tr -d ' '); \
	  if [ "$$XCT" != "0" ]; then \
	    echo "❌ Tests/ holds $$XCT XCTest file(s) — --disable-xctest would drop real tests."; \
	    echo "   The XCTest runner SEGVs at class realization on macOS < 27 (see above): port the"; \
	    echo "   cases to swift-testing, or run them where CoreAI loads (macOS 27)."; exit 1; fi; \
	  METALLIB=$$(bash scripts/resolve-metallib.sh .build) \
	  || { echo "❌ no payload to name — remedy above"; exit 1; }; \
	  echo "   shader payload: $$METALLIB"; \
	  echo "   XCTest half: $$XCT file(s) → swift-testing only (--disable-xctest)"; \
	  LOG="$${OCOREAI_TEST_LOG:-$$(mktemp -t ocoreai-test-XXXXXX).log}"; \
	  RC="$$(mktemp -t ocoreai-test-rc-XXXXXX)"; \
	  echo "   test log: $$LOG"; \
	  if [ -n "$(FILTER)" ]; then \
	    { OCOREAI_METALLIB="$$METALLIB" swift test --disable-xctest --filter "$(FILTER)"; echo "$$?" > "$$RC"; } 2>&1 | tee "$$LOG"; \
	  else \
	    { OCOREAI_METALLIB="$$METALLIB" swift test --disable-xctest; echo "$$?" > "$$RC"; } 2>&1 | tee "$$LOG"; \
	  fi; \
	  T="$$(cat "$$RC")"; rm -f "$$RC"; \
	  if [ "$$T" -ne 0 ]; then \
	    echo "---- failing tests (full log: $$LOG) ----"; \
	    grep -E '✘|Expectation failed|^ *↳' "$$LOG" | head -40; \
	  fi; \
	  exit "$$T"

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
# ── Live probes ──────────────────────────────────────────────────────
# Behavioural evidence for the claims this repo publishes about its HTTP surface: what a
# session-pool HIT actually saves, whether OpenAI *and* Anthropic clients can size a
# request, and whether the endpoint index the 404 envelope points at actually answers.
# Compile-time tests pin the router; only a running server can show a route that is
# registered and still 404s.
#
# Needs a real Metal device AND a model in ~/.ocoreai/models, so this is deliberately an
# explicit step rather than part of ci-local: inside the agent sandbox MLX reports
# "No Metal device available" and every probe fails at boot (docs/agent/build-gate-reality.md).
probes:
	@echo "🔬 Live probes against a freshly booted ocoreai serve..."
	bash scripts/probes/run.sh

# swift-format is the only style gate — aligned with upstream
# (mlx-swift-lm / coreai-models ship no swiftlint; .swift-format is
# the shared config surface).

format:
	@echo "✨ Formatting Swift files..."
	@# Write only with the ruleset CI enforces. `xcrun swift-format` on an Xcode/CLT-only host
	@# reports "main"; its rewrites are a different ruleset, and committing them as a style "fix"
	@# churns files CI already accepts (measured 10-23: five files in one committed module rewrap
	@# differently under 603.0.0 vs "main"). Off-pin, diagnose read-only instead of writing.
	@SFV=$$($(SWIFT_FORMAT) --version 2>&1 | head -1); \
	case "$$SFV" in \
	  *$(SF_PIN)*) \
	    $(SWIFT_FORMAT) format --in-place --recursive --parallel --configuration .swift-format Sources/ Tests/; \
	    echo "Done ($(SF_PIN)). Revert by hand if you disagree: git diff / git checkout -- <path>" ;; \
	  *) \
	    echo "⛔ refusing to write: swift-format reports \"$$SFV\", not $(SF_PIN). Lint instead:"; \
	    $(SWIFT_FORMAT) lint --recursive --parallel --configuration .swift-format Sources/ Tests/ 2>&1 \
	      | awk 'END { print "   advisory notes: " NR " line(s) — the pinned $(SF_PIN) ruleset decides style" }' ;; \
	esac

format-check:
	@echo "🔍 Checking Swift format..."
	@# Judge formatting by what the formatter itself changes, not by `git diff`:
	@# the git-diff version counted every uncommitted feature edit as "unformatted",
	@# so this gate could never pass while work was in progress — and a gate that
	@# always fails locally is a gate nobody runs (that is how 5 unformatted files
	@# reached CI before bfcfb4b). Snapshot content hashes, format, compare.
	@# Off-pin, that method is invalid twice over: the rules are not CI's, and `--in-place`
	@# dirties files CI already accepts. So off-pin = lint (read-only) + exit 0, loudly.
	@SFV=$$($(SWIFT_FORMAT) --version 2>&1 | head -1); \
	MODE=pinned; case "$$SFV" in *$(SF_PIN)*) ;; *) MODE=advisory ;; esac; \
	echo "🧹 formatter: $$SFV (CI pins $(SF_PIN)) → $$MODE"; \
	if [ "$$MODE" = advisory ]; then \
	  echo "⚠️  not the pinned ruleset — diagnosing with lint, writing nothing, not failing:"; \
	  $(SWIFT_FORMAT) lint --recursive --parallel --configuration .swift-format Sources/ Tests/ 2>&1 \
	    | awk 'END { print "   advisory notes: " NR " line(s); the $(SF_PIN) leg in CI is the style authority" }'; \
	  exit 0; \
	fi; \
	BEFORE=$$(mktemp); AFTER=$$(mktemp); \
	find Sources Tests -name '*.swift' -type f -exec shasum {} + | sort -k2 > "$$BEFORE"; \
	$(SWIFT_FORMAT) format --in-place --recursive --parallel --configuration .swift-format Sources/ Tests/; \
	find Sources Tests -name '*.swift' -type f -exec shasum {} + | sort -k2 > "$$AFTER"; \
	BAD=$$(join -j 2 -o 0,1.1,2.1 "$$BEFORE" "$$AFTER" | awk '$$2 != $$3 {print "  " $$1}'); \
	rm -f "$$BEFORE" "$$AFTER"; \
	if [ -z "$$BAD" ]; then \
	  echo "✅ swift-format: zero files reformatted"; \
	else \
	  echo "❌ swift-format reformatted:"; printf '%s\n' "$$BAD"; echo; \
	  echo "Working tree KEEPS the reformat (no blind checkout). Accept: make format"; \
	  exit 1; \
	fi

audit:
	@echo "🔍 Running static audit..."
	bash scripts/audit.swift_patterns.sh
	@# A documented remediation target that cannot even parse is a gate with no exit: `make format`
	@# died on an apostrophe inside a single-quoted awk program, so the stated fix for
	@# `make format-check` had never once run. Parse every recipe before trusting it.
	bash scripts/makefile-parse-check.sh
	@# Two lockfiles, one dependency graph: xcodebuild (make test-ci, the DMG) reads the WORKSPACE
	@# copy, swift build reads the ROOT one. They drifted for three pin bumps and only CI ever said
	@# so, because this target is the local mirror of the CI audit job — which already checks it.
	bash scripts/resolved-sync.sh check
	@# A dead type name in the architecture docs teaches an architecture that does not exist:
	@# ARCHITECTURE.md diagrammed BackendProtocol.swift for weeks after 2123143 deleted it.
	bash scripts/docs-type-existence.sh

## Two passes, one command. anchor-check.sh verifies the cites that carry an `anchor:` marker;
## upstream-cite-check.sh verifies the *bare* `path.ext:NN` cites in Sources/ comments (173 on
## 10-22) against the reference clones, package checkouts and .upstream-external-cites.json —
## 4 of them named a path or line that did not exist, so this layer needed its own gate.
## Verifies every file:line cite in AGENTS.md / area guides / docs and the upstream cites in
## code comments against the file it names (working tree, or the pinned upstream revision).
## Line numbers are how the agent navigates, and they move under every edit and bump: 15 of
## them were wrong on 10-17 with `make docs-check` green, because a cite inside a file is not
## the same claim as a cite pointing at the code.
anchor-check:
	@echo "🎯 Verifying line cites in docs and code comments..."
	bash scripts/anchor-check.sh
	bash scripts/upstream-cite-check.sh

## Four upstream axes, one command. Three HEAD axes (mlx-swift-lm revision pin, coreai-models
## and codex reference axes) against .upstream-baseline.json, plus the mlx-swift *tag* axis —
## that one is judged against the newest release tag, because `exact:` means unreleased commits
## on main are not something any Swift consumer can take. Exit codes: 0 = nothing pending,
## 10 = a window needs adjudication (then `bash scripts/upstream-drift.sh adopt` after the
## verdicts are written to CHANGELOG.md), 1 = a check could not complete. Needs network via
## git/gh or the ~/references clones; it never mutates the repo except through `adopt`.
drift:
	@echo "🛰 Checking upstream drift (3 HEAD axes + mlx-swift tag axis)..."
	bash scripts/upstream-drift.sh

## A pin you cannot install is not a pin. CI builds $(SF_PIN) from the tag for exactly this reason
## (brew serves whatever is current), and until this target existed the same argument did not hold
## locally: an Xcode/CLT host reports "main", so format-check went advisory and exited 0 whatever
## the tree looked like — measured 10-27, ten committed files were already off CI's ruleset and
## nothing local could say so. Builds once into $(SF_CACHE); format-check then finds it by itself.
sf-pin:
	@set -euo pipefail; \
	if [ -x "$(SF_LOCAL)" ]; then echo "✅ swift-format $(SF_PIN) already installed: $$("$(SF_LOCAL)" --version | head -1)"; exit 0; fi; \
	mkdir -p "$(SF_CACHE)"; \
	git clone --depth 1 --branch "$(SF_PIN)" https://github.com/swiftlang/swift-format.git "$(SF_CACHE)/repo"; \
	( cd "$(SF_CACHE)/repo" && swift build -c release --quiet ); \
	echo "✅ built $(SF_PIN) → $(SF_LOCAL) (format-check and format now run CI's ruleset)"


## ── Docs Contract ──────────────────────────────────────────────────

# AGENTS.md (and the area guides) are injected into the model's context on every session, so they
# are code, not notes: budget them, resolve every path they name, and re-run every number they
# claim. Sub-second, needs no build, runs inside the agent sandbox — so there is no excuse to skip
# it. Its first run here failed on three stale counts and four dead map rows: nothing else greps
# the docs.
docs-check:
	bash scripts/agents-md-contract.sh check

## Pinned codespell, version asserted before use, vocabulary in .codespellrc. CI runs it too — on
## ubuntu, because it reads text and the arm64 audit leg already costs 715 s a push.
spell:
	bash scripts/spell-check.sh

## Opt-in local hooks from .pre-commit-config.yaml. Needs pre-commit on PATH
## (python3 -m pip install --user pre-commit); nothing here is required to contribute, CI runs
## the same file. Named install-hooks because a target called `hooks` is shadowed by the
## directory of the same name — make said "up to date" and the parse gate caught it.
install-hooks:
	pre-commit install

## Every no-build gate a round owns, in one command. `ci-local` is the full pipeline but it
## starts with `clean`, and a half-hour target gets skipped mid-round — which is exactly how five
## line-cites survived a push after their files grew (docs-check only asks whether a cited path
## exists; verifying the *line* is anchor-check's job, and nothing chained the two).
round-gates: docs-check anchor-check audit spell
	@echo "✅ round gates green — docs contract, line cites, swift patterns, spelling"

# A round is not finished while it lives only in this checkout: CI on macos-26 is the stated
# authority, and an unpushed commit has been verified by nobody but this box. Two days of uncommitted
# work escaped every gate that exists, so this one checks the tree instead of the text.
push-ready:
	bash scripts/worktree-hygiene.sh
	@# A pure reformat moved 19 line-cites in three files and every local gate stayed green, because
	@# round-gates (which does check them) is not the target anyone runs before pushing. A gate that
	@# exists off the path taken is not a gate: verify the cites here, where the tree is verified.
	@bash scripts/anchor-check.sh || { echo "::error::line-cite drift — repoint the cite or fix the code"; exit 1; }
	@# CI truth, reported not enforced: the authority leg sat `skipped` for ~90 pushes because
	@# nothing local could ask what CI concluded. Exit 2 from this script means "could not ask"
	@# (offline, rate-limited, still running) and must never be read as green.
	@bash scripts/ci-status.sh || true

## ── CI truth for the commit origin/main points at (exit 2 = could not ask, not green) ──
ci-status:
	@bash scripts/ci-status.sh

# Shrink-only ratchet: re-pin the root cap to the file's current size. Refuses to raise it —
# text goes in only when text comes out.
docs-budget:
	bash scripts/agents-md-contract.sh budget

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

ci-local: clean format-check audit docs-check anchor-check build test-ci
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
	@echo "  make sf-pin         Build the swift-format version CI pins, so format-check stops being advisory"
	@echo "  make docs-check     AGENTS.md budget + refs + claims + routing (no build needed)"
	@echo "  make anchor-check   every file:line cite points at the code it claims (no build)"
	@echo "  make round-gates    docs-check + anchor-check + audit in one no-build pass (run it every round)"
	@echo "  make docs-budget    Lower the AGENTS.md size cap (shrink-only)"
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
