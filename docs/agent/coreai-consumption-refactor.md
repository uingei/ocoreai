# CoreAI lane: consume upstream, stop forking — a proposal

Status: **proposal for owner decision**, not a decided plan. Evidence gathered 11-12; nothing here is
implemented. The hand-ports already landed (fp8 #328, #412 pending CI) are patches on the *current*
fork and stand regardless of this decision.

## The proposal

ocoreai's essence is `mlx-swift-lm + coreai-models + agent`. The MLX side already **consumes**
upstream (SPM pin, MLX lane through upstream `ChatSession`); sync there is `bump pin`. The CoreAI
side **forks** ~9000 lines instead — an accident of the platform floor, not a necessity. Make CoreAI
symmetric with MLX:

- `coreai-models` becomes a **trait-gated SPM dependency** (macOS 27 lane only).
- ocoreai owns the **IR + agent + a thin adapter**, not engine internals.
- CoreAI sync becomes `bump pin`, like MLX. The perpetual hand-sync tax ends.

## Why it is feasible (measured, not inferred)

1. **The compile floor is solved — trait-gating experiment passed.** An isolated two-package test
   (11-12, since removed): a dependency whose source fails to compile on *any* SDK was **not built**
   when its enabling trait was off (`swift build` succeeded); with the trait on + a macOS 27 consumer
   it built. Mechanism is `.when(traits:)` on the product dependency — ocoreai already uses it for the
   FM adapter (`Package.swift:129`). `enabledDependencies` does **not** exist in this SwiftPM (6.4);
   the experiment corrected that assumption. Default Xcode SDK here is 27.2 (CoreAI present); shipping
   is CLT 26.5 — trait-off skips the build on either.
2. **The fork is nearly all upstream, not ocoreai glue.** The engines (`CoreAIPipelinedEngine` 1925 L,
   `CoreAISequentialVLMEngine` 1246, `CoreAISequentialEngine` 722, `CoreAIStaticShapeEngine` 659), the
   constrained stack (`GuidedGeneration/` 2097 L, Apple BSD-3 headers, `XGrammarWrapper` → CXGrammar),
   and the verbatim mirrors are all forks of files upstream maintains — upstream ships the full
   `DecodingStrategies/` + `GuidedGeneration/` + CXGrammar (xgrammar 0.2.2). Consuming upstream brings
   them; they are not ocoreai-native logic to preserve.
3. **The agent-facing contract already exists and is upstream-shaped.** ocoreai's `InferenceEngine`
   protocol (`CoreAIEngine.swift:286`) is near-verbatim upstream's (`InferenceEngine.swift:173`:
   `generate/reset/warmup/cancel/supportsLogits/lastPrefixHitCount` identical). The shared IR types
   (`InferenceStubs.swift`: `SamplingConfiguration`, `InferenceOptions`, …) are explicitly the
   "intermediate representation between handler layer and backend" — always compiled, backend-agnostic.
   The agent talks to the IR; only the backend adapter changes.
4. **Comparators converge on the same shape.** omlx: pinned `mlx==0.32.4` + **274** thin post-load
   patches, no wholesale fork, patches back off as upstream evolves. LM Studio **Bionic** (ocoreai's
   exact category — local open-model work/code agent): agent app + downloadable engine runtimes +
   plugin extensions. Both own the agent and consume the engines.

## Change surface

**Delete (return to upstream, ~7000+ L):** the four forked engines; `GuidedGeneration/`; the verbatim
mirrors (ImagePreprocessor/VideoInput/VisionConfig/InputEmbeddings/ImageStrategy); the forked
EngineFactory/TokenHistory/supports inside `CoreAIEngine.swift` and the no-baseline mirror set.

**Keep (ocoreai's value):** the IR (`InferenceStubs` shared types); the `InferenceEngine` /
`MultimodalInferenceEngine` protocols (agent-facing); the agent layer (`EngineInference`, routes via
`any InferenceEngine` — stable interface ⇒ minimal change); `CoreAIModelLoader` (model prep, adapted).

**Add (thin):** the trait-gated `coreai-models` dependency; an **adapter** mapping ocoreai IR ↔ upstream
types (`SamplingConfiguration`/`InferenceOptions`/`InternalModelConfig` → upstream `ModelConfig` etc.)
and wrapping upstream engines to conform to ocoreai's protocol — order hundreds of lines, against
~9000. Patches only where a divergence is genuinely required.

**Divergences mostly dissolve:** `fatalError` is upstream's code (ocoreai's zero-`fatalError` rule
governs ocoreai-owned code, not dependencies — same as mlx-swift-lm); memory-based chunking defaults
are passed through the adapter's config. Forking created these "divergences"; consuming removes them.

## Phases

0. trait-gating — **done, proven.**
1. Add `coreai-models` SPM dep (trait-gated), coexist with the fork, zero behaviour change.
2. Write the adapter; route **one** engine variant (e.g. Sequential) through upstream behind a flag.
3. Parity-verify on **CI xcode-27** against the fork; flip variant by variant.
4. Delete the fork files once all variants migrate; residual divergences become thin patches.

## Risks / open owner decisions

- **CI-only verification:** the CoreAI lane is macOS 27; it cannot run on the macOS 26 host. Every
  phase gate is CI xcode-27. Parity tests (adapter vs fork) are the safety net.
- **Adapter mapping correctness** (IR ↔ upstream types) is the real new work and the real risk;
  constrained + multimodal routing in `EngineInference` needs careful mapping (both are upstream-shaped,
  but ocoreai's wiring is specific).
- **Scope appetite:** this is a one-time architecture refactor of the CoreAI lane, not a quick win.
  Owner decides whether to invest now vs keep the fork and mechanize its maintenance (per-file diff +
  3-way merge) as the lower-risk alternative.
- **Upstream consumability:** confirm `coreai-models` products (`CoreAILM`) expose the engine API the
  adapter needs as public, and that its xgrammar pin coexists with ocoreai's. Phase 1 spike.

## What this is not

Not a commitment to implement, and not a claim the refactor is cheap. It is the grounded target
architecture the evidence points to: **the best sync is no fork.** The decision is whether to spend
the one-time refactor to reach it.