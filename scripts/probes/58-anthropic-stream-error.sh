#!/usr/bin/env bash
# 58-anthropic-stream-error.sh. Does a failed /v1/messages stream SAY it failed?
#
# Why (AGENTS.md invariant 2): the engine reports a mid-turn failure as an `.error` event
# (`Engine/ScriptedInference.swift` yields it when the script is broken, no weights needed to
# produce one). Read 11-21, the streaming `/v1/messages` handler LOGGED that event and dropped
# the message, then ran its normal tail: `content_block_stop → message_delta(stop_reason
# "end_turn") → message_stop`. The wire then claims a clean, finished turn for a turn the
# engine itself named as an error, and the four other failure exits on this face (safety block
# ×3, consumption throw) emitted `{"type":"error"}` with no `error` payload at all, which is
# outside the spec's event: Anthropic's error event is
# `{"type":"error","error":{"type","message"}}`
# (`../references/sglang/python/sglang/srt/entrypoints/anthropic/protocol.py:25-36`), and a
# client reads `event.error.message` to know what happened. sglang's failure exit
# (`entrypoints/anthropic/serving.py:967-982`) also closes every open `content_block` first,
# because a strict client rejects `content_block_start` with no matching stop.
#
# Arms, all weight-free (a broken script IS the failure injector):
#   A1 the stream carries an error event with the spec payload,
#   A2 it carries no `message_delta`, no terminal reason is claimed for a failed turn,
#   A3 every opened content block is closed,
#   A4 the stream still terminates cleanly (last frame `message_stop`),
#   A5 the non-stream face of the same script must not claim `end_turn` either (parity,
#      it sets `stop_reason:"error"`; this arm pins that it stays not-a-success).
#
# Run: bash scripts/probes/58-anthropic-stream-error.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="anthropic-stream-error"

SCRIPT_FILE="$(mktemp -t ocoreai-errscript-XXXXXX).json"
probe_atexit "rm -f '$SCRIPT_FILE'"

# Valid JSON (so segments stream first. A mid-stream failure, not a boot failure) whose
# finishReason is not in the scriptable set: ScriptedInference then yields `.error` after the
# text, which is exactly the shape an engine failure takes on this face.
cat > "$SCRIPT_FILE" <<'JSON'
{
  "segments": ["This turn is about to fail m"],
  "finishReason": "not_a_real_reason",
  "promptTokens": 5,
  "generatedTokens": 8
}
JSON

export OCOREAI_SCRIPTED_ENGINE="$SCRIPT_FILE"
probe_note "script $SCRIPT_FILE — text streams, then the engine yields .error"

# Backend check first: a red below must mean the handler, not a mis-booted tier.
probe_boot
probe_api GET /v1/capabilities
BACKEND="$(probe_json "$PROBE_BODY" 'engineBackend')"
if [ "$BACKEND" = "scripted" ]; then
  probe_ok "engineBackend=scripted — the failure below is injected, not loaded"
else
  probe_fail "engineBackend='${BACKEND:-<absent>}' — without the scripted lane none of these" \
    "arms reaches a real engine failure; aborting before the stream arms mislead"
  probe_summary "$PROBE_NAME"
fi

MESSAGES_BODY='{"model":"scripted-model","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"hi"}]}'
STREAM="$(curl -sSN -m "${OCOREAI_PROBE_CURL_TIMEOUT:-180}" -X POST "$PROBE_BASE/v1/messages" \
  -H 'Content-Type: application/json' -d "$MESSAGES_BODY")"

FRAMES="$(printf '%s' "$STREAM" | grep -c '^data: ')"
probe_require_int "SSE frame count" "$FRAMES"
if [ "$FRAMES" -lt 4 ]; then
  probe_fail "only $FRAMES frames on a stream that opened (premise: message_start + text + failure" \
    "exit leave ≥4); verdict:$(printf '%s' "$STREAM" | head -c 400)"
fi

