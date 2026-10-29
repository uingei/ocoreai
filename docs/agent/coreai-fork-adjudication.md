# coreai-models fork — window adjudication (read 2026-10-29, upstream `7fd2063`)

`Sources/ocoreai/Engine/CoreAI*.swift` is a **fork**, not a vendored copy: 12 files carry Apple's
BSD-3 header plus a provenance line, and the four engines differ from upstream by about
+1 609 / −2 434 lines. `make drift` asks how far each copy sits behind; the number it prints is
*unread commits touching the upstream counterpart*, which is a bookkeeping window, not a work queue.
This file is where a window gets closed: one row per upstream commit, one verdict, one piece of
evidence from **our** tree. The sha that closes a window lives in the file header
(`Adjudicated: <sha>`), the reason lives here, and unfinished verdicts are the § Open list at the
bottom — never an implicit "nothing to do".

Verdict key — **absorbed**: the change is already in our copy, with the line that proves it.
**n/a**: the surface it changes does not exist in our fork, with the grep that proves it.
**open**: it applies to something we ship (or would ship) and somebody owes an action; the action is
named. Absorbed and n/a are decisions; open is debt with a face.

## The windows as measured

| our file | upstream counterpart, all under coreai-models `swift/Sources/` | window | read through |
|---|---|---|---|
| `CoreAIPipelinedEngine.swift` (1 905 L) | `InferenceEngines/CoreAIPipelinedEngine.swift` (2 039 L) | 8 | `7fd2063` |
| `CoreAISequentialEngine.swift` (710 L) | `CoreAISequentialEngine.swift` (1 167 L) | 10 | `7fd2063` |
| `CoreAIStaticShapeEngine.swift` (646 L) | `CoreAIStaticShapeEngine.swift` (1 011 L) | 7 | `7fd2063` |
| `CoreAIVisionConfig.swift` (158 L) | `Bundle/LanguageConfig.swift` (525 L) | 6 | `7fd2063` |
| `CoreAISequentialVLMEngine.swift` (1 241 L) | `CoreAISequentialVLMEngine.swift` (1 107 L) | 0 | `7fd2063` (after `89ba0d4`) |
| `CoreAIEngine.swift` (925 L) | `InferenceEngines/InferenceEngine.swift` | 0 since `7fd2063` | `7fd2063` |
| `CoreAILoggerStub.swift` (14 L) | `CoreAIShared/Logger/Logger.swift` | 0 | `7fd2063` |
| `CoreAIStubs.swift` (171 L) | `CoreAIShared/Runtime/NDArray+Helpers.swift` | 0 | `7fd2063` |

