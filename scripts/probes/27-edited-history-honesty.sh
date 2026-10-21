#!/usr/bin/env bash
# 27-edited-history-honesty.sh — when a caller rewrites the past, does the answer come from
# the history it actually sent, and what does that turn really pay?
#
# ### Why (AGENTS.md § Open "改历史的那一轮仍付全量")
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
#   2. THE PRIZE — § Open keeps the rewind reserve ("接不接仍待样本") pending samples, but
#      the size of the prize was never stated in tokens on the same run as the correctness
#      check, so the decision had no number attached to it.
#
# ### What is asserted
#   1. The run's own premise: an appended warm turn reuses (`cached_tokens > 0`) — without
#      it "the edit costs X" has no baseline (a probe that certifies nothing is the shape
#      AGENTS.md invariant 1 is about).
#   2. The codeword mechanism: the appended turn answers with the codeword it was given.
#   3. THE EDIT IS OBSERVED: after the codeword turn is reworded, the answer must be the
#      NEW codeword and the OLD one must not appear anywhere in the reply. This is the
#      leak the refuse-and-rebuild exists to prevent.
#   4. Honest accounting on that turn: `prompt_tokens >= cached_tokens`, and the reused part
#      may not exceed what the warm appended turn reused (a rebuild that reports more reuse
#      than the extension is the surface promising more than the engine delivered).
#   5. The ledger names this run's refusal (`historyDiverged >= 1`) — cost and cause on one
#      surface, not one without the other.
#
# ### What is measured (NOTE, not asserted)
#   paid = prompt_tokens - cached_tokens on the edited turn, against the reused count of the
#   appended turn: that pair IS the sample the rewind-reserve decision asked for (upstream
#   #622 `KVCacheConfiguration.rewind(maxTokens:)` + `RewindToCommonPrefixRule` exist at our
#   pin and are not requested here). Wiring it is a memory decision, so the number is
#   evidence, not a gate.
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
    probe_ok "the rebuilt turn claims no more reuse (${EDIT_CACHED}) than the extended turn got (${APPEND_CACHED})"
  else
    probe_fail "the edited turn claims cached_tokens=${EDIT_CACHED} > the appended turn's ${APPEND_CACHED} — the surface is promising reuse the engine did not deliver"
  fi
fi

probe_section "4) the refusal is named on the same surface that prices it"
ENC_MODEL="$(python3 -c 'import sys;print(sys.argv[1].replace("/", "%2F"))' "$MODEL")"
probe_api GET "/v1/models/${ENC_MODEL}/kv-cache"
if [ "${PROBE_STATUS:-}" = "200" ]; then
  RR_DIVERGED="$(probe_json "$PROBE_BODY" 'reuseRefusals.byReason.historyDiverged')"
  if [ "${RR_DIVERGED:-0}" -ge 1 ]; then
    probe_ok "kv-cache publishes historyDiverged=${RR_DIVERGED} — the edit's refusal is on the wire, not only in the log"
  else
    probe_fail "this run edited a conversation, yet reuseRefusals.byReason.historyDiverged=${RR_DIVERGED:-absent}"
  fi
else
  probe_fail "GET /v1/models/<model>/kv-cache -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:160}"
fi

probe_note "SAMPLE for the rewind-reserve decision (§ Open): appended turn reused ${APPEND_CACHED:-?} tokens; edited turn paid $((${EDIT_PROMPT:-0} - ${EDIT_CACHED:-0})) of ${EDIT_PROMPT:-?} (cached ${EDIT_CACHED:-0}). That paid figure is what a rewind reserve (upstream #622 KVCacheConfiguration.rewind(maxTokens:) + RewindToCommonPrefixRule, both present at pin 48114eedf and not requested here) would aim to skip; it is reported, not asserted, because reserving rows costs memory and the wiring is an owner call."

probe_summary "$PROBE_NAME"
