# ocoreai — Architecture Context Fingerprint

> Generated 2026-06-24 | v2 of 103 Swift files (~23K LOC) at commit `b5cb84e`
> Purpose: queryable reference without re-reading all source files.

---

## Module Index

| Directory | Files | Responsibility |
|-----------|-------|----------------|
| `Engine/` | 18 | MLX/CoreAI backend abstraction, model loading, KV cache, block pool, session pool |
| `Scheduler/` | 5 | Priority queue scheduling, OOM downgrade chain, memory tracking, admission gate |
| `SQLite/` | 5 | RAW-mode SQLite + FTS5 full-text search, session compression, memory events |
| `Security/` | 8 | Keychain, self-adaptation system (EMA thresholds), intent extraction, audit trail |
| `MCP/` | 6 | MCPBridge fan-out routing, stdio transport, LRU call cache |
| `UI/ViewModels/` | 5 | @Observable state: ChatState, ChatVM, SettingsVM, ModelsVM, DashboardVM |
| `UI/Network/` | — | DirectInferenceClient (Fast Path), APIClient (Bridge Path) |
| `UI/Views/` | — | Chat, Dashboard (mock→real), Models, Settings, Multimodal, Status |
| `Router/` | — | ChatCompletionsRouter — 10+ OpenAI/Anthropic-compatible endpoints |
| `Handlers/` | — | ChatHandler (stream/non-stream SSE), MultimodalHandler, ModelLifecycle |
| `Config/` | — | YAML hot-reload config, typed ConfigStruct |
| `Tools/` | — | ToolRegistry, DownloadManager, MCP tool entries |
| `Models/` | — | OpenAIModels, AnthropicModels, InferenceStubs (fallback), HuggingFace/ModelScope downloaders |
| `Tokenizer/` | — | TokenizerManager multi-backend support |
| `Localization/` | — | StringKey enum, EN/ZH translation table (100% i18n) |

---

## Build Variants (Conditional Compilation)

```
#if coreai          → Apple CoreAI backend (macOS 27+)/ M4 Neural Engine
#if mlx             → MLX backend (Apple MLX via Swift bindings)
#if appStore        → App Store build: strips HTTP server, enables sandbox
#if canImport(Metal) → GPU acceleration availability guard
#if DEBUG           → Debug assertions, verbose logging
```

**Trait mapping:** `Package.swift` maps `mlx` and `gui` SPM traits to `-Dmlx` / `-Dgui` compiler flags.
Default traits: `mlx + gui`.

---

## Startup Sequence

```
App.swift / main()
  │
  ├─ OcoreaiEngine.shared.start()
  │   ├─ TokenizerManager.init()
  │   ├─ SchedulerActor.create()
  │   │   └─ priority queue (P0 > P1 > P2 > P3)
  │   ├─ EnginePool.init(config)
  │   │   ├─ #if mlx → MLXModelLoader
  │   │   └─ #if coreai → CoreAIModelLoader
  │   ├─ PagedKVCache.init()        ← block-paged KV cache
  │   ├─ SVKCache.init()            ← sliding window for small models
  │   ├─ MLXSessionPool.init()
  │   ├─ KVCacheManager.init()
  │   ├─ MemoryTracker.init()       ← 4-tier: normal→warning→critical→OOM
  │   ├─ OOMGuard.init()            ← downgrade chain: 4bit→8bit→CPU→refuse
  │   ├─ AdmissionGate.init()       ← request filtering + load protection
  │   ├─ MetricsRegistry.init()     ← Prometheus-compatible gauges/counters
  │   ├─ SQLiteStore.init()         ← RAW-mode + FTS5
  │   ├─ SessionCompressor.init()   ← 3-layer memory: hot/warm/cold
  │   ├─ FTS5Search.init()
  │   ├─ SkillRegistry.load()
  │   ├─ ToolRegistry.load()
  │   ├─ MCPBridge.init()
  │   └─ AgentSelfAdaptation.init() ← EMA health tracking (P0 gate)
  │
  ├─ #if !appStore
  │   └─ Hummingbird app.start()    ← localhost:OCOREAI_HOST:OCOREAI_PORT
  │       ├─ AuthMiddleware (Bearer token + admin grade)
  │       ├─ RateLimitMiddleware (token bucket, per-route quota)
  │       ├─ ChatCompletionsRouter (10+ endpoints)
  │       └─ MetricsMiddleware
  │
  └─ #if appStore
       └─ SwiftUI App launch        ← DirectInferenceClient Fast Path
```

---

## Critical Path: Chat Request (Fast Path)

