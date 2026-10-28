#!/usr/bin/env bash
# ci-step.sh <probe-number> — one live wire probe, as one CI step.
#
# ### Why one probe per step (10-29)
# The 10-28 push went red on the macos-26 leg and the whole diagnosis was one annotation:
# "The action 'Headless serve smoke (macos-26)' has timed out after 10 minutes." A combined step
# spends ONE shared bound, so a stall inside it names the step and never the probe, and the log
# that would say more sits behind a token. GitHub already reports a duration per step: splitting
# IS the instrument, cheaper than a watchdog and readable with no credential.
#
# ### Budgets are CI's, not the local ones
# These three probes download nothing (probe 37 answers a turn in 39 ms with an empty
# $OCOREAI_MODELS_DIR, measured 10-29), so a response slower than 20 s is exactly the failure this
# step exists to print — waiting it out buys nothing. The local cost of 37/38/39 is 2/10/28 s.
#
# ### A red publishes its own words
# Annotations reach /check-runs/{id}/annotations, which needs no token; the step summary carries
# the same tail for the person who does have the run page.
set -uo pipefail
NO="${1:?usage: ci-step.sh <probe-number>}"
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

BIN="${OCOREAI_BIN:-}"
if [ -z "$BIN" ]; then
  BIN_FILE="${OCOREAI_SMOKE_BIN_FILE:-/tmp/ocoreai-smoke-bin}"
  [ -f "$BIN_FILE" ] && BIN="$(cat "$BIN_FILE")"
fi
[ -n "$BIN" ] || { echo "::error::no smoke binary (OCOREAI_BIN unset and $BIN_FILE missing) — the locate step did not run" >&2; exit 1; }
[ -x "$BIN" ] || { echo "::error::smoke binary is not executable: $BIN" >&2; exit 1; }
export OCOREAI_BIN="$BIN"
export OCOREAI_READY_TIMEOUT="${OCOREAI_READY_TIMEOUT:-40}"
export OCOREAI_PROBE_CURL_TIMEOUT="${OCOREAI_PROBE_CURL_TIMEOUT:-20}"

LOG="probe-$NO.log"
START=$(date +%s)
RC=0
bash scripts/probes/run.sh "$NO" > "$LOG" 2>&1 || RC=$?
ELAPSED=$(( $(date +%s) - START ))
echo "probe $NO: exit $RC after ${ELAPSED}s (binary $BIN · readiness budget ${OCOREAI_READY_TIMEOUT}s · one request ${OCOREAI_PROBE_CURL_TIMEOUT}s)"

if [ "$RC" -eq 0 ]; then
  grep -E "passed,|✘" "$LOG" | tail -3
  exit 0
fi

tail -25 "$LOG" | sed 's/^/::error::  /'
{ echo "### probe $NO failed (exit $RC) after ${ELAPSED}s"; echo '```'
  grep -E "FAIL|NOTE  bridge|server exited|refusing to start|never answered|Fatal error" "$LOG" | tail -20
  echo '```'; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
exit "$RC"
