// Copyright 2026 uingei@163.com.
// Licensed under MIT.
/// NetworkSensor — persistent network connectivity monitoring
///
/// Uses URLSession reachability checks for simple lightweight monitoring.
/// No heavy dependencies — works on all supported OS versions.
///
/// Produces NetworkSnapshot for inference context injection.

import Foundation
import os.log

private let netLogger = Logger(subsystem: "ocoreai", category: "network_sensor")

// MARK: - Connection Quality

public enum ConnectionQuality: String, Codable, Sendable {
    case excellent
    case fair
    case poor
    case none

    public var description: String {
        switch self {
        case .excellent: "excellent"
        case .fair: "fair"
        case .poor: "poor"
        case .none: "offline"
        }
    }
}

// MARK: - Network Snapshot

public struct NetworkSnapshot: Codable, Sendable {
    public let timestamp: Date
    public let quality: ConnectionQuality
    public let rttMs: Double?

    public init(
        timestamp: Date = .init(),
        quality: ConnectionQuality,
        rttMs: Double? = nil
    ) {
        self.timestamp = timestamp
        self.quality = quality
        self.rttMs = rttMs
    }
}

// MARK: - Sensor

@Observable
@MainActor
final class NetworkSensor {
    static let shared = NetworkSensor()

    var quality: ConnectionQuality = .none
    var isReachable: Bool = false
    var latestSnapshot: NetworkSnapshot?
    var isMonitoring: Bool = false
    var rttMs: Double?

    private var _rttSamples: [Double] = []
    private var _monitorTask: Task<Void, Never>?
    private let probeURL = URL(string: "https://www.apple.com/library/test/success.html")!

    init() {
        _ = startMonitoring()
    }

    @MainActor
    func startMonitoring() -> Bool {
        guard !isMonitoring else { return true }
        isMonitoring = true
        _monitorTask = Task.detached(priority: .utility) {
            await self.pollLoop()
        }
        netLogger.info("[NetworkSensor] monitoring started")
        return true
    }

    @MainActor
    func stopMonitoring() {
        _monitorTask?.cancel()
        _monitorTask = nil
        isMonitoring = false
        netLogger.info("[NetworkSensor] monitoring stopped")
    }

    // MARK: - Poll loop

    private func pollLoop() async {
        let sensor = Self.shared

        while !Task.isCancelled {
            let reachable = await sensor.checkReachability()
            await sensor.update(reachable: reachable)
            try? await Task.sleep(for: .seconds(15))
        }
    }

    // MARK: - Reachability probe

    private func checkReachability() async -> Bool {
        let url = Self.shared.probeURL
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3.0)
        request.httpMethod = "HEAD"

        do {
            _ = try await URLSession.shared.data(for: request)
            return true
        } catch {
            return false
        }
    }

    // MARK: - State update

    @MainActor
    private func update(reachable: Bool) {
        let wasReachable = self.isReachable
        self.isReachable = reachable

        let newQuality: ConnectionQuality = reachable ? .excellent : .none

        #if os(macOS)
        if reachable {
            // macOS: assume wired/WiFi unless proven expensive
            self.quality = .excellent
        } else {
            self.quality = .none
        }
        #else
        self.quality = newQuality
        #endif

        latestSnapshot = NetworkSnapshot(
            quality: self.quality,
            rttMs: nil
        )

        if wasReachable != reachable {
            netLogger.info(
                "[NetworkSensor] reachability: \(wasReachable) → \(reachable), quality: \(self.quality.description)"
            )
        }
    }

    // MARK: - Context text

    public func contextText() -> String {
        guard let snap = latestSnapshot else {
            return "[network] no data"
        }
        var parts: [String] = ["[network] quality: \(snap.quality.description)"]
        if let rtt = snap.rttMs, rtt > 0 {
            parts.append("rtt: \(Int(rtt))ms")
        }
        return parts.joined(separator: ", ")
    }
}
