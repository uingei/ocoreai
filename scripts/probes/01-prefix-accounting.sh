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
#   E. One prompt, every hop, on the streaming face: the `prompt_tokens` a warm stream
#      answers must equal what the engine logged as that turn's whole prompt, and the
#      process's own prompt counter (`/metrics`) must move by exactly that number. The
#      wire was accounted on 10-21 and the counter was not, so a turn could cost 730
#      tokens for the client and ~20 for the box's own cost and capacity reporting.
#
# What it measures: tokens paid / reused / promptTime per turn, and the tok/s rate with
# its 30k-context extrapolation, printed from this run's own numbers.
# Turn 4 is an edited resend (a past turn reworded). `canReusePooledSession` still refuses
# to ANSWER from that cache — and since 10-21 the cache is no longer discarded either: the
# session is forked onto the shared prefix, so this turn reuses it and the turn owes an
# accounting line like any other warm turn. Correctness of the edit (the replaced fact must
# not leak) is owned by 27-edited-history-honesty.sh, which is why turn 4's REUSE stays a
# NOTE here: this probe prices turns, it does not judge what they say.
#
# Before/after baseline for the record (same host, same script, same model):
#   10-16 @ pin 4cc5504 — [708, 730, 749] paid, cached 0/0/0, status no_reuse_observed
#   10-16 @ pin 6e338e5 — [708,  20,  16] paid, cached 0/710/733, status reuse_observed
#   10-21 @ pin 48114eedf — same three turns, plus the edited resend: 721 of 752 reused
#                             (it re-prefilled all 752 before fork + rewind reserve)
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
# the transcript no longer *extends* what the pool holds. Answering from that KV would leak
# the pre-edit turn, so `canReusePooledSession` refuses it — but the cache is now rewound
# onto the shared prefix instead of dropped (SessionPool.rewindHistoryEnd -> the fork at
# EngineInference, with the reserve requested in MLXBridge.makeKVCacheConfiguration). The
# number printed here is what that leaves unpaid: rows older than the 1024-row reserve are
# gone, so an edit further back still re-prefills its prefix. Size is a memory dial, so it
# stays a NOTE; the reuse itself is asserted by probe 27 (cached_tokens > 0).
U2EDITED="Now reply with exactly the word BETA, spelled in capitals."
U4="And finally, exactly the word DELTA."
body="$(probe_chat_body "$SESSION" "$(python3 -c '
import json,sys
print(json.dumps([{"role":"user","content":sys.argv[1]},{"role":"assistant","content":sys.argv[2]},{"role":"user","content":sys.argv[3]},{"role":"assistant","content":sys.argv[4]},{"role":"user","content":sys.argv[5]}]))' "$U1" "$A1" "$U2EDITED" "$A2" "$U4")" "$MAX_TOKENS")"
probe_chat "$SESSION" "$body"
if [ "${PROBE_STATUS:-}" = "200" ]; then
  T4_PROMPT="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens')"
  T4_CACHED="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens_details.cached_tokens')"
  probe_note "edited resend (a past turn reworded) 200 — prompt_tokens=${T4_PROMPT:-?} cached_tokens=${T4_CACHED:-none}: what an edit costs with a 1024-row rewind reserve (before the rewind was wired, this same turn re-prefilled all ${T4_PROMPT:-?})"
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
# A rewound turn withholds the shared prefix from its feed exactly the way a HIT does
# (EngineInference sets divergenceIndex to the rewind boundary and feeds the suffix), so it
# is a warm turn and owes an accounting line on the same terms. Counting only the HIT form
# would demand 2 lines for 3 warm turns and blame the engine for keeping a cache it kept.
REWOUNDS="$(grep -c "Session REWOUND for $SESSION" "$PROBE_LOG" 2>/dev/null || true)"
REWOUNDS="${REWOUNDS:-0}"
HITS=$(( HITS + REWOUNDS ))
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

# D. the whole, not just the part. Until 10-21 the wire published the prefilled SUFFIX as
# `prompt_tokens` (upstream GenerateCompletionInfo.promptTokenCount), so a warm turn could log
# "reused 710 of 730" and answer prompt_tokens=20 / cached_tokens=710. Assertion B above compares
# the CACHED numbers turn for turn, so it stayed green through that: a gate that checks the part
# and never the whole cannot see a whole that is too small (AGENTS.md invariant 1). Upstream's
# total is cached + prefilled (mlx-swift-lm Evaluate.swift:2984-2987) and the reuse line already
# prints it, so log and wire must agree digit for digit.
PAIR_CHECK="$(python3 - "$PROBE_LOG" "$SESSION" "$T2_CACHED" "$T2_PROMPT" "$T3_CACHED" "$T3_PROMPT" "$T4_CACHED" "$T4_PROMPT" <<'PY'
import re, sys
log, session = sys.argv[1], sys.argv[2]
wire = [(sys.argv[i], sys.argv[i + 1]) for i in (3, 5, 7)]
try:
    text = open(log, errors="replace").read()
except Exception as e:
    print("ERR cannot read log: %s" % e)
    sys.exit()
logged = re.findall(
    r"Prefix cache reused (\d+) of (\d+) prompt tokens for %s" % re.escape(session), text)
wturns = [(c, p) for c, p in wire if c.isdigit() and p.isdigit() and int(c) > 0]
if not logged and not wturns:
    print("SKIP no reused turn in this run")
    sys.exit()
if len(logged) != len(wturns):
    print("FAIL %d reused turn(s) in the log but %d on the wire" % (len(logged), len(wturns)))
    sys.exit()
bad = [(lc, lp, wc, wp) for (lc, lp), (wc, wp) in zip(logged, wturns) if (lc, lp) != (wc, wp)]
if bad:
    # ONE line, so probe_fail runs in this shell and its counter survives (a verdict counted
    # inside a pipeline subshell is a verdict that never happened).
    print("FAIL " + " ; ".join(
        "log says reused %s of %s, wire says cached_tokens=%s prompt_tokens=%s" % (lc, lp, wc, wp)
        for lc, lp, wc, wp in bad))
else:
    print("OK %s" % ", ".join("reused %s of %s" % (c, p) for c, p in logged))
PY
)"
case "$PAIR_CHECK" in
  OK\ *)  probe_ok "prompt_tokens is the whole the log names — $PAIR_CHECK" ;;
  SKIP\ *) probe_note "$PAIR_CHECK — nothing to tie this run" ;;
  ERR\ *)  probe_fail "$PAIR_CHECK" ;;
  FAIL\ *) probe_fail "wire/log prompt mismatch — ${PAIR_CHECK#FAIL }" ;;
  *)       probe_fail "prompt-tie check produced no verdict (empty output) — a check that stays silent is not a check" ;;
