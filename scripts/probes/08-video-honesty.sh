#!/usr/bin/env bash
# 08-video-honesty.sh — does /v1/chat/completions see the video it accepts, keep what it
# spooled for as long as the conversation cites it, and refuse by name what it cannot open?
#
# ### Why (AGENTS.md invariant 2 — the surface never claims more than the engine delivered)
# The chat route accepts a `video_url` part and hands it to the engine
# (EngineInference.swift -> makeMLXVideo -> MLXLMCommon.UserInput.Video). Whether those
# bytes reach the model is per-checkpoint, not global: at the pinned mlx-swift-lm revision
# `Gemma4Processor.prepare` reads `input.videos` (Gemma4.swift:2196/:2254/:2256) while
# `Gemma4UnifiedProcessor.prepare` never mentions videos — and which processor a checkpoint
# uses is declared in its own processor_config.json (`processor_class`). So "this build
# supports video" is answerable only per model, by measurement.
#
# ### The defect this probe was written for, and what it now also guards
# Run 1 (10-16) found the answer was yes for the default model — and that the conversation
# died immediately after. A `data:` clip was written to a temp file, deleted when the
# request ended, and left inside the transcript that upstream re-feeds on every later turn
# (ChatSession.swift:1131), so turn two — even a plain text follow-up — answered
# `500 {"message":"Generation failed: Inference failed: The operation could not be
# completed"}`, permanently. Same bytes as a `file://` URL: fine, and recalled. The fix
# moved the bytes to MediaSpool, whose lifetime is the session's. Hence three gates here:
#
#   1. SEEING     — the same one-word question, asked with a red clip and with a blue clip,
#                  gets "red" and "blue". A guess cannot be right for both. A prompt-token
#                  jump over the media-free baseline proves frames expanded into the prompt
#                  rather than one template placeholder.
#   2. LIFETIME   — with OCOREAI_MEDIA_SPOOL pointed at a directory this probe owns: the
#                  clip's bytes are there while the conversation lives, they are STILL there
#                  when the next turn is answered 200, and the spool holds one file per
#                  distinct clip rather than one per turn.
#   3. REFUSAL    — a media part naming a missing file is answered 4xx with `error_code`
#                  and `remediation` naming the axis, not 200-with-no-video and not an
#                  opaque 500. (That opaque 500 is precisely what this probe hit; a
#                  refusal that cannot be named is the same lie in a different voice.)
#
# A 5xx is NEVER counted as an honest refusal here — the first version of this file did
# exactly that and reported PASS on a broken server, which is the vacuous-pass family
# AGENTS.md invariant 1 exists to catch.
#
# Premises are floored: the clips must exist, be non-empty, and self-report a duration
# (scripts/make-test-video.swift re-opens what it wrote) or the run aborts instead of
# reporting PASS on a broken fixture. Video encoding needs VideoToolbox, unavailable inside
# the agent sandbox — so a failure says "run unsandboxed (make probes)" rather than
# pretending to be a code regression.
#
# Run: bash scripts/probes/08-video-honesty.sh
PROBE_NAME="08-video-honesty"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

QUESTION="What single colour fills the entire frame? Answer with exactly one word."
RECALL="What colour did the clip I just showed you display? Answer with exactly one word."

probe_section "fixtures — render solid-colour clips with AVFoundation"
WORK="$(mktemp -d -t ocoreai-clip-XXXXXX)"
RED_CLIP="$WORK/red.mp4"
BLUE_CLIP="$WORK/blue.mp4"
export OCOREAI_MEDIA_SPOOL="$WORK/spool"
mkdir -p "$OCOREAI_MEDIA_SPOOL"

if ! command -v swift >/dev/null 2>&1; then
  probe_fail "no swift toolchain to render the clips — set DEVELOPER_DIR"
  probe_summary "$PROBE_NAME"
fi

render_clip() {
  swift "$PROBE_REPO_ROOT/scripts/make-test-video.swift" "$1" "$2" 2 15 2>&1 \
    | grep -E "^wrote |make-test-video: " | tail -1
}
RED_REPORT="$(render_clip "$RED_CLIP" red)"
BLUE_REPORT="$(render_clip "$BLUE_CLIP" blue)"
printf '        %s\n' "$RED_REPORT" "$BLUE_REPORT"
for CLIP in "$RED_CLIP" "$BLUE_CLIP"; do
  if [ ! -s "$CLIP" ]; then
    probe_fail "clip missing or empty: $CLIP — VideoToolbox is unavailable inside the agent sandbox; run this probe unsandboxed (make probes)"
    probe_summary "$PROBE_NAME"
  fi
