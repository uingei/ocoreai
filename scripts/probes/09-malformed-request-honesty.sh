#!/usr/bin/env bash
# 09-malformed-request-honesty.sh — can one bad number in a request body kill the server?
#
# ### Why (AGENTS.md invariant 1: a claim is worth the gate that goes red when it breaks)
# Measured 10-17 against a live server:
#
#   POST /v1/chat/completions {"model":…,"messages":[…],"max_tokens":-5}
#
# produced NO response at all. The process died with EXC_BREAKPOINT (SIGTRAP) inside
# SchedulerActor.dispatch(), where UInt64(request.tokenBudget) traps on a negative. Every
# other conversation on the box went with it, and the client got an empty reply with no
# status, no error body and no remediation. A trap is not a refusal.
#
# The quieter sibling: max_tokens=0 answered 200 OK with an empty completion — the surface
# claiming it had generated something when it generated nothing.
#
# ### What this probe locks down
#   1. NAMED REFUSAL — each out-of-domain knob comes back 400 with error.param naming the
#      field and the message echoing the value that was sent (the shape vllm publishes:
#      vllm/sampling_params.py:630-712 for the ranges, its validation handler for `param`).
#   2. SURVIVAL — after every refusal the server is still there: /health answers, and a
#      normal request with a code word still returns that code word. This is the actual
#      regression gate; a probe that only checked the 400 would have passed on a server
#      that died right after printing it.
#   3. NO PHANTOM 200 — max_tokens=0 is a refusal, not a 200 with empty content.
#   4. PER-WIRE BOUNDS — temperature 1.5 is legal on /v1/chat/completions ([0, 2]) and
#      refused on /v1/messages ([0, 1]). Per-wire ranges, one checker.
#
# Needs a real Metal device for the survival turns (a live generation), so run it
# unsandboxed: `bash scripts/probes/run.sh 09`, the same route `make test-clt` uses.
#
# JSON bodies are built by single-quote concatenation, never by nested quoted command
# substitutions: bash 3.2 (the /usr/bin/env bash on macOS) mis-parses
# `cmd "$(other "…\"key\"…")"` and hands the helper a truncated array — measured 10-18,
# where it produced this probe's only failure on its first run, in the harness, not the
# server. Probe 01 already avoids it the same way (scripts/probes/01-prefix-accounting.sh:59).
#
# Run: bash scripts/probes/09-malformed-request-honesty.sh
PROBE_NAME="09-malformed-request-honesty"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

CODE_WORD="PARAPET"
SESSION="probe09-$$"
SURVIVOR_MSGS='[{"role":"user","content":"Reply with exactly the word '"$CODE_WORD"' and nothing else."}]'
SHORT_MSGS='[{"role":"user","content":"hi"}]'
ZERO_MSGS='[{"role":"user","content":"Say hello."}]'

probe_boot
probe_require_ready_model

# ── helpers ────────────────────────────────────────────────────────────────────

field() { probe_json "$PROBE_BODY" "$1"; }

