// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// InferenceStubs.swift — Shared inference types & fallback stubs
///
/// Shared types (SamplingConfiguration, InferenceOptions etc.) serve as the
/// intermediate representation between handler layer and backend implementation.
/// Actual inference stubs are compiled only when neither `coreai` nor `mlx`
/// backend is available (e.g. CI without Apple Silicon).

// MARK: - Shared Inference Types (always compiled)

import Foundation
import Logging

// MARK: - Prefill Configuration

/// Prefill parameters for prompt chunking.
///
/// Aligns with upstream `MLXLMCommon.PrefillParameters` (Evaluate.swift L58,
/// PrefillParameters.swift): stepSize controls ceiling per forward, chunking
/// controls division strategy, progress reports prefill progress.
public struct PrefillConfig: Sendable, Codable, Equatable {
    /// Ceiling on tokens evaluated per prefill forward. `nil` lets each model
    /// pick its own default (512 for the generic path).
    public var stepSize: Int?

    /// Chunking strategy for dividing the prompt.
    /// - balanced: fewest equal chunks that respect step-size ceiling (default, aligns
    ///   with upstream PrefillParameters.Chunking.balanced)
    /// - remainder: legacy stride — chunks of exactly the step size
    /// - unchunked: whole prompt in one forward (validation only)
    public var chunking: Chunking = .balanced

    public enum Chunking: String, Sendable, Codable, Equatable, CaseIterable {
        case balanced
        case remainder
        case unchunked
    }

    public static let `default` = PrefillConfig()

    public init(
        stepSize: Int? = nil,
        chunking: Chunking = .balanced
    ) {
        self.stepSize = stepSize
        self.chunking = chunking
    }

    /// Map to upstream chunking. Use string equivalence — InferenceStubs has no
    /// backend dependency so we cannot import MLXLMCommon here. Map at the bridge.
}

// MARK: - Sampling Configuration

/// Intermediate sampling configuration — used by both CoreAI and MLX backends.
/// `mode` field mirrors upstream MLXSamplingMode (greedy/nucleus/topK) for mode-driven
/// sampling parameter resolution (explicit-zero-wins semantics).
struct SamplingConfiguration: Codable, Equatable {
    var seed: Int64?
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    /// Sampling mode (mirrors ConfigStruct.SamplingMode). nil → legacy per-field behavior.
    var mode: SamplingMode?
    var minP: Double?
    var repetitionPenalty: Double?
    var presencePenalty: Double?
    var frequencyPenalty: Double?
    var stopSequences: [String]?
    var logitBias: [String: Double]?
    var combined: Bool = true

    // Prefill configuration — structured to match upstream PrefillParameters
    var prefill: PrefillConfig = .default
    // GenerateParameters fields that control KV cache/windowing
    var maxKVSize: Int? = nil
    var kvBits: Int? = nil
    var kvGroupSize: Int = 64
    var quantizedKVStart: Int = 0
    var kvScheme: String? = nil
    var repetitionContextSize: Int = 20
    var presenceContextSize: Int = 20
    var frequencyContextSize: Int = 20

    init(
        seed: Int64? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        mode: SamplingMode? = nil,
        minP: Double? = nil,
        repetitionPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        stopSequences: [String]? = nil,
        logitBias: [String: Double]? = nil,
        combined: Bool = true,
        prefill: PrefillConfig = .default,
        maxKVSize: Int? = nil,
        kvBits: Int? = nil,
        kvGroupSize: Int = 64,
        quantizedKVStart: Int = 0,
        kvScheme: String? = nil,
        repetitionContextSize: Int = 20,
        presenceContextSize: Int = 20,
        frequencyContextSize: Int = 20,
    ) {
        self.seed = seed
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.mode = mode
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.stopSequences = stopSequences
        self.logitBias = logitBias
        self.combined = combined
        self.prefill = prefill
        self.maxKVSize = maxKVSize
        self.kvBits = kvBits
        self.kvGroupSize = kvGroupSize
        self.quantizedKVStart = quantizedKVStart
        self.kvScheme = kvScheme
        self.repetitionContextSize = repetitionContextSize
        self.presenceContextSize = presenceContextSize
        self.frequencyContextSize = frequencyContextSize
    }

