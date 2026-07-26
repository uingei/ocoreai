# ocoreai Architecture Review

> **Status**: Complete — based on source-level reading of 137 Swift files (40,355 LOC)
> **Date**: 2026-07-26
> **Build**: `swift build --target ocoreai` → ✅ exit 0 (1 warning)
> **Methodology**: architecture-analysis skill + code-audit-methodology three-layer verification

---

## 1. Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        HTTP API Layer                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │ ChatHandler  │  │ AnthropicMsg │  │ Multimodal   │          │
│  │ (SSE/OpenAI) │  │ Handler      │  │ Handler      │          │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘          │
│         │                 │                 │                   │
│         ▼                 ▼                 ▼                   │
│  ┌────────────────────────────────────────────────────┐         │
│  │              Router / Middleware                   │         │
│  │  AuthMiddleware, RateLimitMiddleware, SSEHelpers   │         │
│  └────────────────────┬───────────────────────────────┘         │
└──────────────────────┼──────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Engine Layer (actor)                         │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │ EnginePool   │  │ EngineHandle │  │ LoadedModel  │          │
│  │ (orchestrator)│  │ (facade)     │  │ (per-model)  │          │
│  │  - LRU evict  │  │ - generate*  │  │ - CAS warmup │          │
│  │  - session mgr │  │ - tokenize   │  │ - CAS infer  │          │
│  │  - model load │  │              │  │ - session ct │          │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘          │
│         │                 │                 │                   │
│         ▼                 ▼                 ▼                   │
│  ┌────────────────────────────────────────────────────┐         │
│  │         EngineInference (extension)                  │         │
│  │  - _runInference()     → CoreAI engine.generate()    │         │
│  │  - _runInferenceWithMsgs() → MLX ChatSession         │         │
│  │  - handleGuidedGeneration() → GuidedGenerationLoop   │         │
│  │  - MTP path → MLXLMCommon.generate(mtpDrafter:)      │         │
│  └────────────────────────────────────────────────────┘         │
│                                                                 │
│  ┌────────────────────────────────────────────────────┐         │
│  │  Backend Abstraction Layer                          │         │
│  │  BackendProtocol (protocol)                         │         │
│  │  BackendDescriptor: coreai/mlx/stub                 │         │
│  │  ⚠️ Protocol defined but NOT used by EnginePool     │         │
│  └────────────────────────────────────────────────────┘         │
│                                                                 │
│  ┌────────────────────────────────────────────────────┐         │
│  │  Backend Implementations                            │         │
│  │  CoreAIBridge.swift → AIModel/InferenceFunction     │         │
│  │  MLXBridge.swift → ModelContainer/ChatSession         │         │
│  └────────────────────────────────────────────────────┘         │
└──────────────────────┬──────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Scheduler Layer                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │ SchedulerActor│  │ AdmissionGate│  │ MemoryTracker│          │
│  │ (priority Q)  │  │ (OOMGuard)   │  │ (GPU budget)  │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
└──────────────────────┬──────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│                    UI Layer (SwiftUI)                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │ DirectInfe-  │  │ ChatViewModel│  │ SessionMgr   │          │
│  │ renceClient  │  │ (streaming)  │  │ (SQLite)     │          │
│  │ (Fast Path)  │  │              │  │              │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. Per-Layer Analysis

### 2.1 HTTP API Layer (Handlers/)

**Files**: ChatHandler.swift (1126 lines), AnthropicMessagesHandler.swift, MultimodalHandler.swift, LLMLifecycleHandler.swift, MessageBuilder.swift, SSEHelpers.swift

**Key abstractions**:
- `ChatHandler` implements OpenAI-compatible `/chat/completions` with SSE streaming
- `MessageBuilder` assembles conversation context from SQLite session history
- `InferenceCancellation` (CancellationFlag) — lock-guarded token, replaces leaking Task-based design

**Notable patterns**:
- 3-layer parameter fallback: Request body → Runtime defaults → System hard-coded defaults
- `ContentGuard.checkOutput()` wired at L717 on the HTTP streaming path
- `ThinkingTelemetry.signal()` at L609 for reasoning calibration