# One malformed request must come back 400, naming the field and echoing the value,
# and must leave the server alive and answering a normal turn.
#
#   $1 label      what is being refused
#   $2 path       endpoint
#   $3 body       malformed JSON
#   $4 param      error.param expected
#   $5 value      the value the message must echo
refusal_case() {
  local label="$1" path="$2" body="$3" param="$4" value="$5"
  if ! probe_api POST "$path" "$body"; then
    probe_fail "$label — curl could not reach the server (status ${PROBE_STATUS}): the process died on this body"
    return
  fi
  if [ "${PROBE_STATUS}" != "400" ]; then
    probe_fail "$label -> ${PROBE_STATUS}, expected 400. Body: $(printf %.220s "$PROBE_BODY")"
    return
  fi
  local got_param got_message
  got_param="$(field error.param)"
  got_message="$(field error.message)"
  if [ "$got_param" != "$param" ]; then
    probe_fail "$label -> 400 but error.param is [$got_param], expected [$param]: $got_message"
    return
  fi
  case "$got_message" in
    *"got $value"*) ;;
    *)
      probe_fail "$label -> message must echo the value sent (got $value): $got_message"
      return
      ;;
  esac
  probe_ok "$label -> 400 param=$param, message names the rule and echoes $value"

  # The part that matters: the refusal must not cost the server.
  local health survivor_body text
  health="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$PROBE_BASE/health" 2>/dev/null || echo 000)"
  if [ "$health" != "200" ]; then
    probe_fail "$label: /health now answers $health — the refusal took the process with it"
    return
  fi
  survivor_body="$(probe_chat_body "$SESSION" "$SURVIVOR_MSGS" 16)"
  if ! probe_chat "$SESSION" "$survivor_body"; then
    probe_fail "$label: server unreachable on the request right after the refusal (status ${PROBE_STATUS})"
    return
  fi
  text="$(field choices.0.message.content)"
  if [ "${PROBE_STATUS}" != "200" ]; then
    probe_fail "$label: normal request after refusal -> ${PROBE_STATUS}: $(printf %.200s "$PROBE_BODY")"
    return
  fi
  case "$text" in
    *"$CODE_WORD"*)
      probe_ok "$label: server still serving real generations afterwards (${PROBE_ELAPSED_MS} ms, code word present)"
      ;;
    *)
      probe_fail "$label: 200 after refusal but the code word is missing — content [$text]"
      ;;
  esac
}

# ── 1. named refusals, each followed by a survival turn ───────────────────────
probe_section "1 — out-of-domain numbers get a named 400, and the server survives each one"

refusal_case "chat max_tokens=-5" /v1/chat/completions \
  "{\"model\":\"$PROBE_MODEL\",\"session_id\":\"$SESSION\",\"messages\":$SHORT_MSGS,\"max_tokens\":-5}" \
  "max_tokens" "-5"

refusal_case "chat max_completion_tokens=-1" /v1/chat/completions \
  "{\"model\":\"$PROBE_MODEL\",\"session_id\":\"$SESSION\",\"messages\":$SHORT_MSGS,\"max_completion_tokens\":-1}" \
  "max_completion_tokens" "-1"

refusal_case "chat n=3 (one choice per request)" /v1/chat/completions \
  "{\"model\":\"$PROBE_MODEL\",\"session_id\":\"$SESSION\",\"messages\":$SHORT_MSGS,\"n\":3}" \
  "n" "3"

refusal_case "chat temperature=2.5 (OpenAI range is 0-2)" /v1/chat/completions \
  "{\"model\":\"$PROBE_MODEL\",\"session_id\":\"$SESSION\",\"messages\":$SHORT_MSGS,\"temperature\":2.5}" \
  "temperature" "2.5"

refusal_case "chat top_p=0 (open range at zero)" /v1/chat/completions \
  "{\"model\":\"$PROBE_MODEL\",\"session_id\":\"$SESSION\",\"messages\":$SHORT_MSGS,\"top_p\":0}" \
  "top_p" "0"

refusal_case "completions max_tokens=-5 (becomes the scheduler token budget)" /v1/completions \
  "{\"model\":\"$PROBE_MODEL\",\"prompt\":\"hi\",\"max_tokens\":-5}" \
  "max_tokens" "-5"

refusal_case "messages max_tokens=-1" /v1/messages \
  "{\"model\":\"$PROBE_MODEL\",\"max_tokens\":-1,\"messages\":$SHORT_MSGS}" \
  "max_tokens" "-1"

refusal_case "messages temperature=1.5 (Anthropic range is 0-1)" /v1/messages \
  '{"model":"'${PROBE_MODEL}'","max_tokens":64,"temperature":1.5,"messages":'$SHORT_MSGS'}' \
  "temperature" "1.5"

# ── 2. no phantom 200 ──────────────────────────────────────────────────────────
probe_section "2 — max_tokens=0 is a refusal, never a 200 with nothing in it"

