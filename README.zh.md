# ocoreai — Self-Contained AI Agent OS

**macOS 原生 AI Agent 平台** — 双通道推理（MLX GPU + CoreAI ANE）、Agent 循环与工具调用、技能系统、会话记忆，一体成型。基于 Swift 6.3、Hummingbird 2.25、SwiftUI 构建。

[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://www.swift.org)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue.svg)](https://developer.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

### 快速开始

**macOS 15+ · Apple Silicon · Swift 6.3**

```bash
git clone https://github.com/uingei/ocoreai.git && cd ocoreai
swift build -c release --traits mlx
```

通过 Xcode 构建并运行，或 `swift run` 启动。
服务监听 `127.0.0.1:8080`。配置位于 `~/.ocoreai/config.yaml`。

---

### 能力清单

ocoreai 将推理引擎、Agent 编排、持久化存储统一在单一进程中：

- **双通道推理引擎** — MLX（Metal GPU，默认）+ CoreAI（Apple Neural Engine，macOS 27+ / M4+，当前为 Stub 等待 SDK）。零网络调用 — 推理在你的 Mac 上运行。
- **Wired Memory 显存硬隔离** — 硬件级显存边界，防止推理中 OOM。
- **Agent 循环** — 多轮工具调用：模型推理 → 调用注册工具 → 读取结果 → 循环迭代（最多 30 轮，180 秒超时）。内置系统信息、技能、搜索工具。通过 `ToolRegistry` 扩展。
- **技能系统** — YAML 注册表的模块化提示模板。启动时加载，注入系统提示管线。
- **会话记忆** — SQLite + FTS5 全文搜索，LLM 驱动的会话压缩（热/温/冷分层）。记忆事件支持跨会话事实召回。
- **MCP 桥接** — 连接外部 MCP 服务器；通过 HTTP 端点和 ToolRegistry 分发器可用。
- **调度器 + OOM 防护** — 优先级分发（`P0` 系统 → `P4` 用户），GPU 显存预算强制，降级链（4-bit → 8-bit → CPU → 拒绝）。
- **配置系统** — YAML 配置 + 文件监听器（轮询）。显存预算硬件自动检测。
- **多模态 I/O** — 摄像头捕获、麦克风输入、Apple Speech TTS — 全部原生，无外部依赖。
- **SwiftUI 仪表盘** — 实时系统指标、模型管理、设置、聊天界面。

向完整 **Agent OS** 演进 —— 设备级运行时，LLM 通过统一工具接口控制工具、应用和桌面。

---

### API 端点

| 方法 | 端点 | 用途 |
|------|------|------|
| `POST` | `/v1/chat/completions` | OpenAI 聊天（流式 + 非流式，工具调用） |
| `POST` | `/v1/messages` | Anthropic 消息 + 工具使用 |
| `POST` | `/v1/count-tokens` | Token 计数 |
| `GET`  | `/v1/models` | 模型注册表 |
| `GET`  | `/v1/models/:model/sampling` | 获取采样配置 |
| `DELETE` | `/v1/models/:model/sampling` | 重置采样配置 |
| `POST` | `/v1/models/download` | 从 ModelScope / HuggingFace 下载 |
| `POST` | `/v1/multimodal/capture` | 摄像头或音频捕获 |
| `POST` | `/v1/multimodal/speak` | TTS 输出 |
| `GET`  | `/sessions` | 会话列表 |
| `POST` | `/mcp` | MCP JSON-RPC 端点 |
| `GET`  | `/health` | 健康检查 |
| `GET`  | `/metrics` | Prometheus 指标（文本格式） |

---

### 架构

统一架构 —— 推理、Agent、记忆一体进程：

```
┌─────────────────────────────────────────────────────────┐
│                       ocoreai                            │
│                                                         │
│  网关层                                                  │
│  ┌──────────────┐  ┌──────┐                             │
│  │ HTTP (HB)   │  │ GUI  │                             │
│  │ :8080 API   │  │SwiftUI│                             │
│  └──────┬──────┘  └──┬───┘                              │
│         │            │                                   │
│  控制平面                                             │
│  ┌──────┴──────┐  ┌──────────┐  ┌──────────┐            │
│  │   调度器    │  │ Agent    │  │   技能    │            │
│  │ P0→P4 分发  │  │ 循环     │  │ 注册表    │            │
│  │ OOMGuard    │  │ +ToolReg│  │          │            │
│  │ ConfigWatch │  │         │  │          │            │
│  └──────┬──────┘  └────┬───┘  └──────────┘            │
│         │              │                                │
│  推理引擎                                              │
│  ┌──────┴──────────────┴──────────┐                         │
│  │         EnginePool (actor)     │                         │
│  │  ┌──────────┐  ┌──────────┐   │                         │
│  │  │ MLX GPU  │  │ CoreAI  │   │                         │
│  │  │ (Metal)  │  │  ANE    │   │                         │
│  │  └──────────┘  └──────────┘   │                         │
│  │  SessionPool · WiredMem · Spec│                         │
│  └───────────────────────────────┘                         │
│                                                         │
│  持久层                                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐               │
│  │ SQLite   │  │ 安全审计 │  │ MCP      │               │
│  │ FTS5     │  │(Audit)   │  │ 桥接     │               │
│  └──────────┘  └──────────┘  └──────────┘               │
└─────────────────────────────────────────────────────────┘
```

**单一进程，无边界。** 调度器直接连接推理引擎 —— 无 localhost 跳转，无 IPC 序列化，控制平面与 GPU 之间零上下文丢失。

显存预算通过 `sysctl hw.memsize` 自动检测（物理 RAM 的 70%）。OOMGuard 强制执行降级链，无需磁盘 I/O —— 这是 Apple Silicon UMA 架构下的正确做法。

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
  budget_gb: 0      # 0 = 自动检测（70% RAM）
```

支持的推理后端：`coreai`（macOS 27+，M4+，通过 `--traits coreai` 编译），`mlx`（默认，Metal）。

---

### 模块

| 模块 | 路径 | 功能 |
|------|------|------|
| **路由器** | `Router/` | Hummingbird HTTP 路由，端点分发 |
| **处理器** | `Handlers/` | 聊天补全、SSE 流式、模型下载、多模态 |
| **调度器** | `Scheduler/` | 优先级分发、显存追踪、OOM 保护 |
| **引擎** | `Engine/` | MLX/CoreAI 推理桥接、会话池、引擎生命周期 |
| **Agent** | `Agents/` | Agent 循环 — 多轮工具调用、推理→行动循环 |
| **工具注册表** | `Tools/` | Actor 隔离的工具注册、分发、循环检测、审计 |
| **技能** | `Skills/` | 技能注册表、加载器、系统提示构建器 |
| **SQLite** | `SQLite/` | 会话存储 + FTS5 全文搜索 + 记忆事件 |
| **配置** | `Config/` | YAML 配置 + 硬件自动检测 |
| **MCP** | `MCP/` | JSON-RPC 2.0 工具服务器（stdio 传输） |
| **多模态** | `Multimodal/` | 摄像头、音频 I/O、TTS（Apple Speech） |
| **安全** | `Security/` | 钥匙串存储、结构化日志、审计 |
| **指标** | `Metrics/` | Prometheus 指标采集与导出 |

---

### 状态

| 组件 | 状态 |
|------|------|
| MLX Metal 推理 | ✅ |
| VLM 多模态推理 | ✅ |
| CoreAI ANE 后端（macOS 27+） | ⚠️ Stub（等待 SDK） |
| Wired Memory 显存硬隔离 | ✅ |
| 推测解码（传统 draft model） | ✅ |
| SSE 流式 + 非流式 | ✅ |
| OpenAI + Anthropic 兼容 API | ✅ |
| Agent 循环 + 工具调用 | ✅ |
| 工具注册表（Actor 隔离） | ✅ |
| SQLite 会话持久化 + FTS5 | ✅ |
| 技能系统 + 提示构建器 | ✅ |
| MCP 桥接 | ✅ |
| 多模态（摄像头/音频/TTS） | ✅ |
| SwiftUI 仪表盘 | ✅ |
| 自适应健康（EMA） | ✅ |

---

### License

MIT — Copyright © 2026 uingei@163.com
