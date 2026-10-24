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
: "${OCOREAI_EVAL_TOOLS:=read_file write_file edit_file edit_lines search_files exec_command}"
export OCOREAI_EVAL_TOOLS
# Two sets share this runner: the default 36-task set and the frozen 52-task edit-repair set the
# A/B loop judges with. The floor sits under both so a silently truncated set still goes red —
# measured 10-24 against the loaded sets (`_eval.py count`), and raised with them: 30 covered a
# 36/40 pair, 34 covers a 36/52 pair, so the scored set losing eighteen tasks is a failure and the
# default set losing two is a failure. Screening pools override this env rather than the default.
: "${OCOREAI_EVAL_FLOOR_TASKS:=34}"
: "${OCOREAI_EVAL_FLOOR_SPECS:=4}"
# A family floor is a different question from a total floor: 24 tasks with zero edit tasks is
# still a shrunken instrument. Measured 10-22 over tasks.json: the smallest family has 2.
: "${OCOREAI_EVAL_FLOOR_FAMILY:=2}"

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

# The task set is the instrument, so it is proven before the server is even booted (a loader that
# crashes should not cost a boot and leave a server behind), and the loader's stderr travels into
# the refusal instead of being left on the terminal.
LOADER_ERR="$(mktemp -t ocoreai-eval-loader-XXXXXX)"
TASK_COUNT="$(python3 "$HERE/_eval.py" count 2>"$LOADER_ERR")"
probe_require_int "_eval.py count" "$TASK_COUNT" "$(tail -n 1 "$LOADER_ERR")"

# The guard proves its own premise: fed an empty value it must fail. A guard that only fires when
# someone remembers to look is the hole it was written to close.
if (probe_require_int "self-test" "" >/dev/null 2>&1); then
  echo "  FAIL  probe_require_int let an empty value through — the crash path is open again" >&2
  exit 1
fi

# The B/B′ ledger is the record every resolution claim cites, and it drifted the round the task set
# grew (table said 14, the paragraph under it still said "short of target"), so its digits are
# re-derived from the table here rather than trusted. No Metal, no server: it runs before the boot.
if ! python3 "$HERE/_ledger_selftest.py"; then
  echo "  FAIL  scripts/eval/README.md's B/B′ ledger does not follow from its own digits — a verdict" \
    "citing a number the ledger cannot reproduce would be prose wearing a measurement" >&2
  exit 1
fi

# Same class, one rung up: a quoted `# score N/M` is only attributable when the line naming what
# produced it is in the file, and `_repeat_stats.py` refuses to average runs whose conditions
# differ. `_conditions_selftest.py` re-derives both from bytes (no server, no GPU), so it runs
# next to the ledger check, before the boot.
if ! python3 "$HERE/_conditions_selftest.py"; then
  echo "  FAIL  the scoreboard's conditions line is unsound or unwired — a score that cannot name" \
    "its task set, tool set, model, sampling, approval policy and host would be averaged against" \
    "runs played under other rules" >&2
  exit 1
fi

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

# The verifiers are the instrument, so they get audited before a single model turn runs: each
# task is scored against a solved workspace, an untouched one and (where applicable) a
# fabricated answer. Vacuous verifiers take about a second to find and need no Metal.
if ! python3 "$HERE/_verifier_selftest.py"; then
  probe_fail "the scoreboard's own verifiers are not sound (see _verifier_selftest.py above) —" \
    "scores from a verifier that cannot fail would be a harness bug wearing a model score"
  probe_summary "$PROBE_NAME"
fi

SPEC_COUNT="$(python3 "$HERE/_eval.py" spec-count "$OCOREAI_EVAL_TOOLS" 2>"$LOADER_ERR")"
probe_require_int "_eval.py spec-count" "$SPEC_COUNT" "$(tail -n 1 "$LOADER_ERR")"

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
FAMILIES="$(python3 "$HERE/_eval.py" families | tr '\n' ' ')"
while IFS= read -r line; do
  fam="${line%%=*}"
  fam_n="${line##*=}"
  probe_require_int "family $fam task count" "$fam_n"
  if [ "$fam_n" -lt "$OCOREAI_EVAL_FLOOR_FAMILY" ]; then
    probe_fail "family $fam has only $fam_n task(s) (floor $OCOREAI_EVAL_FLOOR_FAMILY) — a whole" \
      "capability family missing from the set is a shrunken instrument, not a model result"
  fi
done < <(python3 "$HERE/_eval.py" families)
probe_note "scoreboard $TASK_COUNT tasks · $SPEC_COUNT tool(s) declared by the server · model $PROBE_MODEL"
probe_note "families $FAMILIES"
probe_note "traces $OUT"
RESULTS="$OUT/results.tsv"
printf 'task\tkind\trc\telapsed_ms\tusage\n' > "$RESULTS"

