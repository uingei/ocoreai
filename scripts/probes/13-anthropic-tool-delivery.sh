#!/usr/bin/env bash
# 13-anthropic-tool-delivery.sh — can POST /v1/messages deliver a tool call at all?
#
# ### Why (invariant 2: the surface may not claim more than the engine delivered)
# `/v1/messages` is the Anthropic-compatible face of the same engine that probe 11 proves
# can call tools on `/v1/chat/completions`. Measured 10-19 on this host
# (`mlx-community/gemma-4-e2b-it-4bit`, temperature 0, `tools:[get_weather]`,
# "Use the get_weather tool to check the weather in Paris."):
#   stop_reason = "end_turn"
#   content     = [{"type":"text","text":"Which city are you interested in? Please specify
#                  the city name."}]
# — neither a call nor an answer to the question asked. Four defects sat at one seam, and
# none of them had a gate because every tool test in the suite speaks the OpenAI wire:
#   1. `tools[]` was rendered into system-prompt TEXT (`## Tool: name\nDescription: …`)
#      with no parameter schema, and `InferenceOptions` got no `declaredToolNames`, no
#      `declaredToolSpecsJSON`, no `hasNativeTools`, no grammar — so the engine's tool
#      surface never ran (vllm serving.py:762-791 and sglang serving.py:646-678 both hand
#      the chat request a structured `tools` array instead).
#   2. `case .toolCall: break` in both modes — a call the engine recognised was dropped.
#   3. The response had no `tool_use` shape, and `content_block_start` carried no
#      `content_block`, which is the field SDKs open a block from.
#   4. `input_schema` converted to bare `properties`, dropping `type` and `required`.
#
# ### What is measured
#   1. Non-stream: a demanded call arrives as a `tool_use` content block (id, name, and
#      `input` as a JSON *object*, not a string) with `stop_reason:"tool_use"`.
#   2. Stream: `content_block_start` names a `tool_use` block, arguments arrive as
#      `input_json_delta`/`partial_json`, the block closes, and `message_delta` carries
#      `stop_reason:"tool_use"`.
#   3. Controls: nothing declared, and `tool_choice:{"type":"none"}` — no call either way.
#   4. Declaring without demanding must not cost the answer (Anthropic puts forcing in
#      `tool_choice`, same as OpenAI): an arithmetic question still answers 4.
#   5. `content_block_start` carries `content_block` even on a plain-text turn.
#   6. A delivered call on THIS face moves the shared `tool_call_delivery` gauge on
#      `/v1/models` to `parsed`, with evidence naming the tool.
#   7. `tool_result` continues the loop: the turn after a supplied result reads the result
#      ("17C, light rain" → the answer says 17), and structured history does NOT re-dispatch
#      the call (no new `tool_use`, `stop_reason` is not `tool_use`).
#   8. `thinking` reaches the engine: the assembly line the server logs reads
#      `enableReasoning=on|off|default` for `enabled`/`disabled`/absent (a behavioural
#      difference needs a checkpoint with a thinking channel — this host's ready model has
#      none, measured identical on BOTH faces, so the log line is the delivery proof here),
#      the answer is byte-identical at temp 0 whether the knob is on or off (nothing about
#      it may cost the answer), and `budget_tokens >= max_tokens` comes back 400 naming
#      the field.
#   9. One assembly, both wires: the two faces log the same assembled shape
#      (`systemChars`/`promptTokens`/roles) for the identical request, and report the same
#      `usage` number for it (before: 774 there against 24 here — this face built its own
#      message list and skipped the agent context the OpenAI face injects, then reported its
#      own estimate instead of the engine's measurement). `count_tokens` is checked as a
#      floor within template-framing range of what the request actually charged.
#  10. `POST /v1/steer` for a session reaches the next `/v1/messages` turn carrying that
#      `metadata.session_id`, as `/v1/steer` documents (measured 10-19: swallowed here —
#      "Please provide more context" — while `/v1/chat/completions` delivered the codeword).
#  11. one declared tool vs the prompt it produces: the assembly's schema-less `## Tool:`
#      text is measured against the no-tools baseline and recorded (two copies reach the
#      model — structured spec + name/description prose), because removal needs an A/B.
#
# Needs a real Metal device: run unsandboxed (`bash scripts/probes/run.sh 13`).
PROBE_NAME="13-anthropic-tool-delivery"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

probe_boot
probe_require_ready_model

ASK_CALL="Use the get_weather tool to check the weather in Paris."
ASK_MATH="What is 2 plus 2? Answer with the number only."

