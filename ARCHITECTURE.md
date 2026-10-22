# ocoreai Architecture — the live map

> What this file is: the current shape of the engine, stated only where a file in this repo carries
> it. The 2026-07-26 "Architecture Review" body that used to live here (20.8 KB of dated ✅/❌
> findings and per-file line counts) was removed on 10-22 because it had rotted into a source of
> false claims, not just stale detail: it diagrammed `BackendProtocol.swift`, which had already been
> deleted (`2123143`); every line count was wrong (`EngineInference.swift` 1,387 vs actual 5,044,
> `EnginePool` 740 vs 1,723, `LoadedModel` 338 vs 717, `CoreAIBridge` 247 vs 41); and §7 still
> recommended a CoreAI matrix with `supportsGrammar: false` after §5 of the same file had recorded
> that CoreAI has native grammar. Recover the original with `git show 4e36755:ARCHITECTURE.md`.
>
> The canonical layer diagram lives in `AGENTS.md` § Architecture (injected every session, capped,
> re-grepped). This file is one hop out and holds ownership + the invariants that shape the code.

## Who owns what

- **HTTP API** — `Handlers/` (openai + anthropic faces share `MessageBuilder.buildMessages`,
  `mergingSteeredTurn` and `persistConversation`), `Router/ChatCompletionsRouter.swift` for routes
  (route truth is `V1EndpointCatalog` + its set-equality test), `Middleware/` for auth + 404 shape.
- **Engine** — `Engine/EnginePool.swift` (orchestrator: model pool, LRU, HardwareRouter pressure
  eviction), `Engine/EngineInference.swift` (dispatch; MLX and CoreAI branches inline under the
  single `#if canImport(CoreAI)` gate — there is no `BackendProtocol`), `Engine/SessionPool.swift`
  (message-level feed dedupe; whether a prefill was skipped is upstream's decision, surfaced as
  `cachedPromptTokenCount`), `Engine/GuidedGeneration/ConstrainedGenerationCapable.swift` (grammar
  on both paths), `Engine/CoreAIPipelinedEngine.swift` (GPU constrained decoding, MPS samplers),
  `Engine/MetalShaderLibrary.swift` (resolves `default.metallib` down an ordered ladder; never
  staged into a signed bundle).
- **Scheduler** — `Scheduler/SchedulerActor.swift`, `AdmissionGate.swift`, `OOMGuard.swift`,
  `MemoryTracker.swift`, `HardwareRouter.swift`, `KVCacheBudget.swift` (floors the token→byte math).
- **Agent/tool surface** — `Tools/ToolRegistry.swift` is the single chokepoint every tool call
  passes; the mutation ledger and the claim-vs-audit check hang there. `Agents/` holds the approval
  cache (`approvalCacheKey`) and hooks; `Reasoning/ThinkingBudget.swift` calibrates thinking.
- **UI** — `UI/` (SwiftUI, `@MainActor`), sessions in SQLite + FTS5; `Multimodal/` for capture,
  hearing (`StreamingConfig` window geometry) and speech.

## Invariants that shape the code, and where each lives

- **A wire field the spec calls optional is Optional in the DTO** → `Models/SamplingDomain.swift`
  + `WireDTOOptionalityTests`; no wire value may own the process.
- **The caller's instructions have one delivery seam** → `splitInstructionMessages`, and instruction
  identity gates pooled-session reuse (`docs/agent/instruction-channel.md`).
- **A declared tool is written to the prompt once** → `ToolProseLedger` measures the checkpoint's
  own template before deciding who writes the schema.
- **A usage field carries the quantity its name claims** → `PromptTokenAccounting` adds the reused
  prefix back at every site on both faces.
- **A turn's last sentence must match its own tool record** → `ClaimVsAudit` + `ToolMutationLedger`.
- **A capability row degrades on measurement, not on tier** → `RuntimeCapability.measured(_:)`.
- **A stub that replaces a real component must be detectable at runtime** → e.g.
  `isRealTokenizerBackend`, published as `tokenizerBackend: real|heuristic`.

## What deliberately does not live here

- **Per-file line counts and ungated `file:NNN` cites.** They rotted twice and no gate read them.
  Line numbers in this repo are pinned by `make anchor-check` (marker syntax) or resolved by
  `scripts/upstream-cite-check.sh`; a type named in this file must exist — audit Class-K checks it.
- **Dated findings, fix narratives and round verdicts** → `CHANGELOG.md`.
- **Capability statements a user can read** → `/v1/capabilities` and the dashboard, backed by
  measurement; `AGENTS.md` invariant 2 governs their wording.

## Superseded, so nobody re-litigates it

`BackendProtocol` (removed `2123143`; inline `#if canImport(CoreAI)` is the documented reality) ·
`PagedKVCache`/`BlockPool`/`KVCacheManager` (removed) · "CoreAI lacks grammar/stop" (false since
`ConstrainedGenerationCapable.swift:26` + the CoreAI decode loop) · "MTP tool calls are silently
dropped" (the MTP path collects *and* dispatches per iteration, aligned with upstream
`MTPSpeculativeTokenIterator`). Note what remains compile-only: `canImport(CoreAI)` is false on the
CLT SDK, so every CoreAI branch has compile evidence and **zero runtime evidence** on macOS 26.
