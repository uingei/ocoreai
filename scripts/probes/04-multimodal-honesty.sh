#!/usr/bin/env bash
# 04-multimodal-honesty.sh — does "能看 / 能听 / 能说" survive contact with the OS?
#
# Why (AGENTS.md invariant 2 — the surface never claims more than the engine delivered):
# `POST /v1/multimodal/status` is indexed as "permission + device status" and published
# three UI toggles. A toggle is intent, not a fact. Measured on this host (10-14, same
# APIs read out-of-process): camera `.denied`, microphone `.denied`, 0 capture devices
# visible, speech recognition `.denied`, 180 installed voices — i.e. every "can see / can
# hear" reading a client could have taken from that payload was unsupported, while the box
# genuinely can talk. Separately, the microphone capture leg answered `success: true` with
# `dataURL: null`, so a client that trusted `success` wrote an empty sample.
#
# MultimodalStatusHonestyTests pins the derivation at compile time. This probe pins the
# running server: the payload shape, the closed vocabularies, the derive-success-from-bytes
# rule, and the one claim none of the unit tests can make — that a vision model actually
# answers an image posted over the wire.
#
# Asserted:
#   • /v1/multimodal/status answers fast (a status read must not open a TCC dialog — a
#     prompt would block here until a human answered it), returns all five channel verdicts
#     and four permission fields, every one inside its documented vocabulary;
#   • no channel is `ready` without the facts that would make it ready (permission
#     authorized + device/voice count ≥ 1), every non-ready channel states why in
#     `limitations`, and an unmeasurable count is omitted rather than sent as `0` or
#     `null` ("none found" and "cannot tell" are different claims);
#   • screen `ready` additionally requires `screenDelivery=captured`, and a failed
#     delivery surfaces as `blocked` carrying the framework's own words — measured 10-15,
#     the grant was on and a display enumerated while `SCScreenshotManager` refused, yet
#     `screenStatus` said `ready`;
#   • no capture leg (camera / microphone / screen) returns `success: true` with a null
#     `dataURL`;
#   • `/v1/multimodal/speak` refuses whitespace-only text instead of reporting success for
#     a turn that synthesizes nothing;
#   • the endpoint index describes the status payload honestly (it must name permissions);
#   • if a `vlm:true` model is loaded, an inline base64 PNG posted to
#     /v1/chat/completions gets a non-empty answer — the only end-to-end proof of "能看"
#     available headlessly (audible TTS is not verifiable this way, and is NOTEd, not
#     claimed).
#
# Run: bash scripts/probes/04-multimodal-honesty.sh
PROBE_NAME="04-multimodal-honesty"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# Counts every verdict this probe actually issued, so a scan that stopped matching cannot
# pass by producing nothing (the vacuous-pass family).
CHECKS=0
tally() { CHECKS=$(( CHECKS + $(printf '%s\n' "$1" | grep -cE '^(OK|FAIL)\|') )); }
emit() {
  while IFS='|' read -r kind msg; do
    [ -z "$kind" ] && continue
    case "$kind" in
      OK)   probe_ok "$msg" ;;
      FAIL) probe_fail "$msg" ;;
      *)    probe_note "$msg" ;;
    esac
  done <<EOF
$1
EOF
}

# Accumulate one verdict line into a named variable. The separator matters: without it the
# whole block arrives at `emit` as a single line and a section reporting three legs issues
# one verdict (measured on this probe's first run).
push() {
  printf -v "$1" '%s%s\n' "${!1}" "$2"
}

now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

probe_boot

# ── 1. status payload ─────────────────────────────────────────────────────────
probe_section "POST /v1/multimodal/status — measured facts, not just toggles"
START_MS=$(now_ms)
probe_api POST /v1/multimodal/status '{}'
ELAPSED_MS=$(( $(now_ms) - START_MS ))
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "POST /v1/multimodal/status -> ${PROBE_STATUS:-no response}"
  probe_summary "$PROBE_NAME"
fi
CHECKS=$(( CHECKS + 1 ))
# A status read that opens a modal dialog would block here until a human answered it.
# 10s is generous for enumeration (voice list + two discovery sessions) and still far
# below any plausible human response time.
if [ "$ELAPSED_MS" -lt 10000 ]; then
  probe_ok "status answered in ${ELAPSED_MS}ms — it reads permission state, it does not ask for it"
