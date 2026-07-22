// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Integration Tests — Middleware Chain: Auth + Rate Limit
///
/// Fills the gap where HTTPE2ESmokeTests runs with auth disabled
/// (AuthMiddleware(.default) → env var → empty → bypassed).
/// These tests verify the middleware pipeline with auth actually enabled.

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing
@testable import ocoreai

private func e2eUUID() -> String {
	FileManager.default.temporaryDirectory
		.appendingPathComponent("e2e_\(UUID().uuidString.prefix(8)).sqlite")
		.path
}

private func cleanupE2E(_ paths: [String]) {
	for p in paths { try? FileManager.default.removeItem(atPath: p) }
}

@Suite("Middleware Chain")
struct MiddlewareChainTests {

	private static let log = Logger(label: "test.integration.middleware")

	private static func jsonBody(_ dict: [String: Any]) throws -> ByteBuffer {
		var buf = ByteBufferAllocator().buffer(capacity: 1024)
		buf.writeBytes(try JSONSerialization.data(withJSONObject: dict, options: []))
		return buf
	}

	private static func makeApp(
		authKeys: [String],
		rlConfig: RateLimitProvider.Config = RateLimitProvider.Config(
			globalRate: 1000, globalBurst: 2000,
			perModelRate: 500, perModelBurst: 1000,
			perIPRate: 500, perIPBurst: 1000, enabled: true
		)
	) async throws -> ((some ApplicationProtocol), [String]) {
		let db1 = e2eUUID()
		let db2 = e2eUUID()
		let enginePool = EnginePool(config: .default, logger: Self.log, tokenizerManager: TokenizerManager())
		let store = SQLiteStore(path: db1)
		try await store.open()
		let fts = FTS5Search(store: store)
		let compressor = SessionCompressor(store: store, fts: fts)
		let mbStore = SQLiteStore(path: db2)
		try await mbStore.open()
		let mbFts = FTS5Search(store: mbStore)
		let mb = MessageBuilder(
			systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
			sessionCompressor: SessionCompressor(store: mbStore, fts: mbFts),
			complexityAnalyzer: ComplexityAnalyzer(),
			thinkingBudget: ThinkingBudget()
		)
		let scheduler = SchedulerActor(maxQueueSize: 4, memoryTracker: nil, log: Self.log)
		let app = try await buildApplication(
			enginePool: enginePool, scheduler: scheduler, metrics: MetricsRegistry(),
			sessionCompressor: compressor,
			semanticSearch: nil,
			mcpBridge: MCPBridge(toolRegistry: ToolRegistry(log: Self.log), transport: MCPStdioTransport(log: Self.log)),
			systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
			messageBuilder: mb, logger: Self.log,
			authMiddleware: AuthMiddleware<OCoreAIContext>(config: AuthConfig(apiKeys: authKeys), logger: Self.log),
			rateLimitMiddleware: RateLimitMiddleware(
				provider: RateLimitProvider(config: rlConfig, logger: Self.log),
				logger: Self.log
			),
			hfToken: nil, msToken: nil
		)
		return (app, [db1, db2])
	}

	// ── Auth blocks unauthenticated ──

