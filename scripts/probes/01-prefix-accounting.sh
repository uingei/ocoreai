#!/usr/bin/env bash
# 01-prefix-accounting.sh — what a session-pool HIT actually saves, measured.
#
# Why (AGENTS.md § Open, P1, 10-14): the open item says every turn pays the full
# prefill — `prefilled == full prompt`, `cached == 0` — and the earlier "prefix reuse
# is working" reading was a misread of model-load time. That conclusion came from a
# temp-dir script that no longer exists. This is the instrument that replaces it: the
# same measurement, reproducible, with the numbers printed.
#
# What it asserts (invariant 2 — the surface never claims more than the engine did):
#   A. The dedupe path is actually exercised, else the run proves nothing.
#   B. `usage.prompt_tokens_details.cached_tokens` on the wire agrees with what the
#      engine logged for the same turn. A turn reporting cached > 0 while upstream
#      reported cached == 0 is the wire lying about the engine — that is the defect
#      family this repo keeps getting bitten by, so it is a hard failure here.
#   C. When the engine withheld messages from a feed and got no reuse back, it must
#      have said so (the WARN added in def1964). Silence would mean a HIT turn that
#      quietly costs full prefill and reports nothing.
#
# What it measures (never a pass/fail — the fix is not landed yet, and a permanently
# red gate teaches people to ignore red):
#   prefilled / cached / promptTime per turn, and the 30k-context extrapolation that
#   the open item quotes (~3-4 s/turn). Set OCOREAI_REQUIRE_PREFIX_REUSE=1 to turn
#   the measurement into a hard assertion the day prefix reuse actually lands — that
#   is the regression gate for closing P1.
#
# Run: bash scripts/probes/01-prefix-accounting.sh
PROBE_NAME="01-prefix-accounting"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

SESSION="PROBE-PREFIX-$$"
MAX_TOKENS="${OCOREAI_PROBE_MAX_TOKENS:-8}"
PAD="$(probe_pad_text "${OCOREAI_PROBE_PAD_UNITS:-40}")"

probe_boot
probe_require_ready_model

# Three turns on one conversation: turn 1 cold, turns 2-3 should be the HIT turns.
U1="Reply with exactly the word ALPHA and nothing else."
A1=""
U2="Now reply with exactly the word BETA and nothing else."
A2=""
U3="And now exactly the word GAMMA."

probe_section "three same-session turns (model=$PROBE_MODEL, session=$SESSION)"

# turn 1
body="$(probe_chat_body "$SESSION" "$(python3 -c 'import json,sys;print(json.dumps([{"role":"user","content":sys.argv[1]}]))' "$U1")" "$MAX_TOKENS")"
probe_chat "$SESSION" "$body"
if [ "${PROBE_STATUS:-}" = "200" ]; then
  A1="$(probe_json "$PROBE_BODY" 'choices.0.message.content')"
  T1_PROMPT="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens')"
  T1_CACHED="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens_details.cached_tokens')"
  probe_ok "turn 1 (cold) 200 — prompt_tokens=${T1_PROMPT:-?} cached_tokens=${T1_CACHED:-none} elapsed=${PROBE_ELAPSED_MS}ms"
else
  probe_fail "turn 1 -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
probe_summary "$PROBE_NAME"
fi

