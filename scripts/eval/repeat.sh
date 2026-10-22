#!/usr/bin/env bash
# repeat.sh — run the scoreboard k times and report the noise floor before any "improvement".
#
# One run of the scoreboard is a sample, not a measurement. Until the spread of repeated
# identical runs is known, every delta reported from it — including one produced by a change
# this repo just shipped — is unattributable (AGENTS.md: a claim is worth the gate that goes
# red when it breaks; a number with no spread answers no question).
#
#   bash scripts/eval/repeat.sh                       # k=3
#   OCOREAI_EVAL_REPEATS=5 bash scripts/eval/repeat.sh
#   OCOREAI_EVAL_REPEAT_ROOT=/tmp/eval-a ... ; OCOREAI_EVAL_REPEAT_ROOT=/tmp/eval-b ...
#   python3 scripts/eval/_repeat_stats.py /tmp/eval-a   # per-config floor
#
# Each run boots its own serve (run.sh owns that) and lands in $ROOT/run-<k>/results.tsv;
# _repeat_stats.py aggregates them into noise.json.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${OCOREAI_EVAL_REPEATS:=3}"
ROOT="${OCOREAI_EVAL_REPEAT_ROOT:-$(mktemp -d -t ocoreai-eval-repeat-XXXXXX)}"
mkdir -p "$ROOT"

if [ "$OCOREAI_EVAL_REPEATS" -lt 2 ]; then
  echo "note: k=1 gives no spread — pass OCOREAI_EVAL_REPEATS>=2 to get a noise floor" >&2
fi

# Pre-flight: an ocoreai instance that is already up holds the single-instance lock, and
# every run would then die on the readiness gate — three times. Say it once, before the
# first boot, with the remedy. Kill by the PID the server names: `pkill -x ocoreai` matches
# this harness's own serve too and takes the scoreboard down mid-run (measured 10-22).
if pgrep -x ocoreai >/dev/null 2>&1; then
  echo "❌ an ocoreai instance is already running: $(pgrep -lx ocoreai | tr '\n' ' ')" >&2
  echo "   it holds the single-instance lock, so no run here can load a model." >&2
  echo "   remedy: kill <that pid> (NOT pkill -x ocoreai — it also matches this run's serve)," >&2
  echo "   or set OCOREAI_ALLOW_MULTI_INSTANCE=1 deliberately if you know the GPU can hold both." >&2
  exit 1
fi

for k in $(seq 1 "$OCOREAI_EVAL_REPEATS"); do
  echo "=== run $k/$OCOREAI_EVAL_REPEATS → $ROOT/run-$k ==="
  OCOREAI_EVAL_OUT="$ROOT/run-$k" bash "$HERE/run.sh" >"$ROOT/run-$k.log" 2>&1
  rc=$?
  tail -2 "$ROOT/run-$k.log" | sed 's/^/    /'
  echo "    run $k exit $rc"
done

python3 "$HERE/_repeat_stats.py" "$ROOT"
