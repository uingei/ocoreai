# Changelog

All notable changes to **ocoreai**. This project adheres to [Keep a Changelog](https://keepachangelog.com/) conventions.

## [Unreleased] — 2026-08-14 → 2026-08-26

### Features

- **Qwen3.5 / Qwen3.6 MTP self-speculative decoding — registration + guard alignment** — The engine guard at `EnginePool.swift:643` previously hard-encoded "Gemma-4 only" and warned out Qwen3.5/3.6 requests even though ocoreai's own `ConfigStruct` doc and the pre-feature CHANGELOG advertised Qwen MTP ("use `mode: 'mtp'`" for Qwen3.5). Two fixes:
  1. Register the upstream `Qwen35TextMTPRegistration` (type strings `qwen3_5` / `qwen3_5_text` / `qwen3_5_moe` / `qwen3_5_mtp`) and `Qwen35VLMMTPRegistration` in `EnginePool.init`, alongside the existing `Gemma4AssistantRegistration`. Qwen3.6 rides the same `qwen3_5*` type family in the upstream registration comments.
  2. Extend the guard at `EnginePool.swift:643` to branch on both Gemma-4 **and** Qwen3.5/3.6 model ids (`lowerId.contains("qwen3.5") || lowerId.contains("qwen3.6")`). For Qwen, pass the **same `modelId`** to `loadMTPDrafter` — the drafter is self-spec, pulling `mtp.*` weights from the main model's own checkpoint (upstream `Qwen35MTPDraftModel` only attaches `@ModuleInfo(key: "mtp")` and sanitizes the rest away). Gemma keeps the dedicated `*-assistant-bf16` checkpoint path.
  Exact-value surface test (`MTPDrafterRegistrationSurfaceTests`, 7 cases): `MTPDrafterTypeRegistry.shared.contains(_:) == true` for `qwen3_5`, `qwen3_5_text`, `qwen3_5_moe`, `qwen3_5_mtp`, `gemma4_assistant`; `== false` for `qwen3_4`, `llama4`. Closes the ocoreai-vs-`ConfigStruct` doc fork.
- **Pin bump: mlx-swift-lm `1441444` → `6745899`** — absorbs upstream commits since 08-25: #575 parallel byte-balanced weight loading (measured 1.8× faster model loads, ~5.9 GB/s on M4 Pro — free consumption, no ocoreai code), #329 variance-normalized KV cache (new opt-in strategy; ocoreai `makeKVCacheConfiguration` dual-path unchanged — explicit, not exhaustive switch, zero drift), #576 LFM2VL image-token-id-from-vocab (no LFM2VL consumers in ocoreai), #571/#574 SSM gradient fix+tests (training-side)。事件面核对: `.rejectedToolCall` 已在两处消费（EngineInference.swift:3349/3914），无 `TokenStreamEvent` exhaustive switch——pin bump 无事件面断裂。
- **MCP tool results: non-text content preserved, no more hard-fail (codex `75cb7c9` / #40737 baseline)** — `MCPBridge.renderToolResultBlocks` 静态核心: text 块逐字拼接（`\n---\n` 分隔），非 text 块（`image`/`audio` 等）渲染为显式占位符（`[image]`…）而非 `throw "No text content"` / 静默 `(no content)` / 丢弃。三条工具结果通路统一接线（forward、registered-handler、local-call）。8 个精确值测试（`MCPToolResultRenderingTests`）。

- **Context-window compaction before the 400 wall (codex `compact.rs` 范式)** — `ConversationCompaction`（`Reasoning/ConversationCompaction.swift`，197 行，确定性 LLM-free 核心）：当 prompt 估算超过 per-model `max_context_window` 时，从 OLDEST 完整可移除单元开始压缩，保护前缀 system + 最近 N 轮，且绝不把 tool result 与其发起的 assistant 轮拆散（原子单元移除）。Token 估算与 Phase 3 heuristic 逐字一致（UTF-8 bytes/4，CJK>1.5 走 /3），驱动 wall 与 budget 的是同一个数。接线于 `ChatHandler` Phase 3.5：压缩 → 重估 → 若 fit 则按压缩后 transcript 继续，否则 wall 仍持 400。11 个精确值测试（`ConversationCompactionTests`，含 CJK 公式 / nil-budget / at-budget 边界 / tool-call 原子性 / boundary / reserve / deterministic 共 11 条）。

- **Pin bump: mlx-swift-lm d661402 → `1441444`** (72bbfbe) — absorbed upstream #544 (MLXFoundationModels β5-SDK compilation fix: `capabilities:` extraneous label :565, `ConvertibleToGeneratedContent` dict :718). ocoreai 0 true consumers of either changed symbol; the module must compile for ocoreai to build. β5 standalone: d661402 FAILS (2 errors) / 1441444 PASSES. Unblocks local build + test run.
- **CoreAI GPU repetition penalty (#176 alignment)** — `RepetitionPenaltyGPUState` (125 LOC, verbatim port from upstream coreai-models) + `MPSGraphCompositeSampler` penalty stage (graph Step-0 `select(logits>0, logits/p, logits*p)` sign-aware divide/multiply, compiled into the feed tensors) + `CoreAIPipelinedEngine` wiring (`recordToken` in the completion callback, `buffer(forStep:)` at encode time, `reset()` clears the ring + buffers). `MPSGraphSamplerFactory.makeSampler` threads `config.repetitionPenalty != nil` → `penaltyEnabled`. Sequential path already covered by `RepetitionPenaltyProcessor` (unchanged).
- **CoreAI grammar → GPU pipelined constrained path (#170 wire)** — `EngineInference` CoreAI grammar branch now dispatches by `ConstrainedGenerationCapable` capability (aligned with upstream coreai-models `CoreAILanguageModel` L582-596) instead of the hard `as? CoreAISequentialEngine` cast. This activates the previously absorbed-but-unwired `PipelinedConstrainedDecodingStrategy` (#146/#170 bitmask per token). Sequential constrained path unchanged.
- **EngineFactory fallback layer removed** — `resolveVariantWithFallback` (dynamic→sequential silent fallback) deleted; auto-detect is now honored directly (dynamic→pipelined, chunkedStatic→staticShape), aligned with upstream `EngineFactory` (which has no fallback). `EngineFactory.{Variant, autoDetectVariant, checkVariantCompatibility, resolveVariant}` bumped `private`→internal for test access (`EngineVariantRoutingTests`).
- **CoreAI grammar constrained decoding** (b69b934) — `TokenizersMLXTokenizerAdapter` (swift-transformers → `MLXLMCommon.Tokenizer`, no MLX tensor deps) unblocks the CoreAI bootstrap guard; `CoreAISequentialEngine.startConstrainedDecoding`/`feedToken` decode-step loop drives xgrammar (`MLXCXGrammar` C shim) mask/acceptToken/rollback. GuidedGeneration 13/13 green. Replaces the 2026-08-13 "fails on CoreAI path" finding.
- **CoreAI .pipelined variant wired** (c4c0a43) — `CoreAIPipelinedEngine` (1,352 LOC) constructed like .sequential/.staticShape (was: `engineUnavailable` throw). Grammar stays on the sequential path (tracks upstream coreai-models #146/#170 GPU bitmask on pipelined); a grammar request hitting the pipelined engine warns and runs unconstrained. _(Superseded 2026-08-22: see "#170 wire" above — grammar now routes to the pipelined GPU bitmask loop when the engine conforms to `ConstrainedGenerationCapable`.)_
- **ThinkingBudget hard budget** (686161c) — upstream `ThinkingBudgetProcessor` wired into the std reasoning path via `GenerationComponents.applyingThinkingBudget` (EngineInference.swift:3345); orthogonal to the ocoreai ThinkingBudget actor.

### Bug Fixes

- **EngineVariantRoutingTests: 3 false-compatible assertions corrected** (72bbfbe) — `checkVariantCompatibility(variant:*, structure: .unknown)` was asserted `.compatible` for all 3 variants; upstream `EngineFactory` and ocoreai mirror both say non-LLM structures are compatible with NONE (default → `false`). Fixed: 3 assertions `== false` with segmenter-comment. Exposed by first-ever local full test run (macos-26 compiles CoreAI tests out via `canImport`; xcode-27 has Testing-macro drift).
- **RepetitionPenaltyGPUState: eviction-order race fixed** (72bbfbe) — `buffer(forStep:)` applied dirty lists in evicted→added order; a token recorded-then-evicted within one flush interval kept its stale penalty and could never be cleared (out of ring → never evicted again). Fixed: flush applies per-token state by CURRENT refcount (`refCount > 0` = in-window). 7 sibling tests confirm no regression. Upstream has the same defect.
- **Multi-tool-call append** (773eeda) — ChatHandler tool-call collection appends instead of overwriting; `ToolCallParser.flush()` can yield multiple tool calls per turn (all-but-last were silently dropped).
- **CoreAI sampler error propagation** (773eeda, MPSGraphSamplers #169 alignment) — completion `(Int32) -> Void` → `(Int32, Error?) -> Void`; 16 failure paths now classify into typed `MPSGraphSamplerError`s instead of silent `completion(0)`; `CoreAIPipelinedEngine` propagates via `continuation.finish(throwing:)`.

### Refactoring / Cleanup

- **Orphaned "Voice Input" a11y labels removed** — `voiceInputLabel` / `voiceInputHint` (`A11y.VoiceInputLabel`/`A11y.VoiceInputHint`, en+zh) referenced nowhere: not in any view, test, or raw a11y-ID string (6 self-contained occurrences in `Localization.swift` only). The label text "coming soon" / "即将推出" is stale — voice input is already wired end-to-end (`MultimodalControls` start/stop → `LocalSTT.transcribe` → `MultimodalState.pendingVoiceTranscript` → `ChatView.sendVoiceMessage` → chat). Removed the case decls + en + zh string values. No behavioral change; kills a misleading dead label on the UI/UX + i18n axis.
- **4c231d3 dead-code + print removal** (4c231d3) — `AgentLoop` enum runner + `AgentLoopConfig` pruned (523→44 LOC; zero callers after the engine iteration loop moved to `DirectInferenceClient`); `AgentLoopResult`/`AgentLoopIterationLog` kept (consumed by ThinkingTelemetry). `StatsReporter` table-display chain removed (~180 LOC — upstream llm-runner-CLI-only, zero refs). `print()` in Sources/ 18→0 (MPSGraphSamplers 6 + InstrumentsProfiler 12; MPSGraphSamplers errors already propagate to `onSamplingDone`, InstrumentsProfiler deinit rewritten as swift-log `Logger(label:)`).

### Tests

- **#176 GPUState + #170 routing tests** — `RepetitionPenaltyGPUStateTests.swift` (6 contract tests: fresh-is-noop, recorded-is-penalized, dedup, window scoping, out-of-range ignored, reset-clears-all) + `MPSGraphCompletionOrderingTests` (16-encode ordering sentinel — guards the completion-ordering assumption `RepetitionPenaltyGPUState` relies on; ported from upstream `CoreAIPipelinedTests.swift`). Both `.enabled(if: MTLCreateSystemDefaultDevice() != nil)` (CPU-only/CI-VM skip). `EngineVariantRoutingTests.swift` (8 tests: dynamic→pipelined, chunkedStatic→staticShape, unknown→sequential, explicit override, incompatible overrides throw, unknown string throws, full compatibility table) — `@available(macOS 27.0)` guard in each test body (no `@available` on macros, skill §6.1).

### Tooling / CI

- **4c231d3 CI test gate** (4c231d3) — `swift build --build-for-testing -scheme ocoreaiTests` (was `ocoreai`, which had NO test action) + a `Run tests (xcrun xctest)` step. Previously the 757 Swift Testing tests silently never compiled/reran in CI. Local gate: `swift build --build-tests` + `xcrun xctest` = 757 tests / 136 suites passed.
- **Pin guard** (773eeda) — Package.swift: DO NOT bump mlx-swift-lm past `d667610`. Upstream `d7dc03d` (#512) adds `TokenStreamEvent.rejectedToolCall`; the FM-trait switches at `MLXLanguageModel.swift:1890/1943` don't handle it → build-fail under `FoundationModelsIntegration && canImport(FoundationModels, _version: 2)`. _Superseded (2026-08-23, 72bbfbe): pin now at `1441444`; upstream #544 resolved the β5-SDK blocker; no active pin guard._
- **pre-commit** — scope swift-format to staged files (5741015), apply to 9 files (ea79b2a), restore hook verbatim from mlx-swift-lm (e8dc47f).
- **QC zero-crash-risk gates** (4624d29) — `.swiftlint.yml` crash rules pinned (`fatal_error_message` = error; `force_unwrapping`/`force_cast`/`force_try`/`implicitly_unwrapped_optional` = warning), CI gates wired. `Sources/` now: 0 `fatalError`, 1 `precondition` (CoreAIPipelinedEngine.swift:285, structural invariant on init), 2 debug-only `assert` (Tools/ToolEntry.swift:74, Engine/KVCache+CoreAI.swift:541). _Superseded (2026-08-17): swiftlint removed to align with upstream (mlx-swift-lm / coreai-models ship no swiftlint); `.swiftformat`-era `make format` also replaced with swift-format. Crash-safe coding remains a code convention, no longer a CI gate._

### Documentation

- **Baseline accuracy pass** (this entry) — AGENTS.md / README.md / README.zh.md corrected: CoreAI grammar + pipelined now wired, pin state, LOC/counts, platform floor (macOS 14 / iOS 17), model name.

---

## 2026-08-13

### Upstream Sync

- **mlx-swift-lm pinned d667610** — mlx-swift→0.31.6, Qwen3.5 JSON tool-call fallback (#529), Qwen3.5 MTP speculative decoding (#351), ThinkingBudget enforcement (#521), KVCache limits (#514), TurboFlash (#520), ChatConventions migration (#502), CacheConfiguration engine (#514)
- **CoreAI SDK** — macOS 27 system framework, not SPM package (imported via `#if canImport(CoreAI)` guards). Derived code from coreai-models BSD-3-Clause (not a dependency — not in Package.swift)
- **mlx-swift pinned da31870** — JIT source auto-derive, fp8 conversion, Muon optimizer, LR schedules

### Features

- **Upstream alignment verified** — Full source-level audit of MLX/CoreAI/upstream alignment. ReasoningEventEmitter ✅ (7 code refs), KVCacheRuntime ✅ (turboQuant/affine via MLXBridge L635). AgentLoop gap: dead code (556 LOC, 0 callers — removed from inference pipeline; module still present). CoreAI grammar: `_runConstrainedDecoding` uses MLX grammar stack (`MLXGuidedGeneration`); fails on CoreAI path (`mlxModelHandle=nil`). Upstream coreai-models has independent grammar stack (`CXGrammar` → `ConstrainedGenerationSession`) not yet consumed. *(Superseded 2026-08-15: see [Unreleased] above — b69b934)*
- **macOS/iOS dual deploy target** — `Package.swift` declares macOS 14 + iOS 17 minimum. iOS build skips HTTP bridge (L500 `#else`), runs SwiftUI-only Fast Path. CoreAI gate: `#if canImport(CoreAI)` + `@available(macOS 27.0, iOS 27.0, *)` dual-gating
- **P0: Compute channel visibility** — Live `ComputeChannel` badge in ChatView streaming indicator + Dashboard health bar, wired from `HardwareRouter` → `EnginePool` → `AppState` (EN/ZH i18n)
- **P1: Thermal-pressure channel-shift toast** — Auto-dismiss toast on thermal/memory pressure events with from→to channel icons; `ChannelShiftToastOverlay` at ChatView bottom; toast i18n for trigger reason + VoiceOver a11y label
- **P1: Settings capability pills** — MLX/CoreAI pills in About section with `#if canImport(CoreAI)` + `#available(macOS 27.0)` dual-gating; CoreAI grays out on pre-27 platforms
- **P1: Thermal callback fan-out** — `EnginePool.setThermalCallback` closure fans out to both `SessionPool` (session eviction) and `AppState` (UI toast broadcast) via `@MainActor`-aware `await` bridge
- **Swift 6.2** — Upgraded `swift-tools-version` 6.1 → 6.2 (align with mlx-swift-lm #519)
- **MLX typed KV cache + TurboQuant** — Full `KVCacheConfiguration` support with `.turboQuant` and `.affine` strategies via `makeKVCacheConfiguration` (MLXBridge)
- **SessionPool prefix reuse** — Message divergence tracking for prefix-level prompt cache reuse; pooled sessions only re-prefill the diverging suffix
- **SessionPool HardwareRouter eviction** — GPU pressure events trigger aggressive cache eviction before OOM
- **SessionPool state restore** — `loadPromptCacheSnapshot` restores LMOutput.State alongside KV cache for correct position anchoring
- **Persistent-perception system** — PerceptionEngine (13 files, 3,045 LOC in `Multimodal/`): full 7-channel scheduler (camera, screen, network, filesystem, internet, system, speaker) with adaptive sampling, RingBuffer + TTL, inference-aware lock-free snapshot, P-S1/P-S2 perception context injection in tool dispatch loops, cross-platform gates (screen macOS-only).
- **CoreAI sequential engine family alignment** — Option A p1: align CoreAI engine types with upstream sequential/variant architecture
- **MTP speculative decoding** — `generate(::mtpDrafter:)` path with streaming reasoning events
- **Upstream pin d667610** — mlx-swift-lm synced 2026-08-14: Qwen3.5 JSON tool-call fallback, Qwen3.5 MTP speculative decoding, ThinkingBudget enforcement, KVCache limits, TurboFlash, CacheConfiguration engine, KVCacheRound staged rounds. ReasoningEventEmitter ✅ (12 refs), KVCacheRuntime ✅ (turboQuant/affine). Gaps at time of entry: ThinkingBudget hard-budget ❌ (✅ wired 08-14, 686161c), CoreAI grammar ❌ (✅ wired 08-15, b69b934 + c4c0a43 pipelined), AgentLoop gap: dead code

### Bug Fixes

- **P0: Release-safe error handling** — All `precondition` calls removed from production hot paths (28 → 0); replaced with guard/throw/clamp in Metrics, RateLimitMiddleware, TokenizerManager, EnginePool, CoreAIEngine, CoreAISequentialEngine, AgentLoop, AuthMiddleware, EngineLifecycleState, TimingHooks. Tool dispatch `fatalError` replaced with graceful error response. Build verified: 0 errors.
- **Concurrency** — Replaced `os_unfair_lock` raw pointer with `NSRecursiveLock`; extracted Mutex shim for macOS 26 CI compile compatibility
- **Session lifecycle** — P0: 3 fixes including TokenHistory growth bounded to `maxContextLength`
- **CoreAI macOS 26 crash** — Removed `Synchronization` dependency, added Mutex shim, fixed `MLXSamplingMode`/`topK`/tuple enum partial match in MLXBridge
- **CoreAI path metrics** — `reasoningTokenCount`/`promptTokPerSec` now tracked via `ThinkTagParser` with `primedInside` detection
- **toolParser flush** — P0-2: residual event handling + dynamic reasoning detection
- **MLXBridge safety** — `try!` → `do-catch` on KVCacheConfiguration init; all force patterns eliminated
- **ModelScope download** — Strips `mscope:` prefix in `EnginePool.loadModel()`
- **Platform channel state** — P0: iOS picker + i18n hardcoded string fixes

### Refactoring

- **Dead code removal** — `sample(from:)` in CoreAIEngine; consolidated MLX KV cache path

### Documentation

- **AGENTS.md** — Updated Known Gaps, upstream audit status, architecture notes
- **README** — Swift 6.2, typed KV cache, SessionPool improvements

---

## [v0.1.0] — 2026-07-05 → 2026-08-09

### Features

- **Typed tool factory** — `Codable` argument decoding, following the `Tool<Args, Output>` pattern
- **Task-aware prompt engineering** — P0 optimization for prompt quality
- **Gap analysis P0/P1/P2 fixes** — xet disable, cancel cleanup, config TTL cache, parameter estimation, adapter block, mtime stall detection
- **HardwareRouter** — Adaptive GPU/ANE/CPU routing with agent loop token budget 2× compensation and broken-chain repair
- **WiredMemory GPU isolation** — Real-time GPU telemetry and memory isolation
- **WiredMemory** — Policy ID stability and cancel-safe ticket lifecycle
- **Vision multimodal** — OCR + VLM dataURL→CIImage inference path
- **Voice-to-voice loop** — 16 kHz STT + i18n TTS voice + camera integration

### Bug Fixes

- **Request pipeline** — Scoping guard chain to tool path only; non-tool requests no longer blocked
- **Compute channel** — Wired computeChannel to session pool + speculative decoding
- **HardwareRouter data flow** — Wired HardwareRouter → inference pipeline (P0 disconnect fix); wired submitAndDispatch to activate admission gate + hardware router
- **Download pipeline resilience** — Retry logic, stall detection, endpoint config, HF progress, cache integrity; ModelScope temp-file-before-handle and 'blob' type acceptance
- **Scheduler** — Fixed state leak in ChatHandler + AnthropicMessagesHandler
- **EnginePool** — Eliminated force unwrap; tightened CI crash-risk gate; removed leftover `source:` param from `mlxModelLoader.load()`
- **Error mapping** — Wired SchedulerError → AppError in handlers
- **Security** — Closed 2 P0 vulnerabilities from code review
- **Build fixes** — Resolved build break, release warning, and release-mode crash
- **Miscellaneous** — Removed dead HF_ENDPOINT check and dead firstError variable in MCP routeParallel
- **SessionPool cross-session leakage** — Pool release cleared `tools`/`toolDispatch` but missed `additionalContext`, causing reasoning context from a prior request to bleed into the next pooled session (SessionPool.swift L252)
- **CoreAI variant compatibility** — Chunked-static ANE model structure fell back to `sequential` engine, violating upstream `checkVariantCompatibility` (sequential + chunkedStatic = incompatible). Now throws a clear error instead of running an incompatible engine (CoreAIEngine.swift L445-450)
- **CoreAI vocabSize hardcoding** — Config fallback default was Qwen3-specific (151,936). Replaced with model-agnostic 32,768 via `defaultVocabSize` constant; actual vocab size probed from logits descriptor at engine init time (CoreAIEngine.swift L554)

### Refactoring

- **Engine load API** — Removed `source` parameter; `defaultHub` property is sufficient; eliminated prefix-based routing

### Documentation

- Synced README with recent changes (HardwareRouter, AdmissionGate, ThinkingBudget, VLM/OCR, Profiling, 6-language i18n)
- Added tuning-knob documentation for admission gate abort margin fraction
- Fixed misleading comment about per-request device switching

### Chores

- Added complete code review infrastructure (governance)
- Ran SwiftLint: errors → 0, hardened config thresholds, fixed style violations
- Resolved deprecations and renamed symbols

---

*Last updated: 2026-08-23. Current HEAD: 72bbfbe.*
