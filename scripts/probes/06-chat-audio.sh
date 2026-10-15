#!/usr/bin/env bash
# 06-chat-audio.sh — does /v1/chat/completions hear the audio it accepts, or drop it?
#
# Why (AGENTS.md invariant 2 — the surface never claims more than the engine delivered):
# `/v1/chat/completions` accepts an `audio_url` content part. At the pinned mlx-swift-lm
# revision nothing under `Libraries/MLXVLMCommon` mentions `audio` at all, so no
# `UserInputProcessor` can turn waveform into model input — measured 10-15 on this host:
# posting an utterance as `audio_url` returned HTTP 200, `prompt_tokens` went DOWN
# (705 vs 743 for the same prompt without audio), and the model answered "Please provide
# the audio". A client cannot tell that from success; a user gets a confident answer to a
# sentence that was never heard.
#
# This probe pins that the third route is gone. For a chat request that carries audio, the
# only acceptable outcomes are:
#
#   1. DELIVERED — 200 whose body discloses `audio_input` (parts >= 1, the OS ASR engine,
#      how many parts produced words), and the words demonstrably reached the prompt:
#      `prompt_tokens` rises above the same turn with no audio, and the answer echoes the
#      utterance; or
#   2. REFUSED — a non-2xx whose typed `error_code` names the axis (permission / locale /
#      engine / payload) plus a remediation, in BOTH stream and non-stream mode.
#
# 200 with no `audio_input` is a FAIL, and that assertion is the point of the file.
#
# It also pins the status axis the two audio routes share: a fault in the client's bytes
# (`undecodable_audio`) is a 400 on the chat route exactly as the transcription table says,
# never a 503 telling the client to retry a payload that will never decode; and a refusal
# costs milliseconds, not a model load, because it happens before the scheduler.
#
# Speech Recognition on this host is `notDetermined`, so the honest live outcome for a real
# utterance is the REFUSAL — this probe reports which outcome it got and never claims
# delivery it did not measure.
#
# Run: bash scripts/probes/06-chat-audio.sh
PROBE_NAME="06-chat-audio"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

CHECKS=0
ok()  { CHECKS=$(( CHECKS + 1 )); probe_ok "$*"; }
bad() { CHECKS=$(( CHECKS + 1 )); probe_fail "$*"; }

UTTERANCE="The quick brown fox jumps over the lazy dog"
BASE_TEXT="Repeat verbatim the words you were given, nothing else."
WORKDIR="$(mktemp -d -t ocoreai-chataudio-XXXXXX)"

# The closed vocabulary a speech refusal may name (TranscriptFailure.errorCode).
VOCAB="os_unsupported speech_not_determined speech_denied speech_restricted locale_unsupported engine_fault engine_refused engine_timeout undecodable_audio no_speech_detected empty_transcript"

in_vocab() {
  local code="$1" v
  for v in $VOCAB; do
    [ "$code" = "$v" ] && return 0
  done
  return 1
}

# One line of the /v1/capabilities route index (`endpoints: [...]`), by path.
# Prints the note, "ABSENT" when the route is not indexed, "PARSE-ERROR" on garbage.
index_note() {
  PROBE_JSON_INPUT="$1" PROBE_JSON_WANT="$2" python3 - <<'PY'
import json, os
try:
    doc = json.loads(os.environ["PROBE_JSON_INPUT"])
except Exception:
    print("PARSE-ERROR"); raise SystemExit(0)
want = os.environ["PROBE_JSON_WANT"]
for row in doc.get("endpoints") or []:
    if row.get("path") == want:
        print(row.get("note") or "")
        break
else:
    print("ABSENT")
PY
}

index_rows() {
  PROBE_JSON_INPUT="$1" python3 - <<'PY'
import json, os
try:
    print(len(json.loads(os.environ["PROBE_JSON_INPUT"]).get("endpoints") or []))
except Exception:
    print(0)
PY
}

# true / false for key presence — probe_json cannot distinguish absent from empty.
has_key() {
  PROBE_JSON_INPUT="$1" PROBE_JSON_PATH="$2" python3 - <<'PY'
import json, os
node = None
try:
    node = json.loads(os.environ["PROBE_JSON_INPUT"])
except Exception:
    print("false"); raise SystemExit(0)
for part in os.environ["PROBE_JSON_PATH"].split("."):
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        print("false"); raise SystemExit(0)
print("true")
PY
}

