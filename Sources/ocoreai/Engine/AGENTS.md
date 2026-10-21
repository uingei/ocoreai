# Engine — backend contract

`Sources/ocoreai/Engine/`: `EnginePool` (actor) → `EngineInference` → MLX / CoreAI backends, plus
`Scheduler/` behind it. The repo-root `AGENTS.md` still governs; this file is only what is specific to
the engine, so it costs context when someone is actually working here.

## Backend axes are independent — never gate one with another
- `#if canImport(CoreAI)` means "this SDK ships CoreAI" (macOS 27+). It says nothing about Metal,
  vision, tokenizers or the ANE. `TokenizerManager` was once gated on `canImport(CoreAI)` while its
  only dependency is swift-transformers `Tokenizers` ⇒ the real tokenizer compiled out on the
  delivery platform and a same-named no-op stub took its place, silently.
- Where a substitution is possible, make it observable (`TokenizerManager.isRealTokenizerBackend` →
  `/v1/capabilities` `tokenizerBackend: real|heuristic`) and pin it with a test.
- Two routes build this subtree: CLT SDK 26.5 (every `canImport(CoreAI)` block compiles out) and
  Xcode SDK 27 (they compile in). `make toolchain-check` evaluates both — never read the ambient
  `DEVELOPER_DIR` as a fact about the platform.

## Shader loading is a candidate ladder, not a path
`MetalShaderLibrary.swift` (resolved once at `EnginePool.init`) walks SwiftPM's freshly compiled
`mlx-swift_Cmlx.bundle` → Xcode DerivedData → pip wheel, verifies each candidate, and publishes the
winner through `MLX.GPU.metallib`; `$OCOREAI_METALLIB` overrides. Never copy a `.metallib` *into* a
signed bundle (nested code object ⇒ CodeSign dies). Gate: `MetalShaderLibraryTests`.

## Never report a saving the engine did not make
- Prefix cache: log what upstream reports — `GenerateCompletionInfo.cachedPromptTokenCount`
  (`EngineEvents.swift`, `EngineInference.swift`). `SessionPool` dedupes the message *feed*; it is
  not evidence of prefill reuse. A HIT that reports 0 reused tokens reused 0 tokens.
- Polling: `EnginePool.waitForLoading` sleeps one poll interval (`min(deadline, now +
  loadingPollInterval)`), never to the deadline — sleeping to the deadline inside `while` cost 120 s
  for a model ready in 8 s. Deadline-sleeping is correct only in a single-shot watchdog
  (`EngineInference.swift:149`).

## Steering is delivered at the request seam
`mergingSteeredTurn` (`Sources/ocoreai/Handlers/ChatHandler.swift`) folds a queued steer into the head
of the *next* request; the in-turn drains live in the tool-dispatch loop (`EngineInference.swift:3003`,
`:3642`) and the GUI composer flush. Every accept-then-deliver surface must name the line that
delivers on the next request, or its contract is fiction (root § Endpoint Promises).

## Video is disclosed where a turn completes, not where bytes arrive
`/v1/models` may say `video_input=delivered` only once a turn that carried frames has *completed*:
the single record site is `recordVideoDelivery` (`EngineInference.swift:3232`), called from the
completion path (`EngineInference.swift:4681`), and the prompt size in its evidence line is upstream's
`completionInfo.promptTokenCount` — never a bytes/4 heuristic.
Counting at the media hand-off instead would claim video for turns that never produced an answer;
reading `processor_class` would claim it for checkpoints whose processor ignores `input.videos`
(`Gemma4UnifiedProcessor`), which is exactly the per-checkpoint trap this disclosure avoids.

**Never inside the pooled release.** `releasePoolSlotWithAssistant` is a no-op when there is no pool —
the degraded `.cpu` lane (`poolRef = nil`) and a pool-disabled engine (`sessionPool = nil`) both run
without one, and both still hand every frame to the processor. Measured 10-20 on that lane: the model
answered "Red" with prompt 712 → 856 (+144 video tokens) while `/v1/models` held `video_input =
not_observed`. `OCOREAI_SESSION_POOL=0` reaches the lane on demand (the memory-pressure route cannot
be scheduled). Gates: `VideoDeliveryPathTests` (placement, premise-floored: one record site in the
tree, none inside the release, guards still exclude media from guided-gen/MTP) +
`VideoDeliveryDisclosureTests` + probe 08 §4 (pooled lane) + probe 17 (unpooled lane).

The server-wide row (`/v1/capabilities` → `video_input`) is the *same* measurement aggregated:
`VideoDeliveryLedger.aggregate` counts models separately from turns/parts, and the sentence lives on
`VideoDeliveryAggregate.evidenceLine`, so no publisher re-words it (a router that assembles its own
evidence sentence is a second truth). Both are measured-only: `not_observed` is a fact about this
process, never a claim about the checkpoint. Gate: `CapabilityMeasurementHonestyTests`.
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:3234 items: videoInputCount, promptTokens -->

## Known defect, deliberately unfixed — do not "fix" it blind
`_applyBitmask` (`EngineInference.swift:1374`) multiplies by `-Float.leastNormalMagnitude`
(≈ −1.18e-38, i.e. no mask) while its own doc says −inf, and `return`s on the first out-of-range
index instead of `continue`ing. Its only caller is `@available(macOS 27.0, *)`
`_runConstrainedDecoding`, so no host here can execute it. Land the fix on macOS 27 with a run, or
leave it as the open item it is; a blind edit is a claim, not a fix.

## Line cites are gated, not trusted
Every `file:line` this area leans on is asserted below against the working tree (or the pinned
upstream revision). Round 14 inserted ~27 lines above the ThinkingBudget call and 15 cites across
AGENTS.md moved off their targets with no gate going red; these markers are the red. Move code, get
`make anchor-check` to name the cite that drifted.
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:149 Task.sleep(until: deadline -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:1374 Float.leastNormalMagnitude -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:3004 SteerQueue.shared.drain -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:3633 SteerQueue.shared.drain -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:4239 .applyingThinkingBudget -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:3734 .applyingThinkingBudget -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:4254 components: genComponents -->
<!-- anchor:. Sources/ocoreai/Engine/EngineInference.swift:3757 components: mtpGenComponents -->
<!-- anchor:. Sources/ocoreai/Engine/MLXBridge.swift:845 case "affine" -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:1724 func saveCache -->
<!-- anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:1110 templateMessages = leadingMessages -->

## Verification in this subtree
- Sandbox route compiles it without escalation; Metal suites self-skip on
  `MTLCreateSystemDefaultDevice() != nil`; full suite + live `serve` need escalation.
- A sudden `CompileMetalFile` failure here is a stale shader node + unwritable module cache, not a
  regression: one unsandboxed build fixes it. Do not revert engine code to "fix" it.
- Claims in this file are re-proved by `make docs-check` from the repo root.
<!-- claim:coreai_engine_files>=14 :: ls Sources/ocoreai/Engine | grep -c '^CoreAI' -->
