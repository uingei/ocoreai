#!/usr/bin/env bash
# Every documented remediation target must at least PARSE.
#
# `make format` — the target `make format-check` tells you to run to accept a reformat — had
# never been executable: its awk program was single-quoted and contained an apostrophe, so the
# shell lost the quote and the recipe died before the formatter started. A gate whose stated fix
# cannot run is a gate with no exit, and nothing but execution ever said so.
#
# Method: expand each recipe with `make -n` (no commands run) and let bash parse it. The scan
# floors its own hit count, so a Makefile whose targets stopped matching fails instead of
# passing vacuously.
#
# A verdict about text is a verdict about the tool that produced the text: macOS ships GNU Make
# 3.81 and bash 3.2, an ubuntu runner ships 4.3 and 5.1, and this leg went red on the runner while
# green on both a macOS host and a fresh macOS clone. So the report names its toolchain, and a red
# names the targets in the step summary — a red nobody can read is a red nobody can act on.
set -uo pipefail

MAKEFILE="${1:-Makefile}"
FLOOR="${MAKEFILE_PARSE_FLOOR:-20}"
[ -f "$MAKEFILE" ] || { echo "makefile-parse-check: no Makefile at $MAKEFILE"; exit 1; }
HOST_LABEL="make=$(make --version 2>/dev/null | head -1 | awk '{print $3}') bash=${BASH_VERSION%% *}"

# A target starts at column 0 (recipes start with a TAB) and its name ends at the colon, so a
# variable like `SF_PIN := 603.0.0` cannot match — the space before the colon is the tell.
targets=$(awk '/^[A-Za-z][A-Za-z0-9_.-]*:/ { sub(/:.*/, ""); print }' "$MAKEFILE" | sort -u)
count=0
failed=0
fail_names=""
fail_detail=""
# `$(printf '\n')` is empty — command substitution strips trailing newlines — so the separator lives
# in a variable instead.
NL=$'\n'
for t in $targets; do
  count=$((count + 1))
  expanded=$(make -n -f "$MAKEFILE" "$t" 2>/dev/null)
  [ -n "$expanded" ] || continue
  if ! err=$(printf '%s\n' "$expanded" | bash -n 2>&1); then
    echo "  FAIL target '$t': its recipe does not parse"
    printf '%s\n' "$err" | sed 's/^/         /' | head -3
    fail_names="$fail_names $t"
    fail_detail="${fail_detail}[${t}]${NL}$(printf '%s\n' "$err" | head -3)${NL}"
    failed=$((failed + 1))
  fi
done

if [ "$count" -lt "$FLOOR" ]; then
  echo "makefile-parse-check: only $count target(s) parsed (floor $FLOOR) — a scan that stopped matching passes vacuously"
  exit 1
fi
if [ "$failed" -ne 0 ]; then
  echo "makefile-parse-check: $failed target recipe(s) cannot be parsed by bash ($HOST_LABEL)"
  # One annotation line, because a runner log needs a token to open and this leg's first red did.
  echo "::error::makefile parse: $failed target(s) fail bash -n ($HOST_LABEL):${fail_names}"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    { printf '### makefile parse — `%s` (%s)\n\n' "$MAKEFILE" "$HOST_LABEL"
      echo 'Expansion of these recipes is not parseable by the runner bash:'
      echo '```'
      printf '%s\n' "$fail_detail"
      echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 1
fi
echo "makefile-parse-check: $count target recipe(s) parse ($HOST_LABEL, floor $FLOOR)"
