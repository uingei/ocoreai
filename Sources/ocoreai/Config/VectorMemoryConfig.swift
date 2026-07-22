// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// VectorMemoryConfig.swift — Configuration for vector embedding memory

import Foundation

/// Configuration for the vector-based semantic memory system.
struct VectorMemoryConfig: Sendable {
	/// Enable automatic embedding of new messages
	var autoEmbed: Bool = true
	
	/// Embedding model ID (for MLXEmbedders)
	var embeddingModel: String = "mlx-community/LFM2.5-Embedding-350M-4bit"
	
	/// Vector dimension (1024 for LFM2.5 models)
	var vectorDim: Int = 1024
	
	/// Max vectors to keep per session (LIFO eviction)
	var maxVectorsPerSession: Int = 500
	
	/// Min similarity threshold for recall
	var minSimilarity: Float = 0.6
	
	/// Number of results to recall
	var recallCount: Int = 5
	
	/// Delay before embedding (ms) — prevents embedding spam on rapid messages
	var embedDelayMs: Int = 500
}
