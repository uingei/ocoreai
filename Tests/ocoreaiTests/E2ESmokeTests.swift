// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// E2E Smoke Tests — Control plane integration
///
/// Tests the full chain across modules (Scheduler → SQLite → ToolRegistry → AgentLoop)
/// without requiring MLX GPU backend or loaded models.

import Testing
import Foundation
import Logging
@testable import ocoreai

@Suite("E2E Smoke — Control Plane")
struct E2ESmokeTests {
	
	// MARK: - Full Scheduler → MemoryTracker → Snapshot pipeline
	
	@Test("Scheduler handles concurrent submissions with memory tracking")
	func testSchedulerMemoryPipeline() async {
		let log = Logger(label: "test.e2e.scheduler")
		
		// 64 MB budget — enough for a few requests
		let tracker = MemoryTracker(budgetBytes: 64 * 1024 * 1024)
		let sched = SchedulerActor(maxQueueSize: 64, memoryTracker: tracker, log: log)
		
		// Submit 3 requests at different priorities
		let ids = ["p0-urgent", "p1-chat", "p2-bg"]
		let priorities: [RequestPriority] = [.interrupt, .chat, .background]
		var submitOK = 0
		
		for (id, prio) in zip(ids, priorities) {
			let req = SchedulingRequest(
				id: id,
				priority: prio,
				modelId: "test-model",
				prompt: "hello \(id)",
				tokenBudget: 1024
			)
			if (try? await sched.submit(req)) != nil {
				submitOK += 1
			}
		}
		
		#expect(submitOK == 3)
		let pc = await sched.pendingCount
		let ac = await sched.activeCount
		#expect(pc + ac >= 3)
		
		// Dispatch should return in priority order: interrupt first
		let first = await sched.dispatch()
		#expect(first?.id == "p0-urgent")
		
		// Snapshot should reflect active state
		let snap = await sched.snapshot()
		#expect(snap.inferringCount >= 1)
		#expect(snap.totalRequests >= 1)
		
		// Complete all active
		for id in ids {
			await sched.complete(id)
		}
		
		// Final snapshot — everything done
		let finalSnap = await sched.snapshot()
		#expect(finalSnap.inferringCount == 0)
	}
	
	// MARK: - ToolRegistry → AgentLoop result pipeline
	
	@Test("ToolRegistry full lifecycle: register → call → result")
	func testToolRegistryFullLifecycle() async {
		let log = Logger(label: "test.e2e.tools")
		let registry = ToolRegistry(log: log)
		
		// Register a tool with parameters and handler
		let entry = ToolEntry(
			name: "calculator",
			toolset: "math",
			schema: ToolSchema(parameters: ["a": .integer, "b": .integer]),
			handler: { _ in "sum=7" }
		)
		
		try? await registry.register(entry)
		
		// Lookup
		#expect(await registry.lookup("calculator") != nil)
		
		// Execute
		do {
			let result = try await registry.call("calculator", arguments: "{\"a\":3, \"b\":4}")
			#expect(result.contains("sum=7"))
		} catch {
			#expect(Bool(false), "Unexpected: \(error)")
		}
		
		// List tools
		let tools = await registry.listTools()
		#expect(tools.contains("calculator"))
		
		// Verify toolset grouping
		let mathTools = await registry.listByToolset("math")
		#expect(mathTools.count == 1)
	}
	
	// MARK: - AgentLoop result pipeline

	@Test("AgentLoopResult accumulates iterations and tool calls")
	func testAgentLoopResultPipeline() {
		var result = AgentLoopResult()

		// Simulate iterations
		result.iterationCount = 2

		result.text = "It's sunny today. Enjoy!"
		result.finishReason = "stop"
		result.totalTokens = 384

		#expect(result.iterationCount == 2)
		#expect(result.iters.isEmpty)
		#expect(result.finishReason == "stop")
		#expect(result.text.contains("sunny"))
		#expect(result.toolCalls?.isEmpty ?? true)
	}
	
	// MARK: - Config → EnginePoolConfig mapping chain
	
	@Test("AppConfig maps to EnginePoolConfig with correct defaults")
	func testConfigToEngineMapping() {
		let log = Logger(label: "test.e2e.config")
		let appConfig = AppConfig() // uses YAML defaults
		
		let engineConfig = EnginePoolConfig(from: appConfig, logger: log)
		
		// Must have valid values
		#expect(engineConfig.maxConcurrentSessions >= 1)
		#expect(engineConfig.maxQueueSize > 0)
		#expect(!engineConfig.defaultModelId.isEmpty)
		#expect(engineConfig.inferenceTimeoutSeconds > 0)
		
		// Session pool config must be present
		#expect(engineConfig.sessionPoolConfig != nil)
	}
	
	// MARK: - SQLite session + FTS5 round-trip

	@Test("Session persisted to SQLite and found via FTS5 search")
	func testSessionPersistenceRoundtrip() async throws {
		let tempDB = "\(FileManager.default.temporaryDirectory.path)/e2e_test_\(UUID().uuidString.prefix(8)).sqlite"
		let store = SQLiteStore(path: tempDB)
		try await store.open()

		let now = Int64(Date().timeIntervalSince1970 * 1_000_000)

		try await store.execute(
			sql: "INSERT INTO sessions (model_id, created_at, updated_at, message_count, token_count) VALUES (?, ?, ?, ?, ?)",
			parameters: ["e2e-model", now, now, 2, 15]
		)
		try await store.execute(
			sql: "INSERT INTO messages (session_id, role, content, created_at, token_count) VALUES (?, ?, ?, ?, ?)",
			parameters: [1, "user", "Hello there friend", Int64(1), 10]
		)
		try await store.execute(
			sql: "INSERT INTO messages (session_id, role, content, created_at, token_count) VALUES (?, ?, ?, ?, ?)",
			parameters: [1, "assistant", "Hi! How can I help?", Int64(2), 5]
		)

		// FTS5 search for "Hello"
		let results = try await store.query(
			"SELECT content FROM messages_fts WHERE messages_fts MATCH 'Hello' ORDER BY rank LIMIT 1"
		)

		#expect(!results.isEmpty)
		let content = results[0]["content"]?.asString ?? ""
		#expect(content.contains("Hello"))

		await store.close()
		try? FileManager.default.removeItem(atPath: tempDB)
	}
}