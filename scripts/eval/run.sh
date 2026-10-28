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
# Two sets share this runner: the default 39-task set and the frozen 52-task edit-repair set the
# A/B loop judges with. The floor sits under both so a silently truncated set still goes red —
# measured 10-24 against the loaded sets (`_eval.py count`), and raised with them: 30 covered a
# 36/40 pair; 34 covers the 39/52 pair loaded today, so the frozen set losing eighteen tasks is a
# failure and the default set losing five is a failure. Screening pools override this env rather
# than the default.
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

# Which instruction doc this arm hands the workspace. `WorkspaceContext.buildSection` injects
# `<workspace>/AGENTS.md` into the system prompt, so this is the paired arm the goal asks for: the
# same 39 tasks, the same tools, the same checkpoint, with and without the corpus an agent loads
# before it types. `none` is the board's whole history and is stated as a value, not left blank.
#   OCOREAI_EVAL_DOCS=none | root | /abs/path/to/AGENTS.md
: "${OCOREAI_EVAL_DOCS:=none}"
DOCS_BYTES=0
DOCS_ARG=none
case "$OCOREAI_EVAL_DOCS" in
  none)
    # A reused workspace must not carry a doc over from another arm — an inherited doc measures the
    # previous experiment while reporting this one.
    for stale in "$EVAL_WS/AGENTS.md" "$EVAL_WS/AGENTS.override.md" "$EVAL_WS/AGENTS.inert.md"; do
      if [ -e "$stale" ]; then
        rm -f "$stale"
        probe_note "removed $stale — OCOREAI_EVAL_DOCS=none says this arm saw no instruction doc"
      fi
    done
    ;;
  root)
    DOCS_SRC="$(cd "$HERE/../.." && pwd)/AGENTS.md"
    ;;
  *)
    DOCS_SRC="$OCOREAI_EVAL_DOCS"
    ;;
esac
if [ "$OCOREAI_EVAL_DOCS" != "none" ]; then
  if [ ! -s "$DOCS_SRC" ]; then
    probe_fail "OCOREAI_EVAL_DOCS=$OCOREAI_EVAL_DOCS names no readable non-empty doc ($DOCS_SRC) —" \
      "the arm would measure nothing while reporting a doc, which is the vacuous comparison this" \
      " harness exists to refuse"
    # An arm that cannot be substantiated at boot must not reach the score line: the board would
    # print a number labelled `with_docs` that is a `none` run. `probe_summary` exits non-zero.
    probe_summary "$PROBE_NAME"
  fi
  DOCS_BYTES=$(wc -c < "$DOCS_SRC" | tr -d ' ')
  probe_require_int "doc size" "$DOCS_BYTES"
  # `OCOREAI_EVAL_DOCS_INERT=1` separates the two causes the corpus A/B cannot otherwise tell apart:
  # the bytes *being injected* vs the bytes merely *being in the workspace*. `WorkspaceContext` reads
  # exactly `AGENTS.override.md` / `AGENTS.md`, so a copy named `AGENTS.inert.md` sits in the tree the
  # agent works in and reaches no prompt — the floor below asserts that from the run itself (the
  # injected name never present + the `systemChars` span stays in the doc-free band), not from a claim.
  DOCS_TARGET="$EVAL_WS/AGENTS.md"
  if [ "${OCOREAI_EVAL_DOCS_INERT:-0}" = "1" ]; then
    DOCS_TARGET="$EVAL_WS/AGENTS.inert.md"
    probe_note "inert arm: bytes land as $(basename "$DOCS_TARGET") — in the workspace, undiscoverable"
  fi
  DOCS_ARG="$DOCS_TARGET"
  probe_note "docs arm: $DOCS_SRC -> $DOCS_TARGET ($DOCS_BYTES B, re-materialized per task)"
elif [ "${OCOREAI_EVAL_DOCS_INERT:-0}" = "1" ]; then
  probe_fail "OCOREAI_EVAL_DOCS_INERT=1 with OCOREAI_EVAL_DOCS=none asks for an inert doc that does" \
    " not exist — name the bytes (`root` or a path) or drop the inert flag"
  probe_summary "$PROBE_NAME"
fi

# The doc is written per task, not once at boot: the loop below wipes $EVAL_WS before every task,
# and a doc copied at boot is gone by the first wipe. Measured 10-27 — every turn assembled a
# doc-free prompt (systemChars=3002 against a 21,548 B doc) and only the premise floor said so.
# One home for the copy, called at boot and again after every wipe.
materialize_docs() {
  [ "$OCOREAI_EVAL_DOCS" = "none" ] && return 0
  cp "$DOCS_SRC" "$DOCS_TARGET"
}
materialize_docs
TOOLS_CACHE="$OUT/tools.json"

