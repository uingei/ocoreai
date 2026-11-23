# ocoreai. Project context for AI agents

> Injected into every session, so it carries **rules and pointers only**: a root rule is ≤3 lines
> (what + the one-line evidence + the gate). Dated incidents and measurements live in
> `CHANGELOG.md` and `docs/agent/`. If this file and the code disagree, the code is the fact: fix
> whichever is wrong.
>
> **The cap is real:** the injector spends at most 32 KiB on the chain (this file + every
> `AGENTS.md` to the cwd) and *names every cut it makes*
> (`WorkspaceContext.maxDocBytes`; `InstructionBudgetSingleSourceTests` binds this sentence to it);
> past the cap a rule is not deferred, it is never read.

## How we work. Pstack (owner ruling 11-17)
- Engineering discipline is the pstack plugin: the operator starts rigorous tasks with
  `/pstack:poteto-mode` (install `pstack@cursor-plugins`; model budget via `/pstack:setup-pstack`).
  Its principles live in its own skill leaves and are deliberately **not re-typed here**. A rule
  with two homes drifts through one.
- The same ruling retires the old default "one-pass in this thread, no sub-agent": delegates run as
  `poteto-agent`s under pstack's routing, and the owner still reviews every commit.
- Replies, commits and prose follow pstack's unslop / technical-writing; a comment says the *why*
  the code cannot, ≤3 lines, no dates and no bug history, that is the commit message.
- What pstack cannot own and this file must: the two invariants, the repo rules below, and every
  gate named here.

## Identity
- An agent made for open models, natively local on Apple silicon: it sees, hears, speaks and codes,
  in one binary. Deepest slice: the coding/computer agent (Execute → Verify → Recover); perception
  and multimodal are product surfaces, not demos.
- Stack: Swift 6.2 · SwiftPM · Hummingbird 2 · SwiftUI · SQLite + FTS5. Two engines:
  MLX Metal GPU + CoreAI (§ Upstream 2).

## Two invariants
Almost every rule below is a corollary; when a shortcut collides with an invariant, the invariant wins.
1. **A claim is worth exactly the gate that goes red when it breaks.** A fix with no gate is a claim;
   a gate that infers its own premises from the environment rots the day the toolchain moves; a scan
   that stopped matching passes vacuously unless it floors its own hit count; a doc whose numbers
   nobody re-greps drifts.
2. **The surface never claims more than the engine delivered.** Anything a user can read (a wire
   field, the dashboard, a tool result) must be measured, and must degrade honestly where the backend is absent. A file tool's `OK` is durability, not validity: the
   verdict travels in one result (`OK-but-invalid`). When authority is unclear: run it and read the answer.

## Three readers. UX · DX · AX (owner ruling 11-16: a principle, not a feature)
Every significant decision. Design, architecture, docs, tests, release. Prices its real effect on
user, developer and agent experience; gains must be joint, never one bought by another, and are
judged by measured use, not checklist completeness; full text: the matrix § 17.

## Build / Test / Lint
```bash
swift build -c release                 # production build
swift build --traits appStore          # App Store route
swift test                             # full suite; needs Metal
make test                              # same, but names $OCOREAI_METALLIB first — else MLX dies mid-run
make test FILTER=<Regex>               # one suite by name (one test target — no half to skip)
make test-clt [FILTER=<Regex>]         # CLT route, serial — same target, whole suite
bash scripts/eval/run.sh               # task-success scoreboard: verifies the WORKSPACE, not the prose
```
- Gate tiering: **sandbox** → app-target build + non-Metal suites; **escalation** → `make test-clt`
  + `make probes` (live `/v1/*`); **CI only** → `xcodebuild` (`test-ci`, iOS build).
- CLT SDK ≠ CLT compiler: an unpinned `SDKROOT` breaks even the manifest, and on the CLT route every
  `canImport(CoreAI)` block compiles out. `make toolchain-check` settles Metal by *compiling a kernel*,
  never by `metal --version`.
