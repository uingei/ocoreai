#!/usr/bin/env bash
# ci-annotate.sh — publish a log's CAUSE where a reader with no token can read it.
#
# ### Why this exists (11-06, measured on every red the packaging leg has published since 10-31)
# Both CI call sites published `tail -25 | sed 's/^/::error::  /'`, because
# `/repos/{o}/{r}/check-runs/{id}/annotations` answers without a token while the step's stdout does
# not. Seven runs in a row (15, 16, 17, 18, 19, 20, 22) that channel returned the tail's FIRST nine
# lines and nothing else: nine compiler warnings, in identical order, from a 25-line window — and
# the line the leg died on, which sits at the END of that window, never appeared. A raw `%` or a
# carriage return is the documented way a workflow command dies in GitHub's parser, and the surviving
# prefix is what that failure looks like; whichever mechanism it was, this script removes the
# exposure by escaping every line and by choosing cause over position. A dropped line is silent, so
# the reader sees a confident excerpt of the wrong part of the log — worse than no excerpt, because
# it reads as an answer.
#
# ### Contract
# stdout = the annotation commands, one per line. Each is percent-encoded (`%`→`%25`), flattened to
# one line, capped at --max-chars. What gets chosen: the lines that name a cause (--pattern,
# order-preserving dedupe, last --max of them). A log with no such line publishes the last `phase=`
# marker it carries and then --tail lines of tail — a tail is a fallback, never the primary answer.
# Exit status is always 0 on the publish path: this publishes, it does not judge, and the caller
# keeps its own verdict.
#
# ### Gate
# `--selftest` is byte-exact and runs in `make audit` (mirrored on ubuntu). Red means one of the two
# properties this script exists for broke — a special character ate a line, or the cause line lost
# to the tail. Both are the failure the six reds were sampled against; the reader whose action it
# changes is whoever has to diagnose a red leg without a token.
#
# Usage: ci-annotate.sh [--level error|warning|notice] [--max N] [--tail N] [--max-chars N]
#                       [--pattern ERE] [--exclude ERE] [--selftest] [FILE|-]
set -uo pipefail

LEVEL=error
MAX=12
TAIL=6
MAX_CHARS=300
PATTERN='error:|Error:|❌|Fatal error|error while|no usable|not found|No such file|No space left|Killed|command not found|Segmentation fault|abort|Traceback|exit code [1-9]|has no member|cannot find'
EXCLUDE=''
FILE=''
SELFTEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --level) LEVEL="${2:-error}"; shift 2 ;;
    --max) MAX="${2:-12}"; shift 2 ;;
    --tail) TAIL="${2:-6}"; shift 2 ;;
    --max-chars) MAX_CHARS="${2:-300}"; shift 2 ;;
    --pattern) PATTERN="${2:-}"; shift 2 ;;
    --exclude) EXCLUDE="${2:-}"; shift 2 ;;
    --selftest) SELFTEST=1; shift ;;
    -) FILE="-"; shift ;;
    -*) printf 'ci-annotate: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *) FILE="$1"; shift ;;
  esac
done

PASS=0
FAIL=0
expect() {
  # expect <name> <needle> <haystack>   (needle must appear)
  case "$3" in
    *"$2"*) PASS=$(( PASS + 1 )) ;;
    *) FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n  expected to contain: %s\n  got: %s\n' "$1" "$2" "$3" ;;
  esac
}
refuse() {
  # refuse <name> <needle> <haystack>   (needle must NOT appear)
  case "$3" in
    *"$2"*) FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n  expected absent: %s\n  got: %s\n' "$1" "$2" "$3" ;;
    *) PASS=$(( PASS + 1 )) ;;
  esac
}

