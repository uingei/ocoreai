#!/usr/bin/env bash
# 23-lora-seam-honesty.sh — does one LoRA request take the box down, and does an id that
# `/v1/models` advertises reach the engine at all?
#
# ### What was measured here on 10-21 (before the fix, this host, cold process)
#   POST /v1/models/evaluate  {"model":<ready id>,"dataset":["The quick brown fox …"],
#                              "batch_size":1,"max_batches":1}
#       → curl (52) Empty reply from server; process died: Trace/BPT trap: 5.
#   POST /v1/models/train     two well-formed 10-token samples, 2 iterations
#       → HTTP 200, SSE cut mid-body ("transfer closed with outstanding read data"),
#         /health unreachable afterwards.
#   The crash report named the line, and it is upstream's:
#       Swift runtime failure: type cast failed
#       dynamic_cast_existential_1_unconditional
#       static LoRATrain.loss(model:inputs:targets:lengths:)
#   i.e. `model as! any LLMModel` at mlx-swift-lm `LoraTrain.swift:165` (pin 48114eedf),
#   reached by a checkpoint that loads through VLMModelFactory. Legal input, dead server,
#   every other conversation on the box gone with it.
#
# ### What this probe locks down (hard gates)
#   1. NO SILENCE, NO DEATH — each LoRA request must return an answer, and `/health` must
#      still answer afterwards. A refusal may be 400 or an SSE `type:"error"` chunk; a
#      dropped connection or a dead server fails the run. This is the regression gate: it
#      goes red the day the seam stops asking the capability question the loss will answer.
#   2. THE REFUSAL NAMES THE REQUIREMENT — when the model cannot do LoRA the message must
#      say what was required (LLMModel) and what arrived, not "model not found".
#   3. AN ID IS AN ID — `/v1/models/evaluate` may no longer answer "Model not found" for
#      the id `/v1/models` advertises while `/health` reports loadedModels: 0.
#   4. SURVIVAL — after all of it a normal chat turn still returns its code word.
#   5. TINY SAMPLE — if this box's model *does* conform (a text LLM), a 1-token sample must
#      come back 400 naming `dataset[0]`. On a non-conforming checkpoint the capability
#      refusal comes first, and the probe says so instead of pretending it checked
#      (LoRASampleDomain pins that rule by exact value in Tests/).
#
# ### Known-open (xfail, measured not assumed)
#   An id that cannot be resolved should refuse promptly. Measured 10-21: a nonexistent hub
#   id produced no answer within 20 s on BOTH /v1/models/evaluate and /v1/chat/completions
#   (the shared `EnginePool` load path waits out the hub resolver), while /health stayed up.
#
# Run: bash scripts/probes/run.sh 23
PROBE_NAME="23-lora-seam-honesty"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

CODE_WORD="BULWARK"
LONG_SAMPLE="The quick brown fox jumps over the lazy dog near the riverbank at dusk."
BOGUS="no-such-org/no-such-model-ocoreai"

probe_boot
probe_require_ready_model
MODEL="$PROBE_MODEL"

alive() {
  probe_api GET /health || true
  [ "${PROBE_STATUS:-}" = "200" ]
}

probe_section "1) evaluate with a legal dataset — answer, and still alive"
probe_api POST /v1/models/evaluate "{\"model\":\"$MODEL\",\"dataset\":[\"$LONG_SAMPLE\"],\"batch_size\":1,\"max_batches\":1}" \
  || probe_note "evaluate returned no response at all: ${PROBE_BODY:0:160}"
EVAL_STATUS="${PROBE_STATUS:-000}"
EVAL_BODY="$PROBE_BODY"
if [ "$EVAL_STATUS" = "200" ]; then
  case "$EVAL_BODY" in
    *loss*) probe_ok "$MODEL conforms — loss measured: $(printf '%s' "$EVAL_BODY" | head -c 120)" ;;
    *) probe_fail "200 without a loss in the body: ${EVAL_BODY:0:160}" ;;
  esac
elif [ "$EVAL_STATUS" = "400" ]; then
  case "$EVAL_BODY" in
    *LLMModel*) probe_ok "named refusal: the message names the capability it needs" ;;
    *) probe_fail "400 that does not name the requirement: ${EVAL_BODY:0:160}" ;;
  esac
