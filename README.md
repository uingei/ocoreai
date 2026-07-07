# ocoreai — Self-Contained AI Agent OS

**macOS-native AI agent platform** — Dual-channel inference (MLX GPU + CoreAI ANE), adaptive hardware routing, agent loop with tool use, skill system, session memory, and multimodal I/O, all in one binary. Built with Swift 6.3, Hummingbird 2.25, SwiftUI.

[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://www.swift.org)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue.svg)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Tests: 374](https://img.shields.io/badge/Tests-374%2F374-brightgreen)](Tests/)

---

### Quick Start

**macOS 15+ · Apple Silicon · Swift 6.3**

```bash
git clone https://github.com/uingei/ocoreai.git && cd ocoreai
swift build -c release
swift run
```

Build the Xcode project and run, or invoke via `swift run`.
Server listens on `127.0.0.1:8080`. Config at `~/.ocoreai/config.yaml`.

> ⚠️ **Localhost-only** — The HTTP API binds to `127.0.0.1` by default. It has no auth, rate limiting, or TLS. Do not expose to external networks.

> 🛠️ **Dev release** — This is a development build. Production use requires additional hardening (see Security section below).

---

### What's in here

ocoreai unifies inference engine, agent orchestration, and persistence in one process:

- **Dual inference backends** — MLX (Metal GPU, default) + CoreAI (Apple Neural Engine, macOS 27+ / M4+, currently stub pending SDK). Zero network calls — inference runs on your Mac.
- **Adaptive hardware routing** — Real-time HardwareRouter dispatches requests to GPU / ANE / CPU based on thermal pressure, memory headroom, and GPU utilization. AdmissionGate enforces a 3-tier admission policy (allow → ANE-only → reject) with configurable abort margin.
- **Wired Memory GPU isolation** — hardware-level GPU memory bounds prevent OOM during inference.
- **Thinking budget** — Adaptive token budget allocation driven by ComplexityAnalyzer scoring (length, intent, history dimensions). Simple queries skip reasoning scaffolding entirely.
- **Agent loop** — multi-turn tool use: the model reasons, calls registered tools, reads results, and iterates (up to 30 rounds, 180s timeout). Built-in tools for system info, skills, and search. Extensible via `ToolRegistry`.
- **Skill system** — YAML registry of modular prompt templates. Loaded at boot, injected into the system prompt pipeline.
- **Session memory** — SQLite + FTS5 full-text search with LLM-driven session compression (hot/warm/cold tiers). Memory events for cross-session fact recall.
- **MCP bridge** — connect external MCP servers; available via HTTP endpoint and ToolRegistry dispatcher.
- **Scheduler + OOM guard** — priority dispatch (`P0` system → `P4` user), GPU memory budget enforcement, downgrade chain (4-bit → 8-bit → CPU → refuse).
- **Config system** — YAML config with file watcher (poll-based). Hardware auto-detection for memory budget.
- **Multimodal I/O** — camera capture, screen capture, microphone input, Vision OCR, 16kHz Apple Speech STT, i18n TTS with multi-voice support — all native, no external dependencies.
- **VLM multimodal inference** — Vision-language model auto-detection, image input via `preprocessor_config.json`, dataURL→CIImage path.
- **Engine lifecycle** — 6-state machine (idle → starting → ready/degraded → stopping → idle) with circuit breaker (3 failures → 60s cooldown) and port conflict detection.
- **i18n** — 6-language localization (en, zh, ja, ko, fr, de).
- **SwiftUI dashboard** — live system metrics, model management, settings, chat interface.
- **Reasoning** — ComplexityAnalyzer + ThinkingBudget for adaptive reasoning depth.
- **Profiling** — ErrorContext (structured error capture) and TimingHooks (per-request latency, throughput, TTFB).

Evolving toward a full **Agent OS** — a device-level runtime where the LLM controls tools, apps, and the desktop through a unified tool interface.

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
│  │ P0→P4 dispatch│  │ Loop     │  │ Registry │             │
│  │ OOMGuard      │  │ +ToolReg │  │          │             │
│  │ ConfigWatch   │  │          │  │          │             │
│  └──────────┬────┘  └────┬─────┘  └──────────┘             │
│             │            │                                  │
│  Routing Layer                                                    │
│  ┌──────────┴────┐  ┌──────────┐                              │
│  │ HardwareRouter│  │ Admission│                              │
│  │ GPU/ANE/CPU   │  │ Gate     │ 3-tier: allow→ANE-only→reject│
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

Memory budget auto-detected via `sysctl hw.memsize` (70% of physical RAM). OOMGuard enforces a downgrade chain with no disk I/O — the correct approach for Apple Silicon UMA.

---

### Configuration

Create `~/.ocoreai/config.yaml`:

```yaml
server:
  port: 8080
  host: 127.0.0.1

backend:
  type: mlx

auth:
  api_key: "your-secret-key"

models:
  default:
    modelScope: "qwen/qwen3.5-4b-4bit"
    hub: modelscope

memory:
  budget_gb: 0      # 0 = auto-detect (70% RAM)
```

Supported backends: `coreai` (macOS 27+, M4+, compiled via `--traits coreai`), `mlx` (default, Metal).

---

### Modules

| Module | Path | What It Does |
|--------|------|-------------|
| **Router** | `Router/` | Hummingbird HTTP router, endpoint dispatch |
| **Handlers** | `Handlers/` | Chat completion, SSE streaming, model download, multimodal |
| **Scheduler** | `Scheduler/` | Priority dispatch, memory tracking, OOM guard, HardwareRouter, AdmissionGate |
| **Engine** | `Engine/` | MLX/CoreAI inference bridge, session pool, engine lifecycle, VLM pipeline |
| **Agents** | `Agents/` | Agent loop — multi-turn tool calling, reasoning → action cycle |
| **Tool Registry** | `Tools/` | Actor-isolated tool registration, dispatch, loop detection, audit trail |
| **Skills** | `Skills/` | Skill registry, loader, system prompt builder |
| **SQLite** | `SQLite/` | Session storage + FTS5 full-text search + memory events |
| **Config** | `Config/` | YAML config with hardware auto-detection |
| **MCP** | `MCP/` | JSON-RPC 2.0 tool server via stdio transport |
| **Multimodal** | `Multimodal/` | Camera, screen, audio I/O, TTS (Apple Speech), Vision OCR |
| **Security** | `Security/` | Keychain store, structured logger, audit trail, ContentGuard, AdaptiveThreshold |
| **Reasoning** | `Reasoning/` | ComplexityAnalyzer, ThinkingBudget (adaptive reasoning depth) |
| **Profiling** | `Profiling/` | ErrorContext (structured error capture), TimingHooks (latency/TTFB) |
| **Metrics** | `Metrics/` | Prometheus metrics collection and export |
| **Locale** | `Localization/` | 6-language i18n (en, zh, ja, ko, fr, de) |

---

### Security

- **Network** — Binds `127.0.0.1` only. No external address exposure.
- **Auth** — Optional `auth.api_key` in config. Disable with `auth.enabled: false`.
- **Rate limiting** — Token-bucket rate limiter with configurable burst/window.
- **ContentGuard** — 3-stage input/output filtering for sensitive content.
- **AdaptiveThreshold** — EMA-based health monitoring with dynamic threshold adjustment.
- **StructuredLogger** — Structured audit trail, log file rotation, macOS Keychain integration.
- **Global crash handler** — On uncaught exception or POSIX signal (segv/abort/bus), writes structured crash log to `~/Library/Application Support/ocoreai/logs/`, then exits.
- **Concurrent safety** — Swift 6 strict concurrency, actor isolation on scheduler/tool registry/inference engine. All `@unchecked Sendable` justified with concurrency comments (10/10 sites).

---

### Status

| Component | Status |
|-----------|--------|
| MLX Metal inference | ✅ |
| VLM multimodal inference | ✅ |
| CoreAI ANE backend (macOS 27+) | ⚠️ Stub (waiting for SDK) |
| Wired Memory GPU isolation | ✅ |
| HardwareRouter (adaptive GPU/ANE/CPU) | ✅ |
| AdmissionGate (3-tier) | ✅ |
| Engine lifecycle state machine + circuit breaker | ✅ |
| ThinkingBudget (adaptive reasoning depth) | ✅ |
| Speculative decoding (MTP + traditional) | ✅ |
| SSE streaming + non-stream | ✅ |
| OpenAI + Anthropic compatible API | ✅ |
| Agent loop with tool use | ✅ |
| Tool Registry (actor-isolated) | ✅ |
| SQLite session persistence + FTS5 | ✅ |
| Skill system + prompt builder | ✅ |
| MCP bridge | ✅ |
| Multimodal (camera/screen/audio/OCR/STT/TTS) | ✅ |
| 6-language i18n | ✅ |
| SwiftUI dashboard UI | ✅ |
| Self-adaptation (EMA health) | ✅ |
| Profiling (ErrorContext + TimingHooks) | ✅ |

---

### Build Info

- Swift 6.3 · iOS SwiftUI · Hummingbird 2.25
- 124 Swift source files, ~32,000 LOC
- macOS 15+ · Apple Silicon only
- Tests: 374/374 passed in 72 suites (1.1s)
- Build: 0 warnings, 0 errors

---

### License

MIT — Copyright © 2026 uingei@163.com
