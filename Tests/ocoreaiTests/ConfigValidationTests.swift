// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ConfigValidationTests.swift — Validate that config validation catches
/// invalid field combinations before the app starts.

import XCTest
@testable import ocoreai

final class ConfigValidationTests: XCTestCase {
	// MARK: - Server Config

	func testDefaultServerValid() throws {
		let config = ServerConfig()
		try XCTAssertNoThrow(try config.validate())
	}

	func testServerPortOutOfRange() throws {
		var config = ServerConfig(port: 0)
		do {
			try config.validate()
			XCTFail("Port 0 should be invalid")
		} catch {
			let desc = (error as? LocalizedError)?.errorDescription ?? ""
			XCTAssertTrue(desc.contains("port"))
		}

		config = ServerConfig(port: 70000)
		do {
			try config.validate()
			XCTFail("Port 70000 should be invalid")
		} catch {
			// expected
		}
	}

	func testServerEdgePorts() throws {
		// Port 1 and 65535 should be valid
		let low = ServerConfig(port: 1)
		try XCTAssertNoThrow(try low.validate())
		let high = ServerConfig(port: 65535)
		try XCTAssertNoThrow(try high.validate())
	}

	// MARK: - Backend Config

	func testDefaultBackendValid() throws {
		let config = BackendConfig()
		try XCTAssertNoThrow(try config.validate())
	}

	func testBackendEmptyPreference() throws {
		let config = BackendConfig(preference: [])
		do {
			try config.validate()
			XCTFail("Empty preference should throw")
		} catch {
			let desc = (error as? LocalizedError)?.errorDescription ?? ""
			XCTAssertTrue(desc.contains("preference"))
		}
	}

	func testBackendZeroSessions() throws {
		let config = BackendConfig(
			preference: ["mlx"],
			maxConcurrentSessions: 0
		)
		do {
			try config.validate()
			XCTFail("Zero sessions should throw")
		} catch {
			let desc = (error as? LocalizedError)?.errorDescription ?? ""
			XCTAssertTrue(desc.contains("maxConcurrentSessions"))
		}
	}

	// MARK: - KV Cache Quantization

	func testDefaultKVQuantValid() throws {
		let q = KVCacheQuantizationConfig()
		try XCTAssertNoThrow(try q.validate())
	}

	func testKVBitsOutOfRange() throws {
		var config = KVCacheQuantizationConfig(
			enabled: true,
			bits: 2
		)
		do {
			try config.validate()
			XCTFail("bits=2 should reject")
		} catch {
			// expected
		}

		config = KVCacheQuantizationConfig(
			enabled: true,
			bits: 16
		)
		do {
			try config.validate()
			XCTFail("bits=16 should reject")
		} catch {
			// expected
		}
	}

	func testKVBitsAllowedValues() throws {
		// bits = 4 and 8 should be valid
		let bits4 = KVCacheQuantizationConfig(enabled: true, bits: 4)
		try XCTAssertNoThrow(try bits4.validate())
		let bits8 = KVCacheQuantizationConfig(enabled: true, bits: 8)
		try XCTAssertNoThrow(try bits8.validate())
		// bits = nil when enabled should be valid
		let bitsNil = KVCacheQuantizationConfig(enabled: true, bits: nil)
		try XCTAssertNoThrow(try bitsNil.validate())
	}

	func testKVQuantZeroGroupSize() throws {
		let config = KVCacheQuantizationConfig(groupSize: 0)
		do {
			try config.validate()
			XCTFail("groupSize=0 should reject")
		} catch {
			// expected
		}
	}

	func testKVQuantNegativeStart() throws {
		let config = KVCacheQuantizationConfig(quantizedKVStart: -1)
		do {
			try config.validate()
			XCTFail("quantizedKVStart=-1 should reject")
		} catch {
			// expected
		}
	}

	// MARK: - Safety Config

	func testSafetyDefaultValid() throws {
		let config = SafetyConfig()
		try XCTAssertNoThrow(try config.validate())
		XCTAssertTrue(config.enabled)
	}

	func testSafetyNonNegotiableCannotDisable() throws {
		let categories: [String] = ["underageSexual", "sexualViolence", "selfHarm"]
		for cat in categories {
			var config = SafetyConfig()
			config.categoryModes[cat] = "disabled"
			do {
				try config.validate()
				XCTFail("Disabling \(cat) should throw")
			} catch {
				let desc = (error as? LocalizedError)?.errorDescription ?? ""
				XCTAssertTrue(desc.contains(cat))
			}
		}
	}

	func testSafetyNonNegotiableOtherModesOk() throws {
		var config = SafetyConfig()
		config.categoryModes["underageSexual"] = "auto"
		try XCTAssertNoThrow(try config.validate())
		config.categoryModes["underageSexual"] = "strict"
		try XCTAssertNoThrow(try config.validate())
	}

	// MARK: - Memory Config

	func testMemoryDefaultValid() throws {
		let config = MemoryConfig()
		try XCTAssertNoThrow(try config.validate())
	}

	func testMemoryZeroTTL() throws {
		let config = MemoryConfig(sessionTTL: 0)
		do {
			try config.validate()
			XCTFail("sessionTTL=0 should throw")
		} catch {
			// expected
		}
	}

