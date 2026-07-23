// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SessionCompressor.swift — Session memory management with token-threshold compression
///
/// Implements a 3-layer memory model:
///   Layer 1 (Hot):  In-memory working set (last N messages)
///   Layer 2 (Warm):  FTS5-searchable SQLite for current session
///   Layer 3 (Cold):  Compressed summaries, purgeable after TTL
///
/// Triggers rule-based summary generation when session token count exceeds threshold (128K default).

import Foundation
import Logging

/// Session memory manager — actor-isolated with token tracking.
actor SessionCompressor {
	private let logger: Logger
	private let store: SQLiteStore
	private let fts: FTS5Search
	/// Number of recent messages cached as the hot working set (exposed for UI layer boundary).
	let hotWindow: Int
	private let tokenThreshold: Int // Token count that triggers compression
	private let ttlDays: Int // Default session retention
	private var llmSummarizer: (@Sendable (String) async throws -> String)? // LLM summarization callback (nil = rule-based only)

	// Per-session tracking
	private var sessionTokenCounts: [Int64: Int] = [:]
	private var compressedSessions: Set<Int64> = []

	/// Default token threshold: 128K tokens (matches context window).
	static let DefaultTokenThreshold = 128_000

	/// Create compressor.
	/// - Parameters:
	///   - store: SQLite store connection
	///   - fts: FTS5 search actor
	///   - hotWindow: Number of recent messages to cache (default 50)
	///   - tokenThreshold: Token count trigger (default 128K)
	///   - ttlDays: Default retention period (default 180)
	init(
		store: SQLiteStore,
		fts: FTS5Search,
	) {
		logger = Logger(label: "ocoreai.session")
		self.store = store
		self.fts = fts
		hotWindow = 50
		tokenThreshold = Self.DefaultTokenThreshold
		ttlDays = 180
		llmSummarizer = nil
	}

	init(
		store: SQLiteStore,
		fts: FTS5Search,
		llmSummarizer: (@Sendable (String) async throws -> String)?,
	) {
		logger = Logger(label: "ocoreai.session")
		self.store = store
		self.fts = fts
		hotWindow = 50
		tokenThreshold = Self.DefaultTokenThreshold
		ttlDays = 180
		self.llmSummarizer = llmSummarizer
	}

	init(
		store: SQLiteStore,
		fts: FTS5Search,
		hotWindow: Int,
		tokenThreshold: Int,
		ttlDays: Int,
		llmSummarizer: (@Sendable (String) async throws -> String)? = nil,
	) {
		logger = Logger(label: "ocoreai.session")
		self.store = store
		self.fts = fts
		self.hotWindow = hotWindow
		self.tokenThreshold = tokenThreshold
		self.ttlDays = ttlDays
		self.llmSummarizer = llmSummarizer
	}

	// MARK: - Lazy Injection

	/// Inject (or replace) the LLM summarization callback after engine boot.
	/// Safe to call multiple times — compression that fires before injection
	/// uses rule-based fallback; afterwards it uses the LLM.
	func setSummarizer(_ callback: (@Sendable (String) async throws -> String)?) async {
		llmSummarizer = callback
		logger.info("LLM summarizer callback installed")
	}

	// MARK: - Session CRUD

	/// Create a new session.
	/// - Parameters:
	///   - modelId: Model identifier
	///   - ttlDays: Retention period override (nil = default)
	/// - Returns: Session ID
	func createSession(modelId: String, ttlDays: Int? = nil) async throws -> Int64 {
		let ttl = ttlDays ?? self.ttlDays
		let now = Int64(Date().timeIntervalSince1970 * 1_000_000)

		let sql = """
		INSERT INTO sessions (model_id, created_at, updated_at, message_count, token_count, ttl_days)
		VALUES (?, ?, ?, 0, 0, ?)
		"""

		do {
			_ = try await store.scalarQuery(sql: sql, parameters: [modelId, now, now, ttl])
			return try await getLastInsertedId()
		} catch let sqliteErr as SQLiteError {
			throw sqliteErr
		} catch {
			throw SQLiteError.executionFailed(detail: error.localizedDescription)
		}
	}

	/// Delete a session and all its messages.
	func deleteSession(_ sessionId: Int64) async throws {
		do {
			try await store.execute(sql: "DELETE FROM messages WHERE session_id = ?", parameters: [sessionId])
			try await store.execute(sql: "DELETE FROM sessions WHERE id = ?", parameters: [sessionId])
			sessionTokenCounts.removeValue(forKey: sessionId)
			compressedSessions.remove(sessionId)
		} catch let sqliteErr as SQLiteError {
			throw sqliteErr
		} catch {
			throw SQLiteError.executionFailed(detail: error.localizedDescription)
		}
	}

	/// List sessions with filtering.
	/// - Parameters:
	///   - modelId: Optional model filter
	///   - limit: Maximum results
	/// - Returns: Array of session models
	func listSessions(modelId: String? = nil, limit: Int = 100) async throws -> [SessionModel] {
		let sql: String
		let params: [AnyHashable]

		if let mid = modelId {
			sql = """
			SELECT id, model_id, created_at, updated_at, message_count, token_count, summary, ttl_days
			FROM sessions WHERE model_id = ?
			ORDER BY updated_at DESC LIMIT ?
			"""
			params = [mid, limit]
		} else {
			sql = """
			SELECT id, model_id, created_at, updated_at, message_count, token_count, summary, ttl_days
			FROM sessions
			ORDER BY updated_at DESC LIMIT ?
			"""
			params = [limit]
		}

		do {
			let rows = try await store.query(sql, parameters: params)
			return rows.compactMap { SessionModel(from: $0) }
		} catch let sqliteErr as SQLiteError {
			throw sqliteErr
		} catch {
			throw SQLiteError.queryFailed(detail: error.localizedDescription)
		}
	}

	// MARK: - Message CRUD

	/// Add a message to a session and track token count.
	func addMessage(
		sessionId: Int64,
		role: String,
		content: String,
		tokenCount: Int,
		toolCalls: [ToolCallRecord]? = nil,
	) async throws -> Int64 {
		guard ["user", "assistant", "system", "tool"].contains(role) else { throw SQLiteError.executionFailed(detail: "Invalid role: \(role)") }
		return try await addUnsafe(sessionId: sessionId, role: role, content: content,
		                    tokenCount: tokenCount, toolCalls: toolCalls)
	}

	private func addUnsafe(
		sessionId: Int64,
		role: String,
		content: String,
		tokenCount: Int,
		toolCalls: [ToolCallRecord]? = nil,
	) async throws -> Int64 {
		let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
		let toolCallsJson: String?
		do {
			if let calls = toolCalls {
				toolCallsJson = try String(data: JSONEncoder().encode(calls), encoding: .utf8)
			} else {
				toolCallsJson = nil
			}
		}

		let sql = """
		INSERT INTO messages (session_id, role, content, created_at, token_count, tool_calls)
		VALUES (?, ?, ?, ?, ?, ?)
		"""

		do {
			let params: [AnyHashable] = if let json = toolCallsJson {
				[sessionId, role, content, now, tokenCount, json]
			} else {
				[sessionId, role, content, now, tokenCount, ""]
			}
			try await store.execute(sql: sql, parameters: params)

			// Capture row id for embedding
			let messageRowId = try await store.scalarQuery(sql: "SELECT last_insert_rowid()")?.asInt64 ?? 0

			// Update session metadata
			try await updateSession(sessionId, messageDelta: 1, tokenDelta: tokenCount)

			// Track in-memory token count
			sessionTokenCounts[sessionId, default: 0] += tokenCount

			// Check compression threshold
			if sessionTokenCounts[sessionId, default: 0] >= tokenThreshold {
				logger.warning("Session \(sessionId) token count \(sessionTokenCounts[sessionId, default: 0]) exceeds threshold \(tokenThreshold)")
				// Trigger compression event
				triggerCompression(sessionId)
			}

			return messageRowId
		} catch let sqliteErr as SQLiteError {
			throw sqliteErr
		} catch {
			throw SQLiteError.executionFailed(detail: error.localizedDescription)
		}
	}

	/// Get messages for a session.
	/// - Parameters:
	///   - sessionId: Session ID
	///   - limit: Maximum messages to return (hot window default)
	///   - offset: Skip messages from start
	/// - Returns: Array of messages
	func getMessages(
		_ sessionId: Int64,
		limit: Int? = nil,
		offset: Int = 0,
	) async throws -> [MessageModel] {
		let lim = limit ?? hotWindow
		let sql = """
		SELECT id, session_id, role, content, created_at, token_count, tool_calls
		FROM messages
		WHERE session_id = ?
		ORDER BY created_at DESC
		LIMIT ? OFFSET ?
		"""

		do {
			let rows = try await store.query(sql, parameters: [sessionId, lim, offset])
			return rows.compactMap { MessageModel(from: $0) }
		} catch let sqliteErr as SQLiteError {
			throw sqliteErr
		} catch {
			throw SQLiteError.queryFailed(detail: error.localizedDescription)
		}
	}

	// MARK: - Layer 1 Hot Window

	/// Get the hot window (most recent N messages) for a session.
	func hotWindow(_ sessionId: Int64) async throws -> [MessageModel] {
		try await getMessages(sessionId, limit: hotWindow)
	}

	/// Get bookend messages: first 3 + last 3 of a session.
	func bookends(_ sessionId: Int64, count: Int = 3) async throws -> [MessageModel] {
		// First N
		let firstSql = """
		SELECT id, session_id, role, content, created_at, token_count, tool_calls
		FROM messages WHERE session_id = ? ORDER BY created_at ASC LIMIT ?
		"""
		let lastSql = """
		SELECT id, session_id, role, content, created_at, token_count, tool_calls
		FROM messages WHERE session_id = ? ORDER BY created_at DESC LIMIT ?
		"""

		do {
			let firstRows = try await store.query(firstSql, parameters: [sessionId, count])
			let lastRows = try await store.query(lastSql, parameters: [sessionId, count])

			var messages: [MessageModel] = []
			messages.append(contentsOf: firstRows.compactMap { MessageModel(from: $0) })
			// Reverse last to chronological order
			let lastMessages = lastRows.compactMap { MessageModel(from: $0) }.reversed()
			messages.append(contentsOf: lastMessages)

			return messages
		} catch let sqliteErr as SQLiteError {
			throw sqliteErr
		} catch {
			throw SQLiteError.queryFailed(detail: error.localizedDescription)
		}
	}

	// MARK: - Compression

	/// Trigger compression for a session.
	///
	/// Uses detached task + weak self to avoid holding a strong reference
	/// on SessionCompressor while pruneColdMessages runs — prevents delaying
	/// GC of session state under memory pressure.
	private func triggerCompression(_ sessionId: Int64) {
		Task.detached(priority: .utility) { [weak self] in
			guard let self else { return }
			await self.pruneColdMessages(sessionId, tokenCount: self.sessionTokenCounts[sessionId, default: 0])
		}
	}

	/// Prune messages beyond hotWindow for a session that exceeded token threshold.
	/// Before deletion, generates a rule-based summary from cold messages
	/// and appends it to the session's summary field.
	private func pruneColdMessages(_ sessionId: Int64, tokenCount: Int) async {
		// 1. Fetch cold messages that will be deleted
		// P1-fix: Include tool_calls so that tool-use context is preserved in the summary.
		// Without this, function call + result pairs are lost during compression,
		// breaking the conversation context for subsequent tool-assisted turns.
		let coldSql = """
		SELECT role, content, tool_calls FROM messages
		WHERE session_id = ?
		AND id NOT IN (
		    SELECT id FROM messages WHERE session_id = ?
		    ORDER BY created_at DESC LIMIT ?
		)
		ORDER BY created_at ASC
		"""
		let coldMessages: [(role: String, content: String, toolCalls: String?)]
		do {
			let rows = try await store.query(coldSql, parameters: [sessionId, sessionId, hotWindow])
			coldMessages = rows.compactMap { row -> (String, String, String?)? in
				guard let role = row["role"]?.asString,
				      let content = row["content"]?.asString else { return nil }
				return (role, content, row["tool_calls"]?.asString)
			}
		} catch {
			logger.warning("Failed to fetch cold messages for session \(sessionId): \(error.localizedDescription)")
			return
		}

		guard !coldMessages.isEmpty else { return }

		// 2. Generate summary from cold messages
		let summary = await generateCompressionSummary(coldMessages)

		// 3. Append to existing session summary
		do {
			if let existing = try? await store.scalarQuery(
				sql: "SELECT summary FROM sessions WHERE id = ?",
				parameters: [sessionId],
			)?.asString,
				!existing.isEmpty
			{
				let combined = existing + "\n" + summary
				try await store.execute(
					sql: "UPDATE sessions SET summary = ?, updated_at = ? WHERE id = ?",
					parameters: [combined, Int64(Date().timeIntervalSince1970 * 1_000_000), sessionId],
				)
			} else {
				try await store.execute(
					sql: "UPDATE sessions SET summary = ?, updated_at = ? WHERE id = ?",
					parameters: [summary, Int64(Date().timeIntervalSince1970 * 1_000_000), sessionId],
				)
			}
		} catch {
			logger.warning("Failed to update session summary: \(error.localizedDescription)")
		}

		// 4. Delete cold messages
		let pruneSql = """
		DELETE FROM messages WHERE session_id = ?
		AND id NOT IN (
		    SELECT id FROM messages WHERE session_id = ?
		    ORDER BY created_at DESC LIMIT ?
		)
		"""
		do {
			try await store.execute(sql: pruneSql, parameters: [sessionId, sessionId, hotWindow])
			logger.info("Session \(sessionId) compressed — kept last \(hotWindow) of ~\(tokenCount) tokens")
			compressedSessions.insert(sessionId)
		} catch {
			logger.warning("Failed to compress session \(sessionId): \(error.localizedDescription)")
		}
	}

	/// LLM-driven summary generation from cold messages.
	/// Attempts LLM summarization first; falls back to rule-based extraction on failure.
	/// P1-fix: toolCalls are included so that tool-use context survives compression.
	private func generateCompressionSummary(_ messages: [(role: String, content: String, toolCalls: String?)]) async -> String {
		// Build conversation context for the summarizer — include tool call info
		let conversationText = messages.map { msg -> String in
			let base = "\(msg.role): \(msg.content)"
			if let tc = msg.toolCalls, !tc.isEmpty {
				return base + "\n[tool_calls: \(tc)]"
			}
			return base
		}.joined(separator: "\n\n")

		// Attempt LLM summarization
		if let llmCallback = llmSummarizer {
			do {
				let prompt = """
				Summarize the following conversation in 3-5 concise bullet points. Focus on key topics, decisions, and outcomes.

				\(conversationText)
				"""
				let summary = try await llmCallback(prompt)
				logger.info("LLM summary generated (\\(summary.count) chars)")
				return summary
			} catch {
				logger.warning("LLM summarization failed (\\(error)), falling back to rules")
			}
		}

		// Rule-based fallback (always available)
		return Self.generateRuleBasedSummary(coldMessages: messages)
	}

	/// Rule-based summary generation from cold messages.
	/// Extracts conversation topics, questions, tool calls, and key assistant responses.
	/// Used as fallback when LLM summarization is unavailable or fails.
	/// P1-fix: now accepts toolCalls parameter for tool-use tracking.
	private static func generateRuleBasedSummary(coldMessages messages: [(role: String, content: String, toolCalls: String?)]) -> String {
		var topics: Set<String> = []
		var questions: [String] = []
		var resolutions: [String] = []
		var toolUses: [String] = []

		for msg in messages {
			// Capture tool call context so the summary knows what was attempted
			if let tc = msg.toolCalls, !tc.isEmpty {
				toolUses.append(String(tc.prefix(200)))
			}
			switch msg.role {
			case "user":
				if msg.content.contains("?") {
					questions.append(String(msg.content.prefix(min(msg.content.count, 120))))
				}
				topics.formUnion(extractKeywords(text: msg.content))
			case "assistant":
				if msg.content.lowercased().contains("solution") ||
					msg.content.lowercased().contains("fixed") ||
					msg.content.lowercased().contains("here's") ||
					msg.content.lowercased().contains("the answer")
				{
					resolutions.append(String(msg.content.prefix(min(msg.content.count, 100))))
				}
			default:
				break
			}
		}

		var parts: [String] = []
		parts.append("Session topics: \(topics.joined(separator: ", "))")
		if !questions.isEmpty {
			parts.append("Questions: \(questions.prefix(3).joined(separator: "; "))")
		}
		if !resolutions.isEmpty {
			parts.append("Resolutions: \(resolutions.prefix(2).joined(separator: "; "))")
		}
		if !toolUses.isEmpty {
			parts.append("Tool calls: \(toolUses.prefix(3).joined(separator: "; "))")
		}
		return parts.joined(separator: " | ")
	}

	/// Extract topic keywords from text.
	private static func extractKeywords(text: String) -> [String] {
		let lower = text.lowercased()
		let keywords = [
			"bug", "error", "fix", "debug", "test", "deploy", "config",
			"database", "API", "authentication", "performance", "memory",
			"compilation", "build", "CI", "model", "inference", "session",
		]
		return Array(keywords.filter { lower.contains($0) }.prefix(3))
	}

	// MARK: - Session Summary

	/// Get the compressed summary for a session.
	func getSessionSummary(_ sessionId: Int64) async throws -> String? {
		guard let result = try await store.scalarQuery(
			sql: "SELECT summary FROM sessions WHERE id = ?",
			parameters: [sessionId],
		)?.asString else { return nil }
		return result.isEmpty ? nil : result
	}

	// MARK: - TTL Expiry

	/// Purge expired sessions based on TTL.
	func purgeExpired() async throws -> ExpiryTask {
		let now = Date().timeIntervalSince1970
		let sql = """
		SELECT id FROM sessions
		WHERE (created_at / 1000000.0 + ttl_days * 86400) < ?
		"""
		let params: [AnyHashable] = [now]

		do {
			let rows = try await store.query(sql, parameters: params)
			let sessionIds = rows.compactMap { $0["id"]?.asInt64 }

			for sid in sessionIds {
				try await store.execute(sql: "DELETE FROM messages WHERE session_id = ?", parameters: [sid])
				try await store.execute(sql: "DELETE FROM sessions WHERE id = ?", parameters: [sid])
				sessionTokenCounts.removeValue(forKey: sid)
				compressedSessions.remove(sid)
			}

			return ExpiryTask(
				sessionIds: sessionIds,
				totalMessages: 0,
				scheduledAt: Date(),
			)
		} catch let sqliteErr as SQLiteError {
			throw sqliteErr
		} catch {
			throw SQLiteError.executionFailed(detail: error.localizedDescription)
		}
	}

	// MARK: - Internal

	private func updateSession(_ id: Int64, messageDelta: Int, tokenDelta: Int) async throws {
		let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
		do {
			try await store.execute(sql: """
			UPDATE sessions
			SET message_count = message_count + ?,
			    token_count = token_count + ?,
			    updated_at = ?
			WHERE id = ?
			""", parameters: [messageDelta, tokenDelta, now, id])
		} catch let sqliteErr as SQLiteError {
			throw sqliteErr
		} catch {
			throw SQLiteError.executionFailed(detail: error.localizedDescription)
		}
	}

	private func getLastInsertedId() async throws -> Int64 {
		guard let result = try await store.scalarQuery(sql: "SELECT last_insert_rowid()")?.asInt64 else {
			throw SQLiteError.executionFailed(detail: "Could not read last_insert_rowid")
		}
		return result
	}

	/// Expose FTS5 full-text search to the router layer.
	func searchFTS5(query: String, sessionId: Int64?, limit: Int) async throws -> [FTSSearchResult] {
		try await fts.search(query, sessionId: sessionId, limit: limit)
	}

	// MARK: - Structured Memory Events (Six-Element Model, 方案 B 单层)

	/// Alias for ``storeMemoryEvent(_:)`` — used by SelfCorrectionPipeline's persistMemory closure.
	func addMemory(_ event: MemoryEvent) async {
		try? await storeMemoryEvent(event)
	}

	/// Store a structured memory event (ON CONFLICT(dedup_key) DO UPDATE for facts).
	func storeMemoryEvent(_ event: MemoryEvent) async throws {
		let entitiesJson = event.entitiesJson ?? ""
		let tagsJson = event.tagsJson ?? ""
		let memoryType = event.memoryType.rawValue
		let sql: String

		// Facts/preferences use upsert to dedup; transients use plain insert
		if event.memoryType == .transient {
			sql = """
			INSERT INTO memory_events (session_id, timestamp, context, entities, cause, process, result,
			    resolution, memory_type, dedup_key, confidence, tags)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			"""
			do {
				try await store.execute(sql: sql, parameters: [
					event.sessionId, event.timestamp, event.context,
					entitiesJson, event.cause, event.process, event.result,
					event.resolution.rawValue, memoryType, event.dedupKey,
					event.confidence, tagsJson,
				])
			} catch let sqliteErr as SQLiteError {
				throw sqliteErr
			} catch {
				throw SQLiteError.executionFailed(detail: error.localizedDescription)
			}
		} else {
			// Upsert: bump confidence if newer, keep older timestamp
			sql = """
			INSERT INTO memory_events (session_id, timestamp, context, entities, cause, process, result,
			    resolution, memory_type, dedup_key, confidence, tags)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(dedup_key) DO UPDATE SET
			    confidence = max(excluded.confidence, confidence),
			    result = excluded.result,
			    resolution = excluded.resolution,
			    tags = excluded.tags,
			    process = excluded.process
			"""
			do {
				try await store.execute(sql: sql, parameters: [
					event.sessionId, event.timestamp, event.context,
					entitiesJson, event.cause, event.process, event.result,
					event.resolution.rawValue, memoryType, event.dedupKey,
					event.confidence, tagsJson,
				])
			} catch let sqliteErr as SQLiteError {
				throw sqliteErr
			} catch {
				throw SQLiteError.executionFailed(detail: error.localizedDescription)
			}
		}
	}

	/// Extract structured memory events from a conversation turn.
	func extractMemoryEvents(userMessage: String, assistantMessage: String, sessionId: Int64) async -> [MemoryEvent] {
		let events = Self.extractEventRules(
			userMessage: userMessage,
			assistantMessage: assistantMessage,
			sessionId: sessionId,
		)

		for event in events {
			do {
				try await storeMemoryEvent(event)
			} catch {
				logger.warning("Failed to store memory event: \(error)")
			}
		}

		return events
	}

	/// Rule-based event extraction — heuristic patterns from conversation turns.
	private static func extractEventRules(
		userMessage: String,
		assistantMessage: String,
		sessionId: Int64,
	) -> [MemoryEvent] {
		var events: [MemoryEvent] = []

		// Detect problem-solving pattern → pattern type (long-lived)
		let problemPatterns = ["error", "fail", "bug", "crash", "wrong", "cannot", "shouldn't", "broken"]
		let userHasProblem = problemPatterns.contains { userMessage.lowercased().contains($0) }
		let assistantHasSolution =
			assistantMessage.contains("the issue") ||
			assistantMessage.contains("the problem") ||
			assistantMessage.contains("the error") ||
			assistantMessage.contains("fixed") ||
			assistantMessage.contains("the solution")

		if userHasProblem && assistantHasSolution {
			events.append(MemoryEvent(
				sessionId: sessionId,
				context: "debugging",
				entities: ["session"],
				cause: Self.summarizeCause(text: userMessage),
				process: Self.summarizeProcess(text: assistantMessage),
				result: Self.summarizeResult(text: assistantMessage),
				resolution: .resolved,
				memoryType: .pattern,
				confidence: 0.7,
				tags: ["debug", "problem-solving"],
			))
		}

		// Detect learning/knowledge pattern → fact type (permanent)
		let isQuestion = userMessage.last == "?" ||
			userMessage.lowercased().contains("how to") ||
			userMessage.lowercased().contains("what is")
		if isQuestion {
			events.append(MemoryEvent(
				sessionId: sessionId,
				context: "knowledge",
				entities: ["session"],
				cause: Self.summarizeCause(text: userMessage),
				process: "answered",
				result: Self.summarizeResult(text: assistantMessage),
				resolution: .resolved,
				memoryType: .fact,
				confidence: 0.6,
				tags: ["learning", "knowledge"],
			))
		}

		// Detect decision pattern → preference type (permanent)
		let decisionPatterns = ["decide", "choose", "go with", "use ", "switch to", "change to"]
		let userDecided = decisionPatterns.contains { userMessage.lowercased().contains($0) }
		if userDecided {
			events.append(MemoryEvent(
				sessionId: sessionId,
				context: "decision",
				entities: ["user"],
				cause: "preference or requirement",
				process: Self.summarizeProcess(text: userMessage),
				result: String(assistantMessage.prefix(100)),
				resolution: .resolved,
				memoryType: .preference,
				confidence: 0.75,
				tags: ["decision", "preference"],
			))
		}

		return events
	}

	/// Summarize cause (≤50 chars).
	private static func summarizeCause(text: String) -> String {
		String(text.prefix(min(text.count, 50)))
	}

	/// Summarize process (≤80 chars).
	private static func summarizeProcess(text: String) -> String {
		String(text.prefix(min(text.count, 80)))
	}

	/// Summarize result (≤80 chars, last sentence).
	private static func summarizeResult(text: String) -> String {
		let sentences = text.components(separatedBy: ". ")
		let last = sentences.last ?? text
		return String(last.prefix(min(last.count, 80)))
	}

	// MARK: - Memory Lifecycle (方案 B)

	/// Purge expired transient events older than days limit.
	func purgeTransientEvents(days: Int = 30) async throws -> Int {
		let cutoff = Double(Int64(Date().timeIntervalSince1970) - Int64(days) * 86400) * 1_000_000
		let sql = """
		DELETE FROM memory_events
		WHERE memory_type = 'transient'
		  AND timestamp < ?
		"""
		do {
			_ = try await store.scalarQuery(sql: sql, parameters: [cutoff])
			return 0
		} catch let sqliteErr as SQLiteError {
			throw sqliteErr
		} catch {
			throw SQLiteError.executionFailed(detail: error.localizedDescription)
		}
	}

	/// Query structured memory events with filters.
	func queryMemoryEvents(
		sessionId: Int64? = nil,
		context: String? = nil,
		memoryType: MemoryEventType? = nil,
		resolution: MemoryEventResolution? = nil,
		minConfidence: Double = 0.0,
		limit: Int = 100,
	) async throws -> [MemoryEvent] {
		var conditions: [String] = []
		var params: [AnyHashable] = []

		if let sid = sessionId {
			conditions.append("session_id = ?")
			params.append(sid)
		}
		if let ctx = context {
			conditions.append("context = ?")
			params.append(ctx)
		}
		if let mt = memoryType {
			conditions.append("memory_type = ?")
			params.append(mt.rawValue)
		}
		if let res = resolution {
			conditions.append("resolution = ?")
			params.append(res.rawValue)
		}
		conditions.append("confidence >= ?")
		params.append(minConfidence)

		let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
		let sql = "SELECT * FROM memory_events\(whereClause) ORDER BY confidence DESC, timestamp DESC LIMIT ?"
		params.append(limit)

		do {
			let rows = try await store.query(sql, parameters: params)
			return rows.compactMap { MemoryEvent(from: $0) }
		} catch let sqliteErr as SQLiteError {
			throw sqliteErr
		} catch {
			throw SQLiteError.queryFailed(detail: error.localizedDescription)
		}
	}

	// MARK: - Cue Spreading + Confidence Boost

	/// After FTS5 recall, boost confidence of matched events (人脑: 回忆 = 强化).
	/// Each recall adds 0.05 to confidence, capped at 1.0.
	/// If confidence crosses 0.9 and event is transient, auto-promote to pattern.
	private func boostRecalled(ids: [Int64]) async throws {
		guard !ids.isEmpty else { return }
		let placeholders = String(repeating: "?", count: ids.count).split(separator: ",").map { String($0) }.joined(separator: ", ")
		// +0.05 capped at 1.0
		try await store.execute(
			sql: "UPDATE memory_events SET confidence = MIN(confidence + 0.05, 1.0) WHERE id IN (\(placeholders))",
			parameters: ids.map { $0 as Int64 },
		)
		// Auto-promote: transient + confidence >= 0.9 → pattern
		try await store.execute(
			sql: """
			UPDATE memory_events
			SET memory_type = 'pattern'
			WHERE id IN (\(placeholders))
			  AND memory_type = 'transient'
			  AND confidence >= 0.9
			""",
			parameters: ids.map { $0 as Int64 },
		)
	}

	/// Cue spreading: after primary FTS5 hit, expand by shared context/tags.
	/// Returns de-duplicated events sorted by confidence DESC.
	private func expandByCues(primaryIDs: [Int64], contexts: [String], tags: [String], limit: Int) async throws -> [MemoryEvent] {
		guard !primaryIDs.isEmpty else { return [] }
		let idPlaceholders = String(repeating: "?", count: primaryIDs.count).split(separator: ",").map { String($0) }.joined(separator: ", ")

		// Gather related events: same context OR shared tags (not already in primary)
		var expandedIDs = primaryIDs
		var allEvents = [MemoryEvent]()

		// Phase 1: Primary results (already fetched by caller)
		let primarySQL = "SELECT * FROM memory_events WHERE id IN (\(idPlaceholders))"
		let primaryRows = try await store.query(primarySQL, parameters: primaryIDs.map { $0 as Int64 })
		allEvents.append(contentsOf: primaryRows.compactMap { MemoryEvent(from: $0) })

		// Phase 2: Spread via context
		if !contexts.isEmpty {
			let ctxPlaceholders = String(repeating: "?", count: contexts.count).split(separator: ",").map { String($0) }.joined(separator: ", ")
			let spreadSQL = """
			SELECT * FROM memory_events
			WHERE context IN (\(ctxPlaceholders))
			  AND id NOT IN (\(idPlaceholders))
			  ORDER BY confidence DESC
			  LIMIT ?
			"""
			let spreadParams: [AnyHashable] = contexts.map(\.self) + primaryIDs.map { Int64($0) } + [limit / 2]
			let spreadRows = try await store.query(spreadSQL, parameters: spreadParams)
			allEvents.append(contentsOf: spreadRows.compactMap { MemoryEvent(from: $0) })
			expandedIDs.append(contentsOf: spreadRows.compactMap { $0["id"]?.asInt64 })
		}

		// Phase 3: Spread via tags (comma-separated in tags column)
		if !tags.isEmpty {
			var tagConditions = contexts.isEmpty ? "" : " AND "
			tagConditions += tags.map { "instr(tags, '\($0)') > 0" }.joined(separator: " OR ")
			let tagSQL = """
			SELECT * FROM memory_events
			WHERE (\(tagConditions))
			  AND id NOT IN (\(idPlaceholders))
			  ORDER BY confidence DESC
			  LIMIT ?
			"""
			let tagParams: [AnyHashable] = primaryIDs.map { $0 as Int64 } + [limit / 3]
			let tagRows = try await store.query(tagSQL, parameters: tagParams)
			allEvents.append(contentsOf: tagRows.compactMap { MemoryEvent(from: $0) })
			expandedIDs.append(contentsOf: tagRows.compactMap { $0["id"]?.asInt64 })
		}

		// Phase 4: Boost all recalled events
		try await boostRecalled(ids: expandedIDs)

		// De-duplicate by id, sort by confidence DESC
		var seen = Set<Int64>()
		var deduped: [MemoryEvent] = []
		for event in allEvents {
			if seen.insert(event.id).inserted {
				deduped.append(event)
			}
		}
		deduped.sort { $0.confidence > $1.confidence }
		return Array(deduped.prefix(limit))
	}

	/// Cross-session permanent memory recall — facts + preferences with recency scoring.
	///
	/// Uses cue spreading: after primary FTS5 hit, expands by shared context/tags
	/// to surface related memories the user may not have directly queried for.
	func recallPermanentMemory(
		query: String? = nil,
		memoryTypes: [MemoryEventType] = [.fact, .preference, .pattern],
		minConfidence _: Double = 0.5,
		limit: Int = 50,
	) async throws -> [MemoryEvent] {
		let typeList = memoryTypes.map(\.rawValue).joined(separator: "', '")
		var sql = """
		SELECT * FROM memory_events
		WHERE memory_type IN ('\(typeList)')
		  AND confidence >= 0.5
		ORDER BY confidence DESC, timestamp DESC
		LIMIT ?
		"""

		// FTS filter if query provided
		let primaryIDs: [Int64]
		let primaryContexts: [String]
		let primaryTags: [String]

		if let q = query, !q.isEmpty {
			sql = """
			SELECT me.* FROM memory_events me
			INNER JOIN memory_events_fts fts ON me.id = fts.rowid
			WHERE me.memory_type IN ('\(typeList)')
			  AND me.confidence >= 0.5
			  AND fts MATCH ?
			ORDER BY fts.rank ASC
			LIMIT ?
			"""

			do {
				let rows = try await store.query(sql, parameters: [q, limit])
				primaryIDs = rows.compactMap { $0["id"]?.asInt64 }
				primaryContexts = Array(Set(rows.compactMap { $0["context"]?.asString }.filter { !$0.isEmpty }))
				primaryTags = Array(extractAllTags(rows: rows).prefix(10))
			} catch let sqliteErr as SQLiteError {
				throw sqliteErr
			} catch {
				throw SQLiteError.queryFailed(detail: error.localizedDescription)
			}

			// Cue spread if we have primary hits
			if !primaryIDs.isEmpty {
				return try await expandByCues(primaryIDs: primaryIDs, contexts: primaryContexts, tags: primaryTags, limit: limit)
			}
			return []
		}

		// No query: return top confidence events with boost
		do {
			let rows = try await store.query(sql, parameters: [limit])
			let events = rows.compactMap { MemoryEvent(from: $0) }
			let ids = events.map(\.id)
			if !ids.isEmpty {
				try await boostRecalled(ids: ids)
			}
			return events
		} catch let sqliteErr as SQLiteError {
			throw sqliteErr
		} catch {
			throw SQLiteError.queryFailed(detail: error.localizedDescription)
		}
	}

	/// Full-text search on memory events (causes, processes, results).
	///
	/// Uses cue spreading: after primary FTS5 hit, expands by shared context/tags.
	func searchMemoryEvents(query: String, sessionId: Int64? = nil, limit: Int = 50) async throws -> [MemoryEvent] {
		let sql: String
		let params: [AnyHashable]

		if let sid = sessionId {
			sql = """
			SELECT me.* FROM memory_events me
			INNER JOIN memory_events_fts fts ON me.id = fts.rowid
			WHERE fts MATCH ? AND me.session_id = ?
			ORDER BY fts.rank ASC
			LIMIT ?
			"""
			params = [query, sid, limit]
		} else {
			sql = """
			SELECT me.* FROM memory_events me
			INNER JOIN memory_events_fts fts ON me.id = fts.rowid
			WHERE fts MATCH ?
			ORDER BY fts.rank ASC
			LIMIT ?
			"""
			params = [query, limit]
		}

		do {
			let rows = try await store.query(sql, parameters: params)
			let primaryIDs = rows.compactMap { $0["id"]?.asInt64 }
			let primaryContexts = Array(Set(rows.compactMap { $0["context"]?.asString }.filter { !$0.isEmpty }))
			let primaryTags = Array(extractAllTags(rows: rows).prefix(10))

			if !primaryIDs.isEmpty {
				return try await expandByCues(primaryIDs: primaryIDs, contexts: primaryContexts, tags: primaryTags, limit: limit)
			}
			return []
		} catch let sqliteErr as SQLiteError {
			throw sqliteErr
		} catch {
			throw SQLiteError.queryFailed(detail: error.localizedDescription)
		}
	}

	// MARK: - Tag Helpers

	/// Extract all unique tags from query results for cue spreading.
	private func extractAllTags(rows: [[String: SendableValue]]) -> [String] {
		var allTags = Set<String>()
		for row in rows {
			if let tagsStr = row["tags"]?.asString, !tagsStr.isEmpty {
				if let data = tagsStr.data(using: .utf8),
				   let tags = try? JSONDecoder().decode([String].self, from: data)
				{
					allTags.formUnion(tags)
				}
			}
		}
		return Array(allTags)
	}
}

extension SessionModel {
	/// Initialize from a SQLite row dictionary.
	init?(from row: [String: SendableValue]) {
		guard
			let id = row["id"]?.asInt64,
			let modelId = row["model_id"]?.asString,
			let createdAtTs = row["created_at"]?.asInt64,
			let updatedAtTs = row["updated_at"]?.asInt64
		else { return nil }

		self.id = id
		self.modelId = modelId
		createdAt = Date(timeIntervalSince1970: Double(createdAtTs) / 1_000_000)
		updatedAt = Date(timeIntervalSince1970: Double(updatedAtTs) / 1_000_000)
		messageCount = Self.getInt(row, "message_count") ?? 0
		tokenCount = Self.getInt(row, "token_count") ?? 0
		summary = row["summary"]?.asString
		ttlDays = Self.getInt(row, "ttl_days") ?? 180
	}

	private static func getInt(_ row: [String: SendableValue], _ key: String) -> Int? {
		guard let sv = row[key] else { return nil }
		switch sv {
		case let .integer(v): return Int(exactly: v)
		case let .float(v): return Int(exactly: v.rounded())
		case let .text(t): return Int(t)
		case .blob, .null: return nil
		}
	}
}
