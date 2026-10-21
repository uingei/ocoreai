#!/usr/bin/env bash
# run.sh — 任务成功率记分板 / the task-success scoreboard.
#
# Why this directory exists: everything else in scripts/ checks the WIRE (does the
# response carry the right fields, does the engine report the reuse it spent). Nothing
# here measures the mission's own unit — did the agent finish a real coding job? So each
# task mutates a throwaway workspace and the verifier inspects THE WORKSPACE, never the
# model's description of its own work. An answer that claims success while the file is
# unchanged scores FAIL, which is the difference between 生成内容 and 可靠行动.
#
# Reuses scripts/probes/_lib.sh rather than writing a parallel harness: own server on a
# free port, the pinned-checkout assertion, a ready-model requirement, and verdict lines
# that floor their own premises (invariant 1). Tool schemas come from GET /v1/tools, so
# this file holds no copy of them to drift.
#
#   bash scripts/eval/run.sh              # boot serve, run every task, print the scoreboard
#   OCOREAI_EVAL_TASKS=other.json ...    # run another task set
#
# Needs a real Metal device (same as the probes) and runs unsandboxed: the tasks require
# the agent to execute its own tools, so approval policy defaults to `auto` here. This is
# a scoreboard, not a CI gate: wire it into CI only once its number is known and held
# steady, or CI starts reporting a ceiling as a regression.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../probes/_lib.sh
source "$HERE/../probes/_lib.sh"
PROBE_NAME="eval-task-success"

: "${OCOREAI_APPROVAL_POLICY:=auto}"
export OCOREAI_APPROVAL_POLICY
: "${OCOREAI_EVAL_TOOLS:=read_file write_file edit_file search_files exec_command}"
export OCOREAI_EVAL_TOOLS
: "${OCOREAI_EVAL_FLOOR_TASKS:=6}"
: "${OCOREAI_EVAL_FLOOR_SPECS:=4}"

OUT="${OCOREAI_EVAL_OUT:-$(mktemp -d -t ocoreai-eval-XXXXXX)}"
mkdir -p "$OUT"

# One workspace for the whole run, stated to the server the way a headless operator
# would: `OCOREAI_WORKSPACE` is what `WorkspaceContext.configuredDirectory()` now reads,
# which is what `FileTools.resolve`, `ExecTools.effectiveCwd` and the injected
# `working_directory:` line all anchor to. A per-task directory instead would put the
# anchor and the prompt's path in different places, which is the bug this measures.
EVAL_WS="${OCOREAI_EVAL_WORKSPACE:-$(mktemp -d -t ocoreai-eval-ws-XXXXXX)}"
mkdir -p "$EVAL_WS"
export OCOREAI_WORKSPACE="$EVAL_WS"
TOOLS_CACHE="$OUT/tools.json"
# _eval.py reads the cached /v1/tools payload through this name; an unexported variable
# here makes every task fail with a KeyError, which is a harness bug wearing a model score.
export OCOREAI_TOOLS_CACHE="$TOOLS_CACHE"

probe_boot
probe_require_ready_model

if ! probe_api GET /v1/tools; then
  probe_fail "GET /v1/tools returned HTTP $PROBE_STATUS — cannot declare tools, so every task" \
    "would fail for the wrong reason"
  probe_summary "$PROBE_NAME"
fi
printf '%s' "$PROBE_BODY" > "$TOOLS_CACHE"
if [ ! -s "$TOOLS_CACHE" ]; then
  probe_fail "GET /v1/tools answered HTTP $PROBE_STATUS with an empty body — tool declarations are the"
  probe_fail "  premise of every task here, so the scoreboard cannot be run against this server"
  probe_summary "$PROBE_NAME"
fi

TASK_COUNT="$(python3 "$HERE/_eval.py" count)"
SPEC_COUNT="$(python3 "$HERE/_eval.py" spec-count "$OCOREAI_EVAL_TOOLS")"

# Two premises, floored before a single task runs: a scoreboard over zero tasks, or one
# where the agent had no tools, would print 0/0 and look like a quiet pass.
if [ "$TASK_COUNT" -lt "$OCOREAI_EVAL_FLOOR_TASKS" ]; then
  probe_fail "only $TASK_COUNT task(s) loaded (floor $OCOREAI_EVAL_FLOOR_TASKS) — the task set is" \
    "the instrument, and a shrunken set measures nothing"
fi
if [ "$SPEC_COUNT" -lt "$OCOREAI_EVAL_FLOOR_SPECS" ]; then
  probe_fail "this server declares only $SPEC_COUNT of the needed tools (floor $OCOREAI_EVAL_FLOOR_SPECS):" \
    "$OCOREAI_EVAL_TOOLS — tasks cannot be attempted, let alone passed"
fi
probe_note "scoreboard $TASK_COUNT tasks · $SPEC_COUNT tool(s) declared by the server · model $PROBE_MODEL"
probe_note "traces $OUT"

PASS=0
RUN=0
for id in $(python3 "$HERE/_eval.py" ids); do
  ws="$EVAL_WS"
  # fresh slate per task, so one task's leftover file can never satisfy another's verifier
  find "$EVAL_WS" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  python3 "$HERE/_eval.py" create-files "$ws" "$id"
  body="$(python3 "$HERE/_eval.py" body "$ws" "$PROBE_MODEL" "eval-$id" "$OCOREAI_EVAL_TOOLS" "$id")"

  if ! probe_chat "eval-$id" "$body"; then
    probe_fail "$id — request could not be made: $PROBE_BODY"
    continue
  fi
  RUN=$(( RUN + 1 ))
  printf '%s' "$PROBE_BODY" > "$OUT/response-$id.json"

  answer="$(python3 "$HERE/_eval.py" answer "$OUT/response-$id.json")"
  usage="$(python3 "$HERE/_eval.py" usage "$OUT/response-$id.json")"
  verify="$(python3 "$HERE/_eval.py" field "$id" verify)"
  expect=""
  [ "$id" = "run-command-report" ] && expect="$(uname -m)"

  OCOREAI_EVAL_ANSWER="$answer" OCOREAI_EVAL_EXPECT="$expect" \
    bash -c "cd '$ws' && $verify" > "$OUT/verify-$id.log" 2>&1
  rc=$?

  printf '%s\n' "$answer" > "$OUT/answer-$id.txt"
  printf 'workspace %s\nusage %s\nelapsed_ms %s\nverify_rc %s\n' "$ws" "$usage" "$PROBE_ELAPSED_MS" "$rc" \
    >> "$OUT/verify-$id.log"

  if [ "$rc" -eq 0 ]; then
    PASS=$(( PASS + 1 ))
    probe_ok "$id — workspace says it was done (${usage}, ${PROBE_ELAPSED_MS}ms)"
  else
    probe_fail "$id — workspace says it was NOT done (verify rc $rc; answer: $(printf '%.120s' "$answer"))"
  fi
done

probe_note "TASK SUCCESS $PASS/$RUN (of $TASK_COUNT loaded; a refusal to run is not a pass)"
probe_summary "$PROBE_NAME"