    /// Apply normalization — drops topK/topP when temperature == 0 (greedy).
    /// Normalized temperature for sampling — defaults to 1.0 when not set.
    private var effectiveTemperature: Double {
        let t = temperature ?? 1.0
        return t.isNaN ? 1.0 : t
    }

    /// Apply normalization — drops topK/topP when temperature == 0 (greedy).
    func normalized() -> SamplingConfiguration {
        var config = self
        if config.temperature == nil || config.temperature == 0 {
            config.topK = nil
            config.topP = nil
        }
        return config
    }

    /// Sample next token ID from logits, consuming temperature/topK/topP/minP.
    ///
    /// Aligned with upstream CompositeSampler algorithm:
    ///   logits -> [temperature scaling] -> [softmax] -> [minP filter] -> [topP filter] -> [topK filter] -> [multinomial]
    ///
    /// Temperature=0 or nil -> argmax (greedy).
    func sample(from logits: [Float]) -> Int32 {
        guard !logits.isEmpty, effectiveTemperature != 0 else {
            return argmax(logits)
        }

        var scaled = logits.map { $0 / Float(effectiveTemperature) }
        let probs = SamplingConfiguration.softmax(&scaled)

        guard let filtered = applyFilters(probs) else {
            return argmax(logits)
        }

        return multinomialSample(filtered)
    }

    // MARK: - Sampling helpers

    private func argmax(_ logits: [Float]) -> Int32 {
        var bestIdx = 0
        var bestVal = logits[0]
        for i in 1 ..< logits.count {
            if logits[i] > bestVal {
                bestVal = logits[i]
                bestIdx = i
            }
        }
        return Int32(bestIdx)
    }

    private static func softmaxF16(_ logits: [Float16]) -> [Float] {
        var f32 = logits.map { Float($0) }
        return softmax(&f32)
    }

    /// Numerically stable softmax: subtract max, exp, normalize.
    private static func softmax(_ logits: inout [Float]) -> [Float] {
        let max = logits.max() ?? 0
        let exps = logits.map { exp($0 - max) }
        let sum = exps.reduce(0, +)
        guard sum > 0 && sum.isFinite else {
            return Array(repeating: 0, count: exps.count)
        }
        return exps.map { $0 / sum }
    }

    /// Apply minP, then topP, then topK — returns filtered probability distribution
    /// or nil if filtering yields empty set (fallback to argmax).
    private func applyFilters(_ probs: [Float]) -> [Float]? {
        var filtered = probs

        // minP filter
        if let minP = minP, minP > 0 {
            let maxProb = filtered.max() ?? 0
            let threshold = Float(minP) * maxProb
            for i in filtered.indices {
                filtered[i] = max(filtered[i], 0)
                if filtered[i] < threshold {
                    filtered[i] = 0
                }
            }
            let sum = filtered.reduce(0, +)
            if sum <= 0 { return nil }
            filtered = filtered.map { $0 / sum }
        }

        // topP (nucleus) filter
        if let topP = topP, topP < 1.0 {
            let cumulative = topPSubset(filtered, cumulativeProb: Float(topP))
            filtered = cumulative.map { $0 }
            let sum = filtered.reduce(0, +)
            if sum <= 0 { return nil }
            filtered = filtered.map { $0 / sum }
        }

        // topK filter
        if let topK = topK, topK > 0 && topK < filtered.count {
            let kSubset = topKSubset(filtered, k: topK)
            filtered = kSubset.map { $0 }
            let sum = filtered.reduce(0, +)
            if sum <= 0 { return nil }
            filtered = filtered.map { $0 / sum }
        }

        return filtered
    }

    /// Keep tokens until cumulative probability reaches threshold (topP).
    private func topPSubset(_ probs: [Float], cumulativeProb: Float) -> [Float] {
        let indexed = probs.enumerated().sorted { $0.element > $1.element }
        var cum: Float = 0
        var kept = [Float](repeating: 0, count: probs.count)
        for (i, p) in indexed {
            kept[i] = p
            cum += p
            if cum >= cumulativeProb { break }
        }
        return kept
    }

    /// Keep only top-K tokens (topK).
    private func topKSubset(_ probs: [Float], k: Int) -> [Float] {
        let indexed = probs.enumerated().sorted { $0.element > $1.element }.prefix(k)
        var kept = [Float](repeating: 0, count: probs.count)
        for (i, p) in indexed {
            kept[i] = p
        }
        return kept
    }

