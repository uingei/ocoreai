#!/usr/bin/env bash
# version.sh — the one place a build version is decided (AGENTS.md: one home per decision).
#
# Ladder: OCOREAI_VERSION (CI exports it from the tag) -> newest tag -> 0.0.0 for an untagged tree.
# The last rung has to be an explicit emptiness check, not `|| echo`: `git describe` prints nothing
# and exits non-zero on a tagless tree, but a pipeline reports its LAST status (`tr`'s, which is 0),
# so `$(describe | tr ... || echo 0.0.0)` yields "" and a bundle ships with an empty
# CFBundleShortVersionString. Measured 10-26 on the tree whose tags were withdrawn.
# Gate: BuildVersionResolutionTests (override | tagless | tagged).
set -euo pipefail

v="${OCOREAI_VERSION:-}"
if [ -z "$v" ]; then
    v="$(git describe --tags --abbrev=0 2>/dev/null | tr -d 'v' || true)"
fi
[ -n "$v" ] || v="0.0.0"
printf '%s\n' "$v"
