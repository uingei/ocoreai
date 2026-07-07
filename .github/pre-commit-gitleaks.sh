#!/usr/bin/env bash
# pre-commit-gitleaks.sh — block secrets before they land in a commit.
#
# Reference: zeroclaw and eliza both use gitleaks in .githooks
#
# Installation (opt-in):
#   git config core.hooksPath .github/hooks
# Or run manually:
#   bash .github/pre-commit-gitleaks.sh

set -euo pipefail

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "warning: gitleaks not found; skipping staged secret scan" >&2
  echo "  Install:  brew install gitleaks" >&2
  exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
CONFIG="${REPO_ROOT}/.gitleaks.toml"

cfg_args=()
if [[ -f "$CONFIG" ]]; then
  cfg_args+=(--config "$CONFIG")
fi

# Scan staged changes only. `protect --staged` exits non-zero on any finding.
gitleaks protect --staged --redact --verbose "${cfg_args[@]}"
