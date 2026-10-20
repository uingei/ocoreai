#!/usr/bin/env bash
# 21-sleep-steer-wake.sh — does input for THIS conversation end clock.sleep's wait on the
# wire, does the injected text actually reach the model in that same turn, and does input for
# ANOTHER conversation leave the wait alone?
#
# ### Why (AGENTS.md invariant 2 + § Endpoint Promises: accept-then-deliver needs a live probe)
# `clock.sleep` tells the model, in its own description, that "the wait ends early when new
# input arrives for this conversation". That sentence is a capability a model reads and plans
# around. `SleepSteerWakeTests` pins the mechanism (100 ms cadence, check-before-sleep, whose
# key is published where) and both outcome wordings, but every one of those tests injects a
# fake backend or a hand-built SteerQueue entry — none of them put a byte on the wire. Until
# this file the sentence on the tool face had no measurement behind it, which is what AGENTS.md
# calls fiction.
#
# The second half cannot be tested offline at all. The wake is keyed by conversation
# (`ToolInvocationContext.conversationKey`, published at the single dispatch chokepoint
# `ToolRegistry.call`). A regression that swapped that key for a process-global flag keeps every
# unit test green — each unit test supplies its own key, so none can see the difference. Only
# two live conversations in one process can. Same family as the identical-call loop net, which
# also had to learn that a conversation, not a process, is the unit of identity.
#
# ### What is asserted
#   1. Premise: `sleep` is a tool this server owns (present in GET /v1/tools, scan floors its
#      own hit count), so these runs drive the built-in path, not a caller-owned handoff.
#   2. Premise: the CONTROL turn spends at least the duration it asked for, and quotes the
#      tool's own report back. Without this, "the steered turn was fast" would only mean the
#      checkpoint never slept.
#   3. Delivery: a steer injected after the wait began ends that turn far below its own
#      requested duration, and the injected text arrives inside the same turn
#      (`[mid-turn user steering]`) — accept-then-deliver, measured, not asserted.
#   4. Wording follows the measured outcome: steered => `interrupt`, control => `completed`.
#   5. Isolation: a steer accepted for a DIFFERENT session must not end this session's sleep.
#      Accepted != delivered; a cross-session wake is the leak SessionIsolationTests closed on
#      the pool side.
#   6. Wire arithmetic on every response: `prompt_tokens_details.cached_tokens` never exceeds
#      `prompt_tokens` (a breakdown cannot be larger than the whole it belongs to).
#
# ### Shape notes (both learned the hard way on 10-21, and they are why this file is verbose)
# * `tool_choice:"required"` is NOT the way to drive a built-in. Measured: with `required` the
#   engine hands the constrained call back to the caller and never dispatches it —
#   `finish_reason:"tool_calls"`, no `Tool call: sleep` line in the log — which is what an
#   OpenAI-compatible server is supposed to do with a caller-owned call. Only plain `auto`
#   reaches this server's internal dispatch for a tool its own registry implements, so
#   `tool_choice` is left absent here and the ask states the duration outright.
# * Identical (tool, arguments) pairs accumulate in the loop net, so all three legs ask for
#   DIFFERENT durations (9000 / 8000 / 7000 ms). Measured 10-21, four identical
#   `sleep(duration_ms:8000)` calls inside 60 s returned
#   `[tool_error: Execution loop detected: sleep] FAILED — its effects do not exist.` — first
#   across conversations, then (after that was scoped per conversation) still correct within one.
# * Timing carries the verdict because a tool result has no wire field: the structured
#   `ToolResultMeta` (resultSummary + durationMs) rides the reasoning-event stream to the GUI
#   (`emitToolResult` in EngineInference.swift) and stops there. The model's own echo of the
#   tool text is what the HTTP client can see, so the probe reads that for the outcome word.
# * Every leg gets its own session_id (no inherited transcript or pool slot) and temperature 0.
#   The steer is injected AFTER the request starts, so the head-of-handler drain
#   (`mergingSteeredTurn`) has already run and found an empty queue: a fast steered turn can
#   only come from the wake path.
#
# Run: bash scripts/probes/21-sleep-steer-wake.sh
# Knobs: OCOREAI_PROBE_SLEEP_MS (base duration, default 9000 — legs step down by 1000 ms),
#        OCOREAI_PROBE_STEER_DELAY (seconds, default 1.5)
PROBE_NAME="21-sleep-steer-wake"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