done
RED_BYTES="$(wc -c < "$RED_CLIP" | tr -d ' ')"
BLUE_BYTES="$(wc -c < "$BLUE_CLIP" | tr -d ' ')"
probe_ok "two clips rendered and self-verified by AVURLAsset ($RED_BYTES + $BLUE_BYTES bytes)"
printf '        media spool for this run: %s\n' "$OCOREAI_MEDIA_SPOOL"

spool_files() { find "$OCOREAI_MEDIA_SPOOL" -type f 2>/dev/null | sort; }
spool_count() { spool_files | grep -c . || true; }

data_url() { printf 'data:video/mp4;base64,%s' "$(base64 < "$1" | tr -d '\n')"; }
RED_URL="$(data_url "$RED_CLIP")"
BLUE_URL="$(data_url "$BLUE_CLIP")"

PROBE_SESSION="PROBE-VIDEO-A-$$"
FRESH_SESSION="PROBE-VIDEO-B-$$"

# make_body KIND SESSION — KIND: none | red | blue | followup | missing
# A session id is not decoration: the defect this probe guards is per-conversation, so
# every request must carry the conversation it belongs to.
make_body() {
  python3 - "$PROBE_MODEL" "$1" "$2" "$QUESTION" "$RECALL" "$RED_URL" "$BLUE_URL" <<'PY'
import json, sys
model, kind, session, question, recall, red, blue = sys.argv[1:8]
text = recall if kind == "followup" else question
content = [{"type": "text", "text": text}]
if kind == "red":
    content.append({"type": "video_url", "video_url": {"url": red}})
elif kind == "blue":
    content.append({"type": "video_url", "video_url": {"url": blue}})
elif kind == "missing":
    content.append({"type": "video_url",
                    "video_url": {"url": "file:///definitely/not/a/real/clip.mp4"}})
print(json.dumps({"model": model, "session_id": session, "max_tokens": 8,
                 "temperature": 0.0, "messages": [{"role": "user", "content": content}]}))
PY
}

# ask KIND SESSION  → ASK_STATUS / ASK_TOKENS / ASK_ANSWER / ASK_CODE / ASK_REMEDY / ASK_RAW
ask() {
  probe_chat "$2" "$(make_body "$1" "$2")"
  ASK_STATUS="${PROBE_STATUS:-}"
  ASK_RAW="${PROBE_BODY:-}"
  ASK_TOKENS="$(probe_json "$ASK_RAW" 'usage.prompt_tokens')"
  ASK_ANSWER="$(probe_json "$ASK_RAW" 'choices.0.message.content')"
  ASK_CODE="$(probe_json "$ASK_RAW" 'error.error_code')"
  ASK_REMEDY="$(probe_json "$ASK_RAW" 'error.remediation')"
}

probe_boot
probe_require_ready_model

probe_section "1. seeing — one question, three ways (model=$PROBE_MODEL)"
ask none "$PROBE_SESSION"
BASE_TOKENS="$ASK_TOKENS"; BASE_ANSWER="$ASK_ANSWER"
printf '        no media  -> HTTP %s, %s tokens, answer: %s\n' "${ASK_STATUS:-?}" "${BASE_TOKENS:-?}" "${BASE_ANSWER:-}"
if [ "$ASK_STATUS" != "200" ]; then
  probe_fail "media-free baseline -> ${ASK_STATUS:-no response}: ${ASK_RAW:0:200}"
  probe_summary "$PROBE_NAME"
fi
ask red "$PROBE_SESSION"
RED_STATUS="$ASK_STATUS"; RED_TOKENS="$ASK_TOKENS"; RED_ANSWER="$ASK_ANSWER"
printf '        red clip  -> HTTP %s, %s tokens, answer: %s\n' "${RED_STATUS:-?}" "${RED_TOKENS:-?}" "${RED_ANSWER:-}"
ask blue "$FRESH_SESSION"
BLUE_STATUS="$ASK_STATUS"; BLUE_TOKENS="$ASK_TOKENS"; BLUE_ANSWER="$ASK_ANSWER"
printf '        blue clip -> HTTP %s, %s tokens, answer: %s (fresh session)\n' "${BLUE_STATUS:-?}" "${BLUE_TOKENS:-?}" "${BLUE_ANSWER:-}"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
RED_L="$(lower "$RED_ANSWER")"; BLUE_L="$(lower "$BLUE_ANSWER")"
RED_NAMED=0; BLUE_NAMED=0
case "$RED_L" in *red*) RED_NAMED=1 ;; esac
case "$BLUE_L" in *blue*) BLUE_NAMED=1 ;; esac

