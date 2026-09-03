# ocoreai — Reliable Execution Layer for Local Agents

**macOS/iOS execution layer for local agents** — one Swift 6.2 binary: on-device inference (MLX Metal + CoreAI, upstream-derived), agent tool loop, session memory, Apple-native multimodal I/O, and an OpenAI/Anthropic-compatible HTTP gateway — single process, no IPC.

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

```bash
curl -s http://127.0.0.1:8080/health
# { "status": "ok", "timestamp": 1714800000, "engineSummary": { "loadedModels": 0, "activeSessions": 0, ... } }
```

Direct SwiftPM build, no `.xcodeproj` (the test gate runs through the SPM `ocoreai.xcworkspace` → `xcodebuild` → `xctest`).
Server listens on `127.0.0.1:8080`. Config at `~/.ocoreai/config.yaml`.

> ⚠️ **Localhost-only** — The HTTP API binds to `127.0.0.1` by default. **Auth is off unless** the `OCOREAI_API_KEYS` env var is set; **no TLS**. Built-in token-bucket rate limiting is on (200 req/s global).

> 🛠️ **Dev release** — This is a development build. Production use requires additional hardening (see Security section below).

---

### What's in here

One process: inference (MLX Metal + CoreAI, upstream-derived) + agent loop (tool calling, skills, session memory via SQLite/FTS5) + HTTP gateway (OpenAI/Anthropic-compatible endpoints, table below) + native multimodal I/O (camera/screen/audio/OCR/STT/TTS, all Apple-native) + MCP bridge (stdio).

Capability detail lives where it's kept current: `CHANGELOG.md` (per-feature, with commit refs) and the upstream repos it tracks — [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm), [coreai-models](https://github.com/apple/coreai-models), [codex](https://github.com/openai/codex).

Known boundaries (as of this commit, not aspirations):

- **Perception & TTS are off by default** — per-channel toggles in Settings; camera/screen/speaker also need OS permissions.
- **TTS/STT require microphone permission**; screen capture is macOS-only.
- **i18n**: en + zh-Hans shipped; ja/ko/fr/es defined but untranslated.
- **CI**: the macOS-26 leg is the authoritative gate; the xcode-27 leg currently fails in an upstream mlx-swift-lm pin (not ocoreai code).
- **Status rows that were ✅ by code audit do not guarantee runtime behavior** — treat as "implemented in source", verified where a test exists.

**Direction** — first product: a **Coding/Computer Agent** that reliably completes multi-step engineering tasks on-device (**Execute** → **Verify** → **Recover**). Inference stays upstream (MLX / CoreAI); ocoreai is the reliable execution layer above it — follow upstream, don't compete.

---

### API Endpoints

| Method | Endpoint | Purpose |
|------|------|------|
| `POST` | `/v1/chat/completions` | OpenAI chat (streaming + non-streaming, tool calls) |
| `POST` | `/v1/completions` | OpenAI legacy completions endpoint (prompt in) |
| `POST` | `/v1` | Auto-route: dispatches by body key (`prompt`→completions, else chat) |
| `POST` | `/v1/messages` | Anthropic messages + tool use |
| `POST` | `/v1/count-tokens` | Token count utility |
| `GET`  | `/v1/models` | Model registry |
| `GET`  | `/v1/models/:model/sampling` | Get sampling config |
| `PATCH` | `/v1/models/:model/sampling` | Hot-swap sampling config |
| `DELETE` | `/v1/models/:model/sampling` | Reset single model sampling |
| `DELETE` | `/v1/models/sampling` | Reset all sampling |
| `POST` | `/v1/models/download` | Download from ModelScope / HuggingFace |
| `POST` | `/v1/models/train` | LLM training |
| `POST` | `/v1/models/evaluate` | LLM evaluation |
| `GET`  | `/v1/stats` | Ops statistics (requests/tokens/duration/TTFB) |
| `POST` | `/v1/multimodal/capture` | Capture camera frame or audio sample |
| `POST` | `/v1/multimodal/speak` | TTS output |
| `POST` | `/v1/multimodal/status` | Multimodal pipeline status |
| `GET`  | `/sessions` | List sessions |
| `GET`  | `/sessions/:id/memory` | Get session memory events |
| `DELETE` | `/sessions/:id` | Delete session |
| `GET`  | `/sessions/search` | Full-text search sessions |
| `GET`  | `/skills` | List registered skills |
| `POST` | `/mcp` | MCP JSON-RPC endpoint |
| `GET`  | `/health` | Liveness check |
| `GET`  | `/ready` | Readiness probe (`ready`/`busy`) |
| `GET`  | `/metrics` | Prometheus metrics (text format) |

> Public (no auth): `/health`, `/ready`, `/v1/models`, `/v1/stats`, `/metrics`. Admin key (`OCOREAI_ADMIN_KEYS`) required for all `PATCH`/`DELETE`.

---

### Architecture

One process, no boundary: gateway (Hummingbird `:8080` + SwiftUI) → control plane (Scheduler `P0`→`P3`, OOMGuard, ConfigWatcher) → routing (HardwareRouter GPU/ANE/CPU, AdmissionGate) → inference (MLX Metal / CoreAI ANE, session pool, spec decoding) → persistence (SQLite + FTS5). The scheduler feeds the engine in-process — no localhost hop, no IPC. Directory layout: see the Modules table below.

---

### Configuration

Create `~/.ocoreai/config.yaml`:

```yaml
server:
  port: 8080
  host: 127.0.0.1

backend:
  preference: ["coreai", "mlx"]   # default order — first available wins
  wiredMemory:
    policy: "max"                  # max | budget | fixed

models:
  default:
    enabled: true
    modelId: "mlx-community/gemma-4-e2b-it-4bit"
    source: modelscope       # "huggingface" forces the HF path; any other value → default hub (modelscope)

memory:
  enabled: true              # session memory (SQLite FTS5 + LLM compression)
```

> **Auth** is not a YAML key: set the `OCOREAI_API_KEYS` env var (comma-separated) to enable it; empty = unauthenticated.

Memory budget auto-detected from `sysctl hw.memsize`; default guard tier is `balanced` = 55% of physical RAM (tiers: safe 40% / balanced 55% / aggressive 75%, custom 20–85%, floor 4 GB). OOMGuard then enforces the downgrade chain 8-bit → 4-bit → refuse (no CPU tier on UMA) — no disk I/O, the correct approach for Apple Silicon UMA.

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

Per-feature status with commit refs lives in `CHANGELOG.md` — a pinned ✅ table here would go stale on every commit. What is stable as of this commit:

- **Authoritative gate**: `make test-ci` (xcodebuild → xctest), CI leg `macos-26` — last full run **1519 tests / 281 suites, all green** (`0db93e6`). The `xcode-27` leg fails in an upstream mlx-swift-lm pin, not ocoreai code.
- **Local builds** compile clean (0 errors; a small number of known source warnings remain — `make test-ci` output).
- **Default-off surfaces** (deliberate, not missing): perception channels, TTS/speaker, self-correction pipeline — see "Known boundaries" above.

### Build Info

- Swift 6.2 · SwiftUI · Hummingbird 2.25
- macOS 14+ / iOS 17+ · Apple Silicon · pure SwiftPM
- No `.xcodeproj` — the test gate runs through the SPM `ocoreai.xcworkspace` → `xcodebuild` → `xctest`

---

### License

MIT — Copyright © 2026 uingei@163.com