if [ "$SELFTEST" = 1 ]; then
  tmp="$(mktemp -d)"
  # A log whose cause is 40 lines above the end, carrying every character class that ate a line
  # on the runner: a bare `%`, a carriage return, a duplicate, and a line no human reads whole.
  {
    i=0
    while [ $i -lt 40 ]; do printf 'warning: noisy progress line %d\n' "$i"; i=$(( i + 1 )); done
    printf 'error: cannot find -loxgen (linker exit code 1) 100%% done\n'
    printf 'error: cannot find -loxgen (linker exit code 1) 100%% done\n'
    printf 'error: swift-frontend died\r mid-diagnostic (a CR ends a workflow command)\n'
    printf 'error: overlong diagnostic '; printf 'x%.0s' $(seq 1 500); printf '\n'
    printf 'warning: the tail must not win\n'
  } > "$tmp/cause.log"
  out="$(bash "$0" --level error "$tmp/cause.log")"
  expect "cause-line-not-eaten-by-tail" "::error::  error: cannot find -loxgen" "$out"
  expect "percent-escaped" "100%25 done" "$out"
  refuse "raw-percent-survives" "100% done" "$out"
  expect "long-line-clipped" "[+" "$out"
  expect "carriage-return-stripped-not-split" "died mid-diagnostic" "$out"
  # Duplicate cause → one annotation. `printf '%s\n' | awk '!seen[$0]++'` is the order-preserving
  # dedupe; a second copy means the dedupe was replaced by a plain grep.
  dup_count="$(printf '%s\n' "$out" | grep -c 'cannot find -loxgen')"
  [ "$dup_count" = 1 ] && PASS=$(( PASS + 1 )) \
    || { FAIL=$(( FAIL + 1 )); printf 'FAIL duplicate-cause-deduped — emitted %s copies, expected 1\n' "$dup_count"; }

  # No cause anywhere: the phase marker is the answer, and it says the failing command was silent.
  { printf 'phase=build-app\n'; printf 'warning: nothing names itself\n'; } > "$tmp/quiet.log"
  quiet="$(bash "$0" --level error "$tmp/quiet.log")"
  expect "phase-marker-is-the-fallback" "phase=build-app" "$quiet"

  # Missing log: the annotation says the evidence is absent, and stays silent about the failure.
  gone="$(bash "$0" --level error "$tmp/nope.log")"
  expect "missing-log-says-so" "the log this step meant to publish is missing" "$gone"
  refuse "missing-log-invents-a-cause" "cannot find" "$gone"

  printf 'ci-annotate --selftest: %d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" = 0 ] || exit 1
  exit 0
fi

emit() {
  # CR first (a CR ends a workflow command), then `%` — escaped before anything else is added, so the
  # escape vocabulary cannot be double-encoded. awk cuts by character, so a multi-byte arrow in a
  # compiler diagnostic cannot be sliced in half into mojibake.
  printf '%s\n' "$1" \
    | tr -d '\r' \
    | sed 's/%/%25/g' \
    | awk -v n="$MAX_CHARS" '{ if (length($0) > n) printf "%s…[+%d chars]\n", substr($0, 1, n), length($0) - n; else print }' \
    | sed "s|^|::${LEVEL}::  |"
}

if [ "$FILE" = "-" ]; then
  tmp_in="$(mktemp)"
  cat > "$tmp_in"
  FILE="$tmp_in"
fi

if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  emit "the log this step meant to publish is missing (FILE unset or absent) — nothing in this annotation is evidence about the failure"
  exit 0
fi

picks="$(grep -E "$PATTERN" "$FILE" 2>/dev/null \
          | { if [ -n "$EXCLUDE" ]; then grep -Ev "$EXCLUDE" || true; else cat; fi } \
          | awk '!seen[$0]++' | tail -n "$MAX")"

if [ -n "$picks" ]; then
  printf '%s\n' "$picks" | while IFS= read -r line; do emit "$line"; done
  exit 0
fi

phase="$(grep -E '^phase=' "$FILE" 2>/dev/null | tail -1)"
[ -n "$phase" ] && emit "$phase — no error line in the log after this phase started (the command that failed printed nothing)"
tail -n "$TAIL" "$FILE" | while IFS= read -r line; do emit "$line"; done
exit 0
