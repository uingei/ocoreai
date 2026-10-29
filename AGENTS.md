# ocoreai — project context for AI agents

> Injected into every session, so it carries **rules and pointers only**: a root rule is ≤3 lines
> (what + the one-line evidence + the gate). Dated incidents, measurements and round verdicts live in
> `CHANGELOG.md` (grep the symbol) or `docs/agent/`; nothing enforces that split but the byte cap. If this file
> and the code disagree, the code is the fact: fix whichever is wrong.
>
> **Why there is a budget:** the host injects this file plus every `AGENTS.md` below it to the cwd as ONE
> concatenation truncated at 32 KiB — past the cap a rule is not deferred, it is never read. B2 prices
> root+guide against the loader's number (rationale: the head of `scripts/agents-md-contract.sh`).

## Identity
- An agent for open models, natively local on Apple silicon: it sees, hears, speaks and codes, in one binary.
- Deepest slice: the coding/computer agent (Execute → Verify → Recover); perception and multimodal are
  product surfaces, not demos.
- Stack: Swift 6.2 · SwiftPM · Hummingbird 2 · SwiftUI · SQLite + FTS5. Two engines:
  MLX Metal GPU + CoreAI (§ Upstream 2).

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

## Adoption — the surface a stranger ranks
- **A release is a cadence, not a green suite or one tag:** the eight installable trees publish 34 → 1 254
  releases, newest ≤8 d old (`scripts/audit-facts.sh`); ours is 1 (`v0.1.14`) — cadence is the open item. The
  tag *is* the version (`scripts/version.sh` prints it), so no doc re-types one. `Core/UpdateCheck.swift` only
  *notifies*; build/publish must split. Ladder: `long-horizon-goal.md` § Rung zero.
<!-- claim:tags_published>=1 :: git ls-remote --refs --tags origin | grep -c 'refs/tags/v' -->
- **Agents are a channel they cannot find:** `/v1/capabilities` serves `endpoints[]`, `skills/ocoreai/` is
  published (probe 39 runs its markers), and `GET /openapi.json` renders the contract off that index; a
  generated client is still missing. Owner call: a public contract is a promise.
- **Intake is a surface:** a duplicate-work check before any outbound issue or PR, answer latency, and a
  verifiable first-screen privacy contract (mechanics + cites: `docs/agent/adoption-runbook.md`).
- **#1 is bounded by distribution, not arithmetic:** 3 469 stars/day for 76 d (`deepseek-harness`),
  1 016/day at 34 d (`Strata`) against our 1 star in 136 d — never call the headline unreachable by math, and
  never chase it: spend on a tag per merge and on a harness consuming us.

## Architecture
HTTP/Handlers → Router/Middleware · Engine: `EnginePool`(actor) → `EngineInference` → MLX | CoreAI ·
Scheduler: SchedulerActor, AdmissionGate, MemoryTracker, OOMGuard · SwiftUI: ChatViewModel,
SessionManager(SQLite). The file per layer and the measured sizes: `ARCHITECTURE.md`.
- `EnginePool` gates backends with inline `#if canImport(CoreAI)`; there is no `BackendProtocol`.
- The two lanes reach the wire by different routes (MLX through upstream `ChatSession`, MTP around it);
  where each line lives is `Sources/ocoreai/Engine/AGENTS.md`.

## Build / Test / Lint
```bash
swift build -c release                 # production build
swift build --traits appStore        # App Store route
swift test                           # full suite; needs Metal
make test                            # same, but names $OCOREAI_METALLIB first — else MLX dies mid-run
make test FILTER=<Regex>             # one suite (swift-testing half: the XCTest helper SEGVs on filter)
make test-clt [FILTER=<Regex>]       # CLT route, serial — runs both halves
make docs-check                      # docs contract: ~3 s, no build
bash scripts/eval/run.sh               # task-success scoreboard: verifies the WORKSPACE, not the prose
```
- Gate tiering: **sandbox** → app-target build + non-Metal suites; **escalation** → `make test-clt`
  + `make probes` (live `/v1/*`); **CI only** → `xcodebuild` (`test-ci`, iOS build).
