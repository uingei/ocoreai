# ocoreai — 本地 Agent 可靠执行层

**macOS/iOS 本地 Agent 的执行层** — 一个 Swift 6.2 二进制：端侧推理（MLX Metal + CoreAI，上游衍生）、Agent 工具循环、会话记忆、Apple 原生多模态 I/O、OpenAI/Anthropic 兼容 HTTP 网关——单进程无 IPC。

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://www.swift.org)
[![macOS 14+ | iOS 17+](https://img.shields.io/badge/macOS%2014%20%7C%20iOS%2017-blue.svg)](https://www.apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/uingei/ocoreai/actions/workflows/ci.yml/badge.svg)](https://github.com/uingei/ocoreai/actions/workflows/ci.yml)

---

### 快速开始

**macOS 14+ · iOS 17+ · Apple Silicon · Swift 6.2 · 纯 SwiftPM**

```bash
git clone https://github.com/uingei/ocoreai.git && cd ocoreai
swift build -c release
swift run
```

```bash
curl -s http://127.0.0.1:8080/health
# { "status": "ok", "timestamp": 1714800000, "engineSummary": { "loadedModels": 0, "activeSessions": 0, ... } }
```

直接 SwiftPM 构建，无 `.xcodeproj`（测试门经 SPM 生成的 `ocoreai.xcworkspace` → `xcodebuild` → `xctest`）。
服务监听 `127.0.0.1:8080`。配置位于 `~/.ocoreai/config.yaml`。

> ⚠️ **仅本机访问** — HTTP API 默认绑定 `127.0.0.1`。认证默认关（设 `OCOREAI_API_KEYS` 环境变量开启），无 TLS。内置令牌桶限流默认开（全局 200 次/秒）。

> 🛠️ **开发版本** — 此为开发构建。生产使用需要额外加固（见下方 Security 部分）。

---

### 这里有什么

一个进程：推理（MLX Metal + CoreAI，上游衍生）+ Agent 循环（工具调用、技能、SQLite/FTS5 会话记忆）+ HTTP 网关（OpenAI/Anthropic 兼容端点，见下表）+ 原生多模态 I/O（摄像头/屏幕/音频/OCR/STT/TTS，全 Apple 原生）+ MCP 桥接（stdio）。

能力细节放在持续更新的地方：`CHANGELOG.md`（逐特性带 commit 引用）以及它跟随的上游仓 —— [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)、[coreai-models](https://github.com/apple/coreai-models)、[codex](https://github.com/openai/codex)。

已知边界（截至本 commit，是事实不是愿景）：

- **感知与 TTS 默认关闭** — Settings 逐通道开启；摄像头/屏幕/扬声器另需系统权限。
- **TTS/STT 需麦克风权限**；屏幕捕获仅 macOS。
- **i18n**：en + zh-Hans 已交付；ja/ko/fr/es 已定义未翻译。
- **CI**：macOS-26 腿为权威门；xcode-27 腿当前红，失败在上游 mlx-swift-lm pin（非 ocoreai 代码）。
- **代码审计 ✅ ≠ 行为验证** — 只说明"源码已实现"，有测试的才算验证过。

**方向** —— 第一产品：**Coding/Computer Agent**，让 LLM 在端侧可靠完成多步工程任务（**Execute** → **Verify** → **Recover**）。推理归上游（MLX / CoreAI），ocoreai 是其上的可靠执行层 —— 跟齐上游，不与之竞争。

---

### API 端点

| 方法 | 端点 | 用途 |
|------|------|------|
| `POST` | `/v1/chat/completions` | OpenAI 聊天（流式 + 非流式，工具调用） |
| `POST` | `/v1/completions` | OpenAI 旧版 completions（prompt 输入） |
| `POST` | `/v1` | 自动路由：按 body 键分发（`prompt`→completions，否则 chat） |
| `POST` | `/v1/messages` | Anthropic 消息 + 工具使用 |
| `POST` | `/v1/count-tokens` | Token 计数 |
| `GET`  | `/v1/models` | 模型注册表 |
| `GET`  | `/v1/models/:model/sampling` | 获取采样配置 |
| `PATCH` | `/v1/models/:model/sampling` | 热替换采样配置 |
| `DELETE` | `/v1/models/:model/sampling` | 重置单模型采样配置 |
| `DELETE` | `/v1/models/sampling` | 重置全部采样配置 |
| `POST` | `/v1/models/download` | 从 ModelScope / HuggingFace 下载 |
| `POST` | `/v1/models/train` | LLM 训练 |
| `POST` | `/v1/models/evaluate` | LLM 评估 |
| `GET`  | `/v1/stats` | 运行统计（请求/Token/耗时/TTFB） |
| `POST` | `/v1/multimodal/capture` | 摄像头或音频捕获 |
| `POST` | `/v1/multimodal/speak` | TTS 输出 |
| `POST` | `/v1/multimodal/status` | 多模态管线状态 |
| `GET`  | `/sessions` | 会话列表 |
| `GET`  | `/sessions/:id/memory` | 获取会话记忆事件 |
| `DELETE` | `/sessions/:id` | 删除会话 |
| `GET`  | `/sessions/search` | 会话全文搜索 |
| `GET`  | `/skills` | 列已注册技能 |
| `POST` | `/mcp` | MCP JSON-RPC 端点 |
| `GET`  | `/health` | 存活检查 |
| `GET`  | `/ready` | 就绪探针（`ready`/`busy`） |
| `GET`  | `/metrics` | Prometheus 指标（文本格式） |

> 免认证 public 路由：`/health`、`/ready`、`/v1/models`、`/v1/stats`、`/metrics`。所有 `PATCH`/`DELETE` 需 admin key（`OCOREAI_ADMIN_KEYS`）。

---

### 架构

单一进程、无边界：网关（Hummingbird `:8080` + SwiftUI）→ 控制平面（调度器 `P0`→`P3`、OOMGuard、ConfigWatcher）→ 路由（HardwareRouter GPU/ANE/CPU、AdmissionGate）→ 推理（MLX Metal / CoreAI ANE、会话池、推测解码）→ 持久层（SQLite + FTS5）。调度器经进程内直接驱动引擎——无 localhost 跳转、无 IPC。目录布局见下方模块表。

---

### 配置

创建 `~/.ocoreai/config.yaml`：

```yaml
server:
  port: 8080
  host: 127.0.0.1

backend:
  preference: ["coreai", "mlx"]   # 默认顺序 — 取第一个可用的
  wiredMemory:
    policy: "max"                  # max | sum | budget | fixed

models:
  default:
    enabled: true
    modelId: "mlx-community/gemma-4-e2b-it-4bit"
    source: modelscope       # "huggingface" 强制走 HF；其他值 → 默认 hub (modelscope)

memory:
  enabled: true              # 会话记忆（SQLite FTS5 + LLM 压缩）
```

> **认证**不是 YAML 键：设环境变量 `OCOREAI_API_KEYS`（逗号分隔）即开启；为空 = 不认证。

显存预算自 `sysctl hw.memsize` 自动检测；默认保护档 `balanced` = 物理 RAM 的 55%（档位：safe 40% / balanced 55% / aggressive 75%，下限 4 GB）。

支持的推理后端：`coreai`（macOS 27+ SDK，需 `#available` 运行时检查）与 `mlx`（Metal）。默认 `backend.preference` 顺序为 `["coreai", "mlx"]` — 取第一个可用后端（可在 `config.yaml` 覆盖）。

---

### 模块

| 模块 | 路径 | 功能 |
|------|------|------|
| **路由器** | `Router/` | Hummingbird HTTP 路由，端点分发 |
| **处理器** | `Handlers/` | 聊天补全、SSE 流式、模型下载、多模态 |
| **调度器** | `Scheduler/` | 优先级分发、显存追踪、OOM 保护、HardwareRouter、AdmissionGate |
| **引擎** | `Engine/` | MLX/CoreAI 推理桥接、双通道 FM/ChatSession 管线、FMToolProxy 桥接、会话池、引擎生命周期、VLM 管线 |
| **Agent** | `Agents/` | Agent 循环 — 多轮工具调用、推理→行动循环 |
| **工具注册表** | `Tools/` | Actor 隔离的工具注册、分发、循环检测、审计 |
| **技能** | `Skills/` | 技能注册表、加载器、系统提示构建器 |
| **SQLite** | `SQLite/` | 会话存储 + FTS5 全文搜索 + 记忆事件 |
| **配置** | `Config/` | YAML 配置 + 硬件自动检测 |
| **MCP** | `MCP/` | JSON-RPC 2.0 工具服务器（stdio 传输） |
| **多模态** | `Multimodal/` | 摄像头、屏幕、音频 I/O、TTS（Apple Speech）、Vision OCR |
| **安全** | `Security/` | ContentGuard、结构化日志、审计、全局崩溃处理、意图/自然语言分类器、自校正管线 |
| **推理** | `Reasoning/` | ComplexityAnalyzer、ThinkingBudget（自适应推理深度） |
| **分析** | `Profiling/` | TimingHooks（延迟/TTFB） |
| **指标** | `Metrics/` | Prometheus 指标采集与导出 |
| **本地化** | `Localization/` | i18n（en, zh-Hans 已部署；ja, ko, fr, es 已定义） |

---

### 安全

- **网络** — 仅绑定 `127.0.0.1`。无外部地址暴露。
- **认证** — 环境变量 `OCOREAI_API_KEYS`（逗号分隔）开启，PATCH/DELETE 另需 `OCOREAI_ADMIN_KEYS`；为空则不认证。非 YAML 键。
- **速率限制** — Token-bucket 令牌桶限流器，可配置 burst/window。
- **ContentGuard** — 三阶段输入/输出内容过滤。
- **StructuredLogger** — 结构化审计跟踪、日志轮转。
- **全局崩溃处理** — 未捕获异常或 POSIX 信号（segv/abort/bus）时，写入结构化崩溃日志到 `~/Library/Application Support/ocoreai/logs/` 后退出。
- **并发安全** — Swift 6 严格并发，scheduler/tool registry/inference engine 的 actor 隔离；`@unchecked Sendable` 声明均附并发理由注释。

---

### 状态

逐特性状态 + commit 引用在 `CHANGELOG.md`。截至本 commit 的稳定事实：

- **权威门**：`make test-ci`（xcodebuild 路径，macOS-26 腿）—— `swift test` 会撞 `.build` metallib 缺失（环境噪声，非真失败），只作增量快筛。
- **CI**：macOS-26 腿绿；xcode-27 腿红在上游 mlx-swift-lm pin，非本仓代码。

---

### Build Info

- Swift 6.2 · SwiftUI · Hummingbird 2.26
- macOS 14+ / iOS 17+ · Apple Silicon · 纯 SwiftPM
- 质量门：`make test-ci`（xcodebuild 路径，macOS-26 腿为权威）；已知现存 5 条源码警告
---

### License

MIT — Copyright © 2026 uingei@163.com
