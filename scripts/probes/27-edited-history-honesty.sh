#!/usr/bin/env bash
# 27-edited-history-honesty.sh — when a caller rewrites the past, does the answer come from
# the history it actually sent, and what does that turn really pay?
#
# ### Why (AGENTS.md § Open "rewind 已接，储备是拍的常数")
# An edited resend is the most common state change a coding-agent UI makes — fix a typo in
# prompt 2 and send again. `SessionPool.canReusePooledSession` refuses it and builds a clean
# session, because the pooled KV describes the *pre-edit* conversation. Probe 01 already
# prices that turn (prompt_tokens/cached_tokens) and proves the refusal is named on
# `/v1/models/:model/kv-cache`, but two things were never established by anything:
#   1. CORRECTNESS — the whole justification for the refusal is that a stale cache would
#      leak the pre-edit context into the answer. Over HTTP, nothing ever checked that the
#      refusal actually prevents the leak: it was a rule believed, not observed. If an
#      edited resend can still answer with the replaced fact, that is a P0 correctness bug
#      hiding behind a green token ledger.
#   2. THE PRIZE — the reserve was a constant nobody had priced: § Open keeps whether 1024
#      rows is the right size ("不随模型或内存水位调") pending samples, so this probe states
#      the prize in tokens on the same run as the correctness check, and keeps the residual
#      (what the reserve could not cover) visible instead of folding it into a pass.
#
# ### What is asserted
#   1. The run's own premise: an appended warm turn reuses (`cached_tokens > 0`) — without
#      it "the edit costs X" has no baseline (a probe that certifies nothing is the shape
#      AGENTS.md invariant 1 is about).
#   2. The codeword mechanism: the appended turn answers with the codeword it was given.
#   3. THE EDIT IS OBSERVED: after the codeword turn is reworded, the answer must be the
#      NEW codeword and the OLD one must not appear anywhere in the reply. This is the
#      leak the refusal exists to prevent — and, once the cache is rewound instead of
#      discarded, the leak the trim must not reintroduce: the rows between the shared
#      prefix and the old answer have to be gone, not merely ignored.
#   4. Honest accounting on that turn: `prompt_tokens >= cached_tokens`, and the reused part
#      may not exceed what the warm appended turn reused (a rebuild that reports more reuse
#      than the extension is the surface promising more than the engine delivered).
#   4b. The edited turn REUSES: `cached_tokens > 0`. The pool refuses to answer a diverged
#       conversation from a stale cache, but it no longer throws that cache away — it offers
#       the caller `ChatSession.fork(history:)` (ChatSession.swift:1652 at pin 48114eedf),
#       which keeps the KV rows the new prompt still starts with. Without this leg the
#       rewind could silently stop working and only latency would notice.
#   5. The ledger records what actually happened: `historyDiverged == 0` (this edit was not
#      refused) and `prefixReuse` publishes the reuse the usage field reported — cause, cost
#      and gain on one surface, none of them inferred by this probe.
#
# ### What is measured (NOTE, not asserted)
#   paid = prompt_tokens - cached_tokens on the edited turn, against the reused count of the
#   appended turn. The reserve is requested (MLXBridge `kvCacheRewindReserveTokens`, 1024
#   rows — pinned present by `SessionRewindOnDivergenceTests`), and what is left paid is
#   the distance the reserve cannot cover: rows older than the reserve are gone, so an edit
#   further back than 1024 tokens still re-prefills its prefix. That residual is the
#   memory dial, not a correctness dial, which is why it is reported and not asserted.
#
# Run: bash scripts/probes/run.sh 27
PROBE_NAME="27-edited-history-honesty"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

SESSION="PROBE-EDIT-$$"
OLD_WORD="MARLIN"
NEW_WORD="SALMON"
MAX_TOKENS=16

U1="Reply with exactly the word ALPHA and nothing else."
A1="ALPHA"
U2="Remember this codeword: $OLD_WORD. Then reply with exactly OK."
A2="OK"
U2EDITED="Remember this codeword: $NEW_WORD. Then reply with exactly OK."
Q="And now reply with exactly the codeword I gave you, one word only."

