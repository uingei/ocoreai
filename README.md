# ocoreai — Apple Silicon LLM Inference Server

**macOS Native AI Inference Runtime** — OpenAI/Anthropic-compatible LLM inference on Apple Silicon with CoreAI / MLX + Metal, built on Hummingbird 2.25 and Swift 6.3.

[![CI](https://github.com/uingei/ocoreai/actions/workflows/ci.yml/badge.svg)](https://github.com/uingei/ocoreai/actions/workflows/ci.yml)
[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://www.swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

### Installation

**macOS 15+ · Swift 6.3 · Apple Silicon**

```bash
git clone https://github.com/uingei/ocoreai.git && cd ocoreai
swift build -c release --traits mlx
.build/release/ocoreai
```

By default the server listens on `127.0.0.1:8080`. Pass a custom config via `~/.ocoreai.yaml`.

---

### What you type → what happens

```bash
# OpenAI-compatible streaming completion
$ curl http://localhost:8080/v1/chat/completions \
    -H "Authorization: Bearer your-api-key" \
    -d '{"model":"default","stream":true,"messages":[{"role":"user","content":"Hello"}]}'
→ streams token-by-token via SSE

# Anthropic-compatible messages
$ curl http://localhost:8080/v1/messages \
    -H "Authorization: Bearer your-api-key" \
    -d '{"model":"default","max_tokens":100,"messages":[{"role":"user","content":"Write a poem"}]}'
→ Anthropic-compatible JSON response

# List registry with sampling state
$ curl http://localhost:8080/v1/models
→ model list with quantization, backend, and status

# Count tokens without running inference
$ curl http://localhost:8080/v1/count-tokens \
    -d '{"prompt":"Hello world"}'
→ {"prompt_tokens":N}

# Download & register a model from ModelScope or HuggingFace
$ curl -X POST http://localhost:8080/v1/models/download \
    -d '{"modelScope":"qwen/qwen3.5-4b-4bit"}'
→ streams download progress via SSE, then registers model

# Health and metrics
$ curl http://localhost:8080/health
$ curl http://localhost:8080/metrics
```

---

### API Endpoints

| Method | Endpoint | Purpose |
|--------|---------|---------|
| `POST` | `/v1/chat/completions` | OpenAI chat (stream + non-stream, tool calling) |
| `POST` | `/v1/messages` | Anthropic messages + tool use |
| `POST` | `/v1/count-tokens` | Token count utility |
| `GET`  | `/v1/models` | Model registry |
| `GET`  | `/v1/models/:model/sampling` | Get sampling config for a model |
| `DELETE` | `/v1/models/:model/sampling` | Reset sampling config |
| `DELETE` | `/v1/models/sampling` | Reset all sampling configs |
| `POST` | `/v1/models/download` | Download from ModelScope / HuggingFace |
| `GET`  | `/sessions` | List sessions |
| `DELETE` | `/sessions/:id` | Delete session |
| `GET`  | `/sessions/:id/memory` | Query memory events |
| `GET`  | `/sessions/search` | FTS5 full-text search |
| `GET`  | `/skills` | List registered skills |
| `POST` | `/mcp` | MCP JSON-RPC endpoint |
| `GET`  | `/health` | Health check |
| `GET`  | `/metrics` | Prometheus metrics (text format) |

---

### How it works

```
┌─────────────────────────────────────────────────────────────┐
│                        ocoreai Server                       │
│                                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐ │
│  │  Router  │→ │ Handler  │→ │ Scheduler│→ │  Engine  │ │
│  │(HB 2.25) │  │  (SSE)   │  │(Actor)   │  │ (MLX)    │ │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘ │
│                                         ↑               │
│  ┌───────────┐  ┌──────────┐  ┌────────┐  │             │
│  │ Config    │  │ SQLite   │  │  MCP   │  └────────────┘ │
│  │(YAML+hwr) │  │(FTS5)    │  │(JSON-RPC)│               │
│  └───────────┘  └──────────┘  └────────┘                │
│  ┌───────────┐  ┌──────────┐  ┌────────┐                │
│  │ MemTrack  │  │ Security │  │ Skills │                │
│  │+OOMGuard  │  │(Audit)   │  │(Reg)   │                │
│  └───────────┘  └──────────┘  └────────┘                │
└─────────────────────────────────────────────────────────────┘
```

MLX performs inference natively on Metal GPUs. On macOS 15.3+ / M4+, CoreAI is the preferred backend (compiled via `--traits coreai`). Memory budget is auto-detected via `sysctl hw.memsize` (70% of physical RAM). OOMGuard enforces a downgrade chain: `4bit → 8bit → CPU → refuse` — no disk I/O, the correct approach for Apple Silicon UMA.

SchedulerActor dispatches requests by priority (`P0=system` … `P4=user`). MemoryTracker allocates/deallocates per-request GPU memory under the actor mailbox.

---

### Configuration

Create `~/.ocoreai.yaml`:

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

Supported backends: `coreai` (macOS 15.3+, M4+, compiled via `--traits coreai`), `mlx` (default, Metal).

---

### Modules

| Module | Location | What It Does |
|--------|----------|-------------|
| **Router** | `Router/` | Hummingbird HTTP router, endpoint dispatch |
| **Handlers** | `Handlers/` | Chat completion, SSE streaming, model download |
|| **Scheduler** | `Scheduler/` | Priority dispatch, memory tracking, OOM guard |
|| **Engine** | `Engine/` | MLX/CoreAI inference bridge, session pool |
|| **SQLite** | `SQLite/` | Session storage + FTS5 full-text search + memory events |
| **Config** | `Config/` | YAML config with hardware auto-detection |
| **MCP** | `MCP/` | JSON-RPC 2.0 tool server via stdio transport |
| **Security** | `Security/` | Keychain store, structured logger, audit trail |
| **Skills** | `Skills/` | Skill registry, loader, system prompt builder |
| **Tools** | `Tools/` | Model download, tool registration |
| **Middleware** | `Middleware/` | Rate limiting, request filtering |

---

### Status

| Component | Status |
|-----------|--------|
| MLX Metal inference | ✅ |
| SSE streaming + non-stream | ✅ |
| Anthropic-compatible API | ✅ |
| SQLite session persistence | ✅ |
| FTS5 full-text search + memory events | ✅ |
| Skill system + prompt builder | ✅ |
| MCP tool endpoints | ✅ |
| Scheduler: Anthropic + Chat path unified | ✅ |
| Dashboard UI | 🔲 Models/Settings mock |

---

### License

MIT — Copyright © 2026 uingei@163.com
