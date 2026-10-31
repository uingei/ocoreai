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
#   4) domain — a penalty window out of range (0) is refused with the field named and the bound in
#      the message, the way `/v1/chat/completions` already refuses it. `presence_context_size` and
#      `frequency_context_size` bought a silent 200 here until 10-31: undeclared keys, dropped by
#      Codable, while the penalty they bound *was* applied — over MLX's default window of 20.
#   5) floor — the leg counts its own subjects in both directions, so a server that 200s everything
#      cannot pass §2 or §4 and one that 400s everything cannot pass §1 or §3.
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
    # A penalty window the client asked for: threaded, so legal, so never refused.
    "presence_window": {"presence_penalty": 1.5, "presence_context_size": 200},
    "frequency_window": {"frequency_penalty": 0.4, "frequency_context_size": 300},
    "logprobs": {"logprobs": 2},
    "echo_with_logprobs": {"echo": True, "logprobs": 2},
}
BAD = {
    # Out of domain on both routes. Until 10-31 this route answered 200 to these two, because the
    # keys were not declared at all: /v1/chat/completions says "must be at least 1, got 0".
    "bad_repetition_window": ("repetition_context_size", 0),
    "bad_presence_window": ("presence_context_size", 0),
    "bad_frequency_window": ("frequency_context_size", 0),
}
for name, extra in CASES.items():
    body = dict(base)
    body.update(extra)
    with open(os.path.join(out, name + ".json"), "w") as fh:
        json.dump(body, fh)
for name, (field, value) in BAD.items():
    body = dict(base)
    body[field] = value
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
KNOBS_OK=0
for shape in repetition_context presence_window frequency_window; do
  case "$shape" in
    repetition_context) field='repetition_context_size' ;;
    presence_window) field='presence_context_size' ;;
    frequency_window) field='frequency_context_size' ;;
  esac
  post_body "$shape"
  if [ "$PROBE_STATUS" = "400" ]; then
    probe_fail "$field was refused — it is a real sampler knob (threaded at CompletionsHandler's" \
      " effective*ContextSize), and refusing a working parameter costs a client a knob it can use"
  elif [ "$PROBE_STATUS" = "200" ]; then
    KNOBS_OK=$(( KNOBS_OK + 1 ))
    probe_ok "$field → 200 — decoded and threaded, not refused and not dropped"
  else
    probe_fail "$field → HTTP $PROBE_STATUS ($(printf '%s' "$PROBE_BODY" | head -c 120))"
  fi
done

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

probe_section "4) domain — a value chat refuses must not buy a 200 here"
# Measured 10-31 before the round: `presence_context_size:0` and `frequency_context_size:0` were
# undeclared keys, so this route dropped them and answered 200, while `/v1/chat/completions`
# answered 400 "must be at least 1, got 0". A client that asked for a 200-token window under a
# penalty it also asked for got MLX's default of 20 (Evaluate.swift:355) and nothing said so.
DENIED=0
for shape in bad_repetition_window bad_presence_window bad_frequency_window; do
  case "$shape" in
    bad_repetition_window) field='repetition_context_size' ;;
    bad_presence_window) field='presence_context_size' ;;
    bad_frequency_window) field='frequency_context_size' ;;
  esac
  post_body "$shape"
  PARAM="$(probe_json "$PROBE_BODY" 'error.param')"
  MESSAGE="$(probe_json "$PROBE_BODY" 'error.message')"
  if [ "$PROBE_STATUS" != "400" ]; then
    probe_fail "$field:0 → HTTP $PROBE_STATUS — the sibling route refuses this value by name, so the" \
    " same body cannot be silently accepted here on the strength of a key nobody declared"
    continue
  fi
  if [ "$PARAM" != "$field" ]; then
    probe_fail "$field:0 → 400 blaming param='${PARAM:-<absent>}' — the client must be told which" \
      " window to fix"; continue
  fi
  case "$MESSAGE" in
    *"at least 1"*) ;;
    *) probe_fail "$field:0 → 400 without the range in its message: \"$MESSAGE\"" \
      " — a bound without the bound is not a diagnosis"; continue ;;
  esac
  DENIED=$(( DENIED + 1 ))
  probe_ok "$field:0 → 400 invalid_request_error, param=$field, range stated"
done

probe_section "5) floor — this leg counts its own subjects"
if [ "$REFUSED" -ge 6 ]; then
  probe_ok "$REFUSED/6 un-honoured parameters refused by name — §2 has subjects, so its green is" \
    " not a scan that matched nothing"
else
  probe_fail "only $REFUSED/6 parameters refused by name — the leg that counts these is not" \
    " measuring what it claims"
fi
if [ "$KNOBS_OK" -ge 3 ] && [ "$DENIED" -ge 3 ]; then
  probe_ok "$KNOBS_OK/3 legal windows accepted and $DENIED/3 out-of-domain ones refused by name — the" \
    " two directions of the window contract were both actually exercised"
else
  probe_fail "windows leg measured $KNOBS_OK/3 accepted, $DENIED/3 refused — one direction went" \
    " untested, so a green here would not mean the contract holds"
fi

probe_summary "$PROBE_NAME"
