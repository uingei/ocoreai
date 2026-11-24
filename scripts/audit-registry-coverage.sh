#!/usr/bin/env bash
# Does the comparator registry still answer for every clone on disk?
#
# Sampled red 11-25: `~/references/mlx` arrived 11-23 and no round noticed, while the same sweep's
# naive one-name-per-bullet regex reported `coreai-models` as a hole (its row shares a bullet with
# `mlx-swift-lm`, comparator-repos.md) - a false positive beside a false negative in one run.
# Reader whose action this red changes: the round that re-derives the corpus (`references-problem-map.md`
# § Corpus at HEAD), which otherwise treats registry silence as absence.
set -uo pipefail

REG="${1:-docs/agent/comparator-repos.md}"
REFS="${OCOREAI_REFERENCES:-$HOME/references}"

# A row name is a disk tree whose name appears backticked on a bullet's first line. Multi-name
# bullets count for every name they carry; `coreai-models/skills/...` never matches, since only a
# bare name in backticks is a row.
disk=$(ls "$REFS" 2>/dev/null | LC_ALL=C sort -u)
rows=$(grep -h '^[-] ' "$REG" | grep -o '`[A-Za-z0-9._-]*`' | tr -d '`' | LC_ALL=C sort -u)

disk_n=$(printf '%s\n' "$disk" | grep -c . || true)
row_n=$(printf '%s\n' "$rows" | grep -c . || true)

# The instrument floors itself: a registry that yields fewer names than this has stopped matching,
# and an empty scan must not pass as coverage (root § Two invariants 1).
if [ "$row_n" -lt 50 ]; then
  echo "registry-coverage: INSTRUMENT BROKEN - only $row_n candidate row names extracted from $REG"
  exit 1
fi

covered=$(LC_ALL=C comm -12 <(printf '%s\n' "$rows") <(printf '%s\n' "$disk") | grep -c . || true)
if [ "$covered" -lt 50 ]; then
  echo "registry-coverage: INSTRUMENT BROKEN - only $covered of $disk_n clones matched a row name"
  exit 1
fi

holes=$(LC_ALL=C comm -13 <(printf '%s\n' "$rows") <(printf '%s\n' "$disk"))
orphans=$(LC_ALL=C comm -23 <(printf '%s\n' "$rows") <(printf '%s\n' "$disk"))

echo "registry-coverage: disk=$disk_n row_names=$row_n covered=$covered"
if [ -n "$holes" ]; then
  echo "on disk with no registry row:"
  printf '  %s\n' $holes
fi
# A row name with no clone is not a defect: a pin's checkout lives under Libraries/, not ~/references.
[ -n "$orphans" ] && echo "note, row names with no clone under $REFS: $(printf '%s ' $orphans)"

[ -z "$holes" ] || exit 1
echo "registry-coverage: OK, every clone on disk carries a row"
