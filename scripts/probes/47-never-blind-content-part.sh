#!/usr/bin/env bash
# 47-never-blind-content-part.sh — a content part that names an attachment this server cannot
# carry is refused by name; it is never decoded into nothing and answered over.
#
# Measured 10-31 on this host against a live `serve` driving the scripted engine (no weights, no
# Metal, so this is a wire-tier verdict and claims nothing about a model), one request per shape:
#   audio_url    + a real 1.6 kHz wav, inline as a data: URL → 503 "Transcription unavailable…"
#                                                         the part was seen, and the refusal
#                                                         names the cause and the fix
#   input_audio  + the identical bytes                    → 200 and a confident answer
#   file / unknown type / image_url with no payload object → 200 and a confident answer
#   image_url naming a path that is not there             → 400 media_unresolvable
# The last line is the standard this route already meets: a media *reference* it cannot open is
# refused with the part type and the path named. The middle lines were the gap — OpenAI's own
# audio shape included — because the decoder had no key for them, so `ChatMedia`, `ChatAudio`,
# the tokenizer and the engine were each correct about a conversation whose payload had vanished.
#
# Why these legs:
#   1) positive control — a plain text turn still answers, so a later 400 means a refusal and not
#      a surface that stopped serving;
#   2) parity — the same bytes as `audio_url` and as `input_audio` cannot have different fates.
#      This is the regression this probe was born from, stated host-independently: whether the
#      pair is refused or heard depends on this box's speech permission, so the assertion is on
#      the pair agreeing, never on which side of that line the host sits;
#   3) refusal — every shape with no payload this server reads comes back 400, `type:
#      invalid_request_error`, `param` pointing at the offending part, and the client's own type
#      string in the message. A refusal that cannot be pointed at is a riddle;
#   4) floor — the probe counts its own verdicts, so a server that 200s everything cannot pass §3
#      and a server that 400s everything cannot pass §1.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="never-blind-content-part"

SCRIPT_FILE="$(mktemp -t ocoreai-script-XXXXXX).json"
BODY_DIR="$(mktemp -d)"
probe_atexit 'rm -f "$SCRIPT_FILE"; rm -rf "$BODY_DIR"'

printf '%s\n' '{"segments": ["OK-ANSWER"], "finishReason": "eos", "promptTokens": 7, "generatedTokens": 3}' \
  > "$SCRIPT_FILE"
export OCOREAI_SCRIPTED_ENGINE="$SCRIPT_FILE"

# One wav, base64-encoded once, reused by both shapes in §2 — if the two bodies carried different
# bytes, a difference in fate would mean nothing.
python3 - "$BODY_DIR" <<'PY'
import base64, io, json, os, struct, sys, wave
out = sys.argv[1]
buf = io.BytesIO()
w = wave.open(buf, 'wb')
w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(struct.pack('<' + 'h' * 800, *([0] * 800)))
w.close()
data = base64.b64encode(buf.getvalue()).decode()
assert len(data) > 1000, "fixture wav is empty — every later 'heard it' claim would be a lie"

def body(name, parts):
    with open(os.path.join(out, name + '.json'), 'w') as fh:
        json.dump({'model': 'scripted-model',
                   'messages': [{'role': 'user', 'content': parts}]}, fh)

body('text_only', [{'type': 'text', 'text': 'Reply with OK.'}])
body('audio_url', [{'type': 'text', 'text': 'What did I say?'},
                   {'type': 'audio_url', 'audio_url': {'url': 'data:audio/wav;base64,' + data}}])
body('input_audio', [{'type': 'text', 'text': 'What did I say?'},
                     {'type': 'input_audio', 'input_audio': {'data': data, 'format': 'wav'}}])