36 distinct upstream commits read — **7 absorbed, 21 n/a, 8 open**. That covers every window the
ledger prints: 31 slots across the per-file rows, plus the 14 commits the axis judges that touch no
mirrored file (`0aff938`, `5b0f350`, `957fa7b`, `dc0b0dd`, `23308de`, `31484f7`, `cc3c234`, `3e172fb`, `0d6c0bf`,
`ed946c8`, `b63133b`, `184cc35`, `7debb8d`, `684ae8e`). Two files were unmeasurable before this pass
(`CoreAIEngine.swift`, `CoreAILoggerStub.swift`); the VLM engine and the stub file now carry the
baseline they were actually absorbed at, so `make drift` reads 0 unread on every CoreAI file and the
next upstream commit is the only thing that can raise a number here.

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
| `f03e8ce` | #368 | limit whitespace between JSON tokens under schema-constrained generation (`maxWhitespaceCount`, default 32) | **open** — top candidate | Apple's limit is enforced on the next-token mask, not in the grammar (upstream `GuidedGeneration/ConstrainedGenerationSession.swift:24-27`: 32 covers 15 nesting levels), so it ports without touching the vendored xgrammar; ours compiles with `anyWhitespace: true` (`GuidedGeneration/XGrammarWrapper.swift:69`), i.e. unbounded indentation inside every tool-call argument |
| `5b0f350` | #383 | ChunkedEmbedding fix for Gemma-3n-E4B | n/a | python export side (`_constants.py`, `export/pipeline.py`, `models/macos/gemma3n.py`) — this repo has no export surface (§ Upstream 2) |
| `957fa7b` | #365 | new eager APIs for Qwen 3.5+ on macOS | n/a | python reference implementations (`models/macos/qwen3_5.py`, `primitives/macos/cache.py`), same rule |
| `dc0b0dd` | #376 | Gemma 4 draft-head export + hidden-state decode output | n/a | `models/gemma4/export.py`, `export_drafter.py`, `models/ios/gemma4_text.py` — export side only |
| `23308de` | #378 | speculative decoding: protocol, `SpeculativeDecoder`, prompt-lookup drafter | n/a to this lane | theirs is a CoreAI-engine subsystem (`SpeculativeDecoding/`); ocoreai's speculative decoding is MLX-only by its own marker — `Engine/LoadedModel.swift:220` "Speculative Decoding (MLX only)". On a macOS 27 host it is the CoreAI-lane speedup we do not have |
| `31484f7` | #363 | select the sequential engine for attention-mask graphs; `--batch-prototype` | n/a | our factory picks by model structure (`CoreAIEngine.swift:665-718`: dynamic → pipelined, static → static-shape) and there is no attention-mask graph path to select for (0 hits for `BatchedDecodeStep`); the rest is their CLI |
| `cc3c234` | #357 | resolve diffusion assets through a bundle's declared asset manifest so compiled bundles load | **open** | ours hardcodes the three component names (`Video/WanPipeline.swift:115,118,121`) and reads the bundle's manifest only for the `diffusion` block (:94) — the pre-fix shape, whose own comment said declared `assets` names are not consulted. No Wan bundle on this host, so whether a bundle we advertises declares other names is unmeasured; the check is one `metadata.json` read, the fix is upstream's two `resolveDeclaredPipelineAsset` helpers |
| `3e172fb` | #248 | guided generation was refused after engine load on static-shape engines: ask \`supportsLogits\` *or* \`ConstrainedGenerationCapable\`, not the constrained flag alone | absorbed | `EngineInference.swift:326` names the commit and the rule, :336 routes on `engine.supportsLogits`, and the CPU-feed loop for a logits-only engine lives at :946-953 |
| `0d6c0bf` | #240 | layered prefill chunk size | absorbed | `CoreAIEngine.swift:166` ("Layered prefill chunking (coreai-models #240, 0d6c0bf)"), applied by `:175` |
| `ed946c8` | #274 | default the 4096 prefill chunk only at >=64 GB | absorbed | `CoreAIEngine.swift:191` — "Chunking defaults (coreai-models #274, ed946c8 — layered resolution)" |
| `b63133b` | #262 | route VLM construction through `EngineFactory` (C1+C2) | n/a | their factory gained 97 L; ocoreai constructs VLM engines in its own factory (`CoreAIEngine.swift:718` `createVLMEngine`), and the VLM file's edit was the removal of inline construction our copy never had |
| `184cc35` | #255 | SAM3 video runtime | n/a | additive `NDArray+Helpers` helpers (`copyIntoNDArray`, `writeNDArrayRegion`) for a subsystem ocoreai does not run — 0 hits for either symbol in `Sources/ocoreai` |
| `7debb8d` | #191 | Wan 2.1 text-to-video pipeline | n/a (measured absence) | added `flattenBFloat16NDArray` to the mirrored helper file; 0 hits in `Sources/ocoreai` — our Wan lane (`Video/WanPipeline.swift`) does not call it, so the slice stays a slice until a consumer appears |
| `684ae8e` | #184 | live transcription with Parakeet v3 | n/a | additive helpers (`argmaxFloat`, `forEachFloatElement`, `floatElements`) for an audio path that uses its own sampler — 0 hits in `Sources/ocoreai` |
| `0aff938` | #385 | attention mask for SAM3 export and runtime (`ImageSegmentationEngine.swift`) | n/a | ocoreai has no image-segmentation surface (0 hits for `SAM3`/`ImageSegmentation` outside a comment) — this commit landed *during* this pass, and the axis baseline adopted today (`0aff938`) is its sha, so the row exists because the ledger noticed the gap before a human did |

## Open, in the order that pays

1. **`f03e8ce` whitespace limit.** Cheapest real win: it ports into `ConstrainedGenerationSession` and
   bounds the whitespace our constrained tool calls can burn. Before writing code, measure the cost on
   a live turn — a probe counting whitespace tokens inside a tool-call argument across a few schemas
   says whether 32 buys anything. No measurement, no change.
2. **`cc3c234` Wan asset names.** One bundle manifest read against a real download answers whether our
   hardcoded `Transformer.aimodel` / `TextEncoder.aimodel` / `VAEDecoder.aimodel` can miss a declared
   name. If it can, port upstream's `resolveDeclaredPipelineAsset`; if it cannot, record that here and
   stop calling it a risk.
3. **`8623ac6` static-shape engine (~500 L).** Decide: re-sync the slice to upstream's current shape, or
   record a permanent divergence with the reason in the header. Leaving it unsaid is the failure mode
   this file exists to end.
4. **`7359dbc` VLM consolidation.** Our VLM copy is bigger than the upstream file it came from, because
   a refactor we never took removed ~216 L there. Take it or say why not; the ledger keeps this window
   open until someone does.
5. **`2704a69` turn-end stop tokens** and **`9db7476` `language.states`** — both settle with one
   macOS 27 run over the bundles we advertise: does the metadata carry the stop token, does any bundle
   declare `states`. Owner-side: a host that can import CoreAI.
6. **`7fd2063` includeLogits two-axis shape** — a bump-shape decision, cheap now, expensive after ten
   more call sites.

## What this pass did not do

Nothing was ported: every absorbed row cites code that was already in the tree, and every open row
names the action rather than taking it. The batching family (#335/#367/#377) is the one place where
"n/a" must not be read as "not worth it" — it is a serving capability we lack wholesale, and its cost
is the ~860 upstream lines listed above plus a scheduler of our own. These verdicts are one-pass reads
of an upstream commit against our tree: a reviewer who disagrees changes the row and the header line
that closes the window, not an argument in chat.
