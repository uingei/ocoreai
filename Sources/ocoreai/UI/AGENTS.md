# UI — the surface must not outclaim the engine

`Sources/ocoreai/UI/`: `Application.swift`, `Views/`, `ViewModels/`, `Models/`, `Theme/`, plus the
dashboard. Root `AGENTS.md` governs; invariant 2 there (the surface never claims more than the engine
delivered) is *this* subtree's whole job.

## State by authority
- Engine actors own engine/model truth (what is loaded, KV pressure, prefix reuse).
  `SessionManager` + SQLite own durable sessions. A `@MainActor` view model owns this window's
  presentation only. A stream/continuation owns one turn, never the app.
- Persisted keys declare their scope — global | session | model | window. A key that is too broad is
  how one session's setting bleeds into another (cf. `SessionIsolationTests`).
- Paint optimistically, roll back visibly; a stale async result must never overwrite newer intent
  (generation counter or request token). Keep reference identity on no-ops so SwiftUI does not
  invalidate a heavy tree for nothing.

## Attention belongs to the user
- No navigation, focus change, sheet or announcement just because something *happened* in the
  background (model loaded, tool finished, a log line appeared). Offer an affordance; leave the
  foreground where the user put it.
- One cancel gesture, exactly one effect. Keyboard ownership follows focus.
- Expensive surfaces (live tools, video, terminals) stay alive when hidden — visibility is not lifecycle.
- Empty / loading / reconnecting / degraded-stale / exhausted-recovery are five different
  experiences, each needing honest copy and a way out. Say "heuristic tokenizer", say "model not
  loaded"; never render blank (`ThirdPartyNoticesView` is the pattern: absent texts ⇒ the panel says so).

## On anything user-visible, the HIG is the authority
Not codex, not mlx-swift-lm (it ships no GUI). Duties: ⌘ coverage and a sane focus order for
primary actions, `Cmd+,` grouped Settings, `textSelection` on anything readable, accessibility labels,
Dark Mode + Dynamic Type, destructive-confirmation wording, and answering in the medium the user used
— this app hears and speaks, so a voice turn ends in voice, not in text the user must read.
Measured thinness (a defect whatever upstream does): `keyboardShortcut` in 3 files, `textSelection`
in 3, `accessibilityLabel` in 15, across ~260 Swift files in `Sources/`.
<!-- claim:ui_keyboard_shortcut_files>=3 :: git grep -l keyboardShortcut -- Sources | wc -l -->
<!-- claim:ui_accessibility_files>=15 :: git grep -l accessibilityLabel -- Sources | wc -l -->

## iOS parity — compile gates settled, runtime not
- Checked against the iPhoneOS SDK rather than from memory: `HSplitView` is `@available(iOS,
  unavailable)`; `navigationSubtitle` needs iOS 26 while the target is `.iOS(.v17)`; `UIPasteboard`
  exposes `data(forPasteboardType:)` (`UIPasteboard.h`), not AppKit's `data(forType:)`. Sites:
  `UI/Views/ProjectsView.swift`, `UI/ViewModels/ChatState+ComposerIngest.swift`.
- Ruled out as false positives: `keyboardShortcut` and `.help` (iOS 14+), `UTType`,
  `AVCaptureDevice.requestAccess`.
- The macOS-only *tools* (move/click/drag/scroll/type/key, `inspect_ui` via AX,
  `open`/`activate`/`list_apps`) are correct platform semantics, not parity debt.
- iOS **runtime** is unverified on this host: `xcodebuild` cannot run in the agent sandbox, so CI's
  `build-ios` job is the compile authority and nobody should claim iOS behaviour.

## Capability strings
Anything the GUI asserts about capability reads `/v1/capabilities` or the model manifest — the same
source the engine used — never a literal typed into a view.


## GUI end-to-end — measured scope (10-22)

`verify-gui-window.sh` asserts what a user would see: a layer-0 window of believable size, and with `SHOT=1` a
frame that has content (distinct-colour floor ≥64). Measured here 10-22: `900x472`, 140 KB, **846 colours**. Its
traffic-light assertion is gone on purpose — AppKit title-button sub-windows are not enumerable unattended (owned
entries measured 0), so it could only warn, and a check that cannot pass dilutes the ones that can.
`scripts/e2e-gui-app.sh` adds the model-dependent half (version == tag, the listener on 127.0.0.1:8080 *is* the
bundle binary, one real completion `'OCOREAI_GUI_E2E_OK'`, graceful SIGTERM) — locally green, and none of it
licenses "the GUI works": the bridge is opt-in (App Store builds serve nothing), CI runs the
window proof but not the completion, and Accessibility-driven control automation is unverified.