msgs() {  # msgs "role|text" ... -> JSON array of messages
  python3 - "$@" <<'PY'
import json, sys
out = []
for a in sys.argv[1:]:
    role, text = a.split("|", 1)
    out.append({"role": role, "content": text})
print(json.dumps(out))
PY
}

ask() {  # ask <label> <prompt_tokens_var> <messages-json...> ; sets ANS/PROMPT/CACHED/STATUS
  local body
  body="$(probe_chat_body "$SESSION" "$(msgs "$@")" "$MAX_TOKENS")"
  probe_chat "$SESSION" "$body"
  ANS="$(probe_json "${PROBE_BODY:-}" 'choices.0.message.content')"
  PROMPT="$(probe_json "${PROBE_BODY:-}" 'usage.prompt_tokens')"
  CACHED="$(probe_json "${PROBE_BODY:-}" 'usage.prompt_tokens_details.cached_tokens')"
}

# ask_json_turn <messages...> — the same feed with response_format json_object attached,
# which routes the turn through GuidedGenerationLoop (that lane builds its own KV cache).
ask_json_turn() {
  local body
  body="$(probe_chat_body "$SESSION" "$(msgs "$@")" 40)"
  body="${body%?},\"response_format\":{\"type\":\"json_object\"}}"
  probe_chat "$SESSION" "$body"
  ANS="$(probe_json "${PROBE_BODY:-}" 'choices.0.message.content')"
  PROMPT="$(probe_json "${PROBE_BODY:-}" 'usage.prompt_tokens')"
  CACHED="$(probe_json "${PROBE_BODY:-}" 'usage.prompt_tokens_details.cached_tokens')"
}

probe_boot
probe_require_ready_model
MODEL="$PROBE_MODEL"

probe_section "1) premise — the conversation builds, and an appended turn reuses KV"
ask "user|$U1"
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "turn 1 -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
else
  probe_ok "turn 1 (cold) 200 — prompt_tokens=${PROMPT:-?} cached_tokens=${CACHED:-none}"
fi
ask "user|$U1" "assistant|$A1" "user|$U2"
[ "${PROBE_STATUS:-}" = "200" ] \
  && probe_ok "turn 2 200 — prompt_tokens=${PROMPT:-?} cached_tokens=${CACHED:-none}" \
  || probe_fail "turn 2 -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
ask "user|$U1" "assistant|$A1" "user|$U2" "assistant|$A2" "user|$Q"
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "turn 3 (appended) -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
  APPEND_CACHED=0
else
  APPEND_CACHED="${CACHED:-0}"
  probe_ok "turn 3 (appended) 200 — prompt_tokens=${PROMPT:-?} cached_tokens=${APPEND_CACHED:-?}"
  if [ "${APPEND_CACHED:-0}" -gt 0 ]; then
    probe_ok "premise holds: an appended turn reuses $APPEND_CACHED token(s) — so the edit below is measured against a real baseline"
  else
    probe_fail "no reuse on a plain appended turn (cached_tokens=${APPEND_CACHED:-absent}) — the baseline is missing, so no cost claim below would mean anything"
  fi
  if printf '%s' "${ANS:-}" | grep -qi "$OLD_WORD"; then
    probe_ok "the appended turn answers with the codeword it was given (${ANS:0:40})"
  else
    probe_fail "the appended turn did not answer with ${OLD_WORD} (got: ${ANS:0:80}) — the mechanism under test is not working, so the edit test would certify nothing"
  fi
fi

probe_section "2) the edit is observed, not leaked — the answer must come from the history sent"
ask "user|$U1" "assistant|$A1" "user|$U2EDITED" "assistant|$A2" "user|$Q"
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "turn 4 (edited resend) -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
else
  EDIT_PROMPT="${PROMPT:-0}"
  EDIT_CACHED="${CACHED:-0}"
  if printf '%s' "${ANS:-}" | grep -qi "$NEW_WORD"; then
    probe_ok "the edited history is what answered: ${ANS:0:40}"
  else
    probe_fail "after rewording the codeword turn to ${NEW_WORD}, the answer was: ${ANS:0:80} — the rewrite did not reach the model"
  fi
  if printf '%s' "${ANS:-}" | grep -qi "$OLD_WORD"; then
    probe_fail "STALE CONTEXT LEAK: the replaced codeword ${OLD_WORD} appears in the answer after the edit — the refuse-and-rebuild rule is not preventing what it exists to prevent"
  else
    probe_ok "no leak: ${OLD_WORD} is absent from the answer — the KV that described the pre-edit conversation did not answer this turn"
  fi
