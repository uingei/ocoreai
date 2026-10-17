#!/usr/bin/env bash
# 05-hearing.sh — does 能听 survive contact with the OS, over the wire?
#
# Why (AGENTS.md invariant 2 — the surface never claims more than the engine delivered):
# `POST /v1/audio/transcriptions` is where speech enters this server, and the seam in front
# of Apple's Speech framework decides its fate from three measured axes (permission read
# without prompting, a locale that resolved, and an analysis pass that completed in a CHILD
# process). Every shortcut for "is STT available?" answers yes on the host this ships from:
# `supportsOnDeviceRecognition` is true while `SpeechAnalyzer.analyzeSequence` traps with
# SIGTRAP — an error no `catch` takes, because it takes the process. So this probe asserts
# the two things unit tests cannot:
#
#   1. the REFUSALS are real and typed — a client that cannot be heard gets a 503 naming the
#      axis (permission / locale / engine) or a 400 naming what it sent wrong, never a 500,
#      never a bare "not found", and never a 200 with invented words;
#   2. when the server says it CAN hear (`verdict: ready`), it demonstrably does: an
#      utterance synthesized on this box with `say` goes in and comes back as text.
#      The verdict is held to its own word, in both directions.
#
# It also pins the shape the capability surfaces advertise: the endpoint index in
# /v1/capabilities must carry this route, and the status payload's `hearing` block must
# never claim `ready` on an unmeasured probe axis.
#
# Run: bash scripts/probes/05-hearing.sh
PROBE_NAME="05-hearing"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

CHECKS=0
ok()   { CHECKS=$(( CHECKS + 1 )); probe_ok "$*"; }
bad()  { CHECKS=$(( CHECKS + 1 )); probe_fail "$*"; }

UTTERANCE="The quick brown fox jumps over the lazy dog"
WORDS_EXPECTED=3

probe_boot

# ── 1. status: reads permission, does not ask for it ──────────────────────────
probe_section "POST /v1/multimodal/status — the measured hearing axis"
START_MS="$(python3 -c 'import time;print(int(time.time()*1000))')"
probe_api POST /v1/multimodal/status '{}'
END_MS="$(python3 -c 'import time;print(int(time.time()*1000))')"
STATUS_MS=$(( END_MS - START_MS ))
if [ "${PROBE_STATUS:-}" = "200" ]; then
  ok "status 200 in ${STATUS_MS}ms"
else
  bad "POST /v1/multimodal/status -> ${PROBE_STATUS:-no response}"
fi
if [ "$STATUS_MS" -lt 10000 ]; then
  ok "status answered in ${STATUS_MS}ms (< 10s: it reads permission, it does not open a dialog a socket cannot answer)"
else
  bad "status took ${STATUS_MS}ms — a status read that blocks is a TCC dialog on a path with no human"
fi

HEARING_LINE="$(python3 - "$PROBE_BODY" <<'PY'
import json, sys
try:
    doc = json.loads(sys.argv[1])
except Exception:
    print("PARSE-ERROR"); sys.exit(0)
h = doc.get("hearing")
if not isinstance(h, dict):
    print("ABSENT"); sys.exit(0)
print("|".join([
    str(h.get("engine", "")), str(h.get("tier_supported", "")), str(h.get("authorization", "")),
    str(h.get("probe", "")), str(h.get("verdict", "")), str(h.get("reason") or ""),
    str(h.get("locale_measured", "")), str(h.get("resolved_locale") or ""),
    str(doc.get("transcriptionStatus", "")),
]))
PY
)"
echo "        hearing: $HEARING_LINE"

PROBE_OUTCOME=""
VERDICT=""
if [ "$HEARING_LINE" = "ABSENT" ]; then
  bad "status published no \`hearing\` block — the measured axis the endpoint note points at is missing"
elif [ "$HEARING_LINE" = "PARSE-ERROR" ]; then
  bad "status payload is not JSON"
else
  ok "status carries the hearing block"
  IFS='|' read -r H_ENGINE H_TIER H_AUTH H_PROBE VERDICT H_REASON H_LOCALEMEASURED H_RESOLVED H_TXSTATUS <<EOF