VERDICT="$(printf '%s' "$STREAM" | python3 -I -c '
import json, sys
kinds, err, opened, closed, last = [], None, 0, 0, None
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("data: "):
        continue
    try:
        d = json.loads(line[6:])
    except Exception:
        continue
    t = d.get("type", "")
    kinds.append(t)
    last = t
    if t == "error":
        err = d
    if t == "content_block_start":
        opened += 1
    if t == "content_block_stop":
        closed += 1
parts = {
    "has_error": err is not None,
    "err_type": (err or {}).get("error", {}).get("type", "<absent>"),
    "err_msg": bool((err or {}).get("error", {}).get("message")),
    "has_message_delta": "message_delta" in kinds,
    "pairing": f"{opened}/{closed}",
    "last": last or "<none>",
}
print(",".join(f"{k}={v}" for k, v in parts.items()))
')"
probe_note "stream verdict: $VERDICT"

# A1. The error event exists and carries the spec payload.
if printf '%s' "$VERDICT" | grep -q "has_error=True"; then
  probe_ok "a failed /v1/messages stream emits an error event"
  ET="$(printf '%s' "$VERDICT" | tr ',' '\n' | sed -n 's/^err_type=//p')"
  EM="$(printf '%s' "$VERDICT" | tr ',' '\n' | sed -n 's/^err_msg=//p')"
  if [ "$ET" = "api_error" ] && [ "$EM" = "True" ]; then
    probe_ok "error.error carries Anthropic's payload — type=api_error, message present"
  else
    probe_fail "error event without the payload a client parses: type='${ET}' message-present='${EM}'" \
      "— the spec requires {type,message} (protocol.py:25-36)"
  fi
else
  probe_fail "a stream whose engine failed carries NO error event at all — the wire claimed" \
    "the turn as a normal finish (frames: $(printf '%s' "$STREAM" | grep '^data:' | head -c 400))"
fi

# A2, no message_delta: a failed turn owes no terminal stop_reason.
if printf '%s' "$VERDICT" | grep -q "has_message_delta=False"; then
  probe_ok "no message_delta on a failed turn — no clean-turn reason is claimed"
else
  probe_fail "the failed turn's stream carries message_delta — a stop_reason for a turn the" \
    "engine named as an error (invariant 2: the surface claims more than the engine delivered)"
fi

# A3. Opened blocks are closed.
PAIRING="$(printf '%s' "$VERDICT" | tr ',' '\n' | sed -n 's/^pairing=//p')"
OPENED="${PAIRING%%/*}"
CLOSED="${PAIRING##*/}"
probe_require_int "opened content blocks" "${OPENED:-x}"
if [ "${OPENED:-x}" = "$CLOSED" ]; then
  probe_ok "every opened content block is closed on the failure path ($PAIRING)"
else
  probe_fail "content blocks opened-but-not-closed on the failure path: $PAIRING — a strict" \
    "client rejects this stream before it can read the error"
fi

# A4. Clean termination.
LAST="$(printf '%s' "$VERDICT" | tr ',' '\n' | sed -n 's/^last=//p')"
if [ "$LAST" = "message_stop" ]; then
  probe_ok "the failure exit still ends the stream (last frame message_stop)"
else
  probe_fail "failed stream's last frame is '$LAST' — clients that wait for message_stop hang"
fi

# A5. Parity: the non-stream face of the same failing script must not claim end_turn.
probe_api POST /v1/messages \
  "$(printf '%s' "$MESSAGES_BODY" | sed 's/,"stream":true//')"
STOP="$(probe_json "$PROBE_BODY" 'stop_reason')"
if [ "$STOP" != "end_turn" ] && [ -n "$STOP" ]; then
  probe_ok "non-stream face says stop_reason='$STOP' for the same failed turn — not a clean finish"
else
  probe_fail "non-stream face claims stop_reason='${STOP:-<absent>}' for a turn the engine" \
    "errored — one face cannot launder what the other is gated on"
fi

probe_summary "$PROBE_NAME"
