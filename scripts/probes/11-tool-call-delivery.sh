#!/usr/bin/env bash
# 11-tool-call-delivery.sh — does a declared tool come back as a call the client can run?
#
# ### Why (AGENTS.md invariant 2, and the cheapest way for an agent server to die quietly)
# An OpenAI-compatible client that posts `tools[]` expects `choices[].message.tool_calls`
# plus `finish_reason:"tool_calls"`; it executes the call and posts a `role:"tool"`
# message back. vllm and sglang never execute a tool themselves — the caller owns the
# tools it declares. Until 10-18 this server did neither: it intersected the caller's
# declaration with its own registry and dropped what did not survive, so a request
# declaring `get_weather` was prompted with NO tool block at all, answered in prose,
# and reported `finish_reason:"stop"`. Measured on this host the day it was found:
#   content = "```json { \"tool_name\": \"get_weather\", ... } ```", finish_reason = stop,
#   tool_calls absent, and nothing on any surface said so. The client's loop died on
#   turn one and the server called it a 200 OK.
#
# No probe covered `tools` before this file: ten probes exercised chat, stop sequences,
# kv-cache, screen, audio, video, capabilities and sampling knobs, and none asked the
# one question a coding agent lives or dies on.
#
# ### What is measured
#   1. The gauge starts honest: a freshly booted process has never seen a declaring
#      turn, so /v1/models must publish toolCallDelivery=not_observed — present, not
#      omitted, because silence reads as capability.
#   2. Declaring a tool this server does NOT own must deliver a structured call: name
#      matches, arguments parse as a JSON object, finish_reason is tool_calls.
#   3. Controls: the same prompt with no tools must not call, and neither must
#      tool_choice:"none" (the 10-06 zero-surface contract).
#   3b. Declaring without demanding (`tool_choice` absent = auto) must still ANSWER
#       the question — a declaration may not cost the reply.
#   3c. tool_choice:"required" plus a request to call must deliver a call.
#   3d. forcing a call the checkpoint resists is recorded, and never fabricated.
#   7. The GUI's own declaration shape (`GET /v1/tools` pasted back, the whole
#      registry) must still answer a plain question instead of calling something.
#   4. Streaming agrees with non-streaming (an SSE tool_calls delta + the word).
#   5. The measurement moved: after step 2 the same /v1/models must say parsed and
#      carry the evidence line that earned it.
#   6. /v1/capabilities must agree with the surface that measured it.
#
# Key casing is per-object and it bit us the first time this probe ran: /v1/models
# objects emit camelCase (`weightsDir`, `videoInput`, `toolCallDelivery` — pinned by
# ModelsWireShapeTests and ToolCallDeliveryDisclosureTests), while /v1/capabilities
# rows are identified by a snake_case NAME (`video_input`, `tool_call_delivery`). Ask
# each surface by its own key, or a delivered call reads as a missing row.
#
# Needs a real Metal device: run unsandboxed (`bash scripts/probes/run.sh 11`). Bodies
# are single-quoted JSON + "$VAR" splices (macOS bash 3.2 mis-parses nested quoted
# command substitution — see probe 09), and every compared turn gets its own session so
# a growing history cannot change the outcome on its own.
#
# Run: bash scripts/probes/11-tool-call-delivery.sh
PROBE_NAME="11-tool-call-delivery"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

WEATHER_TOOLS=',"tools":[{"type":"function","function":{"name":"get_weather","description":"Get the current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string","description":"City name"}},"required":["city"]}}}]'
ASK_WEATHER="Use the get_weather tool to check the weather in Paris."

SESSION_SEQ=0
fresh_session() {
  SESSION_SEQ=$(( SESSION_SEQ + 1 ))
  printf 'probe11-%s-%s' "$$" "$SESSION_SEQ"
}

STATUS=""
BODY=""
CALLS=""
FINISH=""
CONTENT=""

