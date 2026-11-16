# Contributing to ocoreai

Thanks for your interest. ocoreai is a dual-channel ML inference runtime for
macOS — MLX (GPU) and CoreAI (ANE) with dynamic hardware routing via
`HardwareRouter`.

## Quick Start

```bash
# Clone and build
git clone https://github.com/uingei/ocoreai.git
cd ocoreai

# Build
swift build -c release

# Test
swift test --enable-code-coverage

# Run
swift run
# → HTTP gateway + UI; curl http://127.0.0.1:8080/health
```

## Shipping Route

Direct commits to `main` — no branch ritual; `AGENTS.md` § Working here owns the
rule (stage explicit paths, one logical change per commit, only this session's
files). Non-trivial work owes an issue first only if it needs a decision from
outside this session. The CI legs judge every push; the gates worth running
before it are named in `AGENTS.md` § Build / Test / Lint, and `make push-ready`
is the no-build set.

## Evidence Is Required

Evidence is the three questions below, answered where the change records itself: the
`CHANGELOG.md` contract for user-visible work, the commit body otherwise.

### The three questions (applies to every important change, not just PRs)

A change earns its place only if it can answer all three, in that order:

1. **What improved?** Name the behaviour, not the code — "grammar-constrained turns
   stopped returning 500 after valid output", not "refactored the sampler".
2. **What makes you think it improved?** Point at command output from the *same*
   session as the claim (build/test/live probe/grep), and prefer a behaviour-level
   check over a code-level one. An inference is labelled as an inference.
3. **How does it stop regressing?** Name the gate that goes red if the improvement
   disappears: a test, an audit check, a CI step. "I was careful" is not a gate.

Answer in sentences and point at the receipt: an entry that outgrows the change it records is the
diary doing feature work, and prose written to be quoted grows a new falsehood with every fact move.

If question 3 has no answer, the change is a *claim* — write it down as an open item
with the instrument that would settle it, and leave the behaviour alone. This repo has
repeatedly paid for improvements that were only ever asserted (see CHANGELOG's
retractions: the prefix-reuse reading, `cached_tokens` "liar", the 8.36s→0.25s
attribution), and for fixes whose gate could not run locally so the failure surfaced in
CI or in a shipped DMG.

The gate must also assert **its own premises**. A check that infers the platform from
its environment (`DEVELOPER_DIR`, a `MacOSX.sdk` symlink, "CLT means no CoreAI") rots
silently the day the toolchain updates — `make toolchain-check`
(`scripts/toolchain-contract.sh`) exists because exactly that happened on 10-14.

The docs layer is held to the same standard, because `AGENTS.md` is injected into the model's
context on every session: a stale number there is not a typo, it is a wrong instruction. The
standard is now carried by convention plus the code-shaped tests that survive it
(`InstructionBudgetSingleSourceTests` binds the cap sentence to `WorkspaceContext`;
`DependencyPinStatementTests` binds the pin quote to the manifest); the bespoke machinery that
re-ran every path, anchor and `<!-- claim:id OP N :: command -->` marker — `make docs-check`,
`make anchor-check` and their scripts — was **retired 11-16** on the owner's ruling after reading
the consumed trees: mlx-swift-lm verifies its docs by *building* them, coreai-models' CI is
compile+test+format, and no tree greps its own prose. Where a doc quotes a number, keep the
re-greppable command beside it — a claim without an instrument is an instruction nobody can
re-check; re-checking is now the touching reader's job, and the `claim:` markers stay as the record
of each instrument's shape.

A cite into a comparator tree is a promise with an expiry date: a mirror's HEAD moves by design.
Re-read the window before repeating a cite, and write the struct or function beside any line
number so a moved line is catchable by eye — living prose cites symbols; line numbers survive only
as frozen findings.

