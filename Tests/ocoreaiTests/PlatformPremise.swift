// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// PlatformPremise — the one place a test asks whether *this running OS* carries an API family.
///
/// A suite that compiles on an SDK but cannot run on the OS underneath it has exactly two honest
/// options: skip, or say nothing. It has three dishonest ones, all measured in this repo: fail with
/// `Issue.record("requires macOS 27")` (a local red that is really the platform talking, and two
/// verdicts per run), `print` a SKIP (invisible in the run summary, so the suite reads as untested
/// work nobody did), or carry `.disabled("requires macOS 27 runtime")` forever — which does not
/// revive when CI moves to macOS 27 and turns the test into a claim with no gate.
///
/// `#available` is the same predicate the shipped code gates on, so the skip can never disagree with
/// the gate that put the code there. Measured against `operatingSystemVersion` by
/// `PlatformPremiseHonestyTests`, so a predicate that hard-codes `true` goes red.
import Foundation

enum PlatformPremise {
    /// Whether this OS carries the macOS 27 / iOS 27 family (`CoreAI`, the MPSGraph constrained
    /// samplers, `.aimodelc` bundles) — the axes that several suites here are gated on.
    static var hasMacOS27: Bool {
        if #available(macOS 27.0, iOS 27.0, *) { return true }
        return false
    }
}