    /// Multinomial sample via inverse CDF scan.
    private func multinomialSample(_ probs: [Float]) -> Int32 {
        let r = Float.random(in: 0 ..< 1)
        var cum: Float = 0
        for (i, p) in probs.enumerated() {
            cum += p
            if r < cum { return Int32(i) }
        }
        return Int32(probs.count - 1)
    }

    /// Task-aware temperature adjustment — precision tasks (code/math/json) get
    /// lower temperature for deterministic output, creative tasks keep original.
    ///
    /// Only adjusts when temperature > 0.5 (user hasn't already set low temp).
    /// This is the "model outperform itself" lever: right parameter for the right task.
    ///
    /// - Parameter taskType: Detected task type from ``TaskType``
    /// - Returns: Adjusted ``SamplingConfiguration``
    func withTaskAwareParams(for taskType: TaskType) -> SamplingConfiguration {
        var config = self

        // Only adjust if user hasn't already set a low temperature — respect explicit user choice
        guard let currentTemp = config.temperature else {
            return config
        }

        switch taskType {
        case .code, .math, .json:
            // Precision tasks: lower temperature improves correctness
            if currentTemp > 0.5 {
                config.temperature = min(currentTemp, 0.4)
                // Also tighten top_p for precision tasks
                if let topP = config.topP, topP > 0.95 {
                    config.topP = 0.92
                }
            }
        case .comparison:
            // Comparison: moderate temperature for balanced, fair evaluation
            if currentTemp > 0.6 {
                config.temperature = min(currentTemp, 0.5)
            }
        default:
            break  // general/analysis/factual/casual — no adjustment
        }

        return config
    }
}

/// Intermediate inference options — used by both CoreAI and MLX backends.
struct InferenceOptions: Codable {
    var maxTokens: Int?
    var includeLogits: Bool = false
    /// When true, use GuidedGenerationLoop for grammar-constrained output
    /// (e.g., tool calls, JSON schema responses).
    var useGuidedGeneration: Bool = false
    /// The JSON schema string to constrain output grammar.
    /// Used by tools (tool call schema) or response_format.json_schema.
    var grammarSchema: String? = nil
    /// When true, enable reasoning/chain-of-thought mode.
    /// Passed as additionalContext["enable_thinking"] to ChatSession.
    var enableReasoning: Bool = false
    /// Reasoning level for FM backend — aligns with SDK ContextOptions.ReasoningLevel
    /// ("light", "moderate", "deep", or nil for default). ChatSession path uses
    /// enableReasoning only; this field exists for FM path granularity.
    var reasoningLevel: String? = nil
    /// Tool calling mode — controls whether the model is allowed, required,
    /// or disallowed from calling tools. Aligns with upstream
    /// ToolCallingModeResolution (.allowed / .required / .disallowed).
    /// - `.allowed`: Model may or may not call tools based on context.
    /// - `.required`: Model must call at least one tool before responding.
    ///   Enables think-then-call (reasoning phase followed by guided tool gen).
    /// - `.disallowed`: Tool calling is disabled even if tools are available.
    /// Default is `.auto` — ocoreai uses presence of tools to infer mode
    /// (same as current behavior).
    var toolCallingMode: String? = nil
    /// When set, engines use these token IDs instead of sampling.
    /// Used by MMLU-style evaluation to compute P(continuation|context).
    /// Aligned with upstream InferenceOptions.forcedContinuation.
    var forcedContinuation: [Int32]? = nil

    init(
        maxTokens: Int? = nil, includeLogits: Bool = false, useGuidedGeneration: Bool = false,
        grammarSchema: String? = nil, enableReasoning: Bool = false, reasoningLevel: String? = nil,
        toolCallingMode: String? = nil, forcedContinuation: [Int32]? = nil
    ) {
        self.maxTokens = maxTokens
        self.includeLogits = includeLogits
        self.useGuidedGeneration = useGuidedGeneration
        self.grammarSchema = grammarSchema
        self.enableReasoning = enableReasoning
        self.reasoningLevel = reasoningLevel
        self.toolCallingMode = toolCallingMode
        self.forcedContinuation = forcedContinuation
    }