esac

# E. one prompt, every hop, on the streaming face. A warm turn is the only shape where "the whole
# prompt" and "what this turn prefilled" are different numbers, and the streaming path reported the
# former to the client and the latter to everything else: 4b706ef accounted the SSE `usage` chunk
# and left the metrics call on the prefilled suffix, so one turn cost 730 tokens for the client and
# ~20 for /metrics and for the session rows that drive the compaction threshold. No gate compared
# the two hops, so the suite stayed green. Shape: open a conversation with a cold turn, then stream
# the warm one with stream_options.include_usage, and the process's own prompt counter must advance
# by exactly the prompt_tokens that stream answered.
probe_section "streaming face — /metrics must move by the prompt the wire reported"
SSESSION="PROBE-PREFIX-STREAM-$$"
# cold turn on this conversation: the warm one that follows is the turn that can reuse a prefix
body="$(probe_chat_body "$SSESSION" "$(python3 -c 'import json,sys;print(json.dumps([{"role":"user","content":sys.argv[1]}]))' "$U1")" "$MAX_TOKENS")"
probe_chat "$SSESSION" "$body"
if [ "${PROBE_STATUS:-}" = "200" ]; then
  SA1="$(probe_json "$PROBE_BODY" 'choices.0.message.content')"
else
  probe_fail "§E warm-up (cold) turn -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
fi

# Read the counter only now: bracketing the warm-up turn as well would make the delta cover two
# generations, and a turn that costs 708 + 730 is not evidence about a 730-token prompt.
probe_api GET /metrics
PROMPT_BEFORE="$(printf '%s\n' "$PROBE_BODY" \
  | awk '/^ocoreai_inference_tokens_total\{kind="prompt"\} /{print $2}')"

STREAM_MSGS="$(python3 -c '
import json,sys
print(json.dumps([{"role":"user","content":sys.argv[1]},{"role":"assistant","content":sys.argv[2]},{"role":"user","content":sys.argv[3]}]))' "$U1" "$SA1" "$U2")"
STREAM_BODY="$(python3 - "$PROBE_MODEL" "$SSESSION" "$STREAM_MSGS" "$MAX_TOKENS" <<'PY'
import json, sys
model, session_id, messages, max_tokens = sys.argv[1:5]
print(json.dumps({
    "model": model,
    "session_id": session_id,
    "max_tokens": int(max_tokens),
    "temperature": 0.0,
    "stream": True,
    "stream_options": {"include_usage": True},
    "messages": json.loads(messages),
}))
PY
)"
probe_chat "$SSESSION" "$STREAM_BODY" || true
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "§E streaming turn -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
fi
STREAM_USAGE="$(printf '%s' "${PROBE_BODY:-}" | python3 -c '
import json, sys
best = None
saw_content = False
for line in sys.stdin.read().splitlines():
    if not line.startswith("data: "):
        continue
    payload = line[6:].strip()
    if payload == "[DONE]":
        continue
    try:
        obj = json.loads(payload)
    except Exception:
        continue
    for ch in obj.get("choices", []):
        if (ch.get("delta") or {}).get("content"):
            saw_content = True
    if obj.get("usage"):
        best = obj["usage"]
if best is None:
    print("ERR no usage chunk on this stream though stream_options.include_usage was asked for")
elif not saw_content:
    print("ERR the stream carried a usage chunk but no content delta")
else:
    details = best.get("prompt_tokens_details") or {}
    print("%s %s" % (best.get("prompt_tokens"), details.get("cached_tokens", "")))