BODY=""
# msg_body <prompt> <stream:true|false> <tools:1|0> <choice:none|any|none-choice>
msg_body() {
  python3 - "$PROBE_MODEL" "$1" "$2" "$3" "$4" <<'PY'
import json, sys
model, prompt, stream, tools, choice = sys.argv[1:6]
body = {
    "model": model,
    "max_tokens": 96,
    "temperature": 0.0,
    "stream": stream == "true",
    "messages": [{"role": "user", "content": prompt}],
}
if tools == "1":
    body["tools"] = [{
        "name": "get_weather",
        "description": "Get the current weather for a city.",
        "input_schema": {
            "type": "object",
            "properties": {"city": {"type": "string", "description": "City name"}},
            "required": ["city"],
        },
    }]
if choice == "any":
    body["tool_choice"] = {"type": "any"}
elif choice == "none":
    body["tool_choice"] = {"type": "none"}
print(json.dumps(body))
PY
}

# msg_send <prompt> <stream> <tools> <choice> — one /v1/messages turn into PROBE_BODY.
msg_send() {
  local b
  b="$(msg_body "$1" "$2" "$3" "$4")"
  probe_api POST /v1/messages "$b" || true
}

# model_field FIELD — a field of this model's object in a /v1/models body.
model_field() {
  PROBE_MODELS_BODY="$PROBE_BODY" PROBE_WANTED="$PROBE_MODEL" PROBE_FIELD="$1" python3 - <<'PY'
import json, os
try:
    data = json.loads(os.environ["PROBE_MODELS_BODY"]).get("data") or []
except Exception:
    print(""); raise SystemExit(0)
want = os.environ["PROBE_WANTED"]
field = os.environ["PROBE_FIELD"]
def norm(s):
    return (s or "").split("/")[-1]
entry = None
for item in data:
    if item.get("id") == want:
        entry = item
        break
if entry is None:
    for item in data:
        if norm(item.get("id")) == norm(want):
            entry = item
            break
if entry is None and data:
    entry = data[0]
value = entry.get(field) if entry else None
print("" if value is None else (json.dumps(value) if isinstance(value, bool) else value))
PY
}

# sse QUERY — structural read of the SSE body in PROBE_BODY.
#
# Every assertion here parses each `data:` payload as JSON instead of grepping the raw
# stream: this server's JSONEncoder does not fix key order (measured 10-19 — the same
# event came back as `{"index":0,"delta":…}` and `{"type":…,"index":0,…}` in one run), so
# any two-key substring is a coin flip. Probe 11's first run failed for reading the wrong
# key; the same family is closed off here by construction.
#   seq            one line per event: "<type>[ <detail>][ index=<n>]"
#   tool_blocks    content_block_start blocks whose type is tool_use
#   block_start0   the type of the FIRST content_block_start's content_block
#   delta_types    "<delta type>=<count>" lines
#   partial        concatenated input_json_delta payloads
#   text           concatenated text deltas
#   stop_reason    message_delta.stop_reason
sse() {
  PROBE_SSE_BODY="${2:-$PROBE_BODY}" PROBE_SSE_QUERY="$1" python3 - <<'PY'
import json, os, sys
from collections import Counter
raw = os.environ["PROBE_SSE_BODY"]
q = os.environ["PROBE_SSE_QUERY"]
events = []
for line in raw.splitlines():
    if not line.startswith("data: "):
        continue
    payload = line[6:].strip()
    if payload == "[DONE]":
        continue
    try:
        events.append(json.loads(payload))
    except Exception:
        events.append({"type": "PARSE_FAIL", "_raw": payload[:80]})

def blocks(ev_type):
    return [e.get("content_block") or {} for e in events if e.get("type") == ev_type]

def deltas(dt=None):
    out = []
    for e in events:
        if e.get("type") != "content_block_delta":
            continue
        d = e.get("delta") or {}
        if dt is None or d.get("type") == dt:
            out.append(d)
    return out

if q == "seq":
    for e in events:
        detail = ""
        if e.get("type") == "content_block_start":
            detail = " " + str((e.get("content_block") or {}).get("type"))
        elif e.get("type") == "content_block_delta":
            detail = " " + str((e.get("delta") or {}).get("type"))
        elif e.get("type") == "message_delta":
            detail = " " + str((e.get("delta") or {}).get("stop_reason"))
        idx = e.get("index")
        print("%s%s%s" % (e.get("type", "?"), detail, "" if idx is None else " index=%s" % idx))
elif q == "tool_blocks":
    for b in blocks("content_block_start"):
        if b.get("type") == "tool_use":
            print("%s %s" % (b.get("name"), json.dumps(b.get("input"))))
elif q == "block_start0":
    b = blocks("content_block_start")
    print((b[0].get("type") if b else ""))
elif q == "delta_types":
    for key, count in Counter(d.get("type") for d in deltas()).items():
        print("%s=%s" % (key, count))
elif q == "partial":
    sys.stdout.write("".join(d.get("partial_json", "") for d in deltas("input_json_delta")))
elif q == "text":
    sys.stdout.write("".join(d.get("text", "") for d in deltas("text_delta")))
elif q == "stop_reason":
    for e in events:
        if e.get("type") == "message_delta":
            print((e.get("delta") or {}).get("stop_reason", ""))
else:
    print("")
PY
}