- CLT SDK ≠ CLT compiler: an unpinned `SDKROOT` breaks even the manifest, and on the CLT route every
  `canImport(CoreAI)` block compiles out. `make toolchain-check` settles Metal by *compiling a kernel*,
  never by `metal --version`.
- **A gate you did not run is not green; a stated fix that cannot run is no exit.** `make push-ready` runs
  the no-build set, `make audit` parses every recipe. Red is for a claim a reader acts on (prose-shape checks
  are deleted; counts printed carry no verdict, off-pin checks stay advisory). **Prefer a live `serve` +
  `curl` over an inference about behaviour.**
- Style: `swift-format` (`.swift-format`, pinned) via `make format-check`; no other linter.
- Licenses travel with the binary: MIT **plus** third-party terms (BSD-3 cl.1/cl.2, Apache-2.0 §4). Adding
  a dependency, bumping a pin or vendoring a header ⇒ re-run `scripts/collect-third-party-licenses.sh`
  and commit it. Gates: `ThirdPartyNoticesTests`(16) + `scripts/audit.swift_patterns.sh` Class-I;
  composition: `docs/agent/third-party-notices.md`.
<!-- claim:apple_derived_files>=49 :: git grep -l "Copyright 2026 Apple Inc" -- Sources | wc -l -->
<!-- claim:notice_files>=38 :: ls THIRD-PARTY-LICENSES | wc -l -->

## Code Conventions

### Concurrency
- Strict concurrency, `Sendable` enforced: UI is `@MainActor`, engine state actor-isolated, cross-actor
  calls `await`.
- `EnginePool` is an actor with `@unchecked Sendable` perform-isolated mutable state; every
  `@unchecked Sendable` declaration carries a justification comment.
- A continuation wrapped around an SDK callback needs a deadline, **and the caller owns the callback
  object's lifetime**: a delegate the framework does not retain parks the request forever.
- A polling loop sleeps one poll interval, never the deadline; deadline-sleeping inside `while` parks the
  waiter for the whole window and is correct only in a single-shot watchdog.

### Compile-time gates
- `#if canImport(X)` must name the dependency the block actually uses: gating on a framework the code does
  not import silently deletes working code on every platform missing it, while the log keeps claiming the
  capability. Never gate a capability surface on a backend axis — `canImport(CoreAI)` says nothing about
  Metal, vision, tokenizers or the ANE (worked instance: the Engine guide).
- A stub that replaces a real component must be detectable at runtime, not only at compile time: expose the
  flag (`tokenizerBackend: real|heuristic` on `/v1/capabilities`) and assert it.

### Error Handling
- `precondition`/`preconditionFailure` are for structural invariants and upstream-verbatim surfaces only;
  new code adds none. Zero `try!`, `as!`, `fatalError`, `assert` outside comments. `try?` needs
  a real fallback on the next line. `print()` only on CLI/stdout product surface.
<!-- claim:precondition_sites<=14 :: git grep -nE 'precondition(Failure)?\(' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
<!-- claim:precondition_files<=11 :: git grep -nE 'precondition(Failure)?\(' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | cut -d: -f1 | sort -u | wc -l -->
<!-- claim:try_excl_comments<=0 :: git grep -n 'try!' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
<!-- claim:fatalerror_as<=0 :: git grep -nE 'fatalError\(| as! ' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
<!-- claim:print_sites<=2 :: git grep -nE '(^|[^A-Za-z0-9_.])print\(' -- Sources | grep -vE ':[0-9]+: *(//|/\*|\*)' | wc -l -->
- Failure reports name the cause, not the symptom: a failing MCP server's stderr travels inside the
  refusal, screen capture says `blocked` in the framework's words, `unknown` before the first attempt
  (`ScreenDeliveryHonestyTests` + probes 04/26).

