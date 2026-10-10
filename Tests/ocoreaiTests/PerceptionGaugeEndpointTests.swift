// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// PerceptionGaugeEndpointTests.swift — locks the honesty semantics of the
// GET /v1/perception gauge vote-resolution (PerceptionGaugeSnapshot.vote).
// These are the assertions the cold-boot saga earned: absent votes stay
// absent, cast votes report verbatim, environment folds with OR on BOTH
// sides so the gauge never cries wolf.

import Foundation
import Testing
@testable import ocoreai

@MainActor
@Suite("GET /v1/perception — vote resolution honesty")
struct PerceptionGaugeEndpointTests {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.ocoreai.gauge.\(UUID().uuidString)")!
    }

    private func store() -> SettingsStore {
        SettingsStore(defaults: freshDefaults())
    }

    @Test("never-voted network reports nil — absent is not the default true")
    func neverVotedNetworkIsNil() {
        // The ghost-lever hiding mechanism: store default is true, so a
        // naive bool(forKey:) would report "user voted ON" when nobody voted.
        #expect(PerceptionGaugeSnapshot.vote(for: .network, store: store()) == nil)
    }

    @Test("voted-off network reports false verbatim")
    func votedOffNetworkIsFalse() {
        let d = freshDefaults()
        SettingsStore(defaults: d).perceptionNetworkEnabled = false
        #expect(PerceptionGaugeSnapshot.vote(for: .network, store: SettingsStore(defaults: d)) == false)
    }

    @Test("voted-on network reports true verbatim")
    func votedOnNetworkIsTrue() {
        let d = freshDefaults()
        SettingsStore(defaults: d).perceptionNetworkEnabled = true
        #expect(PerceptionGaugeSnapshot.vote(for: .network, store: SettingsStore(defaults: d)) == true)
    }

    @Test("ownerless channels (camera/screen) report nil, never silently false")
    func ownerlessChannelsNil() {
        let d = freshDefaults()
        d.set(true, forKey: SettingsStore.Key.perceptionEnabled.rawValue)
        let s = SettingsStore(defaults: d)
        #expect(PerceptionGaugeSnapshot.vote(for: .camera, store: s) == nil)
        #expect(PerceptionGaugeSnapshot.vote(for: .screen, store: s) == nil)
    }

    @Test("environment folds fs+inet with OR — mirrors liveFlag, no false alarms")
    func environmentFoldsWithOR() {
        // fs=off + inet=on: liveFlag is OR => live true. If the vote side
        // folded with AND it would report false and the gauge would flag a
        // dishonesty that doesn't exist. OR keeps both sides fair.
        let d = freshDefaults()
        SettingsStore(defaults: d).perceptionFilesystemEnabled = false
        SettingsStore(defaults: d).perceptionInternetEnabled = true
        #expect(PerceptionGaugeSnapshot.vote(for: .environment, store: SettingsStore(defaults: d)) == true)
    }

    @Test("environment all-voted-off folds to false")
    func environmentAllOff() {
        let d = freshDefaults()
        SettingsStore(defaults: d).perceptionFilesystemEnabled = false
        SettingsStore(defaults: d).perceptionInternetEnabled = false
        #expect(PerceptionGaugeSnapshot.vote(for: .environment, store: SettingsStore(defaults: d)) == false)
    }

    @Test("environment all-unvoted is nil")
    func environmentUnvotedNil() {
        #expect(PerceptionGaugeSnapshot.vote(for: .environment, store: store()) == nil)
    }
}
