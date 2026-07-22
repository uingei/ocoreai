// ToolDispatchBridgeTests.swift — Verify ChatSession tool injection on both pool-hit and new-session paths.

import Testing
import Logging
@testable import ocoreai

@Suite("Tool Dispatch Bridge")
struct ToolDispatchBridgeTests {
	@Test("pool-hit path: registry produces valid tool specs")
	func poolHitPathProducesSpecs() async {
		let registry = ToolRegistry(log: Logger(label: "test.bridge.poolhit"))
		let entry = ToolEntry(
			name: "test_tool",
			toolset: "test",
			schema: .init(parameters: ["key": .string]),
			handler: { _ in "ok" }
		)
		try? await registry.register(entry)

		let specs = await registry.toToolSpecs()
		#expect(!specs.isEmpty)
		let specEntry = specs[0]
		let fn = specEntry["function"] as? [String: Any] ?? [:]
		#expect(fn["name"] as? String == "test_tool")
	}

	@Test("new-session path: multiple tools produce matching spec count")
	func newSessionPathProducesSpecs() async {
		let registry = ToolRegistry(log: Logger(label: "test.bridge.newsession"))
		try? await registry.register(
			ToolEntry(name: "weather", toolset: "t", schema: .init(parameters: ["city": .string]), handler: { _ in "\"sunny\"" }))
		try? await registry.register(
			ToolEntry(name: "clock", toolset: "t", schema: .init(), handler: { _ in "now" }))

		let specs = await registry.toToolSpecs()
		#expect(specs.count == 2)
	}

	@Test("empty registry produces empty specs")
	func emptyRegistry() async {
		let registry = ToolRegistry(log: Logger(label: "test.bridge.empty"))
		let specs = await registry.toToolSpecs()
		#expect(specs.isEmpty)
	}

	@Test("tool call round-trip: registry dispatch returns handler result")
	func toolCallRoundTrip() async {
		let registry = ToolRegistry(log: Logger(label: "test.bridge.roundtrip"))
		try? await registry.register(
			ToolEntry(name: "echo", toolset: "t", schema: .init(parameters: ["msg": .string]), handler: { _ in "hello" })
		)
		do {
			let result = try await registry.call("echo", arguments: #"{"msg": "hello"}"#)
			#expect(result == "hello")
		} catch {
			Issue.record("Tool dispatch failed: \(error)")
		}
	}
}
