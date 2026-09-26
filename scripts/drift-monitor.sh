#!/usr/bin/env bash
# deterministic upstream drift gate (Hermes cron monitor primitive)
# output = 3 (baseline|HEAD) lines, no timestamp -> deterministic diff
# robust to caller cwd: anchors to the ocoreai repo root via this script's location
set -uo pipefail
ROOT="$HOME/projects/ocoreai"
if [ ! -f "$ROOT/.upstream-baseline.json" ]; then
  ROOT="$(cd "$(dirname "$0")" && pwd)"; 
fi
b() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["baselines"].get(sys.argv[2],"?"))' "$ROOT/.upstream-baseline.json" "$1" 2>/dev/null || echo '?'; }
h() { gh api "repos/$1/commits?per_page=1" -q '.[0].sha[0:7]' 2>/dev/null || echo ERR; }
printf 'mlx-swift-lm\t%s|%s\n' "$(b mlx-swift-lm)" "$(h ml-explore/mlx-swift-lm)"
printf 'coreai-models\t%s|%s\n' "$(b coreai-models)" "$(h apple/coreai-models)"
printf 'codex\t%s|%s\n' "$(b codex)" "$(h openai/codex)"