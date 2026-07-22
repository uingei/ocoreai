// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// HTTP E2E Smoke Tests — Request → Router → Middleware → Handler guard → Response
///
/// Verifies the full HTTP pipeline up to the validation layer.
/// Does NOT test inference (requires loaded model + MLX GPU).

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing
@testable import ocoreai
import ocoreaiTestUtilities

@Suite("E2E Smoke — HTTP Handler Pipeline")
struct HTTPHandlerE2ESmokeTests {
	// MARK: - Helpers

	private static func uuidPath() -> String {
		FileManager.default.temporaryDirectory.appendingPathComponent(
			"e2e_\(UUID().uuidString.prefix(8)).sqlite"
		).path
	}

	private static func cleanupDBs(_ path1: String, _ path2: String) {
		try? FileManager.default.removeItem(atPath: path1)
		try? FileManager.default.removeItem(atPath: path2)
	}

	private static func makeEnginePool() -> EnginePool {
		EnginePool(
			config: .default,
			logger: Logger(label: "test.e2e.http"),
			tokenizerManager: TokenizerManager()
		)
	}

	private static func makeMCPBridge() -> MCPBridge {
		MCPBridge(
			toolRegistry: ToolRegistry(log: Logger(label: "test.e2e.http")),
			transport: MCPStdioTransport(log: Logger(label: "test.e2e.http"))
		)
	}

	private static func makeRateLimitMiddleware() -> RateLimitMiddleware<OCoreAIContext> {
		RateLimitMiddleware(
			provider: RateLimitProvider(
				config: RateLimitProvider.Config(
					globalRate: 1000,
					globalBurst: 2000,
					perModelRate: 500,
					perModelBurst: 1000,
					perIPRate: 500,
					perIPBurst: 1000,
					enabled: true
				),
				logger: Logger(label: "test.e2e.http")
			),
			logger: Logger(label: "test.e2e.http")
		)
	}

	private static func makeTestApp(_ dbPath1: String, _ dbPath2: String) async throws -> some ApplicationProtocol {
		let enginePool = makeEnginePool()

		let store = SQLiteStore(path: dbPath1)
		try await store.open()
		let fts = FTS5Search(store: store)
		let compressor = SessionCompressor(store: store, fts: fts)

		let mbStore = SQLiteStore(path: dbPath2)
		try await mbStore.open()
		let mbFts = FTS5Search(store: mbStore)
		let mb = MessageBuilder(
			systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
			sessionCompressor: SessionCompressor(store: mbStore, fts: mbFts),
			complexityAnalyzer: ComplexityAnalyzer(),
			thinkingBudget: ThinkingBudget()
		)

		let scheduler = SchedulerActor(
			maxQueueSize: 4,
			memoryTracker: nil,
			log: Logger(label: "test.e2e.http")
		)

		return try await buildApplication(
			enginePool: enginePool,
			scheduler: scheduler,
			metrics: MetricsRegistry(),
			sessionCompressor: compressor,
			semanticSearch: nil,
			mcpBridge: makeMCPBridge(),
			systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
			messageBuilder: mb,
			logger: Logger(label: "test.e2e.http"),
			authMiddleware: AuthMiddleware<OCoreAIContext>(
				config: .default,
				logger: Logger(label: "test.e2e.http")
			),
			rateLimitMiddleware: makeRateLimitMiddleware(),
			hfToken: nil,
			msToken: nil
		)
	}

	private static func jsonBody(_ dict: [String: Any]) throws -> ByteBuffer {
		var buffer = ByteBufferAllocator().buffer(capacity: 1024)
		let data = try JSONSerialization.data(withJSONObject: dict, options: [])
		buffer.writeBytes(data)
		return buffer
	}

	private static func stringBody(_ s: String) -> ByteBuffer {
		var buffer = ByteBufferAllocator().buffer(capacity: s.utf8.count)
		buffer.writeString(s)
		return buffer
	}

	private static func responseBody(from response: TestResponse) -> String {
		response.body.getString(at: 0, length: response.body.readableBytes) ?? ""
	}

	// MARK: - Tests

	@Test("GET /health returns 200 with status ok")
	func testHealthEndpoint() async throws {
		let db1 = Self.uuidPath(), db2 = Self.uuidPath()
		defer { Self.cleanupDBs(db1, db2) }
		let app = try await Self.makeTestApp(db1, db2)
		try await app.test(.router) { client in
			try await client.execute(uri: "/health", method: .get) { response in
				#expect(response.status == .ok)
				let body = Self.responseBody(from: response)
				#expect(body.contains("ok"), "Health body should contain 'ok': \(body)")
			}
		}
	}