# Build one chat body: text part, plus an optional audio part.
chat_body() {
  local mode="$1" audio="$2" stream="${3:-false}"
  python3 - "$PROBE_MODEL" "$BASE_TEXT" "$mode" "$audio" "$stream" <<'PY'
import json, sys
model, text, mode, audio, stream = sys.argv[1:6]
parts = [{"type": "text", "text": text}]
if mode == "audio":
    parts.append({"type": "audio_url", "audio_url": {"url": audio}})
body = {
    "model": model,
    "session_id": "probe-chat-audio-%s" % mode,
    "max_tokens": 24,
    "temperature": 0.0,
    "messages": [{"role": "user", "content": parts}],
}
if stream == "true":
    body["stream"] = True
print(json.dumps(body))
PY
}

probe_boot
probe_require_ready_model

# ── 1. baseline: a text-only turn must not claim anything about audio ─────────
probe_section "baseline — text-only turn, so absence means 'no audio here'"
BASE_BODY="$(chat_body text "" )"
probe_chat "probe-chat-audio-baseline" "$BASE_BODY"
if [ "${PROBE_STATUS:-}" = "200" ]; then
  ok "text-only chat 200 in ${PROBE_ELAPSED_MS}ms"
else
  bad "text-only chat -> ${PROBE_STATUS:-no response}: $(printf '%.200s' "$PROBE_BODY")"
fi
BASE_TOKENS="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens')"
BASE_ANSWER="$(probe_json "$PROBE_BODY" 'choices.0.message.content')"
probe_note "baseline prompt_tokens=${BASE_TOKENS:-none} answer='${BASE_ANSWER:0:60}'"
if [ "$(has_key "$PROBE_BODY" audio_input)" = "false" ]; then
  ok "no audio in, no audio_input out — absence is not a claim that audio was delivered"
else
  bad "audio_input present on a request that carried no audio"
fi

# ── 2. payload faults: refused by name, before any model work ────────────────
probe_section "payload faults — 400 + typed code, and fast (refused before the scheduler)"
check_fault() {
  local label="$1" audio="$2"
  local body code elapsed
  body="$(chat_body audio "$audio")"
  probe_chat "probe-chat-audio-fault" "$body"
  elapsed="$PROBE_ELAPSED_MS"
  code="$(probe_json "$PROBE_BODY" 'error.error_code')"
  probe_note "$label -> HTTP ${PROBE_STATUS:-none} in ${elapsed}ms code=${code:-none}"
  if [ "${PROBE_STATUS:-}" = "400" ]; then
    ok "$label refused with 400 (the client's bytes, not the service's state)"
  else
    bad "$label -> ${PROBE_STATUS:-no response}, expected 400: $(printf '%.200s' "$PROBE_BODY")"
  fi
  if in_vocab "${code:-}"; then
    ok "$label names the axis: error_code=$code"
  else
    bad "$label error_code='${code:-absent}' is outside the speech vocabulary"
  fi
  if [ -n "$(probe_json "$PROBE_BODY" 'error.remediation')" ]; then
    ok "$label carries a remediation, not a bare status"
  else
    bad "$label refused without telling the client what to fix"
  fi
  if [ "$elapsed" -lt 5000 ]; then
    ok "$label refused in ${elapsed}ms (< 5s: no engine handle, no prefill spent on a request that cannot be heard)"
  else
    bad "$label took ${elapsed}ms — a payload refusal should not cost model work"
  fi
}
check_fault "remote https audio_url" "https://example.invalid/utterance.wav"
check_fault "undecodable base64"    "data:audio/wav;base64,!!!not-base64!!!"

# Over the per-request part cap: refuse the request rather than hear some parts and
# silently lose the rest.
MANY="$(python3 - "$PROBE_MODEL" "$BASE_TEXT" <<'PY'
import json, sys
model, text = sys.argv[1:3]
parts = [{"type": "text", "text": text}]
for _ in range(9):
    parts.append({"type": "audio_url", "audio_url": {"url": "https://example.invalid/%d.wav" % len(parts)}})