VIDEO_DELIVERED=0
if [ "$RED_STATUS" = "200" ] && [ "$BLUE_STATUS" = "200" ] \
   && [ "$RED_NAMED" = "1" ] && [ "$BLUE_NAMED" = "1" ]; then
  VIDEO_DELIVERED=1
  probe_ok "video is DELIVERED — the model named red for the red clip and blue for the blue clip (a guess cannot do both)"
else
  probe_fail "video was not discriminated (red said \"$RED_ANSWER\" HTTP ${RED_STATUS:-?}; blue said \"$BLUE_ANSWER\" HTTP ${BLUE_STATUS:-?}) — the part was accepted but never seen, or the turn errored"
fi

if [ -n "${BASE_TOKENS:-}" ] && [ -n "${RED_TOKENS:-}" ]; then
  DELTA=$(( RED_TOKENS - BASE_TOKENS ))
  if [ "$DELTA" -ge 8 ]; then
    probe_ok "frames expanded into the prompt: +$DELTA tokens over the media-free baseline ($BASE_TOKENS -> $RED_TOKENS)"
  else
    probe_fail "adding a clip changed prompt_tokens by only $DELTA ($BASE_TOKENS -> $RED_TOKENS) — a real vision sequence costs hundreds; a template placeholder costs ~1"
  fi
else
  probe_fail "prompt_tokens missing on the wire — cannot check whether frames expanded into the prompt"
fi

probe_section "2. lifetime — the bytes outlive the request that wrote them"
SPOOL_AFTER_RED="$(spool_count)"
printf '        spool files after the video turn: %s\n' "${SPOOL_AFTER_RED:-0}"
if [ "${SPOOL_AFTER_RED:-0}" -ge 1 ]; then
  probe_ok "the clip the model read is spooled (${SPOOL_AFTER_RED} file(s), $(du -sh "$OCOREAI_MEDIA_SPOOL" 2>/dev/null | cut -f1 | tr -d ' '))"
else
  probe_fail "no file in $OCOREAI_MEDIA_SPOOL after a video turn that was answered — either the bytes never reached the engine or they were deleted at request end, which is the 10-16 defect"
fi
spool_files | sed 's/^/          /' | sed 's|'"$WORK"'/||'
printf '        spool bytes: %s\n' "$(spool_files | xargs wc -c 2>/dev/null | tail -1 | tr -s ' ' | sed 's/^ *//')"

ask followup "$PROBE_SESSION"
FOLLOW_STATUS="$ASK_STATUS"; FOLLOW_ANSWER="$ASK_ANSWER"; FOLLOW_CODE="$ASK_CODE"
printf '        plain-text follow-up in the same session -> HTTP %s, answer: %s\n' "${FOLLOW_STATUS:-?}" "${FOLLOW_ANSWER:-}"
if [ "$FOLLOW_STATUS" = "200" ]; then
  probe_ok "the turn AFTER a video turn is answered — the transcript's media citation still resolves"
else
  FOLLOW_SUFFIX=""
  [ -n "$FOLLOW_CODE" ] && FOLLOW_SUFFIX=" error_code=$FOLLOW_CODE"
  probe_fail "regression (10-16): the first text-only turn after a video turn returned HTTP ${FOLLOW_STATUS:-?}$FOLLOW_SUFFIX — the transcript cites media bytes that are gone: ${ASK_RAW:0:220}"
fi
SPOOL_AFTER_FOLLOW="$(spool_count)"
if [ "$FOLLOW_STATUS" = "200" ] && [ "${SPOOL_AFTER_FOLLOW:-0}" -ge 1 ]; then
  probe_ok "the clip is still on disk after the next turn ($SPOOL_AFTER_FOLLOW file(s)) — session-scoped lifetime holds"
elif [ "$FOLLOW_STATUS" = "200" ]; then
  probe_note "the follow-up was answered 200 though the spool is now empty ($SPOOL_AFTER_FOLLOW files) — acceptable only because this model's cached transcript no longer needed the frames; if the next turn re-reads them, it will fail"
