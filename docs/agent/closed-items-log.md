# Closed, once — why these are not open items

> Material `AGENTS.md` § *Open* used to carry prose for although it was resolved, retracted or
> judged a phantom gap. An open item is one that can still change a decision; a verdict is
> history, and history kept in the injected layer costs every session.
- **HTTP token-count 面（`/v1/count-tokens` + `/v1/messages/count_tokens`）— 已落码并关闭（10-14）**（Router/）
  缺口原文：只认 `{model,prompt}`，OpenAI 的 `input`、Anthropic 的 `messages`/`system` 一律 400，`/v1/messages/count_tokens` 直接 404（Anthropic SDK 的预算前置调用必挂），而 404 提示语「endpoints via GET /v1/capabilities」背后无索引。落码与验收（手解 precedence `messages`→`input`→`prompt`、与 `/v1/messages` 共用同一个
  builder、`endpoints` 索引 == 路由注册数、活体三查 `prompt_tokens:43` / `input_tokens:22`）逐条在 `CHANGELOG.md` 10-14 那一轮，此处不复述：两处维护必漂。
  此处只留**仍未决**的一条——它不是历史，是仍开着的精度问题：计数值的绝对权威仍是模型自带 tokenizer，未与第三方实现对拍；`tokenizer_backend: heuristic` 分支只在 tokenizer 缺失时生效，其估算精度没有独立断言。

- **`kvCacheRuntimeReport`** — ~~not consumed~~ → 09-22 实证：ocoreai 走**自有等价消费面** `Metrics.kvCacheGpuBytes`(`ocoreai_kv_cache_gpu_bytes`, Metrics.swift:91/210)→ `ServerStatsSnapshot.kvCacheBytes` → Dashboard `kvCacheGB`(DashboardViewModel.swift:107)。上游 `KVCacheRuntimeReport`(KVCacheConfiguration.swift:486) 是另一套 wrapper，#248 已判
ocoreai 无此 wrapper 的 bug —— 接它 = 本地重复面，不做。

- **MLXFoundationModels** — FM 路 wired（`#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)` + Package.swift L26 默认开）。 ~~lacks per-token callback on FM `.done`~~ → 09-22 实证假缺口：per-token 走 `yieldParserEvents → continuation.yield` AsyncStream（EngineInference.swift L430-470 等，与 std MLX 路同构），不依赖
`.done` 回调（`.done` 只是收尾信号）。上游 0 处 onStreamChunk 概念——此条 phantom gap 撤回。

<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/KVCacheConfiguration.swift:486 public struct KVCacheRuntimeReport -->
<!-- anchor:. Sources/ocoreai/Metrics/Metrics.swift:91 private var kvCacheGpuBytes -->
