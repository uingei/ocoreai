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
set -uo pipefail

MAKEFILE="${1:-Makefile}"
FLOOR="${MAKEFILE_PARSE_FLOOR:-20}"
[ -f "$MAKEFILE" ] || { echo "makefile-parse-check: no Makefile at $MAKEFILE"; exit 1; }

# A target starts at column 0 (recipes start with a TAB) and its name ends at the colon, so a
# variable like `SF_PIN := 603.0.0` cannot match — the space before the colon is the tell.
targets=$(awk '/^[A-Za-z][A-Za-z0-9_.-]*:/ { sub(/:.*/, ""); print }' "$MAKEFILE" | sort -u)
count=0
failed=0
for t in $targets; do
  count=$((count + 1))
  expanded=$(make -n -f "$MAKEFILE" "$t" 2>/dev/null)
  [ -n "$expanded" ] || continue
  if ! printf '%s\n' "$expanded" | bash -n 2>/dev/null; then
    echo "  FAIL target '$t': its recipe does not parse"
    printf '%s\n' "$expanded" | bash -n 2>&1 | sed 's/^/         /' | head -3
    failed=$((failed + 1))
  fi
done

if [ "$count" -lt "$FLOOR" ]; then
  echo "makefile-parse-check: only $count target(s) parsed (floor $FLOOR) — a scan that stopped matching passes vacuously"
  exit 1
fi
if [ "$failed" -ne 0 ]; then
  echo "makefile-parse-check: $failed target recipe(s) cannot be parsed by bash"
  exit 1
fi
echo "makefile-parse-check: $count target recipe(s) parse (floor $FLOOR)"
