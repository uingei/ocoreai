# ocoreai checkpoint (10-12 round 13 — 活体回路解锁 + 四条静态审计看不见的缺陷修死)

## 本轮最大收获：本机活体回路其实一直可用（此前记录是沙箱属性）
- 沙箱内: `MLX error: [metal::load_device] No Metal device available` ⇒ 全量测试死于首个 MLX 套件、`serve` 起不来
- **沙箱外（escalate 后同一二进制）**: GPU 可用，`ocoreai serve` 冷启动 6s（模型 3.5s + prewarm 1.1s），`/v1/*` 可 curl，**全量 `swift test` 2277 tests / 428 suites 全绿 / 399s**
- 沙箱外常驻姿势（`setsid` macOS 无；`nohup &` 会被杀）: 用 tty 会话把 `serve` 放前台，另开会话 curl；`HOME=/private/tmp/ochome DEVELOPER_DIR=/Library/CommandLineTools`，`.build-clt` 需 `-F/-rpath` 四段
- 结论写回 `AGENTS.md` Build/Test 段:**活体优先于推断**——本轮 4 条缺陷全部只有活体能抓到

## 本轮落刀（4 条，全部先有活体红证再修绿）
1. **macOS 26 上真分词器被编译掉**（`Tokenizer/TokenizerManager.swift:19` `#if canImport(CoreAI)` 冒充 `Tokenizers`；stub 顶替 ⇒ `register` = `{}`、`get` = nil）
   - 红证: `/v1/count-tokens` 对 `/v1/models` 自报 ready 的同一 id 返回 404；日志 `Tokenization failed` 6 次；日志却仍打 "context wall on real token counts"
   - 编译期探针: `canImport(CoreAI)==false` / `canImport(Tokenizers)==TRUE`
   - 修: 真身改 `canImport(Tokenizers)`；stub 块按依赖拆（tokenizer→`!canImport(Tokenizers)`，CoreAI 类型仍 `!canImport(CoreAI)`）；两侧 `isRealTokenizerBackend`，`/v1/capabilities` 出 `tokenizerBackend`，日志按后端措辞
   - 绿证: `TokenizerBackendTruthTests` 3 test（含 hermetic WordPiece 精确 `ids==[2,3]`）；活体 count-tokens `{"prompt_tokens":19}`、`Tokenization failed` 6→0、prompt_tokens 708→713
2. **一个事实两套谓词 ⇒ 图像能力在 wire 上说谎**（discovery 5 处只测 `preprocessor_config.json`，加载侧 `MLXBridge.swift:115` 只测 `processor_config.json`；UI 两处把 `entry["specialized"]` 当 VLM）
   - 红证: `/v1/models` `vlm:false`，同模型同目录真发图答对 `Red`
   - 修: `ModelStore.hasVisionProcessor(at:fileManager:)` 唯一谓词（皆收两文件名，镜像上游 `VLMModelFactory.swift:549-556`）；5 处 + `isVLMModel` 全委托；UI 解析读 `"vlm"`
   - 绿证: `VLMCapabilityTruthTests` 6 test（含"加载器与发现逐目录一致"）；`PipelineCoverageTests.fromList*` 原样钉着旧键 ⇒ 按更正契约改判 + 加"specialized 不得判 VLM"；活体 `/v1/models` `vlm=True`
3. **语法约束轮跑完不关流 ⇒ 成功轮次统一 500**（guided 分支归还池并把 `chatSession` 置 nil，`handleGuidedGeneration` 全函数 0 处 `finish()`，调用点不 `return`，落到标准路径撞 nil 追加 `.error`）
   - 红证: `json_schema` → 500 `no active chat session`（文本已生成）；`tools` 空 schema → 同 500；`nil chatSession` 2/2
   - 修: 谁拥有这轮流谁收尾——函数成功/吸收路径末尾 `finish()`，两处早退补 `finish()`，调用点后 `return`
   - 绿证: 活体 `json_schema` → `200 {"result": 4\n}`；`curr_time` → `200 finish_reason=tool_calls`；`nil chatSession` 计数 0
