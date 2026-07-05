# Changelog

All notable changes to ocoreai will be documented in this file.

## [v0.1.0] — 2026-07-05

### 🚀 Features

- **Dual-channel inference** — MLX GPU (Metal, default) + CoreAI ANE stub (macOS 27+/M4+)
- **MLXVLM multimodal inference pipeline** — VLM auto-detect, LLM/VLM factory routing, image input via `preprocessor_config.json`
- **Speculative decoding** — MTP and traditional draft model modes end-to-end
- **Multimodal I/O** — Camera capture, screen capture, microphone input, Apple Speech STT/TTS
- **Multimodal visual feedback loop** — ScreenshotService → MultimodalState → Chat full pipeline
- **Wired Memory GPU isolation** — hardware-level GPU memory bounds for inference
- **Engine lifecycle state machine** — 6-state machine with circuit breaker + port conflict detection
- **MCP bridge** — external MCP server tools routed to AgentLoop tool registry
- **Scheduler + OOM guard** — P0→P4 priority dispatch, GPU memory budget, downgrade chain (4-bit → 8-bit → CPU → refuse)
- **Config system** — YAML config with file watcher, hardware auto-detection for memory budget
- **Session memory** — SQLite + FTS5 full-text search, LLM-driven session compression (hot/warm/cold)
- **Agent loop** — multi-turn tool calling (up to 30 rounds, 120s timeout, 4096 token budget)
- **Skill system** — YAML registry, loader, system prompt builder
- **SwiftUI dashboard** — live metrics, model management, settings, chat interface, 6-language i18n
- **Security** — ContentGuard 3-stage filtering, AdaptiveThreshold EMA, GlobalCrashHandler, structured audit logger
- **API compatibility** — OpenAI chat completions + Anthropic messages API endpoints

### 🐛 Bug Fixes

- **P0: AppError → HTTPResponseError** — unified error handling across Hummingbird middleware chain
- **P0: force unwrap cleanup** — 5 force unwraps in App init path replaced with guard-let + failStartup
- **P0: SwiftUI ModelView recursion crash** — ConditionalTypeDescriptor stack overflow fix (52k frames → 0)
- **P0: multimodal pipeline** — DataURLPreview, stale cache fix, STT auto-transcribe on recording stop
- **P0: AgentLoop security** — ContentGuard tool output filtering, maxToolRounds=10 context truncation, Task cancellation check every 128 tokens
- **P0: fire-and-forget release anti-pattern** — ChatCompletionsRouter Task.detached → proper defer release
- **P1: cross-platform Theme crash** — Color(nsColor:) guarded with #if os(macOS)
- **P1: SpecDecoding mode routing** — LoadedModel.createSpeculativeConfig() now reads config.mode
- **P1: HIG compliance** — accessibility annotations, reduced motion, keyboard shortcuts, monitor leak fix
- **P1: HubConfigFetcher ModelScope revision** — main → master (config prefetch silent failure)
- **P2: TTS content filtering** — code block / thinking tag stripping before TTS
- **P2: camera frame compression** — resize 1280px + JPEG 0.6 before VLM input
- **P2: stopSequences / logitBias hardcoded nil** — 4 handler sites now pass through user config
- **P2: InferenceRequest.systemPrompt / .tools hardcoded nil** — Fast Path now passes all params
- **P1: ChatState singleton** — tab-switch message persistence fix
- **P1: EnginePool unloadModel** — now cleans SessionPool on model unload

### 🧪 Testing

- **374 tests, 72 suites, all passing** (was 351/69)
- HTTP E2E smoke tests — request → router → handler pipeline verification
- Middleware chain tests — auth, rate limiting, error propagation
- Added TokenBucket, OOMGuard, SamplingConfig, EngineConfig, AdaptiveThreshold suites

### 📝 Documentation

- **@unchecked Sendable** — 10/10 sites now have concurrency justification comments
- **README** — accuracy fix: removed `--traits mlx` (MLX now default), updated API endpoint table (17 endpoints), added localhost-only disclaimer (en + zh)
- **CHANGELOG** — first release changelog

### 🔧 Breaking Changes

- MLX is now always-on — `--traits mlx` flag no longer needed (was already default)
- `AppError` renamed to `HTTPResponseError` for Hummingbird H1 middleware compatibility

### 📊 Build Info

- Swift 6.3 · iOS SwiftUI · Hummingbird 2.25
- 122 Swift source files, ~32,000 LOC
- macOS 15+ · Apple Silicon only
- Tests: 374/374 passed in 72 suites (1.1s)
- Build: 0 warnings, 0 errors (20.75s)

---

## [Unreleased]

### Known Issues

- **P2: ThinkingBudget indirect integration** — works in ChatHandler Phase 1 via MessageBuilder, but not in AgentLoop internal iterations
- **P2: Skill body = description only** — builtin skills use description as body, no actionable instructions
- **P2: Config hot-reload not propagated to EnginePool** — config reload updates internal state but EnginePool uses init-time snapshot
- **P2: dead notifications** — `cameraFrameAvailable` / `screenFrameAvailable` posted but no consumer (low-priority cleanup)

### App Store Release Checklist (Separate Track)

- [ ] Xcode project file + schemes
- [ ] PrivacyInfo.xcprivacy
- [ ] App icon + launch screen
- [ ] Code signing + entitlements
- [ ] Info.plist permission descriptions (camera/microphone/screen capture)
- [ ] `.lproj` resource bundles for 6 languages
- [ ] `--traits appStore` build verification