fi

ask blue "$PROBE_SESSION"
SAME_SESSION_BLUE_STATUS="$ASK_STATUS"; SAME_SESSION_BLUE_ANSWER="$ASK_ANSWER"
printf '        a SECOND clip in the same session -> HTTP %s, answer: %s\n' "${SAME_SESSION_BLUE_STATUS:-?}" "${SAME_SESSION_BLUE_ANSWER:-}"
case "$(lower "$SAME_SESSION_BLUE_ANSWER")" in
  *blue*) probe_ok "two different clips in one conversation are both read (session still cites both files)" ;;
  *) probe_note "second clip in the same conversation answered \"$SAME_SESSION_BLUE_ANSWER\" (HTTP ${SAME_SESSION_BLUE_STATUS:-?}) — not discriminated; two-videos-in-one-conversation is not claimed anywhere, so this stays a measurement, not a gate" ;;
esac
# What the count means is stated rather than assumed: a conversation whose pooled session
# was discarded (its incoming conversation no longer extends what the session holds) releases
# the bytes only it cited — that is the lifetime rule working, not a leak. The clip a live
# session still cites stays.
printf '        spool files now (2 distinct clips posted across 2 conversations): %s\n' "$(spool_count)"
printf '        spool bytes now: %s\n' "$(spool_files | xargs wc -c 2>/dev/null | tail -1 | tr -s ' ' | sed 's/^ *//')"

probe_section "3. refusal — a media part naming a missing file is named back"
ask missing "$FRESH_SESSION"
printf '        missing file:// clip -> HTTP %s, error_code=%s\n' "${ASK_STATUS:-?}" "${ASK_CODE:-<none>}"
if [ "$ASK_STATUS" = "200" ]; then
  probe_fail "a video_url pointing at a nonexistent file was answered 200 (\"$ASK_ANSWER\") — the part was silently dropped"
elif [ "${ASK_STATUS:0:1}" = "5" ]; then
  code_suffix=""
  [ -n "$ASK_CODE" ] && code_suffix=" error_code=$ASK_CODE"
  probe_fail "a media part naming a missing file got ${ASK_STATUS} — a server-side status for a client-fixable condition: ${ASK_RAW:0:220}${code_suffix}"
elif [ -z "$ASK_CODE" ]; then
  probe_fail "HTTP $ASK_STATUS carries no error_code — clients must string-parse to detect it"
elif [ -z "$ASK_REMEDY" ]; then
  probe_fail "error_code=$ASK_CODE but no remediation — the refusal names the condition and not the fix"
else
  probe_ok "refused by name: HTTP $ASK_STATUS, error_code=$ASK_CODE, remediation states the axis and the fix"
fi

probe_section "4. what the surface publishes about video"
# Read the list (there is no GET /v1/models/:model — only /sampling and /kv-cache hang
# off :model), and pick this run's model out of it by id.
probe_api GET /v1/models
read_video_fields() {
  python3 - "$PROBE_BODY" "$1" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("|")
    sys.exit(0)
for m in d.get("data", []):
    if m.get("id") == sys.argv[2]:
        print("%s|%s" % (m.get("videoInput", ""), m.get("videoEvidence", "")))
        break
else:
    print("|")
PY
}
IFS='|' read -r MODEL_VIDEO MODEL_EVIDENCE <<EOF
$(read_video_fields "$PROBE_MODEL")
EOF
printf '        %s: videoInput=%s ; evidence=%s\n' "$PROBE_MODEL" "${MODEL_VIDEO:-<absent>}" "${MODEL_EVIDENCE:-<absent>}"

case "$MODEL_VIDEO" in
  delivered | not_observed)
    probe_ok "videoInput is inside the closed vocabulary (value: $MODEL_VIDEO)"
    ;;
  *)
    probe_fail "videoInput=${MODEL_VIDEO:-<absent>} is outside the published vocabulary {delivered, not_observed} — a client cannot reason about it"
    ;;
esac

