// Copyright 2026 uingei@163.com.
// Licensed under MIT.
/// InternetSensor — lightweight internet content awareness
///
/// Polls RSS feed summaries for environmental context injection.
/// Respects connection quality to avoid unnecessary data drain.
/// Produces PerceptionFrame(.environment) with news/summary context.

import Foundation
import os.log

private let internetLogger = Logger(subsystem: "ocoreai", category: "internet_sensor")

// MARK: - Internet Content Summary

public struct InternetSummary: Codable, Sendable {
    public let timestamp: Date
    public let headlines: [String]
    public let summaryText: String

    public init(
        timestamp: Date = .init(),
        headlines: [String],
        summaryText: String
    ) {
        self.timestamp = timestamp
        self.headlines = headlines
        self.summaryText = summaryText
    }
}

// MARK: - Configurable feed sources

public struct InternetFeedConfig: Codable, Sendable {
    public var enabled: Bool
    public var feedURLs: [String]
    public var pollInterval: TimeInterval
    public var maxHeadlines: Int

    public static let `default` = InternetFeedConfig(
        enabled: false,
        feedURLs: [],
        pollInterval: 300,
        maxHeadlines: 5
    )

    public static let tech = InternetFeedConfig(
        enabled: true,
        feedURLs: [
            "https://rss.nytimes.com/services/xml/rss/technology/rss.xml"
        ],
        pollInterval: 300,
        maxHeadlines: 3
    )
}

// MARK: - RSS Parser (nonisolated, stateless)

final class RSSParser: Sendable {
    static func parseHeadlines(from xml: String, maxItems: Int = 10) -> [String] {
        var titles: [String] = []
        let titleStart = "<title>"
        let titleEnd = "</title>"

        var remaining = xml
        while titles.count < maxItems,
            let startRange = remaining.range(of: titleStart)
        {
            let afterStart = remaining[remaining.index(after: startRange.upperBound)...]
            if let endRange = afterStart.range(of: titleEnd) {
                let title = afterStart[..<endRange.lowerBound]
                let cleanTitle =
                    title
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .newlines)
                    .joined(separator: " ")
                if !cleanTitle.isEmpty, cleanTitle.count < 200 {
                    titles.append(cleanTitle)
                }
                remaining = String(afterStart[afterStart.index(after: endRange.upperBound)...])
            } else {
                break
            }
        }

        return titles
    }
}

// MARK: - Sensor

@Observable
@MainActor
final class InternetSensor: Sendable {
    static let shared = InternetSensor()

    var config = InternetFeedConfig.default

    var latestSummary: InternetSummary?

    var isActive: Bool = false

    // MARK: - Internal

    private var _monitorTask: Task<Void, Never>?

    /// Start polling feeds
    func start(with feedConfig: InternetFeedConfig? = nil) {
        guard !self.isActive else { return }

        if let feedConfig {
            self.config = feedConfig
        }

        guard self.config.enabled, !self.config.feedURLs.isEmpty else {
            internetLogger.info("[InternetSensor] no feeds configured, inactive")
            return
        }

        self.isActive = true
        _monitorTask = Task.detached(priority: .utility) {
            await Self.shared.pollLoop()
        }

        internetLogger.info("[InternetSensor] polling \(self.config.feedURLs.count) feeds")
    }

    /// Stop polling
    @MainActor
    func stop() {
        _monitorTask?.cancel()
        _monitorTask = nil
        self.isActive = false
    }

    // MARK: - Polling loop

    private func pollLoop() async {
        // Check connectivity before polling
        let reachable = await NetworkSensor.shared.isReachable
        guard reachable else {
            let self_ = Self.shared
            internetLogger.notice("[InternetSensor] network unreachable, skipping poll")
            try? await Task.sleep(for: .seconds(self_.config.pollInterval))
            return
        }

        let quality = await NetworkSensor.shared.quality
        guard quality != .poor, quality != .none else {
            let self_ = Self.shared
            internetLogger.notice("[InternetSensor] poor connection, deferring")
            try? await Task.sleep(for: .seconds(self_.config.pollInterval))
            return
        }

        let self_ = Self.shared
        var headlines: [String] = []

        for feedURL in self_.config.feedURLs {
            if Task.isCancelled { break }
            let items = await Self.shared.fetchFeed(url: feedURL)
            headlines.append(contentsOf: items)
        }

        if !headlines.isEmpty {
            let summary = InternetSummary(
                headlines: Array(headlines.prefix(self_.config.maxHeadlines)),
                summaryText:
                    "internet: \(headlines.count) headlines from \(self_.config.feedURLs.count) feeds"
            )
            Task { @MainActor in
                Self.shared.latestSummary = summary
            }
            internetLogger.debug("[InternetSensor] \(headlines.count) headlines fetched")
        }

        try? await Task.sleep(for: .seconds(self_.config.pollInterval))
    }

    // MARK: - RSS Fetch

    private nonisolated func fetchFeed(url: String) async -> [String] {
        guard let feedURL = URL(string: url) else { return [] }
        var request = URLRequest(
            url: feedURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10.0
        )
        request.setValue("application/rss+xml", forHTTPHeaderField: "Accept")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let xmlString = String(data: data, encoding: .utf8) ?? ""
            return RSSParser.parseHeadlines(from: xmlString, maxItems: 10)
        } catch {
            return []
        }
    }

    // MARK: - Context text

    public func contextText() -> String {
        guard let summary = latestSummary else {
            return "[internet] no context"
        }
        return "[internet] \(summary.summaryText)"
    }
}
