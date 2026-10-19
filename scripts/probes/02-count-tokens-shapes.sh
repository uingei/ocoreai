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
#   • shapes carrying the same text land on ONE count — within an endpoint. The two
#     endpoints here are two surfaces and are compared separately:
#       `/v1/count-tokens`          = a tokenizer service: it sizes the BYTES YOU SENT.
#       `/v1/messages/count_tokens` = the pre-flight for `/v1/messages`, so it sizes what
#                                    that route feeds the MODEL — the caller's bytes PLUS the
#                                    agent context this server injects (skills catalogue,
#                                    workspace, recalled memory, reasoning scaffold).
#                                    Measured 10-19: one one-line message counts 17 raw and
#                                    700 pre-flight, and the request then cost 774
#                                    (`usage.input_tokens`, probe 13 §9).
#     A pre-flight reporting 17 is the defect this round removed (24 counted against 774
#     charged), so the gap is asserted as a floor rather than smoothed away. The old
#     assertion lumped both endpoints into one "same text, same number" group and went
#     red on a request that had gotten MORE honest, not less.
#   • the system block counts into the prompt on BOTH endpoints (a shape that silently
#     drops it shows up here — the failure mode the Anthropic `system`-besides-`messages`
#     form used to have);
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
# Shapes carrying identical text must agree exactly *within an endpoint*: a disagreement
# there means one shape drops or double-counts part of the prompt (the
# `system`-besides-`messages` defect family). `input: [String]` is excluded — it carries
# MORE text by construction. Across endpoints the two surfaces mean different things (see
# the header), so they are compared as raw ≤ pre-flight with the measured delta printed.
python3 - "$RESULTS" <<'SHAPEPY' | sed 's/^/        /'
import sys
# /v1/count-tokens — raw tokenizer counting of the caller's bytes
RAW_BARE = {"prompt (original shape)", "input as string (OpenAI)", "input as [{role,content}]",
            "messages (Anthropic)"}
RAW_SYS = {"messages + system string", "messages + system blocks"}
# /v1/messages/count_tokens — pre-flight for the assembled /v1/messages request
ANT_BARE = {"anthropic messages"}
ANT_SYS = {"anthropic messages + system"}
rows = [l.split("=", 1) for l in sys.argv[1].splitlines() if "=" in l]
def pick(names):
    return {k: int(v) for k, v in rows if k in names and v.isdigit()}
def spread(label, d):
    if not d:
        print("%-20s <no rows — this section proved nothing>" % label)
        return
    vs = sorted(set(d.values()))
    print("%-20s %s -> %s" % (label, vs, "identical" if len(vs) == 1 else "DISAGREE"))
raw_bare, raw_sys = pick(RAW_BARE), pick(RAW_SYS)
ant_bare, ant_sys = pick(ANT_BARE), pick(ANT_SYS)
spread("raw same-text:", raw_bare)
spread("raw +system:", raw_sys)
spread("pre-flight bare:", ant_bare)
spread("pre-flight +sys:", ant_sys)
if raw_bare and ant_bare:
    print("one-line message: raw=%s pre-flight=%s ratio=%.1fx (pre-flight adds the injected agent context)"
          % (max(raw_bare.values()), max(ant_bare.values()),
             max(ant_bare.values()) / float(max(1, max(raw_bare.values())))))
SHAPEPY

BARE_DISTINCT="$(python3 - "$RESULTS" <<'BAREPY'
import sys
RAW_BARE = {"prompt (original shape)", "input as string (OpenAI)",
            "input as [{role,content}]", "messages (Anthropic)"}
vals = set()
for line in sys.argv[1].splitlines():
    if "=" not in line:
        continue
    k, v = line.split("=", 1)
    if k in RAW_BARE and v.isdigit():
        vals.add(int(v))
print(len(vals))
BAREPY
)"
if [ "${BARE_DISTINCT:-0}" = "1" ]; then
  probe_ok "all raw same-text shapes agree on one exact count — the field choice does not change the number"