else
  probe_fail "evaluate gave HTTP $EVAL_STATUS — expected 200 (ran) or 400 (refused), never silence: ${EVAL_BODY:0:160}"
fi
if alive; then probe_ok "server alive after evaluate"; else
  probe_fail "server died on /v1/models/evaluate (HTTP $EVAL_STATUS) — a LoRA request owned the process"
fi

probe_section "2) train with well-formed samples — the stream must close honestly"
probe_api POST /v1/models/train "{\"model\":\"$MODEL\",\"trainingData\":{\"inline\":[\"$LONG_SAMPLE\",\"Pack my box with five dozen liquor jugs and three dozen more.\"]}}" \
  || probe_note "train returned no response at all: ${PROBE_BODY:0:160}"
TRAIN_BODY="$PROBE_BODY"
if printf '%s' "$TRAIN_BODY" | grep -q '"type":"error"'; then
  if printf '%s' "$TRAIN_BODY" | grep -qE '"message":"[^"]{20,}'; then
    probe_ok "train refused with a reason: $(printf '%s' "$TRAIN_BODY" | head -c 140)"
  else
    probe_fail "train error chunk carries no usable message: ${TRAIN_BODY:0:160}"
  fi
elif printf '%s' "$TRAIN_BODY" | grep -q '"type":"train"'; then
  probe_ok "train ran (progress chunks delivered)"
else
  probe_fail "train stream produced neither progress nor an error chunk: ${TRAIN_BODY:0:160}"
fi
if alive; then probe_ok "server alive after train"; else
  probe_fail "server died on /v1/models/train — a LoRA request owned the process"
fi

probe_section "3) tiny sample — dataset rule (only reachable when the model conforms)"
if [ "$EVAL_STATUS" = "200" ]; then
  probe_api POST /v1/models/evaluate "{\"model\":\"$MODEL\",\"dataset\":[\"a\"],\"batch_size\":1,\"max_batches\":1}" || true
  if [ "${PROBE_STATUS:-}" = "400" ] && printf '%s' "$PROBE_BODY" | grep -q 'dataset\[0\]'; then
    probe_ok "1-token sample refused by position: ${PROBE_BODY:0:140}"
  else
    probe_fail "1-token sample was not refused by name (HTTP ${PROBE_STATUS:-000}): ${PROBE_BODY:0:160}"
  fi
else
  probe_note "capability refused first on $MODEL, so the sample rule is unmeasured here — pinned by exact value in Tests/ocoreaiTests/LoRASampleDomainTests.swift"
fi

probe_section "4) an unresolvable id should refuse promptly (known-open: hub resolver waits)"
# Bounded at 25 s on purpose: the measured claim is "no answer within 25 s", not "the
# resolver takes 180 s" — the client-side deadline is what a caller actually experiences,
# and a probe that waits out the resolver spends six minutes learning nothing new.
for path in /v1/models/evaluate /v1/chat/completions; do
  case "$path" in
    /v1/models/evaluate) body="{\"model\":\"$BOGUS\",\"dataset\":[\"hello there world\"],\"batch_size\":1,\"max_batches\":1}" ;;
    *) body="{\"model\":\"$BOGUS\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" ;;
  esac
  started=$(date +%s)
  OCOREAI_PROBE_CURL_TIMEOUT=25 probe_api POST "$path" "$body" || true
  elapsed=$(( $(date +%s) - started ))
  if [ "${PROBE_STATUS:-000}" = "000" ]; then
    probe_xfail open "$path with an unresolvable id: no answer after ${elapsed}s (hub resolver unbounded at the wire)"
  else
    probe_ok "$path refused in ${elapsed}s: ${PROBE_BODY:0:120}"
  fi
done

probe_section "5) survival — every other conversation still works"
probe_api POST /v1/chat/completions "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly the word $CODE_WORD and nothing else.\"}],\"max_tokens\":8}" || true
if printf '%s' "${PROBE_BODY:-}" | grep -q "$CODE_WORD"; then
  probe_ok "chat still serves after the LoRA seam refused three requests"
else
  probe_fail "chat turn did not return the code word after LoRA (HTTP ${PROBE_STATUS:-000}): ${PROBE_BODY:0:160}"
fi

probe_summary "$PROBE_NAME"
