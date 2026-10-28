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
  `ServerStatsSnapshot.kvCacheBytes` → Dashboard `kvCacheGB` (DashboardViewModel.swift:107). Upstream `mlx-swift-lm`'s
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

- **Loop claims needed a fake provider, not a Metal load — shipped.** Every comparator tree judged its
  loop against a fake long before we did: codex on a `wiremock` server (`core/tests/suite`, 260 files),
  hermes-agent on per-provider fakes with replay JSONL (`tests/fakes/providers/`), pi on a faux provider
  under "No real provider APIs, keys, or paid tokens" (`packages/coding-agent/test/suite/harness.ts`),
  opencode on recorded HTTP (`packages/http-recorder`). Ours is `Engine/ScriptedInference.swift`: same
  routes, same SSE, deterministic tool calls, `engineBackend: scripted` on `/v1/capabilities`,
  `ScriptedEngineTests`(5) + probe 37, and the scoreboard refuses to score a replayed run. The round and
  its red-samples are `CHANGELOG.md`'s.

- **The bytes the injected corpus spends are priced — measured, not reviewed.** § Documentation Map has
  long demanded "an inference regression" for injected text while no instrument by that name existed, so
  the demand was a claim pointed at the file that states it (pi runs paired `without_docs`/`with_docs`
  containers — `packages/evals/README.md:1-14`). The instrument is now
  `OCOREAI_EVAL_DOCS=none|root` + `_repeat_stats.py --a/--b`, and it produced numbers twice on the first
  day. Recorded pair (artefact built from the tree being scored, root doc 21,529 B, k=3 per arm on the
  same 39 tasks / 6 tools / checkpoint): **25.00 → 16.33/39, Δ −8.67 tasks (−22.2 pp), McNemar exact
  two-sided p < 0.0001**, b = 29 / c = 3. Replicate pair (hours earlier, then-current artefact, 21,548 B):
  **24.67 → 17.00/39, Δ −7.67 (−19.7 pp), p = 0.0003**, b = 31 / c = 8 — so the quote is a range,
  −19.7 to −22.2 pp. The premise floor passed every `root` run (39 assembled prompts, `systemChars`
  24,630–25,587 ≥ the doc's bytes), so the doc demonstrably arrived. Three mechanisms, each read off a
  trace: the doc becomes an *edit target* (`edit-replace-all`: "I failed to replace \"FOO\" with \"BAR\" in
  AGENTS.md", identical in both pairs); long context *degrades the tool call* (`fix-boundary-comparison`
  typed `edit_file(path=…` into the text channel where the doc-free arm passed 3/3); and *narration
  displaces tool use* (mean answer 63 B → 100 B, median 27 → 36, with the workspace unchanged). Improvement
  is not established: two tasks went 0/3 → 3/3 in the replicate and none did in the recorded pair. What it
  settles: the corpus is not free (21.5 KB/turn costs about what all 40 tool declarations cost, −18.8 pp),
  `without_docs` is the board's real history, the artefact now has to be named (`binary=<name>+<mtime>+
  <bytes>`) because a stale one was silently judging a newer tree, and an unpaired run is worth ±2 tasks
  even on identical conditions. What it does not settle is the shape of the curve —
  `docs/agent/open-items.md`. Numbers, red samples, reproduce command: `CHANGELOG.md` 10-27(24),
  `scripts/eval/README.md`.
