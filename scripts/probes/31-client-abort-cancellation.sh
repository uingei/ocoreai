#!/usr/bin/env bash
# 31-client-abort-cancellation.sh — when a client walks away, does the engine stop?
#
# ### Why (P1 reliability: one engine, one lock)
# ocoreai runs one model per process, and a turn holds the inference lock for its whole
# generation. If an abandoned request kept working, every later request would queue behind
# work nobody wants: CHANGELOG 10-22(4) timed an eval run where a task the harness gave up on
# held the lock ~160 s and 13 later requests were refused inside 4 s. The fix named there was
# "abort on disconnect", and `ChatHandler.swift:1386` bridges the SSE continuation's
# termination onto `InferenceCancellation` with a comment saying Hummingbird does not cancel
# the upstream task on its own.
#
# It was not measured until now — the claim lived in a comment — and it is FALSE. Measured
# 10-22 at pin bb0d5b048 (`gemma-4-e2b-it-4bit`, where a 200-token turn costs ~5 s): a client
# that disconnects at 1.0 s still gets its turn run to completion, `tokens=200/.maxTokens`, on
# both the streaming and the non-streaming face. Walking away buys nothing; the next caller
# waits for work nobody wants. Hummingbird owns the response stream and the public
# `RequestContext` exposes no channel/liveness handle (`CoreRequestContextStorage` carries only
# logger, endpointPath and parameters), so nothing tells the producer the client is gone.
#
# ### Why leg 1 exists
# A gate that cannot observe a completed long turn proves nothing, so leg 1 runs one with its
# client attached. If it cannot, this probe reports itself blind instead of certifying a
# cancellation it never saw — which matters here because the engine has a second, unrelated
# defect that ends some long turns at token one.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="client-abort-cancellation"

probe_boot
probe_require_ready_model

auth_args=()
if [ -n "${OCOREAI_API_KEYS:-}" ]; then
  auth_args=(-H "Authorization: Bearer ${OCOREAI_API_KEYS%%,*}")
fi

LONG_PROMPT='Enumerate 60 fruits, one per line.'
body() {  # body <max_tokens> <stream> <session_id> <prompt>
  printf '{"model":"%s","max_tokens":%s,"stream":%s,"session_id":"%s","messages":[{"role":"user","content":"%s"}]}' \
    "$PROBE_MODEL" "$1" "$2" "$3" "$4"
}
ns_ms() {  # epoch nanoseconds
  python3 -c 'import time;print(int(time.time()*1e9))'
}
log_line_count() { wc -l < "$PROBE_LOG" | tr -d ' '; }

# A successor turn that is itself tiny: 2 tokens, and its prompt is the same size as the long
# turn's, so any wait beyond its own ~0.2 s of work is queue time attributed to the holder.
succ() {  # succ <session_id> -> echoes "<wall_ms> <queue_ms>"
  local sid="$1" mark wall0 wall1
  mark="$(log_line_count)"
  wall0="$(ns_ms)"
  curl -sS -m 90 -X POST "$PROBE_BASE/v1/chat/completions" ${auth_args[@]+"${auth_args[@]}"} \
    -H 'Content-Type: application/json' \
    --data "$(body 20 false "$sid" 'Say READY.')" -o /dev/null 2>&1
  wall1="$(ns_ms)"
  echo "$(( (wall1 - wall0) / 1000000 )) $(queue_ms "$mark")"
}

# ── how a turn is judged ───────────────────────────────────────────────────────────────────
# Read the abandoned turn's OWN completion record, never the successor's queue time. The first
# draft asserted on queue wait and was invalid twice over: (a) its regex matched the timezone
# offset in the log timestamp, and (b) the engine's open one-token-collapse defect (CHANGELOG
# 10-22(6)/(8)) ends some long turns early, so a short queue can mean "cancelled" or "the
# model quit at token one" — indistinguishable from outside. The turn's own StdTurn line is
# unambiguous: reason=.cancelled means work stopped, tokens=200/.maxTokens means the dead
# client's turn ran anyway.
#
# Prints "<tokens> <reason>" where reason is cancelled|maxTokens|eos|other and tokens is "-"
# when the turn left no completion record at all (also evidence that work stopped).
turn_verdict() {  # turn_verdict <session_id> <since_line>
  local line
  line="$(tail -n +"$(( $1 + 1 ))" "$PROBE_LOG" 2>/dev/null | grep "StdTurn: $2 " | tail -1)"
  if [ -z "$line" ]; then
    echo "- none"
    return
  fi
  local toks reason
  toks="$(printf '%s\n' "$line" | sed -n 's/.*tokens=\([0-9][0-9]*\).*/\1/p')"
  reason="$(printf '%s\n' "$line" | sed -n 's/.*StopReason\.\([a-zA-Z]*\).*/\1/p')"
  echo "${toks:--} ${reason:-other}"
}

