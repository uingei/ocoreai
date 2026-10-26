# Closed, once — why these are not open items

> Material `AGENTS.md` § *Open* used to carry prose for although it was resolved, retracted or
> judged a phantom gap. An open item is one that can still change a decision; a verdict is
> history, and history kept in the injected layer costs every session.
- **HTTP token-count surface (`/v1/count-tokens` + `/v1/messages/count_tokens`) — shipped and closed.**
  The gap: only `{model,prompt}` decoded, so OpenAI's `input` and Anthropic's `messages`/`system` got 400,
  `/v1/messages/count_tokens` was a plain 404 (every Anthropic SDK pre-flight budget call died), and the
  404 hint pointed at `/v1/capabilities` with no index behind it. Landing and acceptance are
  `CHANGELOG.md`'s, not this file's — two copies of a verdict drift.
  One part is **still open**, and it is not history: the model's own tokenizer remains the sole authority
  on a count, never cross-checked against a third-party implementation, and the
  `tokenizer_backend: heuristic` branch (tokenizer absent only) has no assertion on its estimate's accuracy.

- **`kvCacheRuntimeReport`** — ~~not consumed~~ → measured: ocoreai already has its own equivalent
  consumer, `Metrics.kvCacheGpuBytes` (`ocoreai_kv_cache_gpu_bytes`, Metrics.swift:91/210) →
  `ServerStatsSnapshot.kvCacheBytes` → Dashboard `kvCacheGB` (DashboardViewModel.swift:107). Upstream's
  `KVCacheRuntimeReport` (KVCacheConfiguration.swift:486) is a second wrapper, and #248 judged the bug
  absent here — adopting it would only build a duplicate local surface. Not done, on purpose.

- **MLXFoundationModels** — the FM lane is wired (`#if FoundationModelsIntegration &&
  canImport(FoundationModels, _version: 2)`, on by default at Package.swift L26).
  ~~lacks per-token callback on FM `.done`~~ → measured phantom gap: per-token delivery runs
  `yieldParserEvents → continuation.yield` over an AsyncStream (EngineInference.swift:430-470, same shape
  as the std MLX lane) and does not depend on `.done`, which is only a terminal signal. Upstream has zero
  `onStreamChunk` concept — retracted as a phantom.

<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/KVCacheConfiguration.swift:486 public struct KVCacheRuntimeReport -->
<!-- anchor:. Sources/ocoreai/Metrics/Metrics.swift:91 private var kvCacheGpuBytes -->
