#!/usr/bin/env bash
# 38-reasoning-effort-honesty.sh — does a demanded `reasoning_effort` reach the checkpoint, or
# only the log?
#
# ### Why
# The wire forwards `reasoning_effort` verbatim into the chat-template context and owns no word
# table (`ReasoningEffortWire`), so for a checkpoint whose template never names the variable the
# word is dropped before generation — yet the caller still gets 200 and believes it asked for
# thinking control. At load the server now renders the checkpoint's own template with a sentinel
# value and records what happened (`ReasoningEffortLedger`), and a demanded word that
# measurably reaches nothing is refused with both exits named, after codex's
# `unsupported_code_mode_warning` (`core/src/session/code_mode_warning.rs:6-24`).
#
# ### Two tiers, because only one of them can run without weights
#   §1 scripted (no model, CI tier) — an UNMEASURED checkpoint must never be refused, and the
#      `/v1/models` row must say `not_observed` rather than omit the question. This is the half
#      that keeps invariant 2 honest in the fail-open direction.
#   §2 checkpoint (needs one ready model; skipped with a printed reason otherwise) — the load
#      probe ran (a loaded model must NOT report `not_observed`: that floor is what stops a
#      rotted measurement reading as honesty), and on a measured `template_ignores` the demand
#      gets 400 naming knob + evidence + remedy, with the server healthy for the next request.
#      On `honored` the same request must pass through — the refusal must not fire on the
#      positive face.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="reasoning-effort-honesty"

SCRIPT_FILE="$(mktemp -t ocoreai-script-XXXXXX).json"
probe_atexit "rm -f '$SCRIPT_FILE'"
cat > "$SCRIPT_FILE" <<'JSON'
{
  "segments": ["thinking control accepted."],
  "finishReason": "eos",
  "promptTokens": 5,
  "generatedTokens": 4
}
JSON
export OCOREAI_SCRIPTED_ENGINE="$SCRIPT_FILE"

EFFORT_BODY='{"model":"scripted-model","messages":[{"role":"user","content":"hi"}],"reasoning_effort":"high"}'

# ── §1 scripted lane: unmeasured is never refused ─────────────────────────────────────────
probe_boot
probe_api GET /v1/capabilities
if [ "$(probe_json "$PROBE_BODY" 'engineBackend')" = "scripted" ]; then
  probe_ok "§1 premise holds — a script drives this server, so nothing here is measured"
else
  probe_fail "§1 could not establish the scripted backend — its premise is missing, so §1 proves nothing"
fi

probe_api GET /v1/models
if [ "${PROBE_STATUS:-}" != "200" ]; then
  probe_fail "GET /v1/models -> ${PROBE_STATUS:-no response}"
else
  ROWS="$(python3 - "$PROBE_BODY" <<'PY'
import json, sys
data = json.loads(sys.argv[1]).get("data", [])
words = {"honored", "template_ignores", "not_observed"}
bad = [f"{m.get('id')}={m.get('reasoningEffort')!r}" for m in data
       if m.get("reasoningEffort") not in words]
print(f"rows={len(data)} bad={';'.join(bad) if bad else 'none'}")
PY
)"
  case "$ROWS" in
  *"bad=none"*) probe_ok "§1 /v1/models rows all use the closed vocabulary ($ROWS)" ;;
  *) probe_fail "§1 /v1/models published a reasoningEffort outside honored|template_ignores|not_observed ($ROWS)" ;;
  esac
fi

probe_api POST /v1/chat/completions "$EFFORT_BODY"
if [ "${PROBE_STATUS:-}" = "200" ]; then
  probe_ok "§1 an unmeasured checkpoint is NOT refused (200) — unmeasured is not a measured 'no'"
else
  probe_fail "§1 a never-measured checkpoint refused a demanded reasoning_effort (${PROBE_STATUS:-no response}) — that is a refusal built on absence of evidence: $PROBE_BODY"
fi

# The scripted lane still answers the same turn with the word removed: the refusal (§2) is
# about the word, not about the model being alive.
probe_api POST /v1/chat/completions '{"model":"scripted-model","messages":[{"role":"user","content":"hi"}]}'
if [ "${PROBE_STATUS:-}" = "200" ]; then
  probe_ok "§1 the same turn without the word still completes (the refusal would cost a turn, not the server)"
else
  probe_fail "§1 the scripted lane stopped answering (${PROBE_STATUS:-no response})"
fi

