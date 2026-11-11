#!/usr/bin/env bash
# upstream-drift.sh — 三源上游 drift 持续跟进（mlx-swift-lm / coreai-models / codex）
#
# 用法：
#   bash scripts/upstream-drift.sh          # 只读检查（不改文件）
#                                            exit 0 = 基线以来 0 新 commit；exit 10 = 有新 commit 待裁决
#                                            exit 1 = 检查没跑完（含被 trap 归一的中止）—— 不是「无漂移」
#     多轴同时给出判定时由 `tally_drift` 合并（唯一的写入处）：10 粘住，1 只填还没有 10 的表 ——
#     一条轴的「待裁决」是事实，另一条轴的「读不到」是这份报告的局限，局限不擦事实（11-05 实测）。
#     契约只有这三个数，trap 的覆盖面是量出来的（bash 3.2.57）：顶层简单命令、函数、`x="$(…)"`
#     赋值的非零返回都归一成 1；唯一绕过它的是裸子 shell —— `(exit 141)` 原样退出 141（实测，放在
#     `if` 体里也一样）。本文今天 0 个顶层子 shell（grep 过），所以这是条边界而不是缺陷；哪天写进
#     一个，它就在契约外面。`make drift` 传不出这三个数（make 把任何失败配方改写成自己的 2），
#     所以读码的自动化调本脚本；走 make 就读 stdout 的 `drift-exit=N`。
#   bash scripts/upstream-drift.sh pairing [diary] [anchor]  # mlx bump 的裁决台账（每个 bump 跨过的 commit 须被点名）；
#                                            同 0/10/1 三数契约；check 路自带台账判定（漏→10 粘住，读不到→1 填空表）
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
#     codex = 普通 comparator（11-03 业主裁定：不再是权威）。它的窗口照常打印，但不再置 DRIFT=10，
#     所以一个未读的 codex 窗口不会把整次 `make drift` 判红 —— 红只欠两条真消费的轴。
#   - 本机无 references/ clone → gh api 是正确通道，不依赖 git fetch
#   - 退出码契约由 trap 执行，不由注释执行：见下面的 on_abnormal_exit。
set -euo pipefail
cd "$(dirname "$0")/.."

# 计划外的中止一律归一成 1（「检查未完成」），并打出现场。为什么必须有这条：
# `set -e` 让脚本中途死掉时*带的是那条命令自己的数字*——python 崩是 2、SIGPIPE 是 141、
# 命令找不到是 127——而本文只登记 0/1/10，读退出码的自动化就会把「没跑完」读成契约里的
# 某个数（10-29 的 141 就是这么骗过每日自检的）。
#
# 不带 `-E`，且这是量出来的（11-05，bash 3.2.57 = macOS 自带的那个）：加了 -E 之后 trap 会
# 继承进函数与命令替换，而 3.2 对「`&&` 左侧失败不算中止」这条例外做得不严——回落路径
# `local_dir() { [ -d … ] && printf … ; }` 里那个假的 `[ -d ]` 也触发 trap，于是三条*被
# `|| …` 咽下去、脚本照常跑完*的回落各自打出一行「计划外中止」。一行说反话的诊断比没有诊断
# 更贵。顶层不加 -E 也照样归一：函数与 `$(…)` 的非零返回终归要在顶层那条命令上失败，那条
# 命令正是 trap 看着的地方——代价只是现场打的是调用方那一行，不是里面那一行。
on_abnormal_exit() {
  local rc=$?
  printf '!! 计划外中止 line %s：`%s` 退出 %s —— 不在契约（0/1/10）内，归一化为 exit 1\n' \
    "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-?}" "$rc" >&2
  exit 1
}
trap on_abnormal_exit ERR

STATE=".upstream-baseline.json"
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REPOS="mlx-swift-lm:ml-explore/mlx-swift-lm coreai-models:apple/coreai-models codex:openai/codex"
# 第四轴单列在文件末尾：mlx-swift 不是 HEAD 轴，是 tag 轴（判定单位不同，退出码语义也不同）。
MLX_REPO="ml-explore/mlx-swift"
cmd="${1:-check}"
DRIFT=0
# 判定合并只有一条规则：10（有待裁决窗口）是事实，1（这一轮没读全）是局限，局限不擦事实。
# 11-05 实测两条同时成立：mlx-swift-lm 打印「+6 commits ⚠ 新窗口待裁决」，随后 codex 的 compare
# 因 api 限流（0/60）读不到，脚本以 1 退出并把结论印成「检查没跑完」——读码的自动化于是被告知
# 「什么都还没定」，而真相是「一条已消费的轴欠一次裁决」。直接赋值一律只留 DRIFT=0 那一处。
tally_drift() { # tally_drift <0|1|10> —— 10 粘住；1 只填还没有事实的表
  local new="${1:-0}"
  if [ "$new" = 10 ]; then
    DRIFT=10
  elif [ "$new" -ne 0 ] && [ "$DRIFT" = 0 ]; then
    DRIFT="$new"
  fi
  return 0
}

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

