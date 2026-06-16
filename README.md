# ocoreai

> Native Swift LLM inference server — drop-in OpenAI & Anthropic compatible API on Apple Silicon
>
> Powered by **mlx-swift-lm** | Default model: **Qwen3.5-4B-OptiQ-4bit** | Inference via **MLX** or **Apple CoreAI**

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![Hummingbird 2.25+](https://img.shields.io/badge/Hummingbird-2.25%2B-blue.svg)](https://github.com/hummingbird-project/hummingbird)
[![MLX](https://img.shields.io/badge/Inference-MLX%20Swift%20LM-purple.svg)](https://github.com/ml-explore/mlx-swift-lm)
[![Platform](https://img.shields.io/badge/Platform-macOS%2015%2B-blue.svg)](https://developer.apple.com/macos)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Overview

**ocoreai** is an LLM inference server built entirely in Swift. It provides drop-in
OpenAI-compatible and Anthropic-compatible APIs with authentication, rate limiting,
Prometheus metrics, KV-cache session pooling, and graceful shutdown.

### Inference Backend Status

| Feature | Status |
|---------|--------|
| MLX backend (macOS 15+) via `mlx-swift-lm` | ✅ Running — streaming, tool calling, session pool |
| CoreAI backend (macOS 27+) | ✅ Implemented — stub fallback on older macOS |
| Dual-backend build support | ✅ `#if mlx` / `#if coreai` traits |
| Session Pool (KV cache reuse) | ✅ LRU eviction + TTL + delta-only message routing |

## Features

- **OpenAI-Compatible API** — `/v1/chat/completions` (streaming + non-streaming), `/v1/models`, `/v1/count-tokens`
- **Anthropic-Compatible API** — `/v1/messages` (streaming + non-streaming, full message protocol)
- **MLX Inference** — Metal-accelerated generation via `mlx-swift-lm` on macOS 15+
- **CoreAI Inference** — Native `import CoreAI` on macOS 27+
- **Session Pool** — Cross-turn KV cache reuse per conversation with LRU eviction & TTL expiry
- **Authentication** — Bearer token, API-key header, query fallback with admin key separation
- **Rate Limiting** — Token bucket: global, per-model, per-IP with configurable burst
- **Prometheus Metrics** — `/metrics` endpoint with counters, histograms, gauges
- **Runtime Parameter Hot-Swap** — PATCH sampling config without restart
- **Graceful Shutdown** — 30s drain timeout with force-kill on expiry
- **Tool Calling** — Full function/AGI tool call support with SSE streaming
- **Delta Message Routing** — Pooled sessions only send new messages, avoiding KV cache duplication

## Quick Start

```bash
# Set environment
export OCOREAI_API_KEYS="your-secret-key"
export OCOREAI_HOST="127.0.0.1"
export OCOREAI_PORT="8000"

# Build & run with MLX (macOS 15+):
swift build -c release -Xswiftc -D -Xswiftc mlx
.build/release/ocoreai

# Build & run with CoreAI (macOS 27+):
swift build -c release -Xswiftc -D -Xswiftc coreai
.build/release/ocoreai
```

## API Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `GET` | `/health` | ❌ | Health check + engine summary |
| `GET` | `/v1/models` | ❌ | List loaded models |
| `GET` | `/metrics` | ❌ | Prometheus metrics |
| `POST` | `/v1/chat/completions` | ✅ | Chat completion (stream/non-stream) |
| `POST` | `/v1/messages` | ✅ | Anthropic messages (stream/non-stream) |
| `POST` | `/v1/count-tokens` | ✅ | Token count utility |
| `GET` | `/v1/models/:model/sampling` | ✅ | Inspect sampling config |
| `PATCH` | `/v1/models/:model/sampling` | 🔑 | Hot-swap sampling config |
| `DELETE` | `/v1/models/:model/sampling` | 🔑 | Reset single model sampling |
| `DELETE` | `/v1/models/sampling` | 🔑 | Reset ALL model sampling defaults |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `OCOREAI_API_KEYS` | _(required)_ | Comma-separated API keys |
| `OCOREAI_ADMIN_KEYS` | _(optional)_ | Admin keys for PATCH/DELETE |
| `OCOREAI_HOST` | `127.0.0.1` | Bind address |
| `OCOREAI_PORT` | `8000` | Bind port |
| `HF_TOKEN` | _(optional)_ | HuggingFace download token |
| `MODELSCOPE_TOKEN` | _(optional)_ | ModelScope download token |

## Architecture

```
┌───────────── Hummingbird 2.25+ ──────────────┐
│  AuthMiddleware → RateLimitMiddleware       │
│  ┌─────────────────────────────────────┐    │
│  │  Routes (OCoreAIContext-bound):      │    │
│  │  /health, /v1/models, /metrics       │    │
│  │  /v1/chat/completions (OpenAI)       │    │
│  │  /v1/messages (Anthropic)            │    │
│  │  /v1/count-tokens                    │    │
│  │  /v1/models/:model/sampling CRUD     │    │
│  └─────────────────────────────────────┘    │
│  MetricsCountingResponder (trailer)         │
├─────────────────────────────────────────────┤
│  EnginePool (actor) + MLXSessionPool        │
│  ┌─────────────────────────────────────┐    │
│  │  LoadedModel (per-model, actor)     │    │
│  │  TokenizerManager                   │    │
│  │  Runtime Sampling Config Store      │    │
│  │  Session Pool (KV cache reuse)      │    │
│  │  EngineHandle (non-blocking proxy)  │    │
│  └─────────────────────────────────────┘    │
├─────────────────────────────────────────────┤
│  Inference Backends (trait-selected):        │
│  ┌─────────────┐   ┌─────────────┐          │
│  │  MLX (mlx)  │   │  CoreAI     │          │
│  │  Swift LM   │   │  (macOS27+) │          │
│  │  Generate   │   │  Native     │          │
│  └─────────────┘   └─────────────┘          │
├─────────────────────────────────────────────┤
│  Apple MLX Metal / CoreAI System Framework   │
└─────────────────────────────────────────────┘
```

## Conditionally Compiled Features

CoreAI is a macOS system framework (macOS 27+) — not a SwiftPM dependency.
MLX is a SwiftPM package (`mlx-swift-lm`) available on macOS 15+.
Build traits control which backend is linked:

| Trait | Effect |
|-------|--------|
| `coreai` | Link Apple CoreAI (macOS 27+) |
| `mlx` | Link MLX via `mlx-swift-lm` (macOS 15+) |

```bash
# macOS 27+ (CoreAI):
swift build -Xswiftc -D -Xswiftc coreai

# macOS 27+ (MLX):
swift build -Xswiftc -D -Xswiftc mlx

# macOS 27+ (dual):
swift build -Xswiftc -D -Xswiftc coreai -Xswiftc -D -Xswiftc mlx

# CI / macOS 26 (MLX):
swift build -Xswiftc -D -Xswiftc mlx

# Stub (no inference, types only):
swift build
```

## Requirements

- **macOS 15+** (MLX backend) or **macOS 27+** (CoreAI backend)
- **Apple Silicon** (M-series)
- **Swift 6.2** / matching Xcode version
- **Hummingbird 2.25+** (pinned `from: "2.25.0"`)
- **Dependencies:** `swift-log` 1.6.0, `swift-atomics` 1.3.0, `mlx-swift-lm` (main branch)

## License

MIT
