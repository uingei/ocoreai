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

/// Intermediate sampling configuration — used by both CoreAI and MLX backends.
struct SamplingConfiguration: Sendable, Codable, Equatable {
    var seed: Int64?
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var minP: Double?
    var repetitionPenalty: Double?
    var stopSequences: [String]?
    var logitBias: [String: Double]?
    var combined: Bool = true

    init(
        seed: Int64? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        minP: Double? = nil,
        repetitionPenalty: Double? = nil,
        stopSequences: [String]? = nil,
        logitBias: [String: Double]? = nil,
        combined: Bool = true
    ) {
        self.seed = seed
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.stopSequences = stopSequences
        self.logitBias = logitBias
        self.combined = combined
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
}

/// Intermediate inference options — used by both CoreAI and MLX backends.
struct InferenceOptions: Sendable, Codable {
    var maxTokens: Int?
    var includeLogits: Bool = false

    init(maxTokens: Int? = nil, includeLogits: Bool = false) {
        self.maxTokens = maxTokens
        self.includeLogits = includeLogits
    }
    init() {}
}

/// Stub types needed when the `coreai` trait is inactive.
/// In mlx-only mode, CoreAI-specific types (CoreAIPreparedModel, CoreAIModelLoader)
/// are not available from their real modules, so we provide stubs here.
#if !coreai

struct EngineOptions: Sendable {
    enum KVCacheStrategy: String, Sendable, Codable {
        case `auto`, none, manual, perLayer
    }
    var kvCacheStrategy: KVCacheStrategy = .auto
    init(kvCacheStrategy: KVCacheStrategy = .auto) { self.kvCacheStrategy = kvCacheStrategy }
}

struct CoreAIPreparedModel: Sendable {
    var isSpecialized: Bool
    static func fallback() -> CoreAIPreparedModel {
        CoreAIPreparedModel(isSpecialized: false)
    }
}

struct CoreAILoadingConfig: Sendable, Codable {
    static let production: CoreAILoadingConfig = CoreAILoadingConfig()
    init() {}
}

actor CoreAIModelLoader {
    init(config: CoreAILoadingConfig, logger: Logging.Logger?) {}
    func load(modelURL: URL, modelId: String) async throws -> CoreAIPreparedModel {
        CoreAIPreparedModel.fallback()
    }
    func teardown() {}
}

actor KVCacheManager {
    struct Config: Sendable, Codable {
        var maxGpuCacheGB: Double = 16.0
        var idleTimeoutSeconds: Int = 300
        static var `default`: Config { Config() }
        init() {}
    }
    init(config: Config, logger: Logging.Logger?) {}
    func registerZeroSession(sessionId: String) {}
    func unregister(sessionId: String) {}
    func markActive(sessionId: String) {}
    func gpuUsageGB() -> Double { 0.0 }
    func coldStoreActiveSessions() async {}
    func shutdown() {}
}

enum StopReason: Int, Codable, Sendable, Error {
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

struct EngineFactory {
    static func createEngine(config: Data, modelURL: URL, options: EngineOptions) async throws -> StubEngine {
        StubEngine()
    }
}

struct StubEngine {
    func generate(with input: [Int32], samplingConfiguration: SamplingConfiguration, inferenceOptions: InferenceOptions) -> AsyncThrowingStream<Int32, Error> {
        AsyncThrowingStream<Int32, Error> { continuation in
            continuation.finish(throwing: StubError("Inference unavailable — enable coreai or mlx trait"))
        }
    }
    func reset() async throws {}
    struct Sequence: AsyncSequence, AsyncIteratorProtocol {
        typealias Element = Int32
        typealias Failure = StubError
        func next() async throws -> Int32? {
            throw StubError("Stale stub call")
        }
        func makeAsyncIterator() -> Sequence { self }
        var stopReason: StopReason { .error }
    }
}

enum StubError: Error, LocalizedError {
    case disabled(String)
    init(_ message: String) { self = .disabled(message) }
    var errorDescription: String? {
        switch self {
        case .disabled(let msg): return msg
        }
    }
}

final class StreamingDetokenizer: @unchecked Sendable {
    func consume(_ tokenId: Int32) throws -> String? {
        throw StubError("Tokenizer unavailable — enable coreai or mlx trait")
    }
    func reset(initialTokenIds: [Int32]) {}
    var currentTokenIds: [Int32] { [] }
}

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
    func registerTokenizer(for modelId: String, tokenizerPath: String) async throws {
        throw StubError("Tokenizer unavailable — enable coreai or mlx trait")
    }
    func registerTokenizerFromHub(for modelId: String, hubId: String) async throws {
        throw StubError("Tokenizer unavailable — enable coreai or mlx trait")
    }
    func getTokenizer(for modelId: String) -> (any TokenizerProvider)? { nil }
    @discardableResult
    func removeTokenizer(for modelId: String) -> Bool { false }
    func shutdown() {}
}

#endif // !coreai
