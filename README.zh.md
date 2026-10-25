# ocoreai — 开放模型的 Agent · 原生本地

**为创作、工作与代码而生** —— 面向编码与知识工作的完整 agentic 系统 — macOS/iOS 上的一个 Swift 6.2 二进制：端侧推理（MLX Metal + CoreAI，上游衍生）、Agent 工具循环、会话记忆、Apple 原生多模态 I/O、OpenAI/Anthropic 兼容 HTTP 网关——单进程无 IPC。

[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://www.swift.org)
[![macOS 14+ | iOS 17+](https://img.shields.io/badge/macOS%2014%20%7C%20iOS%2017-blue.svg)](https://www.apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/uingei/ocoreai/actions/workflows/ci.yml/badge.svg)](https://github.com/uingei/ocoreai/actions/workflows/ci.yml)

---

### 快速开始

**macOS 14+ · iOS 17+ · Apple Silicon · Swift 6.2 · 纯 SwiftPM**

**测过的 vs 声明的:** 本项目在 macOS 26 上实机执行——全量测试、live `/v1/*` 探针、36 题任务台
都在此机跑过,且 `make release` 断言产物不含 CoreAI、minos=14.0。macOS 14/15:未在真机运行过。
iOS 17+:仅编译验证(CI 的 `generic/platform=iOS`),iOS 上从未真跑过一次;所以上面那行是
`Package.swift` 里声明的下限,不是实测结论。

**用户路径 — 双击即用:** 下载 [最新 Release](https://github.com/uingei/ocoreai/releases/latest) 的 `ocoreai-<ver>.dmg` → 打开 → 拖到 `应用程序` → 启动。模型在「模型」页推荐列表首启下载；界面跟随系统语言（已内置简体中文）。

> 首次启动: 当前 DMG 为 ad-hoc 签名(未公证)。若 Gatekeeper 提示"无法打开",在访达的 `应用程序` 里**右键 ocoreai → 打开 → 打开**即可,仅需一次。

**开发者路径 — 源码构建:**

```bash
git clone https://github.com/uingei/ocoreai.git && cd ocoreai
swift build -c release     # 或 make app
swift run ocoreai serve    # headless：引擎 + HTTP 桥，无窗口
# 本地出 DMG: bash scripts/build-dmg.sh
```

```bash
curl -s http://127.0.0.1:8080/health
```

直接 SwiftPM 构建，无 `.xcodeproj`（测试门经 SPM 生成的 `ocoreai.xcworkspace` → `xcodebuild` → `xctest`）。
**无头 HTTP 入口：`ocoreai serve`**（`swift run ocoreai serve`，或直接运行构建产物）——引擎 + 桥绑定 `127.0.0.1:8080`，无需窗口/WindowServer 会话。退出语义：`SIGTERM` 或关闭 stdin 触发优雅退出（引擎排空 ≤30s 后干净退出），`SIGINT` 保持终端默认行为。不带参数直接 `ocoreai` 则照常启动 GUI。服务监听 `127.0.0.1:8080`。配置位于 `~/.ocoreai/config.yaml`。
DMG 安装的 App Store build 默认只开 GUI（Fast Path）；HTTP 桥需显式 opt-in — 终端运行 `OCOREAI_ENABLE_HTTP=1 /Applications/ocoreai.app/Contents/MacOS/ocoreai`（实证：`/health` 200 + `/v1/chat/completions` 推理闭环）。

> ⚠️ **仅本机访问** — HTTP API 默认绑定 `127.0.0.1`。认证默认关（设 `OCOREAI_API_KEYS` 环境变量开启），无 TLS。令牌桶限流默认开：全局 **200 次/秒**（burst 300）、单模型 30/秒（burst 45）、单 IP 20/秒（burst 30）—— 在 `App.swift:718` 一处设定，由 `Middleware/RateLimitMiddleware.swift` 执行。
<!-- claim:global_rate_set=1 :: grep -c 'globalRate: 200' Sources/ocoreai/App.swift -->
<!-- anchor:. Sources/ocoreai/App.swift:718 globalRate: 200 -->

> 🛠️ **开发版本** — 此为开发构建。生产使用需要额外加固（见下方 Security 部分）。

---

### 生命周期

- **更新**：设置 → 关于 → “检查更新…”——对比当前版本与 GitHub 最新 Release，由用户决定下载；绝不静默下载。
- **卸载**：`scripts/uninstall.sh`（默认 dry run）按层级列出全部足迹——可再生缓存/日志、用户数据（会话/配置）、模型权重、App 本体——只删除你以 `--data / --userdata / --models / --app / --all` 选中的层级。模型权重动辄数百 GB：不点名绝不碰。钥匙串零条目是有意设计（token 走 env-first，对齐 mlx-swift-lm/coreai-models）。

### 这里有什么

一个进程：推理（MLX Metal + CoreAI，上游衍生）+ Agent 循环（工具调用、技能、SQLite/FTS5 会话记忆）+ HTTP 网关（OpenAI/Anthropic 兼容端点，见下表）+ 原生多模态 I/O（摄像头/屏幕/音频/OCR/STT/TTS，全 Apple 原生）+ MCP 桥接（stdio）。

能力细节放在持续更新的地方：`CHANGELOG.md`（逐特性带 commit 引用）以及它跟随的上游仓 —— [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)、[coreai-models](https://github.com/apple/coreai-models)、[codex](https://github.com/openai/codex)。

已知边界（截至本 commit，是事实不是愿景）：

- **感知与 TTS 默认关闭** — Settings 逐通道开启；摄像头/屏幕/扬声器另需系统权限。
- **TTS/STT 需麦克风权限**；屏幕捕获仅 macOS。
- **i18n**：en + zh-Hans 已交付；ja/ko/fr/es 已定义未翻译。
- **CI**：六条腿 —— `governance`（ubuntu-latest）、`audit`（macos-26：静态审计、文档契约、行锚点、工具链契约、resolved 同步、swift-format、密钥扫描）、`build-and-test`（矩阵 `macos-26` + `xcode-27`）、`release`（macos-26 DMG）、`build-appstore`（macos-26）、`build-ios`（macos-26）。**macOS-26 是交付门。** 本文只陈述「有哪些腿」，不陈述「腿绿不绿」：钉死某个 SHA 的「最后一次全绿」下次 push 就过期，且克隆里无从复核 —— 本文件上方曾说 `xcode-27` 红、下方又说它绿，两句互相矛盾。实时状态看顶部徽章与该 SHA 对应的 run；逐条裁决在 `CHANGELOG.md`。
- **代码审计 ✅ ≠ 行为验证** — 只说明"源码已实现"，有测试的才算验证过。

**方向** —— 开放模型的 Agent，原生本地，为创作、工作与代码而生；面向编码与知识工作的完整 agentic 系统。**编码是最深切片**：Coding/Computer Agent，让 LLM 在端侧可靠完成多步工程任务（**Execute** → **Verify** → **Recover**）。创作（Apple 原生感知/多模态）与知识工作（检索/阅读/写作）是一等产品面，不是附属。推理归上游（MLX / CoreAI），ocoreai 是其上的可靠执行层 —— 跟齐上游，不与之竞争。

**参考** — [Apple Developer 文档](https://developer.apple.com/documentation/)、[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)(推理与 SPM pin)、[coreai-models](https://github.com/apple/coreai-models)(CoreAI 路线参照)、[codex](https://github.com/openai/codex)(agent 语义)、[Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines) —— 另有 [vLLM](https://github.com/vllm-project/vllm) / [vLLM-Metal](https://github.com/vllm-project/vllm-metal) / [SGLang](https://github.com/sgl-project/sglang) 作服务化系统参照、[omlx](https://github.com/omlx-ai/omlx) 作生产级参照、[OpenClaw](https://github.com/steipete/clawd) 与 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 作 agent 平台参照。

---

### API 端点

| 方法 | 端点 | 用途 |
|------|------|------|
| `POST` | `/v1/chat/completions` | OpenAI 聊天（流式 + 非流式，工具调用） |
| `POST` | `/v1/completions` | OpenAI 旧版 completions（prompt 输入） |
| `POST` | `/v1` | 自动路由：按 body 键分发（`prompt`→completions，否则 chat） |
| `POST` | `/v1/messages` | Anthropic 消息 + 工具使用 + thinking |
| `POST` | `/v1/messages/count_tokens` | Anthropic 预检：数 `/v1/messages` 实际要送出的那次请求（下界） |
| `POST` | `/v1/count-tokens` | 数你送出的那段文本（`prompt` / `input` / `messages`） |
| `POST` | `/v1/embeddings` | 本地 embeddings（LFM2.5-Embedding-350M，1024 维） |
| `GET`  | `/v1/tools` | Agent 工具面（OpenAI `tools[]` 形状，可直接粘回请求） |
| `GET`  | `/v1/capabilities` | 设备能力矩阵（按实测说话，不止看编译进去了什么）+ 分词后端（`real`/`heuristic`）+ 端点索引 |
| `POST` | `/v1/steer` | 向进行中的 turn 插话（无则并入下一次请求） |
| `GET`  | `/v1/models` | 模型注册表 |
| `GET`  | `/v1/models/:model/sampling` | 获取采样配置 |
| `PATCH` | `/v1/models/:model/sampling` | 热替换采样配置 |
| `DELETE` | `/v1/models/:model/sampling` | 重置单模型采样配置 |
| `DELETE` | `/v1/models/sampling` | 重置全部采样配置 |
| `GET`  | `/v1/models/:model/kv-cache` | 已加载模型的 KV cache 报告 — 规划拓扑、容量处置，以及实测的前缀复用、工具声明散文、复用拒用归因 |
| `POST` | `/v1/models/download` | 从 ModelScope / HuggingFace 下载 |
| `POST` | `/v1/audio/transcriptions` | 端侧语音转文字（multipart `file`，或 JSON `audio` base64 / `file://` URL；`verbose_json` 明确拒绝而非静默忽略） |
| `POST` | `/v1/models/train` | LLM 训练 |
| `POST` | `/v1/models/evaluate` | LLM 评估 |
| `GET`  | `/v1/stats` | 运行统计（请求/Token/耗时/TTFB） |
| `GET`  | `/v1/perception` | 持久感知仪表：逐通道对照 用户投票 vs 引擎实时开关 vs 实际出帧（只出开关与时间，绝不出帧内容） |
| `POST` | `/v1/multimodal/capture` | 摄像头 / 麦克风 / 录屏捕获（`success:true` 必带数据） |
| `POST` | `/v1/multimodal/speak` | TTS 输出（需开启喇叭且有已装语音） |
| `POST` | `/v1/multimodal/status` | 开关 + 实测权限、设备/语音数、屏幕出帧证据、逐通道裁决 |
| `GET`  | `/sessions` | 会话列表 |
| `GET`  | `/sessions/:id/memory` | 获取会话记忆事件 |
| `DELETE` | `/sessions/:id` | 删除会话 |
| `GET`  | `/sessions/search` | 会话全文搜索 |
| `GET`  | `/skills` | 列已注册技能 |
| `POST` | `/mcp` | MCP JSON-RPC 端点 |
| `GET`  | `/health` | 存活检查 |
| `GET`  | `/ready` | 就绪探针（`ready`/`busy`） |
| `GET`  | `/metrics` | Prometheus 指标（文本格式） |

> 免认证 public 路由：`/health`、`/ready`、`/v1/models`、`/v1/tools`、`/v1/capabilities`、`/v1/stats`、`/metrics`（与 `AuthMiddleware.publicPaths` 一致）。所有 `PATCH`/`DELETE` 需 admin key（`OCOREAI_ADMIN_KEYS`）。
> 模型 id 里的 `/` 写成 `%2F`。


> 其余路由在设了 `OCOREAI_API_KEYS` 之后一律要 API key —— **包括 `GET /v1/perception`**：它不在 `AuthRoutePolicy.publicPaths` 里，所以是带鉴权的。该集合是这份名单的唯一真源，两者分叉时 `make docs-check` 的 P10 会判红。

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

> **环境变量全参考**：运行时表面积为 **30 个环境变量**（22 个静态 `environment["KEY"]` 字面量 + 8 个经常量/访问器/插值前缀读取，如 `HttpBridgePolicy.envVar`、`ConfigSystem.applyEnvOverrides`），横跨 server/auth/backend/agent-approval/model-store/HF/ModelScope/web tools。见 [`.env.example`](.env.example) — 每个键附代码出处默认值（行号引用）。守卫测试集（`EnvKeysDocumentationTests`）在文件与代码实际读取集漂移时即编译红。

显存预算自 `sysctl hw.memsize` 自动检测；默认保护档 `balanced` = 物理 RAM 的 55%（档位：safe 40% / balanced 55% / aggressive 75%，下限 4 GB）。

支持的推理后端：`coreai`（macOS 27+ SDK，需 `#available` 运行时检查）与 `mlx`（Metal）。默认 `backend.preference` 顺序为 `["coreai", "mlx"]` — 取第一个可用后端（可在 `~/.ocoreai/config.yaml` 覆盖）。

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
| **本地化** | `Localization/` | i18n（en、zh-Hans 全表；ja、ko、fr、es 已在 `OCALocale` 定义但无翻译表，未进 UI 选择器） |

---

### 安全

- **网络** — 仅绑定 `127.0.0.1`。非回环地址未设 `OCOREAI_API_KEYS` 时**拒绝启动**（`ServerAuthGate`）。无外部地址暴露。
- **认证** — 环境变量 `OCOREAI_API_KEYS`（逗号分隔）开启，PATCH/DELETE 另需 `OCOREAI_ADMIN_KEYS`；为空则不认证。非 YAML 键。
- **速率限制** — Token-bucket 令牌桶限流器，可配置 burst/window。
- **ContentGuard** — 三阶段输入/输出内容过滤。
- **StructuredLogger** — 结构化审计跟踪、日志轮转。
- **全局崩溃处理** — 未捕获异常或 POSIX 信号（segv/abort/bus）时，写入结构化崩溃日志到 `~/Library/Application Support/ocoreai/logs/` 后退出。
- **并发安全** — Swift 6 严格并发，scheduler/tool registry/inference engine 的 actor 隔离；`@unchecked Sendable` 声明均附并发理由注释。

---

### 状态

逐特性状态 + commit 引用在 `CHANGELOG.md`。截至本 commit 的稳定事实：

- **权威门**：CI 的 `build-and-test` 腿（`macos-26`，`make test-ci` → `xcodebuild` → `xctest`）。本机也能跑全量：`make test-clt` —— 历史上的拦路石是 agent 沙箱，从来不是平台（见 `AGENTS.md` § Build / Test / Lint），所以关于行为的结论要实测，不许拿「环境噪声」当免检理由。本文不记滚动测试数：每个 commit 都在动，重数只需一条命令（`grep -rE \'^[[:space:]]*@Test\' Tests | wc -l`）。
- **CI**：腿的清单见上方 Known boundaries；实时状态看顶部徽章。本文刻意不写「某 SHA 全绿」—— 那句曾在本文件里自相矛盾（一处说 `xcode-27` 红、另一处说绿），而两条都不在克隆里可复核。

---

### Build Info

- Swift 6.2 · SwiftUI · Hummingbird 2.26
- 声明 `.macOS(.v14)` / `.iOS(.v17)` · Apple Silicon · 纯 SwiftPM —— 实机执行于 macOS 26;iOS 仅编译验证(`generic/platform=iOS`),未运行过
- 质量门：`make test-ci`（xcodebuild 路径，macOS-26 腿为权威）；ocoreai 源码 0 警告（依赖 bundle 噪声除外）
---

### License

MIT — Copyright © 2026 uingei@163.com

MIT 只覆盖 ocoreai 自身代码。产品中携带的第三方代码各自保留其条款，许可全文随产物一同分发（`ocoreai.app/Contents/Resources/THIRD-PARTY-LICENSES/`），并在 GUI 内可直接查看：**设置 → 关于 → 第三方许可**。

- **源自 Apple 的代码** — BSD-3-Clause。`Sources/` 下 44 个文件保留 Apple 版权头及其 BSD-3 声明原文（`git grep -l "Copyright 2026 Apple Inc" -- Sources`；其中 29 个注明 `coreai-models`，其余为来自其他 Apple 代码树的 Apple 原创文件），上游 LICENSE 原文以 `THIRD-PARTY-LICENSES/Apple-coreai-models.txt` 打包，收集时已与上游逐字节比对。
<!-- claim:apple_derived_files>=44 :: git grep -l "Copyright 2026 Apple Inc" -- Sources | wc -l -->
<!-- claim:apple_coreai_named>=29 :: git grep -l "Copyright 2026 Apple Inc" -- Sources | xargs grep -l coreai-models | wc -l -->
- **34 个 SwiftPM 依赖** — 29 个 Apache-2.0 + 5 个 MIT，逐个附全文；索引见 `THIRD-PARTY-LICENSES/NOTICES.md` / `THIRD-PARTY-LICENSES/manifest.json`（该目录共 38 个文件：34 份依赖全文 + Apple + dlpack + `NOTICES.md` + `manifest.json`）。
<!-- claim:spm_deps=34 :: grep -c '"identity" : ' Package.resolved -->
<!-- claim:notice_files>=38 :: ls THIRD-PARTY-LICENSES | wc -l -->
- **随库头文件** — `Sources/lib/CXGrammar/include/dlpack/dlpack.h`，来自 dmlc/dlpack（Apache-2.0），全文以 `Vendored-dlpack-Apache-2.0.txt` 打包。`Sources/lib/` 下任何属于其他权利人的头文件都必须登记进该表，否则 CI 的 Class-I 直接失败。
- **openai/codex** — 仅作语义参照：Rust 实现、未被链接、不重分发源码，因此不打包其许可文本。
- **Apple 系统框架** — 由 macOS 运行时链接，不随本应用重分发。

发布前刷新：`bash scripts/collect-third-party-licenses.sh`（任一依赖缺文本时打包直接失败；CI 里 `ThirdPartyNoticesTests` 锁住同一条规则）。
