#!/usr/bin/env bash
# 16-tool-declaration-duplication.sh — does one declared tool reach the model once or twice?
#
# ### Why (AGENTS.md § Open "tools[] 的真相集是声明" + policy 3 "consume upstream")
# A declared tool reaches the model through TWO seams at once on this server:
#   1. our own prose — MessageBuilder Phase 5 appends `Available tools:\n## Tool: <name>\n
#      Description: <desc>` to the system message (Handlers/MessageBuilder.swift);
#   2. the checkpoint's own chat template — upstream feeds `ChatSession.tools` into
#      `tokenizer.applyChatTemplate(messages:tools:)` (mlx-swift-lm
#      Libraries/MLXVLM/Models/Gemma4.swift:2192 `tools: input.tools`), and the checkpoint's
#      chat_template.jinja renders each tool as `<|tool>declaration<tool|>` inside the system
#      turn.
# vllm/sglang have exactly ONE: the schema goes into the template and nowhere else
# (vllm `entrypoints/openai/chat_utils.py` parses `tools[]` into the template's `tools`
# variable; sglang `srt/entrypoints/openai/protocol.py` converts to function dicts and hands
# them to the renderer). A second, hand-written copy of the same surface is ours.
#
# This probe does NOT decide whether removing our prose is correct — that is per checkpoint,
# because a template that ignores `tools` sees only our prose. It measures, per checkpoint:
# what ONE declared tool costs the delivered prompt, and how much of that our prose accounts
# for. The residue is the template rendering the same tool again.
#
# ### What is measured
#   1. Premise — this checkpoint emits a real `tool_calls` turn for a declared tool. Without
#      it §2 has nothing to duplicate, so §2 is reported vacuous and the run fails.
#   2. Delivery cost of one tool: delivered `usage.prompt_tokens` (tools) − (no tools).
#   3. What our prose accounts for: the same pair on this server's own disclosure line
#      (`promptTokens=`, same tokenizer, template excluded), cross-checked by `systemChars=`.
#   4. Verdict: |Δdelivered − Δours| within 16 tokens ⇒ one declaration (PASS). A residue
#      above that ⇒ the checkpoint rendered the tool a second time: XFAIL `open` with both
#      numbers, and the day the prose stops being injected the residue collapses and the
#      harness reports XPASS as a failure — an expired exception must not pass quietly.
#
# Needs a real Metal device: run unsandboxed (`bash scripts/probes/run.sh 16`).
#
# Run: bash scripts/probes/16-tool-declaration-duplication.sh
PROBE_NAME="16-tool-declaration-duplication"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
probe_boot
probe_require_ready_model

PROBE_TMP="$(mktemp -d -t ocoreai-probe16-XXXXXX)"
probe_atexit "rm -rf \"$PROBE_TMP\""

ASK="What is the weather in Singapore right now?"
TOOL='{"type":"function","function":{"name":"get_weather","description":"Get the current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string","description":"City name"}},"required":["city"]}}}'

json_get() { python3 -c "import sys,json;print(json.load(sys.stdin)$1)" 2>/dev/null; }

# Counts the calls on a non-streaming turn: OpenAI puts them on the message
# (`choices[0].message.tool_calls`), one pass through json so argument payloads with
# newlines or non-ASCII cannot break the count.
tool_call_count() { python3 -c "import sys,json;print(len(json.load(sys.stdin)['choices'][0]['message'].get('tool_calls') or []))" 2>/dev/null; }

# This server's own estimate for the LAST assembly line matching a tool count.
disclosure() {
  local tools="$1" key="$2"
  grep -o "Assembled prompt \[chat\].*" "$PROBE_LOG" \
    | grep " declaredTools=$tools " \
    | tail -1 \
    | grep -o "$key=[0-9]*" | cut -d= -f2
}

ask_turn() {
  local session="$1" with_tools="$2" body
  if [ "$with_tools" = "yes" ]; then
    body="{\"model\":\"$PROBE_MODEL\",\"session_id\":\"$session\",\"max_tokens\":64,\"temperature\":0.0,\"messages\":[{\"role\":\"user\",\"content\":\"$ASK\"}],\"tools\":[$TOOL]}"
  else
    body="{\"model\":\"$PROBE_MODEL\",\"session_id\":\"$session\",\"max_tokens\":64,\"temperature\":0.0,\"messages\":[{\"role\":\"user\",\"content\":\"$ASK\"}]}"
  fi
  probe_chat "$session" "$body"
}

SFX="$$"

printf '\n── 1 — premise: this checkpoint answers a declared tool with a tool call\n'
ask_turn "p16-call-$SFX" yes
if [ "$PROBE_STATUS" != "200" ]; then
  probe_fail "declared-tool turn returned HTTP $PROBE_STATUS — nothing to measure"
  probe_summary "$PROBE_NAME"
  exit 1
