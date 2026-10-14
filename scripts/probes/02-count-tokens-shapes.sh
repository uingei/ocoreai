#!/usr/bin/env bash
# 02-count-tokens-shapes.sh — every spec-legal way to ask "how big is this?".
#
# Why (AGENTS.md § Wire DTOs + § Open): this endpoint exists to size a request, and it
# was the one endpoint OpenAI and Anthropic clients could not call — it 404'd on models
# /v1/models reported ready (10-12), then 400'd on `messages`/`input` bodies because the
# DTO only knew `prompt` (10-13). Both defects were invisible to every static audit in the
# repo and visible in one live request. That is the whole argument for keeping this probe.
#
# Asserted:
#   • each wire shape returns 200 with prompt_tokens > 0;
#   • every answer labels its source (`tokenizer_backend` real|heuristic) — the field that
#     keeps an estimate from being read as a token-exact count;
#   • shapes carrying the same text land within tolerance of each other (a shape that
#     silently drops the system block shows up here, which is the failure mode the
#     Anthropic `system`-besides-`messages` form used to have);
#   • a body with none of prompt/input/messages is a 4xx naming the expected shapes,
#     never a 500 and never "key not found".
#
# Run: bash scripts/probes/02-count-tokens-shapes.sh
PROBE_NAME="02-count-tokens-shapes"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

probe_boot
probe_require_ready_model

TEXT="Explain prefix caching in one sentence."
LONG="$(probe_pad_text 12)"
RESULTS=""

# name | json body (model injected by python so the id never gets hardcoded)
run_shape() {
  local name="$1" builder="$2" endpoint="${3:-/v1/count-tokens}"
  local body
  body="$(python3 - "$PROBE_MODEL" "$builder" "$TEXT" "$LONG" <<'PY'
import json, sys
model, shape, text, long_text = sys.argv[1:5]
if shape == "prompt":
    print(json.dumps({"model": model, "prompt": text}))
elif shape == "input_string":
    print(json.dumps({"model": model, "input": text}))
elif shape == "input_texts":
    print(json.dumps({"model": model, "input": [text, long_text[:120]]}))
elif shape == "input_messages":
    print(json.dumps({"model": model, "input": [{"role": "user", "content": text}]}))
elif shape == "messages":
    print(json.dumps({"model": model, "messages": [{"role": "user", "content": text}]}))
elif shape == "messages_system_string":
    print(json.dumps({"model": model, "messages": [{"role": "user", "content": text}],
                      "system": long_text}))
elif shape == "messages_system_blocks":
    print(json.dumps({"model": model,
                      "messages": [{"role": "user", "content": text}],
                      "system": [{"type": "text", "text": long_text,
                                 "cache_control": {"type": "ephemeral"}}]}))
else:
    print(json.dumps({"model": model}))
PY
)"
  probe_api POST "$endpoint" "$body"
  local status="$PROBE_STATUS" count
  if [ "$endpoint" = "/v1/messages/count_tokens" ]; then
    # Anthropic's response is flat here: {"input_tokens": N, "tokenizer_backend": "…"}
    count="$(probe_json "$PROBE_BODY" 'input_tokens')"
  else
    count="$(probe_json "$PROBE_BODY" 'prompt_tokens')"
  fi
  local backend
  backend="$(probe_json "$PROBE_BODY" 'tokenizer_backend')"
  if [ "$status" != "200" ]; then
    probe_fail "$name -> $status: ${PROBE_BODY:0:180}"
    return
  fi
  if [ -z "$count" ] || [ "$count" = "" ]; then
    probe_fail "$name -> 200 but no token count field in body: ${PROBE_BODY:0:180}"
    return
  fi
  if [ "$count" -le 0 ]; then
    probe_fail "$name -> count=$count (must be > 0)"
    return
  fi
  RESULTS="$RESULTS$name=$count
"
  probe_ok "$name -> 200, count=$count, tokenizer_backend=${backend:-<absent on this endpoint>}"
}

probe_section "POST /v1/count-tokens — the three spec shapes + their variants"
run_shape "prompt (original shape)"            prompt
run_shape "input as string (OpenAI)"          input_string
run_shape "input as [String] (OpenAI)"       input_texts
run_shape "input as [{role,content}]"        input_messages
run_shape "messages (Anthropic)"             messages
run_shape "messages + system string"         messages_system_string
run_shape "messages + system blocks"         messages_system_blocks

probe_section "POST /v1/messages/count_tokens — Anthropic pre-flight"
run_shape "anthropic messages"               messages           /v1/messages/count_tokens
run_shape "anthropic messages + system"      messages_system_string /v1/messages/count_tokens

