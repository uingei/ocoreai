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

# ── the cold leg: opt into the cache state a stranger actually arrives in ────────────────────
#
# A warm-cache clock answers "how fast is this machine once everything is here", which is not the
# question the goal asks. FIRST_RUN_COLD=1 points the model store at an empty temp directory before
# the bundle starts, so the first download sits inside the measured window, and the server's own
# `completed` frame is asserted to land inside that directory — the assertion is what proves the cold
# premise instead of trusting that an exported variable reached a GUI process.
#
# What it still is not: a clean machine. Nothing here pays the Gatekeeper decision (this bundle is
# unsigned and unstapled) and an empty model dir is not an empty home, so both halves stay named in
# the run output and in docs/agent/open-items.md instead of being folded into the number.
FIRST_RUN_COLD="${FIRST_RUN_COLD:-0}"
COLD_DIR=""
if [ "$FIRST_RUN_COLD" = 1 ]; then
  COLD_DIR="$(cd "$(mktemp -d -t ocoreai-coldcache-XXXXXX)" && pwd -P)"
  # A hub id carries its org: a bare `gemma-4-e2b-it-4bit` is refused as "not found" (measured), and
  # letting /v1/models choose risks a 35B checkpoint on a host that cannot hold two engines.
  MODEL="${MODEL:-mlx-community/gemma-4-e2b-it-4bit}"
fi
SCRATCH_E2E="$(mktemp -d -t ocoreai-e2e-XXXXXX)"

# 1. Artifact must not be stale: bundle version == the version this tree resolves to.
#    A stale build/ directory silently ships an old stamp (observed: 0.1.3 under v0.1.5).
V="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo none)"
if [ "$V" != "$TAG" ]; then
  echo "❌ STALE ARTIFACT: $APP says $V, this tree resolves $TAG — rebuild before release"
  exit 1
fi
echo "✅ version parity — bundle $V == tree $TAG"

# ── the four conditions a first-run number is only comparable inside ────────────────
#
# A seconds figure without these is a slogan. The same artifact costs minutes on an empty
# cache and seconds on a warm one, and another machine, checkpoint or install channel moves
# both — so a change to any one of the four is a NEW measurement point, never an edit of the
# old one. Printed first and kept with the run for that reason.
MACHINE="macOS $(sw_vers -productVersion 2>/dev/null || echo ?) $(uname -m) $(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0fGB", $1/1073741824}')"
if [ -n "$COLD_DIR" ]; then
  # Before `open`: the bundle inherits this shell's environment on macOS (measured on this host), and
  # ModelStore.root reads $OCOREAI_MODELS_DIR ahead of ~/.ocoreai/models.
  export OCOREAI_MODELS_DIR="$COLD_DIR"
  MODELS_DIR="$COLD_DIR"
  CACHE="cold — empty cache at $COLD_DIR, the first download is inside the clock (still not a clean machine: no Gatekeeper)"
else
  MODELS_DIR="${OCOREAI_MODELS_DIR:-$HOME/.ocoreai/models}"
  CHECKPOINTS="$(find "$MODELS_DIR" -maxdepth 3 -name config.json 2>/dev/null | wc -l | tr -d ' ')"
  CACHE="warm — $CHECKPOINTS checkpoint(s) already at $MODELS_DIR, no download exercised"
fi
NET="default route: $(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
CLOCK_T0=$SECONDS

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
    # A cold run pulls gigabytes into a temp dir; no early exit may leave them behind.
    if [ -n "${COLD_DIR:-}" ]; then rm -rf "$COLD_DIR"; fi
    if [ -n "${SCRATCH_E2E:-}" ]; then rm -rf "$SCRATCH_E2E"; fi
}
trap cleanup_app EXIT
OCOREAI_ENABLE_HTTP=1 OCOREAI_APPROVAL_POLICY=auto open "$APP"
echo "launched $APP (pid group via open)"
CLOCK_LAUNCH=$SECONDS

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
CLOCK_HEALTH=$SECONDS

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

