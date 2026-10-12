# ocoreai checkpoint (10-12/13 round 14 — 把「谁在用内存、谁的会话」这两笔账算清)

## 本轮定位
上一轮把活体回路解锁后，本轮全部结论都由**跑出来的数字**驱动，静态审计一条都没参与：
CI 从红转绿（样式门）、MLX 设备内存上限的两个写主、整机压力替游离进程买单、
无 `conversationId` 的请求跨会话串味。全量门 **2296 tests / 430 suites 全绿 / 398.5s**（沙箱外）。

## 落刀（3 条，每条先红后绿）
1. `e5f27c1` **MLX 缓冲缓存上限有两个写主，`budget: 70 GB` 从未生效**
   - 红证: `App.swift` 写 `Memory.cacheLimit = memBudget(70 GB)`，随后 `MLXModelLoader.init` 无条件写 256 MB；临时探针实证 `cacheLimit after loader-init = 256 MB`
   - 语义错在拿「调度预算」当「可回收缓冲池」上限：`mlx-swift Source/MLX/Memory.swift:37-56` 写明 cache 是已释放但留着复用的设备内存
   - 实测(M5 Max/128 GB·gemma-4-e2b-it-4bit·greedy 160 tok×3): 256 MB = 43.3/43.3/44.1 tok/s；4 GB = 23.7/23.7/43.5 ⇒ 预算尺寸的缓存**更慢**
   - 修: 单一写主 = `MLXModelLoader`；App 不再碰；`EnginePool` 初始化后打印**生效值** `buffer cache 256 MB … device ceiling 121 GB`
   - 门: 新增 `Class-H`（`scripts/audit.swift_patterns.sh`）钉第二写主，负例实测报 `❌ 1 violation(s)`，删后 `✅ All audits passed`
2. `6b3495d` **整机压力不再替别人买单：降级前必须与自己占用对账**
   - 红证: 本机游离 `python3.11`(pid 83993) 占 ~79 GB ⇒ `memoryUsageFraction` ~74% ⇒ level 3 ⇒ `route()` 判 `.cpu` ⇒ 每请求 `poolRef=nil`（KV 重建）+ 关投机解码；而 ocoreai 自己 3.5 GB / 70 GB 预算
   - 关键事实: Apple Silicon `wire_count` 含**所有进程**的 GPU 锁定页；绕过 SessionPool 反而增加分配抖动 ⇒ 这次降级**内存没省、吞吐花了**
   - 修: `HardwareRouter.pressureIsOurs(gpuFraction:reclaimableBytes:memSizeBytes:)`（≥½ 自有预算 或 可回收 < max(1 GiB, 物理/16)；未知即保护）；`route()` Tier‑1 加 `pressureIsOurs`（默认 true ⇒ 旧语义不变）；`EnginePool` 回调不再无条件 flush；日志不再声称换设备（设备在 `ModelContainer` 装载时绑定）
   - 绿证: `MemoryPressureCorroborationTests` 11 test；活体同一宿主同一游离进程下 `HardwareRouter → CPU` 3→0，只剩 `lane advisory … (degradation gated on corroborated footprint)` + `ignored: ours 0.0/70.4 GB — prefix caches kept`
3. `7b5b659` **`/v1/chat/completions` 跨会话串味：无 id 请求共用同一个 ChatSession**
   - 红证（三条互不相关、各一条消息的 POST）: A `19122`；B `10`；C「我第一个问题是什么？」**原样引用 A 的问题**；`prompt_tokens` 还会随时累积（4019→7152→10285）与实际送入内容不符
   - 根因两层: `conversationId ?? "<model>:ephemeral"` 折成同一 key；`acquire()` 命中只看 `divergence>0`，从不验证缓存历史是否来话前缀
   - 修: `ConversationIdentity.seed` = 首条 user 消息 FNV‑1a‑64（跨轮稳定 ⇒ 重放历史的客户端仍享前缀缓存；跨会话互斥；刻意避开按进程播种的 `hashValue`，否则落盘快照换进程找不回名字）+ `MLXSessionPool.canReusePooledSession(cached:commonPrefix:)` 硬闸门（顺带堵 GUI Edit&Resend 分叉）
   - 绿证: `SessionIsolationTests` 8 test；活体 C 不再知道 A，三条独立请求 `prompt_tokens` 稳定 718/712/710，同一会话第 4 轮仍答出 `PARAPET`
   - **测试当场抓出我自己的错**: FNV 质数写成 `0x1000_0000_0000_01b3`（多一组 0000）→ 低 32 位巧合相同、高 32 位全错；改 `0x1_0000_0001_b3` 后与标准向量逐位吻合