else
  probe_fail "status took ${ELAPSED_MS}ms — a status path that blocks this long is almost certainly waiting on a TCC dialog"
fi

STATUS_VERDICTS="$(python3 - "$PROBE_BODY" <<'PY'
import json, sys

PERMISSIONS = {"authorized", "denied", "restricted", "notDetermined", "notGranted",
               "unsupported", "unknown"}
VERDICTS = {"ready", "blocked", "unknown", "unsupported"}
PERM_FIELDS = ["cameraPermission", "microphonePermission", "speechRecognitionPermission",
               "screenPermission"]
VERDICT_FIELDS = ["cameraStatus", "microphoneStatus", "speakerStatus", "screenStatus",
                  "transcriptionStatus"]
# verdict field -> (permission field, count field or None)
EVIDENCE = {
    "cameraStatus": ("cameraPermission", "cameraDeviceCount"),
    "microphoneStatus": ("microphonePermission", "microphoneDeviceCount"),
    # TTS asks nothing of TCC: the only evidence it needs is an installed voice.
    "speakerStatus": (None, "speechVoiceCount"),
    "screenStatus": ("screenPermission", None),
    "transcriptionStatus": ("speechRecognitionPermission", None),
}


out = []
try:
    doc = json.loads(sys.argv[1])
except Exception as exc:
    print("FAIL|status payload is not JSON (%s)" % exc)
    sys.exit(0)

for f in ["cameraEnabled", "microphoneEnabled", "speakerEnabled", "screenCaptureEnabled"]:
    v = doc.get(f, "<absent>")
    out.append(("OK|%s=%s" % (f, v)) if isinstance(v, bool) else ("FAIL|%s is %r, not a bool" % (f, v)))

for f in PERM_FIELDS:
    v = doc.get(f, "<absent>")
    out.append(("OK|%s=%s" % (f, v)) if v in PERMISSIONS
               else ("FAIL|%s=%r is outside the documented permission vocabulary" % (f, v)))

for f in VERDICT_FIELDS:
    v = doc.get(f, "<absent>")
    out.append(("OK|%s=%s" % (f, v)) if v in VERDICTS
               else ("FAIL|%s=%r is outside the documented verdict vocabulary" % (f, v)))

# `ready` needs evidence. This is the invariant: no verdict may outrun the facts.
for field, (perm_field, count_field) in EVIDENCE.items():
    if doc.get(field) != "ready":
        continue
    if perm_field is not None and doc.get(perm_field) != "authorized":
        out.append("FAIL|%s=ready while %s=%r — a verdict cannot outrun its permission"
                   % (field, perm_field, doc.get(perm_field)))
        continue
    if count_field is not None and not (isinstance(doc.get(count_field), int) and doc[count_field] >= 1):
        out.append("FAIL|%s=ready without evidence in %s (%r)" % (field, count_field, doc.get(count_field)))
        continue
    evidence = []
    if perm_field is not None:
        evidence.append("%s=authorized" % perm_field)
    if count_field is not None:
        evidence.append("%s=%s" % (count_field, doc.get(count_field)))
    out.append("OK|%s=ready, backed by %s" % (field, " + ".join(evidence) or "no stated evidence"))

# Screen carries a second, stronger requirement than the other channels: the grant says the
# user allowed it, only a frame says it works. Measured 10-15 on the shipping host —
# authorized + a display enumerated + SCScreenshotManager refusing — so `ready` without
# `screenDelivery=captured` is the surface outrunning the engine, which is what this probe
# exists to catch.
DELIVERY = {"notAttempted", "captured", "failed"}
screen_delivery = doc.get("screenDelivery", "<absent>")
if screen_delivery not in DELIVERY:
    out.append("FAIL|screenDelivery=%r is outside the documented delivery vocabulary"
               % screen_delivery)