### Testing Quality
- Gold standard: exact values a caller can observe (a wire field, a file's bytes, an exit code),
  parameterized traversal, boundary cases. Reject `count > N` where N is knowable; never pin a constant
  copied from the code under test.
- A scan-based test asserts its own premises: find the root by searching, not by fixed
  `deletingLastPathComponent()` hops, and floor its own hit count.
- A fix gates every consumer of the value it changed, not just the emit site.
- Anything that proves behaviour against a live server ships as a script in `scripts/probes/`, so the
  claim outlives the session that made it.
- One scoreboard run is a sample: set size, spread, noise band and the paired-flip floor each live in
  `scripts/eval/README.md` (one home apiece).
- Process-global state (workspace anchor, `OCOREAI_*`, a `shared` sensor) is leased, never
  set: `.serialized` orders a suite's *own* tests, not suites against each other, and a lease never spans
  live I/O. Gate: `ProcessGlobalLeaseDisciplineTests`(3).

## Open — measured, unresolved
Root owes the address only — area, instrument, whose call it waits on (evidence: `docs/agent/open-items.md`;
verdicts: `closed-items-log.md`; `make audit` Class-J keeps every suite name below honest).
- **`/v1/models/:model/…` needs `%2F`** (Handlers/) — owner call.
- **Stall: MTP stops hard, the std lane by consent** (Tools/, Engine/) — `LoopStallTerminationTests`(6);
  owner call: the terminal word for four faces.
- **CoreAI / macOS 27 items unverifiable here** (Engine/) — `PlatformPremise.hasMacOS27`.
- **A no-tool turn cannot be interrupted** (Engine/) — upstream seam at `991266ad3`; owner call.
- **Rewind landed; the reserve is untuned** (Engine/) — `SessionRewindOnDivergenceTests`(7) + probe 27.
- **`tools[]` gaps; two prefix questions await an owner** — `UI/AGENTS.md`, `ReuseRefusalLedger`.
- **Multimodal: video publishes per-checkpoint; capture cannot stream headlessly** —
  `VideoDeliveryLedger`; `screenStatus` needs a delivered frame.
- **The board scores 6 of the 40 advertised tools; full-surface is `OCOREAI_EVAL_TOOLS=all`** (scripts/eval/)
  — every row prices its `tools[]` bytes; judging the two surfaces waits on the owner.
- **The tool surface is still ungated against the loaded model** (UI/, Engine/) — owner call; `reasoning_effort`'s gate (`ReasoningEffortHonestyTests`(9) + probe 38) is the pattern to extend.
- **Only the publish half has never run** (CI/) — `package.yml` is green on a runner (DMG, probe 41, window
  proof); `release`'s publish + read-back stay tag-gated: a tag is a hand.
- **A corpus costs injection; the tail is disclosed, not gated** — injected bytes cost a 2B checkpoint
  double-digit pp; the fall-off is named to the model and on `/v1/capabilities` (`make docs-check` prints
  `deepest-chain=`). Owner: gate by capacity — cites: `docs/agent/open-items.md`.

## Upstream Audit Dependencies
Five empirical sources plus comparators; round verdicts: `CHANGELOG.md`, one diary, one home.
1. **`mlx-swift-lm`** — the `revision:` pin in `Package.swift` is the contract, currently `991266ad3`;
   `Package.swift` keeps the pin and a pointer, never a per-commit diary. Bump protocol: audit the
   consumption surface → bump `.revision` → `make audit` (both lockfiles) → `swift build` +
   `make test-ci` green → `CHANGELOG.md`. Upstream sources live under
   `Libraries/`, not `Sources/`; clone-vs-pin is `git merge-base --is-ancestor`, and the built checkout's
   cleanliness is asserted by `scripts/probes/_lib.sh`, not by prose.
2. **`coreai-models`** — Apple's reference tree, consumed as a fork of `Engine/CoreAI*` (BSD-3; types
   redefined locally — upstream demands macOS 27). Each file's header carries its upstream baseline;
   `make drift` reports the un-adjudicated window. Python/export-side commits: no export surface here.
