#!/usr/bin/env bash
# 17-video-unpooled-lane.sh — a video turn on a server with no session pool must still earn
# the `video_input=delivered` claim.
#
# ### Why (AGENTS.md invariant 2 — the direction every existing gate missed)
# Probe 08 measures video on the normal lane: the server boots with a session pool, the turn
# lands on a pooled ChatSession, and the disclosure follows. The record, though, lived
# *inside* the pooled release — `releasePoolSlotWithAssistant` opens with
# `if let pool … , let pooled …`, and that whole block is a no-op when there is no pool.
# Two lanes run without one:
#
#   • the degraded lane — HardwareRouter decides `.cpu` under memory pressure and
#     EngineInference sets `poolRef = nil` (the device does not actually change; what the
#     lane loses is prefix-cache reuse); nobody can schedule that on a 128 GB box, and
#   • a pool-disabled engine — `sessionPool = nil` when the config carries no pool.
#
# Both lanes still hand every frame to the processor: the model answers "Red" and
# prompt_tokens grows by the frames' tokens. So the client's answer was correct while the
# surface it consults to choose a model said `not_observed` — invariant 2 broken in the
# direction of silence, invisible to a suite that only ever exercised the pooled lane.
#
# ### How the lane is reached on demand, and how this probe proves it got there
# `OCOREAI_SESSION_POOL=0` (``SessionPoolPolicy``) starts the server without a pool. The
# premise is floored before any measurement, two ways: the boot log must report the pool
# disabled *and* name the variable that disabled it, and a two-turn conversation on the wire
# must show nothing was reused (`cached_tokens` 0/absent, no "Session pool HIT"). A gate
# that assumed the lane would also pass on a server that ignored the switch and proved
# nothing.
#
# The delivery is then measured the way probe 08 measures it — same one-word question with
# and without a red clip, and the frames count as delivered only when the answer says red
# *and* prompt_tokens jumped by tens. That pairing is what licenses asking the surface about
# video at all: `delivered` must be earned here before `/v1/models` is allowed to say it.
#
# Run: bash scripts/probes/17-video-unpooled-lane.sh
PROBE_NAME="17-video-unpooled-lane"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# Read at engine init, so it has to be exported before probe_boot.
export OCOREAI_SESSION_POOL=0

QUESTION="What single colour fills the entire frame? Answer with exactly one word."

WORK="$(mktemp -d -t ocoreai-unpooled-XXXXXX)"
export OCOREAI_MEDIA_SPOOL="$WORK/spool"
mkdir -p "$OCOREAI_MEDIA_SPOOL"
RED_CLIP="$WORK/red.mp4"

probe_section "fixture — a clip that really has frames"
probe_render_clip "$RED_CLIP" red || probe_summary "$PROBE_NAME"
RED_BYTES="$PROBE_CLIP_BYTES"
RED_URL="$(printf 'data:video/mp4;base64,%s' "$(base64 < "$RED_CLIP" | tr -d '\n')")"
probe_ok "red clip ready ($RED_BYTES bytes) — a text-only answer here would be a guess about nothing"

# body KIND SESSION — KIND: noquestion | clip
make_body() {
  python3 - "$PROBE_MODEL" "$1" "$2" "$QUESTION" "$RED_URL" <<'PY'
import json, sys
model, kind, session, question, red = sys.argv[1:6]
content = [{"type": "text", "text": question}]
if kind == "clip":
    content.append({"type": "video_url", "video_url": {"url": red}})
print(json.dumps({"model": model, "session_id": session, "max_tokens": 8,
                 "temperature": 0.0, "messages": [{"role": "user", "content": content}]}))
PY
}

# ask KIND SESSION → ASK_STATUS / ASK_TOKENS / ASK_CACHED / ASK_ANSWER / ASK_RAW
ask() {
  probe_chat "$2" "$(make_body "$1" "$2")"
  ASK_STATUS="${PROBE_STATUS:-}"
  ASK_RAW="${PROBE_BODY:-}"
  ASK_TOKENS="$(probe_json "$ASK_RAW" 'usage.prompt_tokens')"
  ASK_CACHED="$(probe_json "$ASK_RAW" 'usage.prompt_tokens_details.cached_tokens')"
  ASK_ANSWER="$(probe_json "$ASK_RAW" 'choices.0.message.content')"
}

probe_boot
probe_require_ready_model

probe_section "1. premise — this server really runs without a session pool"
if grep -q "MLXSessionPool enabled" "$PROBE_LOG"; then
  probe_fail "OCOREAI_SESSION_POOL=0 was ignored — the log says MLXSessionPool enabled, so the lane under test does not exist: $(grep -m1 'MLXSessionPool enabled' "$PROBE_LOG")"
elif grep -q "MLXSessionPool disabled" "$PROBE_LOG"; then
  if grep -q "OCOREAI_SESSION_POOL" "$PROBE_LOG"; then
    probe_ok "boot reports the pool disabled and names the switch: $(grep -m1 'MLXSessionPool disabled' "$PROBE_LOG" | sed 's/^.*MLXSessionPool/MLXSessionPool/')"
  else
    probe_fail "pool is disabled but the log does not say which switch did it — an operator cannot tell the escape hatch from the config, and this probe cannot prove its premise"
  fi
else
  probe_fail "no MLXSessionPool line in $PROBE_LOG — the engine never reported its pooling state, so this run tests nothing"
fi
if [ "$PROBE_FAIL" -gt 0 ]; then
  probe_summary "$PROBE_NAME"
fi

