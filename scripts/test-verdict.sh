#!/usr/bin/env bash
# test-verdict.sh — did the test harness deliver a verdict at all, and how many tests ran?
#
# ### Why this exists (10-28)
# Both CI legs printed `xctest summary (exit 0): Executed 0 tests, with 0 failures` and went green,
# and that annotation is the sentence a reader uses to decide whether the suite ran. It is XCTest's
# own summary, and this repo's Tests/ tree holds no XCTestCase file, so it prints "Executed 0 tests"
# on every run forever. The half that carries the verdict — swift-testing's
# `Test run with N tests …` — was missing from that annotation only because a `::notice::` line
# ends at its first newline and the value carried two lines. So the annotation was unreadable AND
# the gate had no floor under it: nothing anywhere would have gone red if the bundle stopped
# executing tests while still exiting 0.
#
# ### Contract
#   0  swift-testing reported a run with >= 1 test that did not report failure
#   1  it reported no summary, 0 tests, or a failing run  -> do not read this as green
# The XCTest half is reported, never judged: xctest's own exit code covers its failures, and its
# count is 0 by policy here.
# (The exit code means what the sentence above says: measured 10-29 against a bundle whose run
# failed, printing the ✘ line and exiting 0 claimed a verdict worth acting on while disclaiming
# the only judgement anyone reads it for. CI's step also honours xctest's exit code; this one
# simply stops calling a reported failure a pass.)
#
# Usage: test-verdict.sh <log-file>
set -uo pipefail

log="${1:?usage: test-verdict.sh <log-file>}"
[ -r "$log" ] || { echo "test-verdict: cannot read $log" >&2; exit 1; }

# One line per framework, because a workflow command cannot carry a newline: the value that
# silently lost half its content here was a two-line grep result.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
st_line=$(grep -E "Test run with [0-9]+ test" "$log" | tail -1 || true)
xc_line=$(grep -E "Executed [0-9]+ test" "$log" | tail -1 || true)
st_count=$(printf '%s\n' "$st_line" | sed -nE 's/.*Test run with ([0-9]+) test.*/\1/p' | head -1)
xc_files=$(git -C "$repo_root" grep -l "XCTestCase" -- Tests 2>/dev/null | wc -l | tr -d " ")

emit() {
  # level text…
  if [ "${GITHUB_ACTIONS:-false}" = "true" ]; then
    printf '::%s::%s\n' "$1" "$2"
  else
    printf '%s\n' "$2"
  fi
}

emit notice "swift-testing verdict: ${st_line:-NO SUMMARY LINE — the bundle never reported a verdict}"
emit notice "xctest half: ${xc_line:-none} (this suite is swift-testing-only: $xc_files XCTestCase file(s))"

if [ -z "$st_line" ]; then
  emit error "no swift-testing summary in $(wc -l < "$log" | tr -d " ") log line(s) — the run died before reporting (crash, timeout, or a load failure), which is not a pass"
  exit 1
fi
if [ "${st_count:-0}" -eq 0 ]; then
  emit error "swift-testing reported 0 tests — the bundle contains no compiled test code, so this step cannot judge anything"
  exit 1
fi
if printf '%s' "$st_line" | grep -q "failed after"; then
  emit error "swift-testing reported a failing run — ${st_line}"
  exit 1
fi
exit 0
