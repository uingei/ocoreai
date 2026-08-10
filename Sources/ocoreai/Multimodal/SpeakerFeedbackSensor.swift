// Copyright 2026 uingei@163.com.
// Licensed under MIT.
/// SpeakerFeedbackSensor — TTS output loopback self-monitoring
///
/// Monitors AVSpeechSynthesizer state to track TTS output context:
/// - Whether speech is active
/// - Last spoken content summary (for closed-loop self-correction)
/// - Speech queue depth
///
/// On macOS 26+, Apple SpeechAnalyzer can provide phoneme-level
/// confidence for higher-fidelity monitoring. On older versions,
/// we rely on AVSpeechSynthesizerDelegate callbacks.
///
/// Produces PerceptionFrame(.speaker) with TTS status context.
/// Cross-platform: AVFoundation + Speech on macOS/iOS/iPadOS.

import AVFoundation
import Foundation
import os.log

private let speakerLogger = Logger(subsystem: "ocoreai", category: "speaker_feedback_sensor")

// MARK: - Speaker Feedback State

public struct SpeakerFeedbackData: Codable, Sendable {
    public let timestamp: Date
    public let isSpeaking: Bool
    public let queueDepth: Int
    public let lastSpokenLength: Int  // characters of last completed utterance
    public let averageSpeechRate: Double  // characters per second

    public init(
        timestamp: Date = .init(),
        isSpeaking: Bool,
        queueDepth: Int,
        lastSpokenLength: Int,
        averageSpeechRate: Double
    ) {
        self.timestamp = timestamp
        self.isSpeaking = isSpeaking
        self.queueDepth = queueDepth
        self.lastSpokenLength = lastSpokenLength
        self.averageSpeechRate = averageSpeechRate
    }
}

// MARK: - Speaker Event types

public enum SpeakerEvent: String, Codable, Sendable {
    case started
    case stopped
    case paused
    case resumed
    case finished
}

// MARK: - Sensor

@Observable
@MainActor
final class SpeakerFeedbackSensor: NSObject, Sendable {
    static let shared = SpeakerFeedbackSensor()

    // MARK: - Public state

    var isActive: Bool = false
    var latestFeedback: SpeakerFeedbackData?

    /// Recent speaker events (last 20)
    var recentEvents: [SpeakerEvent] = []

    /// Whether TTS is currently active (read from AudioIO)
    var isTTSActive: Bool = false

    // MARK: - Internal

    private var _monitorTask: Task<Void, Never>?
    private let _maxEvents = 20

    private var _lastSpokenLengths: [Int] = []
    private var _speechTimings: [(start: Date, end: Date)] = []

    override init() {
        super.init()
    }

    /// Start monitoring TTS output
    func start() {
        guard !isActive else { return }
        isActive = true

        _monitorTask = Task.detached(priority: .utility) {
            await Self.shared.pollLoop()
        }

        speakerLogger.info("[SpeakerFeedbackSensor] started")
    }

    /// Stop monitoring
    @MainActor
    func stop() {
        _monitorTask?.cancel()
        _monitorTask = nil
        isActive = false
        speakerLogger.info("[SpeakerFeedbackSensor] stopped")
    }

    // MARK: - Record events

    /// Called when TTS starts speaking.
    func recordEvent(_ event: SpeakerEvent) {
        recentEvents.append(event)
        if recentEvents.count > _maxEvents {
            recentEvents = Array(recentEvents.suffix(_maxEvents))
        }

        switch event {
        case .started:
            isTTSActive = true
            _speechTimings.append((.init(), .init()))
        case .stopped, .finished:
            isTTSActive = false
            // Update timing for last utterance if it exists
            if let lastIdx = _speechTimings.indices.last {
                _speechTimings[lastIdx] = (
                    _speechTimings[lastIdx].start,
                    .init()
                )
            }
        default:
            break
        }
    }

    /// Record length of a completed utterance for stats.
    func recordUtteranceLength(_ length: Int) {
        _lastSpokenLengths.append(length)
        if _lastSpokenLengths.count > 100 {
            _lastSpokenLengths = Array(_lastSpokenLengths.suffix(50))
        }
    }

    // MARK: - Polling loop

    private func pollLoop() async {
        while !Task.isCancelled {
            let feedback = await Self.shared.readFeedback()
            Self.shared.latestFeedback = feedback
            try? await Task.sleep(for: .seconds(30))
        }
    }

    @MainActor
    private func readFeedback() async -> SpeakerFeedbackData {
        let audioIO = AudioIO.shared
        let speaking = audioIO.isSpeaking

        return SpeakerFeedbackData(
            isSpeaking: speaking,
            queueDepth: 0,  // AVSpeechSynthesizer queue is opaque; 0 = unknown
            lastSpokenLength: await Self.shared.recentLength,
            averageSpeechRate: await Self.shared.avgRate
        )
    }

    // MARK: - Recent stats

    @MainActor
    private var recentLength: Int {
        let lengths = _lastSpokenLengths
        if lengths.isEmpty { return 0 }
        return lengths.last ?? 0
    }

    @MainActor
    private var avgRate: Double {
        guard !_speechTimings.isEmpty else { return 0 }
        var totalTime: TimeInterval = 0
        var count = 0
        for timing in _speechTimings {
            let duration = timing.end.timeIntervalSince(timing.start)
            guard duration > 0 else { continue }
            totalTime += duration
            count += 1
        }
        guard count > 0 && _lastSpokenLengths.count >= count else { return 0 }
        let totalChars = _lastSpokenLengths.suffix(count).reduce(0, +)
        return Double(totalChars) / totalTime
    }

    // MARK: - Context text

    public func contextText() -> String {
        guard let feedback = latestFeedback else {
            return "[speaker] no feedback"
        }

        var parts: [String] = ["[speaker]"]
        parts.append("tts=\(feedback.isSpeaking ? "active" : "idle")")
        parts.append("queue=\(feedback.queueDepth)")

        if let feedback2 = latestFeedback, feedback2.averageSpeechRate > 0 {
            parts.append("rate=\(String(format: "%.1f", feedback2.averageSpeechRate))ch/s")
        }

        return parts.joined(separator: ", ")
    }
}
