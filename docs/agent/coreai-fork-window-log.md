# coreai-models fork — the per-commit verdict ledger

The verdicts themselves: one row per upstream commit, read against this tree. The rule, the verdict key
and the priority queue of what is still owed live in `coreai-fork-adjudication.md`; `make drift`
recomputes the counts from each file's header, so nothing here carries a number a command can derive.

## One row per commit

| upstream sha | PR | what coreai-models did | verdict | evidence in our tree |
|---|---|---|---|---|
| `27a66f9` | #227 | `InputLayout` name resolution for shared descriptor analysis | absorbed | `Engine/InputLayout.swift` + `CoreAIPipelinedEngine.swift`, `CoreAISequentialEngine.swift:130`; recorded as `Absorbed: #227` |
| `62ff88b` | #237 | cap pipelined prefix reuse to `processedTokenCount` (pipelined decode yields the last token unprocessed) | absorbed | `CoreAIPipelinedEngine.swift:186-189` caps, re-slices `resolvedNewTokens`, truncates history |
| `89ba0d4` | #251 | VLM tidy B3+B4: shared `SequentialIterator` | absorbed | ocoreai `3497ae8`; `SequentialIterator.clampMaxTokens`/`nextToken` at `CoreAISequentialEngine.swift:596,667` and `CoreAISequentialVLMEngine.swift:1119,1199` |
| `675437b` | #359 | detect byte-fallback vocabularies instead of assuming `.byteLevel`; JSON whitespace policy | absorbed (vocab half) | `GuidedGeneration/TokenizerInfo.swift:29` `VocabularyType.detect`, `ConstrainedGenerationSession.swift:65-71` defaults to it, adapter `Tokenizer/TokenizersMLXTokenizerAdapter.swift:38`. The whitespace half is #368 |
| `257008b` | #250 | async request queue in `llm-server` | n/a | CLI queue over their runner; ocoreai's admission path is `Scheduler/` (`SchedulerActor`, `AdmissionGate`) in front of the `EnginePool` actor — the engine-file edits are the protocol ripple |
| `b11ac19` | #188 | `StaticInputHandler` protocol for zero-allocation input filling | n/a | 0 hits for `StaticInputHandler` in `Sources/ocoreai` — our static-shape copy fills inputs on its own path |
| `6441c8c` | #265 | reproducible generation: `seed` + `system_fingerprint` | n/a | 0 hits for `systemFingerprint` under `Engine/`; the wire `seed` surface is served by the MLX lane (`Handlers/CompletionsHandler.swift`, `Handlers/ChatHandler.swift`) |
| `82c3488` | #354 | KV-state handling: static caches out of the sliding path, ring read-before-write, `additionalStates` on the constrained encode | n/a | 0 hits for `slidingRingCapacity`/`checkWriteFirstStep` — our fork never took the ring path, so the mis-classification has no home here; and the constrained-encode half is structurally already correct: every CoreAI encode routes through `Engine/StateHandler+Encode.swift:30,57`, which binds `additionalStates` |
| `70daf4e` | #335 | batched-decode runtime (attention-mask path) | n/a | 0 hits for `BatchedDecodeStep` in `Sources/ocoreai` |
| `c2ef849` | #258 | idempotent generation via external session state | n/a | 0 hits for `IdempotentEngine`/`GenerationSessionState`; ocoreai's durability lives in `SessionManager` + SQLite, not in an engine wrapper |
| `09ff139` | #367 | continuous-batching scheduler (`BatchScheduler` 515 L, +Scorer 137, `SchedulerSession` 123, `BatchSessionAdapter` 64, `BatchServingRouter` 21) | n/a today, strategic | 0 hits for `BatchScheduler`. The largest capability our fork lacks — a serving feature, not a fix; taking it is a project with its own owner call |
| `1f70655` | #377 | `--concurrent-requests auto`, `/ready` batching + memory estimates in `llm-server` | n/a | their CLI/HTTP surface; our wire surface is `Handlers/` on Hummingbird |
| `1953c4f` | #332 | move the Gemma 4 PLE sidecar to the `auxiliary_assets` key of a bundle's asset manifest | n/a | export/metadata side; 0 hits for `auxiliary_assets` in `Sources/ocoreai` (we load bundles, we do not export them) |
| `13c3a1d` | #375 | choose the VLM engine from `vision.token_merge` | n/a | 0 hits for `tokenMerge` in `Sources/ocoreai` |
| `bd3c539` | #269 | unify stop-token resolution across text and VLM adapters | n/a | the unification happens in adapters and in `LanguageConfig` outside our slice; our EOS path is config/tokenizer (`CoreAIEngine.swift:156`, `CoreAIVisionConfig.swift:132`) |
| `7fd2063` | #297 | split `includeLogits` into orthogonal tokens + logits axes | **open** (API shape) | our copy threads one `includeLogits` bool through 10 files; no shipped-surface bug, but the next bump has to decide the two-axis shape rather than keep a private variant |
| `9db7476` | #351 | honour `language.states` when classifying model states | **open** | our fork decodes no `language.states` (0 hits in the config slice); the check that settles it — does any CoreAI bundle we advertise declare `states` — needs a macOS 27 host (`PlatformPremise.hasMacOS27`) |
| `7359dbc` | #249 | VLM consolidation B1+B2: shared KV cache, `GenerationTokenBox`, `runChunkedPrefill` | **open** (shape debt) | 0 hits for `GenerationTokenBox`/`runChunkedPrefill`; ours kept the inline equivalents, which is why our copy is 1 238 L while upstream's consolidated file is 1 107 L |
| `8cf3075` | #370 | Gemma 4 image input: static-shape runtime (+152 L), `LanguageConfig` (+103 L), `ImagePreprocessor` (access level) | **open** (narrow) | the `ImagePreprocessor` half is `private`→`public` only (upstream L194; ours is `private func renderToContext` at `CoreAIImagePreprocessor.swift:188`, internal callers at :91, :136, :170 — nothing to take); the runtime half sits in the ~500 L of static-shape code our slice never took |
| `8623ac6` | #302 | Gemma 4 E2B/E4B iOS runner upgrades | **open** (big) | upstream rewrote ~500 L of `CoreAIStaticShapeEngine.swift` and 89 L of `LanguageConfig.swift`; our copy is 646 L total. The largest un-absorbed change on a mirrored file — re-sync or record a permanent divergence, one or the other |
| `2704a69` | #264 | recover exported turn-end stop tokens by scanning `tokenizer.json` (`\|end\|` pattern, Gemma/Phi) | **open** | 0 hits for `end_of_turn` in `Sources/ocoreai`. A bundle whose metadata omits the turn-end token would run past it on our CoreAI lane; whether any bundle we advertise does is unmeasured here (macOS 27) |
| `f03e8ce` | #368 | cap whitespace between JSON tokens (`maxWhitespaceCount` 32 — upstream `ConstrainedGenerationSession.swift:24-27`: 15 nesting levels) | **open** — CoreAI lane only | probe 12 §5b measures OUR lane at maxWSrun 11: the guided loop already applies upstream `WhitespaceTokenBias` (-200, `EngineInference.swift:2090`), so the cap binds nothing there. Rest is the CoreAI lane — `#if canImport(CoreAI)` at `EngineInference.swift:781`, ours passes `anyWhitespace: true` at `XGrammarWrapper.swift:69` — unverifiable here |
| `5b0f350`+`957fa7b`+`dc0b0dd` | #383 #365 #376 | ChunkedEmbedding fix (Gemma-3n-E4B), eager APIs for Qwen 3.5+, Gemma 4 draft-head export | n/a | python/export side (`_constants.py`, `export/pipeline.py`, `models/macos/{gemma3n,qwen3_5}.py`, `primitives/macos/cache.py`, `models/gemma4/{export,export_drafter}.py`, `models/ios/gemma4_text.py`) — this repo has no export surface (§ Upstream 2) |
| `23308de` | #378 | speculative decoding: protocol, `SpeculativeDecoder`, prompt-lookup drafter | n/a to this lane | theirs is a CoreAI-engine subsystem (`SpeculativeDecoding/`); ocoreai's speculative decoding is MLX-only by its own marker — `Engine/LoadedModel.swift:223` "Speculative Decoding (MLX only)". On a macOS 27 host it is the CoreAI-lane speedup we do not have |
| `31484f7` | #363 | select the sequential engine for attention-mask graphs; `--batch-prototype` | n/a | our factory picks by model structure (`CoreAIEngine.swift:665-718`: dynamic → pipelined, static → static-shape) and there is no attention-mask graph path to select for (0 hits for `BatchedDecodeStep`); the rest is their CLI |
| `cc3c234` | #357 | resolve diffusion assets through a bundle's declared asset manifest so compiled bundles load | **open** | ours hardcodes the three component names (`Video/WanPipeline.swift:115,118,121`) and reads the bundle's manifest only for the `diffusion` block (:94) — the pre-fix shape, whose own comment said declared `assets` names are not consulted. No Wan bundle on this host, so whether a bundle we advertises declares other names is unmeasured; the check is one `metadata.json` read, the fix is upstream's two `resolveDeclaredPipelineAsset` helpers |
| `3e172fb` | #248 | guided generation was refused after engine load on static-shape engines: ask \`supportsLogits\` *or* \`ConstrainedGenerationCapable\`, not the constrained flag alone | absorbed | `EngineInference.swift:326` names the commit and the rule, :336 routes on `engine.supportsLogits`, and the CPU-feed loop for a logits-only engine lives at :946-953 |
| `0d6c0bf` | #240 | layered prefill chunk size | absorbed | `CoreAIEngine.swift:166` ("Layered prefill chunking (coreai-models #240, 0d6c0bf)"), applied by `:175` |
| `ed946c8` | #274 | default the 4096 prefill chunk only at >=64 GB | absorbed | `CoreAIEngine.swift:191` — "Chunking defaults (coreai-models #274, ed946c8 — layered resolution)" |
| `b63133b` | #262 | route VLM construction through `EngineFactory` (C1+C2) | n/a | their factory gained 97 L; ocoreai constructs VLM engines in its own factory (`CoreAIEngine.swift:718` `createVLMEngine`), and the VLM file's edit was the removal of inline construction our copy never had |
| `184cc35`+`7debb8d`+`684ae8e` | #255 #191 #184 | additive helpers in the mirrored `NDArray+Helpers`, each for a subsystem we do not run | n/a (measured absence) | `copyIntoNDArray`/`writeNDArrayRegion` (SAM3 video), `flattenBFloat16NDArray` (Wan 2.1), `argmaxFloat`/`forEachFloatElement`/`floatElements` (Parakeet v3) — 0 hits for all seven in `Sources/ocoreai`; our `Video/WanPipeline.swift` calls none of them, so the slice stays a slice until a consumer appears |
| `0aff938` | #385 | attention mask for SAM3 export and runtime (`ImageSegmentationEngine.swift`) | n/a | ocoreai has no image-segmentation surface (0 hits for `SAM3`/`ImageSegmentation` outside a comment) — this commit landed *during* this pass, and the axis baseline adopted today (`0aff938`) is its sha, so the row exists because the ledger noticed the gap before a human did |
| `db7823e` | #389 | qwen3_5: `narrow(1, S-1, K)` → `narrow(1, -K, K)` in `GatedDeltaNet`, graph quant re-enabled | n/a | python export side, 0 Swift § Upstream 2, 0 hits for `GatedDeltaNet` in `Sources/`; `conv_input` is `(K-1)+S` long so `S-1` and `-K` are one element: attribution, not arithmetic |

