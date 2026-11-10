# The wire surface — DTOs and endpoint promises

`Handlers/` + `Router/` + `Models/` + `Wire/`: whatever a caller can put on an HTTP request, or read
back from one. The repo-root `AGENTS.md` still governs; this file is only what is specific to the
wire, so it costs context when someone is actually working here.

**Scope test for a new rule:** if it binds only what crosses `/v1/*`, it belongs here; if it binds
how code is written anywhere, it belongs at the root. Two copies of one rule is how one of them drifts.

## Wire DTOs
- A field the spec calls optional must be `Optional` in the DTO (or hand-decoded with
  `decodeIfPresent`): the synthesized `Decodable` requires every non-Optional key, so an `init` default
  does **not** make a key optional on the wire. Pin each with a decode test that omits the key.
  Gate: `WireDTOOptionalityTests`.
- No wire value may own the process. A bounded knob out of domain is a 400 naming field, range and value
  sent (`error.param`, vllm's shape) — never a trap. Ranges live in one checker (`Models/SamplingDomain.swift`,
  `top_k` 0 = disable); the token→byte math is floored **and priced by the model**
  (`Scheduler/KVCacheBudget.swift`, `KVCachePriceLedger` — an unpriced model reserves at the floor, and
  every decision names its basis `measured`|`fallback`). A capability problem arriving on the wire is
  asked once with `is` at the entry point (`Models/LoRAModelSupport.swift`).
  Gates: `RequestNumericDomainTests`, `KVCacheAdmissionPricingTests` + probes 09, 35.
- A fallback schema is a promise too: `"properties": {}` means "no key is legal", so a schema-less
  `json_object` answered `{}`. One permissive schema, `jsonObjectSchema`; a JSON shape arriving with `tools[]`
  constrains the answer unless `tool_choice` demands a call — one home, `buildGrammarSchema` (upstream
  installs a tool grammar only for a demand, serving_chat.py:1488-1501).
  Gate: `GrammarSchemaRegressionTests` + probe 12 §6, §7.
- A per-turn knob must be refreshed where the object is *reused*, not only where it is parsed: sampling
  lives on the upstream session, so a pooled session that keeps last turn's parameters answers this turn
  under them. One home: `MLXSessionPool.staleSamplingFields`. Gate: `PooledParameterDriftTests` + probe 14.

## Endpoint Promises
- A hint that names a discovery route needs an index behind it, and the index is checked against the
  router: `V1EndpointCatalog` + `V1EndpointCatalogTests`, which asserts set equality *and* floors its own
  scan, with `auth` read from `AuthRoutePolicy` rather than hand-copied.
- A capability row that names a mechanism must name where its delivery is measured, and the routing
  surface degrades from that record: tier truth stays in `RuntimeCapability.lines`, `/v1/capabilities`
  publishes `RuntimeCapability.measured(_:)` (a measured failure quotes the framework; it is never
  sticky). Gate: `CapabilityMeasurementHonestyTests` + probe 03.
- A surface that documents where its input goes needs an executable delivery seam, a test that pins it and
  a live probe that proves it. Ask of any accept-then-deliver surface: which line delivers this on the next
  request? If none, the contract is fiction. Gate: `mergingSteeredTurn` at the head of the chat handler +
  `SteerRequestHeadTests` + probe 21.
- A compatibility face reuses the main face's one assembly, one steer seam and one persistence hop, and
  emits its own spec's discriminators (`delta.type` is the chunk kind, not the event name): both faces go
  through `MessageBuilder.buildMessages`, `mergingSteeredTurn` and `persistConversation`, session identity
  is `session_id` / `metadata.session_id`, and each logs one `Assembled prompt [face]: …` line. Gates:
  `AnthropicToolDeliveryTests`, `AnthropicThinkingAndToolChannelTests` + probes 13, 22.
- A knob whose meaning lives in the checkpoint's template is honored on a measurement, not on
  acceptance: `reasoning_effort` is probed at load by rendering the checkpoint's own template with a
  sentinel value (`ReasoningEffortLedger`, Engine/), `/v1/models` publishes `honored` |
  `template_ignores` | `not_observed`, and a word the measurement says cannot reach the model is
  refused 400 naming the knob, the evidence and both exits (the shape of codex
  `core/src/session/code_mode_warning.rs:6-24`). Unmeasured is never refused — absence of evidence is
  not a measured "no", and a refusal costs a caller a turn.
  Gate: `ReasoningEffortHonestyTests` + probe 38 (both tiers red-sampled).
