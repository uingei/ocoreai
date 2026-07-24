# ocoreai — Self-Contained AI Agent OS

**macOS 原生 AI Agent 平台** — 双通道端侧推理（MLX Metal GPU + CoreAI）、Prefix Cache、KV Cache 量化、推测解码（MTP + Drafter）、Agent 循环与工具调用、技能系统、会话记忆、多模态 I/O，一体成型。基于 Swift 6.3、Hummingbird 2.25、SwiftUI 构建。

[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://www.swift.org)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue.svg)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Tests: 703](https://img.shields.io/badge/Tests-703%2F703-brightgreen)](Tests/)

---

### 快速开始

**macOS 15+ · Apple Silicon · Swift 6.3 · 纯 SwiftPM**

```bash
git clone https://github.com/uingei/ocoreai.git && cd ocoreai
swift build -c release
swift run
```

直接 SwiftPM 构建，无需 Xcode 工程。
服务监听 `127.0.0.1:8080`。配置位于 `~/.ocoreai/config.yaml`。

> ⚠️ **仅本机访问** — HTTP API 默认绑定 `127.0.0.1`，无认证、无 TLS。不要暴露在外部网络。

> 🛠️ **开发版本** — 此为开发构建。生产使用需要额外加固（见下方 Security 部分）。

---

### 能力清单

ocoreai 将推理引擎、Agent 编排、持久化存储统一在单一进程中：

- **双通道推理引擎** — MLX（Metal GPU，默认）+ CoreAI（1,115 LOC，动态 KV Cache、TokenHistory prefix caching、GenerationToken + Mutex cancel-and-replace）。零网络调用 — 推理在你的 Mac 上运行。
- **自适应硬件路由** — HardwareRouter 根据热压力、内存余量、GPU 利用率实时将请求分发至 GPU / ANE / CPU。AdmissionGate 执行三级准入策略（允许 → 仅限 ANE → 拒绝），支持可配置 abort margin。
- **Wired Memory 显存硬隔离** — 硬件级显存边界，防止推理 OOM。
- **Thinking Budget（推理预算）** — 基于 ComplexityAnalyzer（长度、意图、历史三维度评分）的自适应 token 预算分配。仅在 Bridge Path 生效；桌面 GUI（Fast Path）尚未接入。
- **Agent 循环** — 多轮工具调用：模型推理 → 调用注册工具 → 读取结果 → 循环迭代（最多 30 轮，180 秒超时）。内置系统信息、技能、搜索工具。通过 `ToolRegistry` 扩展。
- **技能系统** — 模块化技能注册表，启动时加载，双向链接至系统提示管线。
- **会话记忆** — SQLite + FTS5 全文搜索，LLM 驱动的会话压缩（热/温/冷分层）。记忆事件支持跨会话事实召回。语义记忆（向量搜索）代码存在但默认关闭（`autoEmbed: false`）。
- **MCP 桥接** — 通过 stdio 传输连接外部 MCP 服务器；HTTP 端点可用。桌面 UI 尚无 MCP 入口。
- **调度器 + OOM 防护** — 优先级分发（`P0` 系统 → `P4` 用户），GPU 显存预算强制，降级链（4-bit → 8-bit → CPU → 拒绝）。
- **KV Cache 量化** — turbo4/INT8 自动降级，通过 `GenerateParameters.kvBits`/`kvScheme` 配置。
- **推测解码** — Gemma drafter 模型支持（12B/26B/31B 独立路由），MTP 模式已接入。
- **配置系统** — YAML 配置 + 文件监听器（轮询）。显存预算硬件自动检测。
- **多模态 I/O** — 摄像头捕获、屏幕截图、麦克风输入、Vision OCR、16kHz Apple Speech STT、多语言 TTS — 全部原生。摄像头/屏幕默认关闭；STT 需要麦克风权限。
- **i18n** — StringKey 本地化框架完整；仅英文已部署。其他语种（zh, ja, ko, fr, de）已定义但未翻译为 `.strings` 文件。

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
| `PATCH` | `/v1/models/:model/sampling` | 热替换采样配置 |
| `DELETE` | `/v1/models/:model/sampling` | 重置单模型采样配置 |
| `DELETE` | `/v1/models/sampling` | 重置全部采样配置 |
| `POST` | `/v1/models/download` | 从 ModelScope / HuggingFace 下载 |
| `POST` | `/v1/multimodal/capture` | 摄像头或音频捕获 |
| `POST` | `/v1/multimodal/speak` | TTS 输出 |
| `POST` | `/v1/multimodal/status` | 多模态管线状态 |
| `GET`  | `/sessions` | 会话列表 |
| `GET`  | `/sessions/:id/memory` | 获取会话记忆事件 |
| `GET`  | `/sessions/search` | 会话全文搜索 |
| `POST` | `/mcp` | MCP JSON-RPC 端点 |
| `GET`  | `/health` | 健康检查 |
| `GET`  | `/metrics` | Prometheus 指标（文本格式） |

---

### 架构

统一架构 —— 推理、Agent、记忆一体进程：

```
┌──────────────────────────────────────────────────────────────┐
│                         ocoreai                               │
│                                                              │
│  网关层                                                        │
│  ┌────────────────┐  ┌────────┐                              │
│  │ HTTP (HB)      │  │ GUI    │                              │
│  │ :8080 API      │  │ SwiftUI│                              │
│  └────────┬───────┘  └───┬────┘                              │
│           │              │                                   │
│  控制平面                                                    │
│  ┌──────────┴────┐  ┌──────────┐  ┌──────────┐             │
│  │    调度器      │  │ Agent    │  │   技能    │             │
│  │ P0→P4 分发    │  │  循环    │  │  注册表   │             │
│  │    OOMGuard   │  │ +ToolReg │  │          │             │
│  │  ConfigWatch  │  │          │  │          │             │
│  └──────────┬────┘  └────┬─────┘  └──────────┘             │
│             │            │                                  │
│  路由层                                                      │
│  ┌──────────┴────┐  ┌──────────┐                            │
│  │ HardwareRouter│  │ Admission│                            │
│  │ GPU/ANE/CPU   │  │   Gate   │ 三级：允许→ANE-only→拒绝   │
│  └──────────┬────┘  └──────────┘                            │
│             │                                              │
│  推理引擎                                                  │
│  ┌──────────┴────────────────┬───────┐                    │
│  │         EnginePool (actor) │          │                    │
│  │  ┌─────────────┐  ┌──────┐ │        │                    │
│  │  │ MLX GPU     │  │CoreAI│ │        │                    │
│  │  │ (Metal)     │  │ ANE  │ │        │                    │
│  │  └─────────────┘  └──────┘ │        │                    │
│  │  SessionPool · WiredMem · Spec · ThinkingBudget · OCR │   │
│  └─────────────────────────────┘                    │        │
│                                                              │
│  持久层                                                   │
│  ┌──────────────┐  ┌──────────┐  ┌──────────┐             │
│  │ SQLite + FTS5│  │ 安全审计 │  │ MCP      │             │
│  │   会话       │  │ (Audit)  │  │  桥接    │             │
│  └──────────────┘  └──────────┘  └──────────┘             │
└──────────────────────────────────────────────────────────────┘
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
    modelScope: "mlx-community/gemma-4-e2b-it-4bit"
    hub: huggingface

memory:
  budget_gb: 0      # 0 = 自动检测（70% RAM）
```

支持的推理后端：`coreai`（macOS 27+ SDK，需 `#available` 运行时检查），`mlx`（默认，Metal）。

---

### 模块

| 模块 | 路径 | 功能 |
|------|------|------|
| **路由器** | `Router/` | Hummingbird HTTP 路由，端点分发 |
| **处理器** | `Handlers/` | 聊天补全、SSE 流式、模型下载、多模态 |
| **调度器** | `Scheduler/` | 优先级分发、显存追踪、OOM 保护、HardwareRouter、AdmissionGate |
| **引擎** | `Engine/` | MLX/CoreAI 推理桥接、会话池、引擎生命周期、VLM 管线 |
| **Agent** | `Agents/` | Agent 循环 — 多轮工具调用、推理→行动循环 |
| **工具注册表** | `Tools/` | Actor 隔离的工具注册、分发、循环检测、审计 |
| **技能** | `Skills/` | 技能注册表、加载器、系统提示构建器 |
| **SQLite** | `SQLite/` | 会话存储 + FTS5 全文搜索 + 记忆事件 |
| **配置** | `Config/` | YAML 配置 + 硬件自动检测 |
| **MCP** | `MCP/` | JSON-RPC 2.0 工具服务器（stdio 传输） |
| **多模态** | `Multimodal/` | 摄像头、屏幕、音频 I/O、TTS（Apple Speech）、Vision OCR |
| **安全** | `Security/` | 钥匙串存储、结构化日志、审计、ContentGuard、AdaptiveThreshold |
| **推理** | `Reasoning/` | ComplexityAnalyzer、ThinkingBudget（自适应推理深度） |
| **分析** | `Profiling/` | ErrorContext（结构化错误捕获）、TimingHooks（延迟/TTFB） |
| **指标** | `Metrics/` | Prometheus 指标采集与导出 |
| **本地化** | `Localization/` | 6 语种 i18n（en, zh, ja, ko, fr, de） |

---

### 安全

- **网络** — 仅绑定 `127.0.0.1`。无外部地址暴露。
- **认证** — 可选 `auth.api_key` 配置。通过 `auth.enabled: false` 禁用。
- **速率限制** — Token-bucket 令牌桶限流器，可配置 burst/window。
- **ContentGuard** — 三阶段输入/输出内容过滤。
- **AdaptiveThreshold** — 基于 EMA 的健康监控与动态阈值调整。
- **StructuredLogger** — 结构化审计跟踪、日志轮转、macOS Keychain 集成。
- **全局崩溃处理** — 未捕获异常或 POSIX 信号（segv/abort/bus）时，写入结构化崩溃日志到 `~/Library/Application Support/ocoreai/logs/` 后退出。
- **并发安全** — Swift 6 严格并发，scheduler/tool registry/inference engine 的 actor 隔离。所有 `@unchecked Sendable` 均附并发理由注释（10/10 站点）。

---

### 状态

| 组件 | 状态 |
|------|------|
| MLX Metal 推理 | ✅ |
| CoreAI 推理（动态 KV Cache、Prefix Cache） | ✅ |
| KV Cache 量化（turbo4/INT8） | ✅ |
| VLM 多模态推理 | ✅ |
| Wired Memory 显存硬隔离 | ✅ |
| HardwareRouter（自适应 GPU/ANE/CPU） | ✅ |
| AdmissionGate（三级准入） | ✅ |
| 引擎生命周期状态机 + 断路器 | ✅ |
| ThinkingBudget（自适应推理深度） | ⚠️ 仅 Bridge Path — 桌面 GUI（Fast Path）未接入 |
| 推测解码（传统 drafter 模式） | ✅ |
| 推测解码（MTP 模式） | ⚠️ `createSpeculativeConfig()` 返回 nil — MTP SDC 迭代器未连接 |
| SSE 流式 + 非流式 | ✅ |
| OpenAI + Anthropic 兼容 API | ✅ |
| Agent 循环 + 工具调用 | ✅ |
| 工具注册表（Actor 隔离） | ✅ |
| SQLite 会话持久化 + FTS5 | ✅ |
| 技能系统 + 提示构建器 | ✅ |
| MCP 桥接 | ⚠️ 仅 HTTP 端点 — 桌面 UI 无入口 |
| 多模态 I/O（摄像头/屏幕/OCR/STT） | ⚠️ 已接入；摄像头/屏幕默认关闭，STT 需麦克风权限 |
| TTS（语音输出） | ⚠️ 已接入；通过 `speakerEnabled` 惰性触发（默认关闭） |
| Self Correction Pipeline | ⚠️ 仅 Bridge Path — 需显式 `selfCorrection: true`；无 UI 开关 |
| i18n | ⚠️ 框架完整；仅英文已部署，另 5 语种已定义未翻译 |
| SwiftUI 仪表盘 | ✅ |
| 自适应健康（EMA） | ✅ |
| 分析模块（ErrorContext + TimingHooks） | ✅ |

---

### 构建信息

- Swift 6.3 · SwiftUI · Hummingbird 2.25
- 137 个 Swift 源文件，~39,713 LOC
- macOS 15+ · Apple Silicon only
- 测试：52 个测试文件，124 套件
- 构建：0 警告，0 错误

---

### License

MIT — Copyright © 2026 uingei@163.com
