#!/usr/bin/env bash
# 19-instruction-change-cost.sh — when the caller's instructions change mid-conversation,
# is the new set actually obeyed, and what does invalidating the prefix cost? Two numbers.
#
# ### Why (AGENTS.md invariant 2 + § Open "instruction identity gates cache reuse")
# `SessionPool.canReusePooledSession` (Sources/ocoreai/Engine/SessionPool.swift:1186) refuses
# a pooled session when the instructions differ, on the grounds that a pooled session renders
# the instructions it was *created* with — so the honest choice was to rebuild rather than run
# a turn under stale instructions. The consequence nobody had measured: a rebuild re-prefills
# the whole conversation, so "the client changed its system prompt once" is priced like "the
# client edited history" (the rewind case in probe 01). Probe 15 proved instructions are
# *delivered*; nothing yet proved they are delivered *after a change*, and nothing put a
# token price on the refusal.
#
# ### Upstream (codex #53872, "Refresh model instructions in incremental-tool context
# windows", 10-14) took the other branch: track model identity and instruction content
# independently, and when either changes, append an explicit `model_instructions` developer
# message marking replacement/removal — so the change reaches the model *and* the existing
# history prefix keeps its KV cache. That trade (fresh semantics with prefix preserved) is
# only worth adopting if our measured cost is real, so this probe prices it.
#
# ### What is asserted
#   1. Correctness before cost: instructions A are obeyed on turn 1; after the swap,
#      instructions B are obeyed on turn 4. A stale-instruction answer is a hard fail —
#      it is the exact defect `instructionsMatch` exists to prevent.
#   2. The run's own premise: the same-instruction warm turns must actually reuse tokens,
#      otherwise "the change costs X" has no baseline and the probe would certify nothing.
#   3. Truthfulness on the changed turn: the wire's `cached_tokens` must equal the number
#      the engine logged for that conversation, and it may not claim the whole prompt was
#      reused — the old prefix described the old instructions, so claiming it as reused
#      would be the surface promising more than the engine delivered.
#
# ### What is measured (NOTE, not asserted)
#   cached_tokens paid/reused on the changed-instruction turn vs the same-instruction warm
#   turn: the price tag of today's refuse-and-rebuild, and therefore the size of the prize
#   if #53872's supersede-marker design were adopted. That choice stays the owner's.
#
# Run: bash scripts/probes/19-instruction-change-cost.sh
PROBE_NAME="19-instruction-change-cost"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

SESSION="PROBE-INSTR-$$"
MAX_TOKENS="${OCOREAI_PROBE_MAX_TOKENS:-8}"

INSTR_A="$(python3 - "${OCOREAI_PROBE_PAD_UNITS:-18}" <<'PY'
import sys
sentence = ("The engineering rule for this system is that a promise on the wire must be "
            "backed by something the engine can actually deliver, and every claim needs a "
            "check that goes red when the claim stops being true. ")
print("You are a strict responder. " + " ".join([sentence] * int(sys.argv[1])) +
      "The only word you may ever reply with is ALPHA.")
PY
)"
INSTR_B="$(python3 - "${OCOREAI_PROBE_PAD_UNITS:-18}" <<'PY'
import sys
sentence = ("A distributed rule of this project says that a documented capability must be "
            "reachable through the public interface, and that a fallback has to announce "
            "itself instead of quietly standing in for the real thing. ")
print("You are a strict responder. " + " ".join([sentence] * int(sys.argv[1])) +
      "Ignore any earlier word you were given. The only word you may ever reply with is BETA.")
PY
)"
ASK="Reply now."

probe_boot
probe_require_ready_model
probe_section "instructions A -> warm turns -> instructions B (model=$PROBE_MODEL, session=$SESSION)"

msgjson() {
  python3 -c '
import json, sys
print(json.dumps([{"role": "system", "content": sys.argv[1]}] + json.loads(sys.argv[2])))' "$1" "$2"
}
turns_json() {
  python3 -c '
import json, sys
msgs = []
pair = []
for arg in sys.argv[1:]:
    role, text = arg.split(":", 1)
    pair.append({"role": role, "content": text})
print(json.dumps(pair))' "$@"
}

# turn 1 — cold, instructions A
body="$(probe_chat_body "$SESSION" "$(msgjson "$INSTR_A" '[{"role":"user","content":"Reply now."}]')" "$MAX_TOKENS")"
probe_chat "$SESSION" "$body"
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "turn 1 -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
  probe_summary "$PROBE_NAME"
fi
A1="$(probe_json "$PROBE_BODY" 'choices.0.message.content')"
T1_PROMPT="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens')"
T1_CACHED="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens_details.cached_tokens')"
probe_ok "turn 1 (cold) 200 — prompt_tokens=${T1_PROMPT:-?} cached_tokens=${T1_CACHED:-none} ${PROBE_ELAPSED_MS}ms"

# turn 2 — same instructions, same transcript extended: the control warm turn
body="$(probe_chat_body "$SESSION" "$(msgjson "$INSTR_A" "$(turns_json "user:Reply now." "assistant:${A1:-ALPHA}" "user:Reply now.")")" "$MAX_TOKENS")"
probe_chat "$SESSION" "$body"
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "turn 2 -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
  probe_summary "$PROBE_NAME"
