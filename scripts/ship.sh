#!/usr/bin/env bash
# ship.sh — cut the next release tag for the ci.yml `v*` leg; publish stays CI's, push stays human's.
#
# Cadence is the open item (long-horizon-goal § Rung 1): the machinery proved green at v0.1.16, and the
# only link never scripted was "after merges land, someone bumps the number and tags it". Field shapes:
# ollama/codex push tags by hand; goose's machine opens a version-bump PR. This is the goose shape minus
# the PR ritual (root: no branch ritual): the machine does everything local and refuses loudly; the one
# outward verb (push) needs SHIP_PUSH=1 or the operator's own keyboard.
# Next-version decision has its one home here; version.sh stays the read-side home (tag -> build version),
# untouched. minor/major is an owner call: override with OCOREAI_SHIP_VERSION=vX.Y.Z.
set -euo pipefail

die() { echo "ship: $*" >&2; exit 1; }

[ -z "$(git status --porcelain)" ] || die "tree dirty — commit this session's files first (never a half-built tag)"
head_now="$(git rev-parse HEAD)"
remote_now="$(git rev-parse origin/main)"
[ "$head_now" = "$remote_now" ] || die "HEAD ($(git rev-parse --short HEAD)) != origin/main — push the merges first; the tag must point at what CI can check out"

remote_tag="$(git ls-remote --tags origin | awk '{print $2}' | sed 's|refs/tags/||' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
[ -n "$remote_tag" ] || die "no vX.Y.Z tag on origin — the ladder has no bottom rung"

next="${OCOREAI_SHIP_VERSION:-}"
if [ -z "$next" ]; then
    IFS=. read -r maj min pat <<<"${remote_tag#v}"
    next="v${maj}.${min}.$(( pat + 1 ))"   # cadence default: every merge spends a patch tag (§ Adoption)
fi
[[ "$next" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "OCOREAI_SHIP_VERSION must be vX.Y.Z, got '$next'"

if git ls-remote --tags origin "refs/tags/${next}" | grep -q .; then
    die "${next} already exists on origin — a withdrawn release's number does not come back; bump again"
fi
git rev-parse -q --verify "refs/tags/${next}" >/dev/null \
    && die "local ${next} exists but remote does not — a stale local tag (v0.1.14/v0.1.15 shape); delete it or override"

echo "shipping: ${remote_tag} -> ${next} @ $(git rev-parse --short HEAD)"
bash scripts/release-notes.sh "$remote_tag" || true   # machine-compiled notes (OpenHands shape, runbook § install machine)

git tag -a "$next" -m "release ${next}" HEAD
echo "tagged ${next} locally; nothing left the machine."
if [ "${SHIP_PUSH:-0}" = "1" ]; then
    git push origin "refs/tags/${next}"
    echo "pushed — the ci.yml tag leg now owns build+publish (ten-step job, read-back sha-parity)."
else
    echo "next step (operator's window):  git push origin refs/tags/${next}"
fi