# A long turn that really runs: 200 tokens at ~40 tok/s ≈ 5s. Retried because the engine's
# open collapse defect sometimes ends such a turn at token one, which would make the harness
# look blind when it is only unlucky.
ran_long_turn() {  # ran_long_turn <session_id> -> echoes "<attempts> <tokens> <reason>"
  local sid="$1" attempt mark t r
  for attempt in 1 2 3; do
    mark="$(log_line_count)"
    curl -sS -m 90 -X POST "$PROBE_BASE/v1/chat/completions" ${auth_args[@]+"${auth_args[@]}"} \
      -H 'Content-Type: application/json' \
      --data "$(body 200 false "$sid-run$attempt" "$LONG_PROMPT")" -o /dev/null 2>&1
    read -r t r <<<"$(turn_verdict "$mark" "$sid-run$attempt")"
    if [ "${t:-0}" -gt 8 ] 2>/dev/null && [ "$r" = "maxTokens" ]; then
      echo "$attempt $t $r"; return
    fi
  done
  echo "$attempt ${t:-0} ${r:-other}"
}

# ── leg 1: positive control — the harness can observe a turn that runs to completion ──────
read -r CTL_N CTL_T CTL_R <<<"$(ran_long_turn abort31-control)"
probe_note "control: a client that stays connected ran the long turn ($CTL_T tokens/$CTL_R)" \
  " on attempt $CTL_N"
if [ "${CTL_T:-0}" -gt 8 ] 2>/dev/null && [ "$CTL_R" = "maxTokens" ]; then
  probe_ok "the instrument can see a full turn complete — so 'no completion record' below" \
    " will mean the work was stopped, not that the turn never ran"
else
  probe_fail "positive control failed after $CTL_N attempts ($CTL_T tokens/$CTL_R) — long turns" \
    " do not complete on this host, so this probe cannot tell cancellation from collapse"
fi

# ── legs 2+3: abandon mid-turn on each face — does the engine stop? ────────────────────────
for face in true false; do
  mark="$(log_line_count)"
  q0="$(ns_ms)"
  curl -sS -m 1 -N -X POST "$PROBE_BASE/v1/chat/completions" ${auth_args[@]+"${auth_args[@]}"} \
    -H 'Content-Type: application/json' \
    --data "$(body 200 "$face" "abort31-$face" "$LONG_PROMPT")" -o /dev/null >/dev/null 2>&1
  # Give the turn its full budget plus slack: if it is going to finish anyway, it will.
  sleep 8
  q1="$(ns_ms)"
  read -r T R <<<"$(turn_verdict "$mark" "abort31-$face")"
  probe_note "client abandoned stream=$face at 1.0s; the turn's own record: $T tokens/$R" \
    " (window $(( (q1 - q0) / 1000000 ))ms)"
  if [ "$R" = "cancelled" ] || [ "$T" = "-" ]; then
    probe_ok "abandoning a stream=$face turn stopped the work ($T tokens/$R) — nobody burns GPU" \
      " for a client that left"
  elif [ "${T:-0}" -gt 8 ] 2>/dev/null; then
    # Any multi-token completion IS the defect: the client left at 1.0s and a ~700-token
    # prefill costs ~4.9s, so a turn reaching double digits generated long after nobody was
    # listening, whatever word it finished under (.maxTokens at 200, or .eos at 103).
    # Recorded open rather than failed-flat — newly measured, not newly introduced. When
    # cancellation lands this leg XPASSes, and `_lib.sh` counts XPASS as a failure, so the
    # xfail has to be deleted in that same change.
    probe_xfail open "the abandoned stream=$face turn still ran to $T tokens/$R" \
      " (open: no disconnect signal reaches the producer — ChatHandler.swift:1386's" \
      " onTermination bridge does not fire; see CHANGELOG 10-22(9))"
  else
    probe_note "inconclusive for stream=$face ($T tokens/$R) — the turn ended for a third reason" \
      " (see the collapse defect); neither claim is made from it"
  fi
done

probe_summary "$PROBE_NAME"
