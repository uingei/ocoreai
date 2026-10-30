#!/usr/bin/env bash
# 44-reasoning-channel-delivery.sh — does thinking reach `reasoning_content`, or the answer?
#
# ### Why (invariant 2: the surface may not claim more than the engine delivered)
# A reasoning model emits thinking and an answer in ONE decoded stream, and a client can only
# un-mix them if the server does it — delimiters are stripped by the template, so a leaked
# span reads as prose. Since mlx-swift-lm #563 the decoder splits them and hands the caller
# `Generation.reasoning` separately, on both lanes this server switches over: `ChatSession`
# (Libraries/MLXLMCommon/ChatSession.swift:1414) and `generate(mtpDrafter:)`
# (Libraries/MLXLMCommon/Evaluate.swift:2574). Before that split the standard lane had no
# arm for the case at all: thinking arrived inside `.chunk`, so it landed in `content`, and
# the MTP lane carried its own `ReasoningEventEmitter` for the same job — one decision with
# two homes, the second of which now scans answer text that cannot contain a delimiter.
#
# ### What is measured
#   1. A turn that asks for thinking delivers a non-empty `reasoning_content`, keeps `content`
#      free of every channel/think delimiter this host's checkpoints use, and reports
#      `usage.completion_tokens_details.reasoning_tokens` > 0. That count is upstream's
#      per-token number, not a character estimate, so it is the field that proves the split
#      happened at the token level rather than in a post-hoc string sweep.
#   2. The face that delivered thinking NOWHERE before: the same ask with `tools[]` declared.
#      Tools (or a grammar) route a turn away from this server's token-level reasoning path,
#      so the turn runs on `ChatSession`, where #563's split is the only thing that can
#      produce reasoning at all. If reasoning vanishes here, the arm went missing.
#   3. `content` never carries thinking AND an answer at once. An interior slice of the thinking
#      must not appear inside an answer. The one documented exception is named rather than
#      ignored: `contentWireFallback` publishes the thought as the answer when the answer
#      channel stayed empty (the FM/SDK path classifies a whole generation into reasoning, so a
#      content-only consumer would read nothing) — that face is reported as a measurement, with
#      the finish_reason that says why the answer was empty.
#
# Deliberately not asserted: that the ANSWER is arithmetically right. That is a checkpoint
# fact (the same rule probe 12 uses for an open grammar), and this probe owns the routing.
#
# Needs a real Metal device and one ready checkpoint that frames a reasoning channel; the
# default arm names Gemma 4 E2B (labeled channels, #563) and asks for thinking explicitly so
# the verdict never depends on a template's default. Override with OCOREAI_PROBE_MODEL.
# Run: bash scripts/probes/44-reasoning-channel-delivery.sh
PROBE_NAME="44-reasoning-channel-delivery"
source "$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)/_lib.sh"

# The arm names its own checkpoint: a delivery verdict inherited from whatever /v1/models
# lists first is a claim about an unknown model.
: "${OCOREAI_PROBE_MODEL:=gemma-4-e2b-it-4bit}"
export OCOREAI_PROBE_MODEL

SESSION_SEQ=0
fresh_session() {
  SESSION_SEQ=$(( SESSION_SEQ + 1 ))
  printf 'probe44-%s-%s' "$$" "$SESSION_SEQ"
}

ASK='What is 17 times 23? Work it out, then give the number.'
# Every delimiter the checkpoints on this host can emit. A leaked span always carries at
# least one of them, and the list is what makes "content is clean" a check rather than a wish.
DELIMS='(<\|channel>|<channel\|>|<\|thinking>|<thinking\|>|<\|think>|<think\|>|<\?\?>|<|im_start|>|<\|end\|>|<thinking>|</thinking>)'

