// Copyright ? 2026 uingei@163.com.
// Licensed under MIT.
/// PerceptionFrame — a timestamped snapshot from any perception channel.
///
/// Each frame carries source identity, timestamp, and context payload
/// (image URL, OCR text, audio URL, or text). Frames are immutable once
/// produced; the buffer manages lifecycle via TTL and budget constraints.

import Foundation

// MARK: - Channel identity

/// Perception channel types that produce frames.
public enum PerceptionChannel: String, Codable, Sendable, CaseIterable {
    /// Camera capture
    case camera
    /// Screen capture
    case screen
    /// Microphone/audio recording
    case audio
    /// Network state
    case network
    /// Environment (filesystem, internet RSS)
    case environment
    /// System context (thermal, memory, CPU, uptime)
    case system
    /// Speaker feedback (TTS output loopback)
    case speaker

    public var description: String { rawValue }
}

// MARK: - PerceptionFrame

/// An immutable perceptual observation from one channel.
public struct PerceptionFrame: Codable, Sendable {
    /// Source channel
    public let channel: PerceptionChannel
    /// Capture timestamp
    public let capturedAt: Date
    /// Image data URL (camera/screen), nil when frame is text-only
    public let imageURL: String?
    /// OCR-recognized text that replaces the image (~97% token savings)
    public let ocrText: String?
    /// Raw audio URL (microphone)
    public let audioURL: String?
    /// Free-form text context (network state, ambient sensor data)
    public let textContext: String?
    /// Estimated token cost — used by budget tracker
    public let estimatedTokens: Int
    /// Stable frame ID for deduplication
    public let id: String

    public init(
        channel: PerceptionChannel,
        imageURL: String? = nil,
        ocrText: String? = nil,
        audioURL: String? = nil,
        textContext: String? = nil,
        estimatedTokens: Int? = nil
    ) {
        self.channel = channel
        self.capturedAt = .init()
        self.imageURL = imageURL
        self.ocrText = ocrText
        self.audioURL = audioURL
        self.textContext = textContext
        self.estimatedTokens =
            estimatedTokens
            ?? Self.estimateTokens(
                imageURL: imageURL,
                ocrText: ocrText,
                textContext: textContext
            )
        self.id = "\(channel.rawValue)_\(UUID().uuidString)"
    }

    /// Estimate token cost of this frame for budget calculations.
    /// Image: ~800 tokens (VLM), OCR text: ~20 tokens, text context: proportional
    private static func estimateTokens(
        imageURL: String?,
        ocrText: String?,
        textContext: String?
    ) -> Int {
        if imageURL != nil { return 800 }
        if let ocr = ocrText, !ocr.isEmpty { return max(10, ocr.count / 4) }
        if let ctx = textContext, !ctx.isEmpty { return max(3, ctx.count / 4) }
        return 0
    }

    /// Check if this frame is expired given TTL.
    public func isExpired(ttl: TimeInterval) -> Bool {
        capturedAt.timeIntervalSinceNow < -ttl
    }

    /// Human-readable label for UI/logging
    public var label: String {
        switch channel {
        case .camera: "camera"
        case .screen: "screen"
        case .audio: "audio"
        case .network: "network"
        case .environment: "environment"
        case .system: "system"
        case .speaker: "speaker"
        }
    }
}

// MARK: - Context Budget

/// Hard limits on perception context injection per inference request.
public struct PerceptionBudget: Codable, Sendable {
    /// Maximum total tokens of perception context per request
    public var maxTokens: Int
    /// Maximum number of frames per channel
    public var maxFramesPerChannel: Int
    /// Maximum age in seconds — frames older than this are excluded
    public var maxAgeSeconds: TimeInterval
    /// Whether to prefer OCR text over images when both available
    public var ocrPreferText: Bool

    public static let `default` = PerceptionBudget(
        maxTokens: 2048,
        maxFramesPerChannel: 1,
        maxAgeSeconds: 30,
        ocrPreferText: true
    )

    /// Low-power profile — tighter budget for constrained environments
    public static let `lazy` = PerceptionBudget(
        maxTokens: 512,
        maxFramesPerChannel: 1,
        maxAgeSeconds: 60,
        ocrPreferText: true
    )
}

// MARK: - PerceptionBuffer (RingBuffer with TTL + budget)

/// Thread-safe ring buffer of perception frames.
/// Frames expire by TTL; retrieval respects token budget.
public final class PerceptionBuffer: @unchecked Sendable {
    private let mutex = Mutex([PerceptionFrame]())
    private let capacity: Int
    private let defaultTTL: TimeInterval

    /// Create a buffer with the given capacity and TTL.
    public init(capacity: Int = 32, defaultTTL: TimeInterval = 60) {
        self.capacity = capacity
        self.defaultTTL = defaultTTL
    }

    /// Push a frame into the buffer, evicting expired entries and oldest
    /// frames when at capacity.
    public func push(_ frame: PerceptionFrame) {
        mutex.withLock { frames in
            // Purge expired frames
            frames.removeAll { $0.isExpired(ttl: defaultTTL) }
            // Evict oldest to make room
            while frames.count >= capacity {
                frames.removeFirst()
            }
            frames.append(frame)
        }
    }

    /// Retrieve a set of frames suitable for inference context injection.
    /// Respects budget: token cap, per-channel cap, and age limits.
    public func snapshot(budget: PerceptionBudget) -> [PerceptionChannel: PerceptionFrame] {
        mutex.withLock { frames in
            var result: [PerceptionChannel: PerceptionFrame] = [:]
            var usedTokens = 0

            // Sort newest first — prefer recent observations
            let sorted = frames.sorted {
                $0.capturedAt.timeIntervalSinceNow > $1.capturedAt.timeIntervalSinceNow
            }

            for frame in sorted {
                // Age gate
                if frame.isExpired(ttl: budget.maxAgeSeconds) {
                    continue
                }
                // Per-channel cap
                if result[frame.channel] != nil {
                    continue
                }
                // Token budget
                if usedTokens + frame.estimatedTokens > budget.maxTokens {
                    continue
                }
                result[frame.channel] = frame
                usedTokens += frame.estimatedTokens
            }

            return result
        }
    }

    /// Clear all frames.
    public func clear() {
        mutex.withLock { $0.removeAll() }
    }

    /// Current frame count (includes potentially expired entries).
    public var count: Int {
        mutex.withLock { $0.count }
    }

    /// Peek latest frame from a specific channel.
    public func latest(for channel: PerceptionChannel) -> PerceptionFrame? {
        mutex.withLock { frames in
            frames.filter { $0.channel == channel }
                .sorted { $0.capturedAt > $1.capturedAt }
                .first
        }
    }
}