# ask_tools EXTRA_JSON PROMPT — one non-streaming turn.
ask_tools() {
  local session body
  session="$(fresh_session)"
  body='{"model":"'"$PROBE_MODEL"'","session_id":"'"$session"'","temperature":0,"max_tokens":96,"messages":[{"role":"user","content":"'"$2"'"}]'"$1${3:-}"'}'
  probe_chat "$session" "$body" || true
  STATUS="$PROBE_STATUS"
  BODY="$PROBE_BODY"
  CALLS="$(probe_json "$BODY" 'choices.0.message.tool_calls')"
  FINISH="$(probe_json "$BODY" 'choices.0.finish_reason')"
  CONTENT="$(probe_json "$BODY" 'choices.0.message.content')"
}

# call_field INDEX KEY — field of the Nth delivered call.
call_field() {
  probe_json "$BODY" "choices.0.message.tool_calls.$1.function.$2"
}

# model_field FIELD — this model's value from the last GET /v1/models body. Matched by
# id rather than by position: /v1/models lists every loaded model, and the probe model
# is only FIRST by convention.
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

# capability_available NAME — the row's `available` from the last /v1/capabilities body.
capability_available() {
  PROBE_CAPS_BODY="$PROBE_BODY" PROBE_CAP_NAME="$1" python3 - <<'PY'
import json, os
try:
    rows = json.loads(os.environ["PROBE_CAPS_BODY"]).get("capabilities") or []
except Exception:
    print(""); raise SystemExit(0)
for row in rows:
    if row.get("name") == os.environ["PROBE_CAP_NAME"]:
        value = row.get("available")
        print("" if value is None else ("true" if value else "false"))
        raise SystemExit(0)
print("")
PY
}

probe_boot
probe_require_ready_model

# ── 1. the gauge exists and starts honest ───────────────────────────────────
probe_section "1 — /v1/models publishes toolCallDelivery, and says not_observed first"

probe_api GET /v1/models
if [ "$PROBE_STATUS" != "200" ]; then
  probe_fail "GET /v1/models -> $PROBE_STATUS"
else
  DELIVERY="$(model_field toolCallDelivery)"
  if [ -z "$DELIVERY" ]; then
    probe_fail "toolCallDelivery absent from /v1/models — silence is not honesty"
  elif [ "$DELIVERY" != "not_observed" ]; then
    probe_fail "fresh process claims toolCallDelivery=$DELIVERY with no declaring turn run here"
  else
    probe_ok "toolCallDelivery=not_observed before any tool traffic"
  fi
fi

# ── 2. declaring a foreign tool must deliver a call ─────────────────────────
probe_section "2 — a caller-owned tool must come back as tool_calls, not prose"

ask_tools "$WEATHER_TOOLS" "$ASK_WEATHER"
if [ "$STATUS" != "200" ]; then
  probe_fail "declaring turn -> $STATUS: $(printf %.240s "$BODY")"
else
  probe_ok "declaring turn answered 200"
fi
if [ -z "$CALLS" ]; then
  probe_fail "no tool_calls delivered — content was: $(printf %.240s "$CONTENT")"
else
  probe_ok "tool_calls delivered (structured, not prose)"
fi
if [ "$(call_field 0 name)" != "get_weather" ]; then
  probe_fail "call[0].function.name = '$(call_field 0 name)', expected get_weather"
else
  probe_ok "call[0] names the tool the caller declared"
fi
if [ "$FINISH" != "tool_calls" ]; then
  probe_fail "finish_reason = '$FINISH', expected tool_calls"
else
  probe_ok "finish_reason = tool_calls"
fi
ARGS_RAW="$(call_field 0 arguments)"
if printf '%s' "$ARGS_RAW" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, dict) and d' 2>/dev/null; then
  probe_ok "call[0].arguments is a JSON object with content: $ARGS_RAW"
else
  probe_fail "call[0].arguments is not a usable JSON object: $(printf %.160s "$ARGS_RAW")"
fi