# 一条 resolver，两个消费者（轴 + fork 台账）。此前两边各自解析 HEAD：轴 api 优先、
# 台账只读本地 clone 的 origin/HEAD，于是「轴已见 d3382a5 / 台账停在 6a6bb0e」在同一轮
# 报告里同时出现，而逐文件那一行照打「未读 0 个 | 无」—— d3382a5 恰给
# CoreAIStaticShapeEngine.swift 加了 243 行（10-31 实测）。
axis_head() { # axis_head <name> <repo> → "<sha>:<api|clone>"
  local name="$1" repo="$2" h=""
  h="$(api "repos/$repo/commits?per_page=1" head 2>/dev/null)" || true
  [ -n "$h" ] && { printf '%s:api' "$h"; return 0; }
  h="$(local_head "$name" 2>/dev/null)" || true
  [ -n "$h" ] && { printf '%s:clone' "$h"; return 0; }
  return 1
}

# fork 台账窗口终点的阶梯：候选只有在本地被探到才算数（resolve 的规矩）。
#   1) 轴 HEAD 这个对象本地已有 ⇒ 就用它：轴与台账同刻度量，漏读在结构上不可能
#   2) 只有 clone 的 origin/HEAD ⇒ 用它，但把「落后于轴」说出来并 exit 10：
#      逐文件「未读 0 个」只代表 clone 上次 fetch 之前的世界，不能读成「无待裁决」
#   3) 连 clone 的远端 ref 都没有 ⇒ exit 1，窗口不可测
window_endpoint() { # window_endpoint <clone-dir> <axis-ref> → "endpoint=<sha> src=<axis|clone>"
  local dir="$1" axis="${2:-}" mirror=""
  if [ -n "$axis" ] && git -C "$dir" rev-parse --verify -q "${axis}^{commit}" >/dev/null 2>&1; then
    printf 'endpoint=%s src=axis\n' "$(git -C "$dir" rev-parse --short "${axis}^{commit}")"
    return 0
  fi
  mirror="$(git -C "$dir" rev-parse --verify -q origin/HEAD 2>/dev/null \
    || git -C "$dir" rev-parse --verify -q origin/main 2>/dev/null \
    || git -C "$dir" rev-parse --verify -q origin/master 2>/dev/null)" || true
  if [ -z "$mirror" ]; then
    printf 'endpoint= src=none clone 无任何远端 ref，窗口不可测\n'
    return 1
  fi
  if [ -z "$axis" ]; then
    printf 'endpoint=%s src=clone 轴亦读此 clone（同一 ref）\n' \
      "$(git -C "$dir" rev-parse --short "$mirror")"
    return 0
  fi
  printf 'endpoint=%s src=clone LAGGING 轴 HEAD=%s 不在此 clone 上\n' \
    "$(git -C "$dir" rev-parse --short "$mirror")" "${axis:0:9}"
  return 10
}

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
    tally_drift 1
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
    tally_drift 1
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
    tally_drift 1
    return
  fi
  if [ "$newest" = "$pin_ver" ]; then
    printf "%-16s tag=%s pin=%s  0 new release  ✓ 已发布面无漂移（newest tag == pin，src=%s）\n" \
      "mlx-swift" "$newest" "$pin_ver" "$src"
  elif [ "$(printf '%s\n%s\n' "$newest" "$pin_ver" | sort -V | tail -1)" = "$newest" ]; then
    printf "%-16s tag=%s pin=%s  ⚠ 已发布漂移：上游有更新的 tag，按 bump 协议逐条裁决\n" \
      "mlx-swift" "$newest" "$pin_ver"
    tally_drift 10
  else
    printf "%-16s tag=%s pin=%s  !! pin 比最新 tag 还新（pin 落在 tag 之后？），人工复查\n" \
      "mlx-swift" "$newest" "$pin_ver"
    tally_drift 1
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

