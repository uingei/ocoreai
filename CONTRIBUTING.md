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

## Branch Workflow

Work on a branch, ship through a PR against `main`. Never push feature work
directly to `main`.

- Branch naming: `feat/<slug>`, `fix/<slug>`, `docs/<slug>`, `chore/<slug>`
- Open an issue first for anything non-trivial, link it in the PR
- One logical change per PR

```bash
# Sync before PR
git fetch origin
git rebase origin/main
```

## Evidence Is Required

The binding shipping standard is [`.github/PR_EVIDENCE.md`](.github/PR_EVIDENCE.md).

### The three questions (applies to every important change, not just PRs)

A change earns its place only if it can answer all three, in that order:

1. **What improved?** Name the behaviour, not the code — "grammar-constrained turns
   stopped returning 500 after valid output", not "refactored the sampler".
2. **What makes you think it improved?** Point at command output from the *same*
   session as the claim (build/test/live probe/grep), and prefer a behaviour-level
   check over a code-level one. An inference is labelled as an inference.
3. **How does it stop regressing?** Name the gate that goes red if the improvement
   disappears: a test, an audit check, a CI step. "I was careful" is not a gate.

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
context on every session: a stale number there is not a typo, it is a wrong instruction.
`make docs-check` (`scripts/agents-md-contract.sh`) budgets the injected files (shrink-only),
resolves every path and `file:line` anchor they name, re-runs every
`<!-- claim:id OP N :: command -->` marker, and fails when a scan's own hit count drops below its
floor. Write a claim together with its instrument, on the same line: `>=` for a floor that must not
shrink (attribution, endpoint rows), `<=` for a ceiling that must not grow (`print`, `try!`, `TODO`),
and `=` only for facts that move when the doc itself is edited (a pin, a budget).

> A reviewer must be able to confirm the change works **by watching it happen
> and inspecting the artifacts you attached.**

Every PR includes:
- **Build verification** — `swift build -c release` passes
- **Test results** — `swift test --enable-code-coverage` passes
- **MLX/CoreAI logs** — real inference logs when compute channel changed
- **Hardware routing trace** — when `HardwareRouter` / `AdmissionGate` changed
- **Visual evidence** — before/after screenshots for SwiftUI changes

If an evidence type doesn't apply, mark it `N/A - <reason>`. Don't leave it blank.

## Code Review Process

The review process is [two-axis](.github/REVIEW.md):

1. **Standards axis** — Does the code follow repo conventions, Swift best practices, and the smell baseline?
2. **Spec axis** — Does the code faithfully implement the issue/description?

Each finding gets a confidence score (0–100). Only findings ≥ 80 are reported.
This prevents noisy reviews — only report what you're sure about.

Self-review discipline (7-step with forced self-negation) before marking a PR
ready.

## Pre-Commit Verification

Before committing, run the 8-step verification pipeline:

1. **Diff extraction** — `git diff --cached`
2. **Static security scan** — hardcoded keys, secrets, injection patterns
3. **Baseline test + format** — `swift test`, swift-format gate
4. **Self-review checklist** — secrets, input validation, debug leftovers
5. **Standards review** — repo conventions + Swift smell baseline
6. **Spec review** — implementation fidelity to the issue/description
7. **Auto-fix loop** — fix findings, re-verify (max 2 cycles)
8. **Commit** — with `[verified]` prefix

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

## Pull Requests

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

Before marking a PR ready, self-assess the risk:

| Risk | Meaning | Requires |
|---|---|---|
| **Low** | Rollback is a revert; no user action needed | N/A |
| **Medium** | Users may need to update config/behavior | Rollback plan in PR description |
| **High** | Security-critical, breaking API, hardware behavior change | Rollback plan + observable failure symptoms + feature flag if possible |

### PR Workflow

```
fork → branch → commit → push → open PR → review → merge (squash)
```

- **PR template is mandatory** — fill every section in `.github/PULL_REQUEST_TEMPLATE.md`
- **Validation evidence is required** — paste actual command output, not "CI will check"
- **"It works on my machine" is not evidence**
- **Small PRs first** — prefer `XS/S/M`. Split large work into stacked PRs
- **One concern per PR** — avoid mixing refactor + feature + infra
- **Merge style:** squash-merge with conventional commit in the body

## Architecture Context

Before architecture-sensitive changes, read:
- `.github/REVIEW.md` — review process
- `Sources/ocoreai/Scheduler/HardwareRouter.swift` — routing logic

## Questions?

Open an issue or discuss in the existing PR.
