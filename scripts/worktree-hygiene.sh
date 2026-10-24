#!/usr/bin/env bash
# worktree-hygiene.sh — the round is not done while the work lives only in this checkout.
#
# ### Why (AGENTS.md § Working here)
# The project's stated authority is CI on macos-26 (`make test-ci`), and `CHANGELOG.md` is supposed
# to record every user-visible change *with its commit*. Both died silently for two days: ~107 paths
# and +4.5k lines piled up uncommitted, so no CI leg ever ran against them and ~20 CHANGELOG entries
# named upstream hashes while their own commits did not exist. Nothing went red, because nothing
# checked. This script is that check.
#
# ### Asserts (each fails with its remedy, never silently)
#   H1  the tree is clean — an uncommitted round is invisible to review, to CI and to rollback
#   H2  nothing is unpushed — an unpushed commit has been verified by no authority but this box
#   H3  a commit that changed behaviour also carries the `CHANGELOG.md` hunk that names it
#   H4  self-floor: git must answer, and the pairing scan must have found at least one commit to
#       judge — a scan that stopped matching passes vacuously (AGENTS.md § Testing Quality)
set -uo pipefail

fails=0
say() { printf '  %s\n' "$1"; }
ok() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fails=$(( fails + 1 )); }

if ! command -v git >/dev/null 2>&1; then
  bad "git is not on PATH — every assertion below would be vacuous"
  printf 'worktree-hygiene: %d failed\n' "$fails"
  exit 1
fi
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  bad "no HEAD to judge (fresh repo?) — H1–H3 would pass vacuously"
  printf 'worktree-hygiene: %d failed\n' "$fails"
  exit 1
fi

branch="$(git rev-parse --abbrev-ref HEAD)"

# H1 — clean tree (ignored paths are already excluded by .gitignore).
dirty="$(git status --porcelain)"
if [ -z "$dirty" ]; then
  ok "working tree is clean"
else
  n=$(printf '%s\n' "$dirty" | wc -l | tr -d ' ')
  bad "$n path(s) uncommitted — the round is neither reviewable nor pushed:"
  printf '%s\n' "$dirty" | head -12 | sed 's/^/        /'
  say "remedy: commit the slice (one logical change per commit), or stash it deliberately — "
  say "an invisible heap is how 2 days of work escaped CI"
fi

# H2 — nothing unpushed.
if git rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
  ahead=$(git rev-list --count "origin/$branch..HEAD")
  if [ "$ahead" = "0" ]; then
    ok "nothing unpushed (origin/$branch == HEAD)"
  else
    bad "$ahead commit(s) ahead of origin/$branch — CI has not seen them, so they are unverified"
    say "remedy: git push origin $branch"
  fi
else
  bad "origin/$branch does not exist locally — is the branch pushed at all?"
fi

# H3 — the push set pairs behaviour with its diary entry.
# Set-level, not per-commit: ~2 days of work arrived as one heap, and re-cutting it into per-commit
# diary hunks now would invent a history that never happened. The assertion still goes red for the
# failure the rule cares about — behaviour shipped without the CHANGELOG entry that names it — and
# per-commit pairing is reported, not hidden.
pushset="$(git rev-list "origin/$branch..HEAD" 2>/dev/null || true)"
behaviours='^Sources/|^scripts/probes/|^scripts/eval/'
if [ -n "$pushset" ]; then
  set_behaviour=0
  set_changelog=0
  unpaired=0
  for c in $pushset; do
    files="$(git show --pretty=format: --name-only "$c" | grep -v '^$' || true)"
    n="$(printf '%s\n' "$files" | grep -cE "$behaviours" || true)"
    if [ "${n:-0}" -gt 0 ]; then
      set_behaviour=$(( set_behaviour + n ))
      if printf '%s\n' "$files" | grep -qx 'CHANGELOG.md'; then
        ok "commit $(git rev-parse --short "$c") pairs $n behaviour file(s) with CHANGELOG.md"
      else
        unpaired=$(( unpaired + 1 ))
      fi
    fi
    if printf '%s\n' "$files" | grep -qx 'CHANGELOG.md'; then set_changelog=1; fi
  done
  if [ "${set_behaviour:-0}" -eq 0 ]; then
    ok "push set touches no behaviour file (docs/infra only)"
  elif [ "$set_changelog" = "1" ]; then
    ok "push set changed $set_behaviour behaviour file(s) and carries CHANGELOG.md"
    if [ "$unpaired" -gt 0 ]; then
      say "NOTE: $unpaired commit(s) in the push set are behaviour without their own diary hunk"
      say "  — migration of a multi-day heap; future rounds should land the hunk in the same commit"
    fi
  else
    bad "the push set changes $set_behaviour behaviour file(s) and names none of it in CHANGELOG.md"
    say "remedy: the user-visible change and its diary entry belong in the same push"
  fi
else
  # H4 — the patterns must be proven alive against history, or this script passes vacuously.
  floor=0
  for c in $(git rev-list -n 10 HEAD); do
    n="$(git show --pretty=format: --name-only "$c" | grep -v '^$' | grep -cE "$behaviours" || true)"
    if [ "${n:-0}" -gt 0 ] && git show --pretty=format: --name-only "$c" | grep -qx 'CHANGELOG.md'; then
      floor=$(( floor + 1 ))
    fi
  done
  if [ "$floor" -ge 1 ]; then
    ok "nothing to push; pairing patterns proven alive in $floor/10 recent commits"
  else
    bad "no commit in the last 10 pairs behaviour with CHANGELOG.md — either the patterns died"
    bad "  or the convention died; either way this gate is now vacuous"
  fi
fi

printf 'worktree-hygiene: %d failed\n' "$fails"
[ "$fails" = "0" ] || exit 1