$HEARING_LINE
EOF
  case "$H_AUTH" in
    authorized|denied|restricted|notDetermined|notGranted|unsupported|unknown)
      ok "authorization '$H_AUTH' is inside the closed permission vocabulary" ;;
    *) bad "authorization '$H_AUTH' left the closed vocabulary" ;;
  esac
  case "$H_PROBE" in
    notRun|ok|fault|refused|timeout|unavailable)
      ok "probe '$H_PROBE' is inside the closed probe vocabulary" ;;
    *) bad "probe '$H_PROBE' left the closed vocabulary" ;;
  esac
  case "$VERDICT" in
    ready|blocked|unknown|unsupported)
      ok "verdict '$VERDICT' is inside the closed readiness vocabulary" ;;
    *) bad "verdict '$VERDICT' left the closed vocabulary" ;;
  esac
  # The claim and the evidence have to agree, in both directions.
  if [ "$VERDICT" = "ready" ] && [ "$H_PROBE" != "ok" ]; then
    bad "verdict says ready while probe says '$H_PROBE' — an unmeasured axis cannot carry a capability claim"
  elif [ "$VERDICT" != "ready" ] && [ "$H_PROBE" = "ok" ]; then
    ok "probe ok but verdict '$VERDICT' — a stricter gate is honest, never over-claiming"
  else
    ok "verdict '$VERDICT' agrees with probe '$H_PROBE'"
  fi
  # `transcriptionStatus` is the field clients read; it must be the hearing verdict, not the
  # device-facts snapshot sitting beside it.
  if [ "$H_TXSTATUS" = "$VERDICT" ]; then
    ok "transcriptionStatus mirrors the hearing verdict ($H_TXSTATUS) — one answer per axis"
  else
    bad "transcriptionStatus '$H_TXSTATUS' != hearing verdict '$VERDICT' — two answers for one channel"
  fi
  LIMIT_LINES="$(python3 - "$PROBE_BODY" "$VERDICT" <<'PY'
import json, sys
doc = json.loads(sys.argv[1]); verdict = sys.argv[2]
lines = [l for l in (doc.get("limitations") or []) if str(l).startswith("transcription:")]
# A ready channel publishes no line; every other verdict owes exactly one.
want = 0 if verdict == "ready" else 1
print(f"{len(lines)}|{want}|{lines[0] if lines else ''}")
PY
)"
  LIM_COUNT="${LIMIT_LINES%%|*}"
  LIM_WANT="$(printf '%s' "$LIMIT_LINES" | cut -d'|' -f2)"
  LIM_TEXT="$(printf '%s' "$LIMIT_LINES" | cut -d'|' -s -f3-)"
  if [ "$LIM_COUNT" = "$LIM_WANT" ]; then
    ok "limitations carries $LIM_COUNT transcription line (expected $LIM_WANT)"
  else
    bad "limitations carries $LIM_COUNT transcription lines, expected $LIM_WANT (got: $LIM_TEXT)"
  fi
  [ -n "$LIM_TEXT" ] && echo "        why: $LIM_TEXT"
fi

# ── 2. refusal taxonomy: typed, owned, and never a 500 ───────────────────────
probe_section "refusals name the axis instead of shrugging"
check_refusal() {
  local name="$1" needle="$2" want_code="$3" want_status="$4" body="$5"
  probe_api POST /v1/audio/transcriptions "$body"
  local code msg
  code="$(probe_json "$PROBE_BODY" 'error.error_code')"
  msg="$(probe_json "$PROBE_BODY" 'error.message')"
  if [ "${PROBE_STATUS:-}" = "$want_status" ]; then
    ok "$name -> $want_status"
  else
    bad "$name -> ${PROBE_STATUS:-no response}, expected $want_status ($msg)"
  fi
  if [ -z "$want_code" ]; then
    :
  elif [ "$code" = "$want_code" ]; then
    ok "$name carries error_code=$want_code"
  else
    bad "$name error_code='$code', expected '$want_code' ($msg)"
  fi
  if [ -n "$needle" ]; then
    case "$msg" in
      *"$needle"*) ok "$name names '$needle' in the message" ;;
      *) bad "$name does not name '$needle' — a refusal that does not say what to fix is a shrug ($msg)" ;;
    esac
  fi
  CHECKS=$(( CHECKS ))
}

check_refusal "empty JSON body"          ""                      "invalid_audio" "400" '{}'
check_refusal "not base64"              ""                      "invalid_audio" "400" '{"audio":"not*base64!"}'
check_refusal "remote https url"        "url"                   "invalid_audio" "400" '{"url":"https://example.com/a.wav"}'
check_refusal "verbose_json"           "verbose_json"           "invalid_audio" "400" '{"audio":"aGVsbG8=","response_format":"verbose_json"}'
check_refusal "timestamp_granularities" "timestamp_granularities" "invalid_audio" "400" '{"audio":"aGVsbG8=","timestamp_granularities":["word"]}'

