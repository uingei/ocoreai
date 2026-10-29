#!/usr/bin/env bash
# upstream-drift.sh — 三源上游 drift 持续跟进（mlx-swift-lm / coreai-models / codex）
#
# 用法：
#   bash scripts/upstream-drift.sh          # 只读检查（不改文件）
#                                            exit 0 = 基线以来 0 新 commit；exit 10 = 有新 commit 待裁决
#   bash scripts/upstream-drift.sh adopt                  # 把三源当前 HEAD 采纳为新基线（只改 state 文件）
#   bash scripts/upstream-drift.sh adopt coreai-models    # 只采纳这一条轴，其余轴的窗口如实留着
#     轴名写错直接 exit 1 —— 静默采纳 0 条轴看起来像「全部办完」，正是这类工具最贵的错。
#
# 纪律（09-27 机制化轮定案）：
#   - state 基线 = 版本化 SHA 前缀（.upstream-baseline.json，入库可复现）
#   - 判定用 SHA 前缀包含（基线 7 位 / head 前缀可互认；compare API 端点用完整 SHA——短 base 会 404）
#   - 新 commit 列表 = adopt 前的裁决窗口；轴词粗筛只是提示，
#     权威裁决 = consumer-transparent grep 双根全扫（同义词全扫 + 既有机制先查，先例 e8d41c8）
#   - 截断一律 `sed -n '1,Np'`，禁 `| head -N`：窗口 >64 KiB 时 head 提前关闭管道，
#     写入端吃 SIGPIPE，pipefail 让脚本以 141 中止——退出码契约当场失效，读者只看到半张报告
#     （10-29 实测：codex 窗口 >300 条 subject，`>/dev/null` 连三次 exit 141 而非 10）。
#   - mlx-swift-lm = SPM pin（新 commit → bump 协议）；coreai-models = reference（逐条吸收裁决）；
#     codex = 语义轴（对照核心域真值，非逐 commit 复制）
#   - 本机无 references/ clone → gh api 是正确通道，不依赖 git fetch
set -euo pipefail
cd "$(dirname "$0")/.."

STATE=".upstream-baseline.json"
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REPOS="mlx-swift-lm:ml-explore/mlx-swift-lm coreai-models:apple/coreai-models codex:openai/codex"
# 第四轴单列在文件末尾：mlx-swift 不是 HEAD 轴，是 tag 轴（判定单位不同，退出码语义也不同）。
MLX_REPO="ml-explore/mlx-swift"
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

# ── 第四轴：mlx-swift —— 判定单位是 tag，不是 HEAD ─────────────────────────
# 三轴盯 HEAD 是对的：lm 是 revision pin（HEAD 前进 = 待裁决窗口），coreai-models/codex
# 是参考轴。mlx-swift 不同：本仓对它下的是 `exact:` tag（Package.swift），main 上没打 tag
# 的 commit 任何 Swift 消费者都拿不到 —— 「HEAD 领先 N 条」在这里不是待办，只是下一次 tag
# 的审计输入。判定单位换成立即：
#   newest tag > pin  → ⚠ 已发布漂移，DRIFT=10（走 Package.swift 头注的 bump 协议）
#   newest tag == pin → 已发布面 0 漂移；main 领先只打成 ⚑ 提示，不动退出码
# 通道（10-20 实测本机）：api.github.com 的 repo 端点挂起（HTTP 000，而 /rate_limit 回
# 200，gh 未装），git 传输可用 ⇒ tag 走 ls-remote；再失败回落 SPM checkout 的本地 tag，
# 并把 FETCH_HEAD 的时龄打出来 —— 把「最后一次 fetch」说成「现在」是本仓点名的时龄失真。
# ⚑ 段顺手列出 main 上落在 ocoreai 直接消费的 MLX 文件上的 commit（名单 = Package.swift
# 的 consumer-impact audit：10 sites / 5 APIs，两边同一批文件，谁改了哪条一眼可见）。
MLX_FILES="Source/MLX/Stream.swift Source/MLX/Transforms+Eval.swift Source/MLX/MLXArray.swift \
Source/MLX/MLXArray+Bytes.swift Source/MLXNN/Transformer.swift"

