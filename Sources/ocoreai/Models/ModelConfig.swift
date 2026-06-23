// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// MARK: - Model Configuration

import Foundation

/// Parsed model configuration from ``config.json``.
///
/// Provides context-window validation and weight-path resolution.
public struct ModelConfig: Sendable {
    /// Human-readable model name (optional).
    public let name: String?

    /// Inference function name.
    public let function: String

    /// Vocabulary size.
    public let vocabSize: Int

    /// Maximum context (token) length.
    public let maxContextLength: Int

    /// Chunk threshold for speculative decoding.
    public let chunkThreshold: Int

    /// Number of tokens per prefill chunk.
    public let prefillChunkSize: Int

    /// Serialized model weight filenames (for filesystem lookup).
    public let serializedModel: [String]

    /// Tokenizer model path or identifier.
    public let tokenizer: String

    /// Parse configuration from JSON binary ``Data``.
    ///
    /// - Parameter data: Raw JSON bytes read from ``config.json``
    /// - Throws: Serialization failure when JSON shape is invalid
    public init(parsing data: Data) throws {
        let decoder = JSONDecoder()
        let jsonModelConfig = try decoder.decode(
            _ModelConfigJSON.self,
            from: data
        )
        name = jsonModelConfig.name
        function = jsonModelConfig.function ?? "default"
        vocabSize = jsonModelConfig.vocabSize
        maxContextLength = jsonModelConfig.maxContextLength
        chunkThreshold = jsonModelConfig.chunkThreshold
        prefillChunkSize = jsonModelConfig.prefillChunkSize
        serializedModel = jsonModelConfig.serializedModel
        tokenizer = jsonModelConfig.tokenizer
    }

    /// Validate configuration values are within acceptable bounds.
    ///
    /// - Throws: ``AppError.invalidRequest`` when values are out of range
    public func validate() throws {
        guard vocabSize > 0 else {
            throw AppError.invalidRequest("vocabSize must be positive")
        }
        guard maxContextLength > 0 else {
            throw AppError.invalidRequest("maxContextLength must be positive")
        }
    }
}

// MARK: - Internal JSON Shape

/// Internal JSON-decoding target for ``ModelConfig``.
private struct _ModelConfigJSON: Decodable {
    let name: String?
    let function: String?
    let vocabSize: Int
    let maxContextLength: Int
    let chunkThreshold: Int
    let prefillChunkSize: Int
    let serializedModel: [String]
    let tokenizer: String

    private enum CodingKeys: String, CodingKey {
        case name
        case function
        case vocabSize = "vocab_size"
        case maxContextLength = "max_context_length"
        case chunkThreshold = "chunk_threshold"
        case prefillChunkSize = "prefill_chunk_size"
        case serializedModel = "serialized_model"
        case tokenizer
    }
}

private extension ModelConfig {
    /// Direct initializer used by coreai-specific ``KVCacheManager`` cold-store code.
    init(
        name: String,
        function: String,
        vocabSize: Int,
        maxContextLength: Int,
        chunkThreshold: Int,
        prefillChunkSize: Int
    ) {
        self.name = name
        self.function = function
        self.vocabSize = vocabSize
        self.maxContextLength = maxContextLength
        self.chunkThreshold = chunkThreshold
        self.prefillChunkSize = prefillChunkSize
        self.serializedModel = []
        self.tokenizer = ""
    }
}
