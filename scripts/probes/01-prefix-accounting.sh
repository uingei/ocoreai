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
#   B. `usage.prompt_tokens_details.cached_tokens` on the wire agrees, turn for turn,
#      with the accounting line the engine logged. Both directions are hard failures:
#      cached > 0 against a line saying cached=0 is the wire lying about the engine,
#      and a logged saving the responses hide is the same lie pointed the other way.
#   C. Every warm turn (pool HIT that withheld messages) writes exactly one accounting
#      line, reused or not. "reused no tokens" is the case the HIT line cannot see;
#      "reused N" would otherwise be invisible in the other direction, and silence
#      cannot tell "nothing happened" from "nobody looked".
#   D. Prefix reuse actually happens: OCOREAI_REQUIRE_PREFIX_REUSE defaults to 1 since
#      P1 closed on 10-16 (upstream #700/#622/#696), so a host that went back to full
#      prefill is a red gate, not a NOTE. Relax it explicitly with =0; a host that
#      cannot reuse must say so rather than leave the claim untested. Reuse must also be
#      worth something: a turn may not pay more tokens than it reuses.
#
# What it measures: tokens paid / reused / promptTime per turn, and the tok/s rate with
# its 30k-context extrapolation, printed from this run's own numbers.
# Turn 4 is measured and deliberately NOT asserted: an edited resend (a past turn reworded)
# is refused by `canReusePooledSession` and rebuilds from scratch, so its cached_tokens is
# the price of having no rewind reserve. Whether to pay that storage for
# `KVCacheConfiguration.rewind` is the owner's call, and this number is the evidence.
#
# Before/after baseline for the record (same host, same script, same model):
#   10-16 @ pin 4cc5504 — [708, 730, 749] paid, cached 0/0/0, status no_reuse_observed
#   10-16 @ pin 6e338e5 — [708,  20,  16] paid, cached 0/710/733, status reuse_observed
# (turns 1-3; the edited-resend turn was added after these two runs)
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