BASE_MS="${OCOREAI_PROBE_SLEEP_MS:-9000}"
STEER_DELAY="${OCOREAI_PROBE_STEER_DELAY:-1.5}"
CONTROL_MS_ASK="$BASE_MS"
STEER_MS_ASK=$(( BASE_MS - 1000 ))
FOREIGN_MS_ASK=$(( BASE_MS - 2000 ))
# A wake inside one poll interval leaves the whole duration minus generation to save; half of
# the requested wait keeps a real wake comfortably green while a no-op stays red.
STEER_SAVE_MS=$(( STEER_MS_ASK / 2 ))

now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

body_for() {  # <session_id> <duration_ms>
  python3 - "$PROBE_MODEL" "$1" "$2" <<'PY'
import json, sys
model, sid, ms = sys.argv[1:4]
ask = (
    "Call the sleep tool now with duration_ms %s. Do not answer before it returns. "
    "When it returns, repeat the text the tool gave you." % ms
)
print(json.dumps({
    "model": model,
    "session_id": sid,
    "max_tokens": 64,
    "temperature": 0.0,
    "messages": [{"role": "user", "content": ask}],
    "tools": [{
        "type": "function",
        "function": {
            "name": "sleep",
            "description": "Pause execution for a given number of milliseconds.",
            "parameters": {
                "type": "object",
                "properties": {"duration_ms": {"type": "integer",
                                             "description": "Milliseconds to pause"}},
                "required": ["duration_ms"],
            },
        },
    }],
}))
PY
}

TURN_PID=""
run_turn_async() {  # <session_id> <duration_ms> <outdir>
  local sid="$1" ms="$2" out="$3" body
  body="$(body_for "$sid" "$ms")"
  (
    local start end raw
    start="$(now_ms)"
    raw="$(curl -sS -m "${OCOREAI_PROBE_TURN_TIMEOUT:-180}" -X POST \
      -H 'Content-Type: application/json' --data "$body" \
      -w $'\n%{http_code}' "$PROBE_BASE/v1/chat/completions" 2>&1)" || true
    end="$(now_ms)"
    printf '%s' "$(( end - start ))" > "$out/elapsed_ms"
    printf '%s' "${raw##*$'\n'}" > "$out/code"
    printf '%s' "${raw%$'\n'*}" > "$out/body"
  ) &
  TURN_PID=$!
}

read_turn() {  # <outdir> -> TURN_MS / TURN_CODE / TURN_BODY
  local out="$1"
  wait "$TURN_PID" 2>/dev/null || true
  TURN_PID=""
  TURN_MS="$(cat "$out/elapsed_ms" 2>/dev/null || echo 0)"
  TURN_CODE="$(cat "$out/code" 2>/dev/null || echo 000)"
  TURN_BODY="$(cat "$out/body" 2>/dev/null || echo '')"
}

reply_of() { probe_json "$1" 'choices.0.message.content'; }

# usage_field BODY KEY -> integer or empty
usage_field() { probe_json "$1" "$2"; }

