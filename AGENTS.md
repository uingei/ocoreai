# ocoreai — Project Context for AI Agents

> This file is loaded by Hermes on every session. It anchors the agent to the project's conventions, architecture, and known issues — zero cold-start tax.

---

## Identity

**What it is:** macOS/iOS AI agent platform — dual-channel on-device inference (MLX Metal GPU + CoreAI derived from coreai-models reference), agent loop with tool dispatch, skill system, session memory, multimodal I/O, ReasoningEventEmitter pipeline, persistent-perception pipeline (planned). One binary, 160 Swift files (~52K LOC).

**Tech stack:** Swift 6.2 · SwiftPM · Hummingbird 2.25 · SwiftUI · SQLite + FTS5

**Key modules:** 22 subdirectories under `Sources/ocoreai/`: Engine, Agents, Client, Scheduler, MCP, Tools, UI, SQLite, Config, Multimodal, Reasoning, Profiling, Tokenizer, Security, Skills, etc.

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
- `EnginePool` uses inline `#if canImport(CoreAI)` branches, NOT `BackendProtocol` (protocol defined but unused)
- **MLX path reality:** `_runInferenceWithMessages()` → `ChatSession` (session pool, guided gen, toolDispatch) — ReasoningEventEmitter ✅ (7 code refs, 7 files), KVCacheRuntime ✅ (turboQuant/affine via MLXBridge L635). Pinned upstream `mlx-swift-lm` at `d667610` (2026-08-14, mlx-swift→0.31.6). Gaps: upstream ThinkingBudget hard-budget enforcement ❌ (orthogonal to ocoreai ThinkingBudget actor; std reasoning path wired L3314).
- **CoreAI** — derived from Apple's coreai-models reference (BSD-3-Clause), simplified for ocoreai: types redefined locally to avoid macOS 27 platform requirement, ~4,800 LOC across 13 files (Engine/CoreAI*.swift + StateHandler*.swift + KVCache+CoreAI + TensorStorage+CoreAI).
- **ANE path:** Stub/empty via CoreAI — no specialization yet
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
swift test                               # all @Test cases
swift test --enable-code-coverage        # with coverage
swift test --filter OcoreAITests.System  # system tests only
```

**Linting:** SwiftLint via `.swiftlint.yml`. Bug-catching rules only — not style enforcement. `force_unwrapping: warning`, `implicitly_unwrapped_optional: warning`. Run via `swiftlint lint`.

**Build verification is MANDATORY** before claiming completion. `swift build` exit code 0 = done.

---

## Code Conventions

### Concurrency
- Swift 6.2 strict concurrency mode. `Sendable` enforcement active.
- `EnginePool` is an `actor` with `@unchecked Sendable` mutable state (perform-based isolation). 39 total `@unchecked Sendable` declarations, all with justification comments.
- UI layer runs on `@MainActor`. Engine layer is actor-isolated. Cross-actor calls via `await`.
- `@unchecked Sendable` requires justification comment. Closure `var` declared inside closure scope (not outer).

### Error Handling
- Precondition near-free — 1 `precondition` call (CoreAIPipelinedEngine.swift:285, structural invariant on init); all others replaced with guard/throw/clamp after P0 cleanup.
- **Zero `try!`, `as!`, `print()`** in production code.
- **Remaining:** 2 `fatalError` (defense-only stub + unreachable SDK regression path), 1 `assert` (release-optimized away in Tools/ToolEntry).
- `try?` usages concentrated in MCP/Models hotspot (~54 instances, defensive fallback pattern).
- `ErrorContext.swift` does not exist — `Profiling/` only contains `TimingHooks.swift`.
- 2 empty `catch {}` blocks on async operations (EngineInference, watchdog cancellation).

### Naming
- Target names ≠ module boundaries (e.g., `GuidedGenerationLoop` is peer to `ChatSession`, not nested).
- 1 known TODO: `FMToolBridge.swift:183` (VMultimodalSession/PromptBuilder image path). No FIXME/HACK/XXX.

### Testing Quality
- Gold standard: `ThinkingBudget`, `ComplexityAnalyzer` — exact value assertions (`#expect == N`), parameterized traversal, boundary assertions. (BlockPool gold-standard test removed with the module at upstream 2b3c965.)
- **Reject** `count > N` weak assertions.
- Test modules: Scheduler lifecycle + concurrency, OOMGuard (full), MemoryTracker (partial gaps), AdmissionGate (partial gaps), HardwareRouter (Mirror 161 LOC + Integration 207 LOC — see table below).

---

### Upstream Alignment Gaps

