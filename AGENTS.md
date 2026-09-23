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

**What it is:** an agent for open models, natively local — built for creativity, work, and code (09-23 对外定版); code 第一切片 = Coding/Computer Agent (reliable Execute → Verify → Recover). Dual-channel on-device inference (MLX Metal GPU + CoreAI derived from coreai-models reference), agent loop with tool dispatch, skill system, session memory, multimodal I/O, ReasoningEventEmitter pipeline, persistent-perception pipeline. One binary.

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
- **MLX path reality:** `_runInferenceWithMessages()` → `ChatSession` (session pool, guided gen, toolDispatch) — ReasoningEventEmitter ✅ (wired, both MLX + CoreAI paths), KVCacheRuntime ✅ (`turboQuant`/`.affine` 双路 `MLXBridge.swift:757 case "affine"` / `:759 case "turbo-quant"`, 映射到 `.affine(:814/:819)` / `.turboQuant(:806)`). Pinned upstream `mlx-swift-lm` at `c6446cf` (#620 TokenIterator 首 token 即清 buffer cache ← 09-14 `3e6ea1e` ← #613 detok Character→Scalar ← #584 RotatingKVCache trim wrap-aware, 09-17 对齐 origin/main). **ThinkingBudget** ✅ (two paths wired: std reasoning `L4005 .applyingThinkingBudget` + MTP speculative `L3508 .applyingThinkingBudget` + `components: genComponents`/`mtpGenComponents` `L4020`/`L3531`（09-22 实核重钉）; `guard mtpReasoningConfig` 非空才接, `catch → .init()` 回退与 std 同语义).
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

- **iOS UI parity** (UI/) — 09-22 实证：工具层平台门控已核 = 正确（10 个 macOS-only：move/click/drag/scroll/type/key + inspect_ui(AX) + open/activate/list_apps(NSWorkspace)，均 macOS 平台语义）；余 = ChatView/MultimodalControls 的 UI 门控（7/5 处）需 iOS 运行时活验（本机 CI 仅 `macOS 26 · iOS compile-only`=success，非活验证；MCP/Security on iOS TBD）。
- **Reasoning `<thinking>` parse** (Engine/) — 字符串协议状态机（`ThinkTagParser`，0 处 regex，#206 后 15/15 绿），无 AST。
- **`kvCacheRuntimeReport`** — ~~not consumed~~ → 09-22 实证：ocoreai 走**自有等价消费面** `Metrics.kvCacheGpuBytes`(`ocoreai_kv_cache_gpu_bytes`, Metrics.swift:79/196)→ `ServerStatsSnapshot.kvCacheBytes` → Dashboard `kvCacheGB`(DashboardViewModel.swift:107)。上游 `KVCacheRuntimeReport`(KVCacheRuntime.swift:155) 是另一套 wrapper，#248 已判 ocoreai 无此 wrapper 的 bug —— 接它 = 本地重复面，不做。
- **MLXFoundationModels** — FM 路 wired（`#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)` + Package.swift L26 默认开）。 ~~lacks per-token callback on FM `.done`~~ → 09-22 实证假缺口：per-token 走 `yieldParserEvents → continuation.yield` AsyncStream（EngineInference.swift L430-470 等，与 std MLX 路同构），不依赖 `.done` 回调（`.done` 只是收尾信号）。上游 0 处 onStreamChunk 概念——此条 phantom gap 撤回。
- **Hygiene — do not add new**: `precondition` (structural invariants + upstream-verbatim); scattered `try?` defensive fallbacks (~316 in Sources/); 2 bare `empty catch {}` in the EngineInference watchdog.
- **Coverage report** — Tests/CoverageReport missing (no live data).

**Resolved items** (ThinkingBudget wiring, SyncInputHandler, ChatConventionsRegistry, AgentLoop pruned, KVCache typed config, MTP, TurboFlash, CoreAI grammar, PagedKVCache removed, ReasoningEventEmitter, HardwareRouter/AdmissionGate tests, 0 fatalError): not restated here — source of truth is `CHANGELOG.md` + `~/wiki/concepts/upstream-mlx-swift-lm*.md` + `~/wiki/concepts/upstream-coreai-models.md`.

---

### Upstream Audit Dependencies

Three sources for empirical verification:
1. **mlx-swift-lm** — pinned in `Package.swift` at `c6446cf`（09-17 对齐 origin/main; #620 TokenIterator 首 token 清 cache 为 HEAD; 前序 `3e6ea1e` #548/#515 ← `604fae7` #584/#613/#615/#611/#597）。0 drift（`git rev-list --count c6446cf..origin/main` = 0, 09-17 核验）。**Bump 协议**：`git log <old>..origin/main` 逐条审计消费面 → bump `.revision` → `swift build` + `make test-ci` 绿 → 审计行记入本节 + CHANGELOG（Package.swift 只留 pin + 指向本节的指针，不写逐 commit 日记）。
2. **coreai-models** — reference at `89ba0d4`（对齐 origin/main，09-18）。`e282dbd..89ba0d4` 5 commit 逐条核验: `#237` 已吸收（`cd9e901`）· `#248` ocoreai capability-first dispatch 无该报表 wrapper,bug 不存在 · `#249` 行为等价内部重构,ocoreai hand-rolled VLM KV 语义与上游重构前一致 · `#250` 上游 `Tools/llm-server` 工具树,ocoreai 0 消费 · `#251` 已吸收（`3497ae8`，shared `SequentialIterator` 提取）。**1 新增吸收（`#251`）、0 行为分叉。** Reference repo, not SPM dependency。#206 ThinkTagParser agentic hardening absorbed (`1076948`)；ATEM ToolCallParser format NOT absorbed（zero ocoreai consumers of `Format.agentic`）。
3. **Apple Developer Docs** — developer.apple.com/documentation/CoreAI (requires login)

**Wiki:** `~/wiki/concepts/upstream-mlx-swift-lm-38927f5-intent.md` + `~/wiki/concepts/upstream-coreai-models.md` — consumption matrix with file:line evidence.

---

## Documentation Map — Agent-facing vs Human-facing

**Rule of thumb:** if the text is *injected into the model's context at runtime*, it is **Agent-facing** — changes alter model behaviour and require an inference regression. If it is read by people (humans or future agents) to understand the project, it is **Human-facing**.

| Doc | Audience | Why | When to touch |
|---|---|---|---|
| `AGENTS.md` (this file) | **Agent** (Hermes, every session) | Injected as project context on cold start | Conventions / architecture facts drift — keep line-accurate |
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
- (Phase 1 intent-alignment + 3-layer verification (grep → compile → read) are folded into `code-review-discipline` body + Agent Execution Rule #1 — no separate skill; the previously listed `engineering-grilling` / `code-audit-methodology` dead pointers removed.)

**Pre-loaded domain skills (already in context):**
- `hermes-agent` — CLI commands, toolsets, profiles
- `ocoreai-dev` — ocoreai build/test/debug
