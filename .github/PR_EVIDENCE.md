# Definition of Done — PR Evidence Standard

Every PR in ocoreai ships evidence a reviewer can confirm without reading the code.
If a reviewer can't verify the change from the artifact, it isn't done.

## The 3 Laws of "Done"

> A reviewer must be able to confirm the change works **by watching it happen
> and inspecting the artifacts you attached.**

1. **Prove the real thing happened** — Record the actual inference log, the real
   model output, the real build artifact — from a live run, never a mock. Then
   **open every artifact and review it by hand.** Capturing is not reviewing.
2. **Test for real, not "front door" only** — Every change ships tests that drive
   the real path. Error paths, empty input, large data, concurrent access,
   permission denied. A test asserting against a stub standing in for the
   device under test is not a test of your feature.
3. **No residuals, no shortcuts** — No `TODO`, no stubs, no half-migrations, no
   "follow-ups." Keep going until every possibility is exhausted.

---

## 1. Always Ship Through a PR

Never push feature/fix work straight to `main`. Work on a branch and open a PR.

- Branch naming: `feat/<slug>`, `fix/<slug>`, `docs/<slug>`, `chore/<slug>`.
- Open an issue first for anything non-trivial, link it in the PR.
- One logical change per PR. Keep diffs reviewable.

## 2. Always Sync with Latest `main`

Your branch must be in sync with `main` and conflict-free at all times:

```bash
git fetch origin
git rebase origin/main
swift package resolve
swift build -c release
swift test
git push --force-with-lease   # only after a rebase
```

If `main` moved and changed behavior, **re-capture the evidence**. Stale
evidence is worse than none.

## 3. Evidence Matrix — What to Capture by Change Type

| If you changed… | Evidence Required | How to Produce It |
|---|---|---|
| **MLX compute channel** | Real MLX inference log showing metallib loaded, GPU dispatch, output shape | Run inference via CLI or test, log the `[MLXInference]` lines |
| **CoreAI compute channel** | CoreML model compile log + inference output showing ANE dispatch | Run inference, log `[CoreAIInference]` lines + model .mlmodel path |
| **HardwareRouter / AdmissionGate** | Routing decision log: input → signal evaluation → channel choice | Run a multi-request test, log `[HardwareRouter]` decision trace |
| **Multimodal pipeline** | Real vision/audio round-trip: input → encode → model → decode → output | Capture input, log pipeline stages, verify output matches expectation |
| **Chat/LLM handler** | Real LLM call: request JSON, token count, response, latency | Run a conversation turn, capture logs from `[ChatHandler]` |
| **SwiftUI GUI** | Before/after screenshot (macOS native). Error/empty/loading states shown | `screencapture` or SwiftUI preview. Verify Dark mode too. |
| **Caching / buffer** | Memory pressure log before + after. Cache hit/miss trace | `sysctl hw.memsize` + Task memory footprint in debug log |
| **New dependency** | `swift package resolve` log showing resolved version. No breaking changes | `swift package describe <target>` for version check |
| **Performance-sensitive** | Time/profile before vs after for the critical path | Instruments, `os_signpost`, or `CFAbsoluteTime` delta |
| **Any code change** | `swift build -c release` ✅ + `swift test` ✅ | Run locally, paste output or "green" confirmation |

### MLX Path — Real Inference Evidence

When MLX is the inference target:

```bash
# Run inference through the CLI
swift run ocoreai chat --backend mlx "Hello"

# Verify metallib is loaded (log should show):
# [MLXInference] metallib loaded from .build/arm64-apple-macosx/release/mlx.metallib
# [MLXInference] GPU dispatch: model=... devices=...
```

The log must show the **real GPU dispatch**, not "CPU fallback" or "mock."

### CoreAI Path — Real ANE Inference Evidence

When CoreAI is the inference target:

```bash
# Verify CoreML model exists and compiles
swift run ocoreai chat --backend coreai "Hello"

# Log should show:
# [CoreAIInference] model compiled: /path/to/model.mlmodel
# [CoreAIInference] ANE inference: latency=...ms
```

### SwiftUI — Visual Evidence

When changing the GUI:

- Full-window screenshot on macOS (Light + Dark mode)
- Error state screenshot (what does the UI show when the backend fails?)
- Empty state screenshot (initial load, no history)

Use `screencapture -x screenshot.png`.

### Performance — Quantitative Evidence

```swift
let start = CFAbsoluteTimeGetCurrent()
// ... the changed path ...
let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
print("[Performance] elapsed=\(String(format: "%.1f", elapsed))ms")
```

Compare with the previous value.

## 4. Real Tests — Not Mocks

A passing test suite is necessary, not sufficient:

- **Exercise the real path** — A test that swaps the inference backend for a
  stub is not a test of your feature. If the real backend is hard to reach,
  make it reachable in the test (use `#if test` compilation, don't mock it out).
- **Assert outcomes, not routing** — "A request was forwarded" is not the same
  as "the right output was produced." Assert the resulting state and output.
- **Cover error paths** — Backend unavailable, model not found, oversized input,
  GPU memory pressure, timeout.
- **Swift testing** — Use `@Test` from `Testing` framework where applicable.

## 5. Completeness Gate

Before marking a PR "ready for review":

- [ ] Branch rebased onto latest `origin/main`; zero conflicts
- [ ] `swift build -c release` passes
- [ ] `swift build -c release --traits appStore` passes (if applicable)
- [ ] `swift test` passes — and they are real tests, not mocks
- [ ] Relevant evidence captured per the matrix above
- [ ] Every evidence row is attached or explicitly N/A with reason
- [ ] No residuals: no `TODO` / `FIXME` / stub / dead code left behind
- [ ] PR description tells a reviewer exactly what to look at

---

## 6. Why This Exists

ocoreai ships inference across MLX (GPU) and CoreAI (ANE) backends with
dynamic hardware routing. Most regressions are behavioral and hardware-specific —
they pass `swift build` but fail in the real inference loop when GPU memory is
low or ANE model doesn't compile. Real logs, real timing, and verified model
paths are how we make behavior observable and reviewable, not code reading.

## 7. Integration with Hermes Code Review

When using Hermes Agent for code review, the `requesting-code-review` skill
runs an 8-step verification pipeline:

1. **Diff extraction** — what changed
2. **Static security scan** — hardcoded keys, injection patterns
3. **Baseline test + lint** — compare before/after
4. **Self-review checklist** — 8 quick checks
5. **Standards axis** — repo conventions + Swift smell baseline
6. **Spec axis** — does the code faithfully implement the issue/description?
7. **Auto-fix loop** — up to 2 cycles
8. **Commit** — with `[verified]` prefix

Confidence gating: findings below 80/100 confidence are suppressed. This
prevents noisy reviews — only report what you're sure about.

## 8. Artifact Storage

- PR-scoped artifacts: `.github/issue-evidence/<PR#>-<slug>.<ext>`
- Large media (video/audio): upload externally, link in PR body, keep a
  representative still/clip in `issue-evidence/` so the proof survives.