# tool_block <field> — field of the first tool_use block in PROBE_BODY, "" if none.
tool_block() {
  PROBE_MSG_BODY="$PROBE_BODY" PROBE_TB_FIELD="$1" python3 - <<'PY'
import json, os
try:
    data = json.loads(os.environ["PROBE_MSG_BODY"])
except Exception:
    print(""); raise SystemExit(0)
field = os.environ["PROBE_TB_FIELD"]
for block in data.get("content") or []:
    if isinstance(block, dict) and block.get("type") == "tool_use":
        value = block.get(field)
        print("" if value is None else json.dumps(value) if not isinstance(value, str) else value)
        raise SystemExit(0)
print("")
PY
}

msg_field() {
  PROBE_MSG_BODY="$PROBE_BODY" PROBE_MF_PATH="$1" python3 - <<'PY'
import json, os
try:
    node = json.loads(os.environ["PROBE_MSG_BODY"])
except Exception:
    print(""); raise SystemExit(0)
for part in os.environ["PROBE_MF_PATH"].split("."):
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        print(""); raise SystemExit(0)
print("" if node is None else (json.dumps(node) if not isinstance(node, str) else node))
PY
}

# text_block_text [limit] — the answer text this face returned, previewed to `limit`
# characters (default 240) so verdict lines stay readable. Pass a big limit when the
# assertion needs the WHOLE answer: the preview cut a 512-token turn at 240 chars and
# reported "the answer broke" on a turn byte-identical to its control (measured 10-19).
text_block_text() {
  PROBE_MSG_BODY="$PROBE_BODY" python3 - "${1:-240}" <<'PY'
import json, os, sys
limit = int(sys.argv[1])
try:
    data = json.loads(os.environ["PROBE_MSG_BODY"])
except Exception:
    print(""); raise SystemExit(0)
print(" ".join(b.get("text", "") for b in (data.get("content") or [])
          if isinstance(b, dict) and b.get("type") == "text")[:limit])
PY
}

# ── 1. non-stream: a demanded call must arrive as tool_use ──────────────────
probe_section "1 — POST /v1/messages delivers tool_use (non-stream)"

msg_send "$ASK_CALL" false 1 any
if [ "$PROBE_STATUS" != "200" ]; then
  probe_fail "POST /v1/messages -> $PROBE_STATUS: $(printf %.240s "$PROBE_BODY")"
else
  probe_ok "POST /v1/messages answered 200"
fi
STOP="$(msg_field stop_reason)"
if [ "$STOP" != "tool_use" ]; then
  probe_fail "stop_reason='$STOP', expected tool_use — text was: $(text_block_text)"
else
  probe_ok "stop_reason = tool_use"
fi
if [ -z "$(tool_block id)" ]; then
  probe_fail "no tool_use content block: $(printf %.240s "$PROBE_BODY")"
else
  probe_ok "content carries a tool_use block"
fi
if [ "$(tool_block name)" != "get_weather" ]; then
  probe_fail "tool_use.name='$(tool_block name)', expected the declared get_weather"
else
  probe_ok "tool_use names the tool the caller declared"
fi
INPUT_RAW="$(tool_block input)"
if printf '%s' "$INPUT_RAW" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, dict) and d' 2>/dev/null; then
  probe_ok "tool_use.input is a JSON object with content: $INPUT_RAW"
else
  probe_fail "tool_use.input is not a usable JSON object: $(printf %.160s "$INPUT_RAW")"
fi

# ── 2. stream: the same call in Anthropic's SSE shape ───────────────────────
probe_section "2 — the SSE stream carries tool_use + input_json_delta"

msg_send "$ASK_CALL" true 1 any
SSE="$PROBE_BODY"
printf -- '  seq: %s\n' "$(printf '%s' "$(sse seq "$SSE")" | tr '\n' ' ' | cut -c1-200)"
if [ -n "$(sse tool_blocks "$SSE")" ]; then
  probe_ok "a tool_use content block was opened: $(sse tool_blocks "$SSE" | head -1)"
else
  probe_fail "no tool_use block in the stream: $(sse seq "$SSE" | tr '\n' ' ' | cut -c1-220)"
fi
if printf '%s' "$(sse delta_types "$SSE")" | grep -q '^input_json_delta='; then
  probe_ok "arguments arrived as input_json_delta ($(printf '%s' "$(sse delta_types "$SSE")" | tr '\n' ' '))"
else
  probe_fail "no input_json_delta in the stream: $(printf '%s' "$(sse delta_types "$SSE")" | tr '\n' ' ')"
fi
if [ -n "$(sse partial "$SSE")" ]; then
  probe_ok "partial_json carries the arguments: $(sse partial "$SSE")"
