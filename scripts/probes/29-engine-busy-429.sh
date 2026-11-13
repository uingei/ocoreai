#!/usr/bin/env bash
# 29-engine-busy-429.sh — when the one engine is busy, does the wire say 429, and does a
# second request queue instead of being waved off?
#
# ### Why (AGENTS.md invariant 2 + "one home per decision")
# Measured 10-22 in scripts/eval: one run lost 13 consecutive tasks in 4 seconds to
# `{"error":{"message":"Generation failed: Engine busy","code":500}}`. Two defects in one
# sentence. (1) The status: capacity is not a server error — the request was well-formed and
# the engine is merely occupied, and `AppError.engineBusy` already mapped to 429 two files
# away, so the same condition had two homes and the wire took the wrong one. A client that
# backs off on 429 and retries was told to treat a healthy box as broken. (2) The shape:
# `tryAcquireInference()` was a fail-fast CAS with no queue at all, so every overlapping
# request was refused at t=0 even when the running turn needed 600 ms more — in the GUI that
# is "one generation going, second message refused". vllm and sglang queue rather than
# reject (sglang signals capacity with 503 `overloaded_error`, never a per-request 500:
# sglang/python/sglang/srt/entrypoints/http_server.py:595); ocoreai holds one engine per
# process by design, so the wait is bounded and the refusal names when to come back.
#
# ### What is asserted
#   1. Refusal shape: the second request gets **429**, not 500, with `error_code: engine_busy`,
#      `type: rate_limit_error` (the name both OpenAI and Anthropic SDKs branch on) and a
#      `Retry-After` header read from the refusal response's own headers, so the client needs
#      no string-parse to know it may try again. The premise — that a turn was in flight — is
#      certified by the refusal costing the full queue window (t=0 would mean nothing held the
#      lock); a first streamed token, when it arrives, is corroboration, not the premise.
#   2. The refusal costs nothing to the turn in flight: the long request still completes 200.
#   3. Queue-and-serve: with a short turn in flight (inside OCOREAI_ENGINE_BUSY_WAIT), the
#      overlapping request is served with a real completion — saturation is waited out, not
#      exported to the caller.
#   4. The knob cannot rot: `OCOREAI_ENGINE_BUSY_WAIT` is read by the engine, and the shared
#      marker is still the single source of the busy sentence (a literal reintroduced at an
#      engine call site is the regression this probe exists for — `EngineBusyAdmissionTests`
#      greps for it too).
#
# Needs Metal and a loaded model: this is a live probe, not a unit test.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="engine-busy-429"

# 3 s: a padded-prompt turn overruns it on engine clock (refusal shape, with the premise
# retried), an 8-token turn fits inside it (queued and served).
: "${OCOREAI_ENGINE_BUSY_WAIT:=3}"
export OCOREAI_ENGINE_BUSY_WAIT

probe_boot
probe_require_ready_model
probe_note "OCOREAI_ENGINE_BUSY_WAIT=$OCOREAI_ENGINE_BUSY_WAIT · model $PROBE_MODEL"

auth_args=()
if [ -n "${OCOREAI_API_KEYS:-}" ]; then
  auth_args=(-H "Authorization: Bearer ${OCOREAI_API_KEYS%%,*}")
fi

body() {  # body <max_tokens> <prompt>
  printf '{"model":"%s","max_tokens":%s,"stream":false,"messages":[{"role":"user","content":"%s"}]}' \
    "$PROBE_MODEL" "$1" "$2"
}

# The long turn must stream, or the probe has no way to see the turn start: a non-stream
# response lands as one JSON body at the end, and "no data: line yet" is indistinguishable
# from "still preparing" (measured 10-22, first run of this leg waited on a body that
# could only ever arrive after the turn was over).
body_stream() {  # body_stream <max_tokens> <prompt>
  printf '{"model":"%s","max_tokens":%s,"stream":true,"messages":[{"role":"user","content":"%s"}]}' \
    "$PROBE_MODEL" "$1" "$2"
}

# ── leg 1 + 2: long turn in flight ⇒ 429 with Retry-After, and the turn survives ──────────
HDR="$(mktemp -t ocoreai-29-hdr.XXXXXX)"
HDR_REFUSAL="$(mktemp -t ocoreai-29-hdr-refusal.XXXXXX)"
LONG_OUT="$(mktemp -t ocoreai-29-long.XXXXXX)"
SHORT_OUT="$(mktemp -t ocoreai-29-short.XXXXXX)"