### 2.2 Engine Layer (Engine/)

**Files**: EnginePool.swift (740 lines), EngineInference.swift (1387 lines), LoadedModel.swift (338 lines), EngineHandle.swift (164 lines), BackendProtocol.swift (58 lines), MLXBridge.swift (770 lines), CoreAIBridge.swift (247 lines)

#### EnginePool (actor)
- Single orchestration actor with `@unchecked Sendable` mutable state
- LRU eviction: `maxLoadedModels = 4`, evicts idle models (zero active sessions)
- Session pool: `MLXSessionPool` — KV cache reuse for MLX path only
- PagedKVCache: optional, nil when disabled
- **Critical**: `BackendProtocol` is defined but NOT used — EnginePool contains inline `#if canImport(CoreAI)` branches instead of delegating to backends

#### EngineInference (extension)
Contains the core inference dispatch logic with three parallel paths:

| Path | Trigger | Backend | Session Pool | Guided Gen | Tool Dispatch |
|------|---------|---------|-------------|------------|---------------|
| `_runInference` | `generateTokens()` (HTTP API) | CoreAI | ❌ No | ❌ Falls back to MLX | ❌ Falls back to MLX |
| `_runInferenceWithMessages` | `generateFromMessages()` (UI fast path) | MLX | ✅ Yes | ✅ GuidedGenerationLoop | ✅ ChatSession.toolDispatch |
| MTP | `mtpDrafterContainer != nil` | MLX direct `generate()` | ❌ Bypasses pool | ❌ No | ⚠️ Collected but dispatched after (no multi-turn) |

**Key architectural decisions**:
1. **CoreAI path lacks grammar/tool constraints** — when `options.grammarSchema != nil` or `options.useGuidedGeneration`, CoreAI path falls back to MLX (L216-239)
2. **CoreAI path lacks stop sequences** — falls back to MLX when `sampling.stopSequences` is non-empty (L252-270)
3. **CoreAI path lacks seed/repetition/presence/frequency penalties** — logged as warning but silently dropped (L243-276)
4. **MTP path bypasses ChatSession** — calls `MLXLMCommon.generate(mtpDrafter:)` directly, tool calls are collected but not multi-turn (L1039-1206)

#### LoadedModel
- Per-model lifecycle with CAS-guarded warmup (`wasPrewarmed`), inference lock (`inferenceGuard`), and session counter (`sessionCount`)
- Dual backend storage: `mlxModelHandle` (always) + `_preparedModel` (CoreAI only, `Any?` to break `@available` leakage)
- `getCachedEngine()` uses dedicated `engineCacheGuard` CAS — decoupled from `inferenceGuard` so concurrent requests aren't rejected during engine creation

#### BackendProtocol (UNUSED)
```swift
protocol BackendProtocol: Sendable {
    var descriptor: BackendDescriptor { get }
    func loadModel(modelId: String, configData: Data, modelURL: URL, logger: Logger) async throws -> BackendModelHandle
    func releaseModel(_ handle: BackendModelHandle)
    func generate(handle: BackendModelHandle, input: [Int32], sampling: SamplingConfiguration, options: InferenceOptions, completion: @Sendable (InferenceEvent) -> Void) async throws
}
```
**This protocol is defined but never conformed to by any type.** EnginePool uses inline `#if canImport(CoreAI)` branches instead.

### 2.3 Scheduler Layer (Scheduler/)

**Files**: SchedulerActor.swift, AdmissionGate.swift, OOMGuard.swift, MemoryTracker.swift, HardwareRouter.swift, SchedulerModels.swift

- `SchedulerActor` — priority queue with `submitAndDispatch()`
- `AdmissionGate` / `OOMGuard` — wired on BOTH paths:
  - HTTP API: ChatHandler → SchedulerActor.submitAndDispatch (L700+)
  - UI Fast Path: DirectInferenceClient → SchedulerActor.submitAndDispatch (L211)