print(json.dumps({
    "model": model, "session_id": "probe-chat-audio-many", "max_tokens": 8,
    "temperature": 0.0, "messages": [{"role": "user", "content": parts}]}))
PY
)"
probe_chat "probe-chat-audio-many" "$MANY"
MANY_CODE="$(probe_json "$PROBE_BODY" 'error.error_code')"
probe_note "9 audio parts -> HTTP ${PROBE_STATUS:-none} in ${PROBE_ELAPSED_MS}ms code=${MANY_CODE:-none}"
if [ "${PROBE_STATUS:-}" = "400" ]; then
  ok "9 audio parts refused outright (no partial listening, no quiet tail-drop)"
else
  bad "9 audio parts -> ${PROBE_STATUS:-no response}; expected a refusal, not a partial answer"
fi

# ── 3. the utterance round trip: delivered, or refused — never dropped ───────
probe_section "one real utterance — delivered-as-text or refused, and 200-without-disclosure is a FAIL"
AIFF="$WORKDIR/utterance.aiff"
SAY_ERROR="$(say -o "$AIFF" -- "$UTTERANCE" 2>&1)"
SAY_RC=$?
if [ "$SAY_RC" -ne 0 ] || [ ! -s "$AIFF" ]; then
  bad "say could not synthesize the utterance (rc=$SAY_RC): ${SAY_ERROR:0:160}"
  AUDIO_DATA_URL=""
else
  probe_note "synthesized $(wc -c < "$AIFF" | tr -d ' ') bytes of AIFF"
  AUDIO_DATA_URL="$(python3 - "$AIFF" <<'PY'
import base64, sys
with open(sys.argv[1], "rb") as fh:
    print("data:audio/aiff;base64," + base64.b64encode(fh.read()).decode())
PY
)"
fi

if [ -n "$AUDIO_DATA_URL" ]; then
  BODY="$(chat_body audio "$AUDIO_DATA_URL")"
  probe_chat "probe-chat-audio-live" "$BODY"
  UTTER_STATUS="${PROBE_STATUS:-}"
  code="$(probe_json "$PROBE_BODY" 'error.error_code')"
  AI_PARTS="$(probe_json "$PROBE_BODY" 'audio_input.parts')"
  AI_DONE="$(probe_json "$PROBE_BODY" 'audio_input.transcribed')"
  AI_ENGINE="$(probe_json "$PROBE_BODY" 'audio_input.engine')"
  AI_LOCALES="$(probe_json "$PROBE_BODY" 'audio_input.locales')"
  AI_CHARS="$(probe_json "$PROBE_BODY" 'audio_input.characters')"
  AUDIO_TOKENS="$(probe_json "$PROBE_BODY" 'usage.prompt_tokens')"
  AUDIO_ANSWER="$(probe_json "$PROBE_BODY" 'choices.0.message.content')"
  probe_note "utterance -> HTTP ${PROBE_STATUS:-none} in ${PROBE_ELAPSED_MS}ms | prompt_tokens=${AUDIO_TOKENS:-none} (baseline ${BASE_TOKENS:-none}) | audio_input parts=${AI_PARTS:-absent} transcribed=${AI_DONE:-absent} engine=${AI_ENGINE:-absent} locales=${AI_LOCALES:-absent} chars=${AI_CHARS:-absent}"
  probe_note "answer: '${AUDIO_ANSWER:0:120}'"

  case "${PROBE_STATUS:-}" in
    200)
      # Outcome 1: delivered. The disclosure is what makes the 200 honest.
      if [ "$(has_key "$PROBE_BODY" audio_input)" = "true" ] && [ "${AI_PARTS:-0}" -ge 1 ]; then
        ok "200 discloses audio_input (parts=$AI_PARTS) — the audio is accounted for, not gone"
      else
        bad "HTTP 200 with no audio_input — this is the silent drop: accepted, answered, audio never heard"
      fi
      if [ -n "$AI_ENGINE" ]; then
        ok "disclosed engine=$AI_ENGINE (OS ASR — the model received text, not waveform)"
      else
        bad "audio_input has no engine field: the client cannot tell who heard it"
      fi
      if [ "${AI_DONE:-0}" -ge 1 ]; then
        ok "transcribed=$AI_DONE/$AI_PARTS part(s) into words (${AI_CHARS:-0} chars)"
        # The words must be in the prompt the model actually saw, or the disclosure is
        # theatre: same turn, same text, audio replaced by its transcript => tokens rise.
        if [ -n "$AUDIO_TOKENS" ] && [ -n "$BASE_TOKENS" ] \
           && [ "$AUDIO_TOKENS" -gt "$BASE_TOKENS" ]; then
          ok "prompt_tokens rose ${BASE_TOKENS} -> ${AUDIO_TOKENS}: the transcript reached the model"
        else
          bad "prompt_tokens ${AUDIO_TOKENS:-none} vs baseline ${BASE_TOKENS:-none}: a transcript was claimed but never entered the prompt"
        fi
        MATCHED="$(python3 - "$AUDIO_ANSWER" "$UTTERANCE" <<'PY'