3. **`codex`** — semantic axis reference (Rust; nothing linked, redistributed, or copied per commit).
4. **Apple Developer Documentation** — DocC for intent and semantics, the SDK's
   `.swiftinterface` for exact signatures and `@available` gates, live execution for behaviour.
5. **Human Interface Guidelines** — <https://developer.apple.com/design/human-interface-guidelines>: on
   anything user-visible it is the authority; no topic covers agents ⇒
   `docs/agent/agent-interface-guidelines.md`.
6. **Comparators** — the 20 trees in `docs/agent/comparator-repos.md`: not pins; nothing linked or
   redistributed, and a borrowed verdict stays inference until a `file:line` says otherwise.
   Shipped order + fix cost per axis: `docs/agent/competitor-iteration-paths.md`.
- **OpenAI / Anthropic compatibility** is judged as vllm and sglang judge it: the spec, their
  implementation, real requests, observed behaviour — not our convenience.
- **A mirror proves content, never HEAD.** `api.github.com` is authoritative for HEAD and compare windows.
- **Host-local is not project evidence**: `~/references/*`, `~/wiki/*`, `.hermes/` are colour, not verdicts.
  Repo-binding verdicts live in `CHANGELOG.md`. Codex-host facts: `docs/agent/codex-runtime.md`.

## Read on demand — detail one hop away
- `docs/agent/instruction-channel.md` — who delivers the caller's `system`/`developer` text and what its
  cache costs.
- `docs/agent/systemone-decisions.md` — upstream's System 1 decision API and the cheapest honest slice.
- `docs/agent/long-horizon-goal.md` — the ladder and what kills it.
- `docs/agent/adoption-runbook.md` — what the leaders run to be installed, cite per part.

## Routing table — working in X → read this first
| Area | Read | Covers |
|---|---|---|
| `Sources/ocoreai/Engine/**` | `Sources/ocoreai/Engine/AGENTS.md` | backend gates, metallib, KV/prefix accounting, steer seam, constrained decoding, rewind |
| `Sources/ocoreai/UI/**` | `Sources/ocoreai/UI/AGENTS.md` | SwiftUI state authority, HIG duties, iOS-parity reality, focus discipline |
| `Sources/ocoreai/Handlers/**`, `Router/`, `Models/`, `Wire/` | `Sources/ocoreai/Handlers/AGENTS.md` | DTO optionality, endpoint promises, discovery contract |
| `Tests/**` | § Testing Quality below | exact-value assertions, scan floors, self-premise checks |
| `scripts/eval/**` | `scripts/eval/README.md` | task success: does the agent finish real jobs |
| `scripts/probes/**` | `scripts/probes/README.md` | live `/v1/*` wire-contract probes |
| this file, `docs/**` | `scripts/agents-md-contract.sh` (`make docs-check`) | budgets, dead pointers, claim reproduction |

Areas without a guide (Scheduler, MCP, Tools, Skills, Multimodal, Video, Security): § Code Conventions
plus the code; three dated notes ⇒ give one an `AGENTS.md` and a row here (a guide costs context only
inside it).

## Documentation Map — Agent-facing vs Human-facing
Text *injected into the model's context at runtime* is **Agent-facing**: a change alters model
behaviour, so it owes a behaviour verdict (priced by the board — `scripts/eval/README.md`). Text read by
people or future agents is **Human-facing** (map: `docs/agent/docs-map.md`).