')"
probe_api GET /metrics
PROMPT_AFTER="$(printf '%s\n' "$PROBE_BODY" \
  | awk '/^ocoreai_inference_tokens_total\{kind="prompt"\} /{print $2}')"

case "$STREAM_USAGE" in
  ERR\ *)
    probe_fail "streaming usage unusable — ${STREAM_USAGE#ERR }"
    ;;
  *)
    SF_PROMPT="${STREAM_USAGE%% *}"
    SF_CACHED="${STREAM_USAGE##* }"
    if [ -z "$SF_PROMPT" ] || [ -z "$PROMPT_BEFORE" ] || [ -z "$PROMPT_AFTER" ]; then
      probe_fail "§E could not read both sides of the counter (wire prompt_tokens=${SF_PROMPT:-?}, /metrics $PROMPT_BEFORE->$PROMPT_AFTER) — the check judged nothing"
    else
      DELTA=$(( PROMPT_AFTER - PROMPT_BEFORE ))
      if [ "$DELTA" -eq "$SF_PROMPT" ]; then
        probe_ok "streaming turn's prompt_tokens reached every hop — wire said $SF_PROMPT, /metrics moved by $DELTA"
      else
        probe_fail "streaming turn said prompt_tokens=$SF_PROMPT on the wire while /metrics moved by $DELTA — one turn, two numbers for one prompt (the counter is what cost and capacity are read from)"
      fi
      # The counter tie only bites when whole != suffix, i.e. when this turn reused a prefix.
      # A cold streaming turn makes the two equal, and a §E that quietly degrades to that shape
      # would report the same clean line as a run that checked the defect — so say which happened.
      SF_LOGGED="$(grep -E "Prefix cache reused [0-9]+ of [0-9]+ prompt tokens for $SSESSION" "$PROBE_LOG" 2>/dev/null | tail -1 || true)"
      if [ -n "$SF_LOGGED" ]; then
        SF_T="$(printf '%s' "$SF_LOGGED" | sed -nE 's/.*reused ([0-9]+) of ([0-9]+) prompt tokens.*/\2/p')"
        probe_ok "the streaming wire is the whole its log names — log reused $(printf '%s' "$SF_LOGGED" | sed -nE 's/.*reused ([0-9]+) of ([0-9]+) prompt tokens.*/\1/p') of $SF_T, wire prompt_tokens=$SF_PROMPT cached_tokens=${SF_CACHED:-none}"
        if [ "$SF_PROMPT" != "$SF_T" ]; then
          probe_fail "streaming wire prompt_tokens=$SF_PROMPT but the engine's whole prompt was $SF_T — the suffix is on the wire again"
        fi
      elif [ "${OCOREAI_REQUIRE_PREFIX_REUSE:-1}" = "1" ]; then
        probe_fail "§E streaming turn reused nothing, so whole == suffix and the counter tie could not tell the two apart — this run did not test what §E exists to test"
      else
        probe_note "§E streaming turn reused nothing (whole == suffix), so the counter tie judged nothing about the suffix defect"
      fi
    fi
    ;;
esac

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
  #
  # What a turn PAID is the difference, not the prompt: `prompt_tokens` on the wire is the whole
  # rendered prompt and `cached_tokens` the part its KV cache kept, so paid = prompt - cached.
  # Comparing `prompt <= cached` here (what this line did until 10-21) looked sane only because
  # the wire published the prefilled suffix under the prompt's name; with the accounting fixed
  # that comparison fails every healthy turn (prompt 749 / cached 733).
  LOPSIDED=""
  for pair in "$T2_CACHED:$T2_PROMPT" "$T3_CACHED:$T3_PROMPT" "$T4_CACHED:$T4_PROMPT"; do
    c="${pair%%:*}"
    p="${pair##*:}"
    case "$c$p" in ''|*[!0-9]*) continue ;; esac
    paid=$(( p - c ))
    if [ "$c" -gt 0 ] && [ "$paid" -gt "$c" ]; then
      LOPSIDED="$paid tokens prefilled / only $c reused (whole prompt $p)"
    fi
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
    # Only the lines that threw the cache away are refusals. Since 10-21 the diverged-turn
    # line can also end "cache kept for a rewind instead of discarded", and counting that as
    # a refusal would have the counter report a rebuild the engine did not do — the same
    # direction of error this whole probe exists to catch (AGENTS.md invariant 2).
    LOG_REFUSALS="$(grep -c "not reusable:.*building a clean session" "$PROBE_LOG" 2>/dev/null || true)"
    LOG_REFUSALS="${LOG_REFUSALS:-0}"
    if [ "${RR_DIVERGED:-0}" -gt 0 ]; then
      probe_fail "this run's edited resend was rewound, yet reuseRefusals.historyDiverged=$RR_DIVERGED — the ledger still books a rewound turn as refused-and-rebuilt"
    else
      probe_ok "reuseRefusals on the wire: total=$RR_TOTAL historyDiverged=${RR_DIVERGED:-0} — the rewound edit is not booked as a refusal (probe 27 asserts the reuse it got instead)"
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