**Red is for a claim someone acts on; a warning is for everything else.** The test is not "can this be
checked" but "who is misled when it breaks": a wire field, a tool result, a README sentence, an injected
line a model obeys ⇒ red; volume and shape in a file nobody is obliged to read ⇒ a printed number. The
rule is asymmetric on purpose — invariant 1 cuts at the gates too, so a check that has never gone red on
real work is decoration with an exit code, and a red that blocks a correctness fix taxes the fix, not
the rot.

**The tiers, named** (after the 11-16 retirement, two tiers remain):

- **Blocking** — what a compiler, a test, a live probe or the runtime itself can decide: build +
  suites, `make audit` (code patterns, lockfile sync, dead type names in architecture prose,
  makefile parse), swift-format, the pinned toolchain contract, the live probes, and the runtime
  32 KiB chain cap that *names its cuts* (`WorkspaceContext`). Every injected rule is enforced by
  code or honored by a reader; nothing greps prose any more — the P-/B- tier's whole history
  (floors, anchors, claim re-runs, byte ratchets, and the 10-28 deletion of the prose-shape family)
  is the record of how much maintenance one cannot afford to rent.
- **Deleted, not demoted** — kept as the standing rule: a check that only detects prose shape is
  friction, and friction trains readers to skim. New checks belong to the Blocking list's kinds
  only.

Three duties come with that:

- **A new gate pays its own way.** Name the red you sampled to prove it bites, and the reader whose
  action it changes. Prefer widening an existing check, or making a live probe runnable cheaply, over
  a new static scan: probe 37 exists so contract claims stop needing bespoke static proxies, and it
  decides 19 assertions in seconds with no model resident.
- **Meta-work is measured, not assumed free.** Count the commits that went to gates against the ones
  that went to product, and price a gate in *attention*, not runner-seconds — a 3 s check that prints
  prose-shape noise on every run still costs. When the ratio moves the wrong way the fix is to retire
  a check, not to document it better (the measured figures live in `CHANGELOG.md`, rounds `10-27(20)`
  and `10-27(22)`).
- **Gate count is never the deliverable.** 329 of 1415 commits here went to docs/CI/gates — one per
  three product commits — with 3.3k tests, 37 probes and 78 doc checks, while the repo had **zero
  tags**: nothing about the gate stack can be installed, so none of it is what a user would rank us
  on. A gate is worth the false claim it retires; the mission's unit is task success on real jobs
  (`scripts/eval/run.sh`), and that is where the next hour goes.

> A reviewer must be able to confirm the change works **by watching it happen
> and inspecting the artifacts you attached.**

Every PR includes:
- **Build verification** — `swift build -c release` passes
- **Test results** — `swift test --enable-code-coverage` passes
- **MLX/CoreAI logs** — real inference logs when compute channel changed
- **Hardware routing trace** — when `HardwareRouter` / `AdmissionGate` changed
- **Visual evidence** — before/after screenshots for SwiftUI changes

If an evidence type doesn't apply, mark it `N/A - <reason>`. Don't leave it blank.

## Verifying Before You Commit

The tiers live in `AGENTS.md` § Build / Test / Lint: sandbox gates first, escalation
when the change touches Metal or the wire; `swift build` exit 0 before any completion
claim; `make push-ready` before the push. The three questions above are the review —
no score threshold, no pipeline ritual stands between a change and its gate.

## Secret Management — Merge Gate

Local API keys and credentials:

1. **Environment variables** — Set via shell (`.zshrc`, `.bashrc`). `.env` files are git-ignored.
2. **Never commit** — API keys, tokens, passwords, or credentials in any source file.
3. **Never commit PII** — Real names, emails, user identities in tests or fixtures. The full content discipline is the merge gate.

**Secret detection is the platform's job**: enable GitHub secret scanning + push protection (maintained
signatures, blocks at push time). `Tests/`/eval fixtures carry fake keys.

