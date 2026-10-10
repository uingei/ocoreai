#!/usr/bin/env bash
# Re-runnable ocoreai audit fact-sheet — machine-checkable facts only.
# Every audit claim must be backed by a line from this output or an equivalent grep.
# Usage: bash scripts/audit-facts.sh [commit-sha]  (sha → CI check-run conclusions)
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
echo "HEAD=$(git rev-parse --short HEAD) origin/main=$(git rev-parse --short origin/main) dirty=$(git status --short | wc -l | tr -d ' ')"
[ -f .upstream-baseline.json ] && echo "--- upstream baseline ---" && cat .upstream-baseline.json
echo "--- pins (Package.swift) ---"; grep -nE "revision:|exact:" Package.swift
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
echo "--- env count contract ---"
echo "env.example keys: $(grep -cE '^[A-Z_]+=' .env.example 2>/dev/null) | OCOREAI_ prefix only (undercount if multi-prefix): $(grep -rhoE 'OCOREAI_[A-Z_]+' Sources/ | sort -u | wc -l | tr -d ' ')"
grep -n "environment variables\|contract" Tests/ocoreaiTests/EnvKeysDocumentationTests.swift 2>/dev/null | head -3
echo "--- CI state ---"
if [ -n "${1:-}" ]; then
  curl -s --max-time 15 "https://api.github.com/repos/uingei/ocoreai/commits/$1/check-runs" \
    | python3 -c "import json,sys;d=json.load(sys.stdin);[print(x['name'],x.get('conclusion')) for x in d.get('check_runs',[])]"
else
  echo "(pass a commit sha as \$1 to fetch check-run conclusions; gh may be absent — curl is the fallback)"
fi
