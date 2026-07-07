# ocoreai — Code Review Workflow

This document defines the **two-axis code review process** for all changes in
the ocoreai codebase. It is the operational standard for PR review, pre-commit
verification, and architectural audit.

---

## The Two-Axis Model

Every change is reviewed along two independent axes. A change can follow every
convention but implement the wrong thing, or implement the spec perfectly while
violating conventions. Separating them prevents one from masking the other.

| Axis | Question | Scope |
|---|---|---|
| **Standards** | Does the code follow repo conventions and Swift best practices? | Code style, naming, architecture patterns, smell baseline, Swift 6 Sendable, @Observable, Apple HIG |
| **Spec** | Does the code faithfully implement the originating spec? | Issue description, PRD, branch name intent, behavior claim |

Before reviewing, load **historical context** — `git blame` on the changed
lines to catch regressions of previously fixed bugs.

## Finding Taxonomy

Every finding is tagged with one severity level. Review body headings must start
with the emoji marker — this keeps the review scannable.

| Tag | Heading | Meaning | Action |
|---|---|---|---|
| **🔴 [blocking]** | `### 🔴 Blocking — title` | Must be fixed before merge. Crash, data loss, security, spec violation. | Block merge |
| **🟡 [warning]** | `### 🟡 Warning — title` | Should be fixed; not blocking but reviewer wants attention. | Author must respond |
| **🔵 [suggestion]** | `### 🔵 Suggestion — title` | Optional improvement. Author can accept or ignore. | Author's call |
| **🟢 [praise]** | `### 🟢 What looks good — title` | Specific praise that teaches what to repeat. Generic "nice" teaches nothing. | N/A |
| **✅ [resolved]** | `### ✅ Resolved — title` | Prior finding confirmed addressed in a later commit. Used in re-review. | N/A |

## Take-Stock Protocol

Before writing a single line of review, **name out loud**:

1. **What's been raised already** — across inline comments, PR description, linked issues
2. **What's settled** — resolved by author, dismissed by reviewer, addressed in later commit
3. **What's still live** — open blockers, unresolved questions, things the author committed to but didn't ship
4. **Who holds active blocks** — and whether the diff addresses them

The take-stock pass prevents re-raising settled points and surfaces who's actually waiting on what.

## Confidence Gating

Every finding gets a confidence score (0–100). Only findings ≥ 80 are
reported. This prevents noisy reviews.

| Score | Meaning |
|---|---|
| 0 | False positive — pre-existing issue unchanged by the diff |
| 25 | Tentative — might be real but could be intentional |
| 50 | Moderate — real but low-impact nitpick |
| 75 | High — verified likely-true issue directly affecting functionality |
| 100 | Certain — confirmed bug that will happen frequently |

### False Positive Exclusion List

Do **NOT** flag these:
- Pre-existing issues — unchanged code that has always been there
- Lint/formatter territory — what SwiftLint or swift-format already enforces
- Compiler/type-checker territory — what `swift build` catches
- Pedantic nitpicks — a senior engineer wouldn't mention them
- General vague concerns — without concrete evidence
- Silenced violations — explicitly suppressed via `// ignore` or `#if`
- Expected downstream changes — if the PR changes an API contract, callers adapting is expected

### Independent Phase 2 — Issue Validation

> Source: Anthropic Code Review Plugin (references/claude-code/plugins/code-review/)
> Core insight: Generate issues → verify independently → discard false positives

After the two-axis review produces findings, **do not report them immediately**.
Run each finding through an independent validation pass:

**For each finding:**
1. Re-read the diff context (±10 lines around the flagged line)
2. Check: does this finding pass the confidence ≥ 80 threshold on a second look?
3. Check: is this a real issue or a "looks like a bug but is actually correct"?
4. Check: does the finding reference an actual CLAUDE.md / repo convention that applies to this file?
5. If true positive → keep. If false positive → discard and note the count.

This double-pass catches the "reviewer sees a pattern match but the code is actually fine" class of error.

---

## Axis 1: Standards Review

### Repo Standards (check first, take precedence)

- `CONTEXT.md` — domain vocabulary (terms must match)
- `AGENTS.md` / `CODING_STANDARDS.md` — coding conventions
- ADRs under `docs/adr/` — architecture decisions
- Apple HIG — navigation, window management, gestures, Dynamic Type, accessibility

