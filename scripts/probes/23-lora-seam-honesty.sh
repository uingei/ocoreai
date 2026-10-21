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
#   6. AN ID THAT EXISTS NOWHERE IS ANSWERED — 404 or 503, within 30 s, naming the id, with
#      the box still serving. Silence is the defect this gate was written against.
#
# ### Hub refusal — gated hard since the same session
#   Measured here before the guard: a nonexistent hub id answered nothing within 25 s on BOTH
#   /v1/models/evaluate and /v1/chat/completions (the chat leg was still silent at 300 s),
#   because the fallback hub client owns no deadline ocoreai controls and huggingface.co is a
#   black hole on this network. `HubReachability` now asks the fallback whether it can answer at
#   all — existence costs under a second on a reachable hub — so §4 asserts the refusal: an
#   answer within 30 s, HTTP 404 (a hub said it is not here) or 503 (a hub could not be
#   asked), naming the id, with the box still serving afterwards.
#
# ### Known-open (xfail, measured not assumed)
#   The refusal is per-attempt, not remembered: §4b re-sends the same dead id and reports both
#   elapsed times. EnginePool keeps no negative cache, so a client retrying a typo re-pays the
#   probe window (AGENTS.md § Open).
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

probe_section "4) an unresolvable id must be refused by name, promptly"
# Bounded at 30 s on purpose: the guard's window is 8 s per hub, so an honest refusal costs
# well under that, and the number a caller experiences is the client-side wait — not how long
# the resolver could theoretically stall.
FIRST_ELAPSED=0
for path in /v1/models/evaluate /v1/chat/completions; do
  case "$path" in
    /v1/models/evaluate) body="{\"model\":\"$BOGUS\",\"dataset\":[\"hello there world\"],\"batch_size\":1,\"max_batches\":1}" ;;
    *) body="{\"model\":\"$BOGUS\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" ;;
  esac
  started=$(date +%s)
  OCOREAI_PROBE_CURL_TIMEOUT=30 probe_api POST "$path" "$body" || true
  elapsed=$(( $(date +%s) - started ))
  # The JSON encoder emits "/" as "\/", so a raw substring scan of the body misses the very id
  # the refusal names — measured 10-21: the check failed against
  # "Model no-such-org\/no-such-model-ocoreai is not available…". Compare against the wire's
  # own escaping, not the string we typed.
  named="$(printf '%s' "${PROBE_BODY:-}" | tr -d '\\')"
  case "${PROBE_STATUS:-000}" in
    404 | 503)
      case "$named" in
        *"$BOGUS"*)
          # 503 means "could not ask", so it owes the caller the full account: which hub said
          # what, and the lever that would fix this network. 404 means a hub answered, and
          # naming the id is enough.
          if [ "${PROBE_STATUS}" = "503" ]; then
            missing=""
            printf '%s' "$named" | grep -q "ModelScope" || missing="${missing} ModelScope"
            printf '%s' "$named" | grep -q "Hugging Face" || missing="${missing} Hugging-Face"
            printf '%s' "$named" | grep -q "HF_ENDPOINT" || missing="${missing} HF_ENDPOINT"
            if [ -z "$missing" ]; then
              probe_ok "$path refused in ${elapsed}s with HTTP 503 naming the id, both hubs and the HF_ENDPOINT lever"
            else
              probe_fail "HTTP 503 missing:${missing} — a could-not-ask refusal must account for both hubs and name the remedy: ${PROBE_BODY:0:160}"
            fi
          else
            probe_ok "$path refused in ${elapsed}s with HTTP 404, naming $BOGUS"
          fi
          ;;
        *)
          probe_fail "$path refused with HTTP ${PROBE_STATUS} but never named the id: ${PROBE_BODY:0:160}"
          ;;
      esac
      ;;
    000)
      probe_fail "$path answered nothing in ${elapsed}s for an id that exists nowhere — silence is the defect this gate exists for, not an outcome"
      ;;
    *)
      probe_fail "$path answered HTTP ${PROBE_STATUS} for an unresolvable id — expected 404 (absent) or 503 (could not ask): ${PROBE_BODY:0:160}"
      ;;
  esac
  if [ "$path" = "/v1/chat/completions" ]; then
    FIRST_ELAPSED="$elapsed"
  fi
done
if alive; then
  probe_ok "server alive after two refused loads"
else
  probe_fail "server stopped answering /health after refused loads"
fi

probe_section "4b) residual — the refusal is not remembered (known-open)"
# The guard prices every attempt. Measured 10-21 post-fix: ~9 s for the first request for a dead
# id on this network (ModelScope 404 in ~0.2 s + an 8 s HF window), and the same again on a
# retry — EnginePool keeps no negative cache, so a client retrying a typo re-pays the window.
started=$(date +%s)
OCOREAI_PROBE_CURL_TIMEOUT=30 probe_api POST /v1/chat/completions "{\"model\":\"$BOGUS\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" \
  || true
repeat=$(( $(date +%s) - started ))
if [ "${PROBE_STATUS:-000}" = "000" ]; then
  probe_fail "the retry of a dead id went silent after ${repeat}s — a refusal must hold every time, not just the first"
else
  probe_xfail open "a dead id re-pays the probe window — first ${FIRST_ELAPSED}s, retry ${repeat}s, both HTTP ${PROBE_STATUS}: no negative cache in EnginePool"
fi

probe_section "5) survival — every other conversation still works"
probe_api POST /v1/chat/completions "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly the word $CODE_WORD and nothing else.\"}],\"max_tokens\":8}" || true
if printf '%s' "${PROBE_BODY:-}" | grep -q "$CODE_WORD"; then
  probe_ok "chat still serves after the LoRA seam refused three requests"
else
  probe_fail "chat turn did not return the code word after LoRA (HTTP ${PROBE_STATUS:-000}): ${PROBE_BODY:0:160}"
fi

probe_summary "$PROBE_NAME"