else
  probe_fail "input_json_delta carried nothing — clients accumulate on partial_json"
fi
if [ "$(sse stop_reason "$SSE")" != "tool_use" ]; then
  probe_fail "message_delta stop_reason='$(sse stop_reason "$SSE")', expected tool_use"
else
  probe_ok "message_delta stop_reason = tool_use"
fi
if printf '%s' "$(sse text "$SSE")" | grep -q '"name"'; then
  probe_fail "the call dialect leaked to the client as prose text: $(printf %.200s "$(sse text "$SSE")")"
else
  probe_ok "no call dialect in the text channel (structured only)"
fi
if printf '%s' "$(sse seq "$SSE")" | grep -q '^content_block_stop'; then
  probe_ok "every opened block was closed"
else
  probe_fail "an opened block was never closed"
fi

# ── 3. controls: nothing declared, and tool_choice none ─────────────────────
probe_section "3 — controls: no declaration, and tool_choice none, must not call"

msg_send "$ASK_CALL" false 0 none-choice
if [ -n "$(tool_block type)" ] || [ "$(msg_field stop_reason)" = "tool_use" ]; then
  probe_fail "undeclared turn produced tool_use — the surface is not the declaration"
else
  probe_ok "no declaration, no call (stop_reason=$(msg_field stop_reason))"
fi

msg_send "$ASK_CALL" false 1 none
if [ -n "$(tool_block type)" ] || [ "$(msg_field stop_reason)" = "tool_use" ]; then
  probe_fail "tool_choice none still produced tool_use — zero-surface contract broken"
else
  probe_ok "tool_choice none declares nothing, calls nothing"
fi

# ── 4. declaring without demanding must not cost the answer ─────────────────
probe_section "4 — tools declared but not demanded: answer the question, call nothing"

msg_send "$ASK_MATH" false 1 auto
if [ "$(msg_field stop_reason)" = "tool_use" ]; then
  probe_fail "declaring a tool FORCED a call for an arithmetic question — tools[] is not tool_choice:any"
elif ! printf '%s' "$(text_block_text)" | grep -q '4'; then
  probe_fail "declared tools and the answer vanished: '$(text_block_text)' (stop=$(msg_field stop_reason)) — a declaring request may not cost the reply"
else
  probe_ok "declaring tools leaves the model free to answer: $(text_block_text)"
fi

# ── 5. content_block_start carries content_block on a plain-text turn ───────
probe_section "5 — content_block_start names its block even when there is no tool"

msg_send "$ASK_MATH" true 0 none-choice
TEXT_SSE="$PROBE_BODY"
if [ "$(sse block_start0 "$TEXT_SSE")" = "text" ]; then
  probe_ok "text block start carries content_block.type=text (SDKs open a block from it)"
else
  probe_fail "content_block_start without a text content_block: $(printf %.240s "$TEXT_SSE")"
fi
if [ "$(sse stop_reason "$TEXT_SSE")" = "end_turn" ]; then
  probe_ok "plain-text stream ends end_turn"
else
  probe_fail "plain-text stream carried no end_turn reason: $(sse seq "$TEXT_SSE" | tr '\n' ' ' | cut -c1-200)"
fi
if printf '%s' "$(sse text "$TEXT_SSE")" | grep -q '4'; then
  probe_ok "the streamed answer still arrives: $(sse text "$TEXT_SSE")"
else
  probe_fail "the text channel went silent on a plain question: $(sse seq "$TEXT_SSE" | tr '\n' ' ' | cut -c1-200)"
fi

# ── 6. this face reports into the shared delivery gauge ─────────────────────
probe_section "6 — /v1/models toolCallDelivery moves on an Anthropic turn"

probe_api GET /v1/models
DELIVERY="$(model_field toolCallDelivery)"
EVIDENCE="$(model_field toolCallEvidence)"
if [ "$DELIVERY" != "parsed" ]; then
  probe_fail "toolCallDelivery='$DELIVERY' after a delivered tool_use — this face does not report into the shared ledger"
else
  probe_ok "toolCallDelivery=parsed after an Anthropic turn (one ledger, both faces)"
fi
if printf '%s' "$EVIDENCE" | grep -q 'get_weather'; then
  probe_ok "evidence names the tool that came back: $EVIDENCE"
else
  probe_fail "parsed without naming the called tool: '$EVIDENCE'"
fi

# ── 7. the loop closes: a tool_result continues the turn ────────────────────
probe_section "7 — tool_result continues the loop (no re-dispatch, answer uses the result)"

msg_send "$ASK_CALL" false 1 any
CALL_ID="$(tool_block id)"
CALL_INPUT="$(tool_block input)"
if [ -z "$CALL_ID" ]; then
  probe_fail "§7 cannot run: §1-style turn produced no tool_use id (stop=$(msg_field stop_reason))"
