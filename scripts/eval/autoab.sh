#!/usr/bin/env bash
# autoab.sh — the contract loop, automated: gate → apply → build → frozen set k=6 → McNemar →
# keep or revert → ledger.
#
# Why this exists: the loop that found the read-echo defect was run by hand, four configurations at
# k=6, and every judgement in it (which noise floor, which base, whether to revert) was made by a
# reader. The same loop as a script runs five variants a day and makes the judgements *before* it
# sees an answer. Two properties are load-bearing and both are gated by `_autoab_selftest.py`:
#   • the loop cannot move the goal posts — see `autoloop-allow.txt` / `autoloop-protected.txt`;
#   • a variant that was never measured is never a win: build, boot and invalid-run failures all
#     land in the ledger as not-measured, because averaging a broken run into a trend is the exact
#     mistake that once produced a "significant p=0.0032 regression" out of an engine outage.
# The loop edits the working tree and never commits: the owner reviews every commit.
#
#   OCOREAI_AUTOAB_BASE=<root-of-base-k-runs> bash scripts/eval/autoab.sh [proposal.patch …]
#
# Exit: 0 every proposal reached a measured verdict · 1 a proposal was refused (goalposts) ·
# 3 something was not measured or not reverted (the instrument is broken — fix it before believing
# any row of the ledger).

set -uo pipefail
# The judges are re-read every proposal; bytecode cached beside the sources can serve a previous
# proposal's rules to the next one, which is a verdict from a file that no longer exists.
export PYTHONDONTWRITEBYTECODE=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/../.."

: "${OCOREAI_EVAL_TASKS:=scripts/eval/tasks-edit-repair.json}"
: "${OCOREAI_EVAL_REPEATS:=6}"
ALLOW="${OCOREAI_AUTOAB_ALLOW:-$HERE/autoloop-allow.txt}"
PROTECTED="${OCOREAI_AUTOAB_PROTECTED:-$HERE/autoloop-protected.txt}"
BASE="${OCOREAI_AUTOAB_BASE:-}"
LEDGER="$HERE/autoloop.tsv"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="${OCOREAI_AUTOAB_WORK:-$(mktemp -d -t ocoreai-autoab-XXXXXX)}"
mkdir -p "$WORK"

if [ -z "$BASE" ]; then
  echo "❌ OCOREAI_AUTOAB_BASE is required — the root of k frozen-set runs of the *unmodified* tree" >&2
  echo "   make one with: OCOREAI_EVAL_REPEAT_ROOT=<root> OCOREAI_EVAL_REPEATS=$OCOREAI_EVAL_REPEATS bash scripts/eval/repeat.sh" >&2
  echo "   a proposal measured against nothing is not a measurement." >&2
  exit 3
fi
if [ ! -f "$ALLOW" ] || [ ! -f "$PROTECTED" ]; then
  echo "❌ missing $ALLOW or $PROTECTED — the loop does not run without its path rules" >&2
  exit 3
fi

CLT=/Library/Developer/CommandLineTools
CLT_F="$CLT/Library/Developer/Frameworks"
CLT_SDK="$(DEVELOPER_DIR="$CLT" bash scripts/toolchain-contract.sh print-sdk-root 2>/dev/null)"
BUILD_CMD="${OCOREAI_AUTOAB_BUILD_CMD:-DEVELOPER_DIR=$CLT SDKROOT=$CLT_SDK swift build --scratch-path .build-clt -Xswiftc -F$CLT_F -Xlinker -F$CLT_F}"

