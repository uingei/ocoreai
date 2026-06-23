// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EngineConfig.swift — EnginePool configuration

import Foundation

/// Engine pool configuration — passed by value, immutable after initialization.
///
/// Controls concurrent session limits, queue depth, model paths, warmup behavior,
/// and optional KV cache management.
public struct EnginePoolConfig: Sendable {
    /// Maximum concurrent inference sessions before queueing
    public var maxConcurrentSessions: Int

    /// Maximum queued requests before rejection
    public var maxQueueSize: Int

    /// Base filesystem path to model configuration files
    public var modelConfigPath: String

    /// Base filesystem path to model weight directories
    public var modelDirectory: String

    /// Default model identifier (Hub id or local path)
    /// Format: "hf:org/model" for HuggingFace, "mscope:org/model" for ModelScope, or "/path/to/model"
    public var defaultModelId: String

    /// Number of tokens for the prewarm (warmup) inference run
    public var warmupTokens: Int

    /// Optional KV cache management configuration (nil = kvCache disabled)
    var kvCacheConfig: KVCacheManager.Config?

    /// Hard timeout for a single inference request (seconds).
    /// Prevents hung inference from permanently holding resources.
    var inferenceTimeoutSeconds: Int

    /// Optional session pool configuration (nil = pooling disabled).
    /// When enabled, ChatSession instances are pooled per-conversation for KV cache reuse.
    var sessionPoolConfig: SessionPoolConfig?

    /// KV cache dynamic quantization — KV auto-downgrades FP16 → INT4/INT8 after N tokens.
    var kvCacheQuantization: KVCacheQuantizationConfig = .default

    /// Default configuration with sensible production values
    public static let `default`: EnginePoolConfig = .init(
        maxConcurrentSessions: 8,
        maxQueueSize: 32,
        modelConfigPath: "./models/config.json",
        modelDirectory: "./models",
        defaultModelId: "hf:mlx-community/Qwen3.5-4B-OptiQ-4bit",
        warmupTokens: 4,
        kvCacheConfig: nil,
        inferenceTimeoutSeconds: 180,
        sessionPoolConfig: .default,
        kvCacheQuantization: .default
    )

    init(
        maxConcurrentSessions: Int,
        maxQueueSize: Int,
        modelConfigPath: String,
        modelDirectory: String,
        defaultModelId: String,
        warmupTokens: Int,
        kvCacheConfig: KVCacheManager.Config?,
        inferenceTimeoutSeconds: Int,
        sessionPoolConfig: SessionPoolConfig?,
        kvCacheQuantization: KVCacheQuantizationConfig
    ) {
        self.maxConcurrentSessions = maxConcurrentSessions
        self.maxQueueSize = maxQueueSize
        self.modelConfigPath = modelConfigPath
        self.modelDirectory = modelDirectory
        self.defaultModelId = defaultModelId
        self.warmupTokens = warmupTokens
        self.kvCacheConfig = kvCacheConfig
        self.inferenceTimeoutSeconds = inferenceTimeoutSeconds
        self.sessionPoolConfig = sessionPoolConfig
        self.kvCacheQuantization = kvCacheQuantization
    }
}
