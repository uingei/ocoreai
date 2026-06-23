# ocoreai — Apple Silicon LLM Inference Server

**macOS 原生 AI 推理运行时** — 基于 CoreAI / MLX + Metal 的 OpenAI/Anthropic 兼容 LLM 推理服务，Hummingbird 2.25 + Swift 6.3 构建。

[![CI](https://github.com/uingei/ocoreai/actions/workflows/ci.yml/badge.svg)](https://github.com/uingei/ocoreai/actions/workflows/ci.yml)
[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://www.swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

### 安装

**macOS 15+ · Swift 6.3 · Apple Silicon**

```bash
git clone https://github.com/uingei/ocoreai.git && cd ocoreai
swift build -c release --traits mlx
.build/release/ocoreai
```

默认监听 `127.0.0.1:8080`。可通过 `~/.ocoreai.yaml` 自定义配置。

---

### 示例

```bash
# OpenAI 兼容流式推理
$ curl http://localhost:8080/v1/chat/completions \
    -H "Authorization: Bearer *** \
    -d '{"model":"default","stream":true,"messages":[{"role":"user","content":"Hello"}]}'
→ SSE 流式返回逐 token 结果

# Anthropic 兼容消息接口
$ curl http://localhost:8080/v1/messages \
    -H "Authorization: Bearer *** \
    -d '{"model":"default","max_tokens":100,"messages":[{"role":"user","content":"Write a poem"}]}'
→ Anthropic 格式 JSON 响应

# 查看模型列表及采样状态
$ curl http://localhost:8080/v1/models
→ 模型清单，含量化级别、后端、状态

# 统计 token 数（不触发推理）
$ curl http://localhost:8080/v1/count-tokens \
    -d '{"prompt":"Hello world"}'
→ {"prompt_tokens":N}

# 从 ModelScope 下载并注册模型
$ curl -X POST http://localhost:8080/v1/models/download \
    -d '{"modelScope":"qwen/qwen3.5-4b-4bit"}'
→ SSE 流式下载进度，完成后自动注册

# 健康检查和监控指标
$ curl http://localhost:8080/health
$ curl http://localhost:8080/metrics
```

---

### API 端点

| 方法 | 端点 | 说明 |
|------|------|------|
| `POST` | `/v1/chat/completions` | OpenAI 聊天接口（流式 + 非流式，支持工具调用） |
| `POST` | `/v1/messages` | Anthropic 消息接口 + 工具使用 |
| `POST` | `/v1/count-tokens` | Token 统计工具 |
| `GET`  | `/v1/models` | 模型注册表 |
| `GET`  | `/v1/models/:model/sampling` | 获取模型采样配置 |
| `DELETE` | `/v1/models/:model/sampling` | 重置模型采样配置 |
| `DELETE` | `/v1/models/sampling` | 重置所有采样配置 |
| `POST` | `/v1/models/download` | 从 ModelScope / HuggingFace 下载模型 |
| `GET`  | `/sessions` | 列出 session |
| `DELETE` | `/sessions/:id` | 删除 session |
| `GET`  | `/sessions/:id/memory` | 查询 memory events |
| `GET`  | `/sessions/search` | FTS5 全文搜索 |
| `GET`  | `/skills` | 技能列表 |
| `POST` | `/mcp` | MCP JSON-RPC 端点 |
| `GET`  | `/health` | 健康检查 |
| `GET`  | `/metrics` | Prometheus 指标 |

---

### 架构

```
┌─────────────────────────────────────────────────────────────┐
│                         ocoreai 服务器                       │
│                                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐ │
│  │  路由层   │→ │  处理层   │→ │  调度器   │→ │  引擎    │ │
│  │(HB 2.25) │  │  (SSE)   │  │(Actor)   │  │ (MLX)   │ │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘ │
│                                         ↑               │
│  ┌───────────┐  ┌──────────┐  ┌────────┐  │             │
│  │ 配置系统   │  │ SQLite   │  │  MCP   │  └────────────┘ │
│  │(YAML+hw)  │  │(FTS5)    │  │(JSON-RPC)│               │
│  └───────────┘  └──────────┘  └────────┘                │
│  ┌───────────┐  ┌──────────┐  ┌────────┐                │
│  │ 内存追踪   │  │ 安全模块 │  │ 技能系统 │               │
│  │+OOM保护   │  │(审计)    │  │(注册表)  │               │
│  └───────────┘  └──────────┘  └────────┘                │
└─────────────────────────────────────────────────────────────┘
```

MLX 通过 Metal GPU 原生推理。macOS 15.3+ / M4+ 上 CoreAI 为首选后端（通过 `--traits coreai` 编译）。内存预算通过 `sysctl hw.memsize` 自动检测（物理内存的 70%）。OOMGuard 执行降级链：`4bit → 8bit → CPU → 拒绝` — 无磁盘 I/O，适用于 Apple Silicon UMA 架构。

调度器按优先级分发请求（`P0=系统` … `P4=用户`），MemoryTracker 在 actor 邮箱中管理每个请求的 GPU 内存分配/释放。

---

### 配置

创建 `~/.ocoreai.yaml`：

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
  budget_gb: 0      # 0 = 自动检测（70% 物理内存）
```

支持的推理后端：`coreai`（macOS 15.3+，M4+，通过 `--traits coreai` 编译），`mlx`（默认，Metal）。

---

### 模块

| 模块 | 路径 | 功能 |
|------|------|------|
| **路由层** | `Router/` | Hummingbird HTTP 路由，端点分发 |
| **处理层** | `Handlers/` | 聊天完成、SSE 流式、模型下载 |
|| **调度器** | `Scheduler/` | 优先级分发、内存追踪、OOM 保护 |
|| **引擎** | `Engine/` | MLX/CoreAI 推理桥接、会话池 |
|| **SQLite** | `SQLite/` | 会话存储 + FTS5 全文搜索 + memory events |
| **配置** | `Config/` | YAML 配置 + 硬件自动检测 |
| **MCP** | `MCP/` | JSON-RPC 2.0 工具服务（stdio 传输） |
| **安全** | `Security/` | 钥匙串存储、结构化日志、审计追踪 |
| **技能** | `Skills/` | 技能注册表、加载器、系统提示构建器 |
| **工具** | `Tools/` | 模型下载、工具注册 |
| **中间件** | `Middleware/` | 速率限制、请求过滤 |

---

### 状态

| 组件 | 状态 |
|------|------|
| MLX Metal 推理 | ✅ |
| SSE 流式 + 非流式 | ✅ |
| Anthropic 兼容 API | ✅ |
| SQLite 会话持久化 | ✅ |
| FTS5 全文搜索 + memory events | ✅ |
| 技能系统 + 提示构建器 | ✅ |
| MCP 工具端点 | ✅ |
| 调度器: Anthropic + Chat 双路径统一 | ✅ |
| Dashboard UI | 🔲 Models/Settings mock |

---

### 许可证

MIT — Copyright © 2026 uingei@163.com