if [ "${PROBE_STATUS:-}" = "500" ]; then
  bad "a client-side mistake produced a 500 — the server took the blame for the request"
fi

# ── 3. the utterance: say it, then hear it ────────────────────────────────────
probe_section "the utterance round trip (say -> POST -> text)"
AIFF="$(mktemp -t ocoreai-hearing-XXXXXX).aiff"
# probe_atexit, not `trap`: a bare EXIT trap here would replace _lib.sh's probes_cleanup
# and leak the engine (that is what poisoned 06/07/08 on 10-17 — see _lib.sh).
probe_atexit 'rm -f "$AIFF"'
SAY_OK=0
if command -v say >/dev/null 2>&1; then
  # Default AIFF. `--data-format=LEI16@22050` was tried and refused here with
  # "Opening output file failed: fmt?" (measured 10-15) — that flag's formats are not the
  # ones an .aiff container accepts, and naming the failure beats leaving a bare NOTE.
  SAY_ERROR="$(say -o "$AIFF" -- "$UTTERANCE" 2>&1)"
  if [ -s "$AIFF" ]; then
    SAY_OK=1
    probe_note "utterance '$UTTERANCE' synthesized to $(wc -c < "$AIFF" | tr -d ' ') bytes of AIFF"
  else
    probe_note "say produced no sample (${SAY_ERROR:-no error text}) — the round trip is unverified here, and is NOTEd, not claimed"
  fi
else
  probe_note "no \`say\` on this platform — the round trip is unverified here (not claimed)"
fi

transcribe_multipart() {
  curl -sS -m "${OCOREAI_PROBE_CURL_TIMEOUT:-180}" -w $'\n%{http_code}' \
    -F "file=@${AIFF};type=audio/aiff" -F "language=en" \
    ${OCOREAI_API_KEYS:+-H "Authorization: Bearer ${OCOREAI_API_KEYS%%,*}"} \
    "$PROBE_BASE/v1/audio/transcriptions" 2>&1
}

if [ "$SAY_OK" = "1" ]; then
  RAW="$(transcribe_multipart)"
  M_STATUS="${RAW##*$'\n'}"
  M_BODY="${RAW%$'\n'*}"
  M_TEXT="$(probe_json "$M_BODY" 'text')"
  M_CODE="$(probe_json "$M_BODY" 'error.error_code')"
  M_REM="$(probe_json "$M_BODY" 'error.remediation')"
  M_ENGINE="$(probe_json "$M_BODY" 'engine')"
  M_DET="$(probe_json "$M_BODY" 'speech_detected')"
  echo "        multipart -> HTTP ${M_STATUS} | speech_detected=${M_DET:-absent} | engine=${M_ENGINE:-none} | code=${M_CODE:-none}"
  [ -n "$M_TEXT" ] && echo "        transcript: $M_TEXT"

  if [ "$VERDICT" = "ready" ]; then
    # The server said it can hear. Hold it to that.
    if [ "$M_STATUS" = "200" ] && [ -n "$M_TEXT" ]; then
      ok "verdict ready and the box heard a real utterance (${#M_TEXT} chars)"
      if [ "$M_DET" = "True" ] || [ "$M_DET" = "true" ]; then
        ok "speech_detected=true on a real utterance"
      else
        bad "speech_detected='$M_DET' on an utterance that plainly contains speech"
      fi
      MATCHED="$(python3 - "$M_TEXT" "$UTTERANCE" <<'PY'
import sys
heard = set(w.lower().strip(".,!?") for w in sys.argv[1].split())
said = set(w.lower().strip(".,!?") for w in sys.argv[2].split())
print(len(heard & said))
PY
)"
      if [ "${MATCHED:-0}" -ge "$WORDS_EXPECTED" ]; then
        ok "transcript matches the utterance ($MATCHED words in common)"
      else
        bad "transcript shares $MATCHED words with the utterance (< $WORDS_EXPECTED) — heard something, but not this"
      fi
    elif [ "$M_STATUS" = "200" ] && [ "$M_DET" = "False" ]; then
      bad "verdict ready but the detector found no speech in a real utterance — 能听 claimed, not delivered"
    else
      bad "verdict ready but the request failed (HTTP $M_STATUS code=${M_CODE:-none}) — the probe said ok and the endpoint refused"
    fi
  else
    # Not ready: the honest outcome is a typed refusal that names what to change.
    if [ "$M_STATUS" = "503" ] && [ -n "$M_CODE" ]; then
      ok "unready box refuses with error_code=$M_CODE instead of pretending to transcribe"
      if [ -n "$M_REM" ]; then
        ok "refusal carries a remediation a human can act on"
      else
        bad "503 without remediation — the client is left to guess which axis to fix"
      fi
      echo "        remediation: $M_REM"
    elif [ "$M_STATUS" = "200" ]; then
      bad "verdict '$VERDICT' but the endpoint returned 200 with text='$M_TEXT' — a transcript from a box that says it cannot hear"
    else
      bad "expected a typed 503 for verdict '$VERDICT', got HTTP $M_STATUS (code=${M_CODE:-none})"
    fi
  fi

  # The JSON extension must answer the same question the same way.
  JSON_BODY="$(python3 - "$AIFF" <<'PY'
