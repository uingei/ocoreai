#!/usr/bin/env bash
# Re-runnable ocoreai audit fact-sheet — machine-checkable facts only.
# Every audit claim must be backed by a line from this output or an equivalent grep.
# Usage: bash scripts/audit-facts.sh [commit-sha]  (sha → CI check-run conclusions)
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
echo "HEAD=$(git rev-parse --short HEAD) origin/main=$(git rev-parse --short origin/main) dirty=$(git status --short | wc -l | tr -d ' ')"
[ -f .upstream-baseline.json ] && echo "--- upstream baseline ---" && cat .upstream-baseline.json
echo "--- pins (Package.swift) ---"; grep -nE "revision:|exact:" Package.swift
echo "--- toolchain contract (the platform premise the gates assume) ---"
bash scripts/toolchain-contract.sh report
[ -n "${OCOREAI_AUDIT_STRICT:-}" ] && bash scripts/toolchain-contract.sh check
echo "--- gates (Makefile) ---"; grep -n "test-ci\|build-for-testing\|workspace\|scheme" Makefile | head -8
echo "--- test targets ---"; grep -c testTarget Package.swift
echo "--- release surface ---"
grep -rcE "notariz|notarytool" .github/workflows/*.yml scripts/*.sh 2>/dev/null | grep -v ":0$" || echo "notarization: 0 sites"
grep -nE "codesign .* -s -" scripts/*.sh .github/workflows/*.yml 2>/dev/null | head -6
echo "--- auto-update ---"
grep -rln "Sparkle\|SUUpdater\|checkForUpdate\|selfUpdate" Sources/ 2>/dev/null || echo "auto-update: 0 sites"
echo "--- OS cliff ---"; grep -rc "#available(macOS 27" Sources/ -r | awk -F: '{s+=$2} END{print "macOS27-gate sites:", s+0}'
echo "--- platform gates ---"
echo "os(iOS) src files: $(grep -rl 'os(iOS)' Sources/ | wc -l | tr -d ' ') | os(iOS) test files: $(grep -rl 'os(iOS)' Tests/ 2>/dev/null | wc -l | tr -d ' ')"
grep -n "os(iOS)" Sources/ocoreai/App.swift 2>/dev/null || echo "app entry: no os(iOS) branch"
echo "--- hygiene ---"
for pat in 'TODO' 'catch {}' 'try!' 'fatalError'; do
  echo "$pat: $(grep -rc "$pat" Sources/ | awk -F: '{s+=$2} END{print s+0}')"
done
echo "--- god functions ---"
grep -n "func runInferenceBody" Sources/ocoreai/Engine/EngineInference.swift; wc -l Sources/ocoreai/Engine/EngineInference.swift
echo "--- maintenance cost (per-commit tax, last 300 commits; prints, no verdict) ---"
# Field base measured 11-12 on the same heuristic: no-product-code commits codex 27% / ollama 28% /
# opencode 36% / goose 55%; changelog co-touch 0 / 1 / 11 / 4 per 300 (ours measured 100%, CHANGELOG
# 11-12). The row is a ruler, not a gate: a rising tax says where attention went, not that it was wrong.
git log -300 --name-only --format='%x40' | awk '
/^@/{ if(n>0){t++; if(!code)nc++; if(cl)ct++} n=0; code=0; cl=0; next }
NF{ n++; if($0 ~ /^(Sources|Tests)\//) code=1; if($0 ~ /CHANGELOG|[Rr]elease.[Nn]otes/) cl=1 }
END{ if(n>0){t++; if(!code)nc++; if(cl)ct++}
     printf "  ours: commits=%d no-product-code=%d%% changelog-tax=%d%%  (field base: 27-55%% / 0-4%%)\n", t, nc*100/t, ct*100/t }'
echo "--- env count contract ---"
echo "env.example keys: $(grep -cE '^[A-Z_]+=' .env.example 2>/dev/null) | OCOREAI_ prefix only (undercount if multi-prefix): $(grep -rhoE 'OCOREAI_[A-Z_]+' Sources/ | sort -u | wc -l | tr -d ' ')"
grep -n "environment variables\|contract" Tests/ocoreaiTests/EnvKeysDocumentationTests.swift 2>/dev/null | head -3
echo "--- comparator cadence (the numbers § Adoption and Goal Rung 1 quote) ---"
# One request per tree: at per_page=1 the total is the last Link page. Unauthenticated is
# 60 req/h, so this costs 10 of them (8 trees + our own releases/tags) - run it when a number
# is quoted, not on a timer.
# A tree that could not be asked prints the reason and never a number, and a partial scan says
# it is partial: a floor read off a shrunk set is the vacuous-pass shape all over again.
python3 - <<'CADPY'
import json, re, urllib.error, urllib.request
TREES = ["openai/codex", "anomalyco/opencode", "earendil-works/pi",
         "openclaw/openclaw", "ollama/ollama", "aaif-goose/goose",
         "NousResearch/hermes-agent", "deepseek-ai/deepseek-harness"]

def ask(repo):
    url = "https://api.github.com/repos/%s/releases?per_page=1" % repo
    hdr = {"Accept": "application/vnd.github+json",
           "User-Agent": "ocoreai-audit-facts"}
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=hdr), timeout=20) as r:
            body, link = json.load(r), r.headers.get("Link", "")
    except urllib.error.HTTPError as exc:
        return "cannot-ask-HTTP%s" % exc.code, "-"
    except Exception as exc:
        return "cannot-ask-%s" % type(exc).__name__, "-"
    if isinstance(body, dict):
        return "cannot-ask-%s" % str(body.get("message", "?"))[:22], "-"
    newest = body[0]["published_at"][:10] if body else "none"
    last = re.search("[?&]page=(\d+)>; rel=.last.", link)
    return (last.group(1) if last else str(len(body))), newest

rows = [(t,) + ask(t) for t in TREES]
for t, total, newest in rows:
    print("  %-32s releases=%-7s newest=%s" % (t, total, newest))
nums = [r for r in rows if r[1].isdigit()]
if len(nums) == len(rows):
    lo = min(nums, key=lambda r: int(r[1])); hi = max(nums, key=lambda r: int(r[1]))
    print("  range=%s -> %s releases (floor %s, ceiling %s)"
          % (lo[1], hi[1], lo[0].split("/")[-1], hi[0].split("/")[-1]))
else:
    print("  PARTIAL - %d/%d trees answered, so the range above is not a floor"
          % (len(nums), len(rows)))

# The sentence that quotes the range also states ours, and until 11-06 that half was counted
# with `git tag` while the comparator half counted GitHub Releases - two units in one comparison.
# Ours is therefore counted on the stranger's unit: releases a GET without a token can SEE. The
# Link-header trick the comparator half uses counts GitHub's invisible drafts too - measured
# 11-06, `releases?per_page=1` answers an empty visible body while Link says page=10 - so it
# would fold the rehearsal lane's unpromoted drafts into a cadence number no stranger can rank.
def fetch(url):
    hdr = {"Accept": "application/vnd.github+json", "User-Agent": "ocoreai-audit-facts"}
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=hdr), timeout=20) as r:
            return json.load(r)
    except urllib.error.HTTPError as exc:
        return "cannot-ask-HTTP%s" % exc.code
    except Exception as exc:
        return "cannot-ask-%s" % type(exc).__name__

def ask_visible_releases(repo, cap_pages=3):
    total, page = 0, 1
    while page <= cap_pages:
        body = fetch("https://api.github.com/repos/%s/releases?per_page=100&page=%d" % (repo, page))
        if not isinstance(body, list):
            return body
        total += len(body)
        if len(body) < 100:
            return str(total)
        page += 1
    return "%s+" % total

def ask_tags(repo):
    body = fetch("https://api.github.com/repos/%s/tags?per_page=100" % repo)
    if not isinstance(body, list):
        return body
    return "%d%s" % (len(body), "+" if len(body) == 100 else "")

rel = ask_visible_releases("uingei/ocoreai")
tg = ask_tags("uingei/ocoreai")
local = len([t for t in __import__("subprocess").run(
    ["git", "tag"], capture_output=True, text=True).stdout.split() if t.startswith("v")])
print("  ours: releases_visible=%s tags_remote=%s tags_local=%d" % (rel, tg, local))
CADPY
echo "--- CI state ---"
if [ -n "${1:-}" ]; then
  curl -s --max-time 15 "https://api.github.com/repos/uingei/ocoreai/commits/$1/check-runs" \
    | python3 -c "import json,sys;d=json.load(sys.stdin);[print(x['name'],x.get('conclusion')) for x in d.get('check_runs',[])]"
else
  echo "(pass a commit sha as \$1 to fetch check-run conclusions; gh may be absent — curl is the fallback)"
fi
