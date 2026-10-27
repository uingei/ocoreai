# ocoreai — project context for AI agents

> Injected into every session, so it carries **rules and pointers only**: a root rule is ≤3 lines
> (what + the one-line evidence + the gate). Dated incidents, measurements and round verdicts live in
> `CHANGELOG.md` (grep the symbol) or `docs/agent/`; `make docs-check` enforces that split. If this file
> and the code disagree, the code is the fact: fix whichever is wrong.
>
> **Why there is a budget:** every byte is paid by every session working on this repo, and the
> band is not invented — `hermes-agent` gates its root at 12k chars and each root→area chain at 30k,
> "so it loads whole on 128k+ models: long form goes in the guide". Measured across 21 comparator trees
> ours was the largest root (24,866 chars, 51% of our corpus). Long form moves one hop, into the same
> gated corpus — it is not deleted.

## Identity
- An agent for open models, natively local on Apple silicon: it sees, hears, speaks and codes, in one binary.
- Deepest slice: the coding/computer agent — reliable Execute → Verify → Recover. Knowledge work and
  creativity (Apple-native perception, multimodal) are product surfaces, not demos.
- Stack: Swift 6.2 · SwiftPM · Hummingbird 2 · SwiftUI · SQLite + FTS5. Dual-channel on-device
  inference: MLX Metal GPU + CoreAI (derived from Apple's `coreai-models` reference, BSD-3).

## Two invariants
Almost every rule below is a corollary; when a shortcut collides with an invariant, the invariant wins.
1. **A claim is worth exactly the gate that goes red when it breaks.** A fix with no gate is a claim;
   a gate that infers its own premises from the environment rots the day the toolchain moves; a scan
   that stopped matching passes vacuously unless it floors its own hit count; a doc whose numbers
   nobody re-greps drifts.
2. **The surface never claims more than the engine delivered.** Anything a user can read — `/v1/models`,
   `/v1/capabilities`, the dashboard, a tool result, a composer string — must be measured, and must
   degrade honestly where the backend is absent. A file tool's `OK` is durability, not validity: the
   verdict travels in one result (`OK-but-invalid`). When authority is unclear: run it and read the answer.

## Contribution policy
- Every line in git is reviewable, AI or not; "it came from the model" excuses nothing.
- An improvement answers *the three questions* (what improved, what same-session output proves it, which
  gate goes red if it regresses); missing the third makes it a claim. Full text: `CONTRIBUTING.md`.
- If upstream already has the answer, consume it or cite `file:line` — do not author a local variant.

## Architecture
```
HTTP API Layer (Handlers/)   → Router / Middleware
Engine Layer (Engine/)       EnginePool(actor) → EngineInference → MLX | CoreAI backend
Scheduler Layer (Scheduler/) SchedulerActor, AdmissionGate, MemoryTracker, OOMGuard
UI Layer (SwiftUI)           ChatViewModel, SessionManager(SQLite)
```
- `EnginePool` gates backends with inline `#if canImport(CoreAI)`; there is no `BackendProtocol`.
- The two lanes reach the wire by different routes — MLX through upstream `ChatSession`, MTP around it —
  and where each line lives, what `SessionPool` dedupes and how sampling is chosen is
  `Sources/ocoreai/Engine/AGENTS.md`, which loads inside that subtree instead of in every session.

## Build / Test / Lint
```bash
swift build -c release                 # production build — exit 0 is the minimum completion claim
swift build --traits appStore        # App Store route (traits: appStore | FoundationModelsIntegration)
swift test                           # full suite; needs Metal, so CI macos-26 is the authority
make test                            # same, but names $OCOREAI_METALLIB first — else MLX dies mid-run
make test FILTER=<Regex>             # one suite (swift-testing half: the XCTest helper SEGVs on filter)
make test-clt [FILTER=<Regex>]       # CLT route, serial — runs both halves
make docs-check                      # docs contract: ~3 s, no build
make spell                           # codespell, pin asserted; vocab in .codespellrc
bash scripts/eval/run.sh               # task-success scoreboard: verifies the WORKSPACE, not the prose
```
- Gate tiering: **sandbox** → app-target build + non-Metal suites; **escalation** → `make test-clt`
  + `make probes` (live `/v1/*`); **CI only** → `xcodebuild` (`test-ci`, iOS build). Env forensics:
  `docs/agent/build-gate-reality.md`.
- CLT SDK ≠ CLT compiler: an unpinned `SDKROOT` breaks even the manifest, and on the CLT route every
  `canImport(CoreAI)` block compiles out. `make toolchain-check` evaluates both candidate routes instead
  of the ambient `DEVELOPER_DIR`, and settles Metal by *compiling a kernel*, never by `metal --version`.
- **A gate you did not run is not green; a stated fix that cannot run is no exit.** `make push-ready`
  runs the no-build set and `make audit` parses every recipe. Off-pin checks stay advisory; **prefer a
  live `serve` + `curl` over an inference about behaviour.**
- Style: `swift-format` (`.swift-format`, pinned) via `make format-check`; no other linter, aligned with
  upstream; crash-safety is § Error Handling's ceiling.
- Licenses travel with the binary: MIT **plus** third-party terms (BSD-3 cl.1/cl.2, Apache-2.0 §4). Adding
  a dependency, bumping a pin or vendoring a header ⇒ re-run `scripts/collect-third-party-licenses.sh`
  and commit its output. Gates: `ThirdPartyNoticesTests`(16) + `scripts/audit.swift_patterns.sh` Class-I;
  composition: `docs/agent/third-party-notices.md`.
<!-- claim:apple_derived_files>=49 :: git grep -l "Copyright 2026 Apple Inc" -- Sources | wc -l -->
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
- `#if canImport(X)` must name the dependency the block actually uses: gating on a framework the code does
  not import deletes working code on every platform missing it, silently, with the log still claiming the
  capability. Never gate a capability surface on a backend axis — `canImport(CoreAI)` says nothing about
  Metal, vision, tokenizers or the ANE (worked instance: `Sources/ocoreai/Engine/AGENTS.md`).
- A stub that replaces a real component must be detectable at runtime, not only at compile time: expose
  the flag (`isRealTokenizerBackend` → `/v1/capabilities` `tokenizerBackend: real|heuristic`) and assert
  it, so a silent substitution fails a gate instead of shipping.

### Error Handling
- `precondition`/`preconditionFailure` are for structural invariants and upstream-verbatim surfaces only;
  new code adds none. Zero `try!`, `as!`, `fatalError`, `assert` outside comments. `try?` is acceptable
  only where a real fallback follows on the next line. `print()` only on CLI/stdout product surface.
<!-- claim:precondition_sites<=14 :: git grep -nE 'precondition(Failure)?\(' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
<!-- claim:precondition_files<=11 :: git grep -nE 'precondition(Failure)?\(' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | cut -d: -f1 | sort -u | wc -l -->
<!-- claim:try_excl_comments<=0 :: git grep -n 'try!' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
<!-- claim:fatalerror_as<=0 :: git grep -nE 'fatalError\(| as! ' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
<!-- claim:print_sites<=2 :: git grep -nE '(^|[^A-Za-z0-9_.])print\(' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
- Failure reports name the cause, not the symptom: a failing MCP server's stderr travels inside the
  refusal, screen capture says `blocked` with the framework's words and `unknown` before the first
  attempt (`ScreenDeliveryHonestyTests` + probes 04, 26).

### Naming
- Target names ≠ module boundaries (`GuidedGenerationLoop` is a peer of `ChatSession`, not nested inside it).

### Testing Quality
- Gold standard: exact values a caller can observe (a wire field, a file's bytes, an exit code),
  parameterized traversal, boundary cases. Reject `count > N` where N is knowable; never pin a constant
  copied out of the code under test.
- A scan-based test asserts its own premises: find the repo root by searching rather than by fixed
  `deletingLastPathComponent()` hops, and floor the scan's own hit count so a regex that stopped matching
  fails instead of passing vacuously.
- A fix gates every consumer of the value it changed, not just the emit site.
- Anything that proves behaviour against a live server ships as a script in `scripts/probes/`, so the
  claim outlives the session that made it.
- Process-global state (workspace anchor, `OCOREAI_*`, `HF_ENDPOINT`, a `shared` sensor) is leased, never
  set: `.serialized` orders a suite's *own* tests, not suites against each other, and a lease never spans
  live I/O. Gate: `ProcessGlobalLeaseDisciplineTests`(3).

## Open — measured, unresolved
Not resolved here, not forgotten. The root owes only the address: the area, the instrument that would
settle it, and whose call it waits on. The sentence for each, with its evidence:
`docs/agent/open-items.md`; resolved / retracted / phantom: `docs/agent/closed-items-log.md`; `make audit`
Class-J keeps every suite name cited below honest.
- **`/v1/models/:model/…` needs `%2F`** (Handlers/) — owner call.
- **Stall: MTP stops hard, the std lane by consent** (Tools/, Engine/) — `LoopStallTerminationTests`(6);
  owner call: the terminal word for four faces.
- **CoreAI / macOS 27 items unverifiable here** (Engine/) — `PlatformPremise.hasMacOS27`.
- **A no-tool turn cannot be interrupted** (Engine/) — upstream seam at `991266ad3`; owner call.
- **Rewind landed; the reserve is untuned** (Engine/) — `SessionRewindOnDivergenceTests`(7) + probe 27.
- **Video publishing is per-checkpoint** (Multimodal/) — `VideoDeliveryLedger`.
- **Screen capture cannot stream headlessly** (Multimodal/) — `screenStatus` needs a delivered frame.
- **`tools[]` gaps; two prefix questions await an owner** — `UI/AGENTS.md`, `Handlers/AGENTS.md`,
  `ReuseRefusalLedger`.
- **The board measures 6 of the 43 registered tools** (scripts/eval/) — `run.sh` prints its slice; the
  instrument is a full-surface board (codex ships 13 tools, opencode 16).

## Upstream Audit Dependencies
Five empirical sources plus comparators; round-by-round verdicts live in `CHANGELOG.md`, one diary, one home.
1. **`mlx-swift-lm`** — the `revision:` pin in `Package.swift` is the contract, currently `991266ad3`;
   `Package.swift` keeps the pin and a pointer, never a per-commit diary. Bump protocol: audit the
   consumption surface → bump `.revision` → `make audit` (both lockfiles) → `swift build` +
   `make test-ci` green → `CHANGELOG.md`. Upstream sources live under
   `Libraries/`, not `Sources/`; what must hold between clone and pin is `git merge-base --is-ancestor`,
   and "the built checkout is clean and at the pin" is asserted by `scripts/probes/_lib.sh`, not by prose.
2. **`coreai-models`** — Apple's reference tree, consumed here as `Engine/CoreAI*` (BSD-3; types redefined
   locally to avoid the macOS 27 platform requirement). Python/export-side commits are
   consumer-transparent: this repo has no Python or export surface.
3. **`codex`** — semantic axis reference (Rust; nothing linked, nothing redistributed, no per-commit copying).
4. **Apple Developer Documentation** — public, no login. DocC for intent and semantics, the SDK's
   `.swiftinterface` for exact signatures and `@available` gates, live execution for behaviour.
5. **Human Interface Guidelines** — <https://developer.apple.com/design/human-interface-guidelines>: on
   anything user-visible it is the authority, not codex, and none of its topics covers agents ⇒
   `docs/agent/agent-interface-guidelines.md`.
6. **Comparators** — vllm, sglang, vllm-metal, omlx, mlx-serve, MTPLX, ollama, TensorFold, Strata, splash,
   openclaw, hermes-agent, harness2, goose, opencode: not pins; nothing linked or redistributed, and a
   borrowed verdict stays an inference until a `file:line` in our build says otherwise. Per-repo strengths
   and measured conventions: `docs/agent/comparator-repos.md`; shipped order + fix-cost per axis:
   `docs/agent/competitor-iteration-paths.md`.
- **OpenAI / Anthropic compatibility** is judged the way vllm and sglang do it: the spec, their
  implementation, real requests, and observed behaviour — not our convenience.
- **A mirror proves content, never HEAD.** `api.github.com` is authoritative for HEAD and compare windows.
- **Host-local is not project evidence**: `~/references/*`, `~/wiki/*`, `.hermes/` are colour, not verdicts.
  Repo-binding verdicts live in `CHANGELOG.md`. Codex-host facts: `docs/agent/codex-runtime.md`.

## Read on demand — detail one hop away
- `docs/agent/open-items.md` — the long form of § Open, and whose call each item is waiting on.
- `docs/agent/build-gate-reality.md` — the toolchain / SDK / Metal forensics behind that tiering.
- `docs/agent/third-party-notices.md` — license composition, the `coreai-models` metric warning, the
  vendored-header table.
- `docs/agent/closed-items-log.md` — verdicts § Open used to carry prose for.
- `docs/agent/instruction-channel.md` — who delivers the caller's `system`/`developer` text, and what
  refusing to reuse its cache costs.
- `docs/agent/systemone-decisions.md` — upstream's Jev / System 1 decision API and the cheapest honest slice.
- `docs/agent/comparator-repos.md` — what each comparator is good for, measured.
- `docs/agent/codex-runtime.md` — what the coding host is (and is not), skills, sub-agents, escalation.
- `scripts/probes/README.md` — every live probe: what it asserts, what it measured, which shape goes red.
- `docs/agent/long-horizon-goal.md` — the ladder and what kills it.

## Routing table — working in X → read this first
| Area | Read | Covers |
|---|---|---|
| `Sources/ocoreai/Engine/**` | `Sources/ocoreai/Engine/AGENTS.md` | backend gates, metallib, KV/prefix accounting, steer seam, constrained decoding, rewind |
| `Sources/ocoreai/UI/**` | `Sources/ocoreai/UI/AGENTS.md` | SwiftUI state authority, HIG duties, iOS-parity reality, focus discipline |
| `Sources/ocoreai/Handlers/**`, `Router/`, `Models/`, `Wire/` | `Sources/ocoreai/Handlers/AGENTS.md` | DTO optionality, endpoint promises, discovery contract |
| `Tests/**` | § Testing Quality below | exact-value assertions, scan floors, self-premise checks |
| `scripts/eval/**` | `scripts/eval/README.md` | task success: does the agent finish real jobs (the mission's unit) |
| `scripts/probes/**` | `scripts/probes/README.md` | live `/v1/*` wire-contract probes, one index per script |
| this file, `docs/**` | `scripts/agents-md-contract.sh` (`make docs-check`) | budgets, dead pointers, claim reproduction |

Areas without a guide (Scheduler, MCP, Tools, Skills, Multimodal, Video, Security): start from
§ Code Conventions plus the code. When an area accumulates three dated notes, give it an `AGENTS.md` and a
row here — a guide costs context only inside its subtree.

## Docs Contract — how this file stays true
`make docs-check` (`scripts/agents-md-contract.sh`) holds this file and its corpus to their claims; its gate
list, rationale and env knobs live **in that script**; floor/ceiling semantics: `CONTRIBUTING.md`.

## Documentation Map — Agent-facing vs Human-facing
**Rule of thumb:** text *injected into the model's context at runtime* is **Agent-facing** — a change
alters model behaviour and needs an inference regression. Text read by people (or future agents) to
understand the project is **Human-facing**.

The three surfaces injected into a model at runtime, where a word is a behaviour change:
`Sources/ocoreai/Skills/SystemPromptBuilder.swift` (needs an inference regression), `ToolEntry.swift`
+ `Tool*.swift` (`description`/schema are function-calling contracts — test with a live model), and
`Sources/ocoreai/Parsers/*` (marker literals are contracts; pair against upstream before changing one).
Which doc each audience reads, and when to touch it: `docs/agent/docs-map.md`.

## Working here
- **Direct commits to `main`**, no branch ritual; CI on macos-26 (`make test-ci`) is the authority.
  `make docs-check` green when touching this file, `docs/**` or a guide; `make push-ready` checks the
  tree: clean, pushed, paired, cites. `CHANGELOG.md` records every user-visible change with its commit.
- **One cwd, several sessions:** stage explicit paths and commit only files this session changed — never
  `git add -A`/`git add .`, which sweeps in another session's half-work (pi's rule; CI cannot tell you).
- Verification is three layers: grep → compile → read the matched lines; a single-layer check is
  speculation. `swift build` exit 0 before any completion claim; findings cite `file:line`; label
  inference as inference.
- Before writing a symbol, grep for the mechanism that already exists. Before calling an upstream API
  missing, check the sources in § Upstream Audit Dependencies.
- **Footprint ladder — take the highest rung that solves it:** consume upstream → extend an existing seam →
  opt-in flag/trait → tool or skill → new module → new core/agent-facing surface. A new surface needs a
  consumer that exists today.
- **Refused even when well-built** (the list hermes-agent keeps too): a guard for a failure nobody quoted;
  a test that only detects change; a second home for a decision; a new core tool where a file tool or a
  skill already does it — the last clause is the only one a machine can decide, so it has a ceiling: adding
  a declaration goes red until someone raises the number on purpose.
<!-- claim:core_tools<=43 :: git grep -h 'ToolEntry\.typed(' -- Sources/ocoreai/Tools | grep -vE '^[[:space:]]*(//|\*)' | wc -l -->
- **One home per decision, and a side effect is gated where it is declared:** `ToolEntry.isDestructive` is
  the only destructive truth and `securityPrecheck` asks from it (∪ blacklist for names nothing registers):
  a hand-copied matcher list leaves mutating tools unasked. Gate: `DestructiveApprovalGateTests`(5).
- **One resolver, one ladder:** precedence as data, a candidate trusted only once probed, a failed *read*
  falling to the next rung, a failed *authoritative write* surfacing or rolling back, bounded retries that
  end in a recovery affordance. Pattern: `MetalShaderLibrary`.
- **Decide state by authority, and put the scope in the key.** Engine actors own engine/model truth;
  `SessionManager` + SQLite own durable sessions; SwiftUI owns this window's presentation; a wire client
  owns its own view. Persisted keys declare their scope (global | session | model | window); a wrong
  scope is what makes one session's setting bleed into another.
- **Respect the person using it.** Never navigate, refocus, open a pane or announce because something
  *happened* in the background — offer, don't hijack. **Name a destructive route only where the caller's
  own argument asks for it:** `edit_file` offers `rm` solely when `newString` is empty, because in an
  ordinary mismatch that offer nudges a typo into an unrecoverable delete. Gate:
  `EditMismatchRecoveryTests`(10). HIG is authority on anything user-visible; the five non-happy states
  each owe honest copy and a way out (`Sources/ocoreai/UI/AGENTS.md`).
- **A file's lifetime is the lifetime of the thing that cites it.** Bytes outliving their request need an
  owner, a pin in flight, and collection by idle TTL + byte budget — deleting at request end leaves the
  next use an unreadable path far from its cause. `MediaSpool`; gates: `MediaLifetimeTests`(15) + probe 08.
- **Comments say the *why* the code cannot, in 1–3 lines.** No bug history, dates or audit trails inside
  source comments — that is the commit message. Diffs are read by a human: one logical change per commit.
- **A lock lives at the cheapest rung that bites:** hook → `make` → CI, priced in runner-seconds (text
  gates go to ubuntu; arm64 minutes are the expensive seat). A gate nobody can install or sees go red is
  decoration.
- **No defensive clutter; no guard for a failure nobody observed.** Validate once at the boundary that owns
  the value and pass typed values inward; quote the failure (a probe line, a red test, a scoreboard row)
  before writing its guard. For a speculative race or security edge case, name the failure mode, likelihood
  and complexity cost and get the owner's buy-in — no scope for theoretical robustness.
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
