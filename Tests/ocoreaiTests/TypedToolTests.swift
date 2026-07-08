// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// TypedToolTests.swift — validates ToolEntry.typed factory:
/// Codable decode, type-safe dispatch, and error handling.

import Testing
import Foundation
import Logging
@testable import ocoreai

@Suite("ToolEntry.typed — Typed Factory")
struct TypedToolTests {
	func makeRegistry() -> ToolRegistry {
		ToolRegistry(log: Logger(label: "test.registry.typed"))
	}

	@Test("typed tool decodes JSON args and returns result")
	func typedToolWorks() async {
		struct Args: Codable { let x: Int; let y: Int }
		let registry = makeRegistry()

		try? await registry.register(
			ToolEntry.typed(name: "add", toolset: "math", argsType: Args.self) { args in
				String(args.x + args.y)
			}
		)

		do {
			let result = try await registry.call("add", arguments: #"{"x": 3, "y": 4}"#)
			#expect(result == "7")
		} catch {
			#expect(Bool(false), "Unexpected error: \(error)")
		}
	}

	@Test("typed tool rejects invalid JSON")
	func typedToolRejectsInvalidJSON() async {
		struct Args: Codable { let name: String }
		let registry = makeRegistry()

		try? await registry.register(
			ToolEntry.typed(name: "greet", toolset: "chat", argsType: Args.self) { _ in "ok" }
		)

		do {
			_ = try await registry.call("greet", arguments: "not json")
			#expect(Bool(false), "Expected throw on invalid JSON")
		} catch let error as ToolError {
			#expect(error.localizedDescription.contains("Invalid parameter"))
		} catch {
			#expect(Bool(false), "Unexpected error type: \(error)")
		}
	}

	@Test("typed tool rejects missing required field")
	func typedToolRejectsMissingField() async {
		struct Args: Codable { let name: String; let age: Int }
		let registry = makeRegistry()

		try? await registry.register(
			ToolEntry.typed(name: "profile", toolset: "user", argsType: Args.self) { _ in "ok" }
		)

		do {
			_ = try await registry.call("profile", arguments: #"{"name": "alice"}"#)
			#expect(Bool(false), "Expected throw on missing field")
		} catch let error as ToolError {
			#expect(error.localizedDescription.contains("Invalid parameter"))
		} catch {
			#expect(Bool(false), "Unexpected error type: \(error)")
		}
	}

	@Test("typed tool with optional fields accepts partial JSON")
	func typedToolOptionalFields() async {
		struct Args: Codable { let name: String; let nickname: String? }
		let registry = makeRegistry()

		try? await registry.register(
			ToolEntry.typed(name: "user", toolset: "user", argsType: Args.self) { args in
				"\(args.name) \(args.nickname ?? "")"
			}
		)

		do {
			let result = try await registry.call("user", arguments: #"{"name": "alice"}"#)
			#expect(result == "alice ")
		} catch {
			#expect(Bool(false), "Unexpected error: \(error)")
		}
	}

	@Test("typed tool with empty args throws")
	func typedToolEmptyArgs() async {
		struct Args: Codable { let value: String }
		let registry = makeRegistry()

		try? await registry.register(
			ToolEntry.typed(name: "echo", toolset: "debug", argsType: Args.self) { _ in "ok" }
		)

		do {
			_ = try await registry.call("echo", arguments: "")
			#expect(Bool(false), "Expected throw on empty args")
		} catch let error as ToolError {
			#expect(error.localizedDescription.contains("Arguments required"))
		} catch {
			#expect(Bool(false), "Unexpected error type: \(error)")
		}
	}

	@Test("typed tool handler throws propagate correctly")
	func typedToolHandlerThrows() async {
		struct Args: Codable { let cmd: String }
		let registry = makeRegistry()

		try? await registry.register(
			ToolEntry.typed(name: "danger", toolset: "sys", argsType: Args.self) { args in
				if args.cmd == "boom" { throw NSError(domain: "tool", code: 1) }
				return "ok"
			}
		)

		do {
			_ = try await registry.call("danger", arguments: #"{"cmd": "boom"}"#)
			#expect(Bool(false), "Expected throw")
		} catch let error as ToolError {
			#expect(error.localizedDescription.contains("Tool execution failed"))
		} catch {
			#expect(Bool(false), "Unexpected error type: \(error)")
		}
	}
}
