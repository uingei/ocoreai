# ocoreai — distilled per-turn corpus (a candidate under measurement)

> The short arm of the corpus A/B: this file is scored by `OCOREAI_EVAL_DOCS=<path>`, it is not wired
> into any runtime surface, and `AGENTS.md` + `docs/agent/` stay the authority until an owner accepts
> a distilled per-turn corpus. Content is a faithful compression of the root, so the arm measures
> bytes, not a different rule set.

## Two invariants — everything else is a corollary
1. A claim is worth the gate that goes red when it breaks. A fix with no gate is a claim; a scan that
   infers its own premises rots the day the toolchain moves; a doc whose numbers nobody re-greps drifts.
2. The surface never claims more than the engine delivered. Anything a user can read must be measured
   and must degrade honestly where a backend is absent. A file tool's `OK` is durability, not validity.

## Build and verify
- `swift build -c release` (exit 0 is the minimum completion claim) · `make test` (names
  `$OCOREAI_METALLIB` first) · `make docs-check` when docs or gates change · `make audit` · `make spell`.
- Verification is three layers: grep → compile → read the matched lines. One layer is speculation.
  Findings cite `file:line`; label inference as inference.
- A gate you did not run is not green. Prefer a live `serve` + `curl` over an inference about behaviour.

## Editing rules
- Swift 6.2 strict concurrency, `Sendable` enforced; UI is `@MainActor`, engine state is
  actor-isolated; every `@unchecked Sendable` carries a justification comment.
- Zero `try!`, `as!`, `fatalError`, `assert`; `precondition` only for structural invariants; `try?`
  only where a real fallback follows on the next line; no guard for a failure nobody observed.
- `#if canImport(X)` must name the dependency the block actually uses, and never gate a capability
  surface on a backend axis.
- Before writing a symbol, grep for the mechanism that already exists. Footprint ladder — consume
  upstream → extend a seam → opt-in flag/trait → tool or skill → new module → new core surface.
- One home per decision. State lives with its authority at the narrowest scope that can still be
  right, and a persisted key declares its scope (global | session | model | window).

## Git
- Direct commits to `main`; stage explicit paths, never `git add -A` — several sessions share the cwd.
- `CHANGELOG.md` records every user-visible change with its commit.
