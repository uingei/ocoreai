// Copyright © 2026 uingei.
// Licensed under MIT.
/// The switch that arms the P0 instrument is itself a claim, and until now nothing gated it:
/// `=1` must pay only on collapsed turns, `=all` must widen to every turn (arm E's pairing),
/// and unset must mean off. A typo in the mode string used to be invisible — the probe simply
/// never logged, and `scripts/collapse-discriminators.sh` arm D counted the missing lines as
/// collapsed replays and still printed a verdict.
///
/// Serialized: these read and write one process-wide env var.
import Foundation
import Testing

@testable import ocoreai

@Suite("DegenerateMarginProbe: opt-in modes", .serialized)
struct DegenerateMarginProbeModeTests {

    private func setMode(_ value: String?) {
        if let value {
            setenv("OCOREAI_MARGIN_PROBE", value, 1)
        } else {
            unsetenv("OCOREAI_MARGIN_PROBE")
        }
    }

    @Test("unset means off — a normal run never pays for the probe")
    func unsetIsOff() {
        setMode(nil)
        #expect(!DegenerateMarginProbe.isEnabled)
        #expect(!DegenerateMarginProbe.runsOnEveryTurn)
    }

    @Test("=1 is collapse-only: healthy turns still pay nothing")
    func oneIsCollapseOnly() {
        setMode("1")
        defer { setMode(nil) }
        #expect(DegenerateMarginProbe.isEnabled)
        #expect(!DegenerateMarginProbe.runsOnEveryTurn)
    }

    @Test("=all widens the gate; an unrecognised value arms nothing")
    func allWidensTheGate() {
        setMode("all")
        defer { setMode(nil) }
        #expect(DegenerateMarginProbe.isEnabled)
        #expect(DegenerateMarginProbe.runsOnEveryTurn)
        setMode("yes")
        #expect(!DegenerateMarginProbe.isEnabled, "an unrecognised mode must not arm the probe")
        #expect(!DegenerateMarginProbe.runsOnEveryTurn)
    }
}