- **A gate you did not run is not green; a stated fix that cannot run is no exit.** `make push-ready` runs
  the no-build set, `make audit` parses every recipe. Red is for a claim a reader acts on; a check that
  only detects prose shape is deleted, not demoted. **Prefer a live `serve` + `curl` over an inference about behaviour.**
- Style: `swift-format` (`.swift-format`, pinned) via `make format-check`; no other linter.
- Licenses travel with the binary: MIT **plus** third-party terms (BSD-3 cl.1/cl.2, Apache-2.0 §4).
  Adding a dependency, bumping a pin or vendoring a header ⇒ re-run
  `scripts/collect-third-party-licenses.sh` and commit it. Gates: `ThirdPartyNoticesTests` +
  `scripts/audit.swift_patterns.sh` Class-I; composition: `docs/agent/third-party-notices.md`.

## Code Conventions
- Concurrency: strict, `Sendable` enforced. UI is `@MainActor`, engine state is actor-isolated,
  cross-actor calls `await`; every `@unchecked Sendable` declaration carries a justification comment.
  A continuation wrapped around an SDK callback needs a deadline **and the caller owns the callback
  object's lifetime**; a polling loop sleeps one poll interval, never the deadline.
- Compile-time gates: `#if canImport(X)` must name the dependency the block actually uses, and never
  gates a capability surface on a backend axis, `canImport(CoreAI)` says nothing about Metal, vision,
  tokenizers or the ANE. A stub that replaces a real component exposes its flag and is assertable at
  runtime (`tokenizerBackend` on `/v1/capabilities`).
- Errors: `precondition` is for structural invariants only, new code adds none; zero `try!`, `as!`,
  `fatalError`, `assert`; `try?` needs a real fallback on the next line. A failure report names the
  cause in the framework's own words, `unknown` before the first attempt (`ScreenDeliveryHonestyTests` + probes 04/26).
- Tests assert exact values a caller can observe (a wire field, a file's bytes, an exit code),
  parameterized, with boundary cases; reject `count > N` where N is knowable; a scan-based test
  floors its own hit count and finds its root by searching, not by fixed path hops; anything proving
  behaviour against a live server ships in `scripts/probes/`.
- Process-global state (workspace anchor, `OCOREAI_*`, a `shared` sensor) is leased, never set, and a
  lease never spans live I/O (`ProcessGlobalLeaseDisciplineTests`).
- One home per decision, and a side effect is gated where it is declared: `ToolEntry.isDestructive` is
  the only destructive truth and `securityPrecheck` asks from it (∪ blacklist for names nothing
  registers). A hand-copied matcher list leaves mutating tools unasked (`DestructiveApprovalGateTests`).
  Name a destructive route only where the caller's own argument asks for it: `edit_file` offers `rm`
  solely when `newString` is empty (`EditMismatchRecoveryTests`).
- A file's lifetime is the lifetime of the thing that cites it: bytes outliving their request need an
  owner, a pin in flight, and collection by idle TTL + byte budget (`MediaSpool`; `MediaLifetimeTests` + probe 08).
- One resolver, one ladder: precedence as data, a candidate trusted only once probed, a failed *read*
  falling to the next rung, a failed *authoritative write* surfacing or rolling back, bounded retries
  ending in a recovery affordance. Pattern: `MetalShaderLibrary`.

## Architecture
HTTP/Handlers → Router/Middleware · Engine: `EnginePool`(actor) → `EngineInference` → MLX | CoreAI ·
Scheduler: SchedulerActor, AdmissionGate, MemoryTracker, OOMGuard · SwiftUI: ChatState
(`ChatViewModel.swift`), SessionManager(SQLite). The file per layer and the invariants: `ARCHITECTURE.md`.
- `EnginePool` gates backends with inline `#if canImport(CoreAI)`; there is no `BackendProtocol`.
- The two lanes reach the wire by different routes (MLX through upstream `ChatSession`, MTP around it);
  where each line lives is `Sources/ocoreai/Engine/AGENTS.md`.

## Adoption. The surface a stranger ranks
- **A release is a cadence, not a green suite or one tag:** cadence is the open item; the re-measurable
  field ceiling lives at `long-horizon-goal.md` § Rung zero (audit-facts.sh is its instrument). The tag
  *is* the version (`scripts/version.sh` prints it), so no doc re-types one; `Core/UpdateCheck.swift`
  only *notifies*. Build/publish must split.
- **Agents are a channel they cannot find:** `/v1/capabilities` serves `endpoints[]`, `skills/ocoreai/`
  is published (probe 39 runs its markers), `GET /openapi.json` renders the contract off that index;
  no client ships yet. The canonical SDK consumes the wire itself, gated (probe 56).
- **Intake is a surface:** duplicate-work check before any outbound issue or PR, answer latency, a
  verifiable first-screen privacy contract; **#1 is bounded by distribution, not arithmetic**. Never
  call the headline unreachable by math, never chase it: spend on a tag per merge and on a harness
  consuming us (mechanics + stars/day table: `docs/agent/adoption-runbook.md`).

## Upstream Audit Dependencies
Five empirical sources plus comparators; round verdicts: `CHANGELOG.md`.
1. **`mlx-swift-lm`**. The `revision:` pin in `Package.swift` is the contract; the number lives in the
   manifest, never re-typed here, and `DependencyPinStatementTests` binds the manifest's prose and pins
   to `Package.resolved`. Bump protocol: audit the consumption surface → bump `.revision` →
   `make audit` (both lockfiles) → `swift build` + `make test-ci` green → `CHANGELOG.md`. Upstream
   sources live under `Libraries/`, not `Sources/`; clone-vs-pin is `git merge-base --is-ancestor`, and
   the built checkout's cleanliness is asserted by `scripts/probes/_lib.sh`.
2. **`coreai-models`**. Apple's reference tree, consumed as header-stamped forks (BSD-3; types
   redefined locally. Upstream demands macOS 27). Each file's header carries its upstream baseline;
   `make drift` reports the un-adjudicated window.
