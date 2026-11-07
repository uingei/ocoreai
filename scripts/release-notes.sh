#!/usr/bin/env bash
# Render the release-note delta section from CHANGELOG heading lines added since the previous tag.
# Upstream's answer, not a local invention: OpenHands' notes are machine-compiled (its own note header
# says so) and vllm's quote commit counts automatically — a cadence of 1 270 releases is only payable
# when nobody writes per-version prose by hand. Our headings are already three-question one-liners, so
# this is a rendering, not a second home for claims (same pattern as /openapi.json rendering off the
# capabilities index). A reworded heading appears once per release that touched it: tolerated, rare.
set -euo pipefail
prev="${1:-$(git tag --sort=-v:refname | sed -n 2p)}"
if [ -z "${prev}" ]; then
  echo "First tagged release — the full engineering diary is CHANGELOG.md."
  exit 0
fi
out="$(git diff "${prev}..HEAD" -- CHANGELOG.md | grep -E '^\+\*\*[0-9]{2}-[0-9]{2} ' \
      | sed -E 's/^\+\*\*//; s/\*\*$//' || true)"
[ -n "${out}" ] || exit 0
echo "What landed since ${prev}:"
echo ""
echo "${out}" | sed 's/^/- /'