# 3c. The cold leg, timed on the server's own words. POST /v1/models/download answers SSE frames and
#     its terminal frame is the only honest stop for a download clock: a client that stops when the
#     bytes stop can miss a rename, a checksum or a refused write, and would report the transfer as
#     the whole first-run cost. So the verdict comes from eventType=completed, and the cacheDir in
#     that frame is checked against the directory this run exported — the premise gets proven, not
#     assumed. eventType=error prints verbatim: the disk guard refusing a first-run download IS a
#     stranger's first-run experience, and a red here is that finding, not a flaky harness.
CLOCK_DOWNLOAD=""
if [ -n "$COLD_DIR" ]; then
  echo "cold leg: downloading $MODEL into $COLD_DIR"
  DL_T0=$SECONDS
  RC=0
  curl -sN -m "${OCOREAI_COLD_DOWNLOAD_TIMEOUT:-1800}" -X POST \
    -H 'Content-Type: application/json' \
    --data "{\"model\":\"$MODEL\"}" \
    "http://127.0.0.1:${PORT}/v1/models/download" \
    | python3 -c '
import json, sys
last = -10
for raw in sys.stdin:
    if not raw.startswith("data:"):
        continue
    try:
        ev = json.loads(raw[5:].strip())
    except Exception:
        continue
    kind = ev.get("eventType")
    if kind == "progress":
        pct = int(ev.get("percentage") or 0)
        if pct >= last + 10:
            last = pct
            got = (ev.get("transferredBytes") or 0) / 1e6
            tot = (ev.get("totalBytes") or 0) / 1e6
            print("   ... %d%%  %.0f/%.0f MB  eta %ss" % (pct, got, tot, ev.get("etaSeconds")),
                  file=sys.stderr, flush=True)
    elif kind in ("completed", "error"):
        print(json.dumps(ev))
        break
' > "$SCRATCH_E2E/download.json" || RC=$?
  CLOCK_DOWNLOAD=$SECONDS
  DL_FACTS="$(python3 -c '
import json, sys
try:
    ev = json.load(open(sys.argv[1]))
except Exception:
    print("unreadable||"); raise SystemExit
print("%s|%s|%s" % (ev.get("eventType") or "no-terminal-frame",
                    ev.get("cacheDir") or "", ev.get("errorMessage") or ""))
' "$SCRATCH_E2E/download.json" 2>/dev/null || echo 'unreadable||')"
  DL_KIND="${DL_FACTS%%|*}"
  DL_CACHE="$(printf '%s' "$DL_FACTS" | cut -d'|' -f2)"
  DL_ERROR="$(printf '%s' "$DL_FACTS" | cut -d'|' -f3-)"
  if [ "$DL_KIND" != "completed" ]; then
    echo "❌ cold download ended on eventType=$DL_KIND (curl rc=$RC): ${DL_ERROR:-no terminal frame printed}"
    echo "   This leg IS the first-run path; a stream that never says completed is not a fast" \
      " download, it is an unmeasured one. Frames kept at $SCRATCH_E2E/download.json"
    exit 1
  fi
  # realpath on both sides: mktemp answers /var/while the server reports /private/var/, and a
  # prefix compare across those two spellings would call a correct download a wrong cache.
  if ! python3 -c '
