// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Dashboard health honesty — the bar may claim only what the engine's lifecycle machine
/// says, and every resting state must carry a way out.
///
/// Before this suite the bar rendered `engineReady ? "System Online" : "System Loading"`,
/// so an idle engine, a degraded one and a breaker-open one all read "System Loading" and
/// none of them offered an action - while the engine already carried six states, a failure
/// count and (since this round) the cause of the last failure.

import Foundation
import Testing

@testable import ocoreai

@Suite("Dashboard health — the bar claims only what the engine measured")
struct DashboardHealthHonestyTests {
    @Test("every engine state maps to its own readout")
    func derivesEveryState() {
        #expect(DashboardHealth.derive(state: .ready, failures: 0, cause: nil) == .online)
        #expect(DashboardHealth.derive(state: .starting, failures: 0, cause: nil) == .starting)
        #expect(DashboardHealth.derive(state: .stopping, failures: 0, cause: nil) == .stopping)
        #expect(DashboardHealth.derive(state: .degraded, failures: 0, cause: nil) == .degraded)
        #expect(DashboardHealth.derive(state: .idle, failures: 0, cause: nil) == .stopped)
        #expect(
            DashboardHealth.derive(state: .idle, failures: 2, cause: "sqlite open failed")
                == .failed(failures: 2))
        #expect(
            DashboardHealth.derive(state: .error, failures: 3, cause: "sqlite open failed")
                == .failed(failures: 3))
        // A breaker may be open with a reset count; the bar still never claims zero attempts.
        #expect(
            DashboardHealth.derive(state: .error, failures: 0, cause: nil)
                == .failed(failures: 1))
    }

    @Test("only a running engine produces samples worth plotting")
    func samplesMetricsTruthTable() {
        #expect(DashboardHealth.online.samplesMetrics)
        #expect(DashboardHealth.degraded.samplesMetrics)
        #expect(!DashboardHealth.starting.samplesMetrics)
        #expect(!DashboardHealth.stopping.samplesMetrics)
        #expect(!DashboardHealth.stopped.samplesMetrics)
        #expect(!DashboardHealth.failed(failures: 3).samplesMetrics)
    }

    /// Stale must be reachable: numbers kept from an earlier live poll, on a screen whose
    /// engine no longer samples. A cold launch has nothing to be stale about, so the badge
    /// would be theatre if it fired there.
    @Test("stale flags old numbers, never an unmeasured cold start")
    func staleRule() {
        #expect(!DashboardHealth.metricsAreStale(health: .online, hasValues: true))
        #expect(!DashboardHealth.metricsAreStale(health: .degraded, hasValues: true))
        #expect(DashboardHealth.metricsAreStale(health: .stopped, hasValues: true))
        #expect(DashboardHealth.metricsAreStale(health: .failed(failures: 3), hasValues: true))
        #expect(DashboardHealth.metricsAreStale(health: .stopping, hasValues: true))
        #expect(!DashboardHealth.metricsAreStale(health: .stopped, hasValues: false))
        #expect(!DashboardHealth.metricsAreStale(health: .starting, hasValues: false))
    }

    /// A resting state without a way out is the dead end the UI guide forbids; transient
    /// states may wait, so they legitimately carry no action.
    @Test("every resting state carries a way out, transient states do not")
    func restingStatesCarryAnAffordance() {
        let resting: [(DashboardHealth, StringKey)] = [
            (.degraded, .tabSystem),
            (.stopped, .startBackendAction),
            (.failed(failures: 3), .retryAction),
        ]
        for (health, expected) in resting {
            #expect(health.affordanceLabelKey == expected, "\(health) lost its way out")
        }
        for transient in [DashboardHealth.online, .starting, .stopping] {
            #expect(transient.affordanceLabelKey == nil, "\(transient) should not act")
        }
    }

    /// Copy is a promise too: a state whose word lives in only one table renders the raw
    /// key for the other language.
    @Test("every state resolves in both delivered tables, with and without affordance")
    @MainActor
    func everyStateResolvesInBothTables() {
        let all: [DashboardHealth] = [
            .online, .starting, .stopping, .degraded, .stopped, .failed(failures: 2),
        ]
        for health in all {
            #expect(
                !health.labelKey.localized(for: .en).isEmpty, "\(health): empty en label")
            #expect(
                !health.labelKey.localized(for: .zhHans).isEmpty, "\(health): empty zh label")
            #expect(!health.label.isEmpty, "\(health): label does not resolve")
            if let affordance = health.affordanceLabelKey {
                #expect(
                    !affordance.localized(for: .en).isEmpty, "\(health): affordance has no en")
                #expect(
                    !affordance.localized(for: .zhHans).isEmpty,
                    "\(health): affordance has no zh")
            }
        }
    }

    /// The bar must really read the derived state. The scan floors its own subject, so a
    /// regex that stopped matching fails instead of passing vacuously.
    @Test("the view renders the derived health, not the boolean")
    func viewRendersDerivedHealth() throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root.path != "/",
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Package.swift").path)
        {
            root.deleteLastPathComponent()
        }
        #expect(root.path != "/", "repo root not found from \(#filePath)")
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/ocoreai/UI/Views/DashboardView.swift"),
            encoding: .utf8)
        #expect(
            !source.contains("isLive ? StringKey.systemOnline"),
            "the health bar collapsed back to a boolean")
        #expect(
            source.contains("dashboardState.metricsSnapshot != .empty"),
            "the metrics section went back to hiding the last known numbers on stop")
        #expect(
            source.components(separatedBy: "dashboardState.health").count - 1 >= 5,
            "the scan lost its subject: the view barely reads the derived health")
        var caseMentions = 0
        for name in [".online", ".starting", ".stopping", ".degraded", ".stopped", ".failed"] {
            caseMentions += source.components(separatedBy: name).count - 1
        }
        #expect(caseMentions >= 6, "the view stopped rendering each state: \(caseMentions)")
    }
}