mlx_axis() {
  local spm="" spec="" pin_ver="" pin_rev="" newest="" src="" main="" ahead="" hits="" n="" fh=""
  for d in .build-clt/checkouts/mlx-swift .build/checkouts/mlx-swift; do
    [ -d "$d/.git" ] && { spm="$d"; break; }
  done
  if [ -z "$spm" ]; then
    echo "!!  mlx-swift: 无 SPM checkout（$MLX_REPO 未 resolve），tag 轴未检查"
    DRIFT=1
    return
  fi
  spec="$(python3 -c '
import json
d = json.load(open("Package.resolved"))
for p in d.get("pins", []):
    if p.get("identity", "") == "mlx-swift":
        st = p.get("state", {}) or {}
        print((st.get("version") or "") + " " + (st.get("revision") or ""))
        break
' 2>/dev/null || true)"
  pin_ver="${spec%% *}"
  pin_rev="${spec##* }"
  if [ -z "$pin_ver" ]; then
    echo "!!  mlx-swift: Package.resolved 里没有 version pin（exact tag 未解析），tag 轴未检查"
    DRIFT=1
    return
  fi
  newest="$(git -C "$spm" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=45 ls-remote --tags origin \
    2>/dev/null | sed 's#.*refs/tags/##' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 \
    || true)"
  if [ -n "$newest" ]; then
    src="ls-remote"
  else
    newest="$(git -C "$spm" tag --sort=-v:refname 2>/dev/null \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sed -n '1p' || true)"
    fh="$(git -C "$spm" rev-parse --git-path FETCH_HEAD 2>/dev/null || true)"
    if [ -n "$fh" ] && [ -f "$fh" ]; then
      src="local tags, last fetch $(date -u -r "$fh" +%Y-%m-%dT%H:%MZ)"
    else
      src="local tags, fetch 时龄未知"
    fi
  fi
  if [ -z "$newest" ]; then
    echo "!!  mlx-swift: tag 解析失败（ls-remote 与本地 tag 均空），tag 轴未检查"
    DRIFT=1
    return
  fi
  if [ "$newest" = "$pin_ver" ]; then
    printf "%-16s tag=%s pin=%s  0 new release  ✓ 已发布面无漂移（newest tag == pin，src=%s）\n" \
      "mlx-swift" "$newest" "$pin_ver" "$src"
  elif [ "$(printf '%s\n%s\n' "$newest" "$pin_ver" | sort -V | tail -1)" = "$newest" ]; then
    printf "%-16s tag=%s pin=%s  ⚠ 已发布漂移：上游有更新的 tag，按 bump 协议逐条裁决\n" \
      "mlx-swift" "$newest" "$pin_ver"
    DRIFT=10
  else
    printf "%-16s tag=%s pin=%s  !! pin 比最新 tag 还新（pin 落在 tag 之后？），人工复查\n" \
      "mlx-swift" "$newest" "$pin_ver"
    DRIFT=1
  fi
  main="$(git -C "$spm" rev-parse --verify -q origin/main || true)"
  [ "$pin_rev" = "$main" ] && return
  ahead="$(git -C "$spm" rev-list --count "$pin_rev..$main" 2>/dev/null || echo '?')"
  [ "$ahead" = "?" ] && return
  printf '%s\n' "                 main=${main:0:9} +$ahead commits（未发布 ⇒ 非待办，是下一次 tag 的审计输入）"
  hits="$(git -C "$spm" log --format='%h %s' --name-only "$pin_rev..$main" -- $MLX_FILES 2>/dev/null \
    | grep -v '^[[:space:]]*$' || true)"
  [ -z "$hits" ] && return
  n="$(printf '%s\n' "$hits" | grep -c '^[0-9a-f]\{7,\} ' || true)"
  printf '%s\n' "                 ⚑ $n 条落在 ocoreai 直接消费的 MLX 文件上（名单=Package.swift consumer audit）："
  printf '%s\n' "$hits" | sed 's/^/                    /'
}

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