    init() {}
}

// MARK: - Shared types (both CoreAI and MLX backends)

/// Inference stop reason — used by `InferenceEvent.done` across all backends
/// (MLX and CoreAI). Defined unconditionally since the CoreAI beta SDK
/// does not export this type.
enum StopReason: Int, Codable, Error {
    case maxTokens = 0
    case eos = 1
    case stopSequence = 2
    case cancelled = 3
    case error = 4

    static let maxTokensCase: StopReason = .maxTokens
    static let eosCase: StopReason = .eos
    static let stopSequenceCase: StopReason = .stopSequence
    static let cancelledCase: StopReason = .cancelled
    static let errorCase: StopReason = .error
}

// MARK: - Fallback stubs (when CoreAI is unavailable)

#if !canImport(CoreAI)

// MARK: - MLX-only tokenizer stubs (CoreAI path uses TokenizerManager.swift)

/// Empty StreamingDetokenizer for MLX-only builds — MLXLLM containers have
/// built-in tokenizers.
/// ``@unchecked Sendable``: this is a stub class with no properties — trivially
/// Sendable, but the compiler cannot infer it because classes default to non-Sendable.
final class StreamingDetokenizer: @unchecked Sendable {}

protocol TokenizerProvider: Sendable {
    var name: String { get }
    func tokenize(messages: [[String: String]]) async throws -> [Int32]
    func detokenize(tokenIds: [Int32]) async throws -> String
    func streamingDetokenizer() -> StreamingDetokenizer
    func countTokens(messages: [[String: String]]) async throws -> Int
    func prewarm() async throws
}

actor TokenizerManager {
    init() {}
    func registerTokenizer(for _: String, tokenizerPath _: String) async throws {}
    func registerTokenizerFromHub(for _: String, hubId _: String) async throws {}
    func getTokenizer(for _: String) -> (any TokenizerProvider)? { nil }
    @discardableResult
    func removeTokenizer(for _: String) -> Bool { false }
    func shutdown() {}
}

// MARK: - CoreAI type stubs

struct EngineOptions {
    enum KVCacheStrategy: String, Codable {
        case auto, none, manual, perLayer
    }

    var kvCacheStrategy: KVCacheStrategy = .auto
    init(kvCacheStrategy: KVCacheStrategy = .auto) {
        self.kvCacheStrategy = kvCacheStrategy
    }
}

struct CoreAIPreparedModel {
    var isSpecialized: Bool
    static func fallback() -> CoreAIPreparedModel {
        CoreAIPreparedModel(isSpecialized: false)
    }
}

struct CoreAILoadingConfig: Codable {
    static let production: CoreAILoadingConfig = .init()
    init() {}
}

actor CoreAIModelLoader {
    init(config _: CoreAILoadingConfig, logger _: Logging.Logger?) {}
    func load(modelURL _: URL, modelId _: String) async throws -> CoreAIPreparedModel {
        CoreAIPreparedModel.fallback()
    }

    func teardown() {}
}

actor KVCacheManager {

    init(config _: Logging.Logger?) {}
}

enum EngineFactory {
    static func createEngine(config _: Data, modelURL _: URL, options _: EngineOptions) async throws
        -> StubEngine
    {
        StubEngine()
    }
}

struct StubEngine {
    func generate(
        with _: [Int32], samplingConfiguration _: SamplingConfiguration,
        inferenceOptions _: InferenceOptions
    ) -> AsyncThrowingStream<Int32, Error> {
        AsyncThrowingStream<Int32, Error> { continuation in
            continuation.finish(
                throwing: StubError("Inference unavailable — enable coreai or mlx trait"))
        }
    }

    func reset() async throws {}
    struct Sequence: AsyncSequence, AsyncIteratorProtocol {
        typealias Element = Int32
        typealias Failure = StubError
        func next() async throws -> Int32? {
            throw StubError("Stale stub call")
        }

        func makeAsyncIterator() -> Sequence {
            self
        }

        var stopReason: StopReason {
            .error
        }
    }
}

enum StubError: Error, LocalizedError {
    case disabled(String)
    init(_ message: String) {
        self = .disabled(message)
    }

    var errorDescription: String? {
        switch self {
        case .disabled(let msg): msg
        }
    }
}

#endif  // !coreai