# ── 3. controls: nothing declared, and tool_choice none ─────────────────────
probe_section "3 — controls: nothing declared, and tool_choice none, must not call"

ask_tools '' "$ASK_WEATHER"
if [ "$STATUS" = "200" ] && [ -n "$CALLS" ]; then
  probe_fail "undeclared turn still delivered tool_calls — the surface is not the declaration"
elif [ "$FINISH" = "tool_calls" ]; then
  probe_fail "undeclared turn reported finish_reason=tool_calls"
else
  probe_ok "no declaration, no call (finish_reason=$FINISH)"
fi
ask_tools "$WEATHER_TOOLS,\"tool_choice\":\"none\"" "$ASK_WEATHER"
if [ -n "$CALLS" ] || [ "$FINISH" = "tool_calls" ]; then
  probe_fail "tool_choice:none still produced a call (finish_reason=$FINISH) — zero-surface contract broken"
else
  probe_ok "tool_choice:none declares nothing, calls nothing"
fi

# ── 3b. declaring a tool must NOT cost the answer ───────────────────────────
# OpenAI puts forcing in `tool_choice`, not in the presence of `tools[]`: with
# "auto"/absent the model may answer instead of calling. Measured 10-18 before the
# fix: a calls-only grammar gated on declaration squeezed "What is 2 + 2?" into
# content:"" + finish_reason:"stop" — neither a call nor a reply (the no-tools
# control answered `4`). This is now an assertion, not a note, because the contract
# names the field that carries the instruction.
probe_section "3b — tools declared but not demanded: answer the question, call nothing"

ask_tools "$WEATHER_TOOLS" "What is 2 + 2? Answer with the number only."
if [ "$FINISH" = "tool_calls" ]; then
  probe_fail "declaring a tool FORCED a call for an arithmetic question — tools[] is not tool_choice:\"required\" (OpenAI: auto means the model may answer)"
elif ! printf '%s' "$CONTENT" | grep -q '4'; then
  probe_fail "tools declared, question needs no tool, and the answer vanished: content='$CONTENT' finish=$FINISH (the no-tools control answers 4) — a declaring request may not cost the reply"
else
  probe_ok "declaring a tool leaves the model free to answer (content has the 4, no call)"
fi

# ── 3c/3d. tool_choice:"required" is where forcing lives ────────────────────
# 3c asserts the case the checkpoint can honor (it is being asked to call). 3d is
# the measured limit: forcing is constrained decoding, and on a question the model
# resists ("What is 2 + 2?") gemma-4's constrained decode yields ZERO tokens here
# (`content:""`, `finish_reason:"stop"`, measured twice 10-18). No call exists to
# deliver, so the honest outcomes are "a call" or "silence plus a warning in the
# log" — never a fabricated call, which would execute something the model never
# asked for. Whether a checkpoint can honor the demand is its fact, per model.
probe_section "3c — tool_choice:\"required\" + a request to call must deliver a call"

ask_tools "$WEATHER_TOOLS" "Use the get_weather tool to check the weather in Paris." ',"tool_choice":"required"'
if [ "$FINISH" != "tool_calls" ] || [ -z "$CALLS" ]; then
  probe_fail "tool_choice:\"required\" with an explicit request to call produced no call (finish=$FINISH calls='${CALLS:-<none>}')"
else
  probe_ok "tool_choice:\"required\" forces a call as the wire says it should"
fi

probe_section "3d — forcing a call the model resists: recorded, and never fabricated"

ask_tools "$WEATHER_TOOLS" "What is 2 + 2? Answer with the number only." ',"tool_choice":"required"'
if [ "$FINISH" = "tool_calls" ]; then
  probe_ok "this checkpoint honors tool_choice:\"required\" even for arithmetic (call delivered)"
elif printf '%s' "$CONTENT" | grep -q 'get_weather'; then
  probe_fail "no structured call delivered but the answer text names the tool — a call the client cannot run, delivered as a normal answer"
