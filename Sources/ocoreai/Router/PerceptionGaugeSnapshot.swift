// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// PerceptionGaugeSnapshot.swift — machine-readable honesty gauge behind
/// ``GET /v1/perception``.
///
/// Why this exists: every honest-lever fix so far was provable only through
/// a model round-trip (observe_state) or by reading source. A user, a
/// monitor, or the verify-installed-release script deserves a direct,
/// assertion-grade surface: for each channel — persisted vote, live engine
/// flag, and whether frames actually flow. Content never leaves this
/// endpoint; only booleans and ages.

import Foundation

@MainActor
enum PerceptionGaugeSnapshot {

    /// Channel → persisted vote, via the store's own Key raw values and
    /// public getters. camera/screen have no owner toggle in the UX today —
    /// reported as nil vote, never silently false. Never-voted stays nil
    /// for network (its store default is TRUE — conflating absent with
    /// voted-true would hide exactly the ghost-lever class of bug).
    /// (internal: locked by PerceptionGaugeEndpointTests)
    static func vote(
        for channel: PerceptionChannel,
        store: SettingsStore
    ) -> Bool? {
        let raw = UserDefaults.standard
        func hasVote(_ key: SettingsStore.Key) -> Bool {
            raw.object(forKey: key.rawValue) != nil
        }
        switch channel {
        case .network:
            return hasVote(.perceptionNetworkEnabled) ? store.perceptionNetworkEnabled : nil
        case .system: return hasVote(.perceptionSystemEnabled) ? store.perceptionSystemEnabled : nil
        case .environment:
            // environment folds filesystem + internet. liveFlag is OR, so
            // the vote folds with OR too — comparing vote-AND against
            // live-OR would cry wolf (fs=off, inet=on votes; live on via
            // inet => falsely "dishonest"). nil votes don't contribute;
            // all-nil => no vote at all.
            let fs = hasVote(.perceptionFilesystemEnabled) ? store.perceptionFilesystemEnabled : nil
            let in_ = hasVote(.perceptionInternetEnabled) ? store.perceptionInternetEnabled : nil
            if fs == nil && in_ == nil { return nil }
            return (fs ?? false) || (in_ ?? false)
        case .speaker: return hasVote(.perceptionSpeakerEnabled) ? store.perceptionSpeakerEnabled : nil
        case .audio: return hasVote(.perceptionAudioEnabled) ? store.perceptionAudioEnabled : nil
        case .camera, .screen: return nil
        }
    }

    static func build() -> PerceptionGaugeResponse {
        let engine = PerceptionEngine.shared
        let master = SettingsStore.shared.perceptionEnabled
        let snapshot = engine.snapshot()
        let now = Date()

        var channels: [String: PerceptionGaugeResponse.ChannelGauge] = [:]
        for channel in PerceptionChannel.allCases {
            let live = liveFlag(of: engine.channels, channel: channel)
            let voted = vote(for: channel, store: SettingsStore.shared)
            let age: Double? = snapshot[channel].map { now.timeIntervalSince($0.capturedAt) }
            // Honest = what runs matches what was voted, where a vote exists.
            let honest = voted.map { $0 == live } ?? true
            channels[channel.rawValue] = .init(
                votedEnabled: voted,
                liveEnabled: live,
                latestFrameAgeSec: age.map { ($0 * 10).rounded() / 10 },
                honest: honest
            )
        }

        return PerceptionGaugeResponse(
            masterVoted: master,
            engineRunning: engine.isRunning,
            bootHonest: engine.isRunning == master,
            powerProfile: engine.powerProfile.rawValue,
            channels: channels,
            timestamp: Int64(now.timeIntervalSince1970)
        )
    }

    private static func liveFlag(of flags: ChannelFlags, channel: PerceptionChannel) -> Bool {
        switch channel {
        case .camera: return flags.camera
        case .screen: return flags.screen
        case .audio: return flags.audio
        case .network: return flags.network
        case .environment: return flags.filesystem || flags.internet
        case .system: return flags.system
        case .speaker: return flags.speaker
        }
    }
}