if doc.get("screenStatus") == "ready":
    if screen_delivery != "captured":
        out.append("FAIL|screenStatus=ready while screenDelivery=%r — a permission is not a "
                   "captured frame" % screen_delivery)
    else:
        out.append("OK|screenStatus=ready, backed by a delivered frame in %sms"
                   % doc.get("screenDeliveryLatencyMs"))
if screen_delivery == "failed":
    if doc.get("screenStatus") != "blocked":
        out.append("FAIL|screenDelivery=failed but screenStatus=%r — a measured capture "
                   "failure must not leave the verdict at `ready` or `unknown`"
                   % doc.get("screenStatus"))
    if not doc.get("screenDeliveryError"):
        out.append("FAIL|screenDelivery=failed with no screenDeliveryError — a refusal that "
                   "names no reason is the pattern this probe was written against")
    else:
        out.append("OK|screen refusal carries its reason: %s" % doc.get("screenDeliveryError"))

# Unknown is not zero: an unmeasurable count must be absent, never 0 or null.
for f in ["cameraDeviceCount", "microphoneDeviceCount", "speechVoiceCount"]:
    if f not in doc:
        out.append("NOTE|%s omitted (not enumerable here — reported as unknown, not 0)" % f)
    elif doc[f] is None:
        out.append("FAIL|%s is explicit null — the convention is to omit the key" % f)
    elif not isinstance(doc[f], int) or doc[f] < 0:
        out.append("FAIL|%s=%r is not a non-negative count" % (f, doc[f]))
    else:
        out.append("OK|%s=%s measured" % (f, doc[f]))

limits = doc.get("limitations")
if not isinstance(limits, list):
    out.append("FAIL|limitations is %r — every non-ready channel must name its reason" % (limits,))
else:
    out.append("OK|limitations is a list of %d line(s)" % len(limits))
    channels = {"cameraStatus": "camera", "microphoneStatus": "microphone",
                "speakerStatus": "speaker", "screenStatus": "screen",
                "transcriptionStatus": "transcription"}
    for field, channel in channels.items():
        verdict = doc.get(field)
        if verdict in (None, "ready"):
            continue
        if not any(str(line).startswith(channel + ": ") for line in limits):
            out.append("FAIL|%s=%s but limitations has no '%s: ' line" % (field, verdict, channel))
        else:
            line = next(str(l) for l in limits if str(l).startswith(channel + ": "))
            out.append("OK|%s explained: %s" % (field, line))

for line in out:
    print(line)
PY
)"
emit "$STATUS_VERDICTS"
tally "$STATUS_VERDICTS"
printf '        measured voice/device inventory: %s\n' \
  "$(printf '%s\n' "$STATUS_VERDICTS" | grep '^OK|' | grep -cE 'DeviceCount=|VoiceCount=') count field(s) reported"

CAMERA_PERMISSION="$(probe_json "$PROBE_BODY" 'cameraPermission')"
MIC_PERMISSION="$(probe_json "$PROBE_BODY" 'microphonePermission')"
VOICE_COUNT="$(probe_json "$PROBE_BODY" 'speechVoiceCount')"
printf '        host reality: camera=%s microphone=%s voices=%s\n' \
  "${CAMERA_PERMISSION:-?}" "${MIC_PERMISSION:-?}" "${VOICE_COUNT:-?}"

# ── 2. endpoint index describes the payload ───────────────────────────────────
probe_section "GET /v1/capabilities — does the index describe what status actually publishes?"
probe_api GET /v1/capabilities
INDEX_NOTES="$(python3 - "$PROBE_BODY" <<'PY'
import json, sys
try:
    doc = json.loads(sys.argv[1])
except Exception:
    print("FAIL|/v1/capabilities is not JSON")
    sys.exit(0)
eps = doc.get("endpoints") or []
if not isinstance(eps, list):
    print("FAIL|endpoints is %r" % (eps,))
    sys.exit(0)
wanted = {"POST /v1/multimodal/status": ("permission", "ready"),
          "POST /v1/multimodal/capture": ("success",),
          "POST /v1/multimodal/speak": ("voice",)}
found = {}
for ep in eps:
    key = "%s %s" % (ep.get("method", ""), ep.get("path", ""))
    if key in wanted:
        found[key] = str(ep.get("note", ""))