import base64, json, sys
with open(sys.argv[1], "rb") as f:
    b64 = base64.b64encode(f.read()).decode()
print(json.dumps({"audio": f"data:audio/aiff;base64,{b64}", "language": "en"}))
PY
)"
  probe_api POST /v1/audio/transcriptions "$JSON_BODY"
  J_STATUS="${PROBE_STATUS:-}"
  J_TEXT="$(probe_json "$PROBE_BODY" 'text')"
  J_CODE="$(probe_json "$PROBE_BODY" 'error.error_code')"
  echo "        json base64 -> HTTP ${J_STATUS} | code=${J_CODE:-none}"
  if [ "$J_STATUS" = "$M_STATUS" ]; then
    ok "multipart and JSON shapes agree (both HTTP $J_STATUS)"
  else
    bad "multipart said $M_STATUS and JSON said $J_STATUS for the same bytes — two shapes, two answers"
  fi
  if [ "$J_STATUS" = "200" ] && [ "$M_STATUS" = "200" ]; then
    if [ "$J_TEXT" = "$M_TEXT" ]; then
      ok "both shapes return the same transcript"
    else
      bad "the two shapes transcribed the same audio differently ('$J_TEXT' vs '$M_TEXT')"
    fi
  fi

  # `response_format: text` must give the transcript itself, not a JSON envelope.
  TXT_BODY="$(python3 - "$AIFF" <<'PY'
import base64, json, sys
with open(sys.argv[1], "rb") as f:
    b64 = base64.b64encode(f.read()).decode()
print(json.dumps({"audio": f"data:audio/aiff;base64,{b64}", "response_format": "text"}))
PY
)"
  TXT_CT="$(curl -sS -m "${OCOREAI_PROBE_CURL_TIMEOUT:-180}" -o /dev/null -w '%{content_type}|%{http_code}' \
    ${OCOREAI_API_KEYS:+-H "Authorization: Bearer ${OCOREAI_API_KEYS%%,*}"} \
    -H 'Content-Type: application/json' --data "$TXT_BODY" "$PROBE_BASE/v1/audio/transcriptions" 2>&1)"
  case "${TXT_CT%%|*}" in
    text/plain*) ok "response_format=text answers as text/plain (${TXT_CT##*|})" ;;
    *)
      if [ "${TXT_CT##*|}" = "400" ] || [ "${TXT_CT##*|}" = "503" ]; then
        probe_note "response_format=text was refused on this host (${TXT_CT}) — format cannot be checked while the engine is unavailable, and is NOTEd, not claimed"
      else
        bad "response_format=text returned content-type '${TXT_CT%%|*}', expected text/plain"
      fi
      ;;
  esac
fi

# ── 4. the surface points here ────────────────────────────────────────────────
probe_section "capability surface and endpoint index agree"
probe_api GET /v1/capabilities
if [ "${PROBE_STATUS:-}" = "200" ]; then
  IDX="$(python3 - "$PROBE_BODY" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
eps = doc.get("endpoints") or []
hit = [e for e in eps if e.get("path") == "/v1/audio/transcriptions" and e.get("method") == "POST"]
if not hit:
    print("MISSING||")
else:
    note = str(hit[0].get("note") or "")
    stt = [c for c in (doc.get("capabilities") or []) if c.get("name") == "local_stt"]
    print(f"FOUND|{note[:400]}|{str(stt[0].get('note') if stt else '')[:400]}")
