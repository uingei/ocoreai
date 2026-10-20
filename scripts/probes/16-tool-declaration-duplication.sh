#!/usr/bin/env bash
# 16-tool-declaration-duplication.sh — does one declared tool reach the model once or twice?
#
# ### Why (AGENTS.md § "A declared tool is written to the prompt once" + policy 3)
# A declared tool used to reach the model through TWO seams at once:
#   1. our own prose — MessageBuilder Phase 5 appended `Available tools:\n## Tool: <name>\n
#      Description: <desc>` to the system message;
#   2. the checkpoint's own chat template — upstream feeds `ChatSession.tools` into
#      `tokenizer.applyChatTemplate(messages:tools:)` (mlx-swift-lm
#      Libraries/MLXVLM/Models/Gemma4.swift:2192 `tools: input.tools`), and this checkpoint's
#      chat_template.jinja renders each entry as `<|tool>declaration<tool|>` inside the system
#      turn (:196-203).
# vllm and sglang have one seam: the schema goes into the template and nowhere else
# (vllm `entrypoints/openai/chat_utils.py`; sglang `srt/entrypoints/openai/protocol.py`).
# Measured before the fix on gemma-4-e2b-it-4bit: one tool cost +116 delivered prompt_tokens
# while our prose accounted for +65 — the residue was the template's copy.
#
# ### Contract now: ONE declaration per tool, and the checkpoint decides who writes it
# `ToolProseLedger` measures, at load, whether the template grows when handed a probe tool.
# Phase 5 writes its prose only where the template was measured NOT to render tools; the
# decision and the number of blocks actually written go on one log line.
#
# ### What is measured
#   1. Premise — this checkpoint emits a real `tool_calls` turn for a declared tool; without
#      it the rest measures a surface the model never sees, so the run fails, not passes.
#   2. The load-time decision exists: `Tool prose <mode> for <model> — …`, mode from the
#      closed three-value vocabulary. `injectedUnmeasured` on a model that is loaded and
#      answering is XFAIL: the measurement should have run.
#   3. Exactly one copy per declared tool: under `skippedTemplateRenders` zero `## Tool:`
#      blocks may be written while the delivered prompt still grows (the template carried it);
#      under `injectedTemplateIgnores` our blocks are the declaration and must be ≥1.
#      System-message growth is reported but never decides: the action directive
#      `SystemPromptBuilder` adds for any tool turn is ~215 chars and names no tool, so
#      growth alone cannot tell a duplicate declaration from ordinary prompt text.
#   4. Scaling: at two declared tools the same must hold and the delivered delta must keep
#      scaling — so the count is one per tool, not one per request.
#
# An XFAIL is a live exception, not a skip: it exits 0 with the numbers in the log, and if
# the shape stops reproducing the harness reports XPASS as a failure.
#
# Needs a real Metal device: run unsandboxed (`bash scripts/probes/run.sh 16`).
#
# Run: bash scripts/probes/16-tool-declaration-duplication.sh
PROBE_NAME="16-tool-declaration-duplication"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
probe_boot
probe_require_ready_model

ASK="What is the weather in Singapore right now?"
TOOL='{"type":"function","function":{"name":"get_weather","description":"Get the current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string","description":"City name"}},"required":["city"]}}}'
TOOL2='{"type":"function","function":{"name":"get_time","description":"Get the current time in a timezone","parameters":{"type":"object","properties":{"timezone":{"type":"string","description":"IANA timezone name"}},"required":["timezone"]}}}'

json_get() { python3 -c "import sys,json;print(json.load(sys.stdin)$1)" 2>/dev/null; }

# Counts the calls on a non-streaming turn: OpenAI puts them on the message
# (`choices[0].message.tool_calls`).
tool_call_count() { python3 -c "import sys,json;print(len(json.load(sys.stdin)['choices'][0]['message'].get('tool_calls') or []))" 2>/dev/null; }

# This server's own disclosure values for the last assembly line declaring N tools.
disclosure() {
  local tools="$1" key="$2"
  grep -o "Assembled prompt \[chat\].*" "$PROBE_LOG" \
    | grep " declaredTools=$tools " \
    | tail -1 \
    | grep -o "$key=[0-9]*" | cut -d= -f2
}

# Blocks written for the last turn declaring N tools (line shape lives on ToolProseMode.logLine).
blocks_written() {
  local declared="$1"
  grep -o "Tool prose [a-zA-Z]* for $PROBE_MODEL with $declared declared tool(s), [0-9]* ## Tool: block(s) written" "$PROBE_LOG" \
    | tail -1 \
    | sed -nE 's/.* ([0-9]+) ## Tool.*/\1/p'
}