else
  probe_note "forcing produced nothing (content='$(printf %.40s "$CONTENT")', finish=$FINISH) — constrained decode returned zero tokens; server logs the gap and fabricates no call"
fi

# ── 4. streaming must agree with non-streaming ──────────────────────────────
probe_section "4 — SSE carries the same tool_calls the JSON body does"

STREAM_SESSION="$(fresh_session)"
STREAM_BODY='{"model":"'"$PROBE_MODEL"'","session_id":"'"$STREAM_SESSION"'","temperature":0,"max_tokens":96,"stream":true,"messages":[{"role":"user","content":"'"$ASK_WEATHER"'"}]'"$WEATHER_TOOLS"'}'
probe_chat "$STREAM_SESSION" "$STREAM_BODY" || true
SSE="$PROBE_BODY"
if printf '%s' "$SSE" | grep -q '"tool_calls"'; then
  probe_ok "SSE emitted a tool_calls delta"
else
  probe_fail "SSE carried no tool_calls: $(printf %.240s "$SSE")"
fi
if printf '%s' "$SSE" | grep -q '"finish_reason" *: *"tool_calls"'; then
  probe_ok "SSE finish_reason = tool_calls"
else
  probe_note "SSE had tool_calls but no tool_calls finish_reason in the captured stream — SSE field order varies, not asserted"
fi

# ── 5. the gauge moved, and shows how it earned the claim ───────────────────
probe_section "5 — after a delivered call, /v1/models says parsed (with evidence)"

probe_api GET /v1/models
DELIVERY_AFTER="$(model_field toolCallDelivery)"
EVIDENCE_AFTER="$(model_field toolCallEvidence)"
if [ "$DELIVERY_AFTER" != "parsed" ]; then
  probe_fail "toolCallDelivery=$DELIVERY_AFTER after a delivered call"
else
  probe_ok "toolCallDelivery=parsed after a delivered call"
fi
if printf '%s' "$EVIDENCE_AFTER" | grep -q 'structured tool_call'; then
  probe_ok "evidence line shipped with the claim: $EVIDENCE_AFTER"
else
  probe_fail "parsed without evidence — the claim ships no proof: '$EVIDENCE_AFTER'"
fi
if printf '%s' "$EVIDENCE_AFTER" | grep -q 'get_weather'; then
  probe_ok "evidence names the tool that actually came back"
else
  probe_fail "evidence does not name the called tool: '$EVIDENCE_AFTER'"
fi

# ── 6. capabilities agrees with the surface that measured it ────────────────
probe_section "6 — /v1/capabilities tool_call_delivery matches /v1/models"

probe_api GET /v1/capabilities
if [ "$PROBE_STATUS" != "200" ]; then
  probe_fail "GET /v1/capabilities -> $PROBE_STATUS"
else
  CAP_TOOL="$(capability_available tool_call_delivery)"
  if [ -z "$CAP_TOOL" ]; then
    probe_fail "no tool_call_delivery row on /v1/capabilities — agent_loop:true is not evidence"
  elif [ "$CAP_TOOL" != "true" ]; then
    probe_fail "/v1/capabilities says $CAP_TOOL while /v1/models says parsed — two surfaces, two truths"
  else
    probe_ok "capabilities publishes the measured delivery (available=true)"
  fi
fi

# ── 7. the GUI's own input shape, replayed over the wire ────────────────────
# `ChatViewModel` hands the engine the WHOLE registry on every message, and `/v1/tools`
# publishes exactly that array, so pasting it back replays what the app's users hit.
# Three things this section owns, and each one can go red:
#   a) a declaration is not a demand — nothing may be called;
#   b) a declaring turn may never hand back an empty reply;
#   c) declaring tools must actually reach the prompt (prompt_tokens must grow over the
#      same request with no tools declared) — a schema array silently dropped on the way
#      to the model is exactly the defect 10-18 found, and an equality on content alone
#      would not see it.
# What this server does NOT own is how well a checkpoint answers once 8.3k tokens of
# schemas crowd its prompt, so that is recorded as a measured NOTE, never asserted.
# Measured 10-18 (temp 0, cold caches, same request shape): no tools = 774 prompt
# tokens, answer "4"; all 39 declared = 9103 prompt tokens, answer "2 + 2" and stop.
probe_section "7 — the full registry pasted back must still answer a plain question"