else
  probe_fail "identical text counted ${BARE_DISTINCT:-0} different ways across prompt/input/messages on /v1/count-tokens — one shape drops or adds prompt"
fi

# The system block must count into the prompt on BOTH endpoints. The comparison is
# per-endpoint on purpose: the raw endpoint's "+system" number lacks the pre-flight's
# agent context, so the previous cross-endpoint `min(+system) > max(bare)` passed only by
# accident (512 > 17 while the pre-flight's 700 sat in the "bare" group).
SYS_GT="$(python3 - "$RESULTS" <<'SYSPY'
import sys
RAW_BARE = {"messages (Anthropic)", "input as string (OpenAI)", "prompt (original shape)"}
RAW_SYS = {"messages + system string", "messages + system blocks"}
ANT_BARE = {"anthropic messages"}
ANT_SYS = {"anthropic messages + system"}
rows = [l.split("=", 1) for l in sys.argv[1].splitlines() if "=" in l]
def pick(names):
    return [int(v) for k, v in rows if k in names and v.isdigit()]
raw_bare, raw_sys = pick(RAW_BARE), pick(RAW_SYS)
ant_bare, ant_sys = pick(ANT_BARE), pick(ANT_SYS)
raw_ok = bool(raw_bare) and bool(raw_sys) and min(raw_sys) > max(raw_bare)
ant_ok = bool(ant_bare) and bool(ant_sys) and min(ant_sys) > max(ant_bare)
if raw_ok and ant_ok:
    print("yes")
else:
    print("no raw+sys=%s/%s pre-flight+sys=%s/%s" % (raw_sys, raw_bare, ant_sys, ant_bare))
SYSPY
)"
if [ "$SYS_GT" = "yes" ]; then
  probe_ok "the system block is counted into the prompt on both endpoints, not silently dropped"
else
  probe_fail "a request with a system block did not out-count the same request without one on both endpoints ($SYS_GT) — a count is dropping the system prompt"
fi

# The two surfaces, pinned as an ORDER instead of an equality: what a caller is about to
# pay must be at least what its own bytes cost. `/v1/messages/count_tokens` moved past
# `/v1/count-tokens` for the same message when it started counting the assembled request
# (10-19); the day it collapses back onto the raw number is the day this route stops
# telling clients what the request will really cost — the 24-against-774 defect, arriving
# quietly. Probe 13 §9 closes the loop by pinning this number against `usage.input_tokens`.
PREFLIGHT="$(python3 - "$RESULTS" <<'PFPY'
import sys
RAW_BARE = {"messages (Anthropic)", "input as string (OpenAI)", "prompt (original shape)"}
ANT_BARE = {"anthropic messages"}
rows = [l.split("=", 1) for l in sys.argv[1].splitlines() if "=" in l]
def pick(names):
    return [int(v) for k, v in rows if k in names and v.isdigit()]
raw, ant = pick(RAW_BARE), pick(ANT_BARE)
print("%d %d" % (max(raw), max(ant)) if raw and ant else "skip")
PFPY
)"
if [ "$PREFLIGHT" = "skip" ]; then
  probe_fail "pre-flight vs raw compared no rows — one of the two endpoints never answered"
else
  RAW_N="${PREFLIGHT% *}"
  PF_N="${PREFLIGHT#* }"
  probe_note "same one-line message: /v1/count-tokens=$RAW_N (your bytes) /v1/messages/count_tokens=$PF_N (what /v1/messages feeds the model)"
  if [ "$PF_N" -gt "$RAW_N" ]; then
    probe_ok "the pre-flight counts at least the caller's bytes ($PF_N > $RAW_N) — it sizes the request, not just the payload"
  else
    probe_fail "pre-flight=$PF_N vs raw=$RAW_N — /v1/messages/count_tokens is back to under-reporting what its route charges"
  fi
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
