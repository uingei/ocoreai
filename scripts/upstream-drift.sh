#!/usr/bin/env bash
# upstream-drift.sh — 三源上游 drift 持续跟进（mlx-swift-lm / coreai-models / codex）
#
# 用法：
#   bash scripts/upstream-drift.sh          # 只读检查（不改文件）
#                                            exit 0 = 基线以来 0 新 commit；exit 10 = 有新 commit 待裁决
#   bash scripts/upstream-drift.sh adopt    # 把三源当前 HEAD 采纳为新基线（只改 state 文件）
#
# 纪律（09-27 机制化轮定案）：
#   - state 基线 = 版本化 SHA 前缀（.upstream-baseline.json，入库可复现）
#   - 判定用 SHA 前缀包含（基线 7 位 / head 前缀可互认；compare API 端点用完整 SHA——短 base 会 404）
#   - 新 commit 列表 = adopt 前的裁决窗口；轴词粗筛只是提示，
#     权威裁决 = consumer-transparent grep 双根全扫（同义词全扫 + 既有机制先查，先例 e8d41c8）
#   - mlx-swift-lm = SPM pin（新 commit → bump 协议）；coreai-models = reference（逐条吸收裁决）；
#     codex = 语义轴（对照核心域真值，非逐 commit 复制）
#   - 本机无 references/ clone → gh api 是正确通道，不依赖 git fetch
set -euo pipefail
cd "$(dirname "$0")/.."

STATE=".upstream-baseline.json"
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REPOS="mlx-swift-lm:ml-explore/mlx-swift-lm coreai-models:apple/coreai-models codex:openai/codex"
cmd="${1:-check}"
DRIFT=0

# 本地镜像回落：无 DNS 的机器上 api() 必失败，三源会静默 skip（10-13 实测
# `scripts/upstream-drift.sh check` = 三行 "api 失败，跳过"，每日自检空转）。
# ~/references/<repo> 下的 clone 是同一 origin 的镜像，足以算 HEAD 与 base..head
# 窗口；输出标 src=clone，避免把镜像 HEAD 误当成 GitHub 权威。
REFS="${OCOREAI_REFERENCES_DIR:-$HOME/references}"
local_dir()  { [ -d "$REFS/$1/.git" ] && printf '%s' "$REFS/$1"; }
local_head() { local d; d="$(local_dir "$1")" || return 1
  git -C "$d" rev-parse --verify -q origin/HEAD \
    || git -C "$d" rev-parse --verify -q origin/main \
    || git -C "$d" rev-parse --verify -q origin/master; }
local_sha()  { local d; d="$(local_dir "$1")" || return 1
  git -C "$d" rev-parse --verify -q "$2^{commit}" 2>/dev/null; }
local_count() { local d; d="$(local_dir "$1")" || return 1
  git -C "$d" rev-list --count "$2..$3" 2>/dev/null || echo '?'; }
local_msgs() { local d; d="$(local_dir "$1")" || return 1
  git -C "$d" log --format=%s "$2..$3" 2>/dev/null; }

baseline_note() { python3 -c 'import json; d=json.load(open("'"$STATE"'")); print("@"+d["checked_at_utc"])' 2>/dev/null || echo "缺失(首次)"; }
base_sha() {
  # mlx-swift-lm 的基线 = Package.resolved 里的 SPM pin（pin 即采纳记录，单一真源）。
  # json 里的旧值只对 coreai-models/codex 有效——读 json 报 pin 已吸收的漂移是
  # 监控假警报（10-11 实锤：pin=7eb77ef==HEAD 仍天天报 +12 待裁决，淹没真窗口）。
  if [ "$1" = "mlx-swift-lm" ]; then
    python3 - <<'PY'
import json
d = json.load(open("Package.resolved"))
for p in d.get("pins", []):
    if "mlx-swift-lm" in p.get("identity", ""):
        print(p["state"]["revision"][:9]); break
PY
    return
  fi
  python3 -c 'import json; d=json.load(open("'"$STATE"'")); b=d["baselines"].get("'"$1"'",""); print(b if isinstance(b,str) else "")' 2>/dev/null; }

# gh 优先；无 gh 主机回落 curl+python3（api.github.com 实测可用）。
# 此前无 gh 时三源全部静默 skip = 覆盖缺口（10-05 实测踩中）。
# 注意：未认证 api.github.com 限额 60 req/h/IP——一轮全程 ≤15 req，足够。
api() { # api <endpoint> <mode:head|sha|ahead|behind|messages>
  local ep="$1" mode="${2:-head}"
  if command -v gh >/dev/null 2>&1; then
    case "$mode" in
      head) gh api "$ep" -q '.[0].sha' ;;
      sha) gh api "$ep" -q '.sha' ;;
      ahead) gh api "$ep" -q '.ahead_by+0' ;;
      behind) gh api "$ep" -q '.behind_by+0' ;;
      messages) gh api "$ep" -q '.commits[].commit.message | split("\n")[0]' ;;
    esac
  else
    curl -sf --max-time 25 "https://api.github.com/$ep" | python3 -c '
import json,sys
d=json.load(sys.stdin); m=sys.argv[1]
if m=="head": print(d[0]["sha"])
elif m=="sha": print(d["sha"])
elif m=="ahead": print(d.get("ahead_by","?"))
elif m=="behind": print(d.get("behind_by","?"))
elif m=="messages":
    [print(c["commit"]["message"].split("\n")[0]) for c in d.get("commits",[])]
' "$mode"
  fi
}

echo "═══ ocoreai upstream drift — baseline $(baseline_note) ═══"
echo

