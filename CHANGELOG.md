# Changelog

## [Unreleased]

### Added
- **v15 Core AI API Alignment** — two-phase model loading + cache + compute targeting
  - `CoreAIBridge.swift`: Official `AIModelAsset → specialize → AIModel` pipeline
  - `CoreAIModelLoader.swift`: `actor`-isolated loader with `AIModelCache` & `SpecializationOptions`
  - `CoreAILoadingConfig.production`: cache enabled, auto compute unit routing, fallback to `EngineFactory`
  - `LoadedModel` now stores `CoreAIPreparedModel` (specialization result tracked at load time)
  - Apple CoreAI API coverage: ~17% → ~45%

- **KV Cache Integration (v13 P1)**: ``KVCacheManager`` wired through ``EnginePool`` lifecycle
  - ``EnginePool`` accepts ``kvCacheConfig: KVCacheManager.Config?`` (nil = disabled)
  - Session registration on ``acquire()`` (``registerZeroSession()`` for GPU tracking)
  - ``handle.markActive()`` resets idle eviction timer before inference
  - ``EngineHandle.release()`` unregisters session from KV cache
  - ``EnginePool.shutdown()`` cold-stores all active sessions to SSD before unload
  - ``EngineSummary.gpuCacheGB`` exposes live GPU cache usage via ``GET /health``
- **prod_metrics**: Native Prometheus-compatible `/metrics` endpoint (zero external deps)
  - `ocoreai_http_requests_total` — HTTP request counter (method/path/status labels)
  - `ocoreai_inference_duration_seconds` — Inference histogram
  - `ocoreai_ttfb_seconds` — Time-to-first-byte histogram
  - `ocoreai_engine_pool_active_sessions` — Active sessions gauge
  - `ocoreai_engine_pool_loaded_models` — Loaded models gauge
  - `ocoreai_kv_cache_gpu_bytes` — GPU cache gauge
  - `ocoreai_kv_cache_evictions_total` — KV eviction counter
  - `ocoreai_inference_tokens_total` — Token counter (prompt/generated)
- `AuthMiddleware` public path whitelist includes `/metrics` for unauthenticated scraping
- `GracefulShutdown` with 30s drain timeout and force-kill on expiry
- Runtime sampling parameter hot-swap via `PATCH /v1/models/:model/sampling`
- Tool calling support with SSE streaming
- Rate limiting: global, per-model, per-IP token bucket

### Architecture
- Pure Swift on Apple Core AI — zero Python dependency
- Hummingbird 2.0 with strict concurrency (Swift 6.0)
- `EnginePool` actor with per-model `LoadedModel` state
- `TokenizerManager` with Rust-backed tokenizers
- Actor-isolated `MetricsRegistry` for thread-safe metric collection
- **v12 actor migration**: `KVCacheManager`, `TokenBucket`, `RateLimitProvider` converted from `@MainActor class` to `actor` (server-side mailbox isolation, no MainActor dependency)
