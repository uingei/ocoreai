# ocoreai — Project Context for AI Agents

> This file is loaded by Hermes on every session. It anchors the agent to the project's conventions, architecture, and known issues — zero cold-start tax.

---

## AI Contribution Policy

This project is developed with heavy AI assistance. The rules:

1. **Every line in git is reviewable** — AI-generated or not, the owner approves each commit. "It came from the model" is never an exception to a rule in this file.
2. **No claim without a check** — "verified", "fixed", "aligned" in a commit message or doc must be immediately backed by command output (build/test/grep) in the same session.
3. **When in doubt, point outward** — if an upstream repo (mlx-swift-lm / coreai-models / codex) already has an answer, consume/reference it instead of authoring a local variant; cite the upstream file:line.

---

## Identity

**What it is:** macOS/iOS agent execution layer (reliable Execute → Verify → Recover; first product = Coding/Computer Agent) — dual-channel on-device inference (MLX Metal GPU + CoreAI derived from coreai-models reference), agent loop with tool dispatch, skill system, session memory, multimodal I/O, ReasoningEventEmitter pipeline, persistent-perception pipeline. One binary.

**Tech stack:** Swift 6.2 · SwiftPM · Hummingbird 2.25 · SwiftUI · SQLite + FTS5

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
- **MLX path reality:** `_runInferenceWithMessages()` → `ChatSession` (session pool, guided gen, toolDispatch) — ReasoningEventEmitter ✅ (wired, both MLX + CoreAI paths), KVCacheRuntime ✅ (turboQuant/affine via MLXBridge L635). Pinned upstream `mlx-swift-lm` at `37688d2` (2026-08-28: #572 Qwen GDN fused decode + #573 Qwen direct-reduction decode + public `SwitchLayer.callAsFunction`; 前序 6745899 (2026-08-26) 5 free-rider 全 consumer-transparent；本地 build+test 解锁）。 Gaps: upstream ThinkingBudget hard-budget enforcement ❌ (orthogonal to ocoreai ThinkingBudget actor; std reasoning path wired L3314).
- **CoreAI** — derived from Apple's coreai-models reference (BSD-3-Clause), simplified for ocoreai: types redefined locally to avoid macOS 27 platform requirement. Engine/ 14 files: CoreAI* ×8 + StateHandler ×3 + MPSGraphSamplers + KVCache+CoreAI + TensorStorage+CoreAI; + Tokenizer/TokenizersMLXTokenizerAdapter.
- **ANE path:** CoreAI `MPSGraphSamplers` wires MPS constrained argmax/composite/sampler — GPU-based constrained decoding path (c4c0a43 + 031cb54)
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
swift build --traits appStore            # App Store build (traits: appStore | FoundationModelsIntegration)
swift test                               # ⚠️ not the gate (metallib limitation) — real gate: xcodebuild → xcrun xctest (CI 权威门 = macos-26); use `make test-ci`
swift test --enable-code-coverage        # with coverage
swift test --filter SystemContextSensor  # one suite (substring match)
```

**Linting:** none — aligned with upstream (mlx-swift-lm / coreai-models ship no swiftlint). swift-format via `.swift-format` (pinned 603.0.0) is the only style gate, enforced in CI and pre-commit. Crash-safe coding (no `try!`/`as!`/`fatalError` in Sources/) is a code convention, not a CI gate.

**Build verification is MANDATORY** before claiming completion. `swift build` exit code 0 = done.

---

## Code Conventions

### Concurrency
- Swift 6.2 strict concurrency mode. `Sendable` enforcement active.
- `EnginePool` is an `actor` with `@unchecked Sendable` mutable state (perform-based isolation). Every `@unchecked Sendable` declaration carries a justification comment.
- UI layer runs on `@MainActor`. Engine layer is actor-isolated. Cross-actor calls via `await`.
- `@unchecked Sendable` requires justification comment. Closure `var` declared inside closure scope (not outer).

### Error Handling
- Precondition near-free: production code uses precondition/preconditionFailure only for structural invariants and upstream-verbatim numeric/speech surfaces (Wan 2.1, Speech Tier-A, xgrammar seam); new code must not add them — the exact placement set is code-inspection territory, not a documented count.
- **Zero `try!`** in production code.
- **`print()`:** 0 in production code (18→0 at commit 4c231d3 — 6 MPSGraphSamplers + 12 InstrumentsProfiler removed; MPSGraphSamplers errors already propagate to `onSamplingDone`, InstrumentsProfiler deinit diagnostic rewritten as swift-log `Logger(label:)`).
- **`fatalError`:** 0.
- `assert`: one structural-invariant use (Engine/KVCache+CoreAI).
- `try?`: used as the defensive-fallback pattern (heaviest in Tools, Models, Multimodal, MCP, Engine); `try?` stays acceptable where a real fallback follows — the count is measured by code inspection, not tracked here.
- `ErrorContext.swift` does not exist — `Profiling/` only contains `TimingHooks.swift`.
- A small number of empty `catch {}` blocks remain in EngineInference (Task.sleep watchdog deadline tolerance); they are intentional fallbacks, not swallowed failure paths.

### Naming
- Target names ≠ module boundaries (e.g., `GuidedGenerationLoop` is peer to `ChatSession`, not nested).
- 1 known TODO: `FMToolBridge.swift:172` (VMultimodalSession/PromptBuilder image path). No FIXME/HACK/XXX.

### Testing Quality
- Gold standard: `ThinkingBudget`, `ComplexityAnalyzer` — exact value assertions (`#expect == N`), parameterized traversal, boundary assertions. (BlockPool gold-standard test removed with the module at upstream 2b3c965.)
- **Reject** `count > N` weak assertions.
- Test modules: Scheduler lifecycle + concurrency, OOMGuard (full), MemoryTracker (partial gaps), AdmissionGate (partial gaps), HardwareRouter (Mirror + Integration — see table below).

---

### Upstream Alignment Gaps

| Issue | File | Status |
|-------|------|--------|
| **ThinkingBudget hard-budget** | Engine/EngineInference.swift | ✅ Wired std reasoning path (686161c L3314 applyingThinkingBudget); Guided/MTP paths non-reasoning = no budget needed; guided/MTP `components: .init()` (L2697/L2881) intentional |
| **SyncInputHandler** | — | ✅ Upstream d667610 已无 `InputHandler`/`InputCoverage` 符号，gap 消失 |
| **ChatConventionsRegistry** | — | ✅ Upstream d667610 已无 `ChatConventionsRegistry`，reasoningConfig 内化至管线 |
| **AgentLoop runner** | Agents/AgentLoop.swift | ✅ Pruned at 4c231d3 — enum runner + `AgentLoopConfig` removed (zero callers); `AgentLoopResult`/`AgentLoopIterationLog` kept (ThinkingTelemetry). Agent loop now owned by `DirectInferenceClient` + `ChatHandler`. |
| **MLX upstream sync gap** | Package.swift | ✅ Resolved (2026-08-28): pinned at `37688d2` (#572 Qwen GDN fused decode + #573 Qwen direct-reduction decode, 均 consumer-free-ride / zero direct refs) / 前序 6745899 (2026-08-26) 5 free-rider 全 consumer-transparent。 |
| **KVCache typed config** | Engine/MLXBridge.swift | ✅ Wired via makeKVCacheConfiguration (L635) TurboQuant+Affine through generateParameters.kvCache; upstream CacheConfiguration merged into GenerateParameters at d667610 |
| **MTP spec decode** | Engine/EngineInference.swift | ✅ Aligned — blockSize from specDecodingConfig.numDraftTokens (L2880) + upstream auto-clamp; MTPDrafterModelWrapper is type wrapper not gap |
| **TurboFlash** | EngineInference.swift | ✅ Consumed internally by upstream `generate*()` — TurboFlash is an attention kernel mechanism; ocoreai doesn't call it directly |
| **CoreAI grammar constrained decoding** | Engine/ | ✅ Wired (b69b934 + c4c0a43) — `MPSGraphSamplers` provides MPS constrained argmax/composite via CoreAI `sampleToken` path; `TokenizersMLXTokenizerAdapter` bridges upstream Tokenizer. `ConstrainedGeneration` conformers in Engine/. |
| **iOS UI parity** | UI/ | ⚠️ iOS build confirmed Fast-Path-only; full parity audit pending (MCP/Security on iOS TBD) |
| **PerceptionEngine** | Multimodal/PerceptionEngine.swift | ✅ `PerceptionChannel` **7 cases** (`Multimodal/PerceptionContext.swift:14-30`: camera / screen / audio / network / environment / system / speaker) — full perception scheduler with RingBuffer, adaptive sampling, inference-aware snapshot. Cross-platform gates (screen macOS-only, filesystem all). |

### Legacy Issues (Previously Fixed)

| Issue | File | Status |
|-------|------|--------|
| MLX path cross-session leakage | SessionPool.swift | ✅ Fixed — full cleanup on pool release |
| CoreAI variant chunkedStatic+sequential incompatibility | CoreAIEngine.swift | ✅ Fixed — guard throws |
| CoreAI vocabSize Qwen3-specific default | CoreAIEngine.swift | ✅ Fixed — model-agnostic 32,768 |
| CoreAI staticShape/pipelined engine | CoreAIEngine.swift | ✅ All 3 variants wired: StaticShape, Pipelined, Sequential (c4c0a43) — `.pipelined` selectable in EngineFactory |
| PagedKVCache removed | — | ✅ Resolved (P0 cleanup) |
| MLX KVCacheRound/TurboFlash/TurboQuant | EngineInference.swift | ✅ Consumed upstream — no gap |
| MTP toolCall dispatch | EngineInference.swift | ✅ Aligned with upstream `MTPSpeculativeTokenIterator` |
| ReasoningEventEmitter | Engine/EngineInference.swift | ✅ Wired (both MLX + CoreAI paths) |
| Reasoning `<thinking>` regex | Engine/ | ⚠️ Limited — regex-based, no AST |
| MLXFoundationModels deeper integration | Engine/ | FM path wired; lacks per-token callback on FM `.done` |
| `kvCacheRuntimeReport` diagnostic | — | ⚠️ Not consumed by ocoreai — upstream `KVCacheRuntime.swift:147` + `ChatSession.swift:1449` + `KVCachePlan.swift:89/94` still present at d667610 and d7dc03d |
| try? scatter | defensive-fallback pattern across tools/models/multimodal/mcp/engine | Ongoing risk |
| precondition | known placements: structural invariants + upstream-verbatim (Wan 2.1 数值面 `00e199a` + Speech Tier-A `765e3b5` + xgrammar seam) — set is grep-inspected, not a tracked count | ⚠️ Known; do not add new ones |
| fatalError | 0 in production code | ✅ Clear |
| Empty catch {} | EngineInference | 2 remaining — Task.sleep watchdog deadline tolerance |
| Coverage report | Tests/CoverageReport | Missing — no live data |
| HardwareRouter tests | Tests/ | ✅ Mirror + Integration suites present |
| AdmissionGate tests | Tests/ | ✅ reservation, jitter, emergency suites |

---

### Upstream Audit Dependencies

Three sources for empirical verification:
1. **mlx-swift-lm** — pinned at `37688d2` (2026-08-28: #572 Qwen GDN fused decode + #573 Qwen direct-reduction decode + public `SwitchLayer.callAsFunction`, 均 consumer-free-ride / zero direct refs; 前序 6745899 (2026-08-26) 5 free-rider 全 consumer-transparent / 1441444 #544 β5-SDK 编译修复, 2026-08-23)
2. **coreai-models** — reference at `coreai-models@de31ba5` (2026-08-29: #204 PrefillGraph prefill 入口已吸收; 前序 f43b6da Flux2 RoPE+Wan#195+quant#194, 2026-08-25; 86b363d #187 OpenAI LLM server, 2026-08-21)。Reference repo, not SPM dependency。
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

- **Direct commits to `main`** — no branch ritual; the CI gate (`make test-ci` equivalent on macos-26) is the authority, run green before push
- Every commit message: what changed + verification evidence (test count / command output)
- One logical change per commit
- `CHANGELOG.md` updated with every user-visible change (commit reference mandatory)

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
- `code-review-discipline` — Phase 5a standards scan
- (Phase 1 intent-alignment + 3-layer verification (grep → compile → read) are folded into `code-review-discipline` body + Agent Execution Rule #1 — no separate skill; the previously listed `engineering-grilling` / `code-audit-methodology` dead pointers removed at 2026-08-30 audit.)

**Pre-loaded domain skills (already in context):**
- `hermes-agent` — CLI commands, toolsets, profiles
- `ocoreai-dev` — ocoreai build/test/debug
