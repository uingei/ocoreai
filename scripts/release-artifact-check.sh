#!/usr/bin/env bash
# Release-artifact check — judge the SHAPE OF WHAT WE SHIP, not the environment that built it.
#
# `scripts/toolchain-contract.sh` asserts R1 against an SDK on disk, and it does that well:
# it evaluates both candidate routes and settles Metal by compiling a kernel. But an SDK is a
# premise, not a product. Measured on this host at f19298d: `make release` was a bare
# `swift build -c release`, the ambient route was Xcode (SDK 27, ships CoreAI.framework), and
# the artifact it produced loads
#   /System/Library/Frameworks/CoreAI.framework … (weak)
# i.e. the macOS-27 shape, while R1 calls the CoreAI-free build the delivery shape in HARD
# terms, and every `#if canImport(CoreAI)` block in Engine/ is code no macOS 26 user can run
# and no local gate can execute. Nothing in the repo looked at the binary. A HARD rule about
# the shipping shape that no check applies to the shipping artifact is a claim, not a gate
# (Invariant 1).
#
# Usage: release-artifact-check.sh <delivery|macos27> <path-to-binary>
#   delivery  no CoreAI in the load commands (the macOS-26 shape R1 names)
#   macos27   CoreAI present (the deliberate route OCOREAI_TARGET_SDK=macos27 exists for)
# Both assert the artifact declares the floor Package.swift declares (.macOS(.v14)), because a
# silent lift there is how "runs on macOS 14" stops being true without a single test failing.
# Exit: 0 = the artifact is the form you asked for; 1 = it is not, message names the remedy.
set -u

FORM="${1:-}"
BIN="${2:-}"

if [ -z "$FORM" ] || [ -z "$BIN" ]; then
  echo "usage: $0 <delivery|macos27> <path-to-binary>" >&2
  exit 2
fi
case "$FORM" in
  delivery|macos27) ;;
  *) echo "unknown form '$FORM' (expected delivery | macos27)" >&2; exit 2 ;;
esac
if [ ! -f "$BIN" ]; then
  echo "artifact not found: $BIN — build it before judging its shape" >&2
  exit 1
fi
if ! command -v otool >/dev/null 2>&1; then
  echo "otool missing — the shape of a Mach-O cannot be judged without it" >&2
  exit 1
fi

LOADS="$(otool -L "$BIN" 2>/dev/null)"
if [ -z "$LOADS" ]; then
  echo "otool produced nothing for $BIN — not a Mach-O, or unreadable" >&2
  exit 1
fi
# Floor the premise: a binary with no load commands at all would make every grep below pass
# vacuously, which is exactly how a shape check rots into a no-op.
if ! printf '%s\n' "$LOADS" | grep -q '\.framework/'; then
  echo "no frameworks in $BIN's load commands — the scan has nothing to judge" >&2
  exit 1
fi

COREAI="no"
if printf '%s\n' "$LOADS" | grep -q 'CoreAI\.framework'; then
  COREAI="yes"
fi

MINOS="$(otool -l "$BIN" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $2; exit}')"
SDKFIELD="$(otool -l "$BIN" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f && /sdk/{print $2; exit}')"
[ -n "$MINOS" ] || MINOS="unknown"
[ -n "$SDKFIELD" ] || SDKFIELD="unknown"

printf 'artifact=%s\nform=%s\ncoreai=%s\nminos=%s\nsdk_field=%s\n' \
  "$BIN" "$FORM" "$COREAI" "$MINOS" "$SDKFIELD"

RC=0
if [ "$FORM" = "delivery" ] && [ "$COREAI" = "yes" ]; then
  echo "❌ delivery build links CoreAI — that is the macOS-27 shape, not the delivery shape R1 names." >&2
  echo "   remedy: build it on the CoreAI-free route (CLT SDK 26.5), which is what 'make release'" >&2
  echo "   pins; if you meant the macOS-27 form, say so with 'make release-mac27'." >&2
  RC=1
fi
if [ "$FORM" = "macos27" ] && [ "$COREAI" = "no" ]; then
  echo "❌ macos27 build links no CoreAI — this artifact does not contain the macOS-27 blocks," >&2
  echo "   so it is the delivery shape and should come from 'make release'." >&2
  RC=1
fi

# The declared floor is a shipping promise: Package.swift says .macOS(.v14).
if [ "$MINOS" != "unknown" ] && [ "$MINOS" != "14.0" ]; then
  echo "❌ $BIN declares minos $MINOS, but Package.swift declares .macOS(.v14) — macOS 14 users" >&2
  echo "   cannot run this, and no compile would have noticed." >&2
  RC=1
fi

if [ "$RC" = "0" ]; then
  echo "✅ artifact is the $FORM shape (coreai=$COREAI, minos=$MINOS)"
fi
exit "$RC"