else
  probe_ok "turn 1 called $CALL_ID with $CALL_INPUT"
  T1_IN="$(msg_field usage.input_tokens)"
  BODY7="$(PROBE_MODEL="$PROBE_MODEL" PROBE_CALL_ID="$CALL_ID" PROBE_CALL_INPUT="$CALL_INPUT" python3 <<'PY'
import json, os
body = {
    "model": os.environ["PROBE_MODEL"],
    "max_tokens": 64,
    "temperature": 0.0,
    "messages": [
        {"role": "user", "content": "Use the get_weather tool to check the weather in Paris."},
        {"role": "assistant", "content": [
            {"type": "tool_use",
             "id": os.environ["PROBE_CALL_ID"],
             "name": "get_weather",
             "input": json.loads(os.environ["PROBE_CALL_INPUT"])}]},
        {"role": "user", "content": [
            {"type": "tool_result",
             "tool_use_id": os.environ["PROBE_CALL_ID"],
             "content": "17C, light rain"}]},
        {"role": "user", "content": "What did the tool say? Answer in one short sentence."},
    ],
    "tools": [{
        "name": "get_weather",
        "description": "Get the current weather for a city.",
        "input_schema": {
            "type": "object",
            "properties": {"city": {"type": "string", "description": "City name"}},
            "required": ["city"],
        },
    }],
}
print(json.dumps(body))
PY
)"
  probe_api POST /v1/messages "$BODY7"
  T7_IN="$(msg_field usage.input_tokens)"
  T7_TEXT="$(text_block_text)"
  T7_STOP="$(msg_field stop_reason)"
  if [ "$PROBE_STATUS" != "200" ]; then
    probe_fail "tool_result continuation -> $PROBE_STATUS: $(printf %.240s "$PROBE_BODY")"
  else
    probe_ok "continuation answered 200"
    if printf '%s' "$T7_TEXT" | grep -q '17'; then
      probe_ok "the turn reads the supplied result: $T7_TEXT"
    else
      probe_fail "the result never reached the model: '$T7_TEXT'"
    fi
    if [ "$T7_STOP" = "tool_use" ] || [ -n "$(tool_block type)" ]; then
      probe_fail "structured history re-triggered a call (stop=$T7_STOP) — history must not dispatch"
    else
      probe_ok "history carried the call without re-dispatching it (stop=$T7_STOP)"
    fi
  fi
  probe_note "continuation input_tokens=$T7_IN, turn 1 was $T1_IN — the loop history is in the prompt, not dropped"
fi

# ── 8. thinking must reach the engine ──────────────────────────────────────
#
# The live proof is the assembly line, not the answer length. Whether a *behavioural*
# difference is even observable is a per-checkpoint fact: this host's ready chat model
# (gemma-4-e2b-it-4bit) has no reasoning channel — thinking ON and OFF measured identical
# (209 tokens each, both answers starting "This is a logic puzzle"), and the OpenAI face
# shows the same pair (`reasoning:true` / `false` both 777 prompt tokens). So the probe
# asserts what this host can prove: the preference arrives at the options the engine runs
# with, and the knob never costs the answer. A checkpoint with a thinking channel turns the
# same two greps into a behavioural gate for free.
probe_section "8 — thinking.type reaches the engine options, and never costs the answer"

ASK_RIDDLE="A farmer has 17 sheep. All but 9 die. How many are left? Think carefully."
# ant_think_body <mode: enabled|disabled|overbudget> <max_tokens>
ant_think_body() {
  python3 - "$PROBE_MODEL" "$ASK_RIDDLE" "$1" "$2" <<'PY'
import json, sys
model, prompt, mode, max_tokens = sys.argv[1:5]
body = {"model": model, "max_tokens": int(max_tokens), "temperature": 0.0,
        "messages": [{"role": "user", "content": prompt}]}
if mode == "enabled" or mode == "overbudget":
    body["thinking"] = {"type": "enabled", "budget_tokens": 300}
elif mode == "disabled":
    body["thinking"] = {"type": "disabled"}
print(json.dumps(body))
PY
}

# asm FACE — the last assembly disclosure line this face emitted.
asm() {
  grep "Assembled prompt \[$1\]" "$PROBE_LOG" 2>/dev/null | tail -1
}

probe_api POST /v1/messages "$(ant_think_body absent 512)"
ABSENT_ANSWER="$(text_block_text)"
ABSENT_ASM="$(asm messages)"
if printf '%s' "$ABSENT_ASM" | grep -q 'enableReasoning=default'; then
  probe_ok "no thinking field states no preference (engine template decides)"
else
  probe_fail "absent thinking should leave the preference unset: $ABSENT_ASM"
fi