- `MemoryTracker` — reports GPU memory to HardwareRouter for compute channel decision
- `HardwareRouter` — queries `.gpu` / `.cpu` / `.ane` based on memory pressure
  - CPU channel disables session pool + speculative decoding
  - ANE channel routes to CoreAI engine

### 2.4 UI Layer (UI/)

**Files**: ChatView.swift, ChatViewModel.swift, DirectInferenceClient.swift (689 lines), SessionManager.swift, ModelManager.swift

- `DirectInferenceClient` — `@MainActor` fast path, bypasses HTTP entirely
- `ChatViewModel` — streaming consumption, `splitThinkingTags()` only runs at `isComplete` (L627)
- `TranscriptPart` — structured transcript types with collapsible rendering (reasoning, toolCall)

---

## 3. Design Principles Extracted

1. **Dual-backend with graceful degradation**: CoreAI path falls back to MLX for unsupported features (grammar, stop sequences, tool calls). No silent failures — explicit fallback with logging.

2. **Session pool for MLX only**: CoreAI's `supportsSessionPool = false` — KV cache persists via engine-level caching instead. MLX uses `MLXSessionPool` for conversation-level KV reuse.

3. **Wired memory isolation**: `WiredMemoryTicket` scopes per-request GPU memory. Ticket size estimates KV cache only (`maxContextLength * 2048 bytes`), excludes resident weights to avoid double-counting.

4. **CAS-guarded lifecycle**: Warmup, inference lock, engine cache, and session counting all use `ManagedAtomic` with dedicated CAS flags — no actor mailbox blocking for atomic operations.

5. **Three-layer parameter fallback**: Request → Runtime defaults → System defaults. Applied consistently across HTTP API and UI fast path.

6. **Safety on both paths**: ContentGuard output filtering, OOMGuard admission, ThinkingBudget calibration — all wired on both HTTP API and UI fast path.

7. **MTP tool call collection**: Even though MTP bypasses ChatSession's tool loop, tool calls are collected and dispatched after generation (L1182-1206). Not multi-turn but prevents silent loss.

---

## 4. Key Source References

| Component | File | Lines | Size |
|-----------|------|-------|------|
| EnginePool (orchestrator) | Engine/EnginePool.swift | 1-740 | 29.8 KB |
| EngineInference (dispatch) | Engine/EngineInference.swift | 1-1387 | 75.8 KB |
| LoadedModel (lifecycle) | Engine/LoadedModel.swift | 1-338 | 14.3 KB |
| EngineHandle (facade) | Engine/EngineHandle.swift | 1-164 | 6.3 KB |
| BackendProtocol (unused) | Engine/BackendProtocol.swift | 1-58 | 2.2 KB |
| MLXBridge (MLX loader) | Engine/MLXBridge.swift | 1-770 | 33.4 KB |
| CoreAIBridge (CoreAI) | Engine/CoreAIBridge.swift | 1-247 | 9.7 KB |
| ChatHandler (HTTP API) | Handlers/ChatHandler.swift | 1-1126 | 49.3 KB |
| DirectInferenceClient | Client/DirectInferenceClient.swift | 1-689 | 27.7 KB |
| SchedulerActor | Scheduler/SchedulerActor.swift | — | — |
| SessionPool | Engine/SessionPool.swift | — | — |

---

## 5. Risk Assessment

### 🔴 High Priority

| Risk | Location | Impact | Evidence |
|------|----------|--------|----------|
| **BackendProtocol unused** | BackendProtocol.swift:36 | Architectural drift — protocol defined but EnginePool uses inline `#if` branches | `BackendProtocol` never conformed to by `CoreAIBridge` or `MLXBridge`; EnginePool L382-449 contains inline `#if canImport(CoreAI)` |
| **CoreAI path lacks grammar/stop/tool** | EngineInference.swift:216-270 | CoreAI requests silently fall back to MLX, negating ANE acceleration | L216: grammar fallback, L252: stop sequence fallback, L243-276: seed/repetition/presence/frequency warnings |
| **MTP tool calls not multi-turn** | EngineInference.swift:1182-1206 | Tool calls collected but dispatched after generation — no follow-up round | L1039: `registeredToolSpecs == nil` guard, L1182: single dispatch loop |
| **Caught error unused** | EngineInference.swift:1329 | Build warning — error caught but not propagated | `if let caughtError {` defined but never used (build warning confirmed) |