# 台账的口径:哪些 .swift 算「我们的镜像」。此前的口径是目录 + 名字前缀
# (Sources/ocoreai/Engine 下的 CoreAI*.swift),于是 #374 改的五个 GuidedGeneration/ 文件和
# #402 改的 Engine/InstrumentsProfiler.swift 根本不进表 —— 11-03 实测:带 Apple 版权 + BSD-3
# 头、且上游存在同名文件的 .swift 共 26 个,前缀扫描只够到 12 个,两个集合的交是 1 个。
# 新口径读文件自己的头(点了 coreai-models,或带着 fork 的许可证头),用 walk 而非名字。
# 每轮都把候选数打出来:walk 坏掉时那是一个看得见的数,不是一次通过(invariant 1)。
# 读点的拼写有两种,都得认:`Absorbed: #N <sha>` / `Adjudicated: <sha>`,以及早期头里的
# `Provenance: aligned with … @ <sha>`。11-05 实测:表把 40 个文件报成「无基线」,而其中
# 至少 `Engine/KVCache+CoreAI.swift` 与 `Engine/TensorStorage+CoreAI.swift` 的头就写着
# `@ <sha>` —— 那不是没人读过,那是台账读不懂那种写法;同一文件的头还写着
# 「0 commits changed 78413ae..HEAD」,而此后上游又动了它两次,正是没人再 grep 的那类断言。
fork_ledger_py() { # fork_ledger_py <clone> <ref> <ours-root> <table|census>
  python3 - "$1" "$2" "$3" "$4" <<'LEDGER_PY'
import os, re, subprocess, sys
up, ref, ours, mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
PATH_RE = re.compile(r"((?:swift/Sources/)?[A-Za-z0-9_/+.{}-]*[A-Za-z0-9_+]\.swift)")
SHA_RE = re.compile(r"(?:HEAD|absorbed|Absorbed: #\d+|Provenance:[^\n]*@)\s+([0-9a-f]{7,40})")
# `Adjudicated: <sha>` = 这条窗口读到这儿了(逐条裁决记在 docs/agent/coreai-fork-window-log.md)。
# 它只移动窗口的起点,不假装代码进来了:open 的裁决仍在那份文档里,不在这里消失。
ADJ_RE = re.compile(r"Adjudicated:\s+([0-9a-f]{7,40})")
BSD = ("Apple Inc.", "BSD-3-clause")
def git(*a):
    try:
        return subprocess.run(("git",) + a, cwd=up, capture_output=True, text=True, timeout=60).stdout.strip()
    except Exception:
        return ""
def resolve(name):
    # `git ls-files "*X.swift"` 是后缀匹配,不是同名匹配:上游 `DecodingStrategies/` 里
    # `*DecodingStrategy.swift` 命中四个文件,原先取 hits[0] 就把 `ConstrainedDecodingStrategy.swift`
    # 当成了我们 `DecodingStrategy.swift` 的来处 —— 而这两个都是我们的镜像。同名优先;读不到同名时
    # 只认 header 自己指名的路径(那是人的断言),裸文件名不做后缀猜测。11-05 实测 5 个镜像被这样
    # 张冠李戴,其中 3 个上游确有同名文件;危险方向是反向的假绿:窗口按别人的历史数,读出 0 个。
    if name.startswith("swift/") and os.path.exists(os.path.join(up, name)):
        return name
    hits = [h for h in git("ls-files", "*" + name).split("\n") if h.strip()]
    exact = [h for h in hits if os.path.basename(h) == name]
    if exact:
        return exact[0]
    return hits[0] if ("/" in name and hits) else ""
def head_of(path):
    try:
        return "".join(open(path, errors="ignore").readlines()[:45])
    except OSError:
        return ""
cands = []
for dirpath, _sub, files in os.walk(ours):
    for f in sorted(files):
        if not f.endswith(".swift"):
            continue
        path = os.path.join(dirpath, f)
        head = head_of(path)
        # 什么算镜像:带 fork 的许可证头(Apple 版权 + BSD-3 条款,这类文件是被搬进来的),
        # 或者头里点了 coreai-models 并指名了一个 .swift 来处。只在注释里引用上游的 MIT
        # 文件不算 —— 它们是引用,混进镜像表会让 40 个数读起来像 40 个没读的 fork。
        fork_licence = all(k in head for k in BSD)
        names_a_path = "coreai-models" in head and any(
            "{" not in x for x in PATH_RE.findall(head))
        if fork_licence or names_a_path:
            cands.append((path, head))
rows, glue, nobase, deltas = [], 0, [], []
for path, head in cands:
    name = os.path.basename(path)
    rel = os.path.relpath(path, ours)
    # 1:1 镜像优先:同名上游文件就是来处;否则才读 header 指名的路径,因为 header 会提到
    # 兄弟文件(我们的 VLM 头部就点了 Pipelined)。
    cands2 = [name] + [x for x in PATH_RE.findall(head) if "{" not in x]
    src = next((r for q in cands2 if (r := resolve(q))), "")
    shas = SHA_RE.findall(head)
    base = shas[-1] if shas else ""
    adj = ADJ_RE.findall(head)
    read_to = adj[-1] if adj else ""
    window = read_to or base
    if not src:
        if base:
            rows.append(("unnamed", rel, base[:9], "", ""))
        else:
            glue += 1
        continue
    if not window:
        # 11-05 实测:36 个"无基线"里 11 个头上就写着一个 sha —— `Absorbed from coreai-models
        # 27a66f9 (#227, fix #212)`、`(coreai-models #252, ebb3e54)`、`Upstream pin: … 7359dbc`。
        # 台账不猜那些写法是什么意思 —— 有一行明写着 `(upstream ahead)`,把它当基线就是一次假绿 ——
        # 但它也不能把"读不懂"和"没人读过"报成同一个数,所以分开点名,判断交给人。
        tagged = bool(re.search(r"\b[0-9a-f]{7,40}\b", head))
        nobase.append((rel, git("rev-list", "--count", ref, "--", src) or "?", tagged))
        continue
    n = git("rev-list", "--count", "%s..%s" % (window, ref), "--", src)
    new = git("log", "-1", "--format=%h %s", "%s..%s" % (window, ref), "--", src)
    start = ("已读至 " + read_to[:9]) if read_to else ("基线 " + base[:9])
    rows.append(("window", rel, start, n if n != "0" else "0",
                 src.split("/")[-1] + " | " + (new or "无")[:70]))
    # CODE delta: baseline..HEAD on the upstream file, independent of the read-point. The table
    # mode counts un-READ commits (can be 0 while code is frozen); this shows what the code owes.
    if base:
        ss = git("diff", "--shortstat", "%s..%s" % (base, ref), "--", src)
        deltas.append((rel, base[:9], src.split("/")[-1], ss.strip() or "current (0 delta)"))
if mode == "census":
    # 测试缝:一行一个事实,断言不必猜排版。
    print("#cand %d" % len(cands))
    print("#glue %d" % glue)
    for kind, rel, a, b, c in rows:
        print("#row %s %s %s %s %s" % (kind, rel, a, b, c))
    for rel, ever, tagged in nobase:
        print("#nobase %s %s %s" % (rel, ever, "sha" if tagged else "none"))
elif mode == "delta":
    # Per-file CODE debt (baseline..HEAD), the sync-targeting view: which forked files actually
    # differ from upstream, vs the read-point count which can read 0 while the code is frozen.
    owe = [d for d in deltas if not d[3].startswith("current")]
    cur = [d for d in deltas if d[3].startswith("current")]
    print("  per-file CODE delta (baseline..HEAD ≠ read-point): %d owe, %d current, %d no-baseline"
          % (len(owe), len(cur), len(nobase)))
    for rel, b, srcname, ss in sorted(owe):
        print("  OWES    %-40s @%s  %s" % (rel, b, ss))
    for rel, b, srcname, ss in sorted(cur):
        print("  current %-40s @%s" % (rel, b))
else:
    for kind, rel, a, b, c in rows:
        if kind == "unnamed":
            print("  %-36s 基线 %s | 上游文件未指名 — 逐条裁决时补路径" % (rel, a))
        else:
            print("  %-36s %s | 上游 %s" % (rel, a, (b + " 个 | " + c) if b else c))
    if not rows:
        print("  (无 fork 台账条目)")
    if nobase:
        tagged = sum(1 for _r, _e, t in nobase if t)
        print("  无基线镜像 %d 个 —— 来处已定,但头里没有可判读的读点(`Absorbed: #N <sha>`、"
              "`Adjudicated: <sha>`、`Provenance: … @ <sha>`);括号里是上游该文件的历史 commit 数,"
              "带 * 的 %d 个头里其实写着一个 sha,只是那种写法台账不敢认(认错了就是一次假绿):"
              % (len(nobase), tagged))
        for i in range(0, len(nobase), 3):
            print("    " + "  ".join(
                "%s%s(%s)" % (r, "*" if t else "", e) for r, e, t in nobase[i:i + 3]))
    print("  台账口径 walk %s ⇒ 候选 %d(带 Apple+BSD-3 头,或点了 coreai-models 并指名来处),"
          "成行 %d,无基线 %d,胶合/引用 %d"
          % (ours, len(cands), len(rows), len(nobase), glue))
LEDGER_PY
}