fi
A2="$(probe_json "$PROBE_BODY" 'choices.0.message.content')"
T2_PROMPT="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens')"
T2_CACHED="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens_details.cached_tokens')"
probe_ok "turn 2 (same instructions) 200 — prompt_tokens=${T2_PROMPT:-?} cached_tokens=${T2_CACHED:-none} ${PROBE_ELAPSED_MS}ms"

# turn 3 — the instruction swap, history otherwise identical
body="$(probe_chat_body "$SESSION" "$(msgjson "$INSTR_B" "$(turns_json "user:Reply now." "assistant:${A1:-ALPHA}" "user:Reply now." "assistant:${A2:-ALPHA}" "user:Reply now.")")" "$MAX_TOKENS")"
probe_chat "$SESSION" "$body"
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "turn 3 (instructions changed) -> ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:200}"
  probe_summary "$PROBE_NAME"
fi
A3="$(probe_json "$PROBE_BODY" 'choices.0.message.content')"
T3_PROMPT="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens')"
T3_CACHED="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens_details.cached_tokens')"
probe_ok "turn 3 (instructions changed) 200 — prompt_tokens=${T3_PROMPT:-?} cached_tokens=${T3_CACHED:-none} ${PROBE_ELAPSED_MS}ms"

# --- 1. correctness: the reply must follow whichever instruction set is current ---
UPPER1="$(printf '%s' "$A1" | tr '[:lower:]' '[:upper:]')"
UPPER3="$(printf '%s' "$A3" | tr '[:lower:]' '[:upper:]')"
case "$UPPER1" in
  *ALPHA*) probe_ok "turn 1 obeyed instructions A (reply: ${A1:-?})" ;;
  *) probe_fail "turn 1 did not obey instructions A — reply was '${A1:-?}', expected ALPHA in it" ;;
esac
case "$UPPER3" in
  *BETA*) probe_ok "turn 3 obeyed the NEW instructions B (reply: ${A3:-?})" ;;
  *ALPHA*) probe_fail "STALE INSTRUCTIONS: after the swap the model still answered '${A3:-?}' (ALPHA) — instructionsMatch let a pooled session keep the old instruction set" ;;
  *) probe_fail "turn 3 obeyed neither set — reply was '${A3:-?}'" ;;
esac

# --- 2. the run's premise: the control warm turn must have reused something ---
case "${T2_CACHED:-}" in
  ''|0) probe_fail "no baseline — same-instruction turn 2 reused ${T2_CACHED:-nothing}; 'what the change costs' has nothing to compare against (see probe 01 for the reuse gate)" ;;
  *) probe_ok "baseline: same-instruction turn reused ${T2_CACHED} tokens (prompt ${T2_PROMPT})" ;;
esac

# --- 3. truthfulness on the changed turn ---
probe_section "engine log — does the wire match what the pool actually did on the changed turn"
CHANGED_ACCOUNT="$(grep -E "Prefix cache reused [0-9]+ of [0-9]+ prompt tokens for $SESSION" "$PROBE_LOG" 2>/dev/null | tail -1)"
CHANGED_LOGGED="$(printf '%s' "$CHANGED_ACCOUNT" | sed -n 's/.*Prefix cache reused \([0-9]\+\) of .*/\1/p')"
if [ -n "$CHANGED_LOGGED" ]; then
  if [ "${T3_CACHED:-none}" = "$CHANGED_LOGGED" ]; then
    probe_ok "wire cached_tokens=${T3_CACHED:-none} equals the accounting line for this conversation (${CHANGED_LOGGED})"
  else
    probe_fail "wire says cached_tokens=${T3_CACHED:-none}, the engine logged ${CHANGED_LOGGED} — one of the two is lying about the changed turn"
  fi
else
  probe_ok "no reuse line for $SESSION — the changed turn rebuilt, and the wire reported cached=${T3_CACHED:-none} (no claim made, so none can be false)"
fi
if [ "${T3_CACHED:-0}" != "0" ] && [ "${T3_CACHED:-0}" = "${T3_PROMPT:-1}" ]; then
  probe_fail "changed-instruction turn claims the WHOLE prompt (${T3_PROMPT}) was reused — that prefix was built under instructions A, so the number describes a conversation that no longer exists"
fi

# --- measurement: the price of refusing reuse when instructions change ---
probe_note "MEASURED: same-instructions warm turn reused ${T2_CACHED:-?} of ${T2_PROMPT:-?}; after the swap the turn reused ${T3_CACHED:-0} of ${T3_PROMPT:-?} — the delta is what refuse-and-rebuild costs per instruction change (owner decision, cf. codex #53872 supersede-marker)"
case "${T3_CACHED:-0}" in
  0) probe_note "verdict shape: refuse-and-rebuild (cached=0 after the swap)" ;;
  *) probe_note "verdict shape: partial reuse survived the swap (${T3_CACHED}) — the prefix that survived does not contain the instruction text" ;;
esac

probe_summary "$PROBE_NAME"