# turn 4 — the edited resend: same conversation, but the second user turn is reworded, so
# the transcript no longer *extends* what the pool holds. SessionPool.canReusePooledSession
# refuses that (the KV describes the pre-edit conversation) and a clean session is built.
# This is the measurement behind the open rewind-reserve item: upstream #622 now provides
# KVCacheConfiguration.rewind(maxTokens:) plus trim-to-common-prefix, and this engine does
# not request a reserve. NOTE only — wiring it is a decision with a memory cost, so the
# number is evidence for that decision, not a regression gate.
U2EDITED="Now reply with exactly the word BETA, spelled in capitals."
U4="And finally, exactly the word DELTA."
body="$(probe_chat_body "$SESSION" "$(python3 -c '
import json,sys
print(json.dumps([{"role":"user","content":sys.argv[1]},{"role":"assistant","content":sys.argv[2]},{"role":"user","content":sys.argv[3]},{"role":"assistant","content":sys.argv[4]},{"role":"user","content":sys.argv[5]}]))' "$U1" "$A1" "$U2EDITED" "$A2" "$U4")" "$MAX_TOKENS")"
probe_chat "$SESSION" "$body"
if [ "${PROBE_STATUS:-}" = "200" ]; then
  T4_PROMPT="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens')"
  T4_CACHED="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens_details.cached_tokens')"
  probe_note "edited resend (a past turn reworded) 200 — prompt_tokens=${T4_PROMPT:-?} cached_tokens=${T4_CACHED:-none}: this is what an edit costs today"
else
  probe_fail "turn 4 (edited resend) -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
fi

# turn 5 — the same head, a different conversation. Sessions are keyed
# `modelId:conversationId` (SessionPool.poolKey), so this turn pays a cold prefill even
# though a live session for the same model already holds [U1, A1]: codex #55587 decouples
# the prompt-cache key from session identity for exactly this reason (its axis is
# provider-side caching, ours is local KV). NOTE only — loosening the key is an owner
# decision with a correctness cost, so this turn prices it instead of asserting a verdict.
# The deepest overlap here is 2, not 3, because turn 4 rewrote the second message: the
# edited transcript is what conversation 1 is holding now.
SESSION2="PROBE-XCONV-$$"
body="$(probe_chat_body "$SESSION2" "$(python3 -c '
import json,sys
print(json.dumps([{"role":"user","content":sys.argv[1]},{"role":"assistant","content":sys.argv[2]},{"role":"user","content":sys.argv[3]}]))' "$U1" "$A1" "$U2")" "$MAX_TOKENS")"
probe_chat "$SESSION2" "$body"
if [ "${PROBE_STATUS:-}" = "200" ]; then
  T5_PROMPT="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens')"
  T5_CACHED="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens_details.cached_tokens')"
  probe_note "cross-conversation turn (fresh session id, same head) 200 - prompt_tokens=${T5_PROMPT:-?} cached_tokens=${T5_CACHED:-none}: this is what conversation-partitioned KV costs"
else
  probe_fail "turn 5 (cross-conversation) -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
fi

probe_section "engine log — what the pool and upstream actually did"
# The pool keys itself `modelId:conversationId` (SessionPool.poolKey), so the HIT line
# carries the conversation id after the model id. Match the form that says messages were
# WITHHELD: that is exactly a warm turn, i.e. a turn that owes an accounting line. The
# divergence=0 HIT form is a session reuse that re-fed everything, and counting it would
# demand a line the engine is right not to write.
HITS="$(grep -c "Session pool HIT.*$SESSION.*withholding them" "$PROBE_LOG" 2>/dev/null || true)"
HITS="${HITS:-0}"
NOREUSE_LINES="$(grep "Prefix cache reused no tokens for $SESSION" "$PROBE_LOG" 2>/dev/null || true)"
NOREUSE="$(printf '%s' "$NOREUSE_LINES" | grep -c . || true)"
NOREUSE="${NOREUSE:-0}"
REUSE_LINES="$(grep -E "Prefix cache reused [0-9]+ of [0-9]+ prompt tokens for $SESSION" "$PROBE_LOG" 2>/dev/null || true)"
REUSED="$(printf '%s' "$REUSE_LINES" | grep -c . || true)"
REUSED="${REUSED:-0}"

# A. premise floor
if [ "$HITS" -ge 1 ]; then
  probe_ok "pool HIT logged $HITS time(s) for this conversation — the dedupe path was exercised"
else
  probe_fail "no \"Session pool HIT\" for $SESSION in $HITS lines — the run never touched the dedupe path, so it measures nothing. Check that /v1/chat/completions honours session_id (EngineInference convKey)."
fi

# C. every warm turn speaks, both directions. "reused no tokens" is the case the HIT line
# cannot see; "reused N" is the case that would otherwise be invisible the other way.
ACCOUNTED=$(( NOREUSE + REUSED ))
if [ "$HITS" -lt 1 ]; then
  probe_fail "$HITS warm turn(s) — nothing to check, so assertion C proves nothing"
elif [ "$ACCOUNTED" -eq "$HITS" ]; then
  probe_ok "all $HITS warm turn(s) accounted out loud — $REUSED reused, $NOREUSE paid the full prefill"
elif [ "$ACCOUNTED" -gt "$HITS" ]; then
  probe_fail "$ACCOUNTED accounting line(s) for $HITS warm turn(s) — the engine narrates turns that never happened"
else
  probe_fail "$HITS warm turn(s) but only $ACCOUNTED accounted ($REUSED reused + $NOREUSE no-reuse) — a warm turn stayed silent, which is indistinguishable from a quiet full prefill"
fi

# B. wire vs engine, per turn. Both directions are contradictions worth failing: cached>0
# on the wire against an engine line saying cached=0 is the surface claiming more than the
# engine delivered; the reverse is the surface hiding what the engine saved.
MAX_CACHED=0
for v in "$T1_CACHED" "$T2_CACHED" "$T3_CACHED" "$T4_CACHED"; do
  case "$v" in ''|*[!0-9]*) continue ;; esac
  [ "$v" -gt "$MAX_CACHED" ] && MAX_CACHED="$v"
done
WIRE_ZEROS=0
WIRE_REUSE=0
for v in "$T2_CACHED" "$T3_CACHED" "$T4_CACHED"; do
  case "$v" in ''|*[!0-9]*) continue ;; esac
  if [ "$v" -gt 0 ]; then WIRE_REUSE=$(( WIRE_REUSE + 1 )); else WIRE_ZEROS=$(( WIRE_ZEROS + 1 )); fi