# What produced this number, written before any score line: `load_runs` keeps the last `#` line
# as the score, so the score must stay last. `_conditions.py` digests the task file and the
# server's own tool declarations, and `field_diffs` is what `_repeat_stats.py` refuses on.
CONDITIONS="$(python3 "$HERE/_conditions.py" --model "$PROBE_MODEL" \
  --tools "$OCOREAI_EVAL_TOOLS" --approval "$OCOREAI_APPROVAL_POLICY" 2>"$LOADER_ERR")"
if [ -z "$CONDITIONS" ]; then
  probe_fail "could not derive the conditions line for this run ($(tail -n 1 "$LOADER_ERR")) — a" \
    "score with no conditions behind it cannot be compared with any other run, so it is not written"
  probe_summary "$PROBE_NAME"
fi
printf '# conditions %s\n' "$CONDITIONS" >> "$RESULTS"
probe_note "$CONDITIONS"

PASS=0
RUN=0
# A request that never reached the engine is not a model failure. Measured 10-22: one run
# lost 13 consecutive tasks to `Generation failed: Engine busy` in 4 seconds (an abandoned
# request held the inference lock for ~160 s), the run scored 7/23, and `repeat.sh` averaged
# it in — McNemar then reported a *significant* p=0.0032 regression that was an outage.
# A scoreboard that turns infrastructure faults into model scores is worse than no scoreboard.
FAULTS=0
: > "$OUT/faults.txt"
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
  kind="$(python3 "$HERE/_eval.py" field "$id" kind)"
  # Some verifiers compare the answer against what the machine says (uname, wc, pwd). The
  # expectation is a field of the task, so run.sh holds no per-id special case to drift, and
  # an expectation that computes empty is reported as the harness bug it is.
  expect=""
  expect_cmd="$(python3 "$HERE/_eval.py" field "$id" expect_cmd)"
  if [ -n "$expect_cmd" ]; then
    expect="$(cd "$ws" && bash -c "$expect_cmd")"
    [ -n "$expect" ] || probe_fail "$id declares expect_cmd but it produced no output — an empty" \
      "expectation would make the answer match anything"
  fi

  OCOREAI_EVAL_ANSWER="$answer" OCOREAI_EVAL_EXPECT="$expect" \
    bash -c "cd '$ws' && $verify" > "$OUT/verify-$id.log" 2>&1
  rc=$?

  printf '%s\n' "$answer" > "$OUT/answer-$id.txt"
  printf 'workspace %s\nusage %s\nelapsed_ms %s\nverify_rc %s\n' "$ws" "$usage" "$PROBE_ELAPSED_MS" "$rc" \
    >> "$OUT/verify-$id.log"

  # A verifier's rc says the workspace is wrong, never what the produced file said, and the next
  # task wipes the directory: without these bytes the cause of a failure dies with the session.
  # Passing tasks are snapshotted too — "it passed" is only evidence once the shape is on disk.
  snap="$OUT/artifacts-$id.txt"
  snap_bytes="$(python3 "$HERE/_eval.py" snapshot "$ws" "$snap" 2>&1)"
  probe_require_int "artefact snapshot for $id" "$snap_bytes"
  if [ "$snap_bytes" -lt 1 ]; then
    probe_fail "$id left an empty artefact snapshot ($snap_bytes bytes) — an instrument that loses" \
      "its own evidence is a harness fault wearing a model score"
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$rc" "$PROBE_ELAPSED_MS" "$usage" >> "$RESULTS"

  # No delivered turn (`finish=None`) or an engine-level refusal means this task was never
  # attempted. It stays in the file (the row count is the evidence), but it marks the run.
  case "$usage$PROBE_BODY" in
    *"finish=None"*|*"Engine busy"*|*"app_error"*)
      FAULTS=$(( FAULTS + 1 ))
      printf '%s %s\n' "$id" "$usage" >> "$OUT/faults.txt"
      ;;
  esac

  if [ "$rc" -eq 0 ]; then
    PASS=$(( PASS + 1 ))
    probe_ok "$id — workspace says it was done (${usage}, ${PROBE_ELAPSED_MS}ms)"
  else
    probe_fail "$id — workspace says it was NOT done (verify rc $rc; answer: $(printf '%.120s' "$answer"))"
  fi
done

if [ "$FAULTS" -gt 0 ]; then
  printf '# invalid faults=%s/%s model %s\n' "$FAULTS" "$RUN" "$PROBE_MODEL" >> "$RESULTS"
  probe_fail "$FAULTS of $RUN task(s) never reached the engine (see $OUT/faults.txt) — this run" \
    "is NOT a score. Read faults.txt for the refusal; re-run once the cause is gone, and" \
    "_repeat_stats.py will exclude an invalid run rather than average it into a trend."
  probe_note "results $RESULTS"
  probe_note "TASK SUCCESS NOT MEASURED ($FAULTS/$RUN tasks faulted; $PASS delivered passes)"
  exit 1
fi

printf '# score %s/%s  model %s\n' "$PASS" "$RUN" "$PROBE_MODEL" >> "$RESULTS"
probe_note "results $RESULTS"
probe_note "TASK SUCCESS $PASS/$RUN (of $TASK_COUNT loaded; a refusal to run is not a pass)"
probe_summary "$PROBE_NAME"
