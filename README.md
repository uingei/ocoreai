# ocoreai — Reliable Execution Layer for Local Agents

**macOS/iOS agent execution layer** — Dual-channel on-device inference (MLX Metal GPU + CoreAI), prefix caching, KV cache quantization, speculative decoding (MTP + drafter), agent loop with tool use, skill system, session memory, persistent-perception, and multimodal I/O, all in one binary. Built with Swift 6.2, Hummingbird 2.25, SwiftUI.

[![swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://www.swift.org)
[![macOS 14+ / iOS 17+](https://img.shields.io/badge/macOS%2014%20%7C%20iOS%2017-blue.svg)](https://www.apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/uingei/ocoreai/actions/workflows/ci.yml/badge.svg)](https://github.com/uingei/ocoreai/actions/workflows/ci.yml)

---

### Quick Start

**macOS 14+ · iOS 17+ · Apple Silicon · Swift 6.2 · Pure SwiftPM**

```bash
git clone https://github.com/uingei/ocoreai.git && cd ocoreai
swift build -c release
swift run
```

Direct SwiftPM build, no `.xcodeproj` (the test gate runs through the SPM `ocoreai.xcworkspace` → `xcodebuild` → `xctest`).
Server listens on `127.0.0.1:8080`. Config at `~/.ocoreai/config.yaml`.

> ⚠️ **Localhost-only** — The HTTP API binds to `127.0.0.1` by default. **Auth is off unless** the `OCOREAI_API_KEYS` env var is set; **no TLS**. Built-in token-bucket rate limiting is on (200 req/s global).

> 🛠️ **Dev release** — This is a development build. Production use requires additional hardening (see Security section below).

---

### What's in here

ocoreai unifies inference engine, agent orchestration, and persistence in one process:

Dual inference backends — MLX (Metal GPU, `MLXLanguageModel` + `ChatSession` pipeline) + CoreAI (CoreAI*.swift ×8, StateHandler*.swift ×3, KVCache+CoreAI, TensorStorage+CoreAI, MPSGraphSamplers, TokenizersMLXTokenizerAdapter):
- **Adaptive hardware routing** — Real-time HardwareRouter dispatches requests to GPU / ANE / CPU based on thermal pressure, memory headroom, and GPU utilization. AdmissionGate enforces budget admission (admit/reject + channel suggestion, with 15% abort margin reservation). Live channel badge in ChatView streaming indicator + Dashboard health bar; thermal-pressure toast on channel shifts (EN/ZH i18n).
- **Wired Memory GPU isolation** — hardware-level GPU memory bounds prevent OOM during inference.
- **Thinking budget** — Adaptive token budget allocation driven by ComplexityAnalyzer scoring (length, intent, history dimensions) on Bridge Path. Fast Path (desktop GUI) has ThinkingBudget calibration loop wired but with simplified complexity input (constant 0.5 — no upstream ComplexityAnalyzer).
- **Agent loop** — multi-turn tool use: the model reasons, calls registered tools, reads results, and iterates (bounded by the inference timeout, 180s default). Built-in tools for system info, skills, and search. Extensible via `ToolRegistry`.
- **Skill system** — Modular skill registry loaded at boot, bidirectional links to system prompt pipeline.
- **Session memory** — SQLite + FTS5 full-text search with LLM-driven session compression (hot/warm/cold tiers). Memory events for cross-session fact recall. Semantic memory (vector/embedding search) **on by default** (`autoEmbed: true`, LFM2.5-Embedding-350M-4bit, 1024-d vectors, 500/session LIFO eviction).
- **MCP bridge** — connect external MCP servers via stdio transport; HTTP endpoint available. Desktop UI has MCP section in SystemView.
- **Scheduler + OOM guard** — priority dispatch (`P0` interrupt → `P3` background), GPU memory budget enforcement, downgrade chain (8-bit → 4-bit → refuse — no CPU tier on UMA).
- **KV cache quantization** — Enabled by default (turbo4 scheme, 4-bit INT4, activates after 256 tokens). Backed by `GenerateParameters.kvBits` / `kvScheme` / `quantizedKVStart` in upstream MLXLMCommon.
- **Guided generation** — Grammar-constrained output via `MLXGuidedGeneration` (xgrammar/JSON schema), with DiagnosticSink observability and dynamic `CompletionReserve.estimate` structural reserve calculations. Auto-enabled when tool calling or explicit grammar schema is set. Multimodal messages bypass grammar constraints.
- **macOS 27 FM path** — Native `MLXLanguageModel` → `LanguageModelSession` + `MLXFoundationModels` on macOS 27 with tool calling via `FMToolProxy` bridge, reasoning via `ContextOptions`, and transcript-driven streaming. Falls back to ChatSession pipeline on earlier macOS.
- **Speculative decoding** — Gemma drafter models with per-model awareness (12B/26B/31B), MTP support with model-id isolation; KVCacheRuntime (turboQuant/affine) via MLXBridge. CoreAI grammar wired (hybrid xgrammar path via `TokenizersMLXTokenizerAdapter`); pipelined-variant grammar tracks coreai-models #146/#170. Agent loop owned by `DirectInferenceClient` + `ChatHandler`. See `CHANGELOG.md` + upstream audit report.
- **SessionPool** — Prefix-level prompt cache reuse via message divergence tracking; HardwareRouter pressure events trigger aggressive eviction; `loadPromptCacheSnapshot` restores LM state alongside KV cache for correct position anchoring.
- **Persistent perception** — PerceptionEngine (in `Multimodal/`): full 7-channel scheduler (`camera / screen / audio / network / environment / system / speaker` — `PerceptionContext.swift:14-30`; `environment` covers filesystem + internet RSS) with adaptive sampling, RingBuffer + TTL, inference-aware lock-free snapshot, P-S1/P-S2 perception context injection in tool dispatch loops, cross-platform gates (screen macOS-only). **Off by default** — per-channel toggles in Settings must be enabled (camera/screen/speaker also need OS permissions).
- **AIModelCache** — native CoreAI compiled model artifact caching (macOS 27 SDK).
- **Config system** — YAML config with file watcher (poll-based). Hardware auto-detection for memory budget.
- **Multimodal I/O** — camera capture, screen capture, microphone input, Vision OCR, 16kHz Apple Speech STT, i18n TTS — all native. Camera/screen toggles are off by default; STT requires microphone permission.
- **i18n** — StringKey localization framework complete; English and Chinese (zh-Hans) shipped. Six locales defined (en, zh-Hans, ja, ko, fr, es); ja/ko/fr/es not yet translated into `.strings` files.

**Direction** — first product: a **Coding/Computer Agent** that reliably completes multi-step engineering tasks on-device (**Execute** → **Verify** → **Recover**). Inference stays upstream (MLX / CoreAI); ocoreai is the reliable execution layer above it — follow upstream, don't compete.

---

### API Endpoints

| Method | Endpoint | Purpose |
|--------|---------|---------|
| `POST` | `/v1/chat/completions` | OpenAI chat (stream + non-stream, tool calling) |
| `POST` | `/v1/messages` | Anthropic messages + tool use |
| `POST` | `/v1/count-tokens` | Token count utility |
| `GET`  | `/v1/models` | Model registry |
| `GET`  | `/v1/models/:model/sampling` | Get sampling config |
| `PATCH` | `/v1/models/:model/sampling` | Hot-swap sampling config |
| `DELETE` | `/v1/models/:model/sampling` | Reset single model sampling |
| `DELETE` | `/v1/models/sampling` | Reset all model sampling |
| `POST` | `/v1/models/download` | Download from ModelScope / HuggingFace |
| `POST` | `/v1/multimodal/capture` | Capture camera frame or audio sample |
| `POST` | `/v1/multimodal/speak` | TTS output |
| `POST` | `/v1/multimodal/status` | Multimodal pipeline status |
| `GET`  | `/sessions` | List sessions |
| `GET`  | `/sessions/:id/memory` | Get session memory events |
| `GET`  | `/sessions/search` | Full-text search sessions |
| `POST` | `/mcp` | MCP JSON-RPC endpoint |
| `GET`  | `/health` | Health check |
| `GET`  | `/metrics` | Prometheus metrics (text format) |

---

### Architecture

Unified architecture — inference, agent, and memory in one process:

```
┌─────────────────────────────────────────────────────────────┐
│                        ocoreai                                │
│                                                             │
│  Gateway                                                      │
│  ┌────────────────┐  ┌────────┐                              │
│  │ HTTP (HB)      │  │ GUI    │                              │
│  │ :8080 API      │  │ SwiftUI│                              │
│  └────────┬───────┘  └───┬────┘                              │
│           │              │                                   │
│  Control Plane                                                   │
│  ┌──────────┴────┐  ┌──────────┐  ┌──────────┐             │
│  │ Scheduler     │  │ Agent    │  │ Skill    │             │
│  │ P0→P3 dispatch│  │ Loop     │  │ Registry │             │
│  │ OOMGuard      │  │ +ToolReg │  │          │             │
│  │ ConfigWatch   │  │          │  │          │             │
│  └──────────┬────┘  └────┬─────┘  └──────────┘             │
│             │            │                                  │
│  Routing Layer                                                    │
│  ┌──────────┴────┐  ┌──────────┐                              │
│  │ HardwareRouter│  │ Admission│                              │
│  │ GPU/ANE/CPU   │  │ Gate     │ admit/reject+channel suggest │
│  └──────────┬────┘  └──────────┘                              │
│             │                                                 │
│  Inference Engine                                                │
│  ┌──────────┴────────────────┬───────┐                      │
│  │         EnginePool (actor) │          │                      │
│  │  ┌─────────────┐  ┌──────┐ │        │                      │
│  │  │ MLX GPU     │  │CoreAI│ │        │                      │
│  │  │ (Metal)     │  │ ANE  │ │        │                      │
│  │  └─────────────┘  └──────┘ │        │                      │
│  │  SessionPool · WiredMem · Spec · ThinkingBudget · OCR │     │
│  └─────────────────────────────┘                    │           │
│                                                             │
│  Persistence                                                 │
│  ┌──────────────┐  ┌──────────┐  ┌──────────┐              │
│  │ SQLite + FTS5│  │ Security │  │ MCP      │              │
│  │ Sessions     │  │ (Audit)  │  │ Bridge   │              │
│  └──────────────┘  └──────────┘  └──────────┘              │
└─────────────────────────────────────────────────────────────┘
```

**One process, no boundary.** The scheduler feeds the inference engine directly — no localhost hop, no IPC serialization, no context loss between control plane and GPU.

Memory budget auto-detected from `sysctl hw.memsize`; default guard tier is `balanced` = 55% of physical RAM (tiers: safe 40% / balanced 55% / aggressive 75%, custom 20–85%, floor 4 GB). OOMGuard enforces a downgrade chain with no disk I/O — the correct approach for Apple Silicon UMA.

---

### Configuration

Create `~/.ocoreai/config.yaml`:

```yaml
server:
  port: 8080
  host: 127.0.0.1

backend:
  preference: ["mlx"]        # or ["coreai", "mlx"] — first available wins
  wiredMemory:
    policy: "max"            # max | budget | fixed

models:
  default:
    enabled: true
    modelId: "mlx-community/gemma-4-e2b-it-4bit"
    source: modelscope       # "huggingface" forces the HF path; any other value → default hub (modelscope)

memory:
  enabled: true              # session memory (SQLite FTS5 + LLM compression)
```

> **Auth** is not a YAML key: set the `OCOREAI_API_KEYS` env var (comma-separated) to enable it; empty = unauthenticated.

Supported backends: `coreai` (macOS 27+ SDK, requires `#available` runtime check) and `mlx` (Metal). Default `backend.preference` order is `["coreai", "mlx"]` — first available backend wins (override in `config.yaml`).

---

### Modules

| Module | Path | What It Does |
|--------|------|-------------|
| **Router** | `Router/` | Hummingbird HTTP router, endpoint dispatch |
| **Handlers** | `Handlers/` | Chat completion, SSE streaming, model download, multimodal |
| **Scheduler** | `Scheduler/` | Priority dispatch, memory tracking, OOM guard, HardwareRouter, AdmissionGate |
| **Engine** | `Engine/` | MLX/CoreAI inference bridge, dual-channel FM/ChatSession pipeline, FMToolProxy bridge, session pool, engine lifecycle, VLM pipeline |
| **Agents** | `Agents/` | Agent loop — multi-turn tool calling, reasoning → action cycle |
| **Tool Registry** | `Tools/` | Actor-isolated tool registration, dispatch, loop detection, audit trail |
| **Skills** | `Skills/` | Skill registry, loader, system prompt builder |
| **SQLite** | `SQLite/` | Session storage + FTS5 full-text search + memory events |
| **Config** | `Config/` | YAML config with hardware auto-detection |
| **MCP** | `MCP/` | JSON-RPC 2.0 tool server via stdio transport |
| **Multimodal** | `Multimodal/` | Camera, screen, audio I/O, TTS (Apple Speech), Vision OCR |
| **Security** | `Security/` | ContentGuard, StructuredLogger, audit trail, global crash handler, intent/natural-language classifiers, self-correction pipeline |
| **Reasoning** | `Reasoning/` | ComplexityAnalyzer, ThinkingBudget (adaptive reasoning depth) |
| **Profiling** | `Profiling/` | TimingHooks (latency/TTFB) |
| **Metrics** | `Metrics/` | Prometheus metrics collection and export |
| **Locale** | `Localization/` | i18n (en, zh-Hans shipped; ja, ko, fr, es defined) |

---

### Security

- **Network** — Binds `127.0.0.1` only. No external address exposure.
- **Auth** — env var `OCOREAI_API_KEYS` (comma-separated) enables it; `OCOREAI_ADMIN_KEYS` gates PATCH/DELETE. Empty/absent = auth off. Not a YAML key.
- **Rate limiting** — Token-bucket rate limiter with configurable burst/window.
- **ContentGuard** — 3-stage input/output filtering for sensitive content.
- **StructuredLogger** — Structured audit trail, log file rotation.
- **Global crash handler** — On uncaught exception or POSIX signal (segv/abort/bus), writes structured crash log to `~/Library/Application Support/ocoreai/logs/`, then exits.
- **Concurrency** — Swift 6 strict concurrency, actor isolation on scheduler/tool registry/inference engine. `@unchecked Sendable` declarations carry concurrency justification comments.

---

### Status

> 📋 **Code-only status** — All entries below reflect **static code audit** results (grep/compile/availability-guard analysis). Green checkmarks mean "implemented in source code" — they do **not** guarantee runtime stability or end-to-end verified behavior.

| Component | Status |
|-----------|--------|
| MLX Metal inference | ✅ |
| CoreAI inference (dynamic KV cache, prefix caching) | ✅ Three variants wired — sequential, staticShape, pipelined (c4c0a43); auto-detect falls back to sequential, explicit override of unimplemented variants still throws. Grammar constrained decoding on sequential (b69b934), pipelined grammar tracks coreai-models #146/#170 |
| FM language model + tool bridge (macOS 27) | ✅ Code: `MLXLanguageModel` → `LanguageModelSession` → `streamResponse`; FMToolProxy bridges `ToolRegistry` → `FoundationModels.Tool`. Falls back to ChatSession on macOS < 27 |
| KV cache quantization (turbo4/INT8) | ✅ |
| VLM multimodal inference | ✅ |
| Wired Memory GPU isolation | ✅ |
| HardwareRouter (adaptive GPU/ANE/CPU) | ✅ |
| AdmissionGate (budget admission) | ✅ |
| Engine lifecycle state machine + circuit breaker | ✅ |
| ThinkingBudget (adaptive reasoning depth) | ⚠️ Bridge Path: full ComplexityAnalyzer. Fast Path: calibration loop wired with simplified complexity input |
| Speculative decoding (traditional drafter mode) | ✅ |
| Speculative decoding (MTP mode) | ✅ Wired — `createSpeculativeConfig()` returns nil by design; MTP uses its own inference path via `generate(mtpDrafter:, blockSize:)` |
| SSE streaming + non-stream | ✅ |
| OpenAI + Anthropic compatible API | ✅ |
| Agent loop with tool use | ✅ |
| Tool Registry (actor-isolated) | ✅ |
| SQLite session persistence + FTS5 | ✅ |
| Skill system + prompt builder | ✅ |
| MCP bridge | ✅ Code: stdio transport + HTTP JSON-RPC + SystemView desktop |
| Multimodal I/O (camera/screen/OCR/STT) | ⚠️ Wired; camera/screen off by default, STT requires mic permission |
| TTS (speech output) | ⚠️ Wired; lazy-triggered via `speakerEnabled` toggle (off by default) |
| Self Correction Pipeline | ⚠️ Bridge Path only — requires explicit `selfCorrection: true`; no UI toggle |
| i18n | ⚠️ Framework complete; en + zh-Hans shipped, 5 locales defined but untranslated |
| SwiftUI dashboard UI | ✅ Live channel badge (GPU/ANE/CPU) in health bar + ChatView; thermal-pressure toast on channel shifts; Settings capability pills (MLX/CoreAI) with proper runtime gating |
| Self-adaptation (EMA health) | ✅ |
| Profiling (TimingHooks) | ✅ |

---

### Build Info

- Swift 6.2 · SwiftUI · Hummingbird 2.25
- macOS 14+ / iOS 17+ · Apple Silicon · pure SwiftPM
- Quality gate: `xcodebuild build-for-testing` → `xcrun xctest` (CI authoritative = macos-26); test counts tracked in CI, not pinned here
- Build: 0 errors (5 known source warnings remain — see `make test-ci` output)
- Development: `uingei` + AI assistance (Hermes Agent / `qwen3.8:27b-mtp`). All changes are in git — history is the source of authorship.

---

### License

MIT — Copyright © 2026 uingei@163.com
