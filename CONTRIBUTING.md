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
swift run ocoreai chat --backend mlx "Hello"
swift run ocoreai chat --backend coreai "Hello"
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
ready. See the `code-review-discipline` skill for the full flow.

## Pre-Commit Verification

Before committing, run the 8-step verification pipeline:

1. **Diff extraction** — `git diff --cached`
2. **Static security scan** — hardcoded keys, secrets, injection patterns
3. **Baseline test + lint** — `swift test`, SwiftLint
4. **Self-review checklist** — secrets, input validation, debug leftovers
5. **Standards review** — repo conventions + Swift smell baseline
6. **Spec review** — implementation fidelity to the issue/description
7. **Auto-fix loop** — fix findings, re-verify (max 2 cycles)
8. **Commit** — with `[verified]` prefix

See `requesting-code-review` skill for the full pipeline.

## Secret Management — Merge Gate

Local API keys and credentials:

1. **Environment variables** — Set via shell (`.zshrc`, `.bashrc`). `.env` files are git-ignored.
2. **Never commit** — API keys, tokens, passwords, or credentials in any source file.
3. **Never commit PII** — Real names, emails, user identities in tests or fixtures. The full content discipline is the merge gate.

Pre-commit secret scan (recommended):

```bash
brew install gitleaks
git config core.hooksPath .github/hooks
```

Or run manually:
```bash
bash .github/pre-commit-gitleaks.sh
```

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

> Adapted from zeroclaw testing taxonomy (references/zeroclaw/docs/book/src/contributing/testing.md)

Pick the lowest level that proves what you need to prove:

| Level | What it tests | Boundary | Test Location |
|---|---|---|---|
| **Unit** | Single function/struct | Everything isolated | Co-located `#if TESTING` blocks |
| **Component** | One subsystem in isolation | Subsystem real, rest mocked | `Tests/<Target>/Component/` |
| **Integration** | Multiple subsystems wired together | Real internals, external mocked | `Tests/OcoreAI/Integration/` |
| **System** | Full request→response across boundaries | Only external mocked | `Tests/OcoreAI/System/` |
| **Live (.enable-live)** | Real inference backends (MLX/CoreAI) | Nothing mocked | `Tests/OcoreAI/Live/` with build flag |

**Running tests:**
```bash
swift test                                     # unit + component + integration
swift test --filter OcoreAITests.System        # system only
swift test --enable-live                       # live (requires real backends)
swift test --enable-code-coverage              # with coverage
```

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

- **PR template is mandatory** — fill every section in `.github/pull_request_template.md`
- **Validation evidence is required** — paste actual command output, not "CI will check"
- **"It works on my machine" is not evidence**
- **Small PRs first** — prefer `XS/S/M`. Split large work into stacked PRs
- **One concern per PR** — avoid mixing refactor + feature + infra
- **Merge style:** squash-merge with conventional commit in the body

## Architecture Context

Before architecture-sensitive changes, read:
- `CONTEXT.md` — domain vocabulary
- `.github/REVIEW.md` — review process
- `Sources/OcoreAI/Routing/HardwareRouter.swift` — routing logic

## Questions?

Open an issue or discuss in the existing PR.