```
SwiftUI ChatView
  │
  ├─ DirectInferenceClient.stream(messages, config)
  │   │
  │   ├─ MessageBuilder.buildMessages(messages, tools, systemPrompt)
  │   │   └─ → [ChatMessage] with tool definitions + system context
  │   │
  │   ├─ AgentSelfAdaptation.preInferenceCheck(modelId)
  │   │   ├─ healthScore >= 0.7 → .proceed
  │   │   ├─ healthScore >= 0.4 → .proceedWithCaution
  │   │   ├─ healthScore >= 0.25 → .reduceQuality
  │   │   └─ healthScore < 0.25 → .deferRequest
  │   │
  │   ├─ SchedulerActor.submit(request)
  │   │   ├─ AdmissionGate.check(request)
  │   │   │   └─ load check → .accepted / .rejected
  │   │   ├─ priority queue enqueue
  │   │   └─ dispatch() → EnginePool.acquire(sessionId)
  │   │
  │   ├─ EnginePool.acquire(sessionId)
  │   │   ├─ reuse existing session (KV cache warm)
  │   │   └─ or load model → EngineHandle
  │   │
  │   ├─ EngineHandle.generateFromMessages(messages)
  │   │   └─ BackendProtocol.generate()
  │   │       ├─ #if mlx → MLXBackend.generate()
  │   │       └─ #if coreai → CoreAIBackend.generate()
  │   │
  │   └─ → AsyncThrowingStream<InferenceEvent>
  │       ├─ .token(text, count)
  │       ├─ .stop(reason, usage)
  │       └─ .error(message)
  │
  └─ ChatViewModel ← receives tokens via stream sink
       └─ ChatView.body ← renders streamed content
```

---

## Key Type Declarations

### Engine Layer

```swift
// Backend abstraction (zero runtime cost — protocol exists at compile time)
protocol BackendProtocol: Sendable {
    func loadModel(descriptor: BackendDescriptor) async throws -> BackendModelHandle
    func releaseModel(descriptor: BackendDescriptor) async throws
    func generate(
        descriptor: String,
        messages: [ChatMessage],
        tokens: Int,
        config: InferenceConfig
    ) async throws -> AsyncThrowingStream<InferenceEvent, any Error>
}

// Engine pool — session management + model lifecycle
actor EnginePool {
    func acquire(sessionId: String) async -> EngineHandle
    func release(sessionId: String)
    func unloadModel(modelId: String)
    var snapshot: EnginePoolSnapshot { get }
}

// Block-paged KV cache (VLLM-style)
actor PagedKVCache {
    func allocate(blockCount: Int) -> [UInt64]
    func freeTokenRange(sessionId: String, start: UInt64, end: UInt64)
}

// Physical block management
actor BlockPool {
    static func allocate() async -> [BlockPage]
    func recycle(pages: [UInt64], force: Bool)
}

actor MLXModelLoader {               // MLX backend model loading
actor MLXSessionPool {               // per-conversation session pooling
actor CoreAIModelLoader {            // CoreAI backend model loading
actor CoreAIBridge {                 // CoreAI dispatch with compute-target selection
```

### Scheduler Layer

```swift
actor SchedulerActor {
    func submit(_ request: SchedulingRequest) async -> RequestHandle
    func dispatch()
    func complete(handle: RequestHandle, result: InferenceResult)
    func interrupt(handle: RequestHandle)
    func fail(handle: RequestHandle, error: any Error)
    var snapshot: SchedulerSnapshot { get }
}

/// Memory tiered budgeting: normal → warning → critical → OOM
actor MemoryTracker {
    func update(level: MemoryLevel, usageGB: Double)
    var memoryState: MemoryState { get }
}

/// OOM downgrade chain: 4bit → 8bit → CPU → hard refuse
actor OOMGuard {
    func getQuantizationLevel() -> QuantizationLevel
    func reportOOM()
    func recover()
}

/// Request filtering + load protection
actor AdmissionGate {
    func check(request: SchedulingRequest) async -> AdmissionResult
    func updateCapacity(available: Double)
}

public enum RequestPriority: Int, Codable {
    case realTimeChat, chat, background, batch
} // P0 = P1 = P2 = P3 (equal priority, FIFO within tier)
```

### Persistence Layer

```swift
actor SQLiteStore {                 // 42 CRUD methods, RAW-mode SQLite
    func createSession(name: String) async throws -> SessionModel
    func addMessage(_ message: MessageModel) async throws
    func searchSessions(query: String) async -> [SessionSummary]
    // ... +38 more operations
}

actor SessionCompressor {           // 3-layer: hot/warm/cold
    func createSession(name: String) async -> SessionHandle
    func addMessage(handle: SessionHandle, message: String, role: String) async
    func purgeExpired(before: Date) async
}

actor FTS5Search {                  // SQLite full-text search
    func search(query: String, limit: Int) -> [FTSSearchResult]
}
```

### Security / Self-Adaptation