# check_usage_invariant LABEL BODY — cached_tokens <= prompt_tokens whenever both are present.
check_usage_invariant() {
  local label="$1" body="$2" p c
  p="$(usage_field "$body" 'usage.prompt_tokens')"
  c="$(usage_field "$body" 'usage.prompt_tokens_details.cached_tokens')"
  if [ -z "$p" ]; then
    probe_fail "$label: no usage.prompt_tokens on the wire — usage accounting is absent, not small"
  elif [ -z "$c" ]; then
    probe_note "$label: prompt_tokens=$p with no cached_tokens (no reuse observed on this turn)"
  elif [ "$c" -le "$p" ]; then
    probe_ok "$label: cached_tokens=$c <= prompt_tokens=$p (breakdown fits inside the whole)"
  else
    probe_fail "$label: cached_tokens=$c exceeds prompt_tokens=$p — the reused prefix is not counted in the prompt it belongs to (upstream totalPromptTokenCount = cached + prefilled)"
  fi
}

steer() {  # <session_id> <text> -> STEER_CODE / STEER_QUEUED
  local sid="$1" text="$2" q
  q="$(python3 -c 'import json,sys;print(json.dumps({"session_id":sys.argv[1],"text":sys.argv[2]}))' \
    "$sid" "$text")"
  probe_api POST /v1/steer "$q"
  STEER_CODE="${PROBE_STATUS:-000}"
  STEER_QUEUED="$(probe_json "${PROBE_BODY:-}" 'queued_count')"
}

probe_boot
probe_require_ready_model

WORKDIR="$(mktemp -d -t ocoreai-probe21-XXXXXX)"
probe_atexit 'rm -rf "$WORKDIR"'
mkdir -p "$WORKDIR/control" "$WORKDIR/steer" "$WORKDIR/foreign"

S_CONTROL="PROBE21-CTRL-$$"
S_STEER="PROBE21-STEER-$$"
S_SLEEPER="PROBE21-SLEEPER-$$"
S_OTHER="PROBE21-OTHER-$$"

probe_section "setup (model=$PROBE_MODEL · control asks ${CONTROL_MS_ASK}ms, steered ${STEER_MS_ASK}ms, foreign ${FOREIGN_MS_ASK}ms · steer at ${STEER_DELAY}s)"

# ── 1. premise: sleep is a tool this server owns ───────────────────────────────
probe_api GET /v1/tools || true
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "GET /v1/tools -> ${PROBE_STATUS:-no response}"
else
  TOOL_LIST="$(python3 - "${PROBE_BODY:-}" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
items = d if isinstance(d, list) else d.get("tools", d.get("data", []))
names = [t.get("function", {}).get("name") or t.get("name") for t in items if isinstance(t, dict)]
print(len(names))
print(" ".join(n for n in names if n))
PY
)"
  TOOL_HITS="$(printf '%s' "$TOOL_LIST" | head -1)"
  TOOL_NAMES="$(printf '%s' "$TOOL_LIST" | tail -1)"
  # Floor the scan's own hit count: with an empty name list "sleep is absent" and "the parser
  # stopped working" are indistinguishable (invariant 1).
  if [ -z "$TOOL_HITS" ] || [ "$TOOL_HITS" -lt 5 ]; then
    probe_fail "GET /v1/tools parsed only ${TOOL_HITS:-0} tool name(s) — the premise scan is broken, not the tool"
  else
    probe_ok "/v1/tools lists $TOOL_HITS tool(s)"
    case " $TOOL_NAMES " in
      *" sleep "*) probe_ok "sleep is a built-in this server owns (of $TOOL_HITS declared)" ;;
      *) probe_fail "sleep not in GET /v1/tools — this probe would drive a caller-owned handoff, not the built-in wake path" ;;
    esac
  fi
fi

# ── 2. warm-up so model load is not attributed to a measured leg ──────────────
mkdir -p "$WORKDIR/warm"
run_turn_async "PROBE21-WARM-$$" 500 "$WORKDIR/warm"
read_turn "$WORKDIR/warm"
probe_note "warm-up turn ${TURN_MS}ms (model load is paid here, not inside a measured leg)"