# turn 2 (history + reply appended: this is where a HIT should appear)
body="$(probe_chat_body "$SESSION" "$(python3 -c '
import json,sys
print(json.dumps([{"role":"user","content":sys.argv[1]},{"role":"assistant","content":sys.argv[2]},{"role":"user","content":sys.argv[3]}]))' "$U1" "$A1" "$U2")" "$MAX_TOKENS")"
probe_chat "$SESSION" "$body"
if [ "${PROBE_STATUS:-}" = "200" ]; then
  A2="$(probe_json "$PROBE_BODY" 'choices.0.message.content')"
  T2_PROMPT="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens')"
  T2_CACHED="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens_details.cached_tokens')"
  probe_ok "turn 2 (warm) 200 — prompt_tokens=${T2_PROMPT:-?} cached_tokens=${T2_CACHED:-none} elapsed=${PROBE_ELAPSED_MS}ms"
else
  probe_fail "turn 2 -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
fi

# turn 3
body="$(probe_chat_body "$SESSION" "$(python3 -c '
import json,sys
print(json.dumps([{"role":"user","content":sys.argv[1]},{"role":"assistant","content":sys.argv[2]},{"role":"user","content":sys.argv[3]},{"role":"assistant","content":sys.argv[4]},{"role":"user","content":sys.argv[5]}]))' "$U1" "$A1" "$U2" "$A2" "$U3")" "$MAX_TOKENS")"
probe_chat "$SESSION" "$body"
if [ "${PROBE_STATUS:-}" = "200" ]; then
  T3_PROMPT="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens')"
  T3_CACHED="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens_details.cached_tokens')"
  probe_ok "turn 3 (warm) 200 — prompt_tokens=${T3_PROMPT:-?} cached_tokens=${T3_CACHED:-none} elapsed=${PROBE_ELAPSED_MS}ms"
else
  probe_fail "turn 3 -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
fi

probe_section "engine log — what the pool and upstream actually did"
# The pool keys itself `modelId:conversationId` (SessionPool.poolKey), so the HIT line
# carries the conversation id after the model id — match it anywhere in the line.
HITS="$(grep -c "Session pool HIT.*$SESSION" "$PROBE_LOG" 2>/dev/null || true)"
HITS="${HITS:-0}"
NOREUSE_LINES="$(grep "Prefix cache reused no tokens for $SESSION" "$PROBE_LOG" 2>/dev/null || true)"
NOREUSE="$(printf '%s' "$NOREUSE_LINES" | grep -c . || true)"
NOREUSE="${NOREUSE:-0}"

# A. premise floor
if [ "$HITS" -ge 1 ]; then
  probe_ok "pool HIT logged $HITS time(s) for this conversation — the dedupe path was exercised"
else
  probe_fail "no \"Session pool HIT\" for $SESSION in $HITS lines — the run never touched the dedupe path, so it measures nothing. Check that /v1/chat/completions honours session_id (EngineInference convKey)."
fi

# C. honesty of the HIT log
if [ "$NOREUSE" -ge 1 ]; then
  probe_ok "engine said out loud, $NOREUSE time(s), that a HIT turn reused no KV — no silent full prefill"
elif [ "$HITS" -ge 1 ]; then
  probe_fail "$HITS HIT turn(s) logged but no accounting line: either upstream reported reuse (see cached_tokens below) or the engine stayed silent about a full prefill"
fi

# B. wire vs engine, per turn
MAX_CACHED=0
for v in "$T1_CACHED" "$T2_CACHED" "$T3_CACHED"; do
  case "$v" in ''|*[!0-9]*) continue ;; esac
  [ "$v" -gt "$MAX_CACHED" ] && MAX_CACHED="$v"
done
if [ "$NOREUSE" -ge 1 ] && [ "$MAX_CACHED" -gt 0 ]; then
  probe_fail "wire reports cached_tokens=$MAX_CACHED while the engine logged $NOREUSE turn(s) with cached=0 — the surface claims more than the engine delivered"
elif [ "$MAX_CACHED" -gt 0 ]; then
  probe_ok "wire reports cached_tokens=$MAX_CACHED with no contradicting engine line — some prefix reuse happened"
else
  probe_ok "wire reports cached_tokens=0 on every turn, matching upstream — honest, if unreused"
fi

probe_section "measured (P1)"
printf '%s\n' "$NOREUSE_LINES" | grep . | sed 's/^/        /'
python3 - "$T1_PROMPT" "$T2_PROMPT" "$T3_PROMPT" "$MAX_CACHED" <<'PY' | sed 's/^/        /'
import re, sys
t1, t2, t3, cached = sys.argv[1:5]
vals = [int(v) for v in (t1, t2, t3) if str(v).isdigit()]
if vals:
    print("prompt_tokens per turn: %s" % vals)
print("max cached_tokens on the wire: %s" % cached)
if cached.isdigit() and int(cached) == 0:
    print("P1 STATUS: OPEN — every turn prefilled the whole prompt")
else:
    print("P1 STATUS: some reuse observed (%s tokens)" % cached)
PY
if [ -n "$NOREUSE_LINES" ]; then
  # Extrapolate the open item's headline number from THIS run, not from prose.
  python3 - "$NOREUSE_LINES" <<'PY' | sed 's/^/        /'
import re, sys
text = sys.argv[1]
rows = re.findall(r"prefilled all (\d+) prompt tokens \(cached=0, promptTime=(\d+)ms\)", text)
for tok, ms in rows:
    tok, ms = int(tok), int(ms)
    if tok > 0 and ms > 0:
        print("%d tok in %d ms = %.0f tok/s -> 30k-token turn ≈ %.1f s" % (tok, ms, tok / (ms / 1000.0), 30000.0 / (tok / (ms / 1000.0))))
PY
fi

if [ "${OCOREAI_REQUIRE_PREFIX_REUSE:-0}" = "1" ]; then
  if [ "$MAX_CACHED" -gt 0 ]; then
    probe_ok "OCOREAI_REQUIRE_PREFIX_REUSE=1 satisfied — cached_tokens=$MAX_CACHED"
  else
    probe_fail "prefix reuse required but every turn cached 0 — P1 still open"
  fi
else
  probe_note "set OCOREAI_REQUIRE_PREFIX_REUSE=1 to make reuse a hard gate once P1 is fixed"
fi

probe_section "the surface must say what the engine measured"
# GET /v1/models/:model/kv-cache publishes `prefixReuse` — per-model, measured from
# upstream's own cachedPromptTokenCount. This probe knows what it just watched, so it can
# check the published answer against its own measurement (invariant 2).
ENC_MODEL="$(python3 -c 'import sys;print(sys.argv[1].replace("/", "%2F"))' "$PROBE_MODEL")"
probe_api GET "/v1/models/${ENC_MODEL}/kv-cache"
if [ "${PROBE_STATUS:-}" != "200" ]; then
probe_fail "GET /v1/models/<percent-encoded>/kv-cache -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:160}"
else
PR_STATUS="$(probe_json "$PROBE_BODY" 'prefixReuse.status')"
PR_WARM="$(probe_json "$PROBE_BODY" 'prefixReuse.warmTurns')"
PR_REUSED="$(probe_json "$PROBE_BODY" 'prefixReuse.turnsWithReuse')"
if [ -z "$PR_STATUS" ]; then
  probe_fail "kv-cache payload carries no prefixReuse — the measured disposition is not on the wire"
else
  probe_note "prefixReuse on the wire: status=$PR_STATUS warmTurns=${PR_WARM:-?} turnsWithReuse=${PR_REUSED:-?}"
  if [ "$MAX_CACHED" -eq 0 ] && [ "$PR_STATUS" = "reuse_observed" ]; then
    probe_fail "surface says reuse_observed while every turn this run measured cached=0 — the surface claims more than the engine delivered"
  elif [ "$PR_STATUS" = "reuse_observed" ] && [ "${PR_REUSED:-0}" -lt 1 ]; then
    probe_fail "status=reuse_observed but turnsWithReuse=${PR_REUSED:-0} — the claim outruns its own counters"
  else
    probe_ok "prefixReuse.status=$PR_STATUS agrees with what this run measured"
  fi
  # Floor the premise: without this, `not_observed` would pass by never having recorded.
  if [ "${PR_WARM:-0}" -ge 2 ]; then
    probe_ok "ledger recorded $PR_WARM warm turns — the accounting actually ran"
  else
    probe_fail "kv-cache reports ${PR_WARM:-0} warm turn(s) after 3 same-session requests — the ledger never recorded"
  fi
fi
fi

probe_summary "$PROBE_NAME"