ask_turn() {
  local session="$1" with_tools="$2" extra="${3:-}" body
  if [ "$with_tools" = "yes" ]; then
    body="{\"model\":\"$PROBE_MODEL\",\"session_id\":\"$session\",\"max_tokens\":64,\"temperature\":0.0,\"messages\":[{\"role\":\"user\",\"content\":\"$ASK\"}],\"tools\":[$TOOL$extra]}"
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
CALLS=$(echo "$PROBE_BODY" | tool_call_count)
probe_note "declared-tool turn: finish_reason=$FINISH tool_calls=$CALLS"
if [ "${CALLS:-0}" -ge 1 ]; then
  probe_ok "the model calls the declared tool — the surface under test is live"
else
  probe_fail "no tool call on a declared-tool turn (finish=$FINISH): §2-§4 would measure a surface the model never sees"
  probe_summary "$PROBE_NAME"
  exit 1
fi

printf '\n── 2 — the checkpoint was measured, and the server says which copy it keeps\n'
MODE_LINE="$(grep -o "Tool prose [a-zA-Z]* for $PROBE_MODEL —.*" "$PROBE_LOG" | head -1)"
MODE="$(printf '%s' "$MODE_LINE" | sed -nE 's/Tool prose ([a-zA-Z]*) .*/\1/p')"
probe_note "load-time decision: ${MODE_LINE:-<none>}"
if [ -z "$MODE" ]; then
  probe_fail "no 'Tool prose …' line for $PROBE_MODEL: the template measurement never ran, so every tool turn here writes its own copy on top of the template's"
elif [ "$MODE" = "injectedUnmeasured" ]; then
  probe_xfail open "this model is loaded and serving turns, yet its template was never measured — the assembly fell back to writing its own prose, so a template that also renders tools carries two copies (defaulting to inject is honest; the measurement should have run)"
else
  probe_ok "the decision is measured and stated: $MODE"
fi

printf '\n── 3 — exactly one declaration reaches the prompt\n'
ask_turn "p16-notool-$SFX" no
NO_TOKENS=$(echo "$PROBE_BODY" | json_get "['usage']['prompt_tokens']")
S_NO=$(disclosure 0 systemChars)
ask_turn "p16-onetool-$SFX" yes
ONE_TOKENS=$(echo "$PROBE_BODY" | json_get "['usage']['prompt_tokens']")
S_ONE=$(disclosure 1 systemChars)
B1=$(blocks_written 1)

if [ -z "$NO_TOKENS" ] || [ -z "$ONE_TOKENS" ] || [ -z "$S_NO" ] || [ -z "$S_ONE" ]; then
  probe_fail "missing numbers (delivered=$NO_TOKENS/$ONE_TOKENS systemChars=$S_NO/$S_ONE) — §3 cannot decide"
else
  GROWTH=$(( S_ONE - S_NO ))
  DELTA=$(( ONE_TOKENS - NO_TOKENS ))
  probe_note "declaring one tool: our system message grew $GROWTH chars (the action directive SystemPromptBuilder adds for any tool turn — it names nothing), delivered prompt_tokens grew $DELTA, ## Tool: blocks written ${B1:-<none>}"
  probe_note "pre-fix, the same turn grew the system message +302 chars and the prompt +116 tokens: ~44 of them this server's action directive, ~21 its ## Tool: block (now gone), ~51 the template's own <|tool> schema"
  case "$MODE" in
    skippedTemplateRenders)
      if [ "${B1:-0}" -eq 0 ] && [ "$DELTA" -ge 16 ]; then
        probe_ok "one copy: zero ## Tool: blocks written, yet the delivered prompt grew $DELTA tokens — the tool arrived once, from the checkpoint's own template"
      elif [ "${B1:-0}" -ne 0 ]; then
        probe_fail "the decision was $MODE but $B1 ## Tool: block(s) were still written — the duplicate declaration is back"
      else
        probe_fail "prose was skipped yet the delivered prompt grew only $DELTA tokens for a declared tool — the tool may not have reached the model at all"
      fi
      ;;
    injectedTemplateIgnores)
      if [ "${B1:-0}" -ge 1 ]; then
        probe_ok "one copy: this template was measured to ignore tools, so our $B1 ## Tool: block(s) are the only declaration the model can see"
      else
        probe_fail "mode $MODE but zero ## Tool: blocks were written — nothing declared the tool"
      fi
      ;;
    injectedUnmeasured)
      probe_xfail open "no measurement for $PROBE_MODEL, so §3 stands on the same unverified ground as §2"
      ;;
    *)
      probe_fail "unknown tool-prose mode '$MODE' — the ledger's vocabulary is closed at three values"
      ;;
  esac
fi

printf '\n── 4 — scaling: one copy per tool, not one per request\n'
ask_turn "p16-twotools-$SFX" yes ",$TOOL2"
TWO_TOKENS=$(echo "$PROBE_BODY" | json_get "['usage']['prompt_tokens']")
S_TWO=$(disclosure 2 systemChars)
B2=$(blocks_written 2)
if [ -z "$S_TWO" ] || [ -z "$NO_TOKENS" ]; then
  probe_fail "missing numbers for the two-tool turn (systemChars=$S_TWO delivered=$TWO_TOKENS) — §4 cannot decide"
else
  GROWTH2=$(( S_TWO - S_NO ))
  DELTA2=$(( TWO_TOKENS - NO_TOKENS ))
  probe_note "declaring two tools: system message +$GROWTH2 chars, delivered +$DELTA2 tokens, ## Tool: blocks written ${B2:-<none>}"
  case "$MODE" in
    skippedTemplateRenders)
      if [ "${B2:-0}" -eq 0 ] && [ "$DELTA2" -ge "$(( DELTA + 16 ))" ]; then
        probe_ok "one copy per tool at two tools: zero blocks written, and the delivered delta scaled +$(( DELTA2 - DELTA )) tokens for the second tool from the template"
      elif [ "${B2:-0}" -ne 0 ]; then
        probe_fail "at two tools, $B2 ## Tool: block(s) were written under $MODE — the duplicate declaration is back"
      else
        probe_fail "the delivered delta stopped scaling with the surface ($DELTA -> $DELTA2) though the template was measured to render tools"
      fi
      ;;
    injectedTemplateIgnores)
      if [ "${B2:-0}" -eq 2 ]; then
        probe_ok "two declared tools, two blocks written — this template ignores tools, so ours are the declarations"
      else
        probe_fail "mode $MODE with ${B2:-0} blocks written for two declared tools — every declared tool must be described"
      fi
      ;;
    *)
      probe_note "§4 reports numbers only, because §2 found the mode to be ${MODE:-unset}"
      ;;
  esac
fi

probe_summary "$PROBE_NAME"
