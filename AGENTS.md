# ocoreai — Project Context for AI Agents

> This file is loaded by Hermes on every session. It anchors the agent to the project's conventions, architecture, and known issues — zero cold-start tax.

---

## Identity

**What it is:** macOS-native AI agent runtime — dual-channel on-device inference (MLX Metal GPU + CoreAI ANE), agent loop with tool dispatch, skill system, session memory, multimodal I/O, ReasoningEventEmitter pipeline. One binary, 135 Swift files (38,836 LOC).

**Tech stack:** Swift 6.3 · SwiftPM · Hummingbird 2.25 · SwiftUI · SQLite + FTS5

**Key modules:** 21 subdirectories under `Sources/ocoreai/`: Engine, Agents, Client, Scheduler, MCP, Tools, UI, SQLite, Config, Multimodal, Reasoning, Profiling, Tokenizer, Security, Skills, etc.

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
- MLX path: `_runInferenceWithMessages()` → `ChatSession` (session pool, guided gen, toolDispatch)
- CoreAI path: `_runInf()` → `engine.generate()` — no session pool, falls back to MLX for guided gen
-ANE path: Stub/empty via CoreAI — no specialization yet
- MTP path: Bypasses session pool entirely, tool calls collected but dispatched after (no multi-turn)

**Key:** `#if canImport(CoreAI)` single-layer compile-time gate; `sampleToken()` → argmax; toolDispatch wired in both MLX and CoreAI paths.

---

## Build / Test / Lint

```bash
swift build -c release                    # production build
swift build --traits mlx                 # debug build with mlx
swift test                               # all 703 tests
swift test --enable-code-coverage        # with coverage
swift test --filter OcoreAITests.System  # system tests only
```

**Linting:** SwiftLint via `.swiftlint.yml`. Bug-catching rules only — not style enforcement. `force_unwrapping: warning`, `implicitly_unwrapped_optional: warning`. Run via `swiftlint lint`.

**Build verification is MANDATORY** before claiming completion. `swift build` exit code 0 = done.

---

## Code Conventions

### Concurrency
- Swift 6 strict concurrency mode. `Sendable` enforcement active.
- `EnginePool` is an `actor` with `@unchecked Sendable` mutable state (perform-based isolation).
- UI layer runs on `@MainActor`. Engine layer is actor-isolated. Cross-actor calls via `await`.
- `@unchecked Sendable` requires justification comment. Closure `var` declared inside closure scope (not outer).

### Error Handling
- **Zero `try!`, `as!`, `fatalError`, `assert`, `precondition`, `print()`** in production code.
- `129 try?` usages exist — MCP files are the hotspot (10+ each). Known risk.
- `ErrorContext.swift` infrastructure exists but is **unused** — `withLog`/`withLogAsync` have zero callers.
- 3 empty `catch {}` blocks on async operations (EngineInference L62,116; MCPStdioClient L137).

### Naming
- Target names ≠ module boundaries (e.g., `GuidedGenerationLoop` is peer to `ChatSession`, not nested).
- No FIXME/TODO/HACK/XXX in source (verified clean).

### Testing Quality
- Gold standard: `ThinkingBudget`, `BlockPool`, `ComplexityAnalyzer` — exact value assertions (`#expect == N`), parameterized traversal, boundary assertions.
- **Reject** `count > N` weak assertions.
- Test modules: Scheduler lifecycle + concurrency, OOMGuard (full), MemoryTracker (partial gaps), AdmissionGate (partial gaps), HardwareRouter (ZERO tests).

---

## Known Gaps (2026-07-27 Current State)

| Issue | File | Status |
|-------|------|--------|
| PagedKVCache removed | 2b3c965 | ✅ Resolved (P0 cleanup) |
| SpecDecodingConfig.mode | EnginePool.swift L438 | ✅ Wired (consumed) |
| ReasoningConfig | EngineInference.swift L1078 | ✅ Wired (ReasoningEventEmitter) |
| MTP toolCall dispatch | EngineInference.swift L960-982 | ✅ Wired (76b7e79) |
| ReasoningEventEmitter | Engine/EngineInference.swift 两处 | ✅ 新基础架构 |
| Reasoning `<thinking>` regex | Engine/ | Limited — only regex-based |
| MLXFoundationModels deeper integration | Engine/ | Partial — comment reference only |
| try? scatter | 171 instances MCP/Models hotspot | Ongoing risk |
| Empty catch {} | EngineInference L123,168 | 2 instances remain |
| Coverage report | Tests/CoverageReport | Missing — no live data |

---

## Upstream Audit Dependencies

Three sources for empirical verification:
1. **mlx-swift-lm** — locked at 18edd22, HEAD 78eaa5b (+20 commits)
2. **coreai-models** — locked at 5ed9981, HEAD 04a3fd6 (+20 commits)
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
