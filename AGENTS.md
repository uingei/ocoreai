# ocoreai — Project Context for AI Agents

> This file is loaded by the coding agent (Codex — CLI and desktop app) on every session. It anchors the agent to the project's conventions, architecture, and known issues — zero cold-start tax.

---

## AI Contribution Policy

This project is developed with heavy AI assistance. The rules:

1. **Every line in git is reviewable** — AI-generated or not, the owner approves each commit. "It came from the model" is never an exception to a rule in this file.
2. **No claim without a check** — "verified", "fixed", "aligned" in a commit message or doc must be immediately backed by command output (build/test/grep) in the same session.
3. **When in doubt, point outward** — if an upstream repo (mlx-swift-lm / coreai-models / codex) already has an answer, consume/reference it instead of authoring a local variant; cite the upstream file:line.

---

## Identity

**What it is:** an agent for open models, natively local — built for creativity, work, and code; a complete agentic system designed for coding and knowledge work. (09-27 canonical，用户三度给出此句为定版。09-27「open frontier models / coding and knowledge work」是其完整化表述，兼容并存、非互斥，不淘汰任一表述。） coding 最深切片 = Coding/Computer Agent (reliable Execute → Verify → Recover)；knowledge work / creativity (Apple 原生感知/多模态) = 一等产品面. Dual-channel on-device inference (MLX Metal GPU + CoreAI derived from coreai-models reference), agent loop with tool dispatch, skill system, session memory, multimodal I/O, ReasoningEventEmitter pipeline, persistent-perception pipeline. One binary.

**Tech stack:** Swift 6.2 · SwiftPM · Hummingbird 2.26 · SwiftUI · SQLite + FTS5

**Key modules:** subdirectories under `Sources/ocoreai/`: Engine, Agents, Client, Scheduler, MCP, Tools, UI, SQLite, Config, Multimodal, Reasoning, Profiling, Tokenizer, Security, Skills, Video, etc. (the full set is the directory listing itself — not counted here).

---

## Architecture (3-Layer Stack)

```
HTTP API Layer (Handlers/) → Router/Middleware
    ↓
Engine Layer (Engine/) — EnginePool(actor) → EngineInference → MLX/CoreAI backend
    ↓
Scheduler Layer (Scheduler/) — SchedulerActor, AdmissionGate, MemoryTracker, OOMGuard
    ↓
UI Layer (SwiftUI) — ChatViewModel, SessionManager(SQLite)
```

**Dual Path reality:**
- `EnginePool` uses inline `#if canImport(CoreAI)` branches (`BackendProtocol` deleted 2123143, 0 refs remaining)
- **MLX path reality:** `_runInferenceWithMessages()` → `ChatSession` (session pool, guided gen, toolDispatch) — ReasoningEventEmitter ✅ (wired, both MLX + CoreAI paths), KVCacheRuntime ✅ (`turboQuant`/`.affine` 双路 `MLXBridge.swift:757 case "affine"` / `:759 case "turbo-quant"`, 映射到 `.affine(:814/:819)` / `.turboQuant(:806)`). Pinned upstream `mlx-swift-lm` at `7eb77ef` (10-11 `80f0c01` round 9; #662 compiled decode Qwen3.5 VLM · #675 Gemma4 softcap fusion · #641 ChatSession cache fork · #679 component-aware checkpoint loading — 逐条裁决见 CHANGELOG round 9 + `4e4fcbc` Xcode resolved 同步; 前刀 #603 ModelCache 抽出: evict 真取消 in-flight load / DownloadProgress 按 model-id 分桶 / GrammarConstraint.clone 窄化 ← 09-23 `790d4df` CI 2080/385 绿; 前序 `c6446cf` #620 TokenIterator 首 token 即清 buffer cache ← 09-14 `3e6ea1e` ← #613 detok Character→Scalar ← #584 RotatingKVCache trim wrap-aware, 09-17 对齐 origin/main). **ThinkingBudget** ✅ (two paths wired: std reasoning `L4005 .applyingThinkingBudget` + MTP speculative `L3508 .applyingThinkingBudget` + `components: genComponents`/`mtpGenComponents` `L4020`/`L3531`（09-22 实核重钉）; `guard mtpReasoningConfig` 非空才接, `catch → .init()` 回退与 std 同语义).
- **CoreAI** — derived from Apple's coreai-models reference (BSD-3-Clause), simplified for ocoreai: types redefined locally to avoid macOS 27 platform requirement. Engine/ contains CoreAI* ×14 + StateHandler(+ ×3) + MPSGraphSamplers(1511L) + KVCache/TensorStorage(+CoreAI) (Engine/ 44 .swift total); + Tokenizer/TokenizersMLXTokenizerAdapter.
- **ANE path:** CoreAI `MPSGraphSamplers` (`MPSGraphSamplers.swift` 1511 行实存, `CoreAIPipelinedEngine.swift:53/601` 消费) wires MPS constrained argmax/composite/sampler — GPU-based constrained decoding path (c4c0a43 CoreAI .pipelined wired + 256e704 penalty/ConstrainedGenerationCapable routing)
- **MTP path:** `_runInferenceWithMessages` → `generate(::mtpDrafter:)` — bypasses ChatSession, tool calls collected + dispatched per-iteration (aligned with upstream `MTPSpeculativeTokenIterator`)
- **SessionPool:** Prefix-level prompt cache reuse via message divergence tracking; HardwareRouter pressure events trigger aggressive eviction; `loadPromptCacheSnapshot` restores LM state + KV cache

**Key:** `#if canImport(CoreAI)` single-layer compile-time gate; token sampling → `argmax`(greedy) / `multinomialSample`(temperature>0) — 真身 `Models/InferenceStubs.swift:198 sample(from:)`(temperature/topK/topP/minP filters, 对上游 CompositeSampler 算法); toolDispatch wired in both MLX + CoreAI paths.

**Upstream alignment:**
- `KVCacheRound` / `TurboFlash` / `TurboQuant`: consumed internally by upstream `generate*()` — no downstream intervention needed
- `KVCacheConfiguration`: full `.turboQuant` + `.affine` dual-path via `makeKVCacheConfiguration` (MLXBridge)
- `toolDispatch`: ocoreai closure → `ToolRegistry.call()` wired through ChatSession restart loop
- `MTP toolCall dispatch`: collected per `Generation.toolCall`, dispatched after each iteration, results appended to message history

---

## Build / Test / Lint

```bash
swift build -c release                    # production build
swift build --traits appStore            # App Store build (traits: appStore | FoundationModelsIntegration)
swift test                               # full suite — runs locally on macOS 26 IF the process is not sandboxed (Metal needed); CI macos-26 remains the authoritative gate
swift test --enable-code-coverage        # with coverage
swift test --filter SystemContextSensor  # one suite (substring match)
```

**Local gate reality (corrected 10-12, and it was wrong for weeks):** the full suite
**does** run on this host — `2277 tests / 428 suites` completed in ~400s on the CLT route
(`make test-clt`). The blocker was never the platform, metallib, or macOS 26: it was the
**agent sandbox**. Inside the sandbox MLX reports
`[metal::load_device] No Metal device available` and the first MLX-touching suite dies;
unsandboxed, the same binary loads a model and streams tokens. Two consequences that matter
more than the test count: (a) `ocoreai serve` + live `curl` against `/v1/*` is available
locally, and (b) that live loop found four defects no static audit in this repo had
caught — `/v1/count-tokens` 404 on a model `/v1/models` reports ready, `vlm:false` on a
model that answers images correctly, every grammar-constrained turn returning HTTP 500
after generating valid output, and fabricated `terminal command:` output on zero-tool
turns. **Prefer a live check over an inference whenever a claim is about behaviour.**

**Sandboxed route = compile + non-Metal tests, no approval needed (verified 10-13):** a compile gate does *not* require escalation. `HOME=<writable-dir> DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build --scratch-path .build-clt --disable-sandbox` goes green inside the agent sandbox. `--disable-sandbox` drops only SwiftPM's *own* nested sandbox for the package-manifest compile (nesting is impossible here: `sandbox-exec: sandbox_apply: Operation not permitted`); the outer harness sandbox still applies — the same run is denied writing `~/.cache/clang`, which is exactly why `HOME` must point somewhere writable. `make test-clt`'s `-F`/`-rpath` flags are still required for the Testing library, and `DEVELOPER_DIR` keeps it on the macOS-26 (no-CoreAI) route. Inside the sandbox pure-logic suites really run — `--filter 'SessionIsolation|MemoryPressureCorroboration|HardwareRouter|EnginePoolRouting'` = **79 tests / 15 suites green** — while Metal suites self-skip (`.enabled(if: MTLCreateSystemDefaultDevice() != nil)`) and `xcodebuild` cannot run at all (`xcodebuild: error: 'ocoreai.xcworkspace' is not a workspace file`), so the `test-ci` and `build-ios` legs stay CI's job. Tiering: sandbox → build + non-Metal suites; escalation → full suite + live `serve`/`curl`; `xcodebuild` legs → CI.

**Linting:** none — aligned with upstream (mlx-swift-lm / coreai-models ship no swiftlint). swift-format via `.swift-format` (pinned 603.0.0) is the only style gate, enforced in CI and pre-commit. Crash-safe coding (no `try!`/`as!`/`fatalError` in Sources/) is a code convention, not a CI gate.

**Build verification is MANDATORY** before claiming completion. `swift build` exit code 0 = done.

---

## Code Conventions

### Concurrency
- Swift 6.2 strict concurrency mode. `Sendable` enforcement active.
- `EnginePool` is an `actor` with `@unchecked Sendable` mutable state (perform-based isolation). Every `@unchecked Sendable` declaration carries a justification comment.
- UI layer runs on `@MainActor`. Engine layer is actor-isolated. Cross-actor calls via `await`.
- `@unchecked Sendable` requires justification comment. Closure `var` declared inside closure scope (not outer).
- **A polling loop sleeps one poll interval, never the deadline.** `Task.sleep(until: deadline)` inside `while <still pending>` parks the waiter for the whole window regardless of when the condition clears. `EnginePool.waitForLoading` did exactly this (10-13: the first chat request cost 120 s for a model ready in 8 s; fixed to `min(deadline, now + 100 ms)`, release timing pinned by `EnginePoolLoadingGateTests`). Sleeping to the deadline is correct only in a single-shot watchdog — see `EngineInference.swift:149`.

### Compile-time gates
- **A `#if canImport(X)` must name the dependency the code inside actually uses.** Gating on a framework the block does not import silently deletes working code on every platform where that framework is missing. Concrete failure this rule comes from (10-12): `Tokenizer/TokenizerManager.swift` was gated `canImport(CoreAI)` while its only dependency is swift-transformers `Tokenizers` (unconditional product, `Package.swift:97`) — CoreAI is macOS 27 only, so on the macOS 26 delivery platform the real tokenizer was compiled out and a same-named no-op stub in `Models/InferenceStubs.swift` took its place (`registerTokenizer` = `{}`, `getTokenizer` = nil), while the log still claimed "context wall on real token counts".
- **A stub that replaces a real component must be detectable at runtime, not only at compile time.** `TokenizerManager.isRealTokenizerBackend` (true in the real actor, false in the stub) is the pattern: published on `/v1/capabilities` as `tokenizerBackend: real|heuristic`, it decides which wording the engine may log, and a test asserts it — so a silent substitution fails the gate instead of shipping.
- **Never gate a capability surface on a backend axis.** `canImport(CoreAI)` means "this SDK has CoreAI"; it says nothing about Metal, vision processors, or tokenizers. When a gate is about a capability, gate on that capability's real requirement.

### Error Handling
- Precondition near-free: production code uses precondition/preconditionFailure only for structural invariants and upstream-verbatim numeric/speech surfaces; new code must not add them. **Full-scan verified (12 sites / 9 files):**
  - Video/DiscreteFlowScheduler (`precondition` ×2)
  - Video/TiledDecode3D (`precondition` ×1)
  - Multimodal/StreamingWindow (`precondition` ×1)
  - Engine/CoreAIPipelinedEngine (`precondition` ×1)
  - Engine/KVCache+CoreAI (`precondition` ×1)
  - Engine/CoreAIStubs (`precondition` ×2)
  - Engine/GuidedGeneration/PipelinedConstrainedDecodingStrategy (`preconditionFailure` ×1)
  - Engine/GuidedGeneration/XGrammarWrapper (`preconditionFailure` ×2)
  - Engine/GuidedGeneration/TokenizerInfo (`preconditionFailure` ×1)
- **Zero `try!`** in production code.
- **`print()`:** 0 in production code (18→0 at commit 4c231d3).
- **`fatalError`:** 0.
- `assert`: **0** (no `assert(` outside `precondition*` in Sources/).
- `try?`: used as the defensive-fallback pattern; `try?` stays acceptable where a real fallback follows.
- `ErrorContext.swift` does not exist (grep = 0).
- `Profiling/` contains **2 files**: `TimingHooks.swift` + `PerformanceMetrics.swift`.

### Naming
- Target names ≠ module boundaries (e.g., `GuidedGenerationLoop` is peer to `ChatSession`, not nested).
- TODO 计数 09-22 重核 = **1** (原 3, #206 后 `1bef69b`/`088a0b7` 各清 1): 现存 `CoreAIInputEmbeddings.swift:36` (origin 系 `4517ca3` from coreai-models absorb)。references/ 本地不在, "upstream HEAD present" 无法当场复核, origin 以 git 历史为准。

### Testing Quality
- Gold standard: `ThinkingBudget`, `ComplexityAnalyzer` — exact value assertions (`#expect == N`), parameterized traversal, boundary assertions. (BlockPool gold-standard test removed with the module at upstream 2b3c965.)
- **Reject** `count > N` weak assertions.
- Test modules: Scheduler lifecycle + concurrency, OOMGuard (full), MemoryTracker (partial gaps), AdmissionGate (partial gaps), HardwareRouter (Mirror + Integration — see table below).

---

### Open (currently unresolved — the only items worth prose)


- **iOS UI parity** (UI/) — 09-22 实证：工具层平台门控已核 = 正确（10 个 macOS-only：move/click/drag/scroll/type/key + inspect_ui(AX) + open/activate/list_apps(NSWorkspace)，均 macOS 平台语义）。10-13 落三处编译门，逐条以 iPhoneOS 27 SDK 一手证据核对（不凭印象）：`HSplitView` = `@available(iOS, unavailable)`；`navigationSubtitle` = `@available(iOS 26.0, macCatalyst 14.0, macOS 11.0, *)` 而 target 是 `.iOS(.v17)`；`UIPasteboard` 只有 `dataForPasteboardType:`（`UIPasteboard.h:79`；`dataForType:` 是 AppKit 拼法）。复扫排除的误报：`keyboardShortcut`/`.help` = `@available(iOS 14.0, …)`、`UTType`、`AVCaptureDevice.requestAccess` 均可用。仍开 = iOS **运行时**零验证（沙箱内 `xcodebuild` 起不来，编译面由 CI job `build-ios` 把关），MCP/Security on iOS TBD，ChatView/MultimodalControls 的 UI 门控仍需活验。
- **Reasoning `<thinking>` parse** (Engine/) — 字符串协议状态机（`ThinkTagParser`，0 处 regex，#206 后 15/15 绿），无 AST。
- **`kvCacheRuntimeReport`** — ~~not consumed~~ → 09-22 实证：ocoreai 走**自有等价消费面** `Metrics.kvCacheGpuBytes`(`ocoreai_kv_cache_gpu_bytes`, Metrics.swift:79/196)→ `ServerStatsSnapshot.kvCacheBytes` → Dashboard `kvCacheGB`(DashboardViewModel.swift:107)。上游 `KVCacheRuntimeReport`(KVCacheRuntime.swift:155) 是另一套 wrapper，#248 已判 ocoreai 无此 wrapper 的 bug —— 接它 = 本地重复面，不做。
- **MLXFoundationModels** — FM 路 wired（`#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)` + Package.swift L26 默认开）。 ~~lacks per-token callback on FM `.done`~~ → 09-22 实证假缺口：per-token 走 `yieldParserEvents → continuation.yield` AsyncStream（EngineInference.swift L430-470 等，与 std MLX 路同构），不依赖 `.done` 回调（`.done` 只是收尾信号）。上游 0 处 onStreamChunk 概念——此条 phantom gap 撤回。
- **Hygiene — do not add new**: `precondition` (structural invariants + upstream-verbatim); scattered `try?` defensive fallbacks (~316 in Sources/); 2 bare `empty catch {}` in the EngineInference watchdog.
- **Coverage report** — Tests/CoverageReport missing (no live data).

**Resolved items** (ThinkingBudget wiring, SyncInputHandler, ChatConventionsRegistry, AgentLoop pruned, KVCache typed config, MTP, TurboFlash, CoreAI grammar, PagedKVCache removed, ReasoningEventEmitter, HardwareRouter/AdmissionGate tests, 0 fatalError): not restated here — source of truth is `CHANGELOG.md` + `~/wiki/concepts/upstream-mlx-swift-lm*.md` + `~/wiki/concepts/upstream-coreai-models.md`.

---

### Upstream Audit Dependencies

Four sources for empirical verification:
1. **mlx-swift-lm** — pinned in `Package.swift` at `7eb77efa4`（L41 `revision:`；10-11 round 9 `80f0c01` adopt `7eb77ef` +12，前刀 09-23 `790d4df` bump: #603 Extract the model cache — evict 真取消 in-flight load / DownloadProgress 按 model-id 分桶 / GrammarConstraint.clone 窄化; CI 2080/385 绿）。前序链 `3e6ea1e` #548/#515 ← `604fae7` #584/#613/#615/#611/#597。0 drift（10-12 离线复核：`references/mlx-swift-lm` origin/main = `7eb77ef` == pin；本机当日 11:01 fetch，无网络故不走 `gh api`）。**Bump 协议**：`git log <old>..origin/main` 逐条审计消费面 → bump `.revision` → `swift build` + `make test-ci` 绿 → 审计行记入本节 + CHANGELOG（Package.swift 只留 pin + 指向本节的指针，不写逐 commit 日记）。
2. **coreai-models** — reference at origin/main HEAD `52dbd93`（10-12 本地 clone 复核 = `.upstream-baseline.json` 同点 → 0 新 commit；前序 `e7b24da` 之 +5 已由 10-11 `b9c61e7` 裁决吸收）。`e282dbd..89ba0d4` 5 commit 历史: `#237` 已吸收（`cd9e901`）· `#248` 0 ocoreai 消费 · `#249` 行为等价重构 · `#250` Tools/llm-server tree · `#251` 已吸收（`3497ae8`）。**`89ba0d4..e7b24da` 17 commit 逐条核验（09-27 审计）**：已吸收 `#265` seeding (`4cd0d36`) · `#268` KV-state growth (`e4def0d`) · `#274` prefill threshold (`85a85f5`)。Python/diffusion/SAM3/noise-source/INT4-recipe axis 9 commit: consumer-transparent by axis (ocoreai 无 Python/diffusion 消费面)。剩余 Swift engine 面 5 commit: `#271` xmlFunction/ToolCallDetection = 0 生产面 (Qwen3-Coder 不在 ocoreai surface) · `#267` reasoningTemplateContext = ocoreai 已有 `ContextOptions.reasoningLevel` + `ReasoningResolution.thinkingEnabled`(09-24) · `#258` idempotent engine = ocoreai 已有 pool prefix-match · `#266` ReplayRunner = llm-server Tools/ tree (0 ocoreai hits) · `#290` dead-code removal (0 ocoreai hits)。**3 已吸收 + 0 行为分叉 + 0 强制缺口。** Reference repo, not SPM dependency。#206 absorbed (`1076948`)；ATEM `Format.agentic` NOT absorbed（0 consumers）。
3. **codex** — 语义轴参照（非 SPM 依赖、非逐 commit 复制）。基线 `6a39914 → 99f7758`（09-27 drift 轮 adopt）→ **`→ 1cc7e2361`（09-28 drift 轮 adopt）** → `cc7ba3360`（10-11 `b9c61e7` +160 裁决 adopt——**该轮只落 state 文件，未写本行与 CHANGELOG，本行补记**）→ **`a9b081516`（10-12 drift 轮 adopt）**。`cc7ba3360..a9b081516` 11 commit 逐条裁决（10-12 consumer-transparent 双根全扫；源 = 本地 clone `references/codex` origin/main=`a9b081516`，当日 11:09 fetch，无网络不走 gh api）：① TUI 轴 `#53224` Windows clipboard paste · `#53173` restart managed background servers · `#53156` custom terminal drawing API · `#53153` subagent nav shortcuts · `#53152` select/copy turn tips —— 双根 `background.?server`=0 / `subagent|sub_agent|delegate_task`=0 / `\bvim\b`=0，ocoreai = SwiftUI GUI 无 TUI 消费面；② app-server/remote 轴 `#53155` events deliverable during shutdown · `#53049` connection-bound reply handles · `#53150` thread-owned permissions on cold resume —— `git grep -iE "app.?server" Sources/` = **0**，ocoreai 生命周期自有语义 = `EnginePool.shutdown()` cancel+await（`EnginePool.swift:1412`），无 remote 事件队列面；③ CLI 轴 `#53109` broken pipes in plugin list —— Swift/Darwin 默认 SIGPIPE=ignore（写断链不 trap），真正依赖管道语义的子进程 stdin 已处理（`ExecSessions.swift:125`）；④ `#53148` startup draft recovery for Vim Replace keys —— vim 模式 0 消费，而其**轴**（启动期草稿不丢）早已消费：composer draft 上收 `ChatState.shared`（`ChatViewModel.swift:157`，引 codex `#46750`）。**11/11 consumer-transparent，0 强制缺口，0 ocoreai 生产面变更**。唯一从轴里抽出的**原则**=「可读文本即可选」→ 本地落刀（transcript `textSelection`，见 CHANGELOG 10-12）；唯一**显式不采纳**= `#53150` 授权跨 resume 持久化：ocoreai 审批刻意按 turn 清场（`ChatViewModel.swift:1543` → `ApprovalBroker.cancelAll()`），跨冷重启回填授权 = 信任模型变更，留人拍板、不静默做。`99f7758..1cc7e2361` 8 commit 逐条裁决（09-28 consumer-transparent 双根全扫，非轴词粗筛）：全落 codex 自有轴——① TUI 渲染/交互（`#48807/#48814` Mermaid 标签标点 · `#48827` Ghostty/Kitty hand pointer · `#48830` TUI interruption notice）——ocoreai = SwiftUI GUI，双根全扫 `mermaid|ghostty|kitty|hand.?pointer|interruptionNotice` = **0**（TUI 轴无消费面；注意 ocoreai 77 处 `prewarm` 全是**模型引擎预热**轴 ≠ codex `#48812` "prewarming for idle threads"（TUI 会话线程轴），同名不同义）；② `#48819` histogram tool/skill context metrics——ocoreai `Metrics/Metrics.swift` 22 处 histogram 是**自有 engine 指标面**，`tool|skill` 相关 = **0**，非同轴；③ `#48824` voice RTP 20ms——ocoreai `AudioIO/RTP` 9 处是**自有实时音频传输面**，非 codex voice-agent 轴；④ `#48828` archive thread before first turn——ocoreai 会话**不**支持"首 turn 前归档"语义（SessionManager SQLite 语义 = turn 落库才成会话），双根 `archive.?thread|archiveSession` = **0 消费**；⑤ `#48829` Windows sandbox provisioning service——ocoreai 无 sandbox 轴（09-27 `#48565` seatbelt 全仓 0 命中同判），双根 `sandbox.?provisioning|provisionService` = **0**。8/8 consumer-transparent，0 强制缺口，0 ocoreai 生产面变更。持续跟进：`bash scripts/upstream-drift.sh`（check/adopt）+ `.upstream-baseline.json` 版本化基线 + 每日 cron 只读自检；新窗口 = 裁决清单（consumer-transparent 双根全扫为权威，轴词粗筛仅提示）。
4. **Apple Developer Docs** — developer.apple.com/documentation/CoreAI (requires login)

**Wiki:** `~/wiki/concepts/upstream-mlx-swift-lm-38927f5-intent.md` + `~/wiki/concepts/upstream-coreai-models.md` — consumption matrix with file:line evidence.

---

## Documentation Map — Agent-facing vs Human-facing

**Rule of thumb:** if the text is *injected into the model's context at runtime*, it is **Agent-facing** — changes alter model behaviour and require an inference regression. If it is read by people (humans or future agents) to understand the project, it is **Human-facing**.

| Doc | Audience | Why | When to touch |
|---|---|---|---|
| `AGENTS.md` (this file) | **Agent** (Codex, every session) | Injected as project context on cold start | Conventions / architecture facts drift — keep line-accurate |
| `Sources/ocoreai/Skills/SystemPromptBuilder.swift` | **Agent** (LLM context) | Builds the base + skills system prompt | Prompt-wording changes = behaviour changes — needs inference regression |
| `Sources/ocoreai/Tools/ToolEntry.swift` (+ `Tool*.swift`) | **Agent** (LLM context) | `description` / JSON schema are consumed by the model as function-calling contracts | schema/wording changes = tool-call behaviour — test with live model |
| `Sources/ocoreai/Parsers/*` (`ThinkTagParser` etc.) | **Agent** (implicit) | Defines what the model may emit (marker tags) | marker changes break both parse and parse-back — hexdump-verify parity with upstream |
| `README.md` / `README.zh.md` | **Human** | Entry point for humans | Feature surface changes |
| `CHANGELOG.md` | **Human** | Per-feature provenance, commit refs | Every user-visible change (see Workflow) |
| `CONTRIBUTING.md` | **Human** | How to contribute | Process / tooling changes |
| `ARCHITECTURE.md` | **Human** (historical) | Point-in-time architecture review (2026-07-26) | Do not edit — superseded by `docs/*` + wiki |
| `SECURITY.md` | **Human** | Threat model + reporting | Trust-model / network-surface changes |
| `docs/CONTEXT.md` | **Human** (stale) | v2 context from 2026-06-24 | Do not edit — superseded by `AGENTS.md` + `CHANGELOG.md` |
| `docs/precise-tasks.md` | **Agent + Human** | Coding-task taxonomy + gates | 09-14 fixed — was using nonexistent `--traits mlx` flag; MLX is a hard dependency, plain `swift build` |
| `docs/prompt-ocoreai.md` | **Agent** | 自主推进协议（定位/第一性四条/每轮闭环/停止判据，09-22 定稿）| **按需持续维护**（用户授权）：声明与代码脱节、判据失效、损耗点变化时直接改本文件 + commit 尾注说明原因；改完每条须可 grep 实证 |
| `docs/plans/agent-os-dual-mode-architecture.md` | **Human** (plan) | Proposed dual-mode prompt architecture — **not yet implemented** | Promote to implementation plan when adopted |
| `CHECKPOINT.md` | **Agent (transient)** | Live-work checkpoint, overwritten each round | Not stable — do not cite as source of truth |
| `~~.status.md~~` | — | Tracked in git (listed in `.gitignore` L37 but committed earlier) — status snapshot | Do not cite — point-in-time |

**Agent-facing change discipline:**
1. Identify the behaviour that will change (tool schema / prompt wording / marker).
2. Add or extend a regression test (exact-value `#expect`, not `count > N`).
3. If it touches `SystemPromptBuilder` or `ToolEntry` description/schema: run `make test-ci` — the model-behaviour tests in `Tests/ocoreaiTests/` pin the contract.
4. **Never** change a marker literal (e.g. `think`) without hexdump-pairing it against the upstream reference (display layers strip angle brackets — see `ThinkTagParser` audit).

---

## Wiki / Knowledge Base

- **Location:** `~/wiki` (Obsidian vault)
- **Known issue:** Time-aging distortion — wiki pins HEAD but repo advances. Concept pages say "implemented" ≠ actually in Engine.
- **Verification:** `git merge-base --is-ancestor $wiki_head $real_head` + grep for file existence + symbol grep
- **Local scratch dir is not truth:** `.hermes/` is gitignored (`.gitignore` L29) and today holds only `.hermes/plans/2026-10-09_first-principles-roadmap.md`; there is **no** `.hermes/audits/` (10-12 `ls`). Untracked files cannot be shared project evidence — cite `CHANGELOG.md` + `~/wiki/concepts/*` instead, and treat that roadmap as historical wherever it conflicts with this file.

---

## Workflow

- **Direct commits to `main`** — no branch ritual; the CI gate (`make test-ci` equivalent on macos-26) is the authority, run green before push
- Every commit message: what changed + verification evidence (test count / command output)
- One logical change per commit
- `CHANGELOG.md` updated with every user-visible change (commit reference mandatory)

---

## Core Principles

1. **First-principles thinking:** Reason from goals + constraints, not from habit or template-matching. If the goal is ambiguous, stop and confirm before guessing; if the goal is clear but the path is suboptimal, propose the shorter, cheaper, more readable alternative directly.
2. **Precision:** Touch only what must be touched. Do not refactor code that isn't broken, do not improve adjacent comments/formatting without explicit permission.
3. **Terminology:** Use the vocabulary already in the repo. Before introducing a new symbol, grep for existing mechanisms first — avoid the "false-negative then reinvention" failure mode (e.g., seeing no `Compact*` and creating `InferenceCompactor` when `ConversationCompaction` + hooks already exist).
4. **Honesty:** Maximum truth-seeking, maximum curiosity, honesty — not human-preference alignment. Failure means reporting the failure accurately; never fabricate a success, never dress up a broken result as working.
5. **Simplicity:** Solve the problem with the minimum code; any extension must serve the stated question.

These complement — and are not replaced by — the existing Rule 3 (upstream alignment) / Rule 5 (citations) above.

## Agent Execution Rules

1. **Three-layer verification mandatory:** grep → compile verify → read matched lines. Single-layer check = speculation, not fact.
2. **Code changes require `swift build` verification.** exit code 0 = done.
3. **Never introduce `try!`, `as!`, `fatalError`, `assert`, `precondition`, or `print()` into production code.**
4. **Cross-actor calls must use `await` or `SerialAccess` pattern.**
5. **Audit conclusions must cite file:line + commit hash.** "Based on code evidence" vs "inference" must be explicit.
6. **Upstream API verification:** Before citing an API as available/missing, check all 3 upstream sources.
7. **All findings verified via tool output** — no speculation, no estimation.

## Agent Runtime Reality (Codex)

**Who works here:** the coding agent is **Codex** (CLI + desktop app), model family `gpt-6.x`, driving this repo through `exec_command` / `apply_patch` plus the MCP tools the harness lists. It is **not** Hermes and it is **not** served by Ollama. The id this section used to name (`qwen3.8:27b-mtp`) is `OCRE_SEARCH_MODEL` — ocoreai's opt-in web_search backend model (`Sources/ocoreai/Tools/WebSearchTool.swift:346`), reached only from `Sources/ocoreai/Tools/DirectWebSearch.swift:532`/`:540`, i.e. `OCRE_SEARCH_MODE=backend|auto`; the default `native` path (`:529`) needs no local server. It was never the model writing code — that conflation is why the old constraint read as platform physics when it was not.

**Skills:** the authoritative list is the one the runtime injects into its own system prompt. On disk, `~/.codex/skills/.system` = imagegen, openai-docs, review-agent, skill-creator, skill-installer (10-12 `ls`). All four names previously listed here — `single-pass-orchestration`, `code-review-discipline`, `hermes-agent`, `ocoreai-dev` — are **dead pointers**: `find` over `~/.codex` and this repo returns 0 hits (10-12; same class as the earlier `engineering-grilling` / `code-audit-methodology` cleanup). Nothing was lost by deleting them — their substance is already this file (Build / Test / Lint + Agent Execution Rules).

**Sub-agents:** Codex *can* fan out (`spawn_agent`, parallel tool calls). The default stays one-pass — intent → plan → implement → review → verify → commit inside a single response, and no sub-agent unless the owner asks. Two reasons survive the tooling change: the owner reviews every commit, so a fan-out nobody reads adds no assurance; and local verification is serialized regardless — `swift build` / `swift test` share one scratch path (`.build`, `.build-clt`), so parallel jobs contend a lock instead of saving time.

**Unchanged gate:** three-layer verification (grep → compile → read the matched lines), `swift build` exit 0 before any completion claim, `make test-ci` as CI authority, and a CHANGELOG ref for every user-visible change.

**Escalation review is broken on this host (10-13):** `approvals_reviewer = auto_review` asks the configured provider (`~/.codex/config.toml` → `model_provider = omlx`, `base_url = http://127.0.0.1:8000/v1`) for a model named `codex-auto-review`, which that server does not serve → `404 … Model 'codex-auto-review' not found`, and the escalated command never runs (two calls rejected this way; a review-service failure, not a safety verdict). Consequence for this repo: anything needing Metal or `xcodebuild` currently cannot be verified locally at all — use the sandboxed route above and leave the Metal-heavy full suite and the `xcodebuild` legs to CI. The fix is host config outside this repo (serve/alias that model on the provider, or repoint the reviewer): owner's call, not something to route around.