for key, needles in wanted.items():
    note = found.get(key)
    if note is None:
        print("FAIL|%s is not in the published endpoint index" % key)
        continue
    missing = [n for n in needles if n not in note.lower()]
    if missing:
        print("FAIL|%s note does not name %s — it says: %s" % (key, ", ".join(missing), note))
    else:
        print("OK|%s note names what the payload carries: %s" % (key, note))
PY
)"
emit "$INDEX_NOTES"
tally "$INDEX_NOTES"

# ── 3. capture legs: success means bytes, and never a modal ───────────────────
probe_section "POST /v1/multimodal/capture — success:true only when bytes came back"
# Delivery may need a grant; it may not STOP on one. Measured 10-14, before the permission
# gate: the camera leg parked for ≥45s behind AVCaptureDevice.requestAccess, waiting on a
# dialog a socket client cannot answer. 15s is far above a real capture and far below any
# plausible human response, so a leg that exceeds it is blocking on a prompt again.
CAPTURE_CEILING_MS="${OCOREAI_PROBE_CAPTURE_CEILING_MS:-15000}"
export OCOREAI_PROBE_CURL_TIMEOUT="${OCOREAI_PROBE_CAPTURE_TIMEOUT:-45}"
CAPTURE_VERDICTS=""
SCREEN_LEG_VERDICT="no-answer"
SCREEN_LEG_MS=0
SCREEN_LEG_MSG=""
for kind in camera microphone screen; do
  leg_start="$(now_ms)"
  probe_api POST /v1/multimodal/capture "{\"type\":\"${kind}\"}"
  leg_ms=$(( $(now_ms) - leg_start ))
  status="${PROBE_STATUS:-000}"
  if [ "$status" = "000" ]; then
    push CAPTURE_VERDICTS "FAIL|${kind} leg answered nothing in ${leg_ms}ms — a capture request that blocks this long is parked on a TCC dialog the client cannot answer; the gate must refuse instead"
    continue
  fi
  if [ "$status" != "200" ]; then
    push CAPTURE_VERDICTS "FAIL|${kind} capture -> ${status}: $(probe_json "$PROBE_BODY" 'error.message')"
    continue
  fi
  dataURL="$(probe_json "$PROBE_BODY" 'dataURL')"
  success="$(probe_json "$PROBE_BODY" 'success')"
  message="$(probe_json "$PROBE_BODY" 'message')"
  if [ "$kind" = "screen" ]; then
    SCREEN_LEG_MS=$(( $(now_ms) - leg_start ))
    SCREEN_LEG_MSG="$message"
    if [ -n "$dataURL" ]; then
      SCREEN_LEG_VERDICT="delivered"
    else
      SCREEN_LEG_VERDICT="refused"
    fi
  fi
  if [ "$success" = "true" ] && [ -z "$dataURL" ]; then
    push CAPTURE_VERDICTS "FAIL|${kind} reported success:true with dataURL null — \"it worked, here are no bytes\" (${message})"
  elif [ "$leg_ms" -ge "$CAPTURE_CEILING_MS" ]; then
    push CAPTURE_VERDICTS "FAIL|${kind} leg answered only after ${leg_ms}ms (ceiling ${CAPTURE_CEILING_MS}ms) — something before the capture is blocking, most likely a permission prompt"
  elif [ -n "$dataURL" ]; then
    push CAPTURE_VERDICTS "OK|${kind} delivered ${#dataURL} chars of payload in ${leg_ms}ms (success=${success})"
  else
    push CAPTURE_VERDICTS "OK|${kind} refused honestly in ${leg_ms}ms: success=${success} — ${message}"
  fi
done
emit "$CAPTURE_VERDICTS"
tally "$CAPTURE_VERDICTS"
unset OCOREAI_PROBE_CURL_TIMEOUT

# ── 3b. the verdict must agree with the capture it just watched ───────────────
probe_section "POST /v1/multimodal/status again — screen verdict agrees with the leg above"
# This is the pair no unit test can make: the same process, seconds apart, answering
# "is the screen ready?" and then actually trying to capture it. Before the delivery axis
# existed these two disagreed by construction on this host — status published `ready` from
# CGPreflightScreenCaptureAccess while the leg below returned no frame.
probe_api POST /v1/multimodal/status '{}'
AGREE_VERDICTS="$(python3 - "$PROBE_BODY" "$SCREEN_LEG_VERDICT" "$SCREEN_LEG_MS" <<'PY'
import json, sys

