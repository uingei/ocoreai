#!/usr/bin/env bash
# Outbound links in the docs must resolve. vllm and sglang run `lychee` for this; this is the same
# lock at the rung this repo can maintain (no new tool, no pin to chase), probed in parallel so it
# costs seconds and nobody is tempted to mute it.
#
# It exists because the failure was observed, not imagined: measuring our own docs on 10-27 found
# 2 of 29 outbound URLs dead — README.md and README.zh.md both pointed at `github.com/omlx-ai/omlx`
# (the tree is `jundot/omlx`) and `github.com/steipete/clawd` (it is `openclaw/openclaw`), in the
# human-facing front door where a reader clicks.
#
# What is red, and why (measured on this host the day the gate was written, not theorised):
#   -L is followed, so a moved repo stays green (opencode went sst -> anomalyco; the reader lands).
#   a final 4xx is RED — a repo that does not exist, or a path that was deleted.
#   MOST URLs UNANSWERED IS ALSO RED. An earlier version reported transport errors and passed; it
#   then ran against a throttled github.com, got no answer for 18 of 28 URLs — including the two
#   links this gate exists to catch — and printed green. "Could not ask" is never a pass and never
#   a silence either (the same rule scripts/ci-status.sh applies to CI).
#   a handful of stragglers out of a healthy run is REPORTED, not red: huggingface.co and
#   img.shields.io fail from this host under curl and load in a browser.
#
# Not in `make round-gates` — that set runs offline by design. CI runs it in the ubuntu governance
# job; `make links` is the local invocation and needs egress.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FLOOR="${OCOREAI_LINK_FLOOR:-20}"       # premise floor: a scan that stopped matching passes vacuously
TIMEOUT="${OCOREAI_LINK_TIMEOUT:-10}"
LOOPBACK_RE='^https?://(127\.0\.0\.1|localhost|0\.0\.0\.0|192\.168\.[0-9]+\.[0-9]+)'

ALL="$(git ls-files '*.md' | xargs grep -ohE 'https?://[A-Za-z0-9._/:%#?=&+-]+' 2>/dev/null \
       | sed 's/[).,`>"]*$//' | sort -u)"
URLS=(); skipped=0
while IFS= read -r u; do
  [ -n "$u" ] || continue
  if [[ "$u" =~ $LOOPBACK_RE ]]; then skipped=$(( skipped + 1 )); continue; fi
  URLS+=("$u")
done <<< "$ALL"
checked=${#URLS[@]}

# One probe per URL, in flight together (the set is ~30; this is not a fork bomb). Each worker
# writes "<code> <url>" so the aggregation never depends on output ORDER — with -P there is none.
# bash 3.2 has no wait -n, so the batch size is the concurrency limit.
TMP="$(mktemp -t ocoreai-links-XXXXXX)"
BATCH="${OCOREAI_LINK_PARALLEL:-1}"  # serial is the measured setting: 3 connections to github.com in
            # parallel got 13/28 answers here, and 8 got 10/28. Self-inflicted throttling turns a
            # link gate into a noise gate, so the cheap safe answer is one request at a time.
i=0
for u in ${URLS[@]+"${URLS[@]}"}; do
  # A failed request makes curl print `000` ITSELF, so there is no `|| echo 000`: that fallback
  # appends a second code and the line stops parsing. Take the first three characters, and map
  # anything that is not three digits to 000.
  ( c="$(curl -s -o /dev/null -w '%{http_code}' --http1.1 -L --retry 1 --max-time "$TIMEOUT" "$u" 2>/dev/null)"
    c="${c:0:3}"
    case "$c" in ''|*[!0-9]*) c=000 ;; esac; [ ${#c} -gt 3 ] && c="${c:0:3}"
    printf '%s %s\n' "$c" "$u" >> "$TMP" ) &
  i=$(( i + 1 ))
  (( i % BATCH == 0 )) && wait
done
wait
OUT="$(cat "$TMP" 2>/dev/null)"; rm -f "$TMP"

# The premise is the PROBE, not the extraction: a scanner that ran nothing must not report green.
probed=$(printf '%s\n' "$OUT" | grep -c '^[0-9]\{3\} ' || true)
if (( probed != checked )); then
  echo "::error::failed step: link check — extracted ${checked} URL(s) but only ${probed} returned a status; the probe did not run, which is never a pass"
  exit 1
fi

DEAD="$(printf '%s\n' "$OUT" | awk '$1 ~ /^4/ {print "  X " $1 " " $2}')"
FLAKY="$(printf '%s\n' "$OUT" | awk '$1 == "000" || $1 ~ /^5/ {print "  ~ " ($1 == "000" ? "no-response" : $1) " " $2}')"
ndead=$(printf '%s\n' "$DEAD" | grep -c '  X ' || true)
nflaky=$(printf '%s\n' "$FLAKY" | grep -c '  ~ ' || true)

RESOLVED=$(( checked - nflaky ))
echo "link-check: ${checked} outbound URL(s) checked, ${skipped} loopback example(s) skipped, ${ndead} dead, ${nflaky} unresolved (${RESOLVED} answered; floor ${FLOOR})"
if (( checked < FLOOR )); then
  echo "::error::failed step: link check — the scan matched only ${checked} URL(s) (< ${FLOOR}); a regex that stopped matching would pass vacuously"
  exit 1
fi
if (( ndead > 0 )); then
  printf '%s\n' "$DEAD"
  echo "::error::failed step: link check — ${ndead} doc link(s) return 4xx. Fix the citation; do not delete the reference."
  exit 1
fi
# An unanswered run proves nothing: below the resolution floor this is red, not green.
if (( checked >= 10 && RESOLVED * 10 < checked * 8 )); then
  printf '%s\n' "$FLAKY"
  echo "::error::failed step: link check — only ${RESOLVED}/${checked} URL(s) answered, so nothing was verified (could not ask is not a pass)"
  exit 1
fi
[ "$nflaky" -gt 0 ] && printf '%s\n' "$FLAKY"
echo "✅ link gate: every outbound doc link resolves"