### 🟡 Medium Priority

| Risk | Location | Impact | Evidence |
|------|----------|--------|----------|
| **Progressive rendering gap** | ChatViewModel.swift:627 | User sees blank bubble during reasoning phase | `splitThinkingTags()` only runs when `chunk.isComplete == true` |
| **Reasoning delimiters hardcoded** | ChatViewModel.swift:159 | DeepSeek-R1 `<thinking>` tags not extracted | Regex only matches `` `` tags |
| **stopReason not exposed to UI** | EngineInference.swift:874-878 | `.maxTokens` stop reason silently truncated | Guided path distinguishes `.eos` vs `.maxTokens` but UI has no rendering for `.maxTokens` |
| **Session restore data loss** | EngineInference.swift:1230-1231 | Pool miss path may lose message history | `deltaOffset` tracks message count but pool miss resets to 0; relies on `sliceStart = min(deltaOffset, mlxMessages.count)` |

### 🟢 Low Priority / Mitigated

| Risk | Location | Status | Evidence |
|------|----------|--------|----------|
| **PagedKVCache no data flow** | PagedKVCache.swift | ✅ Lifecycle hooks exist, data path verified | `attach()`/`evictSession()` called in EnginePool L269/286; `getMemoryBytes()` consumed in EnginePool L547 |
| **OOMGuard wired on both paths** | DirectInferenceClient.swift:211 | ✅ Verified | `scheduler.submitAndDispatch()` called on both HTTP API (ChatHandler) and UI fast path |
| **ContentGuard on both paths** | DirectInferenceClient.swift:124, ChatHandler.swift:717 | ✅ Verified | Both paths call `contentGuard.checkInput()` / `checkOutput()` |

---

## 6. Architecture-Architecture Misattribution Check

Per code-audit-methodology, I verified these are NOT false positives:

1. **"PagedKVCache spins uselessly"** — ❌ FALSE POSITIVE (from 2026-07-24 audit). `attach()`/`evictSession()` are called in EnginePool L269/286. `getMemoryBytes()` consumed in EnginePool L547. Lifecycle AND data flow verified.

2. **"OOMGuard missing on Fast Path"** — ❌ FALSE POSITIVE. `DirectInferenceClient.doStreamInference` L211 calls `scheduler.submitAndDispatch()` — same as HTTP API path.

3. **"MTP tool calls silently dropped"** — ✅ CONFIRMED. `case .toolCall: break` at L1145-1153 collects calls but the MTP entry guard (L1039) requires `registeredToolSpecs == nil`. Tool calls are dispatched post-generation (L1182-1206) but not multi-turn.

---

## 7. Recommendations

### Immediate (P0)
1. **Remove unused `BackendProtocol`** or implement it — either conform `CoreAIBridge`/`MLXBridge` to it, or delete the dead protocol to eliminate architectural confusion.
2. **Fix `caughtError` unused warning** — EngineInference.swift:1329. Change `if let caughtError {` to `if caughtError != nil {` or use the error in the yield.

### Short-term (P1)
3. **Document CoreAI path limitations** — add a `BackendDescriptor.coreai` capability matrix (supportsGrammar: false, supportsStopSequences: false, supportsTools: false) so callers can make informed backend choices.
4. **MTP multi-turn tool dispatch** — implement a local tool loop on the MTP path mirroring ChatSession's `pendingToolCalls` → `toolDispatch` → `continue restart` pattern (L781-817 in upstream).

### Medium-term (P2)
5. **Progressive reasoning rendering** — move `splitThinkingTags()` from `isComplete` to per-chunk, so users see reasoning content as it streams.
6. **Model-aware reasoning delimiters** — replace hardcoded `` `` `` regex with `ReasoningConfig.infer()` or model configuration lookup.
7. **Session restore full message array** — use `ChatSession(modelContainer, history: consuming [Chat.Message])` constructor for pool-miss path instead of message slicing.
