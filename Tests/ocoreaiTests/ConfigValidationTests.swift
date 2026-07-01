// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ConfigValidationTests.swift — Validate that config validation catches
/// invalid field combinations before the app starts.

import Testing
import Foundation
@testable import ocoreai

@Suite("ConfigValidation")
struct ConfigValidationTests {
	// MARK: - Server Config

	@Test("defaultServerValid")
	func defaultServerValid() throws {
		let config = ServerConfig()
		try config.validate()
	}

	@Test("serverPortOutOfRange")
	func serverPortOutOfRange() throws {
		do {
			try ServerConfig(port: 0).validate()
			#expect(false, "Port 0 should be invalid")
		} catch {
			let desc = (error as? LocalizedError)?.errorDescription ?? ""
			#expect(desc.contains("port") || !desc.isEmpty)
		}

		do {
			try ServerConfig(port: 70000).validate()
			#expect(false, "Port 70000 should be invalid")
		} catch {
			let desc = (error as? LocalizedError)?.errorDescription ?? ""
			#expect(desc.contains("port") || !desc.isEmpty)
		}
	}

	@Test("serverEdgePorts")
	func serverEdgePorts() throws {
		try ServerConfig(port: 1).validate()
		try ServerConfig(port: 65535).validate()
	}

	// MARK: - Backend Config

	@Test("defaultBackendValid")
	func defaultBackendValid() throws {
		try BackendConfig().validate()
	}

	@Test("backendEmptyPreference")
	func backendEmptyPreference() throws {
		do {
			try BackendConfig(preference: []).validate()
			#expect(false, "Empty preference should be invalid")
		} catch {
			let desc = (error as? LocalizedError)?.errorDescription ?? ""
			#expect(desc.contains("preference") || !desc.isEmpty)
		}
	}

	@Test("backendZeroSessions")
	func backendZeroSessions() throws {
		do {
			try BackendConfig(preference: ["mlx"], maxConcurrentSessions: 0).validate()
			#expect(false, "Zero sessions should be invalid")
		} catch {
			let desc = (error as? LocalizedError)?.errorDescription ?? ""
			#expect(desc.contains("session") || !desc.isEmpty)
		}
	}

	// MARK: - KV Cache Quantization

	@Test("defaultKVQuantValid")
	func defaultKVQuantValid() throws {
		try KVCacheQuantizationConfig().validate()
	}

	@Test("kvBitsOutOfRange")
	func kvBitsOutOfRange() throws {
		do {
			try KVCacheQuantizationConfig(enabled: true, bits: 2).validate()
			#expect(false)
		} catch {
			_ = error
		}
		do {
			try KVCacheQuantizationConfig(enabled: true, bits: 16).validate()
			#expect(false)
		} catch {
			_ = error
		}
	}

	@Test("kvBitsAllowedValues")
	func kvBitsAllowedValues() throws {
		try KVCacheQuantizationConfig(enabled: true, bits: 4).validate()
		try KVCacheQuantizationConfig(enabled: true, bits: 8).validate()
		try KVCacheQuantizationConfig(enabled: true, bits: nil).validate()
	}

	@Test("kvQuantZeroGroupSize")
	func kvQuantZeroGroupSize() throws {
		do {
			try KVCacheQuantizationConfig(groupSize: 0).validate()
			#expect(false)
		} catch {
			_ = error
		}
	}

	@Test("kvQuantNegativeStart")
	func kvQuantNegativeStart() throws {
		do {
			try KVCacheQuantizationConfig(quantizedKVStart: -1).validate()
			#expect(false)
		} catch {
			_ = error
		}
	}

	// MARK: - Safety Config

	@Test("safetyDefaultValid")
	func safetyDefaultValid() throws {
		let config = SafetyConfig()
		try config.validate()
		#expect(config.enabled == true)
	}

	@Test("safetyNonNegotiableCannotDisable")
	func safetyNonNegotiableCannotDisable() throws {
		for cat in ["underageSexual", "sexualViolence", "selfHarm"] {
			var config = SafetyConfig()
			config.categoryModes[cat] = "disabled"
			do {
				try config.validate()
				#expect(false, "\(cat) disabled should fail")
			} catch {
				_ = error
			}
		}
	}

	@Test("safetyNonNegotiableOtherModesOk")
	func safetyNonNegotiableOtherModesOk() throws {
		var config = SafetyConfig()
		config.categoryModes["underageSexual"] = "auto"
		try config.validate()
		config.categoryModes["underageSexual"] = "strict"
		try config.validate()
	}

