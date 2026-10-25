# ocoreai — project context for AI agents

> Injected into every session, so it carries **rules and pointers only**.
> Every dated incident, measurement and round verdict lives in `CHANGELOG.md` (grep the symbol) or
> `docs/agent/`. `make docs-check` enforces that split — including "no dates in this file" — because
> the file used to state the rule and break it 38 times. If this file and the code disagree, the
> code is the fact: fix whichever is wrong.

## Identity
- An agent for open models, natively local on Apple silicon: it sees, hears, speaks and codes. One binary.
- Deepest slice: the coding/computer agent — reliable Execute → Verify → Recover. Knowledge work and
  creativity (Apple-native perception, multimodal) are first-class product surfaces, not demos.
- Stack: Swift 6.2 · SwiftPM · Hummingbird 2 · SwiftUI · SQLite + FTS5. Dual-channel on-device
  inference: MLX Metal GPU + CoreAI (derived from Apple's `coreai-models` reference, BSD-3).
- Modules are subdirectories of `Sources/ocoreai/`; § Routing table names the ones with their own guide.

## Two invariants
Almost every rule below is a corollary; when a shortcut collides with an invariant, the invariant wins.
1. **A claim is worth exactly the gate that goes red when it breaks.** A fix with no gate is a claim;
   a gate that infers its own premises from the environment rots the day the toolchain moves; a scan
   that stopped matching passes vacuously unless it floors its own hit count; a doc whose numbers
   nobody re-greps drifts.
2. **The surface never claims more than the engine delivered.** Anything a user can read — `/v1/models`,
   `/v1/capabilities`, the dashboard, a tool result, a composer string — must be measured, and must
   degrade honestly where the backend is absent. A file tool's `OK` is durability, not validity: the verdict
   travels in one result (`OK-but-invalid`). When authority is unclear: run it and read the answer.
   Read-echo chrome of our own surface (`N|` prefixes, the `total_lines:` footer, the
   `[System Perception]` header) is stripped when provable, reported when not: `PresentationEcho`,
   gate `PresentationEchoGuardTests`(16).

## Contribution policy
- Every line in git is reviewable, AI or not; "it came from the model" excuses nothing.
- No claim without a check: "verified/fixed/aligned" needs same-session command output.
- An improvement answers three questions — *what* behaviour improved, *what output* proves it, *which
  gate goes red* if it regresses; missing the third makes it a claim. Full text: `CONTRIBUTING.md` → *The
  three questions* (the open-item rule lives there).
- If upstream already has the answer, consume or reference it and cite `file:line` instead of authoring
  a local variant.

## Architecture
```
HTTP API Layer (Handlers/)   → Router / Middleware
Engine Layer (Engine/)       EnginePool(actor) → EngineInference → MLX | CoreAI backend
Scheduler Layer (Scheduler/) SchedulerActor, AdmissionGate, MemoryTracker, OOMGuard
UI Layer (SwiftUI)           ChatViewModel, SessionManager(SQLite)
```
- `EnginePool` gates backends with inline `#if canImport(CoreAI)`; there is no `BackendProtocol`.
- MLX path: `_runInferenceWithMessages()` → `ChatSession` (session pool, guided generation, `toolDispatch`);
  `ReasoningEventEmitter` on both backends, `KVCacheRuntime` `.turboQuant`/`.affine`, `ThinkingBudget` on the
  std and MTP lanes. Where each line lives: `Sources/ocoreai/Engine/AGENTS.md` (cites gated by anchor-check).
- MTP path: `generate(mtpDrafter:)` bypasses `ChatSession`; tool calls are collected, dispatched and
  published per iteration via `ToolResultPublisher`, aligned with upstream `MTPSpeculativeTokenIterator`.
- ANE/GPU constrained decoding: CoreAI `MPSGraphSamplers` (argmax / composite / sampler).
- `SessionPool` dedupes the *feed*, not the prefill: whether the cache skipped work is upstream's answer
  (`cachedPromptTokenCount`), published per model as `prefixReuse` on `/v1/models/:model/kv-cache` and as
  `reuseRefusals`; a lane that builds its own cache (guided gen, MTP) is booked as the refusal it was.
- Sampling: `argmax` when temperature is 0, `multinomialSample` above it, with filters mirroring
  upstream `CompositeSampler` — `Models/InferenceStubs.swift`.

## Build / Test / Lint
```bash
swift build -c release                 # production build — exit 0 is the minimum completion claim
swift build --traits appStore        # App Store route (traits: appStore | FoundationModelsIntegration)
swift test                           # full suite; needs Metal, so CI macos-26 is the authority
swift test --filter <SuiteRegex>     # one suite (substring)
make docs-check                      # docs contract: sub-second, no build
bash scripts/eval/run.sh               # task-success scoreboard: verifies the WORKSPACE, not the prose
```
- Gate tiering: **sandbox** → app-target build + non-Metal suites (writable `HOME`, CLT
  `DEVELOPER_DIR`/`SDKROOT`; mechanism `docs/agent/build-gate-reality.md`); **escalation** → `make test-clt`
  + `make probes` (live `/v1/*`); **CI only** → the `xcodebuild` legs (`test-ci`, the iOS build job).
- `make toolchain-check` evaluates both candidate routes (Xcode and CLT) instead of the ambient
  `DEVELOPER_DIR`, and settles Metal by *compiling a kernel*, never by `metal --version`.
- CLT SDK ≠ CLT compiler: an unpinned `SDKROOT` breaks even the manifest. On the CLT route every
  `canImport(CoreAI)` block compiles out, and macOS 26 can never run them.
- The full suite does run on this host, and `serve` + live `curl` work: **prefer a live check over an
  inference whenever a claim is about behaviour.**
- Style: `swift-format` (`.swift-format`, pinned) via `make format-check`; no other linter, aligned
  with upstream. Crash-safe coding (no `try!`/`as!`/`fatalError` in `Sources/`) is a convention here
  and a ceiling below § Error Handling.
- Licenses travel with the binary: MIT **plus** third-party terms (BSD-3 cl.1/cl.2, Apache-2.0 §4). Adding a
  dependency, bumping a pin or vendoring a header ⇒ re-run `scripts/collect-third-party-licenses.sh` and commit
  its output. Gates: `ThirdPartyNoticesTests`(16) + `scripts/audit.swift_patterns.sh` Class-I; composition:
  `docs/agent/third-party-notices.md`.
<!-- claim:apple_derived_files>=44 :: git grep -l "Copyright 2026 Apple Inc" -- Sources | wc -l -->
<!-- claim:notice_files>=38 :: ls THIRD-PARTY-LICENSES | wc -l -->

## Code Conventions

### Concurrency
- Swift 6.2 strict concurrency, `Sendable` enforced. UI is `@MainActor`, engine state is
  actor-isolated, cross-actor calls use `await`.
- `EnginePool` is an actor with `@unchecked Sendable` perform-isolated mutable state; every
  `@unchecked Sendable` declaration carries a justification comment.
- A continuation wrapped around an SDK callback needs a deadline, **and the caller owns the callback
  object's lifetime**: a delegate the framework does not retain leaves the continuation unresumed and
  the request parked forever.
- A polling loop sleeps one poll interval, never the deadline. Deadline-sleeping inside `while` parks
  the waiter for the whole window; it is correct only in a single-shot watchdog.

### Compile-time gates
- `#if canImport(X)` must name the dependency the block actually uses. Gating on a framework the code
  does not import deletes working code on every platform missing that framework — silently, with the log
  still claiming the capability.
- A stub that replaces a real component must be detectable at runtime, not only at compile time: expose
  the flag (`isRealTokenizerBackend` → `/v1/capabilities` `tokenizerBackend: real|heuristic`) and assert
  it, so a silent substitution fails a gate instead of shipping.
- Never gate a capability surface on a backend axis: `canImport(CoreAI)` says nothing about Metal,
  vision processors or tokenizers.

### Wire DTOs
- A field the spec calls optional must be `Optional` in the DTO (or hand-decoded with
  `decodeIfPresent`): the synthesized `Decodable` requires every non-Optional key, so an `init` default
  does **not** make a key optional on the wire. Pin each with a decode test that omits the key.
  Gate: `WireDTOOptionalityTests`(8).
- No wire value may own the process. A bounded knob out of domain is a 400 naming field, range and value
  sent (`error.param`, vllm's shape) — never a trap. Ranges live in one checker (`Models/SamplingDomain.swift`,
  `top_k` 0 = disable); the token→byte math is floored **and priced by the model**
  (`Scheduler/KVCacheBudget.swift`, `KVCachePriceLedger` — an unpriced model reserves at the floor, and
  every decision names its basis `measured`|`fallback`). A capability problem arriving on the wire is
  asked once with `is` at the entry point (`Models/LoRAModelSupport.swift`).
  Gates: `RequestNumericDomainTests`(25), `KVCacheAdmissionPricingTests`(7) + probes 09, 35.
- A fallback schema is a promise too: `"properties": {}` means "no key is legal", so a schema-less
  `json_object` answered `{}`. One permissive schema, `jsonObjectSchema`; a JSON shape arriving with `tools[]`
  constrains the answer unless `tool_choice` demands a call — one home, `buildGrammarSchema` (upstream
  installs a tool grammar only for a demand, serving_chat.py:1488-1501).
  Gate: `GrammarSchemaRegressionTests`(11) + probe 12 §6, §7.
- A per-turn knob must be refreshed where the object is *reused*, not only where it is parsed: sampling
  lives on the upstream session, so a pooled session that keeps last turn's parameters answers this turn
  under them. One home: `MLXSessionPool.staleSamplingFields`. Gate: `PooledParameterDriftTests`(6) + probe 14.

### Endpoint Promises
- A hint that names a discovery route needs an index behind it, and the index is checked against the
  router: `V1EndpointCatalog` + `V1EndpointCatalogTests`, which asserts set equality *and* floors its own
  scan, with `auth` read from `AuthRoutePolicy` rather than hand-copied.
- A capability row that names a mechanism must name where its delivery is measured, and the routing
  surface degrades from that record: tier truth stays in `RuntimeCapability.lines`, `/v1/capabilities`
  publishes `RuntimeCapability.measured(_:)` (a measured failure quotes the framework; it is never
  sticky). Gate: `CapabilityMeasurementHonestyTests`(16) + probe 03.
- A surface that documents where its input goes needs an executable delivery seam, a test that pins it and
  a live probe that proves it. Ask of any accept-then-deliver surface: which line delivers this on the next
  request? If none, the contract is fiction. Gate: `mergingSteeredTurn` at the head of the chat handler +
  `SteerRequestHeadTests` + probe 21.
- A compatibility face reuses the main face's one assembly, one steer seam and one persistence hop, and
  emits its own spec's discriminators (`delta.type` is the chunk kind, not the event name): both faces go
  through `MessageBuilder.buildMessages`, `mergingSteeredTurn` and `persistConversation`, session identity
  is `session_id` / `metadata.session_id`, and each logs one `Assembled prompt [face]: …` line. Gates:
  `AnthropicToolDeliveryTests`(26), `AnthropicThinkingAndToolChannelTests`(24) + probes 13, 22.
- A knob the wire accepts must reach the engine, and the terminal word must be the spec's word. Penalties
  apply when non-zero (upstream semantics), a stop string terminates the turn with `finish_reason: stop`,
  and only the last SSE chunk speaks. One home per decision: `upstreamPenalty`,
  `EnginePool.firstStopOccurrence`, `Models/ToolCallWire.swift` (parallelism, terminal word, terminal
  chunk). Gates: `PenaltySignDeliveryTests`(6), `StopSequenceDeliveryTests`(13),
  `ToolCallWireContractTests`(19) + probes 10, 14.
- A usage field carries the quantity its name claims, and a breakdown cannot exceed its whole: the reused
  prefix is added back (`PromptTokenAccounting`) at every site on both faces, and never where no cache was
  observed. Gate: `PromptTokenAccountingTests`(7) + probes 01, 21. Approximate counts have one home too
  (`Models/TokenEstimate.swift`); the bytes/token divisor is a vocabulary property, still unmeasured per model.
- A declared tool is written to the prompt once, and the checkpoint decides who writes it: whether this
  model's template renders the schema is *measured* at load (`ToolProseLedger`), and prose is written only
  where the template provably does not render. Gate: `ToolProseLedgerTests`(15) + probe 16.
- The caller's instructions have one delivery seam, and instruction identity gates cache reuse:
  `splitInstructionMessages` hoists `system`/`developer` into that channel pre-assembly, and
  `canReusePooledSession` requires `instructionsMatch` (a pooled session renders the instructions it was
  *created* with). Long form: `docs/agent/instruction-channel.md`. Gates:
  `SystemInstructionDeliveryTests`(9) + `SessionIsolationTests`(25) + probe 15.
- `tools[]`'s truth set is the declaration; grammar follows the *request* and never "were tools declared" —
  decided once in `shouldConstrainOutput` and honoured
  identically by every `InferenceOptions` assembly. Publishing is measured (`ToolCallDeliveryLedger`, zeroed
  on unload). Gate: `ToolDeclarationSurfaceTests`(15) + probe 11. `required` strength is bounded by the checkpoint.
- A hub is a dependency, not a promise: ask the cheap decidable question before handing over the request,
  and never let "could not ask" wear "does not exist" — `HubReachability.probe` names the repo, the status
  and the remedy (`HF_ENDPOINT`). Gate:
  `HubReachabilityTests`(20) + probes 23, 24.

- **A turn's last sentence is a claim, checked against the audit.** `ClaimVsAudit` compares a
  self-terminated answer's file-change sentences with `ToolMutationLedger`, fed at
  `ToolRegistry.call` — the chokepoint the native loop, MTP, GUI and MCP share (the wire echoes no
  `tool_calls` on a native turn, so it proves nothing). A false "File created." and a false "I failed"
  both get an `[audit]` line on all four faces; read-only tools never count, so a notice can only
  under-accuse. Gate: `ClaimVsAuditTests`(17).
- `/v1/models/:model/…` takes a **percent-encoded** model id (`:model` matches one segment, `/v1/models`
  publishes `org/name`); the catalog says so and probe 03 pins it — the owner call lives in § Open.

### Error Handling
- `precondition`/`preconditionFailure` are for structural invariants and upstream-verbatim surfaces only;
  new code adds none. Zero `try!`, `as!`, `fatalError`, `assert` outside comments. `try?` is acceptable only
  where a real fallback follows on the next line. `print()` only on CLI/stdout product surface (ceiling 2,
  headed for the logger).
<!-- claim:precondition_sites<=14 :: git grep -nE 'precondition(Failure)?\(' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
<!-- claim:precondition_files<=11 :: git grep -nE 'precondition(Failure)?\(' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | cut -d: -f1 | sort -u | wc -l -->
<!-- claim:try_excl_comments<=0 :: git grep -n 'try!' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
<!-- claim:fatalerror_as<=0 :: git grep -nE 'fatalError\(| as! ' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
<!-- claim:print_sites<=2 :: git grep -nE '(^|[^A-Za-z0-9_.])print\(' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
- Failure reports name the cause, not the symptom: a failing MCP server's stderr travels inside the refusal,
  screen capture says `blocked` with the framework's words and `unknown` before the first attempt
  (`ScreenDeliveryHonestyTests` + probes 04, 26).

### Naming
- Target names ≠ module boundaries (`GuidedGenerationLoop` is a peer of `ChatSession`, not nested inside it).

### Testing Quality
- Gold standard: exact-value assertions (`#expect(x == N)`), parameterized traversal, boundary cases.
  Reject `count > N` where the exact value is knowable.
- A scan-based test asserts its own premises: find the repo root by searching rather than by fixed
  `deletingLastPathComponent()` hops, and floor the scan's own hit count so a regex that stopped matching
  fails instead of passing vacuously.
- A fix gates every consumer of the value it changed, not just the emit site (a pin on the emit site left
  `/metrics` and the persisted row behind once already).
- Anything that proves behaviour against a live server ships as a script in `scripts/probes/`, so the claim
  outlives the session that made it. Index: `scripts/probes/README.md`.

## Open — measured, unresolved
Not resolved here, not forgotten: each item names the instrument that would settle it, and its evidence
is in `CHANGELOG.md` (grep the symbol). `make audit` Class-J keeps suite names cited honestly.
- **`/v1/models/:model/…` needs `%2F`** (Handlers/) — verbatim `org/name` ids router-404; accepting a slash
  costs a second routing truth. Owner call; the sharp edge is documented and pinned, not hidden.
- **A stall stops MTP hard, the std lane only by consent** (Tools/, Engine/) — the ladder and
  `LoopStallTerminationTests`(6) landed; upstream's `restart:` loop (ChatSession.swift:1154) still has no
  cap, and a std-lane hard stop throws out of `toolDispatch` (:1632) reaching the wire as an error, not a
  finished turn — the terminal word for four faces is the owner call.
- **CoreAI / macOS 27 items unverifiable on this host** (Engine/) — the bitmask helper's −inf case, the
  fp8→fp16 KV conversion (sits before Apple's fix) and the FoundationModels-block hub fallback are all
  `@available(macOS 27.0, *)` or SDK-gated out ⇒ no blind fix, no claim of one; `HubReachabilityTests`(20)
  pins the FM block at exactly one site so an unnoted edit goes red.
- **A turn with no tool call cannot be interrupted** (Engine/) — the drain points are the tool-result tail
  and the MTP loop; a tool-bearing turn provably breaks in-run (probe 21). The injection seam landed
  upstream at pin `991266ad3` (`observe(to:using:)` + `GenerationTransformer`), so what is left is
  owning what upstream's `ChatSession` loop owns. Owner call.
- **Rewind is landed; the reserve is a guessed constant** (Engine/) — 1024 rows measured on one checkpoint,
  not tuned to model or memory pressure, so an edit further back than the reserve still pays its full prefix.
  `SessionRewindOnDivergenceTests`(7) + probe 27 hold the wiring and the number.
- **Video publishing is per-checkpoint** (Multimodal/) — one processor reads `input.videos`, the other does
  not, so it is never inferred from architecture; a turn that received frames but never answered is not
  counted, and relaxing that is untested (`VideoDeliveryLedger`).
- **Screen capture cannot start a stream headlessly** (Multimodal/) — authorized, display attached, still
  "cannot start stream", while the camera on the same box delivers: an SCStream-in-no-GUI-session limit,
  not TCC. `screenStatus` is `ready` only after a delivered frame.
- **`tools[]` enforcement has gaps** — scope and open halves: `Sources/ocoreai/UI/AGENTS.md`; the
  `required`-strength bound sits in § Endpoint Promises.
- **Two owner questions have data now and no answer** — refresh-vs-refuse when instructions change, and
  cross-conversation prefix sharing. `ReuseRefusalLedger` publishes both; the ledger is opportunity, not a
  capability claim.

## Upstream Audit Dependencies
Five empirical sources plus comparators; round-by-round verdicts live in `CHANGELOG.md`, one diary, one home.
1. **`mlx-swift-lm`** — the `revision:` pin in `Package.swift` is the contract, currently `991266ad3`;
   `Package.swift` keeps the pin and a pointer, never a per-commit diary. Bump protocol: audit the consumption surface commit by
   commit → bump `.revision` → `swift build` + `make test-ci` green → verdicts into `CHANGELOG.md`.
   Upstream sources live under `Libraries/`, not `Sources/`; what must hold between clone and pin is
   `git merge-base --is-ancestor`, and "the built checkout is clean and at the pin" is asserted by
   `scripts/probes/_lib.sh`, not by prose.
2. **`coreai-models`** — Apple's reference tree, consumed here as `Engine/CoreAI*` (BSD-3; types redefined
   locally to avoid the macOS 27 platform requirement). Python/export-side commits are consumer-transparent:
   this repo has no Python or export surface.
3. **`codex`** — semantic axis reference (Rust; nothing linked, nothing redistributed, no per-commit copying).
4. **Apple Developer Documentation** — public, no login. DocC for intent and semantics, the SDK's
   `.swiftinterface` for exact signatures and `@available` gates, live execution for behaviour.
5. **Human Interface Guidelines** — <https://developer.apple.com/design/human-interface-guidelines>: the
   GUI's judge, so on anything user-visible it is the authority, not codex. 102 topics,
   two about AI, none about agents (measured: `agent` = 3 hits, all link metadata) ⇒
   `docs/agent/agent-interface-guidelines.md`.
6. **Comparators** — vllm, sglang, vllm-metal, omlx, mlx-serve, MTPLX, ollama, TensorFold, Strata, splash,
   openclaw, hermes-agent, deepseek-harness, harness2, goose, opencode: not pins; nothing linked or redistributed, and a
   borrowed verdict stays an inference until a `file:line` in our build says otherwise. Per-repo strengths:
   `docs/agent/comparator-repos.md`; shipped order + fix-cost per axis: `docs/agent/competitor-iteration-paths.md`.
- **OpenAI / Anthropic compatibility** is judged the way vllm and sglang do it: the spec, their
  implementation, real requests, and observed behaviour — not our convenience.
- **A mirror proves content, never HEAD.** `api.github.com` is authoritative for HEAD and compare windows.
- **Host-local is not project evidence**: `~/references/*`, `~/wiki/*`, `.hermes/` are colour, not verdicts.
  Repo-binding verdicts live in `CHANGELOG.md`. Codex-host facts: `docs/agent/codex-runtime.md`.

## Read on demand — detail one hop away
- `docs/agent/build-gate-reality.md` — why the local gate is tiered: sandbox / Metal / metallib /
  module-cache / toolchain-bump forensics.
- `docs/agent/third-party-notices.md` — license composition, the `coreai-models` metric warning, the
  vendored-header table.
- `docs/agent/closed-items-log.md` — verdicts § Open used to carry prose for (resolved / retracted / phantom).
- `docs/agent/instruction-channel.md` — who delivers the caller's `system`/`developer` text, and what
  refusing to reuse its cache costs.
- `docs/agent/systemone-decisions.md` — upstream's Jev / System 1 decision API, what we already have, and
  the price of the cheapest honest slice.
- `docs/agent/comparator-repos.md` — what each comparator repo is actually good for.
- `docs/agent/codex-runtime.md` — what the coding host is (and is not), skills, sub-agents, escalation.
- `scripts/probes/README.md` — every live probe: what it asserts, what it measured, which shape goes red.
- `docs/agent/long-horizon-goal.md` — the ladder, and what would kill it.

## Routing table — working in X → read this first
| Area | Read | Covers |
|---|---|---|
| `Sources/ocoreai/Engine/**` | `Sources/ocoreai/Engine/AGENTS.md` | backend gates, metallib, KV/prefix accounting, steer seam, constrained decoding, rewind |
| `Sources/ocoreai/UI/**` | `Sources/ocoreai/UI/AGENTS.md` | SwiftUI state authority, HIG duties, iOS-parity reality, focus discipline |
| `Sources/ocoreai/Handlers/**`, `Router/`, `Models/` | § Wire DTOs + § Endpoint Promises below | wire shapes, discovery contract |
| `Tests/**` | § Testing Quality below | exact-value assertions, scan floors, self-premise checks |
| `scripts/eval/**` | `scripts/eval/README.md` | task success: does the agent finish real jobs (the mission's unit) |
| `scripts/probes/**` | `scripts/probes/README.md` | live `/v1/*` wire-contract probes, one index per script |
| this file, `docs/**` | `scripts/agents-md-contract.sh` (`make docs-check`) | budgets, dead pointers, claim reproduction |

Areas without a guide (Scheduler, MCP, Tools, Skills, Multimodal, Video, Security): start from
§ Code Conventions plus the code. When an area accumulates three dated notes, give it an `AGENTS.md` and a
row here — a guide costs context only inside its subtree, which is the whole point.

## Docs Contract — how this file stays true
`make docs-check` (`scripts/agents-md-contract.sh`; CI: the `audit` job) holds this file and its corpus to
the claims they make, sub-second and without a build. The named gate list, its rationale and env knobs live
**in that script** — one home. Operator semantics (`>=` floor, `<=` ceiling) + the three questions:
`CONTRIBUTING.md`.

## Documentation Map — Agent-facing vs Human-facing
**Rule of thumb:** text *injected into the model's context at runtime* is **Agent-facing** — a change alters
model behaviour and needs an inference regression. Text read by people (or future agents) to understand the
project is **Human-facing**.

| Doc | Audience | When to touch |
|---|---|---|
| `AGENTS.md` (this file) | Agent, every session | a convention or architecture fact drifted — keep lines accurate, add nothing dated |
| `Sources/ocoreai/{Engine,UI}/AGENTS.md` | Agent, inside that subtree | a rule that only bites inside one area belongs there; that is what keeps this file short |
| `docs/agent/*.md` | Human + Agent, one hop away | when a verdict needs more than three lines, move it here and leave a pointer |
| `Sources/ocoreai/Skills/SystemPromptBuilder.swift` | Agent (LLM context) | prompt wording changes are behaviour changes — needs an inference regression |
| `Sources/ocoreai/Tools/ToolEntry.swift` (+ `Tool*.swift`) | Agent (LLM context) | `description`/schema are function-calling contracts — test with a live model |
| `Sources/ocoreai/Parsers/*` | Agent (implicit) | marker literals are contracts; pair against upstream before changing one |
| `CHANGELOG.md`, `README.md`, `ARCHITECTURE.md` | Human | every user-visible change (`CHANGELOG.md` names the commit) |

## Working here
- **Direct commits to `main`**, no branch ritual; CI on macos-26 (`make test-ci`) is the authority.
  `make docs-check` green when touching this file, `docs/**` or a guide. `CHANGELOG.md` records every
  user-visible change with its commit; `make push-ready` checks the tree: clean, pushed, paired.
- Verification is three layers: grep → compile → read the matched lines. A single-layer check is speculation.
  `swift build` exit 0 before any completion claim; audit findings cite `file:line` + commit, and label
  inference as inference.
- Before writing a symbol, grep for the mechanism that already exists (terminology drift is how
  `InferenceCompactor` would have been born next to `ConversationCompaction`). Before calling an upstream API
  missing, check the sources in § Upstream Audit Dependencies.
- **Footprint ladder — take the highest rung that solves it:** consume upstream → extend an existing seam →
  opt-in flag/trait → tool or skill → new module → new core/agent-facing surface. A new surface needs a
  consumer that exists today, not one imagined for tomorrow.
- **One home per decision.** A second copy of a rule is where one of them drifts.
  **A side effect is gated where it is declared:** `ToolEntry.isDestructive` is the only destructive
  truth and `securityPrecheck` asks from it (∪ blacklist for names nothing registers) — a hand-copied
  matcher list is how 11 of 17 mutating tools ran unasked. Gate: `DestructiveApprovalGateTests`(5).
- **One resolver, one ladder:** precedence as data, a candidate trusted only once probed, a failed *read*
  falling to the next rung, a failed *authoritative write* surfacing or rolling back, bounded retries that
  end in a recovery affordance. `MetalShaderLibrary` is the pattern.
- **Decide state by authority, and put the scope in the key.** Engine actors own engine/model truth;
  `SessionManager` + SQLite own durable sessions; SwiftUI owns this window's presentation; a wire client owns
  its own view. Persisted keys declare their scope (global | session | model | window) — a wrong scope is how
  one session's setting bleeds into another.
- **Respect the person using it.** Never navigate, refocus, open a pane or announce because something
  *happened* in the background — offer, don't hijack. The five non-happy states each owe honest copy and
  a way out (the list: `Sources/ocoreai/UI/AGENTS.md`). On anything user-visible the HIG is authority.
- **A file's lifetime is the lifetime of the thing that cites it.** Bytes that outlive the request that wrote
  them need an owner, a pin while in flight, and collection by idle TTL + byte budget; deleting at request end
  turns the next use into an unreadable-path error far from its cause. `MediaSpool`; gates:
  `MediaLifetimeTests`(15) + probe 08.
- **Comments say the *why* the code cannot, in 1–3 lines.** No bug history, dates or audit trails inside
  source comments — that is the commit message. Diffs are read by a human: one logical change per commit.
- **No new defensive clutter:** no wrapper or `try?` around code that cannot fail.
- **Not a diary.** A root rule is ≤3 lines: what + the one-line evidence + the gate. Dates, round verdicts
  and host forensics go next to their claim, in `CHANGELOG.md` / `docs/agent/` (P13 enforces this file).
- Default is one-pass: intent → plan → implement → review → verify → commit in one thread, no sub-agent
  unless the owner asks (the owner reviews every commit).

## Taste test before you hand off
- Does every piece of state live with its authority, at the narrowest scope that can still be right?
- Can any sentence a user can read promise more than the engine measured?
- Does each resolver/fallback have one home, a validated ladder, and a bounded, recoverable end?
- Is the hot path still cheap under *realistic* content — long transcript, warm KV, a real model — not the
  empty demo?
- Did the user, the developer and the agent reading this surface each end up better off than before?
- Did `swift build` exit 0, and does `CHANGELOG.md` name the commit?
