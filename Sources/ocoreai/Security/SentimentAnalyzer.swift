// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SentimentAnalyzer.swift — Real-time sentiment analysis for customer satisfaction
///
/// Analyzes message sentiment with polarity scoring and emoji-based quick detection.
/// Supports continuous emotion scoring for monitoring.

import Foundation

/// Sentiment polarity levels.
enum SentimentPolarity: String, Codable, Sendable {
    case veryPositive = "very_positive"
    case positive = "positive"
    case neutral = "neutral"
    case negative = "negative"
    case veryNegative = "very_negative"
}

/// Sentiment analysis result with compound score and breakdown.
struct SentimentResult: Sendable, Codable {
    /// Overall polarity classification.
    let polarity: SentimentPolarity

    /// Compound score from -1.0 (most negative) to 1.0 (most positive).
    let compound: Double

    /// Positive word count ratio.
    let positiveRatio: Double

    /// Negative word count ratio.
    let negativeRatio: Double

    /// Emotion tags detected.
    let emotions: [String]

    /// Whether this is a high-risk message requiring immediate attention.
    var isHighRisk: Bool {
        polarity == .veryNegative || compound < -0.5
    }

    /// Create result from raw scores.
    init(polarity: SentimentPolarity, compound: Double, positiveRatio: Double, negativeRatio: Double, emotions: [String]) {
        self.polarity = polarity
        self.compound = compound
        self.positiveRatio = positiveRatio
        self.negativeRatio = negativeRatio
        self.emotions = emotions
    }
}

/// Lightweight sentiment analyzer — no ML dependency, keyword-based scoring.
struct SentimentAnalyzer: Sendable {
    private let positiveWords: [String]
    private let negativeWords: [String]
    private let emotionIndicators: [String: String]

    /// Create analyzer with built-in word lists.
    init() {
        self.positiveWords = ["good", "great", "excellent", "amazing", "love", "happy",
                              "satisfied", "helpful", "awesome", "perfect",
                              "满意", "好", "棒", "优秀", "喜欢", "开心",
                              "感谢", "谢谢", "完美", "厉害", "好用"]

        self.negativeWords = ["bad", "terrible", "awful", "worst", "hate", "angry",
                              "disappointed", "frustrated", "useless", "waste",
                              "糟糕", "差", "讨厌", "生气", "没用",
                              "浪费", "不好", "失望", "烦", "生气", "垃圾"]

        self.emotionIndicators = [
            "😊": "happy", "😃": "happy", "😄": "happy", "❤️": "love", "👍": "approval",
            "😢": "sad", "😠": "anger", "😡": "anger", "👎": "disapproval",
            "😐": "neutral", "🙂": "mild_happy", "😤": "frustration",
            "🤬": "rage", "😭": "crying", "😩": "frustration",
            "感谢": "grateful", "谢谢": "grateful", "抱歉": "apologetic",
            "生气": "anger", "开心": "happy", "失望": "disappointed",
        ]
    }

    /// Analyze sentiment of a text message.
    /// - Parameter text: The message to analyze
    /// - Returns: ``SentimentResult`` with polarity and scores
    func analyze(_ text: String) -> SentimentResult {
        let lowerText = text.lowercased()
        let words = lowerText.split(whereSeparator: { $0.isWhitespace })

        var positiveCount = 0
        var negativeCount = 0
        var detectedEmotions: [String] = []

        // Word-based scoring
        for word in words {
            let cleanWord = String(word).trimmingCharacters(in: .punctuationCharacters)
            if positiveWords.contains(cleanWord) {
                positiveCount += 1
            }
            if negativeWords.contains(cleanWord) {
                negativeCount += 1
            }
        }

        // Emoji/char-based emotion detection
        for (indicator, emotion) in emotionIndicators {
            if text.contains(indicator) {
                detectedEmotions.append(emotion)
            }
        }

        let totalEmotive = positiveCount + negativeCount
        let positiveRatio: Double = totalEmotive > 0 ? Double(positiveCount) / Double(totalEmotive) : 0.0
        let negativeRatio: Double = totalEmotive > 0 ? Double(negativeCount) / Double(totalEmotive) : 0.0

        // Compound score: normalize to [-1, 1] range
        var compound: Double = 0.0
        if totalEmotive > 0 {
            compound = (Double(positiveCount) - Double(negativeCount)) / Double(max(totalEmotive, 1))
            // Scale based on word count — more words with same ratio = stronger signal
            compound *= min(Double(totalEmotive) * 0.2, 1.0)
        }

        let polarity = classifyPolarity(compound)

        return SentimentResult(
            polarity: polarity,
            compound: compound,
            positiveRatio: positiveRatio,
            negativeRatio: negativeRatio,
            emotions: detectedEmotions
        )
    }

    /// Classify compound score into a polarity category.
    private func classifyPolarity(_ score: Double) -> SentimentPolarity {
        switch score {
        case 0.5...: return .veryPositive
        case 0.2..<0.5: return .positive
        case -0.2..<0.2: return .neutral
        case -0.5..<(-0.2): return .negative
        case ...(-0.5): return .veryNegative
        default: return .neutral
        }
    }

    /// Batch analyze multiple messages.
    func analyze(_ texts: [String]) -> [SentimentResult] {
        texts.map { analyze($0) }
    }
}