done
if [ "$NOREUSE" -gt "$WIRE_ZEROS" ]; then
  probe_fail "engine logged $NOREUSE turn(s) with cached=0 while the wire reported zero cached on only $WIRE_ZEROS — a response claimed reuse the engine denied"
elif [ "$REUSED" -gt "$WIRE_REUSE" ]; then
  probe_fail "engine logged $REUSED reused turn(s) while the wire showed reuse on only $WIRE_REUSE — the log claims savings the responses hid"
else
  probe_ok "wire and log agree — wire: $WIRE_REUSE reused / $WIRE_ZEROS full prefill, log: $REUSED reused / $NOREUSE full prefill, max cached_tokens=$MAX_CACHED"
fi

probe_section "measured (P1)"
printf '%s\n' "$NOREUSE_LINES" | grep . | sed 's/^/        /'
printf '%s\n' "$REUSE_LINES" | grep . | sed 's/^/        /'
python3 - "$T1_PROMPT" "$T2_PROMPT" "$T3_PROMPT" "$T4_PROMPT" "$MAX_CACHED" <<'PY' | sed 's/^/        /'
import sys
t1, t2, t3, t4, cached = sys.argv[1:6]
paid = [int(v) for v in (t1, t2, t3, t4) if str(v).isdigit()]
if paid:
    print("prompt_tokens paid per turn: %s" % paid)
print("max cached_tokens on the wire: %s" % cached)
if cached.isdigit() and int(cached) == 0:
    print("P1 STATUS: OPEN — every turn prefilled the whole prompt")
else:
    print("P1 STATUS: reuse observed — %s prompt tokens reused on a warm turn" % cached)
PY
# What each turn paid and what reuse saved, read out of THIS run's log lines, not prose.
ACCOUNTING_LINES="$NOREUSE_LINES
$REUSE_LINES"
python3 - "$ACCOUNTING_LINES" <<'PY' | sed 's/^/        /'
import re, sys
text = sys.argv[1]
for tok, ms in re.findall(r"prefilled all (\d+) prompt tokens \(cached=0, promptTime=(\d+)ms\)", text):
    tok, ms = int(tok), int(ms)
    if tok > 0 and ms > 0:
        rate = tok / (ms / 1000.0)
        print("full prefill: %d tok in %d ms = %.0f tok/s -> a 30k-token turn ≈ %.1f s" % (tok, ms, rate, 30000.0 / rate))
for paid, cached, ms in re.findall(r"upstream prefilled (\d+) \(cached=(\d+), promptTime=(\d+)ms\)", text):
    paid, cached, ms = int(paid), int(cached), int(ms)
    print("reuse: %d tok paid in %d ms, %d tok reused (prompt was %d)" % (paid, ms, cached, paid + cached))
PY

# P1 closed on 10-16 (mlx-swift-lm #700 + #622 + #696; measured same-session before/after:
# warm turns went cached=0 -> cached=710/733). The gate is therefore ON by default, and a
# host that genuinely cannot reuse must say so out loud with OCOREAI_REQUIRE_PREFIX_REUSE=0.
REQUIRE_REUSE="${OCOREAI_REQUIRE_PREFIX_REUSE:-1}"
if [ "$REQUIRE_REUSE" = "1" ]; then
  if [ "$MAX_CACHED" -gt 0 ]; then
    probe_ok "reuse required (default) and observed — cached_tokens=$MAX_CACHED on a warm turn"
  else
    probe_fail "prefix reuse required but every warm turn cached 0 — the reuse that landed 10-16 has regressed"
  fi
  # A reused turn must reuse at least what it paid. "Reused 1 token" in a 700-token
  # conversation is a rounding error dressed as a capability, and would keep this gate green
  # while every cost claim built on it went false.
  LOPSIDED=""
  for pair in "$T2_CACHED:$T2_PROMPT" "$T3_CACHED:$T3_PROMPT" "$T4_CACHED:$T4_PROMPT"; do
    c="${pair%%:*}"
    p="${pair##*:}"
    case "$c$p" in ''|*[!0-9]*) continue ;; esac
    if [ "$c" -gt 0 ] && [ "$p" -gt "$c" ]; then LOPSIDED="$p tokens paid / only $c reused"; fi
  done
  if [ -n "$LOPSIDED" ]; then
    probe_fail "lopsided reuse — $LOPSIDED"
  else
    probe_ok "every reused turn reused at least what it paid"
  fi