PROPOSALS=("$@")
if [ ${#PROPOSALS[@]} -eq 0 ]; then
  for p in "$HERE"/proposals/*.patch; do
    [ -e "$p" ] && PROPOSALS+=("$p")
  done
fi
if [ ${#PROPOSALS[@]} -eq 0 ]; then
  echo "no proposals in $HERE/proposals — nothing to measure (add one .patch, see proposals/README.md)"
  exit 0
fi

echo "autoab · task set $OCOREAI_EVAL_TASKS · k=$OCOREAI_EVAL_REPEATS · base $BASE"
echo "         · base commit $(git rev-parse --short HEAD) · work $WORK"
# The before/after comparison is scoped to the prefixes the loop is allowed to write under, and
# the scope is derived from the allow list rather than hardcoded: a change outside that scope is
# not the loop's doing, and an unrelated file appearing mid-run must not read as a variant that
# failed to revert.
SCOPE=()
while IFS= read -r prefix; do SCOPE+=("$prefix"); done < <(sed 's/#.*//' "$ALLOW" | sed '/^[[:space:]]*$/d')
[ ${#SCOPE[@]} -eq 0 ] && SCOPE=(".")
tree_state() { git status --porcelain -- "${SCOPE[@]}" > "$1"; }
BEFORE="$WORK/git-before.txt"
tree_state "$BEFORE"

REFUSED=0
UNMEASURED=0
LEDGER_DIRTY=0   # a keep legitimately dirties the tree; revert must not

ledger() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$STAMP" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" >> "$LEDGER"
}

restore_tree() {
  local patch="$1"
  git apply -R "$patch" 2>>"$WORK/revert.log"
}

for patch in "${PROPOSALS[@]}"; do
  name="$(basename "$patch" .patch)"
  echo "── proposal $name ($patch)"

  if ! gate_out="$(OCOREAI_AUTOAB_ALLOW="$ALLOW" OCOREAI_AUTOAB_PROTECTED="$PROTECTED" \
      python3 "$HERE/_autoab_gate.py" check-paths "$patch" 2>&1)"; then
    echo "$gate_out" | sed 's/^/   /'
    ledger "$name" "$(git rev-parse --short HEAD)" "0" "-" "-" "-" "-" "-" "refused" "gate"
    REFUSED=1
    continue
  fi
  echo "$gate_out" | sed 's/^/   /'

  if ! git apply --check "$patch" 2>"$WORK/$name.apply.err"; then
    echo "   ❌ not measured: the patch does not apply to $(git rev-parse --short HEAD) —" \
      "$(tr '\n' ' ' < "$WORK/$name.apply.err")"
    ledger "$name" "$(git rev-parse --short HEAD)" "0" "-" "-" "-" "-" "-" "not-measured" \
      "stale-patch"
    UNMEASURED=1
    continue
  fi
  git apply "$patch"

  if ! bash -c "$BUILD_CMD" > "$WORK/$name.build.log" 2>&1; then
    echo "   ❌ build failed with the variant applied — reverting, verdict not-measured"
    tail -5 "$WORK/$name.build.log" | sed 's/^/      /'
    restore_tree "$patch" || { echo "   ❌ REVERT FAILED — tree left dirty, stop"; exit 3; }
    ledger "$name" "$(git rev-parse --short HEAD)" "0" "-" "-" "-" "-" "-" "not-measured" \
      "build-failed"
    UNMEASURED=1
    continue
  fi

  VROOT="$WORK/$name"
  echo "   measuring k=$OCOREAI_EVAL_REPEATS → $VROOT"
  OCOREAI_EVAL_TASKS="$OCOREAI_EVAL_TASKS" OCOREAI_EVAL_REPEATS="$OCOREAI_EVAL_REPEATS" \
    OCOREAI_EVAL_REPEAT_ROOT="$VROOT" bash "$HERE/repeat.sh" > "$WORK/$name.repeat.log" 2>&1

  decide_out="$WORK/$name.decide.txt"
  python3 "$HERE/_autoab_gate.py" decide "$BASE" "$VROOT" > "$decide_out" 2>&1
  drc=$?
  sed 's/^/   /' "$decide_out"

  # The valid-run count comes from the judge that used it, not from a grep over the run dirs: a
  # run excluded as an engine fault is absent from the score, and two definitions of "valid" is
  # two numbers that drift.
  read -r decision scores_b scores_v pb pc pp vruns <<< "$(python3 - "$decide_out" <<'PY'
import json, sys
raw = [l for l in open(sys.argv[1], encoding="utf-8") if l.startswith("{")]
d = json.loads(raw[0]) if raw else {}
print("\t".join(str(x) for x in (d.get("decision", "not-measured"),
                                d.get("scores_base", "-"), d.get("scores_variant", "-"),
                                d.get("b", "-"), d.get("c", "-"), d.get("p", "-"),
                                d.get("variant_runs", "-"))))
PY
)"
  : "${decision:=not-measured}"

  if [ "$drc" -eq 0 ]; then
    echo "   ✅ KEEP — variant left applied; commit it (or revert) after review"
    LEDGER_DIRTY=1
  else
    if ! restore_tree "$patch"; then
      echo "   ❌ REVERT FAILED for $name — leaving the tree as-is would hide what is applied" >&2
      exit 3
    fi
  fi
  ledger "$name" "$(git rev-parse --short HEAD)" "$vruns/$OCOREAI_EVAL_REPEATS" \
    "$scores_b" "$scores_v" "$pb" "$pc" "$pp" "$decision" "$VROOT"
done

# The loop must end where it started unless it kept something: a leftover diff is how a reverted
# variant keeps influencing the next measurement while looking like baseline.
AFTER="$WORK/git-after.txt"
tree_state "$AFTER"
if [ "$LEDGER_DIRTY" -eq 0 ] && ! diff -q "$BEFORE" "$AFTER" > /dev/null; then
  echo "❌ the tree is not the tree that went in, and nothing was kept:" >&2
  diff "$BEFORE" "$AFTER" | sed 's/^/   /' >&2
  exit 3
fi

echo "ledger → $LEDGER"
if [ "$UNMEASURED" -ne 0 ]; then
  echo "exit 3 — at least one proposal was NOT measured; fix the instrument before reading the ledger"
  exit 3
fi
if [ "$REFUSED" -ne 0 ]; then
  echo "exit 1 — at least one proposal was refused for touching the goal posts (see above)"
  exit 1
fi
echo "exit 0 — every proposal reached a measured verdict"