	@Test("Auth on: no key → 401/403")
	func testAuthBlocksUnauthenticated() async throws {
		let (app, dbs) = try await Self.makeApp(authKeys: ["key1"])
		defer { cleanupE2E(dbs) }
		try await app.test(.router) { client in
			let buf = try Self.jsonBody(["model": "x", "messages": [["role": "user", "content": "hi"]]])
			var h: HTTPFields = [.contentType: "application/json"]
			try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h, body: buf) { r in
				#expect(r.status == .unauthorized || r.status == .forbidden, "got \(r.status)")
			}
		}
	}

	@Test("Auth on: GET /health bypasses")
	func testAuthBypassHealth() async throws {
		let (app, dbs) = try await Self.makeApp(authKeys: ["key1"])
		defer { cleanupE2E(dbs) }
		try await app.test(.router) { client in
			try await client.execute(uri: "/health", method: .get) { r in #expect(r.status == .ok) }
		}
	}

	@Test("Auth on: GET /v1/models bypasses")
	func testAuthBypassModels() async throws {
		let (app, dbs) = try await Self.makeApp(authKeys: ["key1"])
		defer { cleanupE2E(dbs) }
		try await app.test(.router) { client in
			try await client.execute(uri: "/v1/models", method: .get) { r in #expect(r.status == .ok) }
		}
	}

	// ── Auth: valid credentials pass ──

	@Test("Auth on: Bearer passes → handler sees request")
	func testAuthBearer() async throws {
		let (app, dbs) = try await Self.makeApp(authKeys: ["key1"])
		defer { cleanupE2E(dbs) }
		try await app.test(.router) { client in
			let buf = try Self.jsonBody(["model": "x", "messages": []])
			var h: HTTPFields = [.contentType: "application/json"]
			h[.authorization] = "Bearer key1"
			try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h, body: buf) { r in
				#expect(r.status != .unauthorized, "auth fail: \(r.status)")
			}
		}
	}

	@Test("Auth on: api-key header passes")
	func testAuthApiKeyHeader() async throws {
		let (app, dbs) = try await Self.makeApp(authKeys: ["secret"])
		defer { cleanupE2E(dbs) }
		try await app.test(.router) { client in
			let buf = try Self.jsonBody(["model": "x", "messages": [["role": "user", "content": "hi"]]])
			var h: HTTPFields = [.contentType: "application/json"]
			h[HTTPField.Name("api-key")!] = "secret"
			try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h, body: buf) { r in
				#expect(r.status != .unauthorized, "auth fail: \(r.status)")
			}
		}
	}

	@Test("Auth on: api_key query param passes")
	func testAuthQueryParam() async throws {
		let (app, dbs) = try await Self.makeApp(authKeys: ["qkey"])
		defer { cleanupE2E(dbs) }
		try await app.test(.router) { client in
			let buf = try Self.jsonBody(["model": "x", "messages": [["role": "user", "content": "hi"]]])
			var h: HTTPFields = [.contentType: "application/json"]
			try await client.execute(uri: "/v1/chat/completions?api_key=qkey", method: .post, headers: h, body: buf) { r in
				#expect(r.status != .unauthorized, "auth fail: \(r.status)")
			}
		}
	}

	@Test("Auth on: wrong key → 401")
	func testAuthWrongKey() async throws {
		let (app, dbs) = try await Self.makeApp(authKeys: ["correct"])
		defer { cleanupE2E(dbs) }
		try await app.test(.router) { client in
			let buf = try Self.jsonBody(["model": "x", "messages": [["role": "user", "content": "hi"]]])
			var h: HTTPFields = [.contentType: "application/json"]
			h[.authorization] = "Bearer wrong"
			try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h, body: buf) { r in
				#expect(r.status == .unauthorized, "got \(r.status)")
			}
		}
	}

	@Test("Auth off: no key required")
	func testAuthDisabled() async throws {
		let (app, dbs) = try await Self.makeApp(authKeys: [])
		defer { cleanupE2E(dbs) }
		try await app.test(.router) { client in
			let buf = try Self.jsonBody(["model": "x", "messages": []])
			var h: HTTPFields = [.contentType: "application/json"]
			try await client.execute(uri: "/v1/chat/completions", method: .post, headers: h, body: buf) { r in
				#expect(r.status == .badRequest, "auth off, got \(r.status)")
			}
		}
	}

	// ── Rate limit ──

	@Test("Rate limit: burst=2 → 3rd request 429")
	func testRateLimitExhaustion() async throws {
		let tiny = RateLimitProvider.Config(
			globalRate: 5, globalBurst: 2,
			perModelRate: 5, perModelBurst: 2,
			perIPRate: 5, perIPBurst: 2, enabled: true
		)
		let (app, dbs) = try await Self.makeApp(authKeys: [], rlConfig: tiny)
		defer { cleanupE2E(dbs) }
		try await app.test(.router) { client in
			try await client.execute(uri: "/health", method: .get) { r in #expect(r.status == .ok) }
			try await client.execute(uri: "/health", method: .get) { r in #expect(r.status == .ok) }
			try await client.execute(uri: "/health", method: .get) { r in
				#expect(r.status == .tooManyRequests, "expected 429, got \(r.status)")
			}
		}
	}

	@Test("Rate limit: disabled → 5 requests pass")
	func testRateLimitDisabled() async throws {
		let off = RateLimitProvider.Config(
			globalRate: 1000, globalBurst: 2000,
			perModelRate: 500, perModelBurst: 1000,
			perIPRate: 500, perIPBurst: 1000, enabled: false
		)
		let (app, dbs) = try await Self.makeApp(authKeys: [], rlConfig: off)
		defer { cleanupE2E(dbs) }
		try await app.test(.router) { client in
			for _ in 0..<5 {
				try await client.execute(uri: "/health", method: .get) { r in #expect(r.status == .ok) }
			}
		}
	}
}