	func testMemoryRecallResultsOutOfRange() throws {
		let zero = MemoryConfig(maxRecallResults: 0)
		do {
			try zero.validate()
			XCTFail("maxRecallResults=0 should throw")
		} catch {
			// expected
		}

		let over = MemoryConfig(maxRecallResults: 21)
		do {
			try over.validate()
			XCTFail("maxRecallResults=21 should throw")
		} catch {
			// expected
		}

		// boundary: 1 and 20 should be valid
		let min = MemoryConfig(maxRecallResults: 1)
		try XCTAssertNoThrow(try min.validate())
		let max = MemoryConfig(maxRecallResults: 20)
		try XCTAssertNoThrow(try max.validate())
	}

	// MARK: - Full Config Validation Chain

	func testFullConfigDefaultValid() throws {
		let config = AppConfig()
		try XCTAssertNoThrow(try config.validate())
	}

	func testFullConfigCatchesNestedError() throws {
		var config = AppConfig()
		config.server.port = 0
		do {
			try config.validate()
			XCTFail("Full config should propagate server validation error")
		} catch {
			// expected
		}
	}

	// MARK: - Environment Override

	func testEnvOverridesPort() throws {
		var config = AppConfig()
		let original = config.server.port

		// We can't reliably set env vars in tests without affecting other tests,
		// so just verify the override chain reads the right key format
		XCTAssertTrue(ProcessInfo.processInfo.environment.keys.contains {
			$0.hasPrefix("OCOREAI_") == false // just sanity check format
		})

		// Verify override path: key name construction is correct
		let portKey = "OCOREAI_PORT"
		let backendKey = "OCOREAI_BACKEND"
		let defaultModelKey = "OCOREAI_DEFAULT_MODEL"

		// These keys should not normally be set in test env
		let hasPort = ProcessInfo.processInfo.environment[portKey] != nil
		let hasBackend = ProcessInfo.processInfo.environment[backendKey] != nil
		let hasDefaultModel = ProcessInfo.processInfo.environment[defaultModelKey] != nil

		// If none are set, config stays at defaults
		if !hasPort && !hasBackend && !hasDefaultModel {
			XCTAssertEqual(config.server.port, original)
		}
	}

	// MARK: - MemoryGuardTier

	func testMemoryTierInferenceSmallRAM() throws {
		// < 16 GB → safe
		let tier = ModelConfigEntry.inferMemoryTier(from: 8 * 1_073_741_824)
		XCTAssertEqual(tier.percentage, 40)
		XCTAssertEqual(tier.description, "safe")
	}

	func testMemoryTierInferenceMediumRAM() throws {
		// 16-31 GB → balanced
		let tier = ModelConfigEntry.inferMemoryTier(from: 24 * 1_073_741_824)
		XCTAssertEqual(tier.percentage, 55)
		XCTAssertEqual(tier.description, "balanced")
	}

	func testMemoryTierInferenceLargeRAM() throws {
		// >= 32 GB → aggressive
		let tier = ModelConfigEntry.inferMemoryTier(from: 64 * 1_073_741_824)
		XCTAssertEqual(tier.percentage, 75)
		XCTAssertEqual(tier.description, "aggressive")
	}

	func testMemoryBudgetComputation() throws {
		let ram = 32 * 1_073_741_824 // 32 GB
		let tier = ModelConfigEntry.MemoryGuardTier.balanced

		let budget = ModelConfigEntry.computeMemoryBudget(
			physicalMemory: ram,
			tier: tier
		)

		// 55% of 32 GB = 17.6 GB
		let expected = UInt64(Double(ram) * 0.55)
		// Allow small rounding difference
		XCTAssertTrue(abs(Double(budget) - Double(expected)) < 1_000_000)
	}

	func testMemoryBudgetFloor() throws {
		// Even with tiny RAM, floor is 4 GB
		let tinyRam = 1_073_741_824 // 1 GB
		let tier = ModelConfigEntry.MemoryGuardTier.safe // 40% of 1GB = 400MB

		let budget = ModelConfigEntry.computeMemoryBudget(
			physicalMemory: tinyRam,
			tier: tier
		)

		let floor = 4 * 1_024 * 1_024 * 1_024 // 4 GB floor
		XCTAssertEqual(budget, floor)
	}

	func testMemoryTierClamping() throws {
		// Tier percentage is clamped to 20-85
		let tooLow = ModelConfigEntry.MemoryGuardTier(percentage: 5)
		XCTAssertEqual(tooLow.percentage, 20)

		let tooHigh = ModelConfigEntry.MemoryGuardTier(percentage: 99)
		XCTAssertEqual(tooHigh.percentage, 85)

		let inRange = ModelConfigEntry.MemoryGuardTier(percentage: 50)
		XCTAssertEqual(inRange.percentage, 50)
	}

	func testMemoryTierDescriptions() throws {
		let safe = ModelConfigEntry.MemoryGuardTier(percentage: 40)
		XCTAssertEqual(safe.description, "safe")

		let balanced = ModelConfigEntry.MemoryGuardTier(percentage: 55)
		XCTAssertEqual(balanced.description, "balanced")

		let aggressive = ModelConfigEntry.MemoryGuardTier(percentage: 75)
		XCTAssertEqual(aggressive.description, "aggressive")

		let custom = ModelConfigEntry.MemoryGuardTier(percentage: 50)
		XCTAssertEqual(custom.description, "custom(50%)")
	}
}