The three runtime-injected surfaces, where a word is a behaviour change: `Skills/SystemPromptBuilder.swift`
(structure gated, behaviour not), `ToolEntry.swift` + `Tool*.swift` (`description`/schema are
function-calling contracts — test with a live model), `Parsers/*` (marker literals are contracts; pair
against upstream first). Which doc each audience reads, and when: `docs/agent/docs-map.md`.

## Working here
- **Direct commits to `main`**, no branch ritual; CI on macos-26 (`make test-ci`) is the authority.
  `make docs-check` green when touching this file, `docs/**` or a guide; `make push-ready` checks the
  tree: clean, pushed, paired, cites. `CHANGELOG.md` records every user-visible change.
- **One cwd, several sessions:** stage explicit paths and commit only this session's files — never
  `git add -A`/`git add .`, which sweeps in another session's half-work.
- Verification is three layers: grep → compile → read the matched lines; a single-layer check is
  speculation. `swift build` exit 0 before any completion claim; findings cite `file:line`; label
  inference as inference.
- Before writing a symbol, grep for the mechanism that already exists; before calling a missing upstream
  API, check § Upstream.
- **Footprint ladder — take the highest rung that solves it:** consume upstream → extend an existing seam →
  opt-in flag/trait → tool or skill → new module → new core/agent-facing surface. A new surface needs a
  consumer that exists today.
- **Refused even when well-built** (the list hermes-agent keeps too): a guard for a failure nobody quoted;
  a test that only detects change; a second home for a decision; a new core tool where a file tool or a
  skill already does it — only that last clause is machine-decidable, hence the ceiling below.
<!-- claim:core_tools<=43 :: git grep -h 'ToolEntry\.typed(' -- Sources/ocoreai/Tools | grep -vE '^[[:space:]]*(//|\*)' | wc -l -->
- **One home per decision, and a side effect is gated where it is declared:** `ToolEntry.isDestructive` is
  the only destructive truth and `securityPrecheck` asks from it (∪ blacklist for names nothing registers) —
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
  own argument asks for it:** `edit_file` offers `rm` solely when `newString` is empty, since in an ordinary
  mismatch that offer turns a typo into an unrecoverable delete. Gate: `EditMismatchRecoveryTests`(10). HIG
  is authority on anything user-visible; the five non-happy states owe honest copy and a way out
  (`Sources/ocoreai/UI/AGENTS.md`).
- **A file's lifetime is the lifetime of the thing that cites it.** Bytes outliving their request need an
  owner, a pin in flight, and collection by idle TTL + byte budget. `MediaSpool`; gates:
  `MediaLifetimeTests`(15) + probe 08.
- **Comments say the *why* the code cannot, in 1–3 lines.** No bug history, dates or audit trails inside
  source comments — that is the commit message. One logical change per commit.
- **A lock lives at the cheapest rung that bites:** hook → `make` → CI, priced in runner-seconds (text
  gates go to ubuntu; arm64 minutes are the expensive seat). A gate blocks only when a red means someone
  acted on something false; prose-shape checks are deleted, not downgraded, and a new one names the red
  it was sampled against and the reader whose action it changes (`CONTRIBUTING.md`). **Gate count is never
  the deliverable, and no gate is installable** — see § Adoption.
- **No defensive clutter; no guard for a failure nobody observed.** Validate once at the boundary that owns
  the value and pass typed values inward; quote the failure (a probe line, a red test, a scoreboard row)
  before writing its guard. For a speculative race or security edge: name the mode, likelihood and cost and
  get the owner's buy-in — no scope for theoretical robustness.
- Default is one-pass in this thread, no sub-agent unless the owner asks (the owner reviews every
  commit).

## Taste test before you hand off
- Does every piece of state live with its authority, at the narrowest scope that can still be right?
- Can any sentence a user can read promise more than the engine measured?
- Does each resolver/fallback have one home, a validated ladder, and a bounded, recoverable end?
- Is the hot path still cheap under *realistic* content — long transcript, warm KV, a real model — not the
  empty demo?
- Did the user, developer and agent reading this each end up better off?