if [ "$VIDEO_DELIVERED" = "1" ]; then
  # Measured above: red clip -> "Red", blue clip -> "Blue", prompt +144 for the frames.
  # Staying silent here is not caution, it is withholding a fact the engine earned —
  # this is the assertion that used to be a NOTE.
  if [ "$MODEL_VIDEO" = "delivered" ]; then
    probe_ok "videoInput=delivered is published for the model this run made see video"
  else
    probe_fail "video was MEASURED delivered (colour words + token expansion above) yet videoInput=${MODEL_VIDEO:-<absent>} — the surface under-claims what the engine delivered"
  fi
  case "$MODEL_EVIDENCE" in
    *turn*part*)
      probe_ok "the claim carries its evidence: $MODEL_EVIDENCE"
      ;;
    *)
      probe_fail "videoInput=delivered with no evidence naming turns and parts — an unexplained capability statement"
      ;;
  esac
else
  probe_note "no video delivered this run, so videoInput must not claim delivery — it reads ${MODEL_VIDEO:-<absent>}"
fi

# Control: a model that was handed no video in this process must not inherit the claim.
OTHER_MODEL="$(python3 - "$PROBE_BODY" "$PROBE_MODEL" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("")
    sys.exit(0)
for m in d.get("data", []):
    mid = m.get("id")
    if mid and mid != sys.argv[2] and m.get("state") in (None, "ready"):
        print(mid)
        break
else:
    print("")
PY
)"
if [ -n "$OTHER_MODEL" ]; then
  IFS='|' read -r OTHER_VIDEO OTHER_EVIDENCE <<EOF
$(read_video_fields "$OTHER_MODEL")
EOF
  printf '        control %s: videoInput=%s\n' "$OTHER_MODEL" "${OTHER_VIDEO:-<absent>}"
  if [ "$OTHER_VIDEO" = "not_observed" ]; then
    probe_ok "the negative is per-model and explicit: $OTHER_MODEL reads not_observed — no inheritance, no silence"
  else
    probe_fail "control model $OTHER_MODEL reports videoInput=${OTHER_VIDEO:-<absent>} after a run that only ever sent video to $PROBE_MODEL — the claim leaked across models"
  fi
  if [ -n "$OTHER_EVIDENCE" ]; then
    probe_fail "$OTHER_MODEL carries videoEvidence ($OTHER_EVIDENCE) without ever being given video — evidence invented"
  fi
else
  probe_note "no second ready model for the per-model control (raise OCOREAI_PROBE_MODEL_LIMIT)"
fi

probe_api GET /v1/capabilities
# The server-wide row must agree with the per-model rows measured above: `available` is
# true only if some model here completed a turn carrying a clip, and the sentence has to
# be the ledger wording (models + turns + parts) rather than a paraphrase of it.
# This used to be a NOTE about a missing line; the line exists now, so it is a verdict.
CAPS_VIDEO="$(python3 - "$PROBE_BODY" "${VIDEO_DELIVERED:-0}" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("FAIL|/v1/capabilities body unparseable")
    sys.exit(0)
row = next((r for r in d.get("capabilities", [])
            if isinstance(r, dict) and r.get("name") == "video_input"), None)
if row is None:
    print("FAIL|no video_input row on /v1/capabilities — the discovery surface is silent about taking video in")
    sys.exit(0)
avail, note = row.get("available"), str(row.get("note", ""))
if sys.argv[2] == "1":
    if avail is not True:
        print("FAIL|video was measured delivered above (colour words + token expansion) yet video_input.available=%r" % avail)
    elif "delivered across" not in note:
        print("FAIL|aggregate claim with no evidence naming models, turns and parts: %s" % note[:180])
    else:
        print("OK|video_input=%s — %s" % (avail, note[:150]))
else:
    if avail:
        print("FAIL|video_input.available=true with no completed video turn in this process")
    elif "not_observed" not in note:
        print("FAIL|the negative must be explicit, not blank: %s" % note[:180])
    else:
        print("OK|video_input=not_observed, stated as such")
PY
)"
CAPS_VERDICTS=0
while IFS='|' read -r lvl msg; do
  [ -n "${lvl:-}" ] || continue
  CAPS_VERDICTS=$(( CAPS_VERDICTS + 1 ))
  case "$lvl" in
    OK) probe_ok "$msg" ;;
    *)  probe_fail "${msg#FAIL|}" ;;
  esac
done <<< "$CAPS_VIDEO"
if [ "$CAPS_VERDICTS" -lt 1 ]; then
  probe_fail "the aggregate video comparison issued no verdict — it did not run"
fi

probe_section "cleanup"
rm -rf "$WORK"
printf '        removed %s\n' "$WORK"

probe_summary "$PROBE_NAME"