# ── 3. control: nobody interrupts ──────────────────────────────────────────────
probe_section "leg 1 — control: sleep ${CONTROL_MS_ASK}ms, nobody interrupts ($S_CONTROL)"
run_turn_async "$S_CONTROL" "$CONTROL_MS_ASK" "$WORKDIR/control"
read_turn "$WORKDIR/control"
if [ "$TURN_CODE" != "200" ]; then
  probe_fail "control turn -> $TURN_CODE: $(printf '%s' "$TURN_BODY" | head -c 200)"
  probe_summary "$PROBE_NAME"
fi
CONTROL_MS="$TURN_MS"
CONTROL_REPLY="$(reply_of "$TURN_BODY")"
probe_note "control: ${CONTROL_MS}ms for ${CONTROL_MS_ASK}ms requested — reply: ${CONTROL_REPLY:0:140}"
check_usage_invariant "control" "$TURN_BODY"

if [ "$CONTROL_MS" -ge "$CONTROL_MS_ASK" ]; then
  probe_ok "premise held: the checkpoint really slept (${CONTROL_MS}ms >= ${CONTROL_MS_ASK}ms asked)"
else
  probe_fail "premise FAILED: control returned ${CONTROL_MS}ms for ${CONTROL_MS_ASK}ms requested — the built-in sleep did not run, so nothing below can certify a wake (reply: ${CONTROL_REPLY:0:160})"
fi

ECHOES=0
case "$(lower "$CONTROL_REPLY")" in
  *"wall time"*) ECHOES=1; probe_ok "control echoes the tool's own report — the outcome-word checks have a premise" ;;
  *) probe_note "control does not quote the tool report — outcome-word checks skipped for this checkpoint (timing still carries the verdict)" ;;
esac

# ── 4. delivery: steer this session mid-wait ───────────────────────────────────
probe_section "leg 2 — steer $S_STEER ${STEER_DELAY}s into a ${STEER_MS_ASK}ms wait"
run_turn_async "$S_STEER" "$STEER_MS_ASK" "$WORKDIR/steer"
sleep "$STEER_DELAY"
steer "$S_STEER" "Stop waiting and report what happened."
STEER_CODE_R="$STEER_CODE"
STEER_QUEUED_R="$STEER_QUEUED"
read_turn "$WORKDIR/steer"
if [ "$TURN_CODE" != "200" ]; then
  probe_fail "steered turn -> $TURN_CODE: $(printf '%s' "$TURN_BODY" | head -c 200)"
fi
STEER_MS="$TURN_MS"
STEER_REPLY="$(reply_of "$TURN_BODY")"
probe_note "steered: ${STEER_MS}ms for ${STEER_MS_ASK}ms requested (steer -> HTTP $STEER_CODE_R queued_count=${STEER_QUEUED_R:-?}) — reply: ${STEER_REPLY:0:140}"
check_usage_invariant "steered" "$TURN_BODY"

if [ "$STEER_CODE_R" = "200" ] && [ "${STEER_QUEUED_R:-0}" -ge 1 ]; then
  probe_ok "/v1/steer accepted the injection (queued_count=${STEER_QUEUED_R})"
else
  probe_fail "/v1/steer did not accept the injection (HTTP $STEER_CODE_R, queued_count=${STEER_QUEUED_R:-none}) — a fast steered turn would be luck, not delivery"
fi

if [ "$CONTROL_MS" -ge "$CONTROL_MS_ASK" ]; then
  if [ "$STEER_MS" -lt "$STEER_MS_ASK" ] && [ $(( STEER_MS_ASK - STEER_MS )) -ge "$STEER_SAVE_MS" ]; then
    probe_ok "delivery: the steer ended the wait — ${STEER_MS}ms for a ${STEER_MS_ASK}ms request (saved $(( STEER_MS_ASK - STEER_MS ))ms, needed ${STEER_SAVE_MS}ms)"
  else
    probe_fail "NO EARLY WAKE: steered turn took ${STEER_MS}ms for a ${STEER_MS_ASK}ms request (needed to save ${STEER_SAVE_MS}ms) — input queued for a conversation does not end this conversation's sleep"
  fi
