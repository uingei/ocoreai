// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// RouterResponseTests.swift — Verify that router response types encode
/// to valid JSON with correct field names and structure.

import Testing
import Foundation
@testable import ocoreai

@Suite("RouterResponse")
struct RouterResponseTests {
	private let encoder: JSONEncoder = {
		let e = JSONEncoder()
		e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return e
	}()

	// MARK: - HealthResponse

	@Test("healthResponseEncoding")
	func healthResponseEncoding() throws {
		let summary = EngineSummary(
			loadedModels: 2,
			activeSessions: 3,
			modelIds: ["model-a", "model-b"],
			gpuCacheGB: 4.2,
			specializedModels: 1
		)
		let response = HealthResponse(
			status: "ok",
			timestamp: 1_700_000_000,
			engineSummary: summary
		)

		let data = try encoder.encode(response)
		let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

		#expect(json["status"] as? String == "ok")
		#expect(json["timestamp"] as? Int64 == 1_700_000_000)

		let eSummary = try #require(json["engineSummary"] as? [String: Any])
		#expect(eSummary["loadedModels"] as? Int == 2)
		#expect(eSummary["activeSessions"] as? Int == 3)
		#expect(eSummary["gpuCacheGB"] as? Double == 4.2)
	}

	// MARK: - ModelListResponse

	@Test("modelListEncoding")
	func modelListEncoding() throws {
		let models = [
			ModelObject(id: "model-x"),
			ModelObject(id: "model-y"),
		]
		let response = ModelListResponse(data: models)

		let data = try encoder.encode(response)
		let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

		#expect(json["object"] as? String == "list")

		let dataArray = try #require(json["data"] as? [[String: Any]])
		#expect(dataArray.count == 2)
		#expect(dataArray[0]["id"] as? String == "model-x")
		#expect(dataArray[0]["object"] as? String == "model")
		#expect(dataArray[0]["ownedBy"] as? String == "ocoreai")
	}

	// MARK: - CountTokensResponse

	@Test("countTokensEncoding")
	func countTokensEncoding() throws {
		let response = CountTokensResponse(
			model: "test-model",
			tokenCount: 42
		)

		let data = try encoder.encode(response)
		let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

		#expect(json["model"] as? String == "test-model")
		#expect(json["prompt_tokens"] as? Int == 42)
	}

	// MARK: - SessionDeleteResponse

	@Test("sessionDeleteEncoding")
	func sessionDeleteEncoding() throws {
		let response = SessionDeleteResponse(deleted: true, id: 42)

		let data = try encoder.encode(response)
		let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

		#expect(json["deleted"] as? Bool == true)
		#expect(json["id"] as? Int64 == 42)
	}
}