import sys
answer, wanted = sys.argv[1].lower(), sys.argv[2].lower()
common = set(wanted.split()) & set(answer.split())
print(len(common))
PY
)"
        if [ "${MATCHED:-0}" -ge 3 ]; then
          ok "the answer echoes the utterance ($MATCHED shared words) — speech genuinely entered the turn"
        else
          probe_note "answer shares $MATCHED words with the utterance (short max_tokens; token accounting above is the delivery evidence)"
        fi
      else
        ok "no part produced words (transcribed=${AI_DONE:-0}) — disclosed rather than invented"
      fi
      ;;
    400|403|503)
      # Outcome 2: refused. Honest, as long as it names the axis and the fix.
      if in_vocab "${code:-}"; then
        ok "refused honestly at ${PROBE_STATUS} with error_code=$code"
      else
        bad "refused with error_code='${code:-absent}', outside the speech vocabulary"
      fi
      if [ -n "$(probe_json "$PROBE_BODY" 'error.remediation')" ]; then
        ok "refusal names the fix: $(printf '%.120s' "$(probe_json "$PROBE_BODY" 'error.remediation')")"
      else
        bad "refusal has no remediation — a client cannot act on a bare status"
      fi
      probe_note "expected on this host: Speech Recognition is notDetermined (see /v1/multimodal/status), so nothing can hear the utterance"

      # Cross-surface agreement: the chat route refuses for a permission it can read, so the
      # status payload must not be claiming `ready` for the same microphone two lines later.
      # UTTER_STATUS was latched before this call: probe_api overwrites PROBE_STATUS/PROBE_BODY.
      probe_api POST /v1/multimodal/status '{}'
      HEARING_VERDICT="$(probe_json "$PROBE_BODY" 'hearing.verdict')"
      probe_note "status says hearing.verdict=${HEARING_VERDICT:-absent}, transcriptionStatus=$(probe_json "$PROBE_BODY" 'transcriptionStatus')"
      if [ -n "$HEARING_VERDICT" ] && [ "$HEARING_VERDICT" != "ready" ]; then
        ok "the chat refusal agrees with the status payload (hearing.verdict=$HEARING_VERDICT, not ready)"
      elif [ "$HEARING_VERDICT" = "ready" ]; then
        bad "chat refused for speech permission while /v1/multimodal/status says hearing.verdict=ready — one microphone, two claims"
      else
        bad "chat refused a speech-permission failure with nothing behind it: the status payload carries no hearing verdict"
      fi
      ;;
    *)
      bad "unexpected HTTP ${PROBE_STATUS:-none} for an audio turn: $(printf '%.200s' "$PROBE_BODY")"
      ;;
  esac

  # ── 4. streaming parity: the same audio must not be refused in one mode and
  #    answered as if heard in the other.
  probe_section "stream parity — the refusal stops SSE too (a dropped payload is not a stream)"
  SBODY="$(chat_body audio "$AUDIO_DATA_URL" true)"
  SRAW="$(curl -sS -N -m "${OCOREAI_PROBE_CURL_TIMEOUT:-180}" -w $'\n%{http_code}' \
    -X POST -H 'Content-Type: application/json' --data "$SBODY" "$PROBE_BASE/v1/chat/completions" 2>&1)"
  SSTATUS="${SRAW##*$'\n'}"
  SBODY_RESP="${SRAW%$'\n'*}"
  SSE_CHUNKS="$(printf '%s' "$SBODY_RESP" | grep -c '^data:' || true)"
  probe_note "stream -> HTTP ${SSTATUS} | data-chunks=${SSE_CHUNKS} | first=$(printf '%.140s' "$(printf '%s' "$SBODY_RESP" | head -c 140 | tr '\n' ' ')")"
  if [ "$SSTATUS" = "${UTTER_STATUS:-}" ]; then
    ok "stream and non-stream agree on the outcome (HTTP $SSTATUS for the same audio turn)"
  else
    bad "stream said $SSTATUS where non-stream said ${UTTER_STATUS:-none} — one audio turn, two answers"
  fi
  case "${UTTER_STATUS:-}" in
    400|403|503)
      if printf '%s' "$SBODY_RESP" | grep -q '"error"'; then
        ok "the refusal reaches the streaming route as an error body, not an empty SSE stream"
      else
        bad "streaming refusal carried no error body: a client reading SSE sees a turn that produced nothing"
      fi
      ;;
    200)
      if [ "${SSE_CHUNKS:-0}" -ge 1 ] && printf '%s' "$SBODY_RESP" | grep -q '\[DONE\]'; then
        ok "stream delivered tokens and terminated cleanly ($SSE_CHUNKS chunks)"
      else
        bad "stream returned 200 with $SSE_CHUNKS data chunks — the audio turn produced no stream"
      fi
      ;;
  esac