coreai_fork_ledger() {
  # coreai fork 台账:唯一的吸收记录是源码头里的 `Absorbed: #N <sha>`,而上面的轴只看 HEAD
  # 窗口,看不到"我们 fork 的那几个引擎各自吸收到哪"。这一段把那个数变成一条命令能问出来的
  # 东西:逐文件读 header 的台账起点,再数上游对该文件的未裁决 commit。只报数,不参与裁决
  # (exit 语义仍由上面的轴决定)。
  local d axis="" res="" upref=""
  d="$(local_dir coreai-models)" || { echo "  coreai fork 台账   SKIP ($REFS/coreai-models 不存在)"; return 0; }
  # 窗口终点与轴同刻度这件事,10-29 只写进了注释,所以 10-31 又漏一次。现在终点走
  # window_endpoint 的阶梯:轴 HEAD 在本地探得到就用它,探不到就明说落后并 exit 10。
  axis="$(axis_head coreai-models apple/coreai-models 2>/dev/null | cut -d: -f1)" || axis=""
  res="$(window_endpoint "$d" "$axis")" || true
  upref="$(printf '%s\n' "$res" | sed -n 's/^endpoint=\([^ ]*\).*/\1/p')"
  if [ -z "$upref" ]; then
    echo "  coreai fork 台账   SKIP — $(printf '%s' "$res" | sed 's/^endpoint=[^ ]* //')"
    return 0
  fi
  fork_ledger_py "$d" "$upref" "$(pwd)/Sources/ocoreai" "${1:-table}"
  local srcline
  srcline="$(printf '%s\n' "$res" | sed -n 's/^endpoint=[^ ]* \(src=[a-z]*\).*/\1/p')"
  printf '  窗口终点 = %s（%s；镜像不是 GitHub 权威）\n' "$upref" "$srcline"
  case "$res" in
    *LAGGING*)
      tally_drift 10
      printf '  ⚠ 台账落后于轴：%s — 逐文件「未读」只数到该 clone 上次 fetch，先 fetch 再读这张表\n' \
        "$(printf '%s' "$res" | sed 's/^endpoint=[^ ]* src=[a-z]* //')"
      ;;
  esac
}

