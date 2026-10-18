#!/usr/bin/env bash
# run.sh — run every live probe in this directory against a freshly booted server.
#
# Each probe boots its own `ocoreai serve` on a free port, so this takes as long as the
# model needs to load, once per probe. That is the cost of a measurement nobody has to
# take on faith: the numbers in AGENTS.md § Open and CHANGELOG stop being stories.
#
# These probes need a real Metal device. Inside the agent sandbox MLX reports
# "No Metal device available" and every probe fails at boot — that is the harness, not
# the code; run them unsandboxed, the same route `make test-clt` uses.
#
# Run:  bash scripts/probes/run.sh            (all probes)
#       bash scripts/probes/run.sh 02 03     (only the named ones)
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FILTERS=("$@")
TOTAL=0
FAILED=0
FAILED_NAMES=""

# Every NN-*.sh in this directory. The glob used to be `0*.sh`, which silently stopped
# enumerating at 09 — probe 10 existed, ran never, and "8/8 passed" stayed green while
# describing a surface the suite no longer covered (invariant 1: a scan must floor its
# own premises, and here it could not even see its own members).
for probe in [0-9]*.sh; do
  if [ "${#FILTERS[@]}" -gt 0 ]; then
    match=0
    for f in "${FILTERS[@]}"; do
      case "$probe" in "$f"*) match=1 ;; esac
    done
    [ "$match" -eq 1 ] || continue
  fi
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  $probe"
  echo "════════════════════════════════════════════════════════════════"
  bash "$probe"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  ✔ $probe"
  else
    echo "  ✘ $probe (exit $rc)"
    FAILED=$(( FAILED + 1 ))
    FAILED_NAMES="$FAILED_NAMES $probe"
  fi
  TOTAL=$(( TOTAL + 1 ))
done

echo ""
echo "────────────────────────────────────────────────────────────────"
if [ "$TOTAL" -eq 0 ]; then
  echo "FAIL  no probe matched the filter — nothing ran"
  exit 1
fi
if [ "$FAILED" -eq 0 ]; then
  echo "✅ all $TOTAL live probe(s) passed"
  exit 0
fi
echo "❌ $FAILED/$TOTAL live probe(s) failed:$FAILED_NAMES"
exit 1
