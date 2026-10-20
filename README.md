# ocoreai — An Agent for Open Models. Natively Local.

**Built for creativity, work, and code** — a complete agentic system designed for coding and knowledge work: one Swift 6.2 binary on macOS/iOS: on-device inference (MLX Metal + CoreAI, upstream-derived), agent tool loop, session memory, Apple-native multimodal I/O, and an OpenAI/Anthropic-compatible HTTP gateway — single process, no IPC.

[![swift 6.2](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://www.swift.org)
[![macOS 14+ / iOS 17+](https://img.shields.io/badge/macOS%2014%20%7C%20iOS%2017-blue.svg)](https://www.apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/uingei/ocoreai/actions/workflows/ci.yml/badge.svg)](https://github.com/uingei/ocoreai/actions/workflows/ci.yml)

---

### Quick Start

**macOS 14+ · iOS 17+ · Apple Silicon · Swift 6.2 · Pure SwiftPM**

**用户路径 — 双击即用:**
下载 [最新 Release](https://github.com/uingei/ocoreai/releases/latest) 的 `ocoreai-<ver>.dmg` → 打开 → 拖 `ocoreai` 到 `Applications` → 启动。模型在 App「模型」页推荐列表中首启下载（推荐列表已内置）。

> 首次启动: 当前 DMG 为 ad-hoc 签名(未公证)。若 Gatekeeper 提示"无法打开",在 Finder 的 `Applications` 里**右键 ocoreai → 打开 → 打开**即可,仅需一次。

**开发者路径 — 源码构建 + HTTP 桥:**

```bash
git clone https://github.com/uingei/ocoreai.git && cd ocoreai
swift build -c release     # 或 make app
swift run ocoreai serve    # headless：引擎 + HTTP 桥，无窗口
# or: bash scripts/build-dmg.sh   # 本地出 DMG
```

```bash
curl -s http://127.0.0.1:8080/health
# { "status": "ok", "timestamp": 1714800000, "engineSummary": { "loadedModels": 0, "activeSessions": 0, ... } }
```

Direct SwiftPM build, no `.xcodeproj` (the test gate runs through the SPM `ocoreai.xcworkspace` → `xcodebuild` → `xctest`).
**Headless HTTP entry: `ocoreai serve`** (`swift run ocoreai serve`, or the built binary directly) — boots the engine + bridge on `127.0.0.1:8080` with no GUI/WindowServer session. Shutdown: `SIGTERM` or closing stdin drains the engine (≤30s) then exits clean; `SIGINT` keeps default terminal behavior. Bare `ocoreai` launches the GUI as before. Server listens on `127.0.0.1:8080`. Config at `~/.ocoreai/config.yaml`.
DMG 安装的 App Store build 默认只开 GUI（Fast Path）；HTTP 桥需显式 opt-in — 终端运行 `OCOREAI_ENABLE_HTTP=1 /Applications/ocoreai.app/Contents/MacOS/ocoreai`（实证：bridge 日志出现 + `/health` 200 + `/v1/chat/completions` 推理闭环）。无头启动走 `ocoreai serve`：引擎 + 桥绑定 `127.0.0.1:8080`，无需窗口会话；`SIGTERM` 或关闭 stdin 触发优雅退出（引擎排空 ≤30s），`SIGINT` 保持终端默认行为。

> ⚠️ **Localhost-only** — The HTTP API binds to `127.0.0.1` by default. **Auth is off unless** the `OCOREAI_API_KEYS` env var is set; **no TLS**. Token-bucket rate limiting is on by default: global **200 req/s** (burst 300), per-model 30/s (burst 45), per-IP 20/s (burst 30) — set once at `App.swift:703`, enforced by `Middleware/RateLimitMiddleware.swift`.
<!-- claim:global_rate_set=1 :: grep -c 'globalRate: 200' Sources/ocoreai/App.swift -->
<!-- anchor:. Sources/ocoreai/App.swift:703 globalRate: 200 -->

> 🛠️ **Dev release** — This is a development build. Production use requires additional hardening (see Security section below).

---

### Lifecycle

- **Update**: Settings → About → “Check for Updates…” compares the running
  build against the latest GitHub release and opens the release page — the
  user decides, never a silent download.
- **Uninstall**: `scripts/uninstall.sh` (dry run by default) prints the full
  footprint in tiers — regeneratable caches/logs, user data (sessions/config),
  model weights, the app itself — and removes only the tiers you select with
  `--data / --userdata / --models / --app / --all`. Weights are 100s of GB:
  they are never touched unless you ask. No keychain entries exist by design
  (env-first tokens, mirroring mlx-swift-lm/coreai-models).

### What's in here

One process: inference (MLX Metal + CoreAI, upstream-derived) + agent loop (tool calling, skills, session memory via SQLite/FTS5) + HTTP gateway (OpenAI/Anthropic-compatible endpoints, table below) + native multimodal I/O (camera/screen/audio/OCR/STT/TTS, all Apple-native) + MCP bridge (stdio).

Capability detail lives where it's kept current: `CHANGELOG.md` (per-feature, with commit refs) and the upstream repos it tracks — [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm), [coreai-models](https://github.com/apple/coreai-models), [codex](https://github.com/openai/codex).

Known boundaries (as of this commit, not aspirations):

- **Perception & TTS are off by default** — per-channel toggles in Settings; camera/screen/speaker also need OS permissions.
- **TTS/STT require microphone permission**; screen capture is macOS-only.
- **i18n**: en + zh-Hans shipped (full tables); ja/ko/fr/es defined in `OCALocale` but not in `availableLocales` (no table yet).
- **CI**: six legs — `governance` (ubuntu-latest), `audit` (macos-26: static audit, docs contract, line-cite anchors, toolchain contract, resolved-sync, swift-format, secret scan), `build-and-test` (matrix `macos-26` + `xcode-27`), `release` (macos-26 DMG), `build-appstore` (macos-26), `build-ios` (macos-26). **macOS-26 is the delivery gate.** This file states which legs exist, not whether they are green: a SHA-pinned "last green" claim rots on the next push and cannot be re-checked from a clone — the sentence this one replaces said both legs pass, while `README.zh.md` called `xcode-27` red in one bullet and green in another. Live status = the badge above and the run for this SHA; per-item verdicts = `CHANGELOG.md`.
- **Status rows that were ✅ by code audit do not guarantee runtime behavior** — treat as "implemented in source", verified where a test exists.

**Direction** — an agent for open models, natively local, built for creativity, work, and code; a complete agentic system designed for coding and knowledge work. **Coding** is the deepest slice: a Coding/Computer Agent that reliably completes multi-step engineering tasks on-device (**Execute** → **Verify** → **Recover**). Creativity (Apple-native perception/multimodal) and knowledge work (research, reading, writing) are first-class product surfaces, not afterthoughts. Inference stays upstream (MLX / CoreAI); ocoreai is the reliable execution layer above it — follow upstream, don't compete.

**References** — [Apple Developer Documentation](https://developer.apple.com/documentation/), [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) (inference, SPM pin), [coreai-models](https://github.com/apple/coreai-models) (CoreAI path reference), [codex](https://github.com/openai/codex) (agent semantics), [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines) — plus [vLLM](https://github.com/vllm-project/vllm) / [vLLM-Metal](https://github.com/vllm-project/vllm-metal) / [SGLang](https://github.com/sgl-project/sglang) as serving-system reference, [omlx](https://github.com/omlx-ai/omlx) as production-grade reference, [OpenClaw](https://github.com/steipete/clawd) and [Hermes Agent](https://github.com/NousResearch/hermes-agent) as agent-platform reference.

---

### API Endpoints

| Method | Endpoint | Purpose |
|------|------|------|
| `POST` | `/v1/chat/completions` | OpenAI chat (streaming + non-streaming, tool calls) |
| `POST` | `/v1/completions` | OpenAI legacy completions endpoint (prompt in) |
| `POST` | `/v1` | Auto-route: dispatches by body key (`prompt`→completions, else chat) |
| `POST` | `/v1/messages` | Anthropic messages + tool use + thinking |
| `POST` | `/v1/messages/count_tokens` | Anthropic pre-flight: sizes the request `/v1/messages` will send (a floor) |
| `POST` | `/v1/count-tokens` | Token count of the text you send (`prompt` / `input` / `messages`) |
| `POST` | `/v1/embeddings` | Local embeddings (LFM2.5-Embedding-350M, 1024-dim) |
| `GET`  | `/v1/tools` | Agent tool surface, paste-ready OpenAI `tools[]` shape |
| `GET`  | `/v1/capabilities` | Device capability matrix (measured, not merely compiled) + tokenizer backend (`real`/`heuristic`) + endpoint index |
| `POST` | `/v1/steer` | Interject into a live turn (or queue for the next) |
| `GET`  | `/v1/models` | Model registry |
| `GET`  | `/v1/models/:model/sampling` | Get sampling config |
| `PATCH` | `/v1/models/:model/sampling` | Hot-swap sampling config |
| `DELETE` | `/v1/models/:model/sampling` | Reset single model sampling |
| `DELETE` | `/v1/models/sampling` | Reset all sampling |
| `GET`  | `/v1/models/:model/kv-cache` | KV cache report for a loaded model — planned topology, capacity disposition, and the measured prefix-reuse / tool-prose / reuse-refusal accounting |
| `POST` | `/v1/models/download` | Download from ModelScope / HuggingFace |
| `POST` | `/v1/audio/transcriptions` | On-device speech-to-text (multipart `file`, or JSON `audio` base64 / `file://` URL; `verbose_json` refused by name, not silently ignored) |
| `POST` | `/v1/models/train` | LLM training |
| `POST` | `/v1/models/evaluate` | LLM evaluation |
| `GET`  | `/v1/stats` | Ops statistics (requests/tokens/duration/TTFB) |
| `GET`  | `/v1/perception` | Persistent-perception gauge: per channel, user vote vs live engine flag vs actual frame flow (flags + ages, never frame content) |
| `POST` | `/v1/multimodal/capture` | Capture camera / microphone / screen (`success:true` only with bytes) |
| `POST` | `/v1/multimodal/speak` | TTS output (needs speaker enabled + an installed voice) |
| `POST` | `/v1/multimodal/status` | Toggles + measured permissions, device/voice counts, screen delivery evidence, per-channel verdicts |
| `GET`  | `/sessions` | List sessions |
| `GET`  | `/sessions/:id/memory` | Get session memory events |
| `DELETE` | `/sessions/:id` | Delete session |
| `GET`  | `/sessions/search` | Full-text search sessions |
| `GET`  | `/skills` | List registered skills |
| `POST` | `/mcp` | MCP JSON-RPC endpoint |
| `GET`  | `/health` | Liveness check |
| `GET`  | `/ready` | Readiness probe (`ready`/`busy`) |
| `GET`  | `/metrics` | Prometheus metrics (text format) |

> Public (no auth): `/health`, `/ready`, `/v1/models`, `/v1/tools`, `/v1/capabilities`, `/v1/stats`, `/metrics` — the discovery surface, matching `AuthMiddleware.publicPaths`. Admin key (`OCOREAI_ADMIN_KEYS`) required for all `PATCH`/`DELETE`.

> Everything else needs an API key once `OCOREAI_API_KEYS` is set — **including `GET /v1/perception`**, which is keyed because it is absent from `AuthRoutePolicy.publicPaths`. That set is the one home for this list; P10 of `make docs-check` fails if the two diverge.

> **Measured, never inferred.** `GET /v1/models` carries per-model disclosure keys — `vlm`, `contextLength`, `capabilities`, `videoInput`/`videoEvidence`, `toolCallDelivery`/`toolCallEvidence` (`parsed` | `prose_only` | `not_observed`) — and `GET /v1/capabilities` publishes the same measurements aggregated, plus `tokenizerBackend` (`real`/`heuristic`) and the endpoint index. Nothing is inferred from an architecture name or a linked framework: an unmeasured capability is an explicit `not_observed`/`unknown`, never a silent absence, and unloading a model resets its claims. Model ids contain `/`, so percent-encode them in `/v1/models/:model/…` paths.

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
    policy: "max"                  # max | sum | budget | fixed

models:
  default:
    enabled: true
    modelId: "mlx-community/gemma-4-e2b-it-4bit"
    source: modelscope       # "huggingface" forces the HF path; any other value → default hub (modelscope)

memory:
  enabled: true              # session memory (SQLite FTS5 + LLM compression)
```

> **Auth** is not a YAML key: set the `OCOREAI_API_KEYS` env var (comma-separated) to enable it; empty = unauthenticated.

> **Full env-var reference**: the runtime surface is **23 environment variables** (17 static `environment["KEY"]` literals + 6 read through a constant or interpolated prefix, e.g. `HttpBridgePolicy.envVar`, `ConfigSystem.applyEnvOverrides`) spread across server/auth/backend/agent-approval/model-store/HF/ModelScope/web tools. See [`.env.example`](.env.example) — every key with its code-source default value (line-cited). A guard test set (`EnvKeysDocumentationTests`) fails the build if the file ever drifts from what the code actually reads.

Memory budget auto-detected from `sysctl hw.memsize`; default guard tier is `balanced` = 55% of physical RAM (tiers: safe 40% / balanced 55% / aggressive 75%, custom 20–85%, floor 4 GB). OOMGuard then enforces the downgrade chain 8-bit → 4-bit → refuse (no CPU tier on UMA) — no disk I/O, the correct approach for Apple Silicon UMA.

Supported backends: `coreai` (macOS 27+ SDK, requires `#available` runtime check) and `mlx` (Metal). Default `backend.preference` order is `["coreai", "mlx"]` — first available backend wins (override in `~/.ocoreai/config.yaml`).

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
- **Auth** — env var `OCOREAI_API_KEYS` enables it; `OCOREAI_ADMIN_KEYS` gates PATCH/DELETE. Empty/absent = auth off. **Non-loopback bind without auth is refused** (`ServerAuthGate`). Not a YAML key.
- **Rate limiting** — Token-bucket rate limiter with configurable burst/window.
- **ContentGuard** — 3-stage input/output filtering for sensitive content.
- **StructuredLogger** — Structured audit trail, log file rotation.
- **Global crash handler** — On uncaught exception or POSIX signal (segv/abort/bus), writes structured crash log to `~/Library/Application Support/ocoreai/logs/`, then exits.
- **Concurrency** — Swift 6 strict concurrency, actor isolation on scheduler/tool registry/inference engine. `@unchecked Sendable` declarations carry concurrency justification comments.

---

### Status

Per-feature status with commit refs lives in `CHANGELOG.md` — a pinned ✅ table here would go stale on every commit. What is stable as of this commit:

- **Authoritative gate**: the CI `build-and-test` leg on `macos-26` (`make test-ci` → `xcodebuild` → `xctest`). Locally the same suite runs through `make test-clt` — the historical blocker was the agent sandbox, never the platform (`AGENTS.md` § Build / Test / Lint), so a claim about behaviour gets measured here rather than excused as environment noise. No rolling test count: it moves on every commit, and re-counting is one command (`grep -rE '^[[:space:]]*@Test' Tests | wc -l`).
- **Local builds** compile clean: ocoreai source 0 warnings (dependency-bundle noise aside).
- **Default-off surfaces** (deliberate, not missing): perception channels, TTS/speaker, self-correction pipeline — see "Known boundaries" above.

### Build Info

- Swift 6.2 · SwiftUI · Hummingbird 2.26
- macOS 14+ / iOS 17+ · Apple Silicon · pure SwiftPM
- No `.xcodeproj` — the test gate runs through the SPM `ocoreai.xcworkspace` → `xcodebuild` → `xctest`

---

### License

MIT — Copyright © 2026 uingei@163.com

MIT covers ocoreai's own code. The product also carries third-party code under its own terms, and those texts travel inside the artifact (`ocoreai.app/Contents/Resources/THIRD-PARTY-LICENSES/`), readable in the GUI under **Settings → About → Third-Party Notices**:

- **Apple-derived source** — BSD-3-Clause. 44 files under `Sources/` retain Apple's copyright notice plus its verbatim BSD-3 header (`git grep -l "Copyright 2026 Apple Inc" -- Sources`; 29 of them name `coreai-models`, the rest are Apple-authored files from other Apple trees), and the verbatim upstream LICENSE ships as `THIRD-PARTY-LICENSES/Apple-coreai-models.txt` — byte-compared against upstream at collection time.
<!-- claim:apple_derived_files>=44 :: git grep -l "Copyright 2026 Apple Inc" -- Sources | wc -l -->
<!-- claim:apple_coreai_named>=29 :: git grep -l "Copyright 2026 Apple Inc" -- Sources | xargs grep -l coreai-models | wc -l -->
- **34 SwiftPM dependencies** — 29 Apache-2.0 + 5 MIT, full text each; index in `THIRD-PARTY-LICENSES/NOTICES.md` / `THIRD-PARTY-LICENSES/manifest.json` (38 files in that directory: 34 dependency texts + Apple + dlpack + `NOTICES.md` + `manifest.json`).
<!-- claim:spm_deps=34 :: grep -c '"identity" : ' Package.resolved -->
<!-- claim:notice_files>=38 :: ls THIRD-PARTY-LICENSES | wc -l -->
- **Vendored header** — `Sources/lib/CXGrammar/include/dlpack/dlpack.h`, from dmlc/dlpack (Apache-2.0); text ships as `Vendored-dlpack-Apache-2.0.txt`. Any header under `Sources/lib/` with another holder must be added to that table — CI Class-I fails otherwise.
- **openai/codex** — semantic reference only: Rust, never linked, no source redistributed, so no codex license text ships.
- **Apple system frameworks** — linked by macOS at runtime, not redistributed.

Refresh before a release: `bash scripts/collect-third-party-licenses.sh` (packaging fails if any dependency has no text; `ThirdPartyNoticesTests` pins the same rule in CI).