# 测试缝：终点阶梯可以在一个合成 clone 上问，不碰网络、不读 ~/references。
if [ "$cmd" = "window-endpoint" ]; then
  rc=0
  window_endpoint "${2:-}" "${3:-}" || rc=$?
  exit "$rc"
fi

# 一条真实的顶层命令，以指定的数字失败——契约的另一半（未登记的码不得外流）只能在
# 真命令上问，不能在注释里问。
fail_with() { return "${1:-1}"; }

# 测试缝：`abort-code <n>` 让上面那条以 n 失败，走的是主路径同一个 trap。
# 期望恒为 1（而非 n）：trap 被删，这里就漏出 2/141/127 —— 已实测（删掉 trap 那行同一命令返回 2）。
if [ "$cmd" = "abort-code" ]; then
  fail_with "${2:-2}"
  exit 0  # 不可达：trap 必须先接管，否则这条 exit 才是被测的面
fi

# 一条轴欠不欠一个红：0 = 我们真消费它（SPM pin、逐条吸收的 fork），未读窗口判红；
# 非 0 = 普通 comparator，窗口只报告。11-03 业主裁定 codex 不再是权威（root § Upstream 5），
# 于是它落到报告档；未登记的轴一律按欠债算 —— 新轴默认判红比默认放行便宜。
# 测试缝：`axis-owed <name>` → "owed" | "report-only"（不碰网络）。
axis_owed() {
  case "${1:-}" in
    codex) return 1 ;;
    *) return 0 ;;
  esac
}

# 测试缝：「哪些文件算镜像」这个口径也能在合成目录上问（同上：不碰网络、不读 ~/references）。
if [ "$cmd" = "fork-census" ]; then
  fork_ledger_py "${2:-}" "${3:-}" "${4:-}" "${5:-census}"
  exit $?
fi

# Per-file CODE debt view (baseline..HEAD): which forked files actually differ from upstream.
# The sync-targeting companion to the read-point table — report only, not a gate.
if [ "$cmd" = "coreai-delta" ]; then
  coreai_fork_ledger delta
  exit 0
fi

# 测试缝：裁定表本身（退出码契约的一半住在这里）。
if [ "$cmd" = "axis-owed" ]; then
  if axis_owed "${2:-}"; then echo "owed"; else echo "report-only"; fi
  exit 0
fi

