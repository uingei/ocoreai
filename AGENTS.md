# ocoreai — Project Context for AI Agents

> This file is loaded by Hermes on every session. It anchors the agent to the project's conventions, architecture, and known issues — zero cold-start tax.

---

## Identity

**What it is:** macOS-native AI agent runtime — dual-channel on-device inference (MLX Metal GPU + CoreAI derived from coreai-models reference), agent loop with tool dispatch, skill system, session memory, multimodal I/O, ReasoningEventEmitter pipeline, persistent-perception system. One binary, ~150 Swift files (46,889 LOC).

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
- **MLX path reality:** `_runInferenceWithMessages()` → `ChatSession` (session pool, guided gen, toolDispatch) — **fully aligned** with upstream `mlx-swift-lm` `0b47e69`
- **CoreAI** — derived from Apple's coreai-models reference (BSD-3-Clause), simplified for ocoreai: types redefined locally to avoid macOS 27 platform requirement. Currently sequential-only (`CoreAISequentialEngine` ~556 LOC); `AIModelCache` (~60 LOC) for compiled model artifact caching; staticShape/pipelined not yet implemented.
- **ANE path:** Stub/empty via CoreAI — no specialization yet
- **MTP path:** `_runInferenceWithMessages` → `generate(::mtpDrafter:)` — bypasses ChatSession, tool calls collected + dispatched per-iteration (aligned with upstream `MTPSpeculativeTokenIterator`)
- **SessionPool:** Prefix-level prompt cache reuse via message divergence tracking; HardwareRouter pressure events trigger aggressive eviction; `loadPromptCacheSnapshot` restores LM state + KV cache

**Key:** `#if canImport(CoreAI)` single-layer compile-time gate; `sampleToken()` → argmax; toolDispatch wired in both MLX and CoreAI paths.

**Upstream alignment (verified 2026-08-12):**
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
- `EnginePool` is an `actor` with `@unchecked Sendable` mutable state (perform-based isolation).
- UI layer runs on `@MainActor`. Engine layer is actor-isolated. Cross-actor calls via `await`.
- `@unchecked Sendable` requires justification comment. Closure `var` declared inside closure scope (not outer).

### Error Handling
- **Precondition free in production code** — 0 `precondition` calls remain after P0 cleanup; all replaced with guard/throw/clamp.
- **Zero `try!`, `as!`, `print()`** in production code.
- **Remaining:** 2 `fatalError` (defense-only stub + unreachable SDK regression path), 1 `assert` (release-optimized away in Tools/ToolEntry).
- `try?` usages concentrated in MCP/Models hotspot (~200 instances, defensive fallback pattern).
- `ErrorContext.swift` does not exist — `Profiling/` only contains `TimingHooks.swift`.
- 2 empty `catch {}` blocks on async operations (EngineInference, watchdog cancellation).

### Naming
- Target names ≠ module boundaries (e.g., `GuidedGenerationLoop` is peer to `ChatSession`, not nested).
- No FIXME/TODO/HACK/XXX in source (verified clean).

### Testing Quality
- Gold standard: `ThinkingBudget`, `BlockPool`, `ComplexityAnalyzer` — exact value assertions (`#expect == N`), parameterized traversal, boundary assertions.
- **Reject** `count > N` weak assertions.
- Test modules: Scheduler lifecycle + concurrency, OOMGuard (full), MemoryTracker (partial gaps), AdmissionGate (partial gaps), HardwareRouter (ZERO tests).

---

## Known Gaps (2026-08-12 Current State)

| Issue | File | Status |
|-------|------|--------|
| MLX path cross-session leakage | SessionPool.swift | ✅ Fixed — full cleanup on pool release |
| CoreAI variant chunkedStatic+sequential incompatibility | CoreAIEngine.swift | ✅ Fixed — guard throws |
| CoreAI vocabSize Qwen3-specific default | CoreAIEngine.swift | ✅ Fixed — model-agnostic 32,768 |
| CoreAI staticShape/pipelined engine | CoreAIEngine.swift | ❌ Not implemented — auto-detect falls back to sequential |
| PagedKVCache removed | — | ✅ Resolved (P0 cleanup) |
| MLX KVCacheRound/TurboFlash/TurboQuant | EngineInference.swift | ✅ Consumed upstream — no gap |
| MTP toolCall dispatch | EngineInference.swift | ✅ Aligned with upstream `MTPSpeculativeTokenIterator` |
| ReasoningEventEmitter | Engine/EngineInference.swift | ✅ Wired (both MLX + CoreAI paths) |
| Reasoning `<thinking>` regex | Engine/ | ⚠️ Limited — regex-based, no AST |
| MLXFoundationModels deeper integration | Engine/ | FM path wired; lacks per-token callback on FM `.done` |
| `kvCacheRuntimeReport` diagnostic | ChatSession.swift | ⏳ Upstream API available, not consumed yet |
| try? scatter | ~200 instances MCP/Models hotspot | Ongoing risk |
| precondition | 0 in production (P0 cleanup complete) | ✅ Resolved |
| fatalError | 2 (defense-only stub + unreachable SDK path) | Acceptable |
| Empty catch {} | EngineInference | 2 instances remain |
| Coverage report | Tests/CoverageReport | Missing — no live data |
| HardwareRouter tests | Tests/ | ❌ Zero coverage |
| AdmissionGate tests | Tests/ | ⚠️ Partial coverage |

---

### Upstream Audit Dependencies

Three sources for empirical verification:
1. **mlx-swift-lm** — pinned at `0b47e69` (2026-08-12: KVCacheRound staged rounds #516, TurboFlash short-context fast-path #520, Qwen3MoE sanitization #490, PrefillParameters balanced chunking #470, typed KVCache config #453, MTP speculation past sliding window, ChatConventions migration #502, custom LogitProcessor injection #401)
2. **coreai-models** — pinned at upstream main; ConstrainedGenerationSession, XGrammar, Pipelined/Sequential engines, StateHandler, VLM engine, CompositeSampler, PerformanceMetrics (reference repo, not SPM dependency)
3. **Apple Developer Docs** — developer.apple.com/documentation/CoreAI (requires login)

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