coreai_fork_ledger() {
  # coreai fork 台账:唯一的吸收记录是源码头里的 `Absorbed: #N <sha>`,而上面的轴只看 HEAD
  # 窗口,看不到"我们 fork 的那几个引擎各自吸收到哪"。这一段把那个数变成一条命令能问出来的
  # 东西:逐文件读 header 的台账起点,再数上游对该文件的未裁决 commit。只报数,不参与裁决
  # (exit 语义仍由上面的轴决定)。
  local d
  d="$(local_dir coreai-models)" || { echo "  coreai fork 台账   SKIP ($REFS/coreai-models 不存在)"; return 0; }
  # 窗口终点必须和上面轴用同一个 ref：轴读 origin/HEAD，台账读 checkout 的 HEAD，两者一旦
  # 分叉（clone 未 checkout 到最新），台账会少报——10-29 实测轴已见 0aff938 而台账仍停在 7fd2063。
  local upref
  upref="$(local_head coreai-models 2>/dev/null || echo HEAD)"
  python3 - "$d" "$upref" <<'LEDGER_PY'
import os, re, subprocess, sys
up, ref = sys.argv[1], sys.argv[2]
ours = os.path.join("Sources", "ocoreai", "Engine")
PATH_RE = re.compile(r"((?:swift/Sources/)?[A-Za-z0-9_/+.{}-]*[A-Za-z0-9_+]\.swift)")
SHA_RE = re.compile(r"(?:HEAD|absorbed|Absorbed: #\d+)\s+([0-9a-f]{7,40})")
# `Adjudicated: <sha>` = 这条窗口读到这儿了(逐条裁决记在 docs/agent/coreai-fork-adjudication.md)。
# 它只移动窗口的起点,不假装代码进来了:open 的裁决仍在那份文档里,不在这里消失。
ADJ_RE = re.compile(r"Adjudicated:\s+([0-9a-f]{7,40})")
def git(*a):
    try:
        return subprocess.run(("git",) + a, cwd=up, capture_output=True, text=True, timeout=60).stdout.strip()
    except Exception:
        return ""
def resolve(name):
    if name.startswith("swift/") and os.path.exists(os.path.join(up, name)):
        return name
    hits = [h for h in git("ls-files", "*%s" % name).split("\n") if h.strip()]
    return hits[0] if hits else ""
rows, glue = [], 0
for f in sorted(os.listdir(ours)):
    if not (f.startswith("CoreAI") and f.endswith(".swift")):
        continue
    head = "".join(open(os.path.join(ours, f), errors="ignore").readlines()[:45])
    if "coreai-models" not in head:
        continue
    # 1:1 fork 优先:同名上游文件就是它的来处(四个引擎与 VLM 都是这种);否则才读 header 里
    # 指名的路径,因为 header 会提到兄弟文件(我们的 VLM 头部就点了 Pipelined)。
    cand = [f] + [p for p in PATH_RE.findall(head) if "{" not in p]
    src = next((r for p in cand if (r := resolve(p))), "")
    shas = SHA_RE.findall(head)
    base = shas[-1] if shas else ""
    adj = ADJ_RE.findall(head)
    read_to = adj[-1] if adj else ""
    window = read_to or base
    if not src and not base:
        glue += 1
        continue
    if not src:
        rows.append("  %-31s 基线 %s | 上游文件未指名 — 逐条裁决时补路径" % (f, base[:9]))
        continue
    if not window:
        ever = git("rev-list", "--count", ref, "--", src)
        rows.append("  %-31s 无基线 | 上游 %s(该文件历史 %s 个 commit)— 窗口不可测" % (f, src.split("/")[-1], ever))
        continue
    n = git("rev-list", "--count", "%s..%s" % (window, ref), "--", src)
    new = git("log", "-1", "--format=%h %s", "%s..%s" % (window, ref), "--", src)
    start = ("已读至 %s" % read_to[:9]) if read_to else ("基线 %s" % base[:9])
    rows.append("  %-31s %s | 上游 %s 未读 %s 个 | %s"
                % (f, start, src.split("/")[-1], n if n != "0" else "0", (new or "无")[:78]))
print("\n".join(rows) if rows else "  (无 fork 台账条目)")
print("  窗口终点 = %s（与轴同一 ref；镜像不是 GitHub 权威）" % git("rev-parse", "--short", ref))
print("  另有 %d 个 CoreAI* 是 ocoreai 自己的胶合层(头里既不指名上游文件也无基线)" % glue)
LEDGER_PY
}