# 一次轴的 subject 窗口 = 轴词粗筛的输入，是提示，不是判定：走到这里时 HEAD 与 ahead 都已读到，
# 「⚠ 新窗口待裁决」那行已经落纸。11-05 实测一次 compare 读失败（api 限流）：那次中止由 trap 打出来
# （`window="$(api ...)"` 在 `set -e` 下带走整个进程），10 被改写成 1，剩下两条轴一行没打 ——
# 读码的自动化于是把「一条提示没读到」读成「检查没跑完」，而真正的待裁决窗口反而看不见。
# 规矩同 resolve 的阶梯：失败的*读*自己认账并往下走，只有失败的*判定*才配改退出码。
axis_window() { # axis_window <name> <repo> <src:api|clone> <base> <head>
  local name="$1" repo="$2" src="$3" base="$4" head="$5" window="" rc=0 hits n
  if [ "$src" = clone ]; then
    window="$(local_msgs "$name" "$base" "$head" | sed -n '1,50p')" || rc=$?
  else
    window="$(api "repos/$repo/compare/$base...$head?per_page=50" messages 2>/dev/null \
      | sed 's/\(.\{110\}\).*/\1.../' | sed -n '1,50p')" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    printf '         窗口列表未读到（%s 通道的 subject 读退出 %s）—— 上面的判定不受影响；重跑，或先 fetch %s 再读\n' \
      "$src" "$rc" "$name"
    return 0
  fi
  n="$(printf '%s\n' "$window" | grep -c . || true)"
  hits="$(printf '%s\n' "$window" | grep -icE 'approv|update.?plan|plan tool|hook|mcp|reasoning|tool.?call|sampling|kv|chunk|grammar' || true)"
  echo "         轴词粗筛(提示,非权威): $hits / $n 条"
  printf '%s\n' "$window" | sed -n '1,14s/^/           /p'
  return 0
}

# 一条轴的判定文案与它欠的退出码，从 compare 读到的两个数里选出来。此前这两件事写在主循环里，
# 于是「读不到」与「读到了 0/0」共用同一条 elif：11-05 实测 api.github.com 剩余额度 0/60 时，
# codex 打印的是「? 非线性分叉，人工复查」——把配额报成了分支历史。判定形状与退出码都不许变
# (0=不动,10=待裁决,1=人工复查)，变的只有一句点名。AXIS_DRIFT 而不是 return：ERR trap 对函数
# 返回非零会接管并归一，见文件头的覆盖边界。
axis_verdict() { # axis_verdict <name> <short> <base9> <ahead> <behind> <owed:1|0>
  local name="$1" short="$2" base="$3" ahead="$4" behind="$5" owed="$6"
  AXIS_DRIFT=0
  if [ "$ahead" != "?" ] && [ "$ahead" -gt 0 ] 2>/dev/null; then
    if [ "$owed" = 0 ]; then
      # 只报告、不欠债：窗口照常打印，退出码不动（裁定见 `axis_owed`）。
      printf "%-16s HEAD=%s  +%s commits vs base=%s  · 仅报告（comparator，非权威，不判红）\n" \
        "$name" "$short" "$ahead" "$base"
    else
      printf "%-16s HEAD=%s  +%s commits vs base=%s  ⚠ 新窗口待裁决\n" \
        "$name" "$short" "$ahead" "$base"
      AXIS_DRIFT=10
    fi
  elif [ "$behind" != "?" ] && [ "$behind" -gt 0 ] 2>/dev/null; then
    printf "%-16s HEAD=%s  base=%s  !! 基线在 HEAD 之后 %s 条（force-push?），人工复查\n" \
      "$name" "$short" "$base" "$behind"
    AXIS_DRIFT=1
  elif [ "$ahead" = "?" ] || [ "$behind" = "?" ]; then
    printf "%-16s HEAD=%s  base=%s  !! compare 未读到（api 失败或限流）—— 窗口未知，不是历史异常\n" \
      "$name" "$short" "$base"
    AXIS_DRIFT=1
  elif [ "$base" != "$short" ]; then
    printf "%-16s HEAD=%s  base=%s  ? 非线性分叉，人工复查\n" "$name" "$short" "$base"
    AXIS_DRIFT=1
  fi
  return 0
}

# 测试缝：让上面那条走一次*真失败*的读，不碰网络——把 clone 根指到一个空目录，
# `local_msgs` 就以 1 失败，被测的是「点名并返回 0」而不是「提示失败不许改判定」这句注释。
if [ "$cmd" = "window-read" ]; then
  axis_window "${2:-no-such-axis}" "${3:-none/none}" clone "${4:-deadbeef}" "${5:-deadbeef}"
  exit 0
fi

# 测试缝：判定文案可以直接喂数问，不必让一条测试去耗尽 api 额度。最后一个参数决定这条轴欠不欠红
# (与 `axis-owed` 同一个裁定的两个入参)。
# 测试缝：合并规则可以在三个数上问完，不必让一条测试去凑齐一次真限流。
if [ "$cmd" = "tally" ]; then
  DRIFT="${2:-0}"
  for want in "${@:3}"; do
    tally_drift "$want"
  done
  printf 'DRIFT=%s\n' "$DRIFT"
  exit 0