fi

# ── 5. the index must tell clients what happens to audio on this route ───────
probe_section "endpoint index — the discovery surface says audio is heard or refused, not ignored"
probe_api GET /v1/capabilities
if [ "${PROBE_STATUS:-}" = "200" ]; then
  ROWS="$(index_rows "$PROBE_BODY")"
  probe_note "endpoint index rows: ${ROWS}"
  # Premises floor: if the index stopped being published, every lookup below would read
  # ABSENT and the run would still be "honest about its own blindness" — the floor is what
  # makes a stopped scan red rather than merely a different set of failures.
  if [ "${ROWS:-0}" -ge 30 ]; then
    ok "the index still enumerates the surface ($ROWS routes)"
  else
    bad "endpoint index has $ROWS rows — this scan is not looking at the payload it thinks it is"
  fi
  NOTE="$(index_note "$PROBE_BODY" /v1/chat/completions)"
  probe_note "index note for /v1/chat/completions: ${NOTE:0:170}"
  case "$NOTE" in
    ABSENT) bad "/v1/chat/completions is missing from the endpoint index" ;;
    *audio*) ok "its note tells clients what happens to audio_url on this route" ;;
    *) bad "its note is silent about audio, so clients send waveform expecting the model to hear it" ;;
  esac
  STT_NOTE="$(index_note "$PROBE_BODY" /v1/audio/transcriptions)"
  if [ -n "$STT_NOTE" ] && [ "$STT_NOTE" != "ABSENT" ]; then
    ok "the index also points at the dedicated transcription route"
  else
    bad "/v1/audio/transcriptions absent from the index — the 404 hint leads nowhere"
  fi
else
  bad "GET /v1/capabilities -> ${PROBE_STATUS:-no response}"
fi

# ── verdict ───────────────────────────────────────────────────────────────────
# Premises floor. A happy-path run issues ~19 verdicts here (2 baseline + 9 payload faults
# + 4 utterance + 2 stream parity + 3 index + the cross-surface check). 16 is well under
# that and well above zero: a route that stopped answering, or a scan that stopped matching,
# fails the run instead of passing vacuously (AGENTS.md invariant 1).
if [ "$CHECKS" -ge 16 ]; then
  ok "premise floor: $CHECKS verdicts issued by this run"
else
  probe_fail "only $CHECKS verdicts issued (< 16) — this probe silently stopped measuring"
fi
rm -rf "$WORKDIR"
probe_summary "$PROBE_NAME"