probe_api POST /v1/messages "$(ant_think_body enabled 512)"
ON_STATUS="$PROBE_STATUS"
ON_OUT="$(msg_field usage.output_tokens)"
ON_STOP="$(msg_field stop_reason)"
ON_ANSWER="$(text_block_text)"
ON_FULL="$(text_block_text 1000000)"
ON_ASM="$(asm messages)"
ON_BLOCKS="$(msg_field content.0.type)"
if printf '%s' "$ON_ASM" | grep -q 'enableReasoning=on'; then
  probe_ok "thinking.type=enabled reaches InferenceOptions (enableReasoning=on)"
else
  probe_fail "thinking declared but the option stayed closed: $ON_ASM"
fi

probe_api POST /v1/messages "$(ant_think_body disabled 512)"
OFF_STATUS="$PROBE_STATUS"
OFF_OUT="$(msg_field usage.output_tokens)"
OFF_STOP="$(msg_field stop_reason)"
OFF_ANSWER="$(text_block_text)"
OFF_FULL="$(text_block_text 1000000)"
OFF_ASM="$(asm messages)"
if printf '%s' "$OFF_ASM" | grep -q 'enableReasoning=off'; then
  probe_ok "thinking.type=disabled means OFF — it no longer resolves to ON"
else
  probe_fail "disabled did not reach the options as off: $OFF_ASM"
fi

# The knob must never cost the answer, and at temp 0 that is an exact claim: `enabled`
# and `disabled` must return the same bytes over the FULL answer, with the same
# output-token count. Two regressions move those bytes — the budget capping the output
# (what `min(max_tokens, budget_tokens)` used to do) and `disabled` resolving to ON
# (what this build used to do) — and neither slips past an equality check.
#
# NOT asserted: "the turn concludes with 9". Where this checkpoint puts the conclusion
# moves between boots — measured 10-19 on the same prompt/temp: end_turn at 209 tokens in
# one run, max_tokens at 512 (and still no conclusion at 1024) in another. A conclusion
# check would therefore fail on the checkpoint, not on our code, and a substring test for
# the digit passes on the riddle's own "9" regardless. Both are recorded, not claimed.
if [ "$ON_STATUS" = "200" ] && [ "$OFF_STATUS" = "200" ] && [ -n "$ON_FULL" ] \
   && [ "$ON_FULL" = "$OFF_FULL" ] && [ "$ON_OUT" = "$OFF_OUT" ]; then
  probe_ok "the knob never costs the answer (identical ${#ON_FULL}-char output, ${ON_OUT} tokens both ways)"
else
  probe_fail "thinking A/B changed the answer: enabled=[$ON_STATUS/${ON_OUT}tok/$ON_STOP] disabled=[$OFF_STATUS/${OFF_OUT}tok/$OFF_STOP] enabled='$(printf %.160s "$ON_ANSWER")' disabled='$(printf %.160s "$OFF_ANSWER")'"
fi
probe_note "stop_reason enabled=$ON_STOP disabled=$OFF_STOP at max_tokens=512 — the conclusion position on this checkpoint moves between boots, so the verdict above compares the two turns rather than reading for a number"
if [ "$ON_BLOCKS" = "thinking" ]; then
  probe_ok "reasoning arrived as a thinking block"
else
  probe_note "no thinking block on this checkpoint (content[0].type='${ON_BLOCKS:-none}'): its template has no reasoning channel, so thinking text stays in the answer here"
fi
probe_note "output_tokens enabled=${ON_OUT:-?} disabled=${OFF_OUT:-?} — identical here, and identical on /v1/chat/completions (reasoning:true/false), which is a checkpoint fact, not the knob being unwired: the two greps above are the delivery proof"

probe_api POST /v1/messages "$(ant_think_body overbudget 100)"
if [ "$PROBE_STATUS" = "400" ] && printf '%s' "$PROBE_BODY" | grep -q 'budget_tokens'; then
  probe_ok "budget >= max_tokens refused 400 naming thinking.budget_tokens"
else
  probe_fail "budget 300 with max_tokens 100 returned $PROBE_STATUS: $(printf %.200s "$PROBE_BODY")"
fi

# ── 9. one assembly: the two faces feed the model the same prompt ──────────
#
# Two readings, because there are two claims. The assembly line says what the handlers put
# in front of the engine (roles + system chars + token estimate). `usage` says what each
# face then reports for that prompt — and those must agree too, or a client budgeting on
# one wire mis-reads the other (measured 10-19: the OpenAI face reported the engine's
# measured 774 while this face reported its own 769 estimate for identical messages).
probe_section "9 — identical request, identical prompt on both wires"

