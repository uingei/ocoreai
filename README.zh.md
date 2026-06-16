# ocoreai

> 纯 Swift 原生 LLM 推理服务器 — 苹果芯片上开箱即用的 OpenAI / Anthropic 兼容 API
>
> 默认模型 **Qwen3.5-4B-OptiQ-4bit** | 后端支持 **MLX** 与 **Apple CoreAI**

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![Hummingbird 2.25+](https://img.shields.io/badge/Hummingbird-2.25%2B-blue.svg)](https://github.com/hummingbird-project/hummingbird)
[![MLX](https://img.shields.io/badge/Inference-MLX%20Swift%20LM-purple.svg)](https://github.com/ml-explore/mlx-swift-lm)
[![Platform](https://img.shields.io/badge/Platform-macOS%2015%2B-blue.svg)](https://developer.apple.com/macos)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## 概述

**ocoreai** 是一款完全用 Swift 编写的 LLM 推理服务器，提供开箱即用的 OpenAI 和 Anthropic 兼容 API，支持认证、速率限制、Prometheus 监控指标、KV Cache 会话池和优雅关闭。

### 推理后端状态

| 功能 | 状态 |
|------|------|
| MLX 后端 (macOS 15+) 基于 `mlx-swift-lm` | ✅ 运行中 — 流式输出、工具调用、会话池 |
| CoreAI 后端 (macOS 27+) | ✅ 已实现 — 旧版 macOS 自动降级 |
| 双后端编译支持 | ✅ `#if mlx` / `#if coreai` 编译特性 |
| 会话池 (KV Cache 复用) | ✅ LRU 淘汰 + TTL 过期 + 增量消息路由 |

## 功能特性

- **OpenAI 兼容 API** — `/v1/chat/completions`（流式 + 非流式）、`/v1/models`、`/v1/count-tokens`
- **Anthropic 兼容 API** — `/v1/messages`（流式 + 非流式，完整消息协议）
- **MLX 推理** — 基于 `mlx-swift-lm` 的 Metal 加速生成 (macOS 15+)
- **CoreAI 推理** — macOS 27+ 原生 `import CoreAI`
- **会话池** — 按对话维度跨轮次复用 KV Cache，LRU 淘汰 + TTL 过期
- **认证** — Bearer Token、API Key 请求头、Query 参数降级，管理员 Key 隔离
- **速率限制** — 令牌桶：全局、按模型、按 IP，可配置突发量
- **Prometheus 监控** — `/metrics` 端点，支持计数器、直方图、仪表盘指标
- **运行时参数热切换** — PATCH 采样配置，无需重启
- **优雅关闭** — 30 秒排空超时，超时后强制终止
- **工具调用** — 完整的函数 / AGI 工具调用支持，SSE 流式传输
- **增量消息路由** — 池化会话仅发送新增消息，避免 KV Cache 重复注入

## 快速开始

```bash
# 设置环境变量
export OCOREAI_API_KEYS="your-secret-key"
export OCOREAI_HOST="127.0.0.1"
export OCOREAI_PORT="8000"

# 使用 MLX 后端构建运行 (macOS 15+):
swift build -c release -Xswiftc -D -Xswiftc mlx
.build/release/ocoreai

# 使用 CoreAI 后端构建运行 (macOS 27+):
swift build -c release -Xswiftc -D -Xswiftc coreai
.build/release/ocoreai
```

## API 端点

| 方法 | 路径 | 认证 | 描述 |
|------|------|------|------|
| `GET` | `/health` | ❌ | 健康检查 + 引擎状态概览 |
| `GET` | `/v1/models` | ❌ | 已加载模型列表 |
| `GET` | `/metrics` | ❌ | Prometheus 监控指标 |
| `POST` | `/v1/chat/completions` | ✅ | 聊天补全（流式/非流式） |
| `POST` | `/v1/messages` | ✅ | Anthropic 消息 API（流式/非流式） |
| `POST` | `/v1/count-tokens` | ✅ | Token 计数工具 |
| `GET` | `/v1/models/:model/sampling` | ✅ | 查看采样配置 |
| `PATCH` | `/v1/models/:model/sampling` | 🔑 | 热切换采样配置 |
| `DELETE` | `/v1/models/:model/sampling` | 🔑 | 重置单个模型采样配置 |
| `DELETE` | `/v1/models/sampling` | 🔑 | 重置所有模型采样配置 |

## 配置

| 环境变量 | 默认值 | 描述 |
|----------|--------|------|
| `OCOREAI_API_KEYS` | _(必填)_ | 逗号分隔的 API Key 列表 |
| `OCOREAI_ADMIN_KEYS` | _(可选)_ | 管理员 Key（用于 PATCH/DELETE 操作） |
| `OCOREAI_HOST` | `127.0.0.1` | 监听地址 |
| `OCOREAI_PORT` | `8000` | 监听端口 |
| `HF_TOKEN` | _(可选)_ | HuggingFace 下载凭证 |
| `MODELSCOPE_TOKEN` | _(可选)_ | ModelScope 下载凭证 |

## 架构

```
┌───────────── Hummingbird 2.25+ ──────────────┐
│  AuthMiddleware → RateLimitMiddleware       │
│  ┌─────────────────────────────────────┐    │
│  │  路由 (OCoreAIContext 绑定):          │    │
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
│  推理后端 (编译特性选择):                      │
│  ┌─────────────┐   ┌─────────────┐          │
│  │  MLX (mlx)  │   │  CoreAI     │          │
│  │  Swift LM   │   │  (macOS27+) │          │
│  │  Generate   │   │  Native     │          │
│  └─────────────┘   └─────────────┘          │
├─────────────────────────────────────────────┤
│  Apple MLX Metal / CoreAI System Framework   │
└─────────────────────────────────────────────┘
```

## 条件编译

CoreAI 是 macOS 系统框架 (macOS 27+) — 非 SwiftPM 依赖。
MLX 是 SwiftPM 包 (`mlx-swift-lm`)，支持 macOS 15+。
编译特性控制链接哪个后端：

| 特性 | 效果 |
|------|------|
| `coreai` | 链接 Apple CoreAI (macOS 27+) |
| `mlx` | 链接 MLX via `mlx-swift-lm` (macOS 15+) |

```bash
# macOS 27+ (CoreAI):
swift build -Xswiftc -D -Xswiftc coreai

# macOS 27+ (MLX):
swift build -Xswiftc -D -Xswiftc mlx

# macOS 27+ (双后端):
swift build -Xswiftc -D -Xswiftc coreai -Xswiftc -D -Xswiftc mlx

# CI / macOS 26 (MLX):
swift build -Xswiftc -D -Xswiftc mlx

# 存根模式（无推理，仅类型）:
swift build
```

## 系统要求

- **macOS 15+**（MLX 后端）或 **macOS 27+**（CoreAI 后端）
- **Apple Silicon**（M 系列芯片）
- **Swift 6.2** / 对应 Xcode 版本
- **Hummingbird 2.25+**（固定 `from: "2.25.0"`）
- **依赖版本：** `swift-log` 1.6.0、`swift-atomics` 1.3.0、`mlx-swift-lm`（main 分支）

## 许可证

MIT
