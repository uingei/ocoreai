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
#
# OCOREAI_CI_REDS=1 additionally reads the annotations of every GREEN leg and prints the reds that
# `continue-on-error` swallowed there — one API call per leg, so it stays opt-in.
set -uo pipefail

# $1 is a commit (short or full) OR a remote URL, never one value used as both: a SHA handed to
# the URL branch silently produced owner/repo="9c4d434" and a 404 that read as "verdict UNKNOWN",
# which is the wrong remedy for a wrong argument.
arg="${1:-}"
url="$(git remote get-url origin 2>/dev/null)"
if [ -n "$arg" ] && ! printf '%s' "$arg" | grep -qE '^[0-9a-fA-F]{7,40}$'; then
  url="$arg"
  arg=""
fi
if [ -n "$arg" ]; then
  sha="$(git rev-parse --verify --quiet "${arg}^{commit}" || printf '%s' "$arg")"
else
  sha="$(git rev-parse --verify --quiet origin/main)"
fi
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
import json, os, re, sys, urllib.request
sha, repo = sys.argv[1], sys.argv[2]
try:
    runs = json.load(open("/tmp/ocoreai-ci-status.json")).get("check_runs", [])
except Exception as exc:
    print("❌ could not parse the check-run list (%s) — verdict UNKNOWN" % exc); raise SystemExit(2)
if not runs:
    print("❌ no check-runs for %s@%s — CI has not seen this commit, or the scan rotted"
          % (repo, sha[:7])); raise SystemExit(2)

# Skippable by design: the DMG leg exists only for a tag push.
def step_seconds(st):
    import datetime
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    try:
        return int((datetime.datetime.strptime(st["completed_at"], fmt)
                    - datetime.datetime.strptime(st["started_at"], fmt)).total_seconds())
    except Exception:
        return "?"


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
# A green leg can swallow a red: a step with `continue-on-error` concludes success while its own
# annotation says failure, which is how a step that had never produced an artefact sat failing on
# every run of the authority leg. Opt-in because the price is one call per green leg.
if os.environ.get("OCOREAI_CI_REDS", "").lower() in ("1", "true", "yes"):
    swallowed = 0
    for r in runs:
        if r.get("conclusion") != "success":
            continue
        try:
            with urllib.request.urlopen(r["url"] + "/annotations", timeout=20) as resp:
                ann = json.load(resp)
        except Exception as exc:
            print("  %s: annotations unreadable (%s)" % (r.get("name"), type(exc).__name__))
            continue
        ann = ann.get("annotations", []) if isinstance(ann, dict) else ann
        reds = [a for a in ann if a.get("annotation_level") == "failure"]
        if reds:
            swallowed += len(reds)
            print("  %s: %d swallowed red(s) behind a GREEN leg — %s"
                  % (r.get("name"), len(reds), (reds[0].get("message") or "")[:110].replace("\n", " ")))
    print("  swallowed reds on green legs: %d (0 is the only honest number)" % swallowed)

if unknown:
    print("ci-status: %d leg(s) still running — verdict pending, not green" % unknown)
    raise SystemExit(2)
if bad:
    print("ci-status: AUTHORITY NOT GREEN — %s" % ", ".join(bad))
    # A red leg whose cause needs a token is a red leg nobody fixes. The check-run's details_url
    # carries the job id, and /actions/jobs/{id} is readable unauthenticated: it answers which
    # STEP decided the verdict and how long it took, which is how the 10-28 smoke stall was found
    # ("timed out after 10 minutes" named nothing; the step list named the 607 s step).
    for r in runs:
        if r.get("conclusion") not in ("failure", "cancelled", "timed_out"):
            continue
        m = re.search(r"/actions/runs/(\d+)/job/(\d+)", r.get("details_url") or "")
        if not m:
            continue
        try:
            with urllib.request.urlopen(
                    "https://api.github.com/repos/%s/actions/jobs/%s" % (repo, m.group(2)),
                    timeout=20) as resp:
                job = json.load(resp)
        except Exception as exc:
            print("  (%s: step detail unavailable — %s)" % (r.get("name"), type(exc).__name__))
            continue
        print("  steps of %s that did not pass:" % r.get("name"))
        for st in job.get("steps", []):
            if st.get("conclusion") in ("success", None):
                continue
            print("    %-44s %-10s %ss" % ((st.get("name") or "?")[:44], st.get("conclusion"),
                                           step_seconds(st)))
    raise SystemExit(1)
print("ci-status: every leg that must run on a main push is green")
raise SystemExit(0)
PY