- 另: `be4b11e` `make format`/`format-check` 在 Xcode-only 主机上 `swift-format: No such file or directory` ⇒ 样式门 push 前根本跑不了（这正是 5 个文件漂移到 CI 的原因）；改为 `SWIFT_FORMAT ?= command -v … || xcrun swift-format`

## 排除项（查过，不是缺口，别再当低垂果实）
- **MTP 投机解码**: 默认 checkpoint `gemma-4-e2b-it-4bit` 的 index 与 safetensors 头**双双 0 个 mtp 张量**（2511 张量全扫）⇒ 日志 "Speculative decoding disabled" 是实话，没有免费的 1.5× 可捡
- **`EnginePool.swift:262` 「每请求查 router」**: 读码证真（`EngineInference.queryWithState`），非假声明
- **AGENTS.md `try!`=0 / `fatalError`=0**: 全仓命中全在注释里（6+5 处注释自称「无 as!/try!/fatalError」）⇒ 声明成立；`audit-facts.sh` 的 hygiene 计数会把注释算进去，看数字前先 `grep -v '^\s*//'`

## 待拍板 / 残留（不静默做）
1. **落盘 KV 快照无 `messageHistory`** ⇒ 复用闸门对它恒判可复用；首条消息逐字节相同、同模型的两条匿名会话仍可能撞 key 并从磁盘带回上下文。彻底堵住需把历史键随快照持久化，而 `MessageHistoryKey.contentHash` 用按进程播种的 `hashValue`（跨进程不可校验）——要换持久哈希，独立一轮。
2. **UI 四处声称设备切换** ⇒ 已由 `f226780` 关闭：`.cpu` 徽章改 `Guard`（+`exclamationmark.triangle.fill`）、吐司去掉 `GPU → CPU` 迁移图（顺带修掉把 SF Symbol 名 `arrow.right` 当可见文字的 `Text("arrow.right")`）、文案与 a11y 改「护栏启动」（`%@ → %@ — %@` → `%@ — %@`，en/zh 同改，新增 `A11y.MemoryGuard`）、Settings `routingPolicyFooter` 改写；Dashboard 徽章改由 `AppState.onThermalPressureEvent(_:actioned:)` 驱动，未过对账不贴徽章。**残留**：徽章/吐司像素仍未活验（GUI 交互整轮未活验）。
3. **`Memory.memoryLimit` 121 GB vs 应用预算 70 GB**: 预算目前只是调度记账，没落成设备上限；小内存机型上强设上限会提前拒载大模型 ⇒ 留人拍板。
4. **RAM clamp of context window**（`Engine/ContextWindowPolicy.swift` "Decision status"）——沿用上一轮，仍是人的决定；本轮起 `prompt_tokens` 已是真值，判断依据比之前硬。
5. GUI(SwiftUI) 交互与 iOS 门控仍未活验。
6. 本机那个占 ~79 GB 的游离 `python3.11`(pid 83993) 仍在——**它是** ocoreai 报 critical 压力/（改前）CPU 徽章的直接原因；清理由人决定（未擅自 kill）。

## 复现/门命令（沙箱外）
- build: `env HOME=/private/tmp/ochome DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build --scratch-path .build-clt -Xswiftc -F<CLT_F> -Xlinker -F<CLT_F>`
- 全量: 同上加 `swift test --scratch-path .build-clt --no-parallel --disable-sandbox -Xlinker -rpath -Xlinker <CLT_F> -Xlinker -rpath -Xlinker <CLT_L>`
- 活体: `(OCOREAI_ENABLE_HTTP=1 OCOREAI_PORT=8099 OCOREAI_ALLOW_MULTI_INSTANCE=1 ./.build-clt/arm64-apple-macosx/debug/ocoreai serve > /tmp/x.log 2>&1 &)` 于 escalated 会话内可常驻；curl 亦需 escalated
- 聚焦门: `--filter 'SessionIsolation|MemoryPressureCorroboration|HardwareRouter|EnginePoolRouting'` = 66 tests / 15 suites
