// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SemanticSearch.swift — Vector-based semantic search over session messages
///
/// Complements FTS5 keyword search with dense vector similarity recall.
/// Uses EmbeddingService (MLXEmbedders) to produce embeddings, then performs
/// cosine similarity search against pre-computed message embeddings stored
/// in SQLite's `embed_vector` BLOB column.

import Foundation

/// Semantic search result — message matched by vector similarity.
struct SemanticSearchResult: Identifiable, Sendable {
	let id: Int64
	let sessionId: Int64
	let snippet: String
	let score: Double // cosine similarity, 0.0..1.0
	let createdAt: Date
}

/// Semantic search and embedding pipeline — actor-isolated via SQLiteStore.
actor SemanticSearch {
	private let store: SQLiteStore
	private let embeddingService: EmbeddingService

	private static let vectorDim = 1024
	private static let defaultLimit = 20
	private static let minScore = 0.6

	init(store: SQLiteStore) {
		self.store = store
		self.embeddingService = EmbeddingService()
	}

	// MARK: - Embedding

	/// Embed a message and store the vector in SQLite.
	@Sendable
	func embedMessage(_ messageId: Int64, text: String) async {
		self.embedMessage_impl(messageId, text: text)
	}

	private func embedMessage_impl(_ messageId: Int64, text: String) {
		Task {
			let data = try? await embeddingService.embedText(text)
			if let data {
				_ = try? await store.execute(
					sql: "UPDATE messages SET embed_vector = ? WHERE id = ?",
					parameters: [data, messageId]
				)
			}
		}
	}

	// MARK: - Semantic Search

	/// Search by semantic similarity to a query string.
	func search(
		_ query: String,
		sessionId: Int64? = nil,
		limit: Int? = nil
	) async throws -> [SemanticSearchResult] {
		let actualLimit = limit ?? Self.defaultLimit
		let queryVector = try await embeddingService.embedText(query)
		return try await searchWithVector(queryVector, sessionId: sessionId, limit: actualLimit)
	}

	/// Search using a pre-computed query vector directly.
	func searchWithVector(
		_ queryVector: Data,
		sessionId: Int64? = nil,
		limit: Int? = nil
	) async throws -> [SemanticSearchResult] {
		let actualLimit = limit ?? Self.defaultLimit
		let whereClause: String
		let params: [AnyHashable]

		if let sid = sessionId {
			whereClause = "WHERE embed_vector IS NOT NULL AND session_id = ? AND LENGTH(embed_vector) > 0"
			params = [sid]
		} else {
			whereClause = "WHERE embed_vector IS NOT NULL AND LENGTH(embed_vector) > 0"
			params = []
		}

		let sql = """
			SELECT id, session_id, content, created_at
			FROM messages
			\(whereClause)
			ORDER BY created_at DESC
			LIMIT 500
		"""

		do {
			let rows = try await store.query(sql, parameters: params)
			let results = cosineSimilarityBatch(queryVector, rows: rows)
			return results
				.filter { $0.score >= Self.minScore }
				.sorted { $0.score > $1.score }
				.prefix(actualLimit)
				.map { $0 }
		} catch let sqliteErr as SQLiteError {
			throw sqliteErr
		} catch {
			throw SQLiteError.queryFailed(detail: error.localizedDescription)
		}
	}

	/// Compute cosine similarity between query vector and all row vectors.
	private func cosineSimilarityBatch(
		_ queryVector: Data,
		rows: [[String: SendableValue]]
	) -> [SemanticSearchResult] {
		guard let qFloats = queryVector.floatArray(from: Self.vectorDim) else { return [] }
		var results: [SemanticSearchResult] = []

		for row in rows {
			guard let embedData = row["embed_vector"]?.asData,
					let rowFloats = embedData.floatArray(from: Self.vectorDim) else { continue }

			let sim = cosineSimilarity(qFloats, rowFloats)
			guard sim > 0 else { continue }

			let content = row["content"]?.asString ?? ""
			let createdAtTs = row["created_at"]?.asInt64 ?? 0
			let sessionId = row["session_id"]?.asInt64 ?? 0
			let id = row["id"]?.asInt64 ?? 0

			results.append(SemanticSearchResult(
				id: id,
				sessionId: sessionId,
				snippet: String(content.prefix(300)),
				score: Double(sim),
				createdAt: Date(timeIntervalSince1970: Double(createdAtTs) / 1_000_000)
			))
		}

		return results
	}
}

// MARK: - Helpers

private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
	guard a.count == b.count, !a.isEmpty else { return 0 }
	var dot: Float = 0, normA: Float = 0, normB: Float = 0
	for i in 0..<a.count {
		dot += a[i] * b[i]
		normA += a[i] * a[i]
		normB += b[i] * b[i]
	}
	guard normA > 0 && normB > 0 else { return 0 }
	return dot / (sqrt(normA) * sqrt(normB))
}

extension Data {
	/// Parse as [Float] of expected dimension. Returns nil on size mismatch.
	func floatArray(from dim: Int) -> [Float]? {
		guard self.count == dim * MemoryLayout<Float>.size else { return nil }
		let floats = self.withUnsafeBytes {
			$0.bindMemory(to: Float.self).withMemoryRebound(to: Float.self) {
				Array(UnsafeBufferPointer(start: $0.baseAddress, count: dim))
			}
		}
		return floats
	}
}
