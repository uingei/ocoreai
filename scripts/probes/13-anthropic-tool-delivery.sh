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

text_block_text() {
  PROBE_MSG_BODY="$PROBE_BODY" python3 - <<'PY'
import json, os
try:
    data = json.loads(os.environ["PROBE_MSG_BODY"])
except Exception:
    print(""); raise SystemExit(0)
print(" ".join(b.get("text", "") for b in (data.get("content") or [])
          if isinstance(b, dict) and b.get("type") == "text")[:240])
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

probe_summary "$PROBE_NAME"
