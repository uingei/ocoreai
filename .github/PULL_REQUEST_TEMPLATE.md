# Pull Request

## Description

<!-- Brief summary of what this changes and why -->

## Type of Change

- [ ] 🐛 Bug fix
- [ ] ✨ New feature
- [ ] 🔧 Refactor
- [ ] 📝 Documentation
- [ ] 🔒 Security
- [ ] ⚡ Performance
- [ ] 🧪 Test infrastructure

## Related Issue

<!-- Links: Closes #123, Relates to #456 -->

<!-- This risks section must be filled out before the final review and merge. -->

## Risk Assessment

<!--
Low, medium, or high. What could go wrong and what could be affected.
-->

- **Rollback plan:** <!-- revert is sufficient, or requires config migration? -->
- **Breaking change:** <!-- API, config, runtime behavior? -->
- **Failure symptoms:** <!-- What would a user see if this goes wrong? -->

## Sync Verification

- [ ] Branch rebased onto latest `origin/main`; zero conflicts
- [ ] `swift build -c release` passes post-sync
- [ ] `swift test` passes post-sync
- [ ] If `main` moved and changed behavior, evidence was **re-captured**, not reused

## Evidence Checklist

<!--
Every PR requires verifiable evidence a reviewer can confirm the change works
without reading the code. For each row that applies, attach the artifact or
explicitly mark `N/A — <reason>`. Do not leave rows blank.

Full standard: .github/PR_EVIDENCE.md
-->

| Evidence | Required when… | Status |
|---|---|---|
| **Build passes** | Always | `[ ]` |
| **Tests pass** | Any code change | `[ ]` |
| **New/updated tests** | New or modified code path | `[ ]` |
| **MLX metallib validation** | MLX compute channel change | `[ ]` |
| **CoreML model validation** | CoreAI compute channel change | `[ ]` |
| **Hardware routing** | HardwareRouter / AdmissionGate change | `[ ]` |
| **Multimodal round-trip log** | Vision/audio/vision chain change | `[ ]` |
| **SwiftUI snapshot** | UI change | `[ ]` |
| **Performance profile** | Performance-sensitive change | `[ ]` |
| **Memory pressure check** | Cache/buffer/state change | `[ ]` |

## Evidence Details

<!-- Paste or link the actual evidence. See below for examples. -->

### Build Verification
```
swift build -c release
swift build -c release --traits appStore
```
<!-- Output or "✅ green" -->

### Test Results
```
swift test --enable-code-coverage
```
<!-- Output or "✅ green, X tests" -->

### MLX Path (if applicable)
<!-- Did the MLX inference path actually fire with the new code? Real log, not theory. -->

### CoreAI Path (if applicable)
<!-- Did the CoreML compilation + inference succeed? Model path verified? -->

### UI Change (if applicable)
<!-- Before/after screenshot or SwiftUI preview evidence -->

### Performance (if applicable)
<!-- Time/memory before vs after for the changed path -->

## Completeness Gate

<!-- Run through the 7-step review discipline before marking ready → .github/REVIEW.md -->

- [ ] Code follows repo conventions (see `CONTEXT.md` vocabulary)
- [ ] No `TODO`, `FIXME`, or stub left behind
- [ ] No hardcoded credentials, API keys, or secrets
- [ ] New code has tests if the area has a test suite
- [ ] Dead code / residuals cleaned up
- [ ] `swift build -c release` passes locally
- [ ] `swift test` passes locally
- [ ] Branch sync'd with latest `main`, conflict-free
- [ ] If `main` moved and affected behavior, evidence re-captured

## Reviewer Notes

<!-- What exactly should a reviewer look at? Which file, which lines, what to watch for.
Make the reviewer's job fast — they should confirm behavior, not read the full diff. -->

<!--
Review standard: .github/REVIEW.md (two-axis: Standards + Spec)
Code review discipline: code-review-discipline skill (7-step + self-negation)
-->