ZERO_BODY="$(probe_chat_body "$SESSION" "$ZERO_MSGS" 0)"
probe_api POST /v1/chat/completions "$ZERO_BODY" || true
if [ "${PROBE_STATUS}" = "200" ]; then
  probe_fail "max_tokens=0 answered 200 (content [$(field choices.0.message.content)]) — an empty completion is not an answer"
else
  probe_ok "max_tokens=0 refused with ${PROBE_STATUS}, not a 200 with empty content"
fi
if [ "$(field error.param)" = "max_tokens" ]; then
  probe_ok "the zero case names max_tokens too"
fi

# ── 3. the same value, two specs ───────────────────────────────────────────────
probe_section "3 — temperature 1.5 is legal on the OpenAI wire and refused on the Anthropic wire"

TEMP_OK="{\"model\":\"$PROBE_MODEL\",\"session_id\":\"$SESSION\",\"messages\":$SURVIVOR_MSGS,\"max_tokens\":16,\"temperature\":1.5}"
probe_api POST /v1/chat/completions "$TEMP_OK" || true
if [ "${PROBE_STATUS}" = "200" ]; then
  probe_ok "chat accepts temperature 1.5 (inside OpenAI [0, 2]) -> 200"
else
  probe_fail "chat rejected a legal temperature 1.5 -> ${PROBE_STATUS}: $(printf %.200s "$PROBE_BODY")"
fi

probe_api POST /v1/messages \
  "{\"model\":\"$PROBE_MODEL\",\"max_tokens\":16,\"temperature\":1.5,\"messages\":$SHORT_MSGS}" \
  || true
if [ "${PROBE_STATUS}" = "400" ] && [ "$(field error.param)" = "temperature" ]; then
  probe_ok "messages refuses temperature 1.5 with param=temperature (Anthropic caps at 1)"
else
  probe_fail "messages should refuse temperature 1.5 with param=temperature, got ${PROBE_STATUS}: $(printf %.200s "$PROBE_BODY")"
fi

# ── 4. a burst of bad bodies must not degrade the server ──────────────────────
probe_section "4 — eight malformed requests in a row, then a real turn"

REJECTED=0
for BAD in \
  '"max_tokens":-1' '"max_tokens":0' '"n":0' '"n":9' \
  '"top_p":0' '"min_p":2' '"frequency_penalty":3' '"seed":-1'
do
  BAD_BODY="{\"model\":\"$PROBE_MODEL\",\"session_id\":\"$SESSION\",\"messages\":$SHORT_MSGS,$BAD}"
  probe_api POST /v1/chat/completions "$BAD_BODY" || true
  case "${PROBE_STATUS}" in
    400) REJECTED=$(( REJECTED + 1 )) ;;
    *) probe_note "bad body $BAD -> ${PROBE_STATUS} $(printf %.160s "$PROBE_BODY")" ;;
  esac
done
if [ "$REJECTED" -ge 8 ]; then
  probe_ok "all 8 malformed bodies refused with 400 while the process stayed up"
else
  probe_fail "only $REJECTED/8 malformed bodies got 400 — the rest were accepted or killed the server"
fi

BURST_BODY="$(probe_chat_body "$SESSION" "$SURVIVOR_MSGS" 16)"
if probe_chat "$SESSION" "$BURST_BODY"; then
  BURST_TEXT="$(field choices.0.message.content)"
  if [ "${PROBE_STATUS}" = "200" ] && [ -n "$BURST_TEXT" ]; then
    probe_ok "after the burst: real generation still works (${PROBE_ELAPSED_MS} ms, code word present)"
  else
    probe_fail "after the burst: status ${PROBE_STATUS}, content [$BURST_TEXT] body: $(printf %.240s "$PROBE_BODY")"
  fi
else
  probe_fail "after the burst: server unreachable — one bad body still owns the process"
fi

probe_summary "$PROBE_NAME"
