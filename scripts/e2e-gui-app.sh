#!/bin/bash
# e2e-gui-app.sh — verify the SHIPPING artifact (the GUI .app), not a proxy.
#
# First-principles: the release deliverable is ocoreai.app. A headless
# `ocoreai serve` binary is a CI stand-in that proves the engine boots and
# answers, but it is NOT what a user double-clicks. This script launches the
# real bundle via `open`, drives one real chat completion through its HTTP
# bridge, and asserts the bundle's own version/identity match the tag.
#
# Usage:  bash scripts/e2e-gui-app.sh            # expects build/ocoreai.app
#         APP=dist/.../ocoreai.app bash scripts/e2e-gui-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP:-build/ocoreai.app}"
PORT="${PORT:-8080}"
MODEL="${MODEL:-}"
TAG="$(bash scripts/version.sh)"

[ -d "$APP" ] || { echo "❌ $APP missing — run scripts/build-app.sh first"; exit 1; }

# 1. Artifact must not be stale: bundle version == the version this tree resolves to.
#    A stale build/ directory silently ships an old stamp (observed: 0.1.3 under v0.1.5).
V="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo none)"
if [ "$V" != "$TAG" ]; then
  echo "❌ STALE ARTIFACT: $APP says $V, this tree resolves $TAG — rebuild before release"
  exit 1
fi
echo "✅ version parity — bundle $V == tree $TAG"

# 2. Free the port AND kill any lingering bundle processes (a zombie that
#    dropped the socket but lives on makes `open` a no-op activate — the
#    GUI-SIGTERM bug of 2026-10-09; the app now handles SIGTERM itself,
#    but the harness must still be deterministic on older binaries).
for p in $(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null); do kill -TERM "$p" 2>/dev/null || true; done
for p in $(pgrep -f "$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")/Contents/MacOS" 2>/dev/null); do kill -TERM "$p" 2>/dev/null || true; done
sleep 3
for p in $(pgrep -f "$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")/Contents/MacOS" 2>/dev/null); do kill -9 "$p" 2>/dev/null || true; done
sleep 1
cleanup_app() {
    # No early exit may leave the shipped bundle running: Core/SingleInstanceLock.swift then
    # answers "Another ocoreai instance is already running" to every later probe launch, at the
    # full 240 s readiness timeout each. Observed: this script aborted at the window-capture leg
    # and the app lingered until a manual SIGTERM.
    local p
    p="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
    if [ -n "$p" ]; then
        kill -TERM "$p" 2>/dev/null || true
    fi
}
trap cleanup_app EXIT
OCOREAI_ENABLE_HTTP=1 OCOREAI_APPROVAL_POLICY=auto open "$APP"
echo "launched $APP (pid group via open)"

# 3. Health, then assert the LISTENER is the bundle binary (not a Debug/ proxy).
ok=0
for _ in $(seq 1 40); do
  curl -s -m 4 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && { ok=1; break; }
  sleep 3
done
[ "$ok" = 1 ] || { echo "❌ GUI app never became healthy on :${PORT}"; exit 1; }
PID="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t | head -1)"
BIN="$(ps -p "$PID" -o comm= | tr -d ' ')"
case "$BIN" in
  *".app/Contents/MacOS/ocoreai") echo "✅ serving from the shipping bundle: $BIN" ;;
  *) echo "❌ listener is NOT the .app bundle: $BIN"; exit 1 ;;
esac

# 3b. The user must actually SEE a window — HTTP health alone could be a
#     windowless zombie serving forever. CGWindowList proves a layer-0
#     window exists (no Accessibility TCC needed). The PNG is evidence, not a
#     gate: capture depends on screen-recording consent for the driving
#     process, and refusing here used to hide everything after it.
PNG="$PWD/build/ocoreai-window.png"
export PNG
# Opt out of the pixel requirement locally: consent to screen recording belongs to whoever
# drives this script, and a refusal is not an artifact defect. CI keeps the default (required).
SHOT=1 GUI_REQUIRE_PIXELS=0 bash scripts/verify-gui-window.sh

# 4. One real completion through the GUI bridge (default model from /v1/models).
if [ -z "$MODEL" ]; then
  MODEL="$(curl -s -m 10 "http://127.0.0.1:${PORT}/v1/models" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["data"][0]["id"] if d.get("data") else "")')"
fi
[ -n "$MODEL" ] || { echo "❌ no model served"; exit 1; }
echo "model: $MODEL"
python3 - "$PORT" "$MODEL" <<'PY' > /tmp/e2e_gui_req.json
import json, sys
port, model = sys.argv[1], sys.argv[2]
print(json.dumps({
    "model": model,
    "messages": [{"role": "user", "content": "Reply with exactly: OCOREAI_GUI_E2E_OK"}],
    "max_tokens": 24, "stream": False}))
PY
REPLY="$(curl -s -m 240 "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H 'Content-Type: application/json' -d @/tmp/e2e_gui_req.json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); ch=d.get("choices"); print(repr((ch[0]["message"].get("content") or "")[:200]) if ch else json.dumps(d)[:200])')"
echo "reply: $REPLY"
case "$REPLY" in
  *OCOREAI_GUI_E2E_OK*) echo "✅ GUI artifact completed a real turn" ;;
  *) echo "❌ GUI artifact failed the completion round-trip: $REPLY"; exit 1 ;;
esac

# 5. Graceful shutdown assertion: SIGTERM must EXIT the process (GUI bug
#    of 2026-10-09: it survived two SIGTERMs — port gone, process lingered,
#    poisoning the next launch). Escalate only after asserting the failure.
kill -TERM "$PID" 2>/dev/null || true
exited=0
for _ in $(seq 1 45); do
  kill -0 "$PID" 2>/dev/null || { exited=1; break; }
  sleep 1
done
if [ "$exited" != 1 ]; then
  echo "❌ SIGTERM did not terminate the GUI app (pid $PID alive after 45s)"
  kill -9 "$PID" 2>/dev/null || true
  exit 1
fi
echo "✅ SIGTERM graceful exit (drain + terminate)"
if [ -f "$PNG" ]; then
    echo "🎉 e2e-gui-app: shipping artifact verified end-to-end — engine + window geometry + pixel evidence ($PNG)"
else
    echo "🎉 e2e-gui-app: shipping artifact verified end-to-end — engine + window geometry; pixel evidence SKIPPED this session (see ⚠️ above)"
fi