# ask_turn LABEL TOOLS_JSON — one non-streaming turn; sets R_STATUS/R_REASON/R_CONTENT/R_FINISH/R_RT.
ask_turn() {
  local lab="$1" tools="$2" s b
  s="$(fresh_session)"
  b="$(MODEL="$PROBE_MODEL" SESSION="$s" ASK="$ASK" TOOLS="$tools" python3 -c '
import json, os
body = {
    "model": os.environ["MODEL"],
    "session_id": os.environ["SESSION"],
    "temperature": 0.0,
    "max_tokens": 256,
    "reasoning": True,
    "messages": [{"role": "user", "content": os.environ["ASK"]}, ],
}
tools = os.environ.get("TOOLS") or ""
if tools.strip():
    body["tools"] = json.loads(tools)
print(json.dumps(body))')"
  probe_chat "$s" "$b" || true
  R_STATUS="${PROBE_STATUS:-}"
  R_REASON="$(probe_json "$PROBE_BODY" 'choices.0.message.reasoning_content')"
  R_CONTENT="$(probe_json "$PROBE_BODY" 'choices.0.message.content')"
  R_FINISH="$(probe_json "$PROBE_BODY" 'choices.0.finish_reason')"
  R_RT="$(probe_json "$PROBE_BODY" 'usage.completion_tokens_details.reasoning_tokens')"
  printf -- '-- %s\n' "$lab"
  printf '   status=%s finish=%s reasoning_tokens=%s reasoning_chars=%s content_chars=%s\n' \
    "$R_STATUS" "${R_FINISH:-?}" "${R_RT:-absent}" "${#R_REASON}" "${#R_CONTENT}"
  LAST_BODY="$PROBE_BODY"
}

probe_boot
probe_require_ready_model

# Tool specs come from the server's own declared surface, the way scripts/eval/_eval.py reads
# them — a hand-written fake tool would test a channel the product never sends.
probe_api GET /v1/tools || true
TOOL_SPECS="$(PROBE_BODY="$PROBE_BODY" python3 -c '
import json, os, sys
d = json.loads(os.environ["PROBE_BODY"] or "{}")
specs = d.get("data") or d.get("tools") or []
keep = specs[:2]
out = []
for s in keep:
    fn = (s.get("function") or {}).get("name") or s.get("name")
    if not fn:
        continue
    out.append(s if s.get("function") else {
        "type": "function",
        "function": {"name": fn, "description": s.get("description") or fn,
                     "parameters": s.get("parameters") or {"type": "object", "properties": {}}},
    })
sys.stdout.write(json.dumps(out))')"
TOOL_N="$(TOOL_SPECS="$TOOL_SPECS" python3 -c 'import json,os,sys; print(len(json.loads(os.environ["TOOL_SPECS"])))')"
probe_require_int "tool specs read from GET /v1/tools for §2" "$TOOL_N"

# ── 1 — thinking arrives on its own channel ──────────────────────────────────
probe_section "1 — a thinking turn delivers reasoning_content, clean content, and a token count"
ask_turn "no tools, reasoning=true" ""
if [ "$R_STATUS" != "200" ]; then
  probe_fail "the thinking turn returned $R_STATUS — nothing downstream can be about delivery"
else
  probe_ok "200 on a turn that demands thinking"
  if [ -n "$R_REASON" ]; then
    probe_ok "reasoning_content delivered (${#R_REASON} chars)"
  else
    probe_fail "reasoning_content absent on a turn that asked for thinking — the split is not reaching
     the wire: the checkpoint framed no channel, or EngineInference dropped a Generation.reasoning"
  fi
  case "$R_CONTENT" in
    "")
      if [ "$R_FINISH" = "length" ]; then
        probe_note "content empty with finish_reason=length — thinking consumed the budget, an honest
           face; the wire reported it as truncation rather than an answer"
      else
        probe_fail "content empty and finish_reason=$R_FINISH — a thinking-only turn that did not say so"
      fi
      ;;
    *) probe_ok "content non-empty (${#R_CONTENT} chars)" ;;
  esac
  if printf '%s' "$R_CONTENT" | grep -Eq "$DELIMS"; then
    probe_fail "content still carries a channel delimiter ($(printf '%s' "$R_CONTENT" | grep -Eo "$DELIMS" | head -1))
     — the client received thinking inside the answer, which is the face this probe exists for"
  else
    probe_ok "content carries none of the channel/think delimiters"
  fi
  if [ -n "$R_RT" ] && [ "$R_RT" -gt 0 ] 2>/dev/null; then
    probe_ok "usage.completion_tokens_details.reasoning_tokens = $R_RT (upstream's per-token count)"
  else
    probe_fail "reasoning_tokens is ${R_RT:-absent} while reasoning_content carried ${#R_REASON} chars —
     the answer channel and the usage field disagree about whether this turn thought"
  fi
  S1_REASON="$R_REASON"; S1_CONTENT="$R_CONTENT"; S1_FINISH="$R_FINISH"