## Window read 11-03 — `7fd2063` → `ac03f2b` (16 commits)

Endpoint moved three times mid-read (`bc72ed5` → `972f001` → `c1e6d56` → `ac03f2b`). Completeness is a
census, not an impression: each commit was intersected with the 304 Swift basenames in `Sources/ocoreai`
— shared basename ⇒ a row below; none ⇒ its surface is
`llm-runner`/`llm-server`/`SpeculativeDecoding`/export-side, which this tree lacks. The census is also
how two commits turned up that **the ledger cannot see**: it enumerates `Engine/CoreAI*.swift` only, and
#374/#402 both edited mirrors outside it (their rows say so). Nothing ported, and open items 5-6 in
`coreai-fork-adjudication.md` stay open.

| upstream commit | verdict | evidence from our tree |
|---|---|---|
| `df8f817` #388 — VLM folded into `CoreAISequentialEngine` (−1 107 L file, +792 L, +549 L new vision front-end) | **open, not taken** | ~1 900 L of restructuring on a lane that cannot run: `canImport(CoreAI)` compiles out on CLT, gate `PlatformPremise.hasMacOS27`. A blind edit here is a claim |
| #388's new protocol member `acceptsMultimodalInput` ("a text bundle reports false") | **open, worth taking** | the invariant-2 fact this fork lacks: `CoreAIEngine.swift:304-308` has `isBusy`/`supportsLogits` only, per-checkpoint multimodal is config-level (`CoreAIVisionConfig.swift:49`). Not added: a flag no runnable engine measures publishes an unmeasured capability. Landing site named in that header |
| #388 + #394 in `InputEmbeddings.swift` / `LanguageConfig.swift` | **n/a** | the embeddings hunk is comment-only (scatter-merge reworded, two TODOs moved); the config hunks are at `:530` (`VisionTokenMerge`) and `:64-90` (`LanguageOverrides`) — outside the `L184-279` slice, both symbols 0 hits in `Sources/` |
| `6a6bb0e` #374 — a scored continuation ran as one `main` batch; a width-1 `main` beside a prefill graph aborts, so that asset takes the generation path | **open, macOS 27**, invisible to the ledger | it edits 5 mirrors the ledger never enumerates — `GuidedGeneration/{DecodingStrategy,ConstrainedDecodingStrategy,PipelinedConstrainedDecodingStrategy,ConstrainedGenerationSession,TokenizerInfo}.swift` — each `#if canImport(CoreAI)`; and no forced-continuation surface exists here (0 hits `evaluateRawTokens`/`evaluateContinuation`) |
| `d3382a5` #386 + `1e59152` #394 — CoreAI spec decode (`DraftProposal`, `DraftScan`, `forwardProposal{,Greedy}` → `DrafterFeatures`) | **n/a**, axis input | our drafter is the checkpoint's own MTP layers (`ConfigStruct.swift:336-337`, Gemma4); upstream exports a separate draft head — *why* is inference, #394 does not say. 0 consumers of `Drafter*`/`forwardProposal` here |
| `ac03f2b` #402 — spec-decode timings become Instruments spans; `profile { }` ends a span on every exit | **n/a**, also outside the ledger | 0 hits `SpeculativeDecoder`/`generationSeconds`/`draftSeconds` here; the mirrored half is `Engine/InstrumentsProfiler.swift` (592 L vs upstream's 909, `beginX() -> ProfileSpan` + `consuming end()`) — it compiles on the shipping lane (`canImport(CoreAI)`: 0), but no leaked span has been observed, so no wrapper |
| #382, #391, #396, #398, #399, #397, #400, #392, #403, #385, #389 | **n/a** | census: no shared basename with `Sources/ocoreai` (their surface is `llm-runner`/`llm-server`/`SpeculativeDecoding`/SAM3/export-side); #392/#397 stay colour for a CI lane whose authority is `make test-ci` on `macos-26`; #385/#389 also keep rows above |