	// MARK: - Memory Config

	@Test("memoryDefaultValid")
	func memoryDefaultValid() throws {
		try MemoryConfig().validate()
	}

	@Test("memoryZeroTTL")
	func memoryZeroTTL() throws {
		do {
			try MemoryConfig(sessionTTL: 0).validate()
			#expect(false)
		} catch {
			_ = error
		}
	}

	@Test("memoryRecallResultsOutOfRange")
	func memoryRecallResultsOutOfRange() throws {
		do { try MemoryConfig(maxRecallResults: 0).validate(); #expect(false) } catch { _ = error }
		do { try MemoryConfig(maxRecallResults: 21).validate(); #expect(false) } catch { _ = error }
		try MemoryConfig(maxRecallResults: 1).validate()
		try MemoryConfig(maxRecallResults: 20).validate()
	}

	// MARK: - Full Config Validation Chain

	@Test("fullConfigDefaultValid")
	func fullConfigDefaultValid() throws {
		try AppConfig().validate()
	}

	@Test("fullConfigCatchesNestedError")
	func fullConfigCatchesNestedError() throws {
		var config = AppConfig()
		config.server.port = 0
		do {
			try config.validate()
			#expect(false)
		} catch {
			_ = error
		}
	}

	// MARK: - MemoryGuardTier

	@Test("memoryTierInferenceSmallRAM")
	func memoryTierInferenceSmallRAM() throws {
		let tier = ModelConfigEntry.inferMemoryTier(from: 8 * 1_073_741_824)
		#expect(abs(tier.percentage - 40) < 1)
		#expect(tier.description == "safe")
	}

	@Test("memoryTierInferenceMediumRAM")
	func memoryTierInferenceMediumRAM() throws {
		let tier = ModelConfigEntry.inferMemoryTier(from: 24 * 1_073_741_824)
		#expect(abs(tier.percentage - 55) < 1)
		#expect(tier.description == "balanced")
	}

	@Test("memoryTierInferenceLargeRAM")
	func memoryTierInferenceLargeRAM() throws {
		let tier = ModelConfigEntry.inferMemoryTier(from: 64 * 1_073_741_824)
		#expect(abs(tier.percentage - 75) < 1)
		#expect(tier.description == "aggressive")
	}

	@Test("memoryBudgetComputation")
	func memoryBudgetComputation() throws {
		let ram: UInt64 = 32 * 1_073_741_824
		let tier = ModelConfigEntry.MemoryGuardTier.balanced
		let budget = ModelConfigEntry.computeMemoryBudget(physicalMemory: ram, tier: tier)
		let expected = UInt64(Double(ram) * 0.55)
		let diff = budget > expected ? Decimal(budget - expected) : Decimal(expected - budget)
		#expect(diff < Decimal(1_000_000))
	}

	@Test("memoryBudgetFloor")
	func memoryBudgetFloor() throws {
		let tinyRam: UInt64 = 1_073_741_824
		let tier = ModelConfigEntry.MemoryGuardTier.safe
		let budget = ModelConfigEntry.computeMemoryBudget(physicalMemory: tinyRam, tier: tier)
		let floor: UInt64 = 4 * 1_024 * 1_024 * 1_024
		#expect(budget == floor)
	}

	@Test("memoryTierClamping")
	func memoryTierClamping() throws {
		let tooLow = ModelConfigEntry.MemoryGuardTier(percentage: 5)
		#expect(tooLow.percentage == 20)
		let tooHigh = ModelConfigEntry.MemoryGuardTier(percentage: 99)
		#expect(tooHigh.percentage == 85)
		let inRange = ModelConfigEntry.MemoryGuardTier(percentage: 50)
		#expect(inRange.percentage == 50)
	}

	@Test("memoryTierDescriptions")
	func memoryTierDescriptions() throws {
		#expect(ModelConfigEntry.MemoryGuardTier(percentage: 40).description == "safe")
		#expect(ModelConfigEntry.MemoryGuardTier(percentage: 55).description == "balanced")
		#expect(ModelConfigEntry.MemoryGuardTier(percentage: 75).description == "aggressive")
		#expect(ModelConfigEntry.MemoryGuardTier(percentage: 50).description == "custom(50%)")
	}
}