fi

if [ "$cmd" = "axis-verdict" ]; then
  axis_verdict "${2:-axis}" "${3:-aaaaaaaaa}" "${4:-bbbbbbbbb}" "${5:-?}" "${6:-?}" "${7:-1}"
  printf 'AXIS_DRIFT=%s\n' "$AXIS_DRIFT"
  exit 0
fi

# ── 裁决台账（bump 窗口的逐条点名）────────────────────────────────────────────
# 这条轴的基线 = SPM pin，于是「bump 跳过了没读的 commit」这条轴自己看不见自己的债:
# pin 一挪,没读的窗口就永久从报告里消失(11-09 实测:a70ef531 只裁决了它去取的 #732,
# 同窗口另外 4 条 —— #731/#745/#746/#740 —— 无声进了出货树,#731 恰是我们 guided lane
# 需要的正确性修复)。修法是台账不是新轴:每个挪 revision: 的 commit,它跨过的每条上游
# commit 必须被点名(sha7 或 subject 里的 #PR)在 bump 自己的 message 或 CHANGELOG 里。
# 锚点前(171cd3ee,10-06)的历史是**声明的盲面**:打印祖先数并跳过扫描 —— 拿今天的口径
# 去判六月的树会造 51 条没法追认的红,那是伪造 retro-scope,不是补台账。
# 测试缝:bash scripts/upstream-drift.sh pairing [diary-file] [anchor-sha]
PAIR_ANCHOR="171cd3ee"
pairing_ledger() { # pairing_ledger [diary-file] [anchor-sha] → exit 0 全点名 / 10 有漏 / 1 没跑成
  local diary="${1:-CHANGELOG.md}" anchor="${2:-$PAIR_ANCHOR}" mirror="" d
  for d in "$REFS/mlx-swift-lm" .build/checkouts/mlx-swift-lm .build-clt/checkouts/mlx-swift-lm; do
    [ -n "$mirror" ] && continue
    [ -d "$d/.git" ] && mirror="$d"
  done
  [ -n "$mirror" ] || { echo "!!  裁决台账：无 clone/checkout 可读（\$OCOREAI_REFERENCES_DIR 或 .build/checkouts）—— 未跑成,不是无漏"; return 1; }
  [ -f "$diary" ] || { echo "!!  裁决台账：diary '$diary' 读不到 —— 未跑成,不是无漏"; return 1; }
  python3 -I - "$mirror" "$diary" "$anchor" <<'PY'
import json,re,subprocess,sys
mirror,diary,anchor=sys.argv[1:4]
def git(*a,cwd=None): return subprocess.run(a,capture_output=True,text=True,cwd=cwd).stdout
def gitc(*a,cwd=None): return subprocess.run(a,capture_output=True,text=True,cwd=cwd).returncode
try: pin=json.load(open("Package.resolved"))
except Exception: print("!!  裁决台账：Package.resolved 读不到 —— 未跑成"); sys.exit(1)
pinrev=next((p["state"]["revision"] for p in pin.get("pins",[]) if "mlx-swift-lm" in p.get("identity","")), "")
if not pinrev or gitc("git","-C",mirror,"cat-file","-e",f"{pinrev}^{{commit}}"):
    print(f"!!  裁决台账：pin {pinrev[:9] or '?'} 在镜像里读不到 —— 未跑成,不是无漏"); sys.exit(1)
def rev_of(commit):
    m=re.search(r'mlx-swift-lm\.git",\s*revision:\s*"([0-9a-f]+)"', git("git","show",f"{commit}:Package.swift"))
    return m.group(1) if m else None
log=git("git","log","--format=%H","--reverse","--","Package.swift").split()
bumps=[(c,rev_of(c),rev_of(c+"^")) for c in log if rev_of(c) and rev_of(c)!=rev_of(c+"^")]
if len(bumps)<10: print(f"!!  裁决台账：只找到 {len(bumps)} 个 bump(预期 ≥10)——前提破了,不是无漏"); sys.exit(1)
text=open(diary,encoding="utf-8").read()
started=False; rows=[]; miss_total=0; scan_total=0; anchor_base=None; pre_total=0
for c,new,old in bumps:
    if c.startswith(anchor): started=True; anchor_base=old
    if not started:
        # 锚点前:数我们的 bump 跨过的条数(不是全上游的祖先数),端点缺读就如实计 '?'.
        if old and not gitc("git","-C",mirror,"cat-file","-e",f"{old}^{{commit}}") \
           and not gitc("git","-C",mirror,"cat-file","-e",f"{new}^{{commit}}"):
            pre_total+=len(git("git","-C",mirror,"rev-list",f"{old}..{new}").split())
        continue
    msg=git("git","log","-1","--format=%B",c)
    if gitc("git","-C",mirror,"cat-file","-e",f"{old}^{{commit}}") or gitc("git","-C",mirror,"cat-file","-e",f"{new}^{{commit}}"):
        print(f"  {c[:9]} {old[:9]}..{new[:9]}  !! 端点不在镜像里 —— 这一窗未判,计为漏"); miss_total+=1; continue
    ids=git("git","-C",mirror,"rev-list",f"{old}..{new}").split()
    miss=[]
    for full in ids:
        subj=git("git","-C",mirror,"log","-1","--format=%s",full).strip()
        pr=re.search(r"#(\d+)",subj)
        tok=[full[:7],full[:9]]+([f"#{pr.group(1)}"] if pr else [])
        if not any(t in msg or t in text for t in tok): miss.append(f"{full[:9]}{' '+pr.group(0) if pr else ''}")
    scan_total+=len(ids); miss_total+=len(miss)
    status=f"{len(ids)-len(miss)}/{len(ids)}" if not miss else f"{len(ids)-len(miss)}/{len(ids)}  !! 未点名: {', '.join(miss)}"
    rows.append(f"  {c[:9]} {old[:9]}..{new[:9]}  {status}")
if scan_total<40: print(f"!!  裁决台账：锚点后只扫到 {scan_total} 条(预期 ≥40)——前提破了"); sys.exit(1)
print(f"  裁决台账 {anchor[:9]} 起 {len(rows)} 个 bump / {scan_total} 条逐条点名;锚点前 {pre_total} 条 = 声明的盲面(纪律前的历史,跳过扫描,不假装追认)")
for r in rows: print(r)
sys.exit(10 if miss_total else 0)
PY
}