## Window read 11-05 — `ac03f2b` → `f333cf5` (8 commits)

Completeness is the same census as the section above, not an impression: every changed path's basename ∩
the **304** Swift basenames in `Sources/ocoreai` — **0/8** commits share a name. The per-file fork ledger
agrees from the other root: 14 baselined rows, each reading 0 upstream commits in the window. Endpoint
provenance is uneven and is stated as such — 7 commits read in the local clone at `b3376e2` (`git fetch`
failed twice, curl 28, so the clone lags the axis HEAD by one commit), that eighth commit read from the
GitHub API's file list rather than a diff. Nothing ported; the open rows above stay open, including
`acceptsMultimodalInput`, #297's two-axis logits shape, #302's static-shape re-sync and #357's declared
assets.

| upstream coreai-models commit | verdict | evidence from our tree |
|---|---|---|
| `050fc8f` #404 — test-result summaries, python tests in parallel | **n/a** | `.github/scripts/test_summary.py` + `ci.yml` only; our CI authority is `.github/workflows/` on `macos-26` (`make test-ci`), which no upstream file touches |
| `048a7d4` #401 — parakeet-tdt-0.6b-v2 export | **n/a** | export/python axis (§ Upstream 2: this repo has no export surface); ∩ = 0 |
| `1286758` #408 — quantize on a chosen device, externalize composites per backend | **n/a** | `export/compression.py` +7, `export/pipeline.py` +12; ∩ = 0 |
| `181bff0` #395 — embedding modality: CLIP/CLAP bundles | **n/a** | 21 files, python export + its tests; ∩ = 0 |
| `b3376e2` #369 — EmbeddingGemma 2 export + registry entry | **n/a** | 33 files, python export + primitives/tests; ∩ = 0 |
| `5fe26cb` #410 — draft head reads the scan table in at load (`DraftScan.swift` +5) | **n/a**, axis input | follow-up to the `SpeculativeDecoding/` subsystem #378/#386/#394 already declined above: 0 files named `DraftScan.swift` under `Sources/`, and our drafter is the checkpoint's own MTP layers (`ConfigStruct.swift:336-337`) |
| `f4803f9` #409 — stop speculative decoding at single-token `--stop-tokens` | **n/a** to the lane, worth having read | `SpeculativeDecodingOptions.swift`/`LLMRunnerMain.swift`/2 tests, ∩ = 0; `Engine/LoadedModel.swift:223` marks speculative decoding MLX-only. What it settles upstream: a verify block can accept a sequence's first tokens before the stop is recognizable, so single-token stops join the stop set and multi-token ones are **named as ignored** (`SpeculativeDecodingOptions.swift:90-99`) instead of a run ending on part of one. The stall in §Open is the loop's *terminal word*, four faces — this commit does not answer that, so it is cited as precedent for naming what a lane cannot honour, not borrowed as a verdict |
| `f333cf5` #415 — ci: worksteal scheduling retries crashed workers | **n/a** | one file, `.github/workflows/ci.yml`, 10 lines — read from the API's file list, not a diff (see provenance above); our runner is our own workflow set |
