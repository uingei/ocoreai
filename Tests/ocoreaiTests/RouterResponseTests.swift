// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// RouterResponseTests.swift — Verify that router response types encode
/// to valid JSON with correct field names and structure.

import XCTest
@testable import ocoreai

final class RouterResponseTests: XCTestCase {
	private let encoder: JSONEncoder = {
		let e = JSONEncoder()
		e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return e
	}()

	// MARK: - HealthResponse

	func testHealthResponseEncoding() throws {
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
		let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

		XCTAssertEqual(json?["status"] as? String, "ok")
		XCTAssertEqual(json?["timestamp"] as? Int64, 1_700_000_000)

		let eSummary = json?["engineSummary"] as? [String: Any]
		XCTAssertNotNil(eSummary)
		XCTAssertEqual(eSummary?["loadedModels"] as? Int, 2)
		XCTAssertEqual(eSummary?["activeSessions"] as? Int, 3)
		XCTAssertEqual(eSummary?["gpuCacheGB"] as? Double, 4.2)
	}

	// MARK: - ModelListResponse

	func testModelListEncoding() throws {
		let models = [
			ModelObject(id: "model-x"),
			ModelObject(id: "model-y"),
		]
		let response = ModelListResponse(data: models)

		let data = try encoder.encode(response)
		let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

		XCTAssertEqual(json?["object"] as? String, "list")

		let dataArray = json?["data"] as? [[String: Any]]
		XCTAssertEqual(dataArray?.count, 2)
		XCTAssertEqual(dataArray?[0]["id"] as? String, "model-x")
		XCTAssertEqual(dataArray?[0]["object"] as? String, "model")
		XCTAssertEqual(dataArray?[0]["ownedBy"] as? String, "ocoreai")
	}

	// MARK: - CountTokensResponse

	func testCountTokensEncoding() throws {
		let response = CountTokensResponse(
			model: "test-model",
			tokenCount: 42
		)

		let data = try encoder.encode(response)
		let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

		XCTAssertEqual(json?["model"] as? String, "test-model")
		// CodingKey maps tokenCount → prompt_tokens
		XCTAssertEqual(json?["prompt_tokens"] as? Int, 42)
	}

	// MARK: - SessionDeleteResponse

	func testSessionDeleteEncoding() throws {
		let response = SessionDeleteResponse(deleted: true, id: 42)

		let data = try encoder.encode(response)
		let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

		XCTAssertEqual(json?["deleted"] as? Bool, true)
		XCTAssertEqual(json?["id"] as? Int64, 42)
	}


}