4. **prompt 与工具面分叉 ⇒ 模型编造执行结果**（10-06 把 wire 默认工具面收成 0，prompt 仍命令"用你的工具跑命令"）
   - 红证: 零工具轮 "Count from 1 to 60" → `terminal\ncommand: "seq 1 60"\nstdout: …`；声明 `web_search` 后无 tool call 却写 "I have searched the web …(Source: https://mlx.studio/)"
   - 修: `codingAgentIdentity` / `toolActionDirective`（+claim-discipline）/ `noToolsDirective` 三段；`build(hasTools:)` 组装且 **`hasTools` 进 hash**；`MessageBuilder` 用 Phase 5 同字段传真面；`App` 传 identity-only；`codingAgentBase` = `basePrompt(hasTools:true)` 别名
   - 绿证: `SystemPromptContractTests` +3 test（含"工具面进缓存键"）；活体直答 `1..60`、伪造指纹 False；web_search 两轮均真 `tool_calls`
- 另: README/README.zh 端点表补 6 条已注册但从未公开的端点（`/v1/tools`、`/v1/capabilities`、`/v1/embeddings`、`/v1/steer`、`kv-cache`），public 名单与 `AuthMiddleware.publicPaths` 对齐；`.codex-tmp/` 补进 `.gitignore`（原先未忽略）

## 门
- `swift build --build-tests`（CLT）exit 0；**全量 `swift test` 2277 tests / 428 suites 全绿（399s，沙箱外）**
- swift-format（本机 xcrun，version=main）16 个改动文件 format-stable（0 会被重排）

## 工作树状态（重要）
- **工作树含两轮**: 上一轮 27 项（Edit&Resend / ComposerIngest / ContextWindowPolicy / 全局 FTS 修复 / env 契约 / `.env.example` / AGENTS 运行段 / drift 基线）+ 本轮 ~18 项；`git status` = 39 M + 10 ??
- **不可拆提交**: `EnginePool.swift`（本轮也改）引用了未跟踪的 `ContextWindowPolicy.swift` ⇒ 只提我的文件会让 HEAD 编译不过 ⇒ 要么整树提交，要么继续搁置
- `.git` 在本会话沙箱内只读（permission profile），提交需 escalate；两轮均未提交

## 未决（留拍板 / 下轮）
- **本机内存夹逼 context window**: 仍是 owner call（`ContextWindowPolicy.swift` "Decision status" 记明）；注意改后新事实——macOS 26 现在有**真 token 计数**，窗口封顶终于能用真数字而非字节启发式来判断
- GUI 活体验: SwiftUI 交互（Edit&Resend 编辑器焦点/⌘↵、框选复制、Params sheet 拖拽、iOS 门控）仍未活验；本轮解锁的是 headless serve + HTTP 线级
- `#53150` 授权跨冷重启持久化 = 信任模型变更，刻意不采纳
- 可疑但未追: 每次请求前 `HardwareRouter → CPU … Mem: 74.3%` + `ThermalPressureEvent: memory gpu→cpu`（128GB 机器上仅载 1.5B 模型时出现，疑似把 cache/compress 计入 used ⇒ 长期降级 CPU）；`Critical memory pressure (level 3)` 同疑。**下轮值得量化**: 同一 prompt 在 gpu/cpu 两通道 tok/s 对比
- `/v1/tools` 之外，README「Known boundaries」的 `CI: last green run deee580` 等具体号会过期，未逐条复核

## 下轮方法论提醒（写死）
- 「grep=0 ⇒ 不存在」之前必须换工具或读原文区间二次确认（上轮 `OCOREAI_` 误打 `OCREAI_` 差点误判死杠杆）
- 「测试全绿 ⇒ 能力成立」不成立: 本轮 4 条缺陷全在 2277 tests 绿的状态下活着，因为要 Metal + 真模型 + HTTP 才可达；能力类断言优先跑活体
- `#if canImport(X)` 必须 X = 块内真实依赖（AGENTS.md 新增「Compile-time gates」条）