# ── §2 checkpoint tier ────────────────────────────────────────────────────────────────────
probe_api GET /v1/models
READY_MODEL="$(python3 - "$PROBE_BODY" <<'PY'
import json, sys
for m in json.loads(sys.argv[1]).get("data", []):
    caps = m.get("capabilities") or []
    if str(m.get("state", "ready")) == "ready" and "embed" not in caps:
        print(m.get("id", ""))
        break
PY
)"
if [ -z "$READY_MODEL" ]; then
  probe_note "§2 skipped — no ready checkpoint on this host (the measured-negative half needs weights; put one in ~/.ocoreai/models)"
  probe_summary "$PROBE_NAME"
fi
probe_note "§2 running against $READY_MODEL"

# The scripted server holds the single-instance lock, and `_lib.sh` deliberately never reaps
# the server this script started itself — so §2 stops it by pid (never `pkill -x ocoreai`, which
# also matches a serve another session owns).
if [ -n "${PROBE_PID:-}" ] && kill -0 "$PROBE_PID" 2>/dev/null; then
  probe_note "§2 stopping the scripted server (pid $PROBE_PID) before the checkpoint boot"
  kill -TERM "$PROBE_PID" 2>/dev/null || true
  for _ in $(seq 1 40); do
    kill -0 "$PROBE_PID" 2>/dev/null || break
    sleep 0.5
  done
  PROBE_PID=""
fi

unset OCOREAI_SCRIPTED_ENGINE
probe_boot
probe_require_ready_model
# Force the load: the face is produced at load, and a row that predates a load says nothing.
probe_api POST /v1/chat/completions \
  "{\"model\":\"$PROBE_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say ok.\"}],\"max_tokens\":8}"
if [ "${PROBE_STATUS:-}" = "200" ]; then
  probe_ok "§2 the checkpoint loaded and answered (the load-time template probe ran on these weights)"
else
  probe_fail "§2 the warm-up turn failed (${PROBE_STATUS:-no response}) — §2 cannot judge a face it never produced"
fi

probe_api GET /v1/models
MODE="$(python3 - "$PROBE_BODY" "$PROBE_MODEL" <<'PY'
import json, sys
for m in json.loads(sys.argv[1]).get("data", []):
    if m.get("id") == sys.argv[2]:
        print(m.get("reasoningEffort") or "")
        break
PY
)"
case "$MODE" in
honored | template_ignores)
  probe_ok "§2 a loaded checkpoint reports a measured face ($MODE), not a silent absence"
  ;;
not_observed | "")
  probe_fail "§2 the load-time template probe never recorded anything for the loaded model — the measurement rotted and the face would read as honesty (mode='${MODE:-absent}')"
  ;;
*)
  probe_fail "§2 unexpected reasoningEffort value '$MODE'"
  ;;
esac

probe_api POST /v1/chat/completions \
  "{\"model\":\"$PROBE_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"reasoning_effort\":\"high\"}"
case "$MODE" in
template_ignores)
  if [ "${PROBE_STATUS:-}" = "400" ]; then
    probe_ok "§2 a demanded word this template measurably ignores is refused 400, not delivered 200"
    MSG="$(probe_json "$PROBE_BODY" 'error.message')"
    MISSING=""
    for needle in "reasoning_effort" "$PROBE_MODEL" "high" "Omit" "honored"; do
      case "$MSG" in *"$needle"*) ;; *) MISSING="$MISSING $needle" ;; esac
    done
    if [ -z "$MISSING" ]; then
      probe_ok "§2 the refusal names the knob, the checkpoint, the value sent, and both exits"
    else
      probe_fail "§2 the refusal omits what a client needs to act on ($MISSING): $MSG"
    fi
  else
    probe_fail "§2 expected 400 on a measured 'template_ignores' checkpoint, got ${PROBE_STATUS:-no response}: $PROBE_BODY"
  fi
  ;;
honored)
  if [ "${PROBE_STATUS:-}" = "200" ]; then
    probe_ok "§2 a checkpoint that reads the kwarg still gets it (the refusal does not fire on the positive face)"
  else
    probe_fail "§2 a measured 'honored' checkpoint was refused (${PROBE_STATUS:-no response}): $PROBE_BODY"
  fi
  ;;
esac

# A refusal is a refusal, not a crash: the next request must be served (probe 09's pattern).
probe_api GET /health
if [ "${PROBE_STATUS:-}" = "200" ]; then
  probe_ok "§2 the server is healthy on the request after the refusal"
else
  probe_fail "§2 the server did not survive the refusal (${PROBE_STATUS:-no response})"
fi

probe_summary "$PROBE_NAME"