3. **Apple Developer Documentation**. DocC for intent, the SDK's `.swiftinterface` for exact
   signatures and `@available` gates, live execution for behaviour.
4. **Human Interface Guidelines**. <https://developer.apple.com/design/human-interface-guidelines>: on
   anything user-visible it is the authority; no topic covers agents ⇒
   `docs/agent/agent-interface-guidelines.md`.
5. **Comparators**. The trees in `docs/agent/comparator-repos.md` (+ diffusion/comparator docs):
   nothing linked or redistributed; a borrowed verdict without a `file:line` stays inference. The
   standard is `~/references`' **shipped practice**, not this tree's habit: where those trees (read at
   HEAD, cited `file:line`) conflict with in-tree precedent, references win; deviation needs an owner
   reason, never implementation-legacy. `~/wiki/*`, `.hermes/` stay colour.
- **OpenAI / Anthropic compatibility** is judged as vllm and sglang judge it: the spec, their
  implementation, real requests, observed behaviour, not our convenience.
- **A mirror proves content, never HEAD.** `api.github.com` is authoritative for HEAD and compare windows.

## Open. Measured, unresolved
Root owes the address only. Area, instrument, whose call it waits on; full evidence: `docs/agent/open-items.md`.
- Loop stall stops hard, and the std lane only by consent. Owner call: the terminal word (`LoopStallTerminationTests`).
- A no-tool turn steers and stops flag-staged (both #608/#798 halves on the std lane). Owner call: the default flip; bypass lanes keep rollback.
- The tool surface is ungated against the loaded model. Owner call; `reasoning_effort`'s gate
  (`ReasoningEffortHonestyTests` + probe 38) is the pattern to extend.
- The surviving release is ad-hoc signed; Gatekeeper's download path stays unjudged. Owner call (probe 41).
- CoreAI / macOS 27 items unverifiable on this host, `PlatformPremise.hasMacOS27`.

## Documentation Map. Agent-facing vs Human-facing
Text *injected into the model's context at runtime* is **Agent-facing**: a change alters model
behaviour, so it owes a behaviour verdict (priced by the board, `scripts/eval/README.md`). Text read
by people or future agents is **Human-facing** (map: `docs/agent/docs-map.md`). The three
runtime-injected surfaces, where a word is a behaviour change: `Skills/SystemPromptBuilder.swift`
(structure gated, behaviour not), `ToolEntry.swift` + `Tool*.swift` (`description`/schema are
function-calling contracts. Test with a live model), `Parsers/*` (marker literals are contracts;
pair against upstream first).

## Routing table. Working in X → read this first
Read-on-demand topics: `docs/agent/instruction-channel.md` (who delivers `system`/`developer` text and
its cache cost), `systemone-decisions.md` (upstream's decision API), `long-horizon-goal.md` (the ladder
and what kills it), `adoption-runbook.md`, `references-conformance-matrix.md` (the full `~/references` audit).

| Area | Read | Covers |
|---|---|---|
| `Sources/ocoreai/Engine/**` | `Sources/ocoreai/Engine/AGENTS.md` | backend gates, metallib, KV/prefix accounting, steer seam, constrained decoding, rewind |
| `Sources/ocoreai/UI/**` | `Sources/ocoreai/UI/AGENTS.md` | SwiftUI state authority, HIG duties, iOS-parity reality, focus discipline |
| `Sources/ocoreai/Handlers/**`, `Router/`, `Models/`, `Wire/` | `Sources/ocoreai/Handlers/AGENTS.md` | DTO optionality, endpoint promises, discovery contract |
| `Tests/**` | § Code Conventions above | exact-value assertions, scan floors, self-premise checks |
| `scripts/eval/**` | `scripts/eval/README.md` | task success: does the agent finish real jobs |
| `scripts/probes/**` | `scripts/probes/README.md` | live `/v1/*` wire-contract probes |
| this file, `docs/**` | `scripts/docs-type-existence.sh` (in `make audit`) | dead type names in architecture prose |

Areas without a guide (Scheduler, MCP, Tools, Skills, Multimodal, Video, Security): § Code Conventions
plus the code.

## Working here
- **Direct commits to `main`**; CI on macos-26 (`make test-ci`) is the authority. Stage explicit paths
  and commit only this session's files. Never `git add -A`/`git add .`: several sessions share this
  cwd. One logical change per commit; `CHANGELOG.md` records every user-visible change.
- **Every claim answers the three questions** (what improved · what same-session output proves it ·
  which gate goes red if it regresses). The contract lives in `CONTRIBUTING.md`; missing the third
  makes it a claim. Where upstream already has the answer, consume it or cite `file:line`; do not
  author a local variant.
- Verification is three layers: grep → compile → read the matched lines. `swift build` exit 0 before
  any completion claim; findings cite `file:line`; living prose cites symbols; label inference as inference.
- Before writing a symbol, grep for the mechanism that already exists. **Footprint ladder. Take the
  highest rung that solves it:** consume upstream → extend an existing seam → opt-in flag/trait → tool
  or skill → new module → new core/agent-facing surface. A new surface needs a consumer that exists today.
- **Respect the person using it.** Never navigate, refocus, open a pane or announce because something
  *happened* in the background. Offer, don't hijack. HIG is authority on anything user-visible; the
  five non-happy states owe honest copy and a way out (`Sources/ocoreai/UI/AGENTS.md`).
- **A lock lives at the cheapest rung that bites:** hook → `make` → CI, priced in runner-seconds. A gate
  blocks only when a red means someone acted on something false, and a new one names the red it was
  sampled against and the reader whose action it changes (`CONTRIBUTING.md`). **Gate count is never the
  deliverable, and no gate is installable**. See § Adoption.
- **No defensive clutter:** validate once at the boundary that owns the value; quote the failure (a
  probe line, a red test, a scoreboard row) before writing its guard. For a speculative race or
  security edge: name mode, likelihood and cost and get the owner's buy-in.