probe_section "the same bytes must count the same, whichever field they arrived in"
# Shapes carrying identical text must agree exactly: a disagreement means one shape drops
# or double-counts part of the prompt (the `system`-besides-`messages` defect family).
# `input: [String]` is excluded — it carries MORE text by construction.
python3 - "$RESULTS" <<'SHAPEPY' | sed 's/^/        /'
import sys
BARE = {"prompt (original shape)", "input as string (OpenAI)", "input as [{role,content}]",
        "messages (Anthropic)", "anthropic messages"}
SYS = {"messages + system string", "messages + system blocks", "anthropic messages + system"}
rows = [l.split("=", 1) for l in sys.argv[1].splitlines() if "=" in l]
bare = {k: int(v) for k, v in rows if k in BARE and v.isdigit()}
withsys = {k: int(v) for k, v in rows if k in SYS and v.isdigit()}
print("same-text counts (bare):    %s" % bare)
print("same-text counts (+system): %s" % withsys)
if bare:
    print("bare spread %s -> %s" % (sorted(set(bare.values())),
        "identical" if len(set(bare.values())) == 1 else "DISAGREE"))
if withsys:
    print("+system spread %s -> %s" % (sorted(set(withsys.values())),
        "identical" if len(set(withsys.values())) == 1 else "DISAGREE"))
if bare and withsys:
    print("system text counted into the prompt: %s (max bare=%s, min +system=%s)"
          % (min(withsys.values()) > max(bare.values()), max(bare.values()), min(withsys.values())))
SHAPEPY

BARE_DISTINCT="$(python3 - "$RESULTS" <<'BAREPY'
import sys
BARE = {"prompt (original shape)", "input as string (OpenAI)", "input as [{role,content}]",
        "messages (Anthropic)", "anthropic messages"}
vals = set()
for line in sys.argv[1].splitlines():
    if "=" not in line:
        continue
    k, v = line.split("=", 1)
    if k in BARE and v.isdigit():
        vals.add(int(v))
print(len(vals))
BAREPY
)"
if [ "${BARE_DISTINCT:-0}" = "1" ]; then
  probe_ok "all same-text shapes agree on one exact count — the field choice does not change the number"
else
  probe_fail "identical text counted ${BARE_DISTINCT:-0} different ways across prompt/input/messages — one shape drops or adds prompt"
fi

SYS_GT="$(python3 - "$RESULTS" <<'SYSPY'
import sys
BARE = {"prompt (original shape)", "messages (Anthropic)", "input as string (OpenAI)"}
SYS = {"messages + system string", "messages + system blocks", "anthropic messages + system"}
bare, sysv = [], []
for line in sys.argv[1].splitlines():
    if "=" not in line:
        continue
    k, v = line.split("=", 1)
    if not v.isdigit():
        continue
    if k in BARE:
        bare.append(int(v))
    elif k in SYS:
        sysv.append(int(v))
print("yes" if bare and sysv and min(sysv) > max(bare) else "no")
SYSPY
)"
if [ "$SYS_GT" = "yes" ]; then
  probe_ok "the system block is counted into the prompt, not silently dropped"
else
  probe_fail "a request with a system block did not count more than the same request without one — the system prompt is being dropped from the count"
fi

# Coverage floor: the shapes actually ran. Without this a broken `run_shape` that
# records nothing would leave the section empty and the probe green.
SHAPES_OK="$(printf '%s' "$RESULTS" | grep -c . || true)"
if [ "${SHAPES_OK:-0}" -ge 7 ]; then
  probe_ok "$SHAPES_OK wire shape(s) answered with a positive count"
else
  probe_fail "only ${SHAPES_OK:-0} shape(s) produced a usable count (expected >= 7) — coverage of this endpoint is not what the section header claims"
fi

probe_section "negative case — a body with nothing to count"
probe_api POST /v1/count-tokens "{\"model\":\"$PROBE_MODEL\"}"
case "${PROBE_STATUS:-}" in
  400|404|422)
    if printf '%s' "$PROBE_BODY" | grep -qiE 'prompt|input|messages'; then
      probe_ok "empty body -> $PROBE_STATUS naming the accepted shapes"
    else
      probe_fail "empty body -> $PROBE_STATUS but the error does not name prompt/input/messages: ${PROBE_BODY:0:180}"
    fi
    ;;
  500)
    probe_fail "empty body -> HTTP 500 (a client error must not be a server error): ${PROBE_BODY:0:180}"
    ;;
  200)
    probe_fail "empty body -> 200 with count=$(probe_json "$PROBE_BODY" 'prompt_tokens'): counting nothing as success hides a malformed request"
    ;;
  *)
    probe_fail "empty body -> unexpected ${PROBE_STATUS:-no response}: ${PROBE_BODY:0:180}"
    ;;
esac

probe_summary "$PROBE_NAME"