PY
)"
  if [ "${IDX%%|*}" = "FOUND" ]; then
    ok "the endpoint index lists POST /v1/audio/transcriptions"
    NOTE_FIELD="$(printf '%s' "$IDX" | cut -d'|' -f2)"
    case "$NOTE_FIELD" in
      *multipart*) ok "its note names the multipart shape clients send" ;;
      *) bad "its note does not mention multipart, so OpenAI clients will not know they are supported" ;;
    esac
    STT_NOTE="$(printf '%s' "$IDX" | cut -d'|' -f3-)"
    case "$STT_NOTE" in
      *audio/transcriptions*) ok "the local_stt capability line points at the endpoint that delivers it" ;;
      *) bad "local_stt is advertised without pointing at where speech enters ('$STT_NOTE')" ;;
    esac
  else
    bad "POST /v1/audio/transcriptions is missing from the endpoint index in /v1/capabilities"
  fi
else
  bad "GET /v1/capabilities -> ${PROBE_STATUS:-no response}"
fi

# ── 5. the child probe, run directly ──────────────────────────────────────────
probe_section "--probe-hearing (the child that absorbs the trap)"
SELF_BIN="$(probe_resolve_binary || true)"
if [ -n "${SELF_BIN:-}" ]; then
  HELP_TEXT="$("$SELF_BIN" --help 2>&1 | head -80 || true)"
  case "$HELP_TEXT" in
    *"--probe-hearing"*) bad "the internal probe flag leaked into --help" ;;
    *) ok "--help does not advertise the internal probe flag" ;;
  esac

  if [ "$SAY_OK" = "1" ]; then
    FIXTURE="$AIFF"
  else
    FIXTURE=""
    for CAND in /System/Library/Audio/Sounds/*.aiff; do
      [ -f "$CAND" ] && { FIXTURE="$CAND"; break; }
    done
  fi
  if [ -n "$FIXTURE" ]; then
    # NB: no `|| true` — swallowing the status here is how a SIGTRAP turns into a pass.
    PROBE_STDOUT="$("$SELF_BIN" --probe-hearing "$FIXTURE" 2>/dev/null)"
    CHILD_RC=$?
    printf '        child rc=%s stdout: %s\n' "$CHILD_RC" \
      "$(printf '%s' "$PROBE_STDOUT" | tr '\n' ' ' | cut -c1-220)"

    # 1. A child that died must not have claimed success.
    case "$PROBE_STDOUT" in
      *'"ok":true'*)
        if [ "$CHILD_RC" -ge 128 ]; then
          bad "child reported ok:true and then died on a signal (rc=$CHILD_RC) — a probe that lies is worse than one that dies"
        else
          ok "child completed an analysis pass and reported ok (rc=$CHILD_RC)"
        fi ;;
      *) ok "child claimed no success it did not measure (rc=$CHILD_RC)" ;;
    esac

    # 2. Stage accounting: how far did it get?
    HAS_PRE=0; HAS_FINAL=0
    case "$PROBE_STDOUT" in *'"stage":"pre-analysis"'*) HAS_PRE=1 ;; esac
    case "$PROBE_STDOUT" in *'"stage":"final"'*) HAS_FINAL=1 ;; esac
    if [ "$CHILD_RC" -eq 0 ]; then
      if [ "$HAS_FINAL" = "1" ]; then
        ok "child reported its final line (rc=0)"
      else
        bad "child exited 0 with no final report line — the contract says it always reports"
      fi
    elif [ "$CHILD_RC" -ge 128 ]; then
      if [ "$HAS_PRE" = "1" ] && [ "$HAS_FINAL" = "0" ]; then
        ok "trap signature: reached the analysis pass, never left it (rc=$CHILD_RC; 133=SIGTRAP)"
        probe_note "this is precisely the case the child process exists for. The parent sees a"
        probe_note "signal, records engineFault, and refuses the request — instead of the app,"
        probe_note "engine pool and live sessions going down with an uncapturable trap."
      else
        bad "child died on a signal (rc=$CHILD_RC) with pre-analysis=$HAS_PRE final=$HAS_FINAL — stage accounting broken"
      fi
    else
      if [ "$HAS_FINAL" = "1" ]; then
        ok "child refused cleanly and still reported (rc=$CHILD_RC)"
      else
        bad "child exited $CHILD_RC with no final report line"
      fi
    fi
  fi

else
  bad "could not resolve the ocoreai binary to run --probe-hearing (set OCOREAI_BIN)"
fi

# ── 6. premise floor ──────────────────────────────────────────────────────────
if [ "$CHECKS" -ge 18 ]; then
  ok "premise floor: ${CHECKS} verdicts issued by this run"
else
  bad "only ${CHECKS} verdicts issued (< 18) — a leg stopped matching, so this run proves nothing"
fi

probe_summary "$PROBE_NAME"
