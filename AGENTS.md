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
- **MLX path reality:** `_runInferenceWithMessages()` → `ChatSession` (session pool, guided gen, toolDispatch) — ReasoningEventEmitter ✅ (wired, both MLX + CoreAI paths), KVCacheRuntime ✅ (turboQuant/affine via MLXBridge L635). Pinned upstream `mlx-swift-lm` at `e3d4a20` (2026-09-03 `d7bd972` ← `5694a2f` #599 ← 37688d2 #572/#573 + #602 Gemma4Text loraLayers + #589 Qwen3.5/3Next + #605 + #471 ParoQuant MoE). Gaps: upstream ThinkingBudget hard-budget enforcement ❌ (orthogonal to ocoreai ThinkingBudget actor; std reasoning path wired L3314).
- **CoreAI** — derived from Apple's coreai-models reference (BSD-3-Clause), simplified for ocoreai: types redefined locally to avoid macOS 27 platform requirement. Engine/ contains CoreAI* ×8 + StateHandler ×3 + MPSGraphSamplers + KVCache+CoreAI + TensorStorage+CoreAI (37 .swift total); + Tokenizer/TokenizersMLXTokenizerAdapter.
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
- Precondition near-free: production code uses precondition/preconditionFailure only for structural invariants and upstream-verbatim numeric/speech surfaces; new code must not add them. **Verified 2026-09-04 (8 sites):**
  - Video/DiscreteFlowScheduler (`preconditionFailure` ×3)
  - Video/TiledDecode3D (`precondition` ×1)
  - Multimodal/StreamingWindow (`precondition` ×1)
  - Engine/CoreAIPipelinedEngine (`precondition` ×1)
  - Engine/KVCache+CoreAI (`precondition` ×1)
  - Engine/CoreAIStubs (`precondition` ×1)
  - Engine/GuidedGeneration/PipelinedConstrainedDecodingStrategy (`preconditionFailure` ×1)
- **Zero `try!`** in production code.
- **`print()`:** 0 in production code (18→0 at commit 4c231d3).
- **`fatalError`:** 0.
- `assert`: **0** (verified 2026-09-04 by grep — no `assert(` outside `precondition*` in Sources/).
- `try?`: used as the defensive-fallback pattern; `try?` stays acceptable where a real fallback follows.
- `ErrorContext.swift` does not exist (grep = 0).
- `Profiling/` contains **2 files** (2026-09-04 verified): `TimingHooks.swift` + `PerformanceMetrics.swift`.

### Naming
- Target names ≠ module boundaries (e.g., `GuidedGenerationLoop` is peer to `ChatSession`, not nested).
- Zero TODO/FIXME/HACK/XXX in Sources (verified by grep; a historical FMToolBridge image-path note was removed with refactoring).

### Testing Quality
- Gold standard: `ThinkingBudget`, `ComplexityAnalyzer` — exact value assertions (`#expect == N`), parameterized traversal, boundary assertions. (BlockPool gold-standard test removed with the module at upstream 2b3c965.)
- **Reject** `count > N` weak assertions.
- Test modules: Scheduler lifecycle + concurrency, OOMGuard (full), MemoryTracker (partial gaps), AdmissionGate (partial gaps), HardwareRouter (Mirror + Integration — see table below).

---

### Open (currently unresolved — the only items worth prose)

- **iOS UI parity** (UI/) — iOS build confirmed Fast-Path-only; parity audit pending (MCP/Security on iOS TBD).
- **Reasoning `<thinking>` parse** (Engine/) — regex-based, no AST.
- **`kvCacheRuntimeReport`** — not consumed; upstream `KVCacheRuntime.swift:147` / `ChatSession.swift:1449` / `KVCachePlan.swift:89/94` still present (d667610).
- **MLXFoundationModels** — FM path wired; lacks per-token callback on FM `.done`.
- **Hygiene — do not add new**: `precondition` (structural invariants + upstream-verbatim); scattered `try?` defensive fallbacks (ongoing risk); 2 `empty catch {}` in the EngineInference watchdog.
- **Coverage report** — Tests/CoverageReport missing (no live data).

**Resolved items** (ThinkingBudget wiring, SyncInputHandler, ChatConventionsRegistry, AgentLoop pruned, KVCache typed config, MTP, TurboFlash, CoreAI grammar, PagedKVCache removed, ReasoningEventEmitter, HardwareRouter/AdmissionGate tests, 0 fatalError): not restated here — source of truth is `CHANGELOG.md` + `~/wiki/concepts/upstream-mlx-swift-lm*.md` + `~/wiki/concepts/upstream-coreai-models.md`.

---

### Upstream Audit Dependencies

Three sources for empirical verification:
1. **mlx-swift-lm** — pinned in `Package.resolved` at `e3d4a20` (2026-09-03 `d7bd972`; 前序 5694a2f #599; 37688d2 #572/#573 consumer-free-ride). Upstream origin/main = `e3d4a20` (0 drift, 2026-09-04 verified via `git rev-list --count e3d4a20..origin/main` = 0).
2. **coreai-models** — reference at `cefd53d` (#215; 含 b11ac19 #188 StaticInputHandler = 正源). Reference repo, not SPM dependency.
3. **Apple Developer Docs** — developer.apple.com/documentation/CoreAI (requires login)

**Wiki:** `~/wiki/concepts/upstream-mlx-swift-lm-38927f5-intent.md` + `~/wiki/concepts/upstream-coreai-models.md` — consumption matrix with file:line evidence.

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