echo "═══ ocoreai upstream drift — baseline $(baseline_note) ═══"
coreai_fork_ledger || true
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
        window="$(local_msgs "$name" "$base_full" "$head" | sed -n '1,50p')"
      else
        window="$(api "repos/$repo/compare/$base_full...$head?per_page=50" messages 2>/dev/null | sed 's/\(.\{110\}\).*/\1.../' | sed -n '1,50p')"
      fi
      n_commits="$(printf '%s\n' "$window" | grep -c . || true)"
      hits="$(printf '%s\n' "$window" | grep -icE 'approv|update.?plan|plan tool|hook|mcp|reasoning|tool.?call|sampling|kv|chunk|grammar' || true)"
      echo "         轴词粗筛(提示,非权威): $hits / $n_commits 条"
      printf '%s\n' "$window" | sed -n '1,14s/^/           /p'
    fi
  fi
done


mlx_axis

echo
if [ "$cmd" = "adopt" ]; then
  ADOPT_OK=1
  # 部分采纳：一条轴逐条读完并裁决完，就该能只关这一条窗口。全量 adopt 会顺手把
  # 没读过的轴（codex 的数百条）一并盖进基线，把「未读」伪装成「已裁决」。
  shift || true
  SELECTED=("$@")
  if [ "${#SELECTED[@]}" -gt 0 ]; then
    for want in "${SELECTED[@]}"; do
      known=0
      for pair in $REPOS; do
        [ "${pair%%:*}" = "$want" ] && known=1
      done
      if [ "$known" -eq 0 ]; then
        echo "!! 未知轴 '$want'（可选：mlx-swift-lm / coreai-models / codex）— 未改动 $STATE"
        exit 1
      fi
    done
  fi
  for pair in $REPOS; do
    name="${pair%%:*}"; repo="${pair##*:}"
    if [ "${#SELECTED[@]}" -gt 0 ]; then
      picked=0
      for want in "${SELECTED[@]}"; do
        [ "$want" = "$name" ] && picked=1
      done
      if [ "$picked" -eq 0 ]; then
        echo "     · $name 未选 ⇒ 基线保持不变（窗口如实留着，下次 check 继续报）"
        continue
      fi
    fi
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
    if [ "${#SELECTED[@]}" -gt 0 ]; then
      echo "✔ 已采纳所选轴 → ${STATE}（其余轴基线未动）"
    else
      echo "✔ 基线已采纳 → $STATE"
    fi
    echo "  ⚠ adopt ≠ 完成：上列新 commit 窗口仍须 ① consumer-transparent 双根全扫逐条裁决 ② AGENTS.md 审计行 ③ CHANGELOG 行（先例 e8d41c8）。"
    exit 0
  else
    echo "!! 部分源 gh api 失败，基线未完整更新，人工复查。"
    exit 1
  fi
fi

if [ "$DRIFT" -eq 0 ]; then echo "结论：四轴（三 HEAD 轴 + mlx-swift tag 轴）均无待裁决漂移。"; exit 0
elif [ "$DRIFT" -eq 10 ]; then echo "结论：存在新漂移窗口，裁决后再 adopt。"; exit 10
else echo "结论：检查不完整/基线异常，人工复查。"; exit 1; fi