import os, sys
raise SystemExit(0 if os.path.realpath(sys.argv[1]).startswith(os.path.realpath(sys.argv[2])) else 1
' "$DL_CACHE" "$COLD_DIR"; then
    echo "❌ cold premise NOT in effect — the server wrote to ${DL_CACHE:-nothing}, this run exported $COLD_DIR"
    echo "   The exported store never reached the bundle, so every second above would be a warm number."
    exit 1
  fi
  ON_DISK="$(du -sk "$COLD_DIR" 2>/dev/null | awk '{print $1}')"
  echo "✅ cold leg: $MODEL reached $DL_CACHE in $((CLOCK_DOWNLOAD - CLOCK_HEALTH))s · ${ON_DISK:-?} KB on disk"
fi

# 4. One real completion through the GUI bridge (default model from /v1/models).
if [ -z "$MODEL" ]; then
  MODEL="$(curl -s -m 10 "http://127.0.0.1:${PORT}/v1/models" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["data"][0]["id"] if d.get("data") else "")')"
fi
[ -n "$MODEL" ] || { echo "❌ no model served"; exit 1; }
echo "model: $MODEL"
# `state` is how this server says "loadable", and a cold start answers with a model that is
# still loading — timing a completion from that moment would report the queue, not the
# first-run path a user waits through. Wait for the honest edge, then stamp it.
ready=0
for _ in $(seq 1 80); do
  curl -s -m 10 "http://127.0.0.1:${PORT}/v1/models" \
    | python3 -c 'import json,sys
data = json.load(sys.stdin).get("data", [])
raise SystemExit(0 if any(str(m.get("state","ready"))=="ready" for m in data) else 1)' \
    && { ready=1; break; }
  sleep 2
done
[ "$ready" = 1 ] || { echo "❌ no model reached state=ready in 160s — the first-run path stalls here, say so rather than time a queued turn"; exit 1; }
CLOCK_READY=$SECONDS
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
CLOCK_DONE=$SECONDS

# 5. THE TERMINAL EVENT. A completion proves the wire answers; the rung the goal names is a stranger's
#    agent finishing a real job armed only with the published skill, judged against THIS bundle. The
#    instrument is not re-authored here: probe 40 runs with OCOREAI_PROBE_BASE_URL set to the app this
#    script launched, so the same run that audits the task text for a leaked token and proves the
#    verifier rejects a WRONG deliverable is the run that watched it accept this artefact's answer.
#    The exit code is deliberately not the claim — probe 40 exits 0 when a premise could not be
#    established (known-open) — so the verdict binds to its own PASS line, and a run that measured
#    nothing reports itself as having measured nothing.
PROBE40_LOG="$SCRATCH_E2E/probe40.log"
# `|| PROBE40_RC=$?` is load-bearing, and it is the same trap this repo just fixed in ci.yml: under
# `set -e` a bare failing command aborts the script before the next line runs, so a red verifier used
# to end the run silently, with its log one line away from being deleted by the cleanup trap.
PROBE40_RC=0
OCOREAI_PROBE_BASE_URL="http://127.0.0.1:${PORT}" OCOREAI_READY_TIMEOUT="${OCOREAI_READY_TIMEOUT:-240}" \
  bash scripts/probes/40-stranger-agent-skill-task.sh > "$PROBE40_LOG" 2>&1 || PROBE40_RC=$?
CLOCK_JOB=$SECONDS
JOB_PASS="$(grep -m1 'retrieved the secret token on' "$PROBE40_LOG" | grep -m1 'PASS' || true)"
if [ -n "$JOB_PASS" ]; then
  echo "✅ real job done against the installed artifact: ${JOB_PASS:0:200}"
  VERDICT=measured
elif [ "$PROBE40_RC" -ne 0 ]; then
  echo "❌ the terminal verifier went RED against the installed artifact:"
  tail -25 "$PROBE40_LOG" | sed 's/^/     /'
  exit 1
else
  echo "❌ REAL JOB NOT MEASURED — probe 40 exited 0 without its verdict line, which means a premise"
  echo "                 it could not establish (known-open), not a job completed:"
  grep -E 'XFAIL|NOTE ' "$PROBE40_LOG" | tail -6 | sed 's/^/     /'
  exit 1
fi

# The number the goal is stated in, plus the only conditions it is comparable inside. The clock stops
# at the verifier above; a first answer is a segment on the way, not the end.
echo "FIRST-RUN CLOCK  open→health $((CLOCK_HEALTH - CLOCK_LAUNCH))s · health→model-ready $((CLOCK_READY - CLOCK_HEALTH))s · ready→first-completion $((CLOCK_DONE - CLOCK_READY))s · completion→real-job $((CLOCK_JOB - CLOCK_DONE))s · whole run to the verifier $((CLOCK_JOB - CLOCK_T0))s  [$VERDICT]"
echo "CONDITIONS       machine=$MACHINE · artifact=$(basename "$APP") $V · model=$MODEL · cache=$CACHE · $NET"
if [ -n "$COLD_DIR" ]; then
  echo "COLD LEG         MEASURED — the first download is inside the window above (store emptied, and"
  echo "                 the server's own completed frame stopped the download clock)."
else
  echo "COLD LEG         NOT MEASURED — no cold path ran, so every figure above is a warm-cache number."
  echo "                 FIRST_RUN_COLD=1 empties the model store and times the real download."
fi
# True in both branches, and stated rather than assumed away: neither mode is a clean machine. This
# bundle is unsigned and unstapled, so nothing here pays the Gatekeeper decision, and an emptied model
# dir is not an emptied home. Both halves stay open items, never a term of the clock.
echo "NOT REACHED      a clean machine — no Gatekeeper/quarantine decision, no first-launch TCC"
echo "                 prompts, no cask path. Still open (docs/agent/open-items.md); not in the number."


# 6. Graceful shutdown assertion: SIGTERM must EXIT the process (GUI bug
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
    echo "🎉 e2e-gui-app: shipping artifact verified end-to-end — engine + window geometry + pixel evidence + a stranger's agent finished a real job ($PNG)"
else
    echo "🎉 e2e-gui-app: shipping artifact verified end-to-end — engine + window geometry + real job; pixel evidence SKIPPED this session (see ⚠️ above)"
fi