if [ "$cmd" = "pairing" ]; then
  # `&& rc=0 || rc=$?` 是量出来的必需形态:裸调用 + `rc=$?` 会被 ERR trap 先接管,10 归一成 1,
  # 台账的「有漏」就被报成「没跑成」——文件头那条契约在调用点自己兑现一次。
  rc=0
  pairing_ledger "${2:-CHANGELOG.md}" "${3:-$PAIR_ANCHOR}" && rc=0 || rc=$?
  printf 'PAIRING_EXIT=%s\n' "$rc"
  exit "$rc"
fi

echo "═══ ocoreai upstream drift — baseline $(baseline_note) ═══"
coreai_fork_ledger || true
echo

for pair in $REPOS; do
  name="${pair%%:*}"
  repo="${pair##*:}"
  res="$(axis_head "$name" "$repo" 2>/dev/null)" || res=""
  head="${res%%:*}"
  src="${res##*:}"
  [ -n "$head" ] || src=""
  if [ -z "$head" ]; then
    echo "!!  $name: api 失败且无本地 clone（$REFS/${name}），跳过"
    tally_drift 1
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
    owed=0
    if axis_owed "$name"; then owed=1; fi
    axis_verdict "$name" "$short" "${base:0:9}" "$ahead" "$behind" "$owed"
    if [ "$AXIS_DRIFT" -ne 0 ]; then tally_drift "$AXIS_DRIFT"; fi
    # 窗口照旧打印：comparator 的窗口是「报告」，不是「欠债」——只是它不再决定退出码。
    if [ "$DRIFT" -eq 10 ] || ! axis_owed "$name"; then
      axis_window "$name" "$repo" "$src" "$base_full" "$head"
    fi
  fi
done


mlx_axis

# 裁决台账只在 check 路参与判定（adopt 有自己的收口）；它没跑成只把 1 填进还没有 10 的表。
if [ "$cmd" = "check" ]; then
  prc=0
  pairing_ledger >/dev/null 2>&1 && prc=0 || prc=$?
  if [ "$prc" -eq 10 ]; then
    echo "  !! 裁决台账：有 bump 跨过未点名的上游 commit —— 逐条见 `bash scripts/upstream-drift.sh pairing`"
    tally_drift 10
  elif [ "$prc" -ne 0 ]; then
    echo "  !! 裁决台账未跑成（镜像/diary 读不到）—— 是局限,不是无漏"
    tally_drift 1
  else
    echo "  裁决台账 ✓ 锚点后每个 revision: bump 跨过的 commit 都被点名（锚点前面的盲面已声明,见 pairing 缝）"
  fi
fi

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
