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
of the *next* request; the in-turn drains live in the tool-dispatch loop (`EngineInference.swift:2908`,
`:3514`) and the GUI composer flush. Every accept-then-deliver surface must name the line that
delivers on the next request, or its contract is fiction (root § Endpoint Promises).

## Known defect, deliberately unfixed — do not "fix" it blind
`_applyBitmask` (`EngineInference.swift:1385`) multiplies by `-Float.leastNormalMagnitude`
(≈ −1.18e-38, i.e. no mask) while its own doc says −inf, and `return`s on the first out-of-range
index instead of `continue`ing. Its only caller is `@available(macOS 27.0, *)`
`_runConstrainedDecoding`, so no host here can execute it. Land the fix on macOS 27 with a run, or
leave it as the open item it is; a blind edit is a claim, not a fix.

## Verification in this subtree
- Sandbox route compiles it without escalation; Metal suites self-skip on
  `MTLCreateSystemDefaultDevice() != nil`; full suite + live `serve` need escalation.
- A sudden `CompileMetalFile` failure here is a stale shader node + unwritable module cache, not a
  regression: one unsandboxed build fixes it. Do not revert engine code to "fix" it.
- Claims in this file are re-proved by `make docs-check` from the repo root.
<!-- claim:coreai_engine_files>=14 :: ls Sources/ocoreai/Engine | grep -c '^CoreAI' -->