fi

probe_section "3) honest accounting on the turn that paid"
if [ "${PROBE_STATUS:-}" = "200" ]; then
  if [ "${EDIT_PROMPT:-0}" -ge "${EDIT_CACHED:-0}" ] && [ "${EDIT_PROMPT:-0}" -gt 0 ]; then
    probe_ok "usage is self-consistent: prompt_tokens=${EDIT_PROMPT} >= cached_tokens=${EDIT_CACHED}"
  else
    probe_fail "a breakdown larger than its whole: prompt_tokens=${EDIT_PROMPT} cached_tokens=${EDIT_CACHED}"
  fi
  if [ "${EDIT_CACHED:-0}" -le "${APPEND_CACHED:-0}" ]; then
    probe_ok "the edited turn claims no more reuse (${EDIT_CACHED}) than the extended turn got (${APPEND_CACHED})"
  else
    probe_fail "the edited turn claims cached_tokens=${EDIT_CACHED} > the appended turn's ${APPEND_CACHED} — the surface is promising reuse the engine did not deliver"
  fi
  if [ "${EDIT_CACHED:-0}" -gt 0 ]; then
    probe_ok "the edited resend reused ${EDIT_CACHED}/${EDIT_PROMPT} token(s) — the shared prefix was kept instead of re-prefilled"
  else
    probe_fail "the edited resend re-prefilled the whole conversation (cached_tokens=${EDIT_CACHED:-0}) — the rewind never reached the cache, so this turn still costs the full prompt"
  fi
fi

probe_section "4) the ledger records a rewind, not a refusal"
ENC_MODEL="$(python3 -c 'import sys;print(sys.argv[1].replace("/", "%2F"))' "$MODEL")"
probe_api GET "/v1/models/${ENC_MODEL}/kv-cache"
if [ "${PROBE_STATUS:-}" = "200" ]; then
  RR_DIVERGED="$(probe_json "$PROBE_BODY" 'reuseRefusals.byReason.historyDiverged')"
  if [ "${RR_DIVERGED:-0}" -eq 0 ]; then
    probe_ok "historyDiverged=${RR_DIVERGED:-0} — this edit was rewound onto the shared prefix, not discarded and rebuilt"
  else
    probe_fail "reuseRefusals.byReason.historyDiverged=${RR_DIVERGED} — the pool threw this conversation's cache away instead of rewinding it"
  fi
  PR_LAST_CACHED="$(probe_json "$PROBE_BODY" 'prefixReuse.lastCached')"
  PR_LAST_PREFILL="$(probe_json "$PROBE_BODY" 'prefixReuse.lastPrefilled')"
  if [ "${PR_LAST_CACHED:-0}" -gt 0 ] && [ "${PR_LAST_PREFILL:-0}" -gt 0 ]; then
    probe_ok "kv-cache publishes the same turn the usage field reported: cached=${PR_LAST_CACHED}, prefilled=${PR_LAST_PREFILL} — measured by the engine, not inferred by this probe"
  else
    probe_fail "prefixReuse reports lastCached=${PR_LAST_CACHED:-absent} lastPrefilled=${PR_LAST_PREFILL:-absent} after a turn that reused ${EDIT_CACHED:-?} tokens — the wire and the usage field disagree"
  fi
else
  probe_fail "GET /v1/models/<model>/kv-cache -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:160}"
fi