for pair in $REPOS; do
  name="${pair%%:*}"
  repo="${pair##*:}"
  src=api
  head="$(api "repos/$repo/commits?per_page=1" head 2>/dev/null)" || true
  if [ -z "$head" ]; then
    head="$(local_head "$name" 2>/dev/null)" || true
    [ -n "$head" ] && src=clone
  fi
  if [ -z "$head" ]; then
    echo "!!  $name: api 失败且无本地 clone（$REFS/${name}），跳过"
    DRIFT=1
    continue
  fi
  [ "$src" = clone ] && echo "     · $name src=local clone（$REFS/${name}，非 GitHub 权威；HEAD 截至该 clone 的 fetch 时刻）"
  short="${head:0:9}"
  base="$(base_sha "$name")"
  if [ -z "$base" ]; then
    printf "%-16s HEAD=%s  base=—(待首轮裁决/adopt)\n" "$name" "$short"
    continue
  fi
  if [ "$src" = clone ]; then
    base_full="$(local_sha "$name" "$base" 2>/dev/null || echo "$base")"
  else
    base_full="$(api "repos/$repo/commits/$base" sha 2>/dev/null || echo "$base")"
  fi
  if [ "$base_full" = "$head" ]; then
    printf "%-16s HEAD=%s  0 new  ✓ 与基线同点\n" "$name" "$short"
  else
    if [ "$src" = clone ]; then
      ahead="$(local_count "$name" "$base_full" "$head")"
      behind="$(local_count "$name" "$head" "$base_full")"
    else
      ahead="$(api "repos/$repo/compare/$base_full...$head" ahead 2>/dev/null || echo '?')"
      behind="$(api "repos/$repo/compare/$base_full...$head" behind 2>/dev/null || echo '?')"
    fi
    if [ "$ahead" != "?" ] && [ "$ahead" -gt 0 ] 2>/dev/null; then
      printf "%-16s HEAD=%s  +%s commits vs base=%s  ⚠ 新窗口待裁决\n" "$name" "$short" "$ahead" "${base:0:9}"
      DRIFT=10
    elif [ "$behind" != "?" ] && [ "$behind" -gt 0 ] 2>/dev/null; then
      printf "%-16s HEAD=%s  base=%s  !! 基线在 HEAD 之后 %s 条（force-push?），人工复查\n" "$name" "$short" "${base:0:9}" "$behind"
      DRIFT=1
    elif [ "${base:0:9}" != "$short" ]; then
      printf "%-16s HEAD=%s  base=%s  ? 非线性分叉，人工复查\n" "$name" "$short" "${base:0:9}"
      DRIFT=1
    fi
    if [ "$DRIFT" -eq 10 ]; then
      if [ "$src" = clone ]; then
        window="$(local_msgs "$name" "$base_full" "$head" | head -50)"
      else
        window="$(api "repos/$repo/compare/$base_full...$head?per_page=50" messages 2>/dev/null | sed 's/\(.\{110\}\).*/\1.../' | head -50)"
      fi
      n_commits="$(printf '%s\n' "$window" | grep -c . || true)"
      hits="$(printf '%s\n' "$window" | grep -icE 'approv|update.?plan|plan tool|hook|mcp|reasoning|tool.?call|sampling|kv|chunk|grammar' || true)"
      echo "         轴词粗筛(提示,非权威): $hits / $n_commits 条"
      printf '%s\n' "$window" | head -14 | sed 's/^/           /'
    fi
  fi
done

echo
if [ "$cmd" = "adopt" ]; then
  ADOPT_OK=1
  for pair in $REPOS; do
    name="${pair%%:*}"; repo="${pair##*:}"
    src=api
    head="$(api "repos/$repo/commits?per_page=1" head 2>/dev/null)" || true
    if [ -z "$head" ]; then
      head="$(local_head "$name" 2>/dev/null)" || true
      [ -n "$head" ] && src=clone
    fi
    [ -n "$head" ] || { ADOPT_OK=0; continue; }
    [ "$src" = clone ] && echo "     · $name adopted from local clone ($REFS/$name) — 记录于 resolved_via"
    python3 - "$STATE" "$name" "$head" "$NOW_UTC" "$repo" "$src" <<'PY'
import json,sys
path,name,head,now,repo,src=sys.argv[1:7]
try: d=json.load(open(path))
except Exception: d={"baselines":{},"note":"versioned upstream drift baseline — scripts/upstream-drift.sh"}
d["baselines"][name]=head[:7]   # 短 SHA：gh api 单点解析容忍度最高（7 位唯一即可）
d["sources"]={**d.get("sources",{}),name:repo}
d.setdefault("resolved_via",{})[name]=src
d["checked_at_utc"]=now
json.dump(d,open(path,"w"),indent=2); open(path,"a").write("\n")
PY
  done
  if [ "$ADOPT_OK" -eq 1 ]; then
    echo "✔ 基线已采纳 → $STATE"
    echo "  ⚠ adopt ≠ 完成：上列新 commit 窗口仍须 ① consumer-transparent 双根全扫逐条裁决 ② AGENTS.md 审计行 ③ CHANGELOG 行（先例 e8d41c8）。"
    exit 0
  else
    echo "!! 部分源 gh api 失败，基线未完整更新，人工复查。"
    exit 1
  fi
fi

if [ "$DRIFT" -eq 0 ]; then echo "结论：三轴基线以来 0 新 commit。"; exit 0
elif [ "$DRIFT" -eq 10 ]; then echo "结论：存在新漂移窗口，裁决后再 adopt。"; exit 10
else echo "结论：检查不完整/基线异常，人工复查。"; exit 1; fi
