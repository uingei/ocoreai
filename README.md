# ocoreai — Local-First AI Agent Runtime

**macOS-native LLM inference platform** — Agent loop with tool use, multimodal I/O, and skill system, powered by CoreAI / MLX + Metal. Built with Swift 6.3, Hummingbird 2.25, SwiftUI.

[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://www.swift.org)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue.svg)](https://developer.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

### Quick Start

**macOS 15+ · Apple Silicon · Swift 6.3**

```bash
git clone https://github.com/uingei/ocoreai.git && cd ocoreai
swift build -c release --traits mlx
.build/release/ocoreai
```

Server listens on `127.0.0.1:8080`. Config at `~/.ocoreai/config.yaml`.

---

### What's in here

ocoreai is a **local-first AI agent runtime**:

- **Dual inference backends** — MLX (Metal GPU, default) + CoreAI (Apple Neural Engine, macOS 27+ / M4+). Zero network calls — inference runs on your Mac.
- **Agent loop** — multi-turn tool use: the model reasons, calls registered tools, reads results, and iterates (up to 30 rounds, 180s timeout). Built-in tools for system info, skills, search. Extensible via `ToolRegistry`.
- **Skill system** — modular prompt injection from YAML registry. Skills are loaded at boot and injected into the system prompt pipeline.
- **Multimodal I/O** — camera capture, microphone input, Apple Speech TTS — all native, no external dependencies.
- **Session memory** — SQLite + FTS5 full-text search with LLM-driven session compression (hot/warm/cold tiers).
- **MCP bridge** — connect external MCP servers; their tools auto-register into `ToolRegistry` alongside built-in tools.
- **Scheduler + OOM guard** — priority dispatch (`P0` system → `P4` user), GPU memory budget enforcement, downgrade chain (4-bit → 8-bit → CPU → refuse).
- **SwiftUI dashboard** — live system metrics, model management, settings, chat interface.

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
| `DELETE` | `/v1/models/:model/sampling` | Reset sampling config |
| `POST` | `/v1/models/download` | Download from ModelScope / HuggingFace |
| `POST` | `/v1/multimodal/capture` | Capture camera frame or audio sample |
| `POST` | `/v1/multimodal/speak` | TTS output |
| `GET`  | `/sessions` | List sessions |
| `POST` | `/mcp` | MCP JSON-RPC endpoint |
| `GET`  | `/health` | Health check |
| `GET`  | `/metrics` | Prometheus metrics (text format) |

---

### Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                        ocoreai                               │
│                                                              │
│  ┌──────────┐  ┌───────────┐  ┌──────────┐  ┌───────────┐  │
│  │  Router  │→ │ Handler   │→ │ Scheduler│→ │  Engine   │  │
│  │(HB 2.25) │  │  (SSE)    │  │(Actor)   │  │(MLX/CoreAI)│  │
│  └──────────┘  └───────────┘  └──────────┘  └─────┬─────┘  │
│                                         ┌─────────┘        │
│  ┌───────────┐  ┌──────────┐  ┌────────┐  │               │
│  │ Config    │  │ SQLite   │  │  MCP   │  │               │
│  │(YAML+hw)  │  │(FTS5)    │  │(JSON-RPC)│              │
│  └───────────┘  └──────────┘  └────────┘                 │
│  ┌───────────┐  ┌──────────┐  ┌────────┐                 │
│  │ MemTrack  │  │ Security │  │ Skills │                 │
│  │+OOMGuard  │  │(Audit)   │  │(Reg)   │                 │
│  └───────────┘  └──────────┘  └────────┘                 │
│  ┌───────────┐  ┌──────────┐                             │
│  │ ToolReg   │  │ Multimodal│                            │
│  │(Agent    │  │(CAM+MIC+ │                            │
│  │  Loop)   │  │ TTS)      │                            │
│  └───────────┘  └──────────┘                             │
└──────────────────────────────────────────────────────────────┘
```

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
| **Scheduler** | `Scheduler/` | Priority dispatch, memory tracking, OOM guard |
| **Engine** | `Engine/` | MLX/CoreAI inference bridge, session pool, engine lifecycle |
| **Agents** | `Agents/` | Agent loop — multi-turn tool calling, reasoning → action cycle |
| **Tool Registry** | `Tools/` | Actor-isolated tool registration, dispatch, loop detection, audit trail |
| **Skills** | `Skills/` | Skill registry, loader, system prompt builder |
| **SQLite** | `SQLite/` | Session storage + FTS5 full-text search + memory events |
| **Config** | `Config/` | YAML config with hardware auto-detection |
| **MCP** | `MCP/` | JSON-RPC 2.0 tool server via stdio transport |
| **Multimodal** | `Multimodal/` | Camera capture, audio I/O, TTS (Apple Speech) |
| **Security** | `Security/` | Keychain store, structured logger, audit trail |
| **Metrics** | `Metrics/` | Prometheus metrics collection and export |

---

### Status

| Component | Status |
|-----------|--------|
| MLX Metal inference | ✅ |
| CoreAI backend (macOS 27+) | ✅ |
| SSE streaming + non-stream | ✅ |
| OpenAI + Anthropic compatible API | ✅ |
| Agent loop with tool use | ✅ |
| Tool Registry (actor-isolated) | ✅ |
| SQLite session persistence + FTS5 | ✅ |
| Skill system + prompt builder | ✅ |
| MCP bridge | ✅ |
| Multimodal (camera/audio/TTS) | ✅ |
| SwiftUI dashboard UI | ✅ |
| Self-adaptation (EMA health) | ✅ |

---

### License

MIT — Copyright © 2026 uingei@163.com