else
  probe_note "delivery check skipped: the control never spent its duration, so there is no baseline to compare against"
fi

# The injected text must arrive in THIS turn, not merely be accepted into a queue.
case "$STEER_REPLY" in
  *"[mid-turn user steering]"*) probe_ok "the injected text reached the model inside the same turn ([mid-turn user steering] present in the reply)" ;;
  *) probe_fail "the injected text never arrived in the reply — reply was: ${STEER_REPLY:0:200}" ;;
esac

if [ "$ECHOES" = "1" ]; then
  case "$(lower "$STEER_REPLY")" in
    *interrupt*) probe_ok "steered turn reports the interruption in the tool's own words" ;;
    *) probe_fail "steered turn did not report an interruption — reply was: ${STEER_REPLY:0:200} (a woken sleep must say \`Sleep interrupted by new input.\`, not claim a full sleep)" ;;
  esac
  case "$(lower "$CONTROL_REPLY")" in
    *complete*) probe_ok "control reports \`Sleep completed.\` — the full-duration wording is intact" ;;
    *) probe_fail "control did not report completion — reply was: ${CONTROL_REPLY:0:200}" ;;
  esac
fi

# ── 5. isolation: another conversation's input must not wake this one ───────────
probe_section "leg 3 — sleeper $S_SLEEPER (${FOREIGN_MS_ASK}ms), steer aimed at $S_OTHER"
run_turn_async "$S_SLEEPER" "$FOREIGN_MS_ASK" "$WORKDIR/foreign"
sleep "$STEER_DELAY"
steer "$S_OTHER" "Input that belongs to a different conversation."
FOREIGN_CODE_R="$STEER_CODE"
FOREIGN_QUEUED_R="$STEER_QUEUED"
read_turn "$WORKDIR/foreign"
if [ "$TURN_CODE" != "200" ]; then
  probe_fail "isolated turn -> $TURN_CODE: $(printf '%s' "$TURN_BODY" | head -c 200)"
fi
FOREIGN_MS="$TURN_MS"
FOREIGN_REPLY="$(reply_of "$TURN_BODY")"
probe_note "isolated: ${FOREIGN_MS}ms for ${FOREIGN_MS_ASK}ms requested (foreign steer -> HTTP $FOREIGN_CODE_R queued_count=${FOREIGN_QUEUED_R:-?}) — reply: ${FOREIGN_REPLY:0:140}"
check_usage_invariant "isolated" "$TURN_BODY"

if [ "$FOREIGN_CODE_R" = "200" ] && [ "${FOREIGN_QUEUED_R:-0}" -ge 1 ]; then
  probe_ok "the foreign steer was accepted (queued_count=${FOREIGN_QUEUED_R}) — this leg cannot be explained by a dropped injection"
else
  probe_fail "foreign steer not accepted (HTTP $FOREIGN_CODE_R) — the isolation leg has no injection to withhold, and proves nothing"
fi
if [ "$FOREIGN_MS" -ge "$FOREIGN_MS_ASK" ]; then
  probe_ok "isolation: this conversation slept through another conversation's input (${FOREIGN_MS}ms >= ${FOREIGN_MS_ASK}ms)"
else
  probe_fail "CROSS-SESSION WAKE: a steer for $S_OTHER ended $S_SLEEPER's sleep after ${FOREIGN_MS}ms of a ${FOREIGN_MS_ASK}ms request — the wake condition is not scoped to the owning conversation (reply: ${FOREIGN_REPLY:0:160})"
fi

probe_note "MEASURED: control ${CONTROL_MS}ms/${CONTROL_MS_ASK}ms · steered ${STEER_MS}ms/${STEER_MS_ASK}ms · foreign-steered ${FOREIGN_MS}ms/${FOREIGN_MS_ASK}ms (poll cadence 100ms, steer injected at ${STEER_DELAY}s)"

probe_summary "$PROBE_NAME"