### Swift-Specific Standards

| Rule | Severity | CI Gate |
|---|---|---|
| No `force_unwrapping` in `Sources/` | Error | ✅ Blocked |
| No `implicitly_unwrapped_optional` in `Sources/` | Error | ✅ Blocked |
| No `fatal_error_message` in `Sources/` | Error | ✅ Blocked |
| `@unchecked Sendable` must have comment justification | Warning | Pattern audit |
| `@Observable` over `ObservableObject` | Warning | Pattern audit |
| Dynamic Type support (no hardcoded font sizes) | Warning | UI audit |
| i18n — no hardcoded English in UI | Warning | Pattern audit |
| Error handling — no `try!` in network/file paths | Warning | Pattern audit |

### Swift Smell Baseline (Fowler + Swift-Specific)

| Smell | Signal | Fix |
|---|---|---|
| **Force unwrap** | `!` where `?` suffices | Use `guard let`, `if let`, or `??` |
| **Catching everything** | `catch {}` with empty body | Handle specific errors or re-throw |
| **State fragmentation** | Same state in @State + @observed + NotificationCenter | Consolidate to one `@Observable` source of truth |
| **MainActor misuse** | `@MainActor` on data fetch, blocking the main queue | `@MainActor` only on UI-bound state |
| **Dead notification** | `Notification.post` with zero listeners | Remove or verify listener exists |
| **Message chains** | Long `a.b.c.d()` property access | Facade method on `a` |
| **Mysterious name** | Variable/function name doesn't reveal purpose | Rename; can't think of honest name = design murky |
| **Primitive obsession** | String/int standing in for a domain concept | Give the concept its own small type |
| **Duplicate state** | Same data in model + cache + notification | One source of truth, resolve on demand |
| **Speculative generality** | Abstraction for needs the spec doesn't have yet | Inline until real need appears |

### Historical Context Check

Before reviewing the diff, check what history says:

```bash
# Recent changes to the same files
git log --oneline -10 -- $(git diff --name-only)

# Blame on changed lines
git blame -L <start>,<end> -- path/to/file
```

Questions to ask:
- Did this code already fail here before?
- Is there a commit explaining why the previous approach was wrong?
- Was this fix reverted before?

### Standards Report Format

```
## Standards Review

### Hard violations (confidence ≥ 80)
- [file:line] confidence:XX — <description>

### Baseline smells (confidence ≥ 80)
- [file:line] confidence:XX — "<SmellName>": <brief description>

### Suppressed (fell below threshold)
- <N> findings dropped by confidence filter

### Standards: VERDICT — <N> findings (hard/smell)
```

---

## Axis 2: Spec Review

### Spec Source Hierarchy (highest → lowest priority)

1. GitHub issue reference in branch name (`fix/#123`)
2. PRD/spec in `docs/` matching the feature
3. PR description / commit message
4. User-provided description from conversation
5. If nothing found — report "no spec available" and skip

### What to Check

| Category | Description |
|---|---|
| **Missing / partial** | Requirements the spec asked for that are not implemented |
| **Scope creep** | Behavior in the diff that the spec did not ask for |
| **Wrong implementation** | Requirements that look implemented but deviate from the spec |
| **Hardware path gap** | Spec says both MLX + CoreAI, but only one was changed |
| **Error path gap** | Spec implies graceful degradation, but code crashes on failure |

### Spec Report Format

```
## Spec Review

### Missing / partial (confidence ≥ 80)
- [spec reference] confidence:XX — <description>

### Scope creep (confidence ≥ 80)
- [diff file:line] confidence:XX — behavior not in spec

### Wrong implementation (confidence ≥ 80)
- [spec] vs [diff file:line] — spec says X, code does Y

### Suppressed (fell below threshold)
- <N> findings dropped by confidence filter

### Spec: VERDICT — <N> findings
```

---

## Pre-Commit Verification Pipeline

Run before `git commit`. 8 steps, auto-fix loop after step 5.

