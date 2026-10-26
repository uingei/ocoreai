#!/usr/bin/env bash
# ci-status.sh — what did the declared authority actually conclude for a commit?
#
# ### Why this exists (10-26)
# AGENTS.md § Build / Test / Lint names CI on macos-26 the authority, and worktree-hygiene says an
# unseen commit is unverified. Neither sentence was checkable from a terminal, so `Static Audit`
# failing on a formatter pin — which left Build & Test, App Store and iOS all `skipped` — ran ~90
# pushes without anyone local knowing. A claim you cannot ask about is a claim you are hoping.
#
# ### Contract (exit codes carry the epistemic state, AGENTS.md § Hub Reachability)
#   0  every leg that must run on a main push concluded success
#   1  a leg failed, or a leg that must run was skipped (skipped != verified)
#   2  COULD NOT ASK: no network, rate-limited, or no check-runs returned. Never reported as green.
set -uo pipefail

sha="${1:-$(git rev-parse origin/main 2>/dev/null)}"
url="${1:-}"
if [ -z "$url" ]; then url="$(git remote get-url origin 2>/dev/null)"; fi
repo="$(printf '%s' "$url" | sed -E 's#^.*(github\.com[:/])##; s#\.git$##')"
[ -n "$repo" ] && [ -n "$sha" ] || { echo "❌ cannot derive owner/repo and SHA (origin remote?)"; exit 2; }

api="https://api.github.com/repos/${repo}/commits/${sha}/check-runs?per_page=100"
code=$(curl -s -m 20 -o /tmp/ocoreai-ci-status.json -w '%{http_code}' "$api" 2>/dev/null)
case "$code" in
  200) : ;;
  403|429) echo "❌ api.github.com rate-limited (HTTP $code) — unauthenticated is 60 req/h; pass a token"; exit 2 ;;
  000)   echo "❌ api.github.com unreachable from this box — CI verdict is UNKNOWN, not green"; exit 2 ;;
  *)     echo "❌ api.github.com answered HTTP $code — CI verdict is UNKNOWN, not green"; exit 2 ;;
esac

python3 - "$sha" "$repo" <<'PY'
import json, sys
sha, repo = sys.argv[1], sys.argv[2]
try:
    runs = json.load(open("/tmp/ocoreai-ci-status.json")).get("check_runs", [])
except Exception as exc:
    print("❌ could not parse the check-run list (%s) — verdict UNKNOWN" % exc); raise SystemExit(2)
if not runs:
    print("❌ no check-runs for %s@%s — CI has not seen this commit, or the scan rotted"
          % (repo, sha[:7])); raise SystemExit(2)

# Skippable by design: the DMG leg exists only for a tag push.
SKIPPABLE = ("Release DMG",)
bad, unknown = [], 0
for r in sorted(runs, key=lambda r: r.get("name", "")):
    name, concl = r.get("name", "?"), r.get("conclusion")
    print("  %-42s %s" % (name[:42], concl or r.get("status")))
    if concl == "success":
        continue
    if concl == "skipped" and any(name.startswith(s) for s in SKIPPABLE):
        continue
    if concl is None or concl in ("queued", "in_progress", "pending", "action_required"):
        unknown += 1
    else:
        bad.append("%s=%s" % (name, concl))
if unknown:
    print("ci-status: %d leg(s) still running — verdict pending, not green" % unknown)
    raise SystemExit(2)
if bad:
    print("ci-status: AUTHORITY NOT GREEN — %s" % ", ".join(bad))
    raise SystemExit(1)
print("ci-status: every leg that must run on a main push is green")
raise SystemExit(0)
PY