fi
FINISH=$(echo "$PROBE_BODY" | json_get "['choices'][0].get('finish_reason')")
CALLS=$(echo "$PROBE_BODY" | json_get "['choices'][0].get('tool_calls') or []" | python3 -c "import sys,ast;print(len(ast.literal_eval(sys.stdin.read())))")
CALLS=$(echo "$PROBE_BODY" | tool_call_count)
probe_note "declared-tool turn: finish_reason=$FINISH tool_calls=$CALLS"
if [ "${CALLS:-0}" -ge 1 ]; then
  probe_ok "the model calls the declared tool — the surface under test is live"
else
  probe_fail "no tool call on a declared-tool turn (finish=$FINISH): §2 would measure a surface the model never sees, so §2 is vacuous here"
  probe_summary "$PROBE_NAME"
  exit 1
fi

printf '\n── 2 — what ONE declared tool costs the delivered prompt\n'
ask_turn "p16-notool-$SFX" no
NO_TOKENS=$(echo "$PROBE_BODY" | json_get "['usage']['prompt_tokens']")
E_NO=$(disclosure 0 promptTokens)
S_NO=$(disclosure 0 systemChars)
ask_turn "p16-onetool-$SFX" yes
ONE_TOKENS=$(echo "$PROBE_BODY" | json_get "['usage']['prompt_tokens']")
E_ONE=$(disclosure 1 promptTokens)
S_ONE=$(disclosure 1 systemChars)

if [ -z "$NO_TOKENS" ] || [ -z "$ONE_TOKENS" ] || [ -z "$E_NO" ] || [ -z "$E_ONE" ]; then
  probe_fail "missing numbers (delivered=$NO_TOKENS/$ONE_TOKENS ours=$E_NO/$E_ONE) — §2 cannot decide"
  probe_summary "$PROBE_NAME"
  exit 1
fi

DELTA=$(( ONE_TOKENS - NO_TOKENS ))
OURS=$(( E_ONE - E_NO ))
RESIDUE=$(( DELTA - OURS ))
CHARS=$(( S_ONE - S_NO ))
probe_note "one declared tool: delivered prompt_tokens $NO_TOKENS -> $ONE_TOKENS (delta $DELTA)"
probe_note "our prose by this server's own tokenizer: promptTokens $E_NO -> $E_ONE (delta $OURS), systemChars +$CHARS"
probe_note "residue attributed to the checkpoint's own template rendering the tool: $RESIDUE tokens"

if [ "$DELTA" -le 0 ]; then
  probe_fail "declaring a tool changed nothing in the delivered prompt (delta $DELTA) — either the surface never reached the model or §1 lied"
elif [ "$RESIDUE" -le 16 ]; then
  probe_ok "one tool costs one declaration (delivered $DELTA ≈ ours $OURS) — no duplication on this checkpoint"
else
  probe_xfail open "this declared tool is written to the model twice: our prose costs ~$OURS tokens and the delivered prompt grew $DELTA, so the checkpoint's template added ~$RESIDUE more for the same tool (its chat template renders <|tool>…<tool|> per entry)"
fi

printf '\n── 3 — scaling: the residue grows with the surface, not with our prose\n'
TOOL2='{"type":"function","function":{"name":"get_time","description":"Get the current time in a timezone","parameters":{"type":"object","properties":{"timezone":{"type":"string","description":"IANA timezone name"}},"required":["timezone"]}}}'
body2="{\"model\":\"$PROBE_MODEL\",\"session_id\":\"p16-twotools-$SFX\",\"max_tokens\":64,\"temperature\":0.0,\"messages\":[{\"role\":\"user\",\"content\":\"$ASK\"}],\"tools\":[$TOOL,$TOOL2]}"
probe_chat "p16-twotools-$SFX" "$body2"
TWO_TOKENS=$(echo "$PROBE_BODY" | json_get "['usage']['prompt_tokens']")
E_TWO=$(disclosure 2 promptTokens)
DELTA2=$(( TWO_TOKENS - NO_TOKENS ))
OURS2=$(( E_TWO - E_NO ))
RESIDUE2=$(( DELTA2 - OURS2 ))
probe_note "two declared tools: delivered delta $DELTA2, ours $OURS2, residue $RESIDUE2 (one tool: residue $RESIDUE)"
if [ "$RESIDUE2" -ge "$RESIDUE" ]; then
  probe_note "residue grows with the surface (+$(( RESIDUE2 - RESIDUE )) for the second tool) — it is per-tool, not a one-off template overhead"
else
  probe_fail "residue did not grow with the surface ($RESIDUE -> $RESIDUE2): the per-tool attribution in §2 is not the mechanism"
fi

probe_summary "$PROBE_NAME"