```
Step 1  Diff extraction        — git diff --cached
Step 2  Static security scan   — hardcoded keys, secrets, injection
Step 3  Baseline test + lint   — swift test, swiftlint
Step 4  Self-review checklist  — 8 quick checks
Step 5  Two-axis review        — Standards + Spec (with confidence gating)
Step 6  Evaluate results       — pass / fail decision
Step 7  Auto-fix loop          — up to 2 fix-and-reverify cycles
Step 8  Commit                 — with [verified] prefix
```

Fix priority order:
1. Security issues → 2. Test regressions → 3. Hard standard violations →
4. Wrong implementation → 5. Missing requirements → 6. Scope creep →
7. Baseline smells

---

## Project-Level Audit Checklist

When auditing the project infrastructure itself (not a single PR):

### Phase A — CI/CD Health
```bash
swift build                                    # debug
swift build -c release                         # release
swift build -c release --traits appStore       # appStore trait
swift test --enable-code-coverage              # tests
swiftlint lint Sources/ 2>&1 | tail -3        # lint baseline
bash scripts/audit.swift_patterns.sh           # pattern audit
```

### Phase B — Governance
| Dimension | Check | Command |
|---|---|---|
| PR Template | Exists with checklist | `ls .github/PULL_REQUEST_TEMPLATE.md` |
| CODEOWNERS | Exists with routes | `ls .github/CODEOWNERS` |
| Evidence standard | PR_EVIDENCE.md exists | `ls .github/PR_EVIDENCE.md` |
| Review workflow | REVIEW.md exists | `ls .github/REVIEW.md` |
| Contributing guide | CONTRIBUTING.md exists | `ls CONTRIBUTING.md` |
| Secret scanning | gitleaks config | `ls .gitleaks.toml` |

### Phase C — Code Metrics
| Metric | Command | Target |
|---|---|---|
| Source file count | `find Sources -name "*.swift" \| wc -l` | — |
| Test/source ratio | `Tests/*.swift count` vs `Sources/*.swift count` | ≥ 20% |
| @unchecked Sendable | `grep -rn '@unchecked Sendable' Sources/` | Each justified |
| Empty catch | `grep -rn 'catch.*{}' Sources/` | Whitelisted with reason |
| Force unwrap | `grep -rn '!' Sources/` | 0 in Sources |

---

## Verdict Decision Tree

| Situation | Action |
|---|---|
| Your review is approving and no active blocker exists | **Approve** |
| You found 🔴 blocking issues you'd personally block on | **Request Changes** |
| You have nothing new, but another reviewer holds an active block | **Comment** |
| Your findings are all 🔵 suggestions or non-blocking questions | **Comment** |
| Re-review: all your prior findings show `### ✅ Resolved` | **Approve** |

## Review Voice

Write as a thoughtful senior contributor who has read everything and cares about the outcome:

- **Be specific.** Vague feedback creates anxiety without direction. Explain the principle behind every finding.
- **Name what is good.** Specific praise (`🟢 The merge order is correct because…`) builds shared judgment. Generic "nice work" teaches nothing.
- **Separate work from person.** "This approach has a problem" not "you made a mistake."
- **Don't re-raise settled points.** If a prior item is resolved, use `### ✅ Resolved — ...` to acknowledge it.
- **Reference standards by source** when they're the basis of a finding. "Per `PR_EVIDENCE.md` §3" is more useful than "per our standards."

## Review Output — Final Summary

Both axes reported, then one-line summary:

```
Summary — Standards: <N> findings. Spec: <N> findings. Phase2-validated: <M>/<N> confirmed.
```

---

## P0 / P1 Severity Standards

### P0 — Must Fix Before Merge
- **Cache / state leak** — data written once never refreshed
- **Cold launch side effect** — init → load → triggers unexpected behavior
- **Pipeline break** — A produces but B never consumes
- **Identity-ownership mismatch** — atomic submit-and-dispatch doesn't verify the dispatched item is the submitted one → double dispatch / OOM cascade
- **Crash path in Sources/** — force unwrap, implicit unwrapped optional, unhandled throw

### P1 — Should Fix
- Improper compression/scaling under memory pressure
- Asymmetric API design (open ≠ close inverse)
- Comment contradicts code behavior
- Missing error handling on one code path that others handle

### Design Choices — Do Not Change
- Zero compression but functionally correct
- Persistence strategy differences (text but not images)
- Permission request timing
- Tradeoff between MLX latency and CoreAI energy efficiency
