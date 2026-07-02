# ocoreai — 本地优先 AI Agent 运行时

**macOS 原生 LLM 推理平台** — 基于 CoreAI / MLX + Metal 的 Agent 推理系统，内置工具调用、多模态 I/O 与技能系统。Swift 6.3 + Hummingbird 2.25 + SwiftUI 构建。

[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://www.swift.org)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue.svg)](https://developer.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

### 快速开始

**macOS 15+ · Apple Silicon · Swift 6.3**

```bash
git clone https://github.com/uingei/ocoreai.git && cd ocoreai
swift build -c release --traits mlx
.build/release/ocoreai
```

服务监听 `127.0.0.1:8080`。配置位于 `~/.ocoreai/config.yaml`。

---

### 是什么

ocoreai 是一个**本地优先的 AI Agent 运行时**：

- **双推理后端** — MLX（Metal GPU，默认）+ CoreAI（Apple Neural Engine，macOS 27+ / M4+）。零网络请求 — 推理在你的 Mac 上完成。
- **Agent 循环** — 多轮工具调用：模型推理 → 调用已注册工具 → 读取结果 → 迭代（最多 30 轮，180 秒超时）。内置系统信息、技能查询、搜索等工具。通过 `ToolRegistry` 扩展。
- **技能系统** — YAML 注册的模块化 Prompt 注入。启动时加载，注入到系统提示管线。
- **多模态 I/O** — 摄像头采集、麦克风输入、Apple Speech TTS — 全部原生，无外部依赖。
- **会话记忆** — SQLite + FTS5 全文搜索，LLM 驱动的会话压缩（热/温/冷三级）。
- **MCP 桥接** — 连接外部 MCP 服务器，其工具自动注册到 `ToolRegistry`。
- **调度器 + OOM 防护** — 优先级分发（`P0` 系统 → `P4` 用户），GPU 内存预算强制，降级链（4-bit → 8-bit → CPU → 拒绝）。
- **SwiftUI 仪表板** — 实时系统指标、模型管理、设置、聊天界面。

正在演进为完整的 **Agent OS** — 设备级运行时，LLM 通过统一工具接口控制工具、应用与桌面。

---

### API 端点

| 方法 | 端点 | 说明 |
|------|------|------|
| `POST` | `/v1/chat/completions` | OpenAI 聊天（流式 + 非流式，工具调用） |
| `POST` | `/v1/messages` | Anthropic 消息 + 工具使用 |
| `POST` | `/v1/count-tokens` | Token 统计 |
| `GET`  | `/v1/models` | 模型注册表 |
| `GET`  | `/v1/models/:model/sampling` | 获取采样配置 |
| `DELETE` | `/v1/models/:model/sampling` | 重置采样配置 |
| `POST` | `/v1/models/download` | 从 ModelScope / HuggingFace 下载模型 |
| `POST` | `/v1/multimodal/capture` | 摄像头帧或音频采样 |
| `POST` | `/v1/multimodal/speak` | TTS 输出 |
| `GET`  | `/sessions` | 列出会话 |
| `POST` | `/mcp` | MCP JSON-RPC 端点 |
| `GET`  | `/health` | 健康检查 |
| `GET`  | `/metrics` | Prometheus 指标 |

---

### 架构

```
┌──────────────────────────────────────────────────────────────┐
│                      ocoreai 运行时                          │
│                                                              │
│  ┌──────────┐  ┌───────────┐  ┌──────────┐  ┌───────────┐  │
│  │  路由层   │→ │  处理层   │→ │  调度器   │→ │  引擎    │  │
│  │(HB 2.25) │  │  (SSE)    │  │(Actor)   │  │(MLX/CoreAI)│  │
│  └──────────┘  └───────────┘  └──────────┘  └─────┬─────┘  │
│                                         ┌─────────┘        │
│  ┌───────────┐  ┌──────────┐  ┌────────┐  │               │
│  │ 配置系统   │  │ SQLite   │  │  MCP   │  │               │
│  │(YAML+hw)  │  │(FTS5)    │  │(JSON-RPC)│              │
│  └───────────┘  └──────────┘  └────────┘                 │
│  ┌───────────┐  ┌──────────┐  ┌────────┐                 │
│  │ 内存追踪   │  │ 安全模块 │  │ 技能系统 │               │
│  │+OOM防护   │  │(审计)    │  │(注册表)  │               │
│  └───────────┘  └──────────┘  └────────┘                 │
│  ┌───────────┐  ┌──────────┐                             │
│  │ 工具注册   │  │ 多模态   │                            │
│  │(Agent     │  │(摄像头+  │                            │
│  │  Loop)    │  │ 麦克风+  │                            │
│  │           │  │ TTS)     │                            │
│  └───────────┘  └──────────┘                             │
└──────────────────────────────────────────────────────────────┘
```

内存预算通过 `sysctl hw.memsize` 自动检测（物理内存的 70%）。OOMGuard 执行降级链，无磁盘 I/O — 适用于 Apple Silicon UMA 架构。

---

### 配置

创建 `~/.ocoreai/config.yaml`：

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

支持的推理后端：`coreai`（macOS 27+，M4+，通过 `--traits coreai` 编译），`mlx`（默认，Metal）。

---

### 模块

| 模块 | 路径 | 功能 |
|------|------|------|
| **路由层** | `Router/` | Hummingbird HTTP 路由，端点分发 |
| **处理层** | `Handlers/` | 聊天完成、SSE 流式、模型下载、多模态 |
| **调度器** | `Scheduler/` | 优先级分发、内存追踪、OOM 防护 |
| **引擎** | `Engine/` | MLX/CoreAI 推理桥接、会话池、引擎生命周期 |
| **Agent** | `Agents/` | Agent 循环 — 多轮工具调用、推理→行动周期 |
| **工具注册** | `Tools/` | Actor 隔离的工具注册、分发、循环检测、审计追踪 |
| **技能** | `Skills/` | 技能注册表、加载器、系统提示构建器 |
| **SQLite** | `SQLite/` | 会话存储 + FTS5 全文搜索 + memory events |
| **配置** | `Config/` | YAML 配置 + 硬件自动检测 |
| **MCP** | `MCP/` | JSON-RPC 2.0 工具服务（stdio 传输） |
| **多模态** | `Multimodal/` | 摄像头采集、音频 I/O、TTS（Apple Speech） |
| **安全** | `Security/` | 钥匙串存储、结构化日志、审计追踪 |
| **指标** | `Metrics/` | Prometheus 指标采集和导出 |

---

### 状态

| 组件 | 状态 |
|------|------|
| MLX Metal 推理 | ✅ |
| CoreAI 后端（macOS 27+） | ✅ |
| SSE 流式 + 非流式 | ✅ |
| OpenAI + Anthropic 兼容 API | ✅ |
| Agent 循环与工具调用 | ✅ |
| 工具注册（Actor 隔离） | ✅ |
| SQLite 会话持久化 + FTS5 | ✅ |
| 技能系统 + 提示构建器 | ✅ |
| MCP 桥接 | ✅ |
| 多模态（摄像头/音频/TTS） | ✅ |
| SwiftUI 仪表板 UI | ✅ |
| 自适应系统（EMA 健康监控） | ✅ |

---

### 许可证

MIT — Copyright © 2026 uingei@163.com
