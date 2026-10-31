#!/usr/bin/env bash
# 48-completions-promise-honesty.sh — does a /v1/completions parameter that nothing acts on say
# so, or buy a 200 that looks like it was honoured?
#
# Measured 10-31 on one live `serve` driving the scripted engine (no weights, so this is a
# wire-tier verdict and claims nothing about a model): six bodies — `echo:true`, `suffix`,
# `logprob_token_ids`, `include_stop_str_in_output:true`, `min_tokens:40`,
# `skip_special_tokens:false` — produced response bodies **identical to the plain request**, each
# HTTP 200. `n`, `stop`, `seed`, `temperature` and the repetition knobs all reach the sampler;
# these six decoded into properties no consumer read, and two more were declared in `CodingKeys`
# and never decoded at all (`logprob_token_ids`, `repetition_context_size`) — the second one the
# spelling `/v1/chat/completions` honours at `ChatHandler.swift:635`.
#
# Why the six are a defect and not a limitation: `echo` is what a loglikelihood harness asks for
# when it wants a score conditioned on the prompt. Given a 200 with a *continuation* in
# `choices[].text`, the harness computes an accuracy from the wrong quantity and reports it as a
# number. vllm honours `echo` and refuses by name the combinations it cannot serve, with
# `parameter` in the error (`vllm/entrypoints/openai/completion/protocol.py:535-550`) — this repo
# already answers the same way for `n>1` on chat and for `logprobs` on this very route.
#
# Legs:
#   1) positive control — a plain request is answered, so a later 400 means a refusal;
#   2) refusal — each un-honoured parameter comes back 400 `invalid_request_error`, with `param`
#      naming the field the client sent and `value` its value (probe rule 7: assert the field);
#   3) the two directions the refusal must NOT fire — `repetition_context_size` (a real knob:
#     200, threaded to its own sampler slot) and `logprobs` (its own honest answer: A2 scoring
#      where CoreAI exists, 501 `logitsUnsupported` where it does not), plus `echo` *with*
#      `logprobs`, which must reach the scoring path rather than the echo refusal;
#   4) floor — the leg counts its own subjects, so a server that 200s everything cannot pass §2 and
#      a server that 400s everything cannot pass §1 or §3.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="completions-promise-honesty"

SCRIPT_FILE="$(mktemp -t ocoreai-script-XXXXXX).json"
BODY_DIR="$(mktemp -d)"
probe_atexit 'rm -f "$SCRIPT_FILE"; rm -rf "$BODY_DIR"'

printf '%s\n' '{"segments": [" continuation"], "finishReason": "eos", "promptTokens": 6, "generatedTokens": 2}' \
  > "$SCRIPT_FILE"
export OCOREAI_SCRIPTED_ENGINE="$SCRIPT_FILE"

python3 - "$BODY_DIR" <<'PY'
import json, os, sys
out = sys.argv[1]
base = {"model": "scripted-model", "prompt": "The capital of France is", "max_tokens": 8}
CASES = {
    "plain": {},
    "echo": {"echo": True},
    "suffix": {"suffix": " END"},
    "logprob_token_ids": {"logprob_token_ids": [7, 8]},
    "include_stop": {"include_stop_str_in_output": True},
    "min_tokens": {"min_tokens": 40},
    "skip_special": {"skip_special_tokens": False},
    # Must NOT be refused: a knob this route threads, and the two loglikelihood shapes.
    "repetition_context": {"repetition_context_size": 12},
    "logprobs": {"logprobs": 2},
    "echo_with_logprobs": {"echo": True, "logprobs": 2},
}
for name, extra in CASES.items():
    body = dict(base)
    body.update(extra)
    with open(os.path.join(out, name + ".json"), "w") as fh:
        json.dump(body, fh)
print("bodies=%d" % len(os.listdir(out)), file=sys.stderr)
PY

probe_boot

post_body() {
  local body
  body="$(cat "$BODY_DIR/$1.json")"
  probe_api POST /v1/completions "$body"
}

probe_section "1) positive control — a plain request is answered, so a later 400 is a refusal"
post_body plain
if [ "$PROBE_STATUS" = "200" ] && printf '%s' "$PROBE_BODY" | grep -q '"text"'; then
  probe_ok "plain /v1/completions 200 with a completion — the surface serves, so §2's 400s are" \
    " verdicts and not a route that stopped answering"
