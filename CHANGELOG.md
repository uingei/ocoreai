# Changelog

All notable changes to **ocoreai**. This project adheres to [Keep a Changelog](https://keepachangelog.com/) conventions.

## [Unreleased] — 2026-08-12

### Features

- **P0: Compute channel visibility** — Live `ComputeChannel` badge in ChatView streaming indicator + Dashboard health bar, wired from `HardwareRouter` → `EnginePool` → `AppState` (EN/ZH i18n)
- **P1: Thermal-pressure channel-shift toast** — Auto-dismiss toast on thermal/memory pressure events with from→to channel icons; `ChannelShiftToastOverlay` at ChatView bottom; toast i18n for trigger reason + VoiceOver a11y label
- **P1: Settings capability pills** — MLX/CoreAI pills in About section with `#if canImport(CoreAI)` + `#available(macOS 27.0)` dual-gating; CoreAI grays out on pre-27 platforms
- **P1: Thermal callback fan-out** — `EnginePool.setThermalCallback` closure fans out to both `SessionPool` (session eviction) and `AppState` (UI toast broadcast) via `@MainActor`-aware `await` bridge
- **Swift 6.2** — Upgraded `swift-tools-version` 6.1 → 6.2 (align with mlx-swift-lm #519)
- **MLX typed KV cache + TurboQuant** — Full `KVCacheConfiguration` support with `.turboQuant` and `.affine` strategies via `makeKVCacheConfiguration` (MLXBridge)
- **SessionPool prefix reuse** — Message divergence tracking for prefix-level prompt cache reuse; pooled sessions only re-prefill the diverging suffix
- **SessionPool HardwareRouter eviction** — GPU pressure events trigger aggressive cache eviction before OOM
- **SessionPool state restore** — `loadPromptCacheSnapshot` restores LMOutput.State alongside KV cache for correct position anchoring
- **8-channel persistent-perception system** — Full persistent-perception pipeline (camera, sensors, environment) with P-S1/P-S2 perception context injection in tool dispatch loops
- **CoreAI sequential engine family alignment** — Option A p1: align CoreAI engine types with upstream sequential/variant architecture
- **MTP speculative decoding** — `generate(::mtpDrafter:)` path with streaming reasoning events
- **Upstream pin 2af378b** — mlx-swift-lm upgraded to #516 (KVCacheRound staged rounds, MTP past sliding window, Qwen3MoE sanitization)

### Bug Fixes

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

*Last updated: 2026-08-12. Current HEAD: c693be0.*