fi

# ── 2 — the face that used to deliver thinking nowhere ───────────────────────
probe_section "2 — the same ask WITH tools[] declared still delivers reasoning"
if [ "$TOOL_N" -lt 1 ]; then
  probe_fail "§2 cannot run: the server declared no tools, so the ChatSession-with-tools face is untested"
else
  ask_turn "tools declared ($TOOL_N spec(s)), reasoning=true" "$TOOL_SPECS"
  if [ "$R_STATUS" != "200" ]; then
    probe_fail "the with-tools thinking turn returned $R_STATUS"
  elif [ -n "$R_REASON" ]; then
    probe_ok "reasoning_content delivered with tools declared (${#R_REASON} chars)"
    [ -z "$R_RT" ] && probe_note "with-tools turn streams ${#R_REASON} chars of thinking but reports no
       reasoning_tokens: upstream counts them through ThinkingBudgetProcessor
       (Libraries/MLXLMCommon/ThinkingBudget.swift:486), which the ChatSession lane does not install —
       installing it would also bound thinking, so the count waits on that decision, not on this wire"
  else
    probe_fail "tools declared -> reasoning_content EMPTY — the turn ran on ChatSession and its
     Generation.reasoning was dropped: this is exactly the face that had no arm before the split"
  fi
  case "$R_CONTENT" in
    "") probe_note "with-tools turn answered via tool_calls (finish=$R_FINISH) — delivery of the
       reasoning channel is what §2 asserts, not the answer" ;;
    *)
      if printf '%s' "$R_CONTENT" | grep -Eq "$DELIMS"; then
        probe_fail "with-tools content carries a delimiter — the answer channel is dirty on the
         ChatSession lane specifically"
      else
        probe_ok "with-tools content is delimiter-free"
      fi
      ;;
  esac
fi

# ── 3 — the channels are disjoint ────────────────────────────────────────────
probe_section "3 — content never carries thinking AND an answer at once"
if [ -n "${S1_REASON:-}" ] && [ -n "${S1_CONTENT:-}" ]; then
  FACE="$(S1_REASON="$S1_REASON" S1_CONTENT="$S1_CONTENT" python3 -c '
import os
r = os.environ["S1_REASON"]
c = os.environ["S1_CONTENT"]
if c.strip() == r.strip():
    print("fallback")
    raise SystemExit(0)
# An interior slice avoids leading/trailing whitespace accidents at both ends.
probe = r[len(r)//4: len(r)//4 + 60] if len(r) >= 240 else r.strip()
print("LEAK" if probe and probe in c else "clean")')"
  case "$FACE" in
    fallback)
      probe_note "content is exactly the delivered thinking — the thinking-only face of
       contentWireFallback: the answer channel stayed empty (finish_reason=${S1_FINISH:-?}), and the
       thought was published there so a consumer reading only \`content\` still receives something.
       reasoning_content carried the same text, so nothing about the split was lost"
      ;;
    LEAK)
      probe_fail "a 60-char interior slice of the delivered thinking also appears inside an answer —
       thinking was published twice on both channels, which no face of this server asks for"
      ;;
    *) probe_ok "no thinking slice reappears inside the answer" ;;
  esac
else
  probe_fail "§3 has nothing to compare (reasoning or content empty) — §1's premise did not hold,
   so disjointness cannot be claimed"
fi

probe_summary "$PROBE_NAME"