# Wire corroboration: two turns in one conversation, nothing reused.
POOL_SESSION="PROBE-UNPOOLED-A-$$"
ask noquestion "$POOL_SESSION"
FIRST_STATUS="$ASK_STATUS"
ask noquestion "$POOL_SESSION"
SECOND_STATUS="$ASK_STATUS"; SECOND_CACHED="$ASK_CACHED"
HITS="$(grep -c "Session pool HIT" "$PROBE_LOG" 2>/dev/null || true)"
printf '        turn 2: HTTP %s, cached_tokens=%s ; "Session pool HIT" lines: %s\n' \
  "${SECOND_STATUS:-?}" "${SECOND_CACHED:-absent}" "${HITS:-0}"
if [ "${FIRST_STATUS:-0}" != "200" ] || [ "${SECOND_STATUS:-0}" != "200" ]; then
  probe_fail "text turns on this lane failed (HTTP ${FIRST_STATUS:-?} / ${SECOND_STATUS:-?}) — the degraded lane is not serving: ${ASK_RAW:0:200}"
elif [ "${HITS:-0}" -gt 0 ] || { [ -n "$SECOND_CACHED" ] && [ "$SECOND_CACHED" != "0" ]; }; then
  probe_fail "the server reused a pooled session despite OCOREAI_SESSION_POOL=0 (cached_tokens=${SECOND_CACHED:-?}, $HITS HIT lines) — the premise of this probe is false, check SessionPoolPolicy"
else
  probe_ok "no reuse on this lane (cached_tokens=${SECOND_CACHED:-absent}, no pool HIT) — the unpooled path is really under test"
fi

probe_section "2. delivery — a video turn on the unpooled lane (model=$PROBE_MODEL)"
VIDEO_SESSION="PROBE-UNPOOLED-B-$$"
ask noquestion "$VIDEO_SESSION"
BASE_TOKENS="$ASK_TOKENS"; BASE_ANSWER="$ASK_ANSWER"
printf '        no clip -> HTTP %s, prompt_tokens=%s, answer: %s\n' "${ASK_STATUS:-?}" "${BASE_TOKENS:-?}" "${BASE_ANSWER:-}"
if [ "${ASK_STATUS:-0}" != "200" ]; then
  probe_fail "media-free baseline failed: ${ASK_RAW:0:200}"
  probe_summary "$PROBE_NAME"
fi

ask clip "$VIDEO_SESSION"
CLIP_STATUS="$ASK_STATUS"; CLIP_TOKENS="$ASK_TOKENS"; CLIP_ANSWER="$ASK_ANSWER"
printf '        red clip -> HTTP %s, prompt_tokens=%s, answer: %s\n' \
  "${CLIP_STATUS:-?}" "${CLIP_TOKENS:-?}" "${CLIP_ANSWER:-}"
if [ "${CLIP_STATUS:-0}" != "200" ]; then
  probe_fail "the video turn failed on this lane (HTTP $CLIP_STATUS): ${CLIP_RAW:0:200}"
  probe_summary "$PROBE_NAME"
fi

VIDEO_DELIVERED=0
case "$(lower "$CLIP_ANSWER")" in
  *red*)
    VIDEO_DELIVERED=1
    probe_ok "the unpooled lane saw the clip — the model said \"$CLIP_ANSWER\" for a red frame (\"$BASE_ANSWER\" without one)"
    ;;
  *)
    probe_fail "the model never named red on this lane (answer: \"$CLIP_ANSWER\") — either frames did not reach it or the answer is wrong, and neither licenses a disclosure"
    ;;
esac
if [ -n "$BASE_TOKENS" ] && [ -n "$CLIP_TOKENS" ]; then
  DELTA=$(( CLIP_TOKENS - BASE_TOKENS ))
  if [ "$DELTA" -ge 8 ]; then
    probe_ok "frames expanded into the prompt: +$DELTA tokens ($BASE_TOKENS -> $CLIP_TOKENS)"
  else
    probe_fail "adding a clip changed prompt_tokens by only $DELTA ($BASE_TOKENS -> $CLIP_TOKENS) — a real vision sequence costs hundreds; nothing here proves the frames entered the prompt"
  fi
else
  probe_fail "prompt_tokens missing on the wire — cannot check whether frames expanded into the prompt"
fi
if [ "$PROBE_FAIL" -gt 0 ]; then
  probe_summary "$PROBE_NAME"
fi

probe_section "3. disclosure — the surface must say what this lane delivered"
probe_api GET /v1/models
MODEL_VIDEO="$(python3 - "$PROBE_BODY" "$PROBE_MODEL" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("")
    sys.exit(0)
for m in d.get("data", []):
    if m.get("id") == sys.argv[2]:
        print(m.get("videoInput", ""))
        break
else:
    print("")
PY
)"
MODEL_EVIDENCE="$(python3 - "$PROBE_BODY" "$PROBE_MODEL" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("")
    sys.exit(0)
for m in d.get("data", []):
    if m.get("id") == sys.argv[2]:
        print(m.get("videoEvidence", ""))
        break
else:
    print("")
PY
)"
printf '        %s: videoInput=%s ; evidence=%s\n' "$PROBE_MODEL" "${MODEL_VIDEO:-<absent>}" "${MODEL_EVIDENCE:-<absent>}"

if [ "$MODEL_VIDEO" = "delivered" ]; then
  probe_ok "video_input=delivered survives a server with no session pool — the claim follows the delivery, not the pooling"
else
  probe_fail "this lane answered the colour of a clip it was given (+$DELTA prompt tokens), yet videoInput=${MODEL_VIDEO:-<absent>} — the regression this probe exists for: the record was inside the pooled release, which never ran"
fi
case "$MODEL_EVIDENCE" in
  *turn*part*)
    probe_ok "the claim carries its evidence: $MODEL_EVIDENCE"
    ;;
  *)
    probe_fail "videoInput=$MODEL_VIDEO with no evidence naming turns and parts — an unexplained capability statement"
    ;;
esac

probe_summary "$PROBE_NAME"