else
  probe_note "OCOREAI_REQUIRE_PREFIX_REUSE=$REQUIRE_REUSE — reuse measured but not asserted on this host"
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
  # The refusal ledger: which rule said no, and how often a cold turn arrived while another
  # session already held the head. Same discipline as prefixReuse above — the counter must be
  # on the wire, must be non-zero when this run knows a refusal happened, and must not
  # out-count the log lines that record them.
  RR_TOTAL="$(probe_json "$PROBE_BODY" 'reuseRefusals.total')"
  RR_DIVERGED="$(probe_json "$PROBE_BODY" 'reuseRefusals.byReason.historyDiverged')"
  RR_XCONV="$(probe_json "$PROBE_BODY" 'reuseRefusals.crossConversationTurns')"
  RR_BEST="$(probe_json "$PROBE_BODY" 'reuseRefusals.bestMessagesInCommon')"
  if [ -z "$RR_TOTAL" ]; then
    probe_fail "kv-cache payload carries no reuseRefusals — the refusal accounting is not on the surface"
  else
    LOG_REFUSALS="$(grep -c "not reusable:" "$PROBE_LOG" 2>/dev/null || true)"
    LOG_REFUSALS="${LOG_REFUSALS:-0}"
    if [ "${RR_TOTAL:-0}" -ge 1 ] && [ "${RR_DIVERGED:-0}" -ge 1 ]; then
      probe_ok "reuseRefusals on the wire: total=$RR_TOTAL historyDiverged=$RR_DIVERGED (the edited resend was named, not just logged)"
    else
      probe_fail "the edited resend was refused this run, yet reuseRefusals reports total=${RR_TOTAL:-?} historyDiverged=${RR_DIVERGED:-absent} — the ledger did not record what the pool did"
    fi
    if [ "${RR_TOTAL:-0}" -lt "$LOG_REFUSALS" ]; then
      probe_fail "reuseRefusals.total=$RR_TOTAL is below the $LOG_REFUSALS in-memory refusal line(s) in the log — a counter that misses refusals cannot price the rules it counts"
    else
      probe_ok "counter $RR_TOTAL covers the $LOG_REFUSALS in-memory refusal(s) logged (any excess is a disk-snapshot refusal)"
    fi
    LOG_XCONV="$(grep -c "Cross-conversation prefix opportunity" "$PROBE_LOG" 2>/dev/null || true)"
    LOG_XCONV="${LOG_XCONV:-0}"
    if [ "${RR_XCONV:-0}" -ge 1 ] && [ "${RR_BEST:-0}" -ge 2 ]; then
      probe_ok "cross-conversation opportunity counted: turns=$RR_XCONV deepest=${RR_BEST}-message head already resident (counted, not reused)"
    else
      probe_fail "turn 5 arrived while another session held its head, yet reuseRefusals reports crossConversationTurns=${RR_XCONV:-absent} best=${RR_BEST:-absent} (log lines: $LOG_XCONV)"
    fi
    if [ "${RR_XCONV:-0}" -lt "$LOG_XCONV" ]; then
      probe_fail "$LOG_XCONV opportunity line(s) in the log but the counter says $RR_XCONV — the surface under-reports what the engine saw"
    fi
  fi
fi
fi

probe_summary "$PROBE_NAME"
