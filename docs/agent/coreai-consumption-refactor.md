# CoreAI lane: consume upstream, stop forking — a proposal

Status: **proposal for owner decision — Phase 2 integration found a fundamental platform wall (below);
consumption is gated on a delivery-model change.** Evidence gathered 11-12; the integration scaffolding
was reverted, nothing here is implemented. The hand-ports already landed (fp8 #328, #412 pending CI)
are patches on the *current* fork and stand regardless.

## Phase 2 integration finding (11-12): the platform wall

Integration into ocoreai itself (trait + dep + adapter skeleton, since reverted) exposed what the
isolated spike could not: **CoreAILM is a macOS 27 product and cannot link into ocoreai's macOS 14
target.** SwiftPM's platform check is manifest-level (`product.minPlatform ≤ target.platform`); even
`-Xswiftc -target arm64-apple-macosx27.0` does not bypass it (`this target supports 14.0`). Contrast:
mlx-swift-lm's floor is macOS 14, so the FM adapter links; coreai-models' floor is macOS 27, so it
cannot. A second, solvable collision also surfaced (ocoreai's local `CXGrammar` C bridge renamed
`CXGrammarFork` to avoid the target-name clash with upstream's) — but the platform wall is fundamental.

**This corrects the proposal's premise:** the fork is *not* "an accident of the platform floor" — it is
the mechanism that reconciles macOS 14 delivery with macOS 27 CoreAI. Source-level `@available(macOS 27)`
gating compiles macOS 27 code into the macOS 14 single binary; product linking cannot. omlx/Bionic
consume engines because they lack this "macOS 14 binary must also carry macOS 27 CoreAI" constraint.

**Consumption therefore requires a delivery-model change — an owner decision:**
1. **Keep the fork + mechanize maintenance** (per-file diff + 3-way merge + verbatim script-copy) —
   respects the platform constraint, cuts the sync tax, no delivery change. The pragmatic path.
2. Raise ocoreai's floor to macOS 27 — enables consumption, abandons macOS 14 delivery.
3. Runtime-loaded engine extension (the Bionic model) — macOS 14 host binary dlopens a macOS 27 engine
   library; high cost in Swift.

The "no fork" north star is blocked by the platform floor unless the delivery model changes. Phases 0–1
remain proven (trait-gating; CoreAILM consumable in a *macOS 27 consumer*); Phase 2 integration into the
macOS 14 target is gated on the decision above.

## The proposal

ocoreai's essence is `mlx-swift-lm + coreai-models + agent`. The MLX side already **consumes**
upstream (SPM pin, MLX lane through upstream `ChatSession`); sync there is `bump pin`. The CoreAI
side **forks** ~9000 lines instead. The fork is the platform-floor workaround (see the Phase 2 finding
above), not mere inertia — but it carries a perpetual hand-sync tax. The aspiration is to make CoreAI
symmetric with MLX *if the delivery model allows*:

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
1. Consumability spike — **done, proven (11-12).** An isolated consumer depending on `coreai-models`
   (path) + hummingbird `from: 2.25.0` resolved (exit 0) and **built `CoreAILM` clean** (58 s, only
   benign upstream warnings). The feared hummingbird conflict does **not** occur: the root's `from`
   overrides the transitive `exact: 2.22.0` (resolved 2.28.1) — **no patch needed**. xgrammar 0.2.2
   matches. Next: add the dep to ocoreai itself (trait-gated), coexist with the fork, zero behaviour change.
2. Write the adapter; route **one** engine variant (e.g. Sequential) through upstream behind a flag.
3. Parity-verify on **CI xcode-27** against the fork; flip variant by variant.
4. Delete the fork files once all variants migrate; residual divergences become thin patches.

## Risks / open owner decisions

- **Verification split (refined):** the CoreAI lane *compiles* on the macOS 26 host with the Xcode 27.2
  SDK (SDKROOT unset ⇒ `swift build` compiles CoreAI; the #412 port was compile-verified this way). Only
  *runtime/behaviour* needs macOS 27 ⇒ CI xcode-27. So the adapter is compile-checkable locally; parity
  tests (adapter vs fork) on CI are the behaviour safety net.
- **Adapter mapping correctness** (IR ↔ upstream types) is the real new work and the real risk;
  constrained + multimodal routing in `EngineInference` needs careful mapping (both are upstream-shaped,
  but ocoreai's wiring is specific).
- **Scope appetite:** this is a one-time architecture refactor of the CoreAI lane, not a quick win.
  Owner decides whether to invest now vs keep the fork and mechanize its maintenance (per-file diff +
  3-way merge) as the lower-risk alternative.
- **Upstream consumability — RESOLVED by the Phase 1 spike:** `CoreAILM` resolves and builds as an SPM
  dependency alongside ocoreai's hummingbird 2.25+; no hummingbird patch required. Remaining: confirm the
  specific engine API surface the adapter needs is public (read during Phase 2).

## What this is not

Not a commitment to implement, and not a claim the refactor is cheap or even currently feasible. The
"best sync is no fork" aspiration is **blocked by the macOS 14 platform floor** (Phase 2 finding):
consuming CoreAILM requires a macOS 27 delivery target ocoreai does not have. The realistic default is
**keep the fork and mechanize its maintenance**; consumption stays a north star gated on an explicit
delivery-model decision (raise the floor, or runtime-load the engine). The evidence and change surface
above are kept so that decision, if taken, starts from measured ground rather than guesswork.