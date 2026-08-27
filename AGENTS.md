# ocoreai — Project Context for AI Agents

> This file is loaded by Hermes on every session. It anchors the agent to the project's conventions, architecture, and known issues — zero cold-start tax.

---

## Identity

**What it is:** macOS/iOS agent execution layer (reliable Execute → Verify → Recover; first product = Coding/Computer Agent) — dual-channel on-device inference (MLX Metal GPU + CoreAI derived from coreai-models reference), agent loop with tool dispatch, skill system, session memory, multimodal I/O, ReasoningEventEmitter pipeline, persistent-perception pipeline. One binary, 194 Swift files (62,467 LOC).

**Tech stack:** Swift 6.2 · SwiftPM · Hummingbird 2.25 · SwiftUI · SQLite + FTS5

**Key modules:** 24 subdirectories under `Sources/ocoreai/`: Engine, Agents, Client, Scheduler, MCP, Tools, UI, SQLite, Config, Multimodal, Reasoning, Profiling, Tokenizer, Security, Skills, Video, etc.

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
- **MLX path reality:** `_runInferenceWithMessages()` → `ChatSession` (session pool, guided gen, toolDispatch) — ReasoningEventEmitter ✅ (22 refs, 7 files), KVCacheRuntime ✅ (turboQuant/affine via MLXBridge L635). Pinned upstream `mlx-swift-lm` at `6745899` (2026-08-26: 5 free-rider commits `626516b..6745899` 全 consumer-transparent；前序 1441444 #544 修复已合并；本地 build+test 解锁）。 Gaps: upstream ThinkingBudget hard-budget enforcement ❌ (orthogonal to ocoreai ThinkingBudget actor; std reasoning path wired L3314).
- **CoreAI** — derived from Apple's coreai-models reference (BSD-3-Clause), simplified for ocoreai: types redefined locally to avoid macOS 27 platform requirement, 6,965 LOC across 15 files (Engine/ 14: CoreAI* ×8 + StateHandler ×3 + MPSGraphSamplers + KVCache+CoreAI + TensorStorage+CoreAI; + Tokenizer/TokenizersMLXTokenizerAdapter).
- **ANE path:** CoreAI `MPSGraphSamplers` (1,421 LOC) wires MPS constrained argmax/composite/sampler — GPU-based constrained decoding path (c4c0a43 + 031cb54)
- **MTP path:** `_runInferenceWithMessages` → `generate(::mtpDrafter:)` — bypasses ChatSession, tool calls collected + dispatched per-iteration (aligned with upstream `MTPSpeculativeTokenIterator`)
- **SessionPool:** Prefix-level prompt cache reuse via message divergence tracking; HardwareRouter pressure events trigger aggressive eviction; `loadPromptCacheSnapshot` restores LM state + KV cache

**Key:** `#if canImport(CoreAI)` single-layer compile-time gate; `sampleToken()` → argmax; toolDispatch wired in both MLX and CoreAI paths.

**Upstream alignment (verified 2026-08-13):**
- `KVCacheRound` / `TurboFlash` / `TurboQuant`: consumed internally by upstream `generate*()` — no downstream intervention needed
- `KVCacheConfiguration`: full `.turboQuant` + `.affine` dual-path via `makeKVCacheConfiguration` (MLXBridge)
- `toolDispatch`: ocoreai closure → `ToolRegistry.call()` wired through ChatSession restart loop
- `MTP toolCall dispatch`: collected per `Generation.toolCall`, dispatched after each iteration, results appended to message history

---

## Build / Test / Lint

```bash
swift build -c release                    # production build
swift build --traits mlx                 # debug build with mlx
swift test                               # ⚠️ not the gate (metallib limitation) — real gate: xcodebuild → xcrun xctest (batch delivery 时 CI 实跑 1,109 tests / 200 suites + 本批 13 = 当前 macos-26 GREEN，逐批累积)
swift test --enable-code-coverage        # with coverage
swift test --filter OcoreAITests.System  # system tests only
```

**Linting:** none — aligned with upstream (mlx-swift-lm / coreai-models ship no swiftlint). swift-format via `.swift-format` (pinned 603.0.0) is the only style gate, enforced in CI and pre-commit. Crash-safe coding (no `try!`/`as!`/`fatalError` in Sources/) is a code convention, not a CI gate.

**Build verification is MANDATORY** before claiming completion. `swift build` exit code 0 = done.

---

## Code Conventions

### Concurrency
- Swift 6.2 strict concurrency mode. `Sendable` enforcement active.
- `EnginePool` is an `actor` with `@unchecked Sendable` mutable state (perform-based isolation). 55 total `@unchecked Sendable` declarations (2026-08-27 复核), all with justification comments.
- UI layer runs on `@MainActor`. Engine layer is actor-isolated. Cross-actor calls via `await`.
- `@unchecked Sendable` requires justification comment. Closure `var` declared inside closure scope (not outer).

### Error Handling
- Precondition near-free — 7 `precondition` calls (2026-08-27 复核): CoreAIPipelinedEngine:298, CoreAIStubs:95, CoreAIStubs:132, PipelinedConstrainedDecodingStrategy:125, Video/DiscreteFlowScheduler:46, Video/DiscreteFlowScheduler:108, Video/TiledDecode3D:26 (后 3 处= Wan 2.1 数值面吸收 `00e199a` 上游逐字)；all others replaced with guard/throw/clamp after P0 cleanup。
- **Zero `try!`** in production code.
- **`print()`:** 0 in production code (18→0 at commit 4c231d3 — 6 MPSGraphSamplers + 12 InstrumentsProfiler removed; MPSGraphSamplers errors already propagate to `onSamplingDone`, InstrumentsProfiler deinit diagnostic rewritten as swift-log `Logger(label:)`).
- **`fatalError`:** 0.
- `assert`: 1 (Engine/KVCache+CoreAI.swift:542 structural invariant, 2026-08-27 复核;前序 ToolEntry.swift:74 已随 ToolEntry 签名重构移除)。
- `try?` usages: 269 total across all modules (2026-08-27 复核; 前序 202 随本批 Wan+context 累积上升) — top: Tools 54, Models 44, Multimodal 39, Engine 28, UI 25, MCP 25, SQLite 12 (defensive fallback pattern)。
- `ErrorContext.swift` does not exist — `Profiling/` only contains `TimingHooks.swift`.
- 2 empty `catch {}` blocks (EngineInference.swift:270, :315 — Task.sleep watchdog deadline tolerance; 2026-08-27 复核，行号随本批 Wan+context 批次漂移，前序 :153/:198)。

### Naming
- Target names ≠ module boundaries (e.g., `GuidedGenerationLoop` is peer to `ChatSession`, not nested).
- 1 known TODO: `FMToolBridge.swift:172` (VMultimodalSession/PromptBuilder image path). No FIXME/HACK/XXX.

### Testing Quality
- Gold standard: `ThinkingBudget`, `ComplexityAnalyzer` — exact value assertions (`#expect == N`), parameterized traversal, boundary assertions. (BlockPool gold-standard test removed with the module at upstream 2b3c965.)
- **Reject** `count > N` weak assertions.
- Test modules: Scheduler lifecycle + concurrency, OOMGuard (full), MemoryTracker (partial gaps), AdmissionGate (partial gaps), HardwareRouter (Mirror 161 LOC + Integration 230 LOC — see table below).

---

### Upstream Alignment Gaps

| Issue | File | Status |
|-------|------|--------|
| **ThinkingBudget hard-budget** | Engine/EngineInference.swift | ✅ Wired std reasoning path (686161c L3314 applyingThinkingBudget); Guided/MTP paths non-reasoning = no budget needed; guided/MTP `components: .init()` (L2697/L2881) intentional |
| **SyncInputHandler** | — | ✅ Upstream d667610 已无 `InputHandler`/`InputCoverage` 符号，gap 消失 |
| **ChatConventionsRegistry** | — | ✅ Upstream d667610 已无 `ChatConventionsRegistry`，reasoningConfig 内化至管线 |
| **AgentLoop runner** | Agents/AgentLoop.swift | ✅ Pruned at 4c231d3 (523→44 LOC) — enum runner + `AgentLoopConfig` removed (zero callers); `AgentLoopResult`/`AgentLoopIterationLog` kept (ThinkingTelemetry). Agent loop now owned by `DirectInferenceClient` (858 LOC) + `ChatHandler`. |
| **MLX upstream sync gap** | Package.swift | ✅ Resolved (2026-08-26): pinned at `6745899` — 5 free-rider commits `626516b..6745899` 全 consumer-transparent / 前序 1441444 #544 + d661402/d7dc03d 上游 blocker closed。 |
| **KVCache typed config** | Engine/MLXBridge.swift | ✅ Wired via makeKVCacheConfiguration (L635) TurboQuant+Affine through generateParameters.kvCache; upstream CacheConfiguration (364 LOC) merged into GenerateParameters at d667610 |
| **MTP spec decode** | Engine/EngineInference.swift | ✅ Aligned — blockSize from specDecodingConfig.numDraftTokens (L2880) + upstream auto-clamp; MTPDrafterModelWrapper is type wrapper not gap |
| **TurboFlash** | EngineInference.swift | ✅ Consumed internally by upstream `generate*()` — TurboFlash is an attention kernel mechanism; ocoreai doesn't call it directly |
| **CoreAI grammar constrained decoding** | Engine/ | ✅ Wired (b69b934 + c4c0a43) — `MPSGraphSamplers` (1,421 LOC, 2026-08-27 复核) provides MPS constrained argmax/composite via CoreAI `sampleToken` path; `TokenizersMLXTokenizerAdapter` (108 LOC) bridges upstream Tokenizer. `ConstrainedGeneration` conformers in Engine/. 13 @Test green (2026-08-26 复核). `
| **iOS UI parity** | UI/ | ⚠️ iOS build confirmed Fast-Path-only; full parity audit pending (MCP/Security on iOS TBD) |
| **PerceptionEngine** | Multimodal/PerceptionEngine.swift | ✅ `PerceptionChannel` **7 cases** (`PerceptionContext.swift:14-30`: camera / screen / audio / network / environment / system / speaker; 2026-08-27 复核) — full perception scheduler with RingBuffer, adaptive sampling, inference-aware snapshot. `Multimodal/` **16 files, 3,600 LOC** (前序 13 files / 3,045 LOC，本批 audio+STT+TTS+screenshot 增 3 件; 2026-08-27 复算). Cross-platform gates (screen macOS-only, filesystem all). |

### Legacy Issues (Previously Fixed)

| Issue | File | Status |
|-------|------|--------|
| MLX path cross-session leakage | SessionPool.swift | ✅ Fixed — full cleanup on pool release |
| CoreAI variant chunkedStatic+sequential incompatibility | CoreAIEngine.swift | ✅ Fixed — guard throws |
| CoreAI vocabSize Qwen3-specific default | CoreAIEngine.swift | ✅ Fixed — model-agnostic 32,768 |
| CoreAI staticShape/pipelined engine | CoreAIEngine.swift | ✅ All 3 variants wired: StaticShape 634 LOC, Pipelined 1,352 LOC, Sequential 623 LOC (c4c0a43) — `.pipelined` selectable in EngineFactory |
| PagedKVCache removed | — | ✅ Resolved (P0 cleanup) |
| MLX KVCacheRound/TurboFlash/TurboQuant | EngineInference.swift | ✅ Consumed upstream — no gap |
| MTP toolCall dispatch | EngineInference.swift | ✅ Aligned with upstream `MTPSpeculativeTokenIterator` |
| ReasoningEventEmitter | Engine/EngineInference.swift | ✅ Wired (both MLX + CoreAI paths, 22 refs across 7 files) |
| Reasoning `<thinking>` regex | Engine/ | ⚠️ Limited — regex-based, no AST |
| MLXFoundationModels deeper integration | Engine/ | FM path wired; lacks per-token callback on FM `.done` |
| `kvCacheRuntimeReport` diagnostic | — | ⚠️ Not consumed by ocoreai — upstream `KVCacheRuntime.swift:147` + `ChatSession.swift:1449` + `KVCachePlan.swift:89/94` still present at d667610 and d7dc03d |
| try? scatter | 202 instances across all modules | Ongoing risk |
| precondition | 7 in production (CoreAIPipelinedEngine:298, CoreAIStubs:95, CoreAIStubs:132, PipelinedConstrainedDecodingStrategy:125, Video/DiscreteFlowScheduler:46, Video/DiscreteFlowScheduler:108, Video/TiledDecode3D:26) | ⚠️ Known (Wan 2.1 数值面 `00e199a` 吸收 3 处上游逐字) |
| fatalError | 0 in production code | ✅ Clear |
| Empty catch {} | EngineInference | 2 instances remain |
| Coverage report | Tests/CoverageReport | Missing — no live data |
| HardwareRouter tests | Tests/ | ✅ Mirror (161 LOC) + Integration (230 LOC) = 391 LOC |
| AdmissionGate tests | Tests/ | ✅ 356 LOC — reservation, jitter, emergency suites |

---

### Upstream Audit Dependencies

Three sources for empirical verification:
1. **mlx-swift-lm** — pinned at `6745899` (2026-08-26: 5 free-rider commits `626516b..6745899` 全 consumer-transparent；前序 1441444 #544 β5-SDK 编译修复，2026-08-23)
2. **coreai-models** — reference at `f43b6da` (2026-08-25: Flux2 RoPE in-graph #192 + Wan export #195 + graph-quant externalization #194；前序 86b363d #187 OpenAI LLM server, 2026-08-21)。Reference repo, not SPM dependency。
3. **Apple Developer Docs** — developer.apple.com/documentation/CoreAI (requires login)

**Wiki audit report:** `~/wiki/ocoreai_upstream_sync_analysis.md` — full consumption matrix with file:line evidence.

---

## Wiki / Knowledge Base

- **Location:** `~/wiki` (Obsidian vault)
- **Known issue:** Time-aging distortion — wiki pins HEAD but repo advances. Concept pages say "implemented" ≠ actually in Engine.
- **Verification:** `git merge-base --is-ancestor $wiki_head $real_head` + grep for file existence + symbol grep
- **Audit reports** in `.hermes/audits/` are legitimate historical snapshots

---

## Workflow

- Branch naming: `feat/`, `fix/`, `docs/`, `chore/`
- PR evidence mandatory: build logs + test output + inference logs
- One logical change per PR, open issue first for anything non-trivial
- Never push feature work directly to `main`

---

## Agent Execution Rules

1. **Three-layer verification mandatory:** grep → compile verify → read matched lines. Single-layer check = speculation, not fact.
2. **Code changes require `swift build` verification.** exit code 0 = done.
3. **Never introduce `try!`, `as!`, `fatalError`, `assert`, `precondition`, or `print()` into production code.**
4. **Cross-actor calls must use `await` or `SerialAccess` pattern.**
5. **Audit conclusions must cite file:line + commit hash.** "Based on code evidence" vs "inference" must be explicit.
6. **Upstream API verification:** Before citing an API as available/missing, check all 3 upstream sources.
7. **All findings verified via tool output** — no speculation, no estimation.

## Ollama Single-Pass Constraint

This environment runs on **Ollama** (provider: `ollama-launch`, model: `qwen3.8:27b-mtp`). Ollama does **not** support concurrent model invocations — `delegate_task` and nested `skill_view` calls fail or produce unreliable results.

**Single-pass protocol:** Use the `single-pass-orchestration` skill as the default coding methodology. All 7 phases (grilling → plan → TDD/evals → implement → review → auto-fix → commit) run **sequentially within one response**. Do NOT invoke skills as separate tool calls mid-implementation. Apply their rules in-context.

**Skills to load upfront (read once, apply manually):**
- `single-pass-orchestration` — pipeline entry point
- `engineering-grilling` — Phase 1 intent alignment
- `code-review-discipline` — Phase 5a standards scan
- `code-audit-methodology` — 3-layer verification (grep → compile → read)

**Pre-loaded domain skills (already in context):**
- `hermes-agent` — CLI commands, toolsets, profiles
- `ocoreai-dev` — ocoreai build/test/debug