# A FAIL whose cause never reaches disk is a scoreboard nobody can root-cause: a native turn echoes
# no tool_calls, so `response-<id>.json` holds only the final text and the server log is the sole
# record of which tool ran, what it was asked, and what it answered. `_lib.sh` deletes that log on
# cleanup unless told to keep it (measured 10-27: a task that failed with "the tool execution
# failed" could not be explained from any artefact), so keep it and ship it beside the run's rows.
export OCOREAI_PROBE_KEEP_LOGS=1
# Registered through `probe_atexit`, NOT a raw `trap … EXIT`: bash keeps one handler per signal, so a
# trap here silently replaces `probes_cleanup` and the board's own serve is left holding the
# single-instance lock. Measured 10-27: after a full-surface arm finished, an orphaned release `serve`
# (pid 97436) survived, and the next `repeat.sh` refused at its pre-flight — the class `_lib.sh`
# documents at probe_atexit, reproduced by the file that ships the harness.
probe_atexit 'if [ -n "${PROBE_LOG:-}" ] && [ -f "$PROBE_LOG" ]; then cp -f "$PROBE_LOG" "$OUT/server.log" 2>/dev/null; fi'
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

# One rung further on the same class: the cost figures are computed from the rows this run is
# about to write, so the parser is judged on hand-computable fixtures before the boot — including
# the trap where a `# efficiency` line lands after `# score` and silently becomes the score.
if ! python3 "$HERE/_efficiency_selftest.py"; then
  echo "  FAIL  the scoreboard's cost figures are unsound — the cost of a verified success" \
    "would be a number nobody can check" >&2
  exit 1
fi

# Which artefact answered, and whether it can even be the artefact this tree describes. A verdict is
# a claim about a *build*, while `_lib.sh` resolves whatever binary sits on disk: measured 10-27, a
# board scored a tree whose sources were four hours newer than the binary it ran, and `results.tsv`
# had no field that could show it. Deliberately judging an older build is allowed — say so.
EVAL_BIN="$(probe_resolve_binary 2>/dev/null)"
if [ -z "$EVAL_BIN" ]; then
  probe_fail "no ocoreai artefact resolved — the conditions line would record the answering build as" \
    " `unknown`, so no later run could tell whether it matched this one"
  probe_summary "$PROBE_NAME"
fi
BIN_MTIME="$(stat -f %m "$EVAL_BIN")"
SRC_MTIME="$(git -C "$PROBE_REPO_ROOT" ls-files -z -- Sources Package.swift | xargs -0 stat -f %m \
  | sort -n | tail -1)"
probe_require_int "newest tracked source mtime" "$SRC_MTIME"
probe_note "artefact $EVAL_BIN · mtime $BIN_MTIME · newest tracked source mtime $SRC_MTIME"
if [ "$BIN_MTIME" -lt "$SRC_MTIME" ] && [ "${OCOREAI_EVAL_ALLOW_STALE_BIN:-}" != "1" ]; then
  probe_fail "the artefact predates the tree it is being scored against (binary mtime $BIN_MTIME" \
    "< newest source $SRC_MTIME) — build first (swift build -c release), or set" \
    " OCOREAI_EVAL_ALLOW_STALE_BIN=1 to judge an older build on purpose"
  probe_summary "$PROBE_NAME"
fi

probe_boot

# A score is a claim about a model, so this refuses to run at all when the turn was replayed.
# `ScriptedInference` exists to decide wire-contract claims without Metal; a scoreboard read from
# it would publish "the agent finished 30 real coding jobs" about a JSON file. The check reads the
# surface instead of the environment, so a scripted server someone else started is refused too.
if probe_api GET /v1/capabilities; then
  BACKEND="$(probe_json "$PROBE_BODY" 'engineBackend')"
  if [ "${BACKEND:-}" = "scripted" ]; then
    probe_fail "engineBackend=scripted — /v1/chat/completions here replays a script, so any score" \
      "printed from it would be a claim about a model that never ran. Unset OCOREAI_SCRIPTED_ENGINE."
    probe_summary "$PROBE_NAME"
  fi
  probe_note "engineBackend=${BACKEND:-unknown} — a real engine, so a score here describes a model"
fi

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
  --tools "$OCOREAI_EVAL_TOOLS" --approval "$OCOREAI_APPROVAL_POLICY" \
  --docs "$DOCS_ARG" --binary "$EVAL_BIN" 2>"$LOADER_ERR")"
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
  materialize_docs
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

# What a verified success cost, derived from the rows above: cost is summed over every attempt
# (a failed turn spent its seconds and its tokens) and every quotient is printed next to its
# denominator. This line goes BEFORE the score on purpose — `_repeat_stats._read_run` takes the
# last `#` line as the score, and _efficiency_selftest.py demonstrates the displaced reading.