```swift
actor AgentSelfAdaptationActor {    // EMA health tracking + prevention
    static func create(enabled: Bool) -> Self
    static func disabled() -> Self  // zero-overhead stub
    func preInferenceCheck(modelId: String) -> InferenceRecommendation
    func reportCorrection(modelId: String, converged: Bool, iterations: Int, context: String)
    func reportStressEvent(type: StressEventType, severity: Double)
    func getAdaptiveThreshold(modelId: String) -> Double
    func getHealth() -> SystemHealth
}

struct AdaptiveThreshold {          // self-learning thresholds
    mutating func addObservation(success: Bool, iterations: Int, context: String)
    func getThreshold(for modelId: String) -> Double
    func getStats() -> (threshold: Double, observations: Int, recentSuccessRate: Double)
}

struct FailurePatternLibrary {      // pattern memory → prevention rules
    mutating func learnFailure(modelId: String, context: String, iterationCount: Int)
    func getPreventionRules(for modelId: String) -> [PreventionRule]
}
```

### MCP Bridge

```swift
actor MCPBridge {
    static func shared(config: MCPBridgeConfig?) -> MCPBridge
    func routeToolCall(tool: ToolCall, toolRegistry: [String: ToolEntry]) async throws -> [ToolResult]
    func addServer(endpoint: MCPEndpoint)
    func removeServer(id: String)
}

actor MCPServer {                   // individual MCP server connection
actor MCPStdioTransport {           // stdio protocol transport
actor MCPCallCache {                // LRU cache for tool call results
```

### UI ViewModels

```swift
@MainActor @Observable final class ChatState {
    var messages: [MessageModel]
    var isStreaming: Bool
    var connection: ConnectionState
    func send(message: String)
    func cancelStreaming()
}

@MainActor @Observable final class ChatViewModel {
    // task(.task { ... }) lifecycle + cancellation tracking
}

@MainActor @Observable final class SettingsViewModel {
@MainActor @Observable final class ModelsViewModel {
@MainActor @Observable final class DashboardViewModel {
```

---

## State Machines

### EnginePool States
```
idle ──loadModel──→ model-loading ──loaded──→ active
                                              │
                                     release───┘
                                              │
                                     shutdown──→ shutting-down ──done──→ idle
```

### SchedulerActor Flow
```
submit(request)
  → AdmissionGate.check()
    .accepted → enqueue(priority queue)
    .rejected → fail(error)
  → dispatch() → EnginePool.acquire()
    .complete(result) → emit to AsyncStream
    .interrupt() → cancel streaming
    .fail(error) → emit .stop(reason: .error)
```

### MemoryTracker (Hysteresis)
```
normal ──usage↑──→ warning ──usage↑──→ critical ──usage↑──→ OOM
   ▲              │           │             │           │
   └────usage↓────┘           └────usage↓────┘           └────usage↓────┘
   (hysteresis: each tier drops to next-lower before recovering)
```

### OOMGuard Downgrade Chain
```
original-quant → 4bit → 8bit → CPU-fallback → hard-refuse
```

---

## Key Conventions

| Pattern | Detail |
|---------|--------|
| **Actor-first** | 33 business actors, no `@MainActor` outside UI layer |
| **@Observable** | All 5 ViewModel state objects migrated from `@StateObject/ObservableObject` |
| **Protocol abstraction** | `BackendProtocol` zero-runtime-cost via Swift traits, not `@unchecked Sendable` |
| **Sendable safety** | `SendableValue` enum (not `@unchecked Sendable`), 11 `@unchecked Sendable` all verified safe |
| **i18n** | 100% `StringKey.l` enum-driven, EN + ZH, zero hardcoded UI strings |
| **Accessibility** | 109 `.accessibilityElement()` modifiers, VoiceOver labels on all interactive elements |
| **Error handling** | 99 `try?`, 93 empty `catch` — all logged via `StructuredLogger` |
| **Logging** | Swift Log (SwiftLog), label-scoped per module |

---

## App Store Compliance Checklist

| Requirement | Status |
|-------------|--------|
| PrivacyInfo.xcprivacy | ✅ 7 data types tracked |
| Entitlements | ✅ Sandbox + network + camera + mic + GPU + download dir |
| Info.plist | ✅ App category, iPad orientation, Apple Events |
| HTTP Server stripped | ✅ `#if appStore` compile guard |
| No public IP binding | ✅ localhost only |
| Permissions declared | ✅ Camera, Microphone (FaceTime/iMessage deferred) |

---

## GitHub / CI

- **Repo:** `github.com/uingei/ocoreai`
- **CI pipeline:** `test → build-gui → release`
- **Build command:** `swift build --traits mlx,gui`
- **Test command:** `swift test` (Swift SDK `Testing` module, no SPM dependency)
- **Current HEAD:** `b5cb84e` (self-adaptation system)