else
  probe_fail "plain request got HTTP $PROBE_STATUS ($(printf '%s' "$PROBE_BODY" | head -c 160)) —" \
    " nothing below can be read as a refusal verdict"
fi

probe_section "2) refusal — each un-honoured parameter is named as the client sent it"
REFUSED=0
# Body-file label → the wire field the client actually wrote. Spelled out rather than derived,
# because the assertion is about the name on the wire: reusing the label here is how the first
# run of this probe found nothing (it blamed the server for the probe's own shorthand).
for shape in echo suffix logprob_token_ids include_stop min_tokens skip_special; do
  case "$shape" in
    include_stop) field='include_stop_str_in_output' ;;
    skip_special) field='skip_special_tokens' ;;
    *) field="$shape" ;;
  esac
  post_body "$shape"
  TYPE="$(probe_json "$PROBE_BODY" 'error.type')"
  PARAM="$(probe_json "$PROBE_BODY" 'error.param')"
  VALUE="$(probe_json "$PROBE_BODY" 'error.value')"
  MESSAGE="$(probe_json "$PROBE_BODY" 'error.message')"
  if [ "$PROBE_STATUS" != "400" ]; then
    probe_fail "$shape → HTTP $PROBE_STATUS: the parameter was accepted, so the answer is a 200" \
      " that does not say it ignored the field"
    continue
  fi
  if [ "$TYPE" != "invalid_request_error" ]; then
    probe_fail "$shape → 400 but type='${TYPE:-<absent>}' — both specs name invalid_request_error" \
      " for a 400 and an SDK branches on it"
    continue
  fi
  if [ "$PARAM" != "$field" ]; then
    probe_fail "$shape → 400 blaming param='${PARAM:-<absent>}' — the client must be told which" \
      " field to drop"; continue
  fi
  case "$MESSAGE" in
    *"$field"*) ;;
    *) probe_fail "$shape → message does not name the field it refused"; continue ;;
  esac
  if [ -z "$VALUE" ]; then
    probe_fail "$shape → 400 with no \`value\` — vllm puts the offending value beside the param" \
      " and a client reads it to see which of its own settings this was"; continue
  fi
  REFUSED=$(( REFUSED + 1 ))
  probe_ok "$shape → 400 invalid_request_error, param=$field, value='$VALUE'"
done

probe_section "3) the other direction — a knob that works, and the path loglikelihood owns"
post_body repetition_context
if [ "$PROBE_STATUS" = "400" ]; then
  probe_fail "repetition_context_size was refused — it is a real sampler knob (threaded at" \
    " CompletionsHandler's effectiveRepetitionContextSize), and refusing a working parameter costs" \
    " a client a knob it can use"
elif [ "$PROBE_STATUS" = "200" ]; then
  probe_ok "repetition_context_size → 200 — decoded and threaded, not refused and not dropped"
else
  probe_fail "repetition_context_size → HTTP $PROBE_STATUS ($(printf '%s' "$PROBE_BODY" | head -c 120))"
fi
for shape in logprobs echo_with_logprobs; do
  post_body "$shape"
  CODE="$(probe_json "$PROBE_BODY" 'error.error_code')"
  PARAM="$(probe_json "$PROBE_BODY" 'error.param')"
  case "$PROBE_STATUS" in
    200)
      probe_ok "$shape → 200 from the scoring path — this build answers loglikelihood for real" \
        " ($shape included)" ;;
    501)
      probe_ok "$shape → 501 logitsUnsupported — the honest answer for a box with no scoring" \
        " engine, and $shape reached the seat that decides it" ;;
    400)
      probe_fail "$shape → 400 refusing a parameter (param='${PARAM:-?}') instead of answering" \
        " the loglikelihood request — the refusal must not preempt the seat that can serve it" ;;
    *)
      probe_fail "$shape → HTTP $PROBE_STATUS${CODE:+ $CODE}, expected 200 (scored) or 501" \
        " (no scoring engine)" ;;
  esac
done

probe_section "4) floor — this leg counts its own subjects"
if [ "$REFUSED" -ge 6 ]; then
  probe_ok "$REFUSED/6 un-honoured parameters refused by name — §2 has subjects, so its green is" \
    " not a scan that matched nothing"
else
  probe_fail "only $REFUSED/6 parameters refused by name — the leg that counts these is not" \
    " measuring what it claims"
fi

probe_summary "$PROBE_NAME"