# The busy turn is PHYSICAL work, not a token budget: the shipped reasoning face caps a
# counting turn wherever it likes, and measured 11-13 the same construction held the lock for
# 30 s on one boot and released it inside 1 s on the next. A padded prompt (~2 100 tokens) buys
# seconds of prefill on the engine clock before any token can come out, and the whole
# experiment RETRIES — the premise is re-measured, never asserted. Firing happens on the first
# SSE token or at a 2 s cap: firing at 0.4 s once let the short turn reach the lock first
# (measured 10-22 — HTTP arrival order is not lock arrival order), and by 2 s the padded turn
# holds it.
LONG_PROMPT="$(probe_pad_text 40) Now: count from 1 to 400, one number per line."
busy_proven=0
for attempt in 1 2 3; do
  : > "$LONG_OUT"
  (
    curl -sS -N -m 180 -X POST "$PROBE_BASE/v1/chat/completions" ${auth_args[@]+"${auth_args[@]}"} \
      -H 'Content-Type: application/json' -H 'Accept: text/event-stream' -D "$HDR" \
      --data "$(body_stream 512 "$LONG_PROMPT")" > "$LONG_OUT" 2>&1
  ) &
  LONG_PID=$!
  for _ in $(seq 1 20); do
    grep -q '^data:' "$LONG_OUT" 2>/dev/null && break
    kill -0 "$LONG_PID" 2>/dev/null || break
    sleep 0.1
  done
  B_START_MS=$(($(date +%s) * 1000))
  PROBE_HDR_FILE="$HDR_REFUSAL"
  if ! probe_api POST /v1/chat/completions "$(body 8 'Say OK.')"; then
    PROBE_HDR_FILE=""
    probe_note "attempt $attempt: the overlapping request never answered — retrying"
    wait "$LONG_PID" 2>/dev/null || true
    continue
  fi
  PROBE_HDR_FILE=""
  B_WAIT_MS=$(( $(($(date +%s) * 1000)) - B_START_MS ))
  # The refusal's own wait is the contention evidence: the queue window cannot elapse
  # without a lock holder, and a refusal at t=0 certifies nothing.
  if [ "$PROBE_STATUS" = "429" ] && [ "$B_WAIT_MS" -ge 2000 ]; then
    busy_proven=1
    probe_ok "429 after ${B_WAIT_MS}ms (attempt $attempt) — it waited out the queue window" \
      " against a turn that held the lock"
    break
  fi
  probe_note "attempt $attempt: status $PROBE_STATUS after ${B_WAIT_MS}ms — the busy turn" \
    " released the lock too early for this boot; retrying the premise"
  wait "$LONG_PID" 2>/dev/null || true
done

if [ "$busy_proven" = "1" ]; then
  case "$PROBE_BODY" in
    *engine_busy*) probe_ok "payload carries error_code engine_busy" ;;
    *) probe_fail "payload lacks error_code engine_busy — clients would still be" \
      " string-parsing: $PROBE_BODY" ;;
  esac
  case "$PROBE_BODY" in
    *rate_limit_error*) probe_ok "payload speaks the SDK's own type (rate_limit_error)" ;;
    *) probe_fail "payload type is not rate_limit_error — SDKs branch on type, not message:" \
      " $PROBE_BODY" ;;
  esac
  if grep -qi '^retry-after:' "$HDR_REFUSAL"; then
    probe_ok "429 names when to come back" \
      " ($(grep -i '^retry-after:' "$HDR_REFUSAL" | tr -d '\r')) — read off the refusal's own response"
  else
    probe_fail "429 without Retry-After — the client is told to retry but not when. Headers were:"
    sed 's/^/        /' "$HDR_REFUSAL"
  fi
else
  probe_fail "3 attempts never held the lock for the ${OCOREAI_ENGINE_BUSY_WAIT}s window —" \
    " capacity cannot be judged against a turn that never existed on this boot"
fi

wait "$LONG_PID"
SSE_CHUNKS="$(grep -c '^data:' "$LONG_OUT" 2>/dev/null)"; SSE_CHUNKS="${SSE_CHUNKS:-0}"
if [ "$busy_proven" = "1" ] && ! grep -q '\[DONE\]' "$LONG_OUT" 2>/dev/null; then
  probe_fail "the request in flight never reached [DONE] ($SSE_CHUNKS chunks) — refusing a" \
    " second caller must not disturb the first"
elif [ "$busy_proven" = "1" ]; then
  probe_ok "the turn in flight was unharmed by the refusal ($SSE_CHUNKS streamed chunks, [DONE])"
else
  probe_note "in-flight survival not judged — no refusal was ever produced (§1 premise failed)"
fi

# ── leg 3: a short turn in flight ⇒ the overlap is waited out, not exported ───────────────
(
  curl -sS -m 60 -X POST "$PROBE_BASE/v1/chat/completions" ${auth_args[@]+"${auth_args[@]}"} \
    -H 'Content-Type: application/json' \
    --data "$(body 8 'Say OK.')" > "$SHORT_OUT" 2>&1
) &
SHORT_PID=$!
sleep 0.05
if probe_api POST /v1/chat/completions "$(body 8 'Say hi.')"; then
  if [ "$PROBE_STATUS" = "200" ]; then
    if grep -q "Queued for inference" "$PROBE_LOG" 2>/dev/null; then
      probe_ok "overlapping request queued and was served (200) — the engine logged the wait:"
      grep "Queued for inference" "$PROBE_LOG" | tail -1 | sed 's/^/        /'
    else
      probe_fail "200 with no 'Queued for inference' line in the engine log — this turn may" \
        " simply have missed the overlap, which would make the leg vacuous (as it nearly did)"
    fi
  else
    probe_fail "overlapping request got $PROBE_STATUS inside the ${OCOREAI_ENGINE_BUSY_WAIT}s" \
      " queue window with a short turn in flight — the wait is not reaching the lock:" \
      " $PROBE_BODY"
  fi
else
  probe_fail "queued request never answered: $PROBE_BODY"
fi
wait "$SHORT_PID" 2>/dev/null || true

# ── leg 4: the knob and the marker still exist where the code says they do ────────────────
if grep -rq "OCOREAI_ENGINE_BUSY_WAIT" "$PROBE_REPO_ROOT/Sources/ocoreai/Engine/" \
  && ! grep -rnE '\.error\("Engine busy"\)' "$PROBE_REPO_ROOT/Sources/ocoreai/Engine/" >/dev/null; then
  probe_ok "OCOREAI_ENGINE_BUSY_WAIT is read in Sources/ocoreai/Engine"
else
  probe_fail "OCOREAI_ENGINE_BUSY_WAIT is gone from the engine — this probe's premise would be" \
    " silently false (both legs depend on the bounded wait being real)"
fi

probe_summary "$PROBE_NAME"