doc = json.loads(sys.argv[1])
leg, leg_ms = sys.argv[2], sys.argv[3]
verdict = doc.get("screenStatus")
delivery = doc.get("screenDelivery")
error = doc.get("screenDeliveryError")
limits = doc.get("limitations") or []
screen_lines = [str(x) for x in limits if str(x).startswith("screen: ")]

out = ["INFO|screen leg was %s in %sms" % (leg, leg_ms)]
if leg == "delivered":
    if delivery == "captured":
        out.append("OK|a delivered leg is recorded as screenDelivery=captured")
    else:
        out.append("FAIL|the screen leg returned bytes but screenDelivery=%r — the success "
                   "was not recorded, so the next status call will under-report" % delivery)
elif leg == "refused":
    if verdict == "ready":
        out.append("FAIL|screenStatus=ready immediately after a refused capture — the exact "
                   "claim this probe was written to catch")
    elif verdict == "blocked":
        out.append("OK|the refusal moved the verdict: screenStatus=blocked")
    else:
        out.append("FAIL|screenStatus=%r after a refused capture — a measured failure must "
                   "surface as blocked, not %s" % (verdict, verdict))
    if delivery == "failed":
        out.append("OK|screenDelivery=failed recorded by the leg itself")
    else:
        out.append("FAIL|screenDelivery=%r after a refused leg — nothing recorded the failure"
                   % delivery)
    if error:
        out.append("OK|reason carried to the verdict: %s" % error)
    else:
        out.append("FAIL|no screenDeliveryError after a refused leg")
    if screen_lines:
        out.append("OK|limitations explains it: %s" % screen_lines[0])
    else:
        out.append("FAIL|screen is not ready but limitations has no 'screen: ' line")
else:
    out.append("NOTE|screen leg never answered — nothing to cross-check the verdict against")

for line in out:
    print(line)
PY
)"
emit "$AGREE_VERDICTS"
tally "$AGREE_VERDICTS"

# ── 4. speak refuses nothing-to-say ───────────────────────────────────────────
probe_section "POST /v1/multimodal/speak — no success for a turn that says nothing"
SPEAK_VERDICTS=""
for body in '{"text":""}' '{"text":"   \n  "}' '{"text":"\t"}'; do
  speak_start="$(now_ms)"
  probe_api POST /v1/multimodal/speak "$body"
  speak_ms=$(( $(now_ms) - speak_start ))
  if [ "${PROBE_STATUS:-}" != "200" ]; then
    push SPEAK_VERDICTS "FAIL|speak ${body} -> ${PROBE_STATUS:-no response}"
    continue
  fi
  success="$(probe_json "$PROBE_BODY" 'success')"
  message="$(probe_json "$PROBE_BODY" 'message')"
  if [ "$success" = "true" ]; then
    push SPEAK_VERDICTS "FAIL|empty text answered success:true — nothing was queued to synthesize"
  elif [ "$speak_ms" -ge 5000 ]; then
    push SPEAK_VERDICTS "FAIL|empty-text refusal took ${speak_ms}ms — the check should not reach the synthesizer"
  else
    push SPEAK_VERDICTS "OK|empty text refused in ${speak_ms}ms: success=false — ${message}"
  fi
done
emit "$SPEAK_VERDICTS"
tally "$SPEAK_VERDICTS"
probe_note "audible output is deliberately not exercised: a headless probe cannot hear, so"
probe_note "'the speaker produced sound' stays unclaimed here — voices=${VOICE_COUNT:-?} is the measured ceiling on that channel"
# ── 5. 能看: a real image through the wire ────────────────────────────────────
probe_section "Vision delivery — an inline PNG posted to /v1/chat/completions"
probe_api GET /v1/models
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "GET /v1/models -> ${PROBE_STATUS:-no response} — cannot look for a vision model"
  CHECKS=$(( CHECKS + 1 ))
