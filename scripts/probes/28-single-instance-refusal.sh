#!/usr/bin/env bash
# 28-single-instance-refusal.sh — when another instance holds the lock, does `serve` LEAVE?
#
# ### Why (AGENTS.md invariant 2, applied to the process instead of the wire)
# "The surface never claims more than the engine delivered" covers the process table: a live
# daemon that answers nothing is a surface claiming an engine. Measured 10-22 with the lock
# held by the built .app: `serve` printed "refusing to start a second engine" and
# "lifecycle: error" at t=0, then stayed in the runloop until an outside SIGTERM killed it,
# so scripts/eval/run.sh burned its whole readiness timeout — 237 s — on an answer it had
# already been given. The remedy was in the first line of the log; the exit code arrived four
# minutes later.
#
# ### What is asserted
#   1. Premise: instance A booted, /health is 200 and a model is ready — so the lock is held
#      by something that actually serves, which is the only state in which a refusal is the
#      right answer.
#   2. Departure: instance B exits on its own, unsignalled, within OCOREAI_REFUSE_TIMEOUT
#      (default 15 s) and with a non-zero code. "Refused" that has to be killed by its caller
#      is not a refusal, it is a hang wearing one.
#   3. The message carries the remedy: the holder's pid and OCOREAI_ALLOW_MULTI_INSTANCE, so
#      the operator does not have to read source to unblock themself.
#   4. The holder is unharmed: A still answers /health after B's departure — the guard
#      rejects a second engine, it does not disturb the first.
#   5. The harness cannot rot: _lib.sh still scans for the terminal startup sentences (a scan
#      that was deleted would report readiness for a server that said it would never serve),
#      and HeadlessServer still has the non-zero exit on `.error`.
#
# Not asserted here (deliberately): that OCOREAI_ALLOW_MULTI_INSTANCE=1 boots two engines
# successfully. Two 4-bit checkpoints resident at once is the GPU race this lock exists to
# prevent, and a probe must not stress the invariant it is guarding.
#
# Needs Metal, and a second process — it is a live probe, not a unit test.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$HERE/_lib.sh"
PROBE_NAME="single-instance-refusal"

: "${OCOREAI_REFUSE_TIMEOUT:=15}"

probe_boot
probe_require_ready_model
probe_note "holder pid $PROBE_PID holds the single-instance lock (model $PROBE_MODEL)"

BIN="$(probe_resolve_binary)"
PORT_B="$(probe_free_port)"
LOG_B="$(mktemp -t ocoreai-refuse-XXXXXX).log"

OCOREAI_ENABLE_HTTP=1 \
OCOREAI_HOST=127.0.0.1 \
OCOREAI_PORT="$PORT_B" \
  "$BIN" serve < /dev/null > "$LOG_B" 2>&1 &
PID_B=$!
probe_note "instance B $PID_B → 127.0.0.1:$PORT_B (no signal will be sent to it)"

RC=""
waited=0
while [ "$waited" -le "$OCOREAI_REFUSE_TIMEOUT" ]; do
  if ! kill -0 "$PID_B" 2>/dev/null; then
    wait "$PID_B"
    RC=$?
    break
  fi
  sleep 1
  waited=$(( waited + 1 ))
done

if [ -z "$RC" ]; then
  probe_fail "instance B was still alive after ${OCOREAI_REFUSE_TIMEOUT}s — a refused serve must exit" \
    "on its own; its log already said it would not serve, so the wait changed nothing:"
  sed 's/^/        /' "$LOG_B"
  kill -TERM "$PID_B" 2>/dev/null || true
  probe_summary "$PROBE_NAME"
fi
probe_ok "instance B exited unsignalled after ${waited}s with code $RC (was: alive until killed, 237 s)"

if [ "$RC" -eq 0 ]; then
  probe_fail "instance B exited 0 while refusing to start — a startup that did not happen must not" \
    "look like a clean run to a supervisor (launchd/systemd retry on non-zero)"
fi

if grep -q "refusing to start a second engine" "$LOG_B"; then
  probe_ok "log names the refusal"
else
  probe_fail "log does not name the refusal — the operator gets an exit code and no reason:"
  sed 's/^/        /' "$LOG_B"
fi
if grep -q "$PROBE_PID" "$LOG_B" && grep -q "OCOREAI_ALLOW_MULTI_INSTANCE" "$LOG_B"; then
  probe_ok "refusal carries the remedy: holder pid $PROBE_PID + OCOREAI_ALLOW_MULTI_INSTANCE"
else
  probe_fail "refusal neither names the holder pid nor the opt-out env var — the message has to be" \
    "actionable on its own (last lines):"
  sed 's/^/        /' "$LOG_B"
fi

probe_api GET /health
if [ "${PROBE_STATUS:-}" = "200" ]; then
  probe_ok "holder still serves after the refusal (/health 200) — the guard rejects, it does not disturb"
else
  probe_fail "holder /health -> ${PROBE_STATUS:-no response}: rejecting a second engine broke the first"
fi

# Static floors: the two fixes this probe exists to keep.
if ! grep -qE "refusing to start a second engine|lifecycle: error|Circuit breaker open" "$HERE/_lib.sh"; then
  probe_fail "_lib.sh lost its terminal-startup-state scan — a dead-on-arrival server would again" \
    "cost the full readiness timeout instead of one second"
fi
root="$HERE"
for _ in 1 2 3 4 5 6; do
  [ -d "$root/.git" ] && break
  root="$(dirname "$root")"
done
if ! grep -q "_exit(1)" "$root/Sources/ocoreai/Headless/HeadlessServer.swift"; then
  probe_fail "HeadlessServer no longer exits non-zero on lifecycle: error — the daemon is back to" \
    "sitting alive on a startup that never happened"
fi
probe_note "static floor: _lib.sh terminal-state scan + HeadlessServer non-zero exit both present"

probe_summary "$PROBE_NAME"