- A knob the wire accepts must reach the engine, and the terminal word must be the spec's word. Penalties
  apply when non-zero (upstream semantics), a stop string terminates the turn with `finish_reason: stop`,
  and only the last SSE chunk speaks. One home per decision: `upstreamPenalty`,
  `EnginePool.firstStopOccurrence`, `Models/ToolCallWire.swift` (parallelism, terminal word, terminal
  chunk). Gates: `PenaltySignDeliveryTests`, `StopSequenceDeliveryTests`,
  `ToolCallWireContractTests` + probes 10, 14.
- A usage field carries the quantity its name claims, and a breakdown cannot exceed its whole: the reused
  prefix is added back (`PromptTokenAccounting`) at every site on both faces, and never where no cache was
  observed. Gate: `PromptTokenAccountingTests` + probes 01, 21. Approximate counts have one home too
  (`Models/TokenEstimate.swift`); the bytes/token divisor is a vocabulary property, still unmeasured per model.
- A declared tool is written to the prompt once, and the checkpoint decides who writes it: whether this
  model's template renders the schema is *measured* at load (`ToolProseLedger`), and prose is written only
  where the template provably does not render. Gate: `ToolProseLedgerTests` + probe 16.
- The caller's instructions have one delivery seam, and instruction identity gates cache reuse:
  `splitInstructionMessages` hoists `system`/`developer` into that channel pre-assembly, and
  `canReusePooledSession` requires `instructionsMatch` (a pooled session renders the instructions it was
  *created* with). Long form: `docs/agent/instruction-channel.md`. Gates:
  `SystemInstructionDeliveryTests` + `SessionIsolationTests` + probe 15.
- `tools[]`'s truth set is the declaration; grammar follows the *request* and never "were tools declared" —
  decided once in `shouldConstrainOutput` and honoured
  identically by every `InferenceOptions` assembly. Publishing is measured (`ToolCallDeliveryLedger`, zeroed
  on unload). Gate: `ToolDeclarationSurfaceTests` + probe 11. `required` strength is bounded by the checkpoint.
- A hub is a dependency, not a promise: ask the cheap decidable question before handing over the request,
  and never let "could not ask" wear "does not exist" — `HubReachability.probe` names the repo, the status
  and the remedy (`HF_ENDPOINT`). Gate:
  `HubReachabilityTests` + probes 23, 24.

- **A turn's last sentence is a claim, checked against the audit.** `ClaimVsAudit` compares a
  self-terminated answer's file-change sentences with `ToolMutationLedger`, fed at
  `ToolRegistry.call` — the chokepoint native loop, MTP, GUI and MCP share (a native turn echoes no
  `tool_calls`, so the wire proves nothing). Both false directions get an `[audit]` line on four faces.
  A shell success is `WriteEvidence.unobserved`, not a write: over a record of shell calls only the line
  names what the audit cannot see instead of silencing itself (measured silent 11-01, probe 40). The
  ledger is process-wide but records are turn-attributed: a handler mints one key per request, the
  engine threads it to this chokepoint, and the query credits only its own dispatches (measured
  11-01: the unkeyed window invented the changed-files line across concurrent turns). Keyless
  dispatches — GUI, external `tools/call`, the macOS-27 FM/ANE channels — belong to no audited
  turn, the named residual (§ Open). Gate: `ClaimVsAuditTests` + `ClaimVsAuditTurnKeyTests`.
- `/v1/models/:model/…` takes the id **verbatim** (`org/name`, exactly as `/v1/models` publishes it) or
  percent-encoded (`%2F`). Those routes capture a recursive wildcard, which covers both in ONE registration;
  `:model` and `**` cannot coexist (`Route /v1/models/{model} overrides /v1/models/**`), so the wildcard
  replaces rather than joins, and `resolvedPathModelId` stays the only place an id becomes a storage key.
  Catalog states it, probe 03 pins it.

## Verification in this subtree
- `make test FILTER='WireDTOOptionalityTests'` — a key the spec calls optional decodes when absent.
- `make test FILTER='GrammarSchemaRegressionTests'` — the schema a constrained answer is promised.
- `make test FILTER='ToolCallWireContractTests'` — parallelism, terminal word, terminal chunk.
- `make test FILTER='ReasoningEffortHonestyTests'` — the refusal needs a demand *and* a measured
  negative; `bash scripts/probes/run.sh 38` decides the same claim on a live server, model-free.
- `make probes` — the same rows against a live `/v1/*` server, so the claim outlives the session
  that made it.