| Issue | File | Status |
|-------|------|--------|
| **ThinkingBudget hard-budget** | Engine/EngineInference.swift | ✅ Wired std reasoning path (686161c L3314 applyingThinkingBudget); Guided/MTP paths non-reasoning = no budget needed; guided/MTP `components: .init()` (L2697/L2881) intentional |
| **SyncInputHandler** | — | ✅ Upstream d667610 已无 `InputHandler`/`InputCoverage` 符号，gap 消失 |
| **ChatConventionsRegistry** | — | ✅ Upstream d667610 已无 `ChatConventionsRegistry`，reasoningConfig 内化至管线 |
| **AgentLoop dead code** | Agents/AgentLoop.swift | ❌ P1 — 556 LOC, zero callers in Handlers/UI. MLX path uses ChatSession directly (L534-537). Either activate for non-MLX paths or prune. |
| **MLX upstream sync gap** | Package.swift | ✅ Resolved — pinned at d667610 (aligned with upstream HEAD) |
| **KVCache typed config** | Engine/MLXBridge.swift | ✅ Wired via makeKVCacheConfiguration (L635) TurboQuant+Affine through generateParameters.kvCache; upstream CacheConfiguration (364 LOC) merged into GenerateParameters at d667610 |
| **MTP spec decode** | Engine/EngineInference.swift | ✅ Aligned — blockSize from specDecodingConfig.numDraftTokens (L2880) + upstream auto-clamp; MTPDrafterModelWrapper is type wrapper not gap |
| **TurboFlash** | EngineInference.swift | ✅ Consumed internally by upstream `generate*()` — TurboFlash is an attention kernel mechanism; ocoreai doesn't call it directly |
| **CoreAI grammar constrained decoding** | Engine/EngineInference.swift | ❌ P1 — `_runConstrainedDecoding` uses MLX grammar stack (`MLXGuidedGeneration`); fails on CoreAI (`mlxModelHandle=nil`). Upstream coreai-models has its own grammar stack (`CXGrammar` → `ConstrainedGenerationSession` → `ConstrainedDecodingStrategy`, swift-transformers `Tokenizer`); not consumed in ocoreai |
| **iOS UI parity** | UI/ | ⚠️ iOS build confirmed Fast-Path-only; full parity audit pending (MCP/Security on iOS TBD) |
| **PerceptionEngine** | Multimodal/PerceptionEngine.swift | ✅ Implemented (13 files, 3049 LOC in `Multimodal/`) — full 7-channel perception scheduler with RingBuffer, adaptive sampling, inference-aware snapshot. Cross-platform gates (screen macOS-only, filesystem all). |

### Legacy Issues (Previously Fixed)

| Issue | File | Status |
|-------|------|--------|
| MLX path cross-session leakage | SessionPool.swift | ✅ Fixed — full cleanup on pool release |
| CoreAI variant chunkedStatic+sequential incompatibility | CoreAIEngine.swift | ✅ Fixed — guard throws |
| CoreAI vocabSize Qwen3-specific default | CoreAIEngine.swift | ✅ Fixed — model-agnostic 32,768 |
| CoreAI staticShape/pipelined engine | CoreAIEngine.swift | ✅ StaticShape (611 LOC) wired; Pipelined (1314 LOC) engine exists but auto-detect `.dynamic` throws "pipelined not yet available" — fallback to sequential for dynamic models |
| PagedKVCache removed | — | ✅ Resolved (P0 cleanup) |
| MLX KVCacheRound/TurboFlash/TurboQuant | EngineInference.swift | ✅ Consumed upstream — no gap |
| MTP toolCall dispatch | EngineInference.swift | ✅ Aligned with upstream `MTPSpeculativeTokenIterator` |
| ReasoningEventEmitter | Engine/EngineInference.swift | ✅ Wired (both MLX + CoreAI paths, 7 code refs) |
| Reasoning `<thinking>` regex | Engine/ | ⚠️ Limited — regex-based, no AST |
| MLXFoundationModels deeper integration | Engine/ | FM path wired; lacks per-token callback on FM `.done` |
| `kvCacheRuntimeReport` diagnostic | — | ❌ Upstream d667610 已无此符号（曾存在后被移除） |
| try? scatter | ~54 instances MCP/Models hotspot | Ongoing risk |
| precondition | 1 in production (CoreAIPipelinedEngine.swift:285, structural invariant) | ⚠️ Known |
| fatalError | 2 (defense-only stub + unreachable SDK path) | Acceptable |
| Empty catch {} | EngineInference | 2 instances remain |
| Coverage report | Tests/CoverageReport | Missing — no live data |
| HardwareRouter tests | Tests/ | ✅ Mirror (161 LOC) + Integration (207 LOC) = 368 LOC |
| AdmissionGate tests | Tests/ | ✅ 356 LOC — reservation, jitter, emergency suites |

---

### Upstream Audit Dependencies

Three sources for empirical verification:
1. **mlx-swift-lm** — pinned at `d667610` (2026-08-14: Qwen3.5 MTP speculative decoding #351, ThinkingBudget enforcement #521, KVCache limits #514, TurboFlash #520, ChatConventions migration #502, mlx-swift→0.31.6)
2. **coreai-models** — pinned at `d13b882` (iOS export use contract #168). Reference repo, not SPM dependency.
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

This environment runs on **Ollama** (provider: `ollama-launch`, model: `qwen3.6:27b-mtp`). Ollama does **not** support concurrent model invocations — `delegate_task` and nested `skill_view` calls fail or produce unreliable results.

**Single-pass protocol:** Use the `single-pass-orchestration` skill as the default coding methodology. All 7 phases (grilling → plan → TDD/evals → implement → review → auto-fix → commit) run **sequentially within one response**. Do NOT invoke skills as separate tool calls mid-implementation. Apply their rules in-context.

**Skills to load upfront (read once, apply manually):**
- `single-pass-orchestration` — pipeline entry point
- `engineering-grilling` — Phase 1 intent alignment
- `code-review-discipline` — Phase 5a standards scan
- `code-audit-methodology` — 3-layer verification (grep → compile → read)

**Pre-loaded domain skills (already in context):**
- `hermes-agent` — CLI commands, toolsets, profiles
- `ocoreai-dev` — ocoreai build/test/debug