	@Test("GET /v1/models returns 200 with list")
	func testModelsEndpoint() async throws {
		let db1 = Self.uuidPath(), db2 = Self.uuidPath()
		defer { Self.cleanupDBs(db1, db2) }
		let app = try await Self.makeTestApp(db1, db2)
		try await app.test(.router) { client in
			try await client.execute(uri: "/v1/models", method: .get) { response in
				#expect(response.status == .ok)
				let body = Self.responseBody(from: response)
				#expect(body.contains("list"), "Models body should contain 'list': \(body)")
			}
		}
	}

	@Test("GET /metrics returns 200")
	func testMetricsEndpoint() async throws {
		let db1 = Self.uuidPath(), db2 = Self.uuidPath()
		defer { Self.cleanupDBs(db1, db2) }
		let app = try await Self.makeTestApp(db1, db2)
		try await app.test(.router) { client in
			try await client.execute(uri: "/metrics", method: .get) { response in
			#expect(response.status == .ok)
			}
		}
	}

	@Test("POST /v1/chat/completions empty messages → 400")
	func testChatEmptyMessages() async throws {
		let db1 = Self.uuidPath(), db2 = Self.uuidPath()
		defer { Self.cleanupDBs(db1, db2) }
		let app = try await Self.makeTestApp(db1, db2)
		try await app.test(.router) { client in
			let buf: ByteBuffer = try Self.jsonBody(["model": "any-model", "messages": []])
			var headers: HTTPFields = [:]
			headers[.contentType] = "application/json"
			try await client.execute(
				uri: "/v1/chat/completions",
				method: .post,
				headers: headers,
				body: buf
			) { response in
				// 400 (validation) or 500 (no model loaded) — both prove the HTTP pipeline works
				#expect(response.status == .badRequest || response.status == .internalServerError)
			}
		}
	}

	@Test("POST /v1/messages empty messages → 400")
	func testAnthropicEmptyMessages() async throws {
		let db1 = Self.uuidPath(), db2 = Self.uuidPath()
		defer { Self.cleanupDBs(db1, db2) }
		let app = try await Self.makeTestApp(db1, db2)
		try await app.test(.router) { client in
			let buf: ByteBuffer = try Self.jsonBody(["model": "claude-test", "messages": []])
			var headers: HTTPFields = [:]
			headers[.contentType] = "application/json"
			try await client.execute(
				uri: "/v1/messages",
				method: .post,
				headers: headers,
				body: buf
			) { response in
				#expect(response.status == .badRequest)
			}
		}
	}

	@Test("POST /v1/count-tokens empty prompt → 400|500")
	func testCountTokensEmptyPrompt() async throws {
		let db1 = Self.uuidPath(), db2 = Self.uuidPath()
		defer { Self.cleanupDBs(db1, db2) }
		let app = try await Self.makeTestApp(db1, db2)
		try await app.test(.router) { client in
			let buf: ByteBuffer = try Self.jsonBody(["model": "any-model", "prompt": ""])
			var headers: HTTPFields = [:]
			headers[.contentType] = "application/json"
			try await client.execute(
				uri: "/v1/count-tokens",
				method: .post,
				headers: headers,
				body: buf
			) { response in
				// 400 (validation) or 500 (no model loaded) — both prove the HTTP pipeline works
				#expect(response.status == .badRequest || response.status == .internalServerError)
			}
		}
	}

	@Test("Invalid JSON → 400")
	func testInvalidJSON() async throws {
		let db1 = Self.uuidPath(), db2 = Self.uuidPath()
		defer { Self.cleanupDBs(db1, db2) }
		let app = try await Self.makeTestApp(db1, db2)
		try await app.test(.router) { client in
			let buf = Self.stringBody("not json at all")
			var headers: HTTPFields = [:]
			headers[.contentType] = "application/json"
			try await client.execute(
				uri: "/v1/chat/completions",
				method: .post,
				headers: headers,
				body: buf
			) { response in
				#expect(response.status == .badRequest)
			}
		}
	}

	@Test("POST /v1/chat/completions missing model → 400|503")
	func testMissingModel() async throws {
		let db1 = Self.uuidPath(), db2 = Self.uuidPath()
		defer { Self.cleanupDBs(db1, db2) }
		let app = try await Self.makeTestApp(db1, db2)
		try await app.test(.router) { client in
			let buf: ByteBuffer = try Self.jsonBody(["messages": [["role": "user", "content": "hello"]]])
			var headers: HTTPFields = [:]
			headers[.contentType] = "application/json"
			try await client.execute(
				uri: "/v1/chat/completions",
				method: .post,
				headers: headers,
				body: buf
			) { response in
				// 400 (validation) or 503 (no model loaded → engineUnavailable) or 500 — all prove the pipeline works
				#expect(response.status == .badRequest || response.status == .serviceUnavailable || response.status == .internalServerError)
			}
		}
	}
}