ASK_PLAIN="What is 2 plus 2? Answer with the number only."
# One session id on both faces: the assembly has session-scoped parts (the complexity-tiered
# reasoning scaffold is keyed by session), so pinning the session is what makes "the same
# request" mean the same thing on both wires.
SESSION9="probe13-parity-$$"
BODY9_ANT="$(python3 - "$PROBE_MODEL" "$ASK_PLAIN" "$SESSION9" <<'PY'
import json, sys
print(json.dumps({"model": sys.argv[1], "max_tokens": 16, "temperature": 0.0,
  "metadata": {"session_id": sys.argv[3]},
  "messages": [{"role": "user", "content": sys.argv[2]}]}))
PY
)"
BODY9_OAI="$(python3 - "$PROBE_MODEL" "$ASK_PLAIN" "$SESSION9" <<'PY'
import json, sys
print(json.dumps({"model": sys.argv[1], "max_tokens": 16, "temperature": 0.0,
  "session_id": sys.argv[3],
  "messages": [{"role": "user", "content": sys.argv[2]}]}))
PY
)"
probe_api POST /v1/chat/completions "$BODY9_OAI"
OAI_IN="$(msg_field usage.prompt_tokens)"
OAI_ASM="$(asm chat)"
probe_api POST /v1/messages "$BODY9_ANT"
ANT_IN="$(msg_field usage.input_tokens)"
ANT_ASM="$(asm messages)"
probe_note "assembly [chat]     $OAI_ASM"
probe_note "assembly [messages] $ANT_ASM"
SYS9="$(printf '%s' "$OAI_ASM" | sed -nE 's/.*systemChars=([0-9]+).*/\1/p')"
OAI_SHAPE="$(printf '%s' "$OAI_ASM" | sed -nE 's/.*(systemChars=[0-9]+ promptTokens=[0-9]+).*/\1/p')"
ANT_SHAPE="$(printf '%s' "$ANT_ASM" | sed -nE 's/.*(systemChars=[0-9]+ promptTokens=[0-9]+).*/\1/p')"
if [ -n "$OAI_SHAPE" ] && [ "$OAI_SHAPE" = "$ANT_SHAPE" ]; then
  probe_ok "both faces assembled the same prompt ($ANT_SHAPE)"
else
  probe_fail "the two faces assembled different prompts: chat='$OAI_SHAPE' messages='$ANT_SHAPE'"
fi
probe_note "reported usage: /v1/chat/completions prompt_tokens=$OAI_IN, /v1/messages input_tokens=$ANT_IN"
if [ -n "$OAI_IN" ] && [ "$OAI_IN" = "$ANT_IN" ]; then
  probe_ok "both faces report the same prompt cost for the same prompt"
else
  probe_fail "one engine, two numbers for one prompt: $OAI_IN vs $ANT_IN"
fi
# A match at a small number would prove nothing: the point is that BOTH carry the agent
# context (skills catalogue + workspace + memory + scaffold), hundreds of tokens over a
# one-line request. Measured before the fix: 24 here against 774 there.
if [ -n "$ANT_IN" ] && [ "$ANT_IN" -ge 400 ]; then
  probe_ok "this face carries the agent context too ($ANT_IN tokens for a one-line request)"
else
  probe_fail "input_tokens=$ANT_IN — the agent context is missing on this face again"
fi

probe_api POST /v1/messages/count_tokens "$BODY9_ANT"
COUNTED="$(msg_field input_tokens)"
probe_note "count_tokens=$COUNTED vs the same request's usage.input_tokens=$ANT_IN"
if [ -z "$COUNTED" ] || [ -z "$ANT_IN" ]; then
  probe_fail "count_tokens or usage reported nothing (count=$COUNTED usage=$ANT_IN)"
else
  # The pre-flight measures the message list with the message tokenizer; usage reports the
  # engine's measured prefill, which includes the chat template's per-message framing. The
  # gap is a constant of a few tokens per turn — recorded, not hidden — and a gross
  # mismatch (the old 24-vs-774) still fails here.
  GAP=$(( COUNTED > ANT_IN ? COUNTED - ANT_IN : ANT_IN - COUNTED ))
  if [ "$GAP" -le 16 ]; then
    probe_ok "count_tokens pre-flights the same prompt (|gap|=$GAP tokens = template framing)"
  else
    probe_fail "count_tokens said $COUNTED, the request cost $ANT_IN — the pre-flight budgets a different prompt"
  fi
fi

# ── 10. /v1/steer delivers on this face too ────────────────────────────────
probe_section "10 — a steer queued for a session reaches /v1/messages"

probe_api POST /v1/steer '{"session_id":"probe13-steer","text":"The secret codeword is ORIOLE."}'
if [ "$PROBE_STATUS" != "200" ]; then
  probe_fail "POST /v1/steer -> $PROBE_STATUS: $(printf %.200s "$PROBE_BODY")"
else
  BODY10="$(python3 - "$PROBE_MODEL" <<'PY'
import json, sys
print(json.dumps({"model": sys.argv[1], "max_tokens": 32, "temperature": 0.0,
  "metadata": {"session_id": "probe13-steer"},
  "messages": [{"role": "user", "content": "What is the secret codeword? Answer with one word."}]}))
