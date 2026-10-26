#!/usr/bin/env bash
# The spell gate, in one home: `make spell`, a pre-commit hook and CI all run this command
# against this repo's .codespellrc, on a version whose number is asserted before it is used.
# The assert is the point: a scanner a package manager installs serves whatever release is
# current, and this repo already lost ~90 CI runs to that with swift-format.
#
# Deliberately not on the arm64 audit leg (it costs 715 s and this reads text): CI runs it in
# the ubuntu governance job. Vocab lives in .codespellrc, one home, each entry a fact.
set -euo pipefail
PIN=2.4.3
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BIN="${OCOREAI_CODESPELL:-}"
[ -n "$BIN" ] || BIN="$(command -v codespell || true)"
# `pip install --user` on this host lands here, off PATH.
[ -x "$BIN" ] || BIN="$HOME/Library/Python/3.9/bin/codespell"
if [ ! -x "$BIN" ]; then
  echo "::error::failed step: spell gate (codespell $PIN not found; python3 -m pip install --user codespell==$PIN) — not skipped"
  exit 1
fi
V="$("$BIN" --version | tr -dc '0-9.')"
if [ "$V" != "$PIN" ]; then
  echo "::error::failed step: spell gate (codespell reports $V, wanted $PIN — bump the pin deliberately)"
  exit 1
fi

# A scan whose paths stopped matching passes vacuously, so the run proves two premises: the
# dictionary still bites (planted typo must be reported) and the tree is non-empty (floor below).
PROBE="$(mktemp)"
# The typo is assembled, not spelled: a literal one here would be a finding in the scanned tree.
printf 'a misspelled ali%sment here\n' g > "$PROBE"
if "$BIN" "$PROBE" >/dev/null 2>&1; then
  echo "::error::failed step: spell gate (planted typo was not reported — the gate is not biting)"
  exit 1
fi
rm -f "$PROBE"

SCAN=(Sources Tests docs scripts Libraries README.md README.zh.md ARCHITECTURE.md CONTRIBUTING.md AGENTS.md Makefile)
TRACKED=$(git ls-files Sources Tests docs scripts Libraries | wc -l | tr -dc '0-9')
if [ "$TRACKED" -lt 700 ]; then
  echo "::error::failed step: spell gate (only $TRACKED tracked files under the scanned paths, expected >=700)"
  exit 1
fi

if "$BIN" --config .codespellrc --check-filenames "${SCAN[@]}"; then
  echo "✅ spell gate: clean (codespell $PIN over $TRACKED tracked files + the root docs)"
  exit 0
fi
echo "::error::failed step: spell gate (see .codespellrc: fix the word, or add it there with the reason)"
exit 1