probe_api GET /v1/tools
REG_TOOLS="$(printf '%s' "$PROBE_BODY" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
data = d.get("data") or d.get("tools") or []
if data:
    sys.stdout.write(json.dumps(data, ensure_ascii=False))')"
if [ -z "$REG_TOOLS" ]; then
  probe_fail "GET /v1/tools published no tools[] — the GUI's declaration shape cannot be replayed"
else
  REG_N="$(printf '%s' "$REG_TOOLS" | python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())))')"
  Q="What is 2 + 2? Answer with the number only."

  # Baseline: the identical request with nothing declared, its own fresh session.
  base_s="$(fresh_session)"
  probe_chat "$base_s" '{"model":"'"$PROBE_MODEL"'","session_id":"'"$base_s"'","temperature":0,"max_tokens":32,"messages":[{"role":"user","content":"'"$Q"'"}]}' || true
  BASE_CONTENT="$(probe_json "$PROBE_BODY" 'choices.0.message.content')"
  BASE_PROMPT="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens')"

  s="$(fresh_session)"
  probe_chat "$s" '{"model":"'"$PROBE_MODEL"'","session_id":"'"$s"'","temperature":0,"max_tokens":64,"messages":[{"role":"user","content":"'"$Q"'"}],"tools":'"$REG_TOOLS"'}' || true
  REG_CALL="$(probe_json "$PROBE_BODY" 'choices.0.message.tool_calls')"
  REG_CONTENT="$(probe_json "$PROBE_BODY" 'choices.0.message.content')"
  REG_PROMPT="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens')"

  if [ -n "$REG_CALL" ]; then
    probe_fail "declaring the registry's $REG_N tools forced a call ('$REG_CALL') for an arithmetic question — a declaration is not tool_choice:\"required\""
  elif [ -z "$REG_CONTENT" ]; then
    probe_fail "declaring the registry's $REG_N tools returned an empty reply (finish=$(probe_json "$PROBE_BODY" 'choices.0.finish_reason')) — a declaring turn must never hand back nothing"
  else
    probe_ok "the GUI's full $REG_N-tool surface calls nothing and still answers (content='$(printf %.24s "$REG_CONTENT")')"
    if [ -n "$REG_PROMPT" ] && [ -n "$BASE_PROMPT" ]; then
      MARGINAL=$(( REG_PROMPT - BASE_PROMPT ))
      if [ "$MARGINAL" -ge 1000 ]; then
        probe_ok "the declared schemas reached the model: prompt_tokens $BASE_PROMPT -> $REG_PROMPT (+$MARGINAL for $REG_N tools)"
      else
        probe_fail "declaring $REG_N tools moved prompt_tokens only $BASE_PROMPT -> $REG_PROMPT (+$MARGINAL) — the schemas are not reaching the prompt, so the declaration is decorative"
      fi
    else
      probe_fail "usage.prompt_tokens missing from a declaring turn (baseline=${BASE_PROMPT:-?} declared=${REG_PROMPT:-?}) — the feeding claim cannot be measured on this server"
    fi
    probe_note "declaring all $REG_N registry tools costs ${MARGINAL:-?} prompt tokens on a one-line question (no-tools answer was '$BASE_CONTENT'), and this checkpoint answered '$REG_CONTENT' then stopped — the unconditional full-surface declaration the GUI ships is a measured context AND answer-quality cost, not yet a policy; narrowing per-turn tool selection is the vllm/sglang/codex practice (CHANGELOG 10-18 续4)"
  fi
fi

probe_summary "$PROBE_NAME"