PY
)"
  probe_api POST /v1/messages "$BODY10"
  if printf '%s' "$(text_block_text)" | grep -q 'ORIOLE'; then
    probe_ok "the steer arrived on the next /v1/messages turn: $(text_block_text)"
  else
    probe_fail "the steer was swallowed on this face: '$(text_block_text)' (the route documents delivery on /v1/messages)"
  fi
fi

# ── 11. how many copies of a declared tool does the model get? ──────────────
#
# First-principles question the answer to which upstream does not leave open: vllm and
# sglang hand the model ONE structured `tools` array (`entrypoints/anthropic/serving.py:
# 762-791`, `srt/entrypoints/anthropic/serving.py:646-678`) and never also write the tool
# into the system prompt. Here the shared assembly's Phase 5 appends
# `## Tool: <name>\nDescription: …` — a copy WITHOUT the parameter schema — while the same
# spec simultaneously reaches the engine as a structured declaration
# (`EngineInference.swift:3143 chatSession?.tools = registeredToolSpecs`). Measured here,
# recorded as a number so the open item in AGENTS.md § Open has an instrument: the day the
# injection is removed (or the schema joins it) this line moves, and the A/B that settles
# removal has a before/after to point at. Deliberately a NOTE, not a PASS — pinning the
# duplication would make the correct fix fail the probe.
probe_section "11 — one declared tool: how many copies reach the prompt"

BODY11="$(python3 - "$PROBE_MODEL" <<'PY'
import json, sys
print(json.dumps({"model": sys.argv[1], "max_tokens": 8, "temperature": 0.0,
  "messages": [{"role": "user", "content": "What is 2 plus 2? Answer with the number only."}],
  "tools": [{"type": "function", "function": {
      "name": "get_weather",
      "description": "Get current weather for a city.",
      "parameters": {"type": "object",
                     "properties": {"city": {"type": "string", "description": "City name"}},
                     "required": ["city"]}}}],
  "tool_choice": "none"}))
PY
)"
probe_api POST /v1/chat/completions "$BODY11"
ASM11="$(asm chat)"
SYS11="$(printf '%s' "$ASM11" | sed -nE 's/.*systemChars=([0-9]+).*/\1/p')"
DECL11="$(printf '%s' "$ASM11" | sed -nE 's/.*declaredTools=([0-9]+).*/\1/p')"
if [ "$DECL11" = "1" ]; then
  probe_ok "the declaration reached the assembly for this turn (declaredTools=1)"
else
  probe_fail "a declared tool did not reach the assembly: $ASM11"
fi
if [ -z "$SYS11" ] || [ -z "$SYS9" ]; then
  probe_fail "assembly line missing systemChars (§11 cannot measure the duplication): $ASM11"
else
  # One copy per declared tool (AGENTS.md § Open, fixed 10-20续7): the checkpoint's own chat
  # template declares tools it renders, so our ## Tool: prose must be skipped for it. The
  # decision and its reason are published at load; §11 checks the effect against that claim.
  MODE11="$(grep -o "Tool prose [a-zA-Z]* for $PROBE_MODEL —.*" "$PROBE_LOG" | head -1)"
  B11="$(grep -o "Tool prose [a-zA-Z]* for $PROBE_MODEL with 1 declared tool(s), [0-9]* ## Tool: block(s) written" "$PROBE_LOG" | tail -1 | sed -nE 's/.* ([0-9]+) ## Tool.*/\1/p')"
  GROWTH11=$(( SYS11 - SYS9 ))
  probe_note "load-time decision: ${MODE11:-<none>}; this turn wrote ${B11:-<none>} ## Tool: block(s); system message $SYS9 -> $SYS11 (+$GROWTH11 chars, which is the tool-agnostic action directive, not a declaration)"
  case "$MODE11" in
    *"Tool prose skippedTemplateRenders"*)
      if [ "${B11:-0}" -eq 0 ]; then
        probe_ok "one declared tool, zero ## Tool: blocks written — the checkpoint's own <|tool> block is the single declaration"
      else
        probe_fail "the ledger said skippedTemplateRenders but this turn wrote $B11 ## Tool: block(s): the duplicate declaration is back"
      fi
      ;;
    *"Tool prose injectedTemplateIgnores"*)
      if [ "${B11:-0}" -ge 1 ]; then
        probe_ok "this template was measured to ignore tools, so our $B11 block(s) are the only declaration it can see"
      else
        probe_fail "mode injectedTemplateIgnores but no ## Tool: block was written — nothing declared the tool"
      fi
      ;;
    *)
      probe_xfail open "a declared tool arrived with no measured decision on record (${MODE11:-no Tool prose line}) — the model may be getting the surface in two dialects"
      ;;
  esac
fi

probe_summary "$PROBE_NAME"