# The same reasoning prices the surface every turn carried: the tool declarations are prompt bytes
# the model may never use, and until now their cost was unprinted while every registered tool rode
# each turn. Written after the rows (so an aborted run cannot leave a `#` line that
# `_read_run` would read as the score) and before the score, like the cost line.
SURFACE="$(python3 "$HERE/_eval.py" surface "$OCOREAI_EVAL_TOOLS" 2>"$LOADER_ERR")"
if [ -z "$SURFACE" ]; then
  probe_fail "could not derive the tool-surface figures for this run ($(tail -n 1 "$LOADER_ERR")) —" \
    "a score that cannot say how many prompt bytes its own tool declarations cost prices half the" \
    " experiment, so nothing is written"
  probe_summary "$PROBE_NAME"
fi
printf '# surface %s\n' "$SURFACE" >> "$RESULTS"
probe_note "$SURFACE"

EFFICIENCY="$(python3 "$HERE/_eval.py" efficiency "$RESULTS" 2>"$LOADER_ERR")"
if [ -z "$EFFICIENCY" ]; then
  probe_fail "could not derive the cost figures for this run ($(tail -n 1 "$LOADER_ERR")) — a" \
    "score nobody can price is not comparable with the run before it, so nothing is written"
  probe_summary "$PROBE_NAME"
fi
printf '# efficiency %s\n' "$EFFICIENCY" >> "$RESULTS"
probe_note "$EFFICIENCY"

# Premise floor, and it is the arm's whole claim: a `with_docs` run whose system prompt did not grow
# by at least the doc's own bytes measured nothing but noise. `Assembled prompt […]: … systemChars=N`
# is the server's own log line, so this reads the engine's word rather than inferring from a file
# that happened to be on disk.
if [ "$OCOREAI_EVAL_DOCS" != "none" ]; then
  # Every assembled prompt, not the first one: a doc that reached turn 1 and vanished for the rest
  # of the board would still pair two different instruments under one label.
  CHARS="$(grep -oE 'systemChars=[0-9]+' "$PROBE_LOG" 2>/dev/null | cut -d= -f2)"
  CHARS_N="$(printf '%s\n' "$CHARS" | grep -c '[0-9]')"
  CHARS_MIN="$(printf '%s\n' "$CHARS" | sort -n | head -1)"
  CHARS_MAX="$(printf '%s\n' "$CHARS" | sort -n | tail -1)"
  if [ -z "$CHARS_MIN" ]; then
    probe_fail "no 'Assembled prompt … systemChars=' line in the server log — the arm cannot show" \
      " whether the doc reached the prompt, so its score is not attributable to a doc"
  elif [ "${OCOREAI_EVAL_DOCS_INERT:-0}" = "1" ]; then
    # The inert arm's claim is the opposite: the bytes were in the workspace and reached no prompt.
    # `WorkspaceContext` discovers exactly `AGENTS.override.md` / `AGENTS.md` (the candidate list, with
    # `WorkspaceContextTests` pinning the contract), so the decisive run-side facts are that the
    # injected name never existed while the inert bytes did. The span is printed because it is the
    # behavioural witness: those same bytes injected move it by their own size (measured 10-27 — 2,442 B
    # injected lands at 5,543..6,500 against a doc-free 2,7xx..3,9xx).
    if [ -e "$EVAL_WS/AGENTS.md" ] || [ ! -e "$DOCS_TARGET" ]; then
      probe_fail "the inert arm is not inert: $DOCS_TARGET present=$([ -e "$DOCS_TARGET" ] && echo yes || echo no)" \
        " but $EVAL_WS/AGENTS.md present=$([ -e "$EVAL_WS/AGENTS.md" ] && echo yes || echo no) — the bytes" \
        " may have been discovered, so this arm cannot separate injection from mere presence"
    else
      probe_ok "the bytes sat in the workspace undiscovered ($DOCS_BYTES B as" \
        " $(basename "$DOCS_TARGET"), no AGENTS.md) — $CHARS_N prompt(s) assembled at" \
        " systemChars $CHARS_MIN..$CHARS_MAX"
    fi
  elif [ "$CHARS_MIN" -lt "$DOCS_BYTES" ]; then
    probe_fail "the doc did not reach every turn: $CHARS_N assembled prompt(s), smallest" \
      " systemChars=$CHARS_MIN < the $DOCS_BYTES B doc (largest $CHARS_MAX) — a turn smaller than" \
      " the doc is a `none` turn wearing a doc label, so this arm is not paired with anything"
  else
    probe_ok "the doc reached every turn ($CHARS_N assembled prompt(s), systemChars $CHARS_MIN..$CHARS_MAX" \
      " ≥ $DOCS_BYTES B) — the arm is real"
  fi
fi

printf '# score %s/%s  model %s\n' "$PASS" "$RUN" "$PROBE_MODEL" >> "$RESULTS"
probe_note "results $RESULTS"
probe_note "TASK SUCCESS $PASS/$RUN (of $TASK_COUNT loaded; a refusal to run is not a pass)"
probe_summary "$PROBE_NAME"