body('image_ok', [{'type': 'text', 'text': 'What colour is this?'},
                  {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,iVBORw0KGgo='}}])
UNCARRIED = {
    'file': [{'type': 'text', 'text': 'summarise'}, {'type': 'file',
             'file': {'filename': 'a.pdf', 'file_data': 'AAAA'}}],
    'unknown': [{'type': 'text', 'text': 'hi'}, {'type': 'mystery_part'}],
    'image_empty': [{'type': 'text', 'text': 'look'}, {'type': 'image_url'}],
    'audio_empty': [{'type': 'text', 'text': 'listen'},
                    {'type': 'audio_url', 'audio_url': {'url': ''}}],
    # A named attachment with no container name: guessing `wav` would invent a format the
    # client never sent, so this carries nothing and must say so.
    'audio_noformat': [{'type': 'text', 'text': 'listen'},
                       {'type': 'input_audio', 'input_audio': {'data': 'AAAA'}}],
}
for name, parts in UNCARRIED.items():
    body(name, parts)
print('bodies=%d wav_base64_bytes=%d' % (len(os.listdir(out)), len(data)), file=sys.stderr)
PY

probe_boot

post_body() {  # post_body <file>  → PROBE_STATUS / PROBE_BODY from the wire
  local body
  body="$(cat "$BODY_DIR/$1.json")"
  probe_api POST /v1/chat/completions "$body"
}

probe_section "1) positive control — a plain text turn is answered, so a later 400 is a refusal"
post_body text_only
if [ "$PROBE_STATUS" = "200" ] && printf '%s' "$PROBE_BODY" | grep -q 'OK-ANSWER'; then
  probe_ok "text-only turn 200 with its answer — the surface serves, so §3's 400s are verdicts"
else
  probe_fail "text-only turn returned HTTP $PROBE_STATUS — nothing below this line can be read" \
    " as a carriage verdict ($(printf '%s' "$PROBE_BODY" | head -c 160))"
fi

probe_section "2) parity — the same bytes cannot have different fates by spelling"
post_body audio_url
OURS_STATUS="$PROBE_STATUS"; OURS_BODY="$PROBE_BODY"
post_body input_audio
SPEC_STATUS="$PROBE_STATUS"; SPEC_BODY="$PROBE_BODY"
OURS_CODE="$(probe_json "$OURS_BODY" 'error.error_code')"
SPEC_CODE="$(probe_json "$SPEC_BODY" 'error.error_code')"
OURS_MESSAGE="$(probe_json "$OURS_BODY" 'error.message')"
if [ "$OURS_STATUS" = "$SPEC_STATUS" ] && [ "$OURS_CODE" = "$SPEC_CODE" ]; then
  probe_ok "audio_url and input_audio with identical bytes both got HTTP $OURS_STATUS" \
    "${OURS_CODE:+ ($OURS_CODE)} — the OpenAI shape reaches the same audio path, whatever this" \
    " box's speech permission decides"
else
  probe_fail "same bytes, different fates: audio_url → HTTP $OURS_STATUS${OURS_CODE:+ $OURS_CODE}," \
    " input_audio → HTTP $SPEC_STATUS${SPEC_CODE:+ $SPEC_CODE} — one spelling is carried and the" \
    " other is dropped, which is the blind-200 this probe exists to catch"
fi
if [ "$SPEC_STATUS" = "200" ]; then
  probe_note "§2 ended 200 here, which is honest only because both spellings were heard into" \
    " text; on a box without that permission the same pair must refuse together, and §3 is what" \
    " proves the refusal path is wired rather than absent"
fi
case "$OURS_MESSAGE" in
  *"names an attachment this server cannot carry"*)
    probe_fail "audio_url with real bytes was refused by the carriage rule — a part this server" \
      " does have a shape for must reach the audio path, not the refusal" ;;
  *)
    probe_ok "audio_url with real bytes was not refused as un-carriable — the carriage rule does" \
      " not swallow the shape it was written for" ;;
esac

probe_section "3) refusal — every shape with no payload this server reads is named, not dropped"
REFUSED=0
for shape in file unknown image_empty audio_empty audio_noformat; do
  case "$shape" in
    file) expect='file' ;;
    unknown) expect='mystery_part' ;;
    image_empty) expect='image_url' ;;
    audio_empty) expect='audio_url' ;;
    audio_noformat) expect='input_audio' ;;
  esac
  post_body "$shape"
  TYPE="$(probe_json "$PROBE_BODY" 'error.type')"
  PARAM="$(probe_json "$PROBE_BODY" 'error.param')"
  MESSAGE="$(probe_json "$PROBE_BODY" 'error.message')"
  if [ "$PROBE_STATUS" != "400" ]; then
    probe_fail "$shape (type '$expect') → HTTP $PROBE_STATUS with $(printf '%s' "$PROBE_BODY" \
      | head -c 120) — the part was accepted, so the turn answers over an attachment nobody read"
    continue
  fi
  if [ "$TYPE" != "invalid_request_error" ]; then
    probe_fail "$shape → 400 but type='${TYPE:-<absent>}' — both specs name invalid_request_error" \
      " for a 400 and an SDK branches on it"
    continue
  fi
  case "$PARAM" in
    messages\[*"content["*"].type") ;;
    *) probe_fail "$shape → 400 with param='${PARAM:-<absent>}' — a 400 on a multi-field body is" \
        " only actionable if the client learns which part to fix"; continue ;;
  esac
  case "$MESSAGE" in
    *"$expect"*) ;;
    *) probe_fail "$shape → message does not name the type the client sent ('$expect')"; continue ;;
  esac
  REFUSED=$(( REFUSED + 1 ))
  probe_ok "$shape → 400 invalid_request_error, param $PARAM, message names '$expect' and the" \
    " shapes this server reads"
done

probe_section "4) controls and floor — the rule fires on what it is about, and the scan saw subjects"
post_body image_ok
if [ "$PROBE_STATUS" = "400" ] && printf '%s' "$PROBE_BODY" | grep -q 'cannot carry'; then
  probe_fail "an image_url with a real data: URL was refused as un-carriable — the rule is firing" \
    " on parts it can carry, which costs a working multimodal request"
else
  probe_ok "image_url with inline bytes was not refused by the carriage rule (HTTP $PROBE_STATUS)" \
    " — the rule fires on missing payloads, not on media"
fi
if [ "$REFUSED" -ge 5 ]; then
  probe_ok "$REFUSED/5 un-carriable shapes refused by name — §3 has subjects, so its green is not" \
    " a scan that matched nothing"
else
  probe_fail "only $REFUSED/5 un-carriable shapes were refused by name — the leg that counts these" \
    " is itself not measuring what it claims"
fi

probe_summary "$PROBE_NAME"