**If a secret lands in a commit by accident:**
1. Rotate the credential **immediately**
2. Purge history with `git filter-repo` or BFG (not `git revert` — history still contains the secret)
3. Remove the leaked value from any PR, issue, or comment that quoted it

Quick manual audit of the staged diff:
```bash
git diff --cached | grep -iE '(api[_-]?key|secret|token|password|bearer|sk-)'
git status --short | grep -E '\.env$'
```

## Code Style & Conventions

- **Swift 6** strict concurrency
- **@Observable** for state management
- **SwiftUI** following Apple HIG
- **Structured logging** with `[ClassName]` prefix
- **No `force try` / `!` unwrap in `Sources/`** — these are crash-risks blocked by CI
- **i18n** — UI strings must use localization (no hardcoded English in UI)
- **Dynamic Type** — all text must support Dynamic Type via `Font.system(textStyle:)`
- **No unused code** — delete it, wire it into behavior, or track a follow-up issue. Do not silence with `// ignore`
- **Error handling** — `try` with `do/catch` in production paths; no `try!` unless the invariant is documented

Static patterns that CI blocks in `Sources/`:
- `force_unwrapping` (error level)
- `implicitly_unwrapped_optional` (error level)
- `fatal_error_message` (error level)

## Testing — Five Levels

All tests live flat in `Tests/ocoreaiTests/` (no per-level subdirectories); shared test code goes in `Tests/ocoreaiTestUtilities/`.

| Level | What it tests | Example classes (valid `--filter` targets) |
|---|---|---|
| **Unit** | Single function/struct | `InputLayoutTests`, `AgenticThinkTagParserVendoredTests` |
| **Integration** | Multiple subsystems wired together | `GuidedGenerationIntegrationTests`, `HardwareRouterIntegrationTests` |
| **System** | Full request → response across boundaries | `ChatPipelineBehavioralTests`, `ServerAuthGateTests` |
| **Boundaries (live-ish)** | State-machine / boundary logic with real backends simulated | `SystemContextSensorTests`, `ExecSessionsTests` |

**Running tests:**
```bash
swift test                               # full suite
swift test --filter ServerAuthGateTests  # one class
swift test --enable-code-coverage        # with coverage
```

There is no `--enable-live` flag and no `Tests/OcoreAI/{Component,Integration,System,Live}` tree — the test target is `ocoreaiTests` (see `Package.swift`), and `--filter` takes a test-class name, not a suite prefix.

**Testing discipline:**
- Exercise the **real path** — a test that swaps the inference backend for a stub is not a test of your feature
- Assert **outcomes**, not routing — "a request was forwarded" ≠ "the right output was produced"
- Cover **error paths** — backend unavailable, model not found, oversized input, GPU memory pressure, timeout
- If the existing tests for your area are shallow or mocked, **fixing them is part of your change**
- Use `@Test` from Swift Testing framework for new tests

## Commits

### Commit Messages

Conventional Commits:
```
feat(routing): add thermal-aware GPU dispatch
fix(chat): prevent unbounded message queue growth
docs(architecture): add hardware router ADR
refactor(coreai): split model compilation from inference
chore: bump MLX to 0.22
```

### Risk Labels

Before committing a risky change, self-assess the risk:

| Risk | Meaning | Requires |
|---|---|---|
| **Low** | Rollback is a revert; no user action needed | N/A |
| **Medium** | Users may need to update config/behavior | Rollback plan stated in the commit body |
| **High** | Security-critical, breaking API, hardware behavior change | Rollback plan + observable failure symptoms + feature flag if possible |

### The Route

Work lands on `main` directly (§ Shipping Route). What survives the old PR list,
scoped to the commit: keep changes small; one concern per commit; paste actual
command output where evidence is asked — "it works on my machine" is not evidence.

## Architecture Context

Before architecture-sensitive changes, read:
- `Sources/ocoreai/Scheduler/HardwareRouter.swift` — routing logic

## Questions?

Open an issue or discuss in the existing PR.