fi
# Prefer a model already reported ready; loading one is the engine's call, not this probe's.
VLM_MODEL="$(python3 - "$PROBE_BODY" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1]).get("data", [])
except Exception:
    sys.exit(0)
for want_ready in (True, False):
    for m in data:
        ready = str(m.get("state", "ready")) == "ready"
        if m.get("vlm") is True and (ready or not want_ready):
            print(m.get("id", ""))
            sys.exit(0)
PY
)"
if [ -z "$VLM_MODEL" ]; then
  probe_note "no model on this host publishes vlm:true — the see-path cannot be proven here"
  printf '        %s\n' "$(python3 - "$PROBE_BODY" <<'PY'
import json, sys
rows = json.loads(sys.argv[1]).get("data", [])
print("published rows: " + (", ".join("%s(vlm=%s)" % (m.get("id"), m.get("vlm", "<absent>")) for m in rows) or "none"))
PY
)"
else
  # 8x8 solid-red PNG, built with no external asset so the run is reproducible anywhere.
  PNG_B64="$(python3 - <<'PY'
import base64, struct, zlib
w = h = 8
raw = b"".join(b"\x00" + b"\xff\x00\x00" * w for _ in range(h))
def chunk(tag, payload):
    return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9))
       + chunk(b"IEND", b""))
print(base64.b64encode(png).decode())
PY
)"
  BODY="$(python3 - "$VLM_MODEL" "$PROBE_NAME" "$PNG_B64" <<'PY'
import json, sys
model, session_id, png = sys.argv[1:4]
print(json.dumps({
    "model": model,
    "session_id": session_id,
    "max_tokens": 24,
    "temperature": 0.0,
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "What single colour fills this image? Answer with the colour name only."},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64," + png}},
        ],
    }],
}))
PY
)"
  probe_chat "$PROBE_NAME" "$BODY"
  if [ "${PROBE_STATUS:-}" != "200" ]; then
    probe_fail "vision turn to ${VLM_MODEL} -> ${PROBE_STATUS:-no response}: $(probe_json "$PROBE_BODY" 'error.message')"
    CHECKS=$(( CHECKS + 1 ))
  else
    ANSWER="$(python3 - "$PROBE_BODY" <<'PY'
import json, sys
try:
    doc = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
choices = doc.get("choices") or []
if not choices:
    sys.exit(0)
content = (choices[0].get("message") or {}).get("content")
if isinstance(content, str):
    print(content.strip())
elif isinstance(content, list):
    print(" ".join(str(p.get("text", "")) for p in content).strip())
PY
)"
    MODEL_REPORTED="$(probe_json "$PROBE_BODY" 'model')"
    if [ -n "$ANSWER" ]; then
      probe_ok "${VLM_MODEL} answered an inline PNG over the wire in ${PROBE_ELAPSED_MS}ms (model=${MODEL_REPORTED:-?})"
      CHECKS=$(( CHECKS + 1 ))
      printf '        answer: %s\n' "$(printf '%s' "$ANSWER" | head -c 120)"
      probe_note "the bar is a non-empty answer, not the right colour — a ≤2B open model naming"
      probe_note "red is not something this probe should gate the product on (see model_fidelity)"
    else
      probe_fail "${VLM_MODEL} accepted the image but returned empty content — 能看 is claimed, not delivered"
      CHECKS=$(( CHECKS + 1 ))
    fi
  fi
fi

# ── 6. premise floor ──────────────────────────────────────────────────────────
# Status shape (4 toggles + 4 permissions + 5 verdicts + counts + limitations) plus the
# index notes plus three capture legs plus three speak refusals plus the screen delivery
# evidence and its post-capture cross-check is ~32 verdicts. 22 is far under that and far
# above zero: a payload that stopped carrying facts, or an analysis that stopped matching,
# fails instead of passing vacuously.
if [ "$CHECKS" -ge 22 ]; then
  probe_ok "premise floor: ${CHECKS} verdicts issued by this run"
else
  probe_fail "only ${CHECKS} verdicts issued (< 22) — the payload shape or this probe's scan broke, so the run proves nothing"
fi

probe_summary "$PROBE_NAME"