probe_section "5) a turn that routes around the pooled session declines the rewind, and says so"
# Guided gen (and MTP) build their own KV cache and hand the pooled slot back before
# generating, so a rewind offered to those turns is never spent. Measured 10-22 before the
# lane gate existed: an edited resend carrying response_format logged
# "Session REWOUND ... instead of re-prefilling 2" and then paid all 753 tokens cold, while
# the pool had already skipped the historyDiverged booking for a refusal the turn did pay.
# If a future change teaches the guided lane to reuse the pooled cache, this section is the
# leg that has to be re-audited: the claims and the spend must move together.
SESSION="PROBE-EDIT-BYPASS-$$"
LOG_BEFORE="$(wc -l < "${PROBE_LOG:-/dev/null}" 2>/dev/null | tr -d '[:space:]')"
LOG_BEFORE="${LOG_BEFORE:-0}"
ask "user|$U1" "assistant|$A1" "user|$U2"
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "bypass-lane setup turn -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
else
  probe_ok "bypass-lane premise: standard turn 200 — prompt_tokens=${PROMPT:-?} cached_tokens=${CACHED:-none}"
fi
ask_json_turn "user|$U1" "assistant|$A1" "user|$U2EDITED" "assistant|$A2" "user|$Q"
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "bypass-lane edited resend -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
else
  SECTION_LOG="$(tail -n "+$((LOG_BEFORE + 1))" "${PROBE_LOG:-/dev/null}" 2>/dev/null)"
  if printf '%s' "${ANS:-}" | grep -qi "$NEW_WORD" \
    && ! printf '%s' "${ANS:-}" | grep -qi "$OLD_WORD"; then
    probe_ok "the guided lane answers from the edited history too: ${ANS:0:50}"
  else
    probe_fail "on a grammar-constrained edited resend the answer was: ${ANS:0:80} — expected ${NEW_WORD} with ${OLD_WORD} absent"
  fi
  if printf '%s\n' "$SECTION_LOG" | grep -q "REWOUND for $SESSION"; then
    probe_fail "the log claims a rewind (REWOUND for $SESSION) on a turn that generates around the pooled ChatSession — cached_tokens=${CACHED:-none} says the spend never happened"
  else
    probe_ok "no rewind claimed on this lane — the pool was not asked to keep a cache this turn cannot spend"
  fi
  if printf '%s\n' "$SECTION_LOG" | grep -q "$SESSION.*building a clean session"; then
    probe_ok "the refusal is stated honestly (building a clean session), not dressed as a rewind"
  else
    probe_fail "no honest refusal line for $SESSION — the turn rebuilt a session and nothing in the log says so"
  fi
  if [ "${CACHED:-0}" -eq 0 ]; then
    probe_ok "usage agrees with the claim: cached_tokens=${CACHED:-none} on a cold guided-lane turn"
  else
    probe_fail "cached_tokens=${CACHED} on a lane that is not supposed to spend the pooled cache — either the lane changed or this probe's premise did"
  fi
  ENC_MODEL2="$(python3 -c 'import sys;print(sys.argv[1].replace("/", "%2F"))' "$MODEL")"
  probe_api GET "/v1/models/${ENC_MODEL2}/kv-cache"
  RR2="$(probe_json "${PROBE_BODY:-}" 'reuseRefusals.byReason.historyDiverged')"
  if [ "${RR2:-0}" -ge 1 ]; then
    probe_ok "historyDiverged=${RR2} — the declined rewind is booked as the refusal it was (section 4 counted 0 for the turn that actually rewound)"
  else
    probe_fail "reuseRefusals.byReason.historyDiverged=${RR2:-absent} after a bypass-lane divergence — a full rebuild went unreported on the wire"
  fi
fi

probe_note "MEASURED: appended turn reused ${APPEND_CACHED:-?} tokens; edited turn reused ${EDIT_CACHED:-0} of ${EDIT_PROMPT:-?} and paid $((${EDIT_PROMPT:-0} - ${EDIT_CACHED:-0})). The paid remainder is the distance the 1024-row rewind reserve (MLXBridge kvCacheRewindReserveTokens) cannot cover — rows older than the reserve are gone, so an edit further back still re-prefills its prefix. Size it by memory, not by correctness: pre-reserve this same turn reused 0 of 758."

probe_summary "$PROBE_NAME"
