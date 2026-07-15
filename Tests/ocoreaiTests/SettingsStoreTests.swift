// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SettingsStoreTests — UserDefaults persistence, clamping, token priority.
///
/// Creates a fresh UserDefaults suite per test to avoid cross-test pollution.

import Foundation
import Testing
@testable import ocoreai

@MainActor
@Suite("SettingsStore")
struct SettingsStoreTests {

	// MARK: - Helper

	/// Create an isolated SettingsStore for each test.
	private func store() -> SettingsStore {
		SettingsStore(defaults: freshDefaults())
	}

	private func freshDefaults() -> UserDefaults {
		let id = UUID().uuidString
		let suite = UserDefaults(suiteName: "test.ocoreai.\(id)")!
		return suite
	}

	// MARK: - Server

	@Test("serverHost defaults to 127.0.0.1")
	func serverHostDefault() {
		#expect(store().serverHost == "127.0.0.1")
	}

	@Test("serverHost can be set")
	func serverHostSet() {
		let s = store()
		s.serverHost = "192.168.1.100"
		#expect(s.serverHost == "192.168.1.100")
	}

	@Test("serverPort defaults to 8080")
	func serverPortDefault() {
		#expect(store().serverPort == 8080)
	}

	@Test("serverPort can be set")
	func serverPortSet() {
		let s = store()
		s.serverPort = 9090
		#expect(s.serverPort == 9090)
	}

	// MARK: - Performance clamping

	@Test("pollIntervalSec clamps to 1-10")
	func pollIntervalClamping() {
		let s = store()
		s.pollIntervalSec = 0
		#expect(s.pollIntervalSec == 1)

		s.pollIntervalSec = 5
		#expect(s.pollIntervalSec == 5)

		s.pollIntervalSec = 100
		#expect(s.pollIntervalSec == 10)
	}

	@Test("chartWindowSec clamps to 30-600")
	func chartWindowClamping() {
		let s = store()
		s.chartWindowSec = 0
		#expect(s.chartWindowSec == 30)

		s.chartWindowSec = 150
		#expect(s.chartWindowSec == 150)

		s.chartWindowSec = 9999
		#expect(s.chartWindowSec == 600)
	}

	// MARK: - KV Cache

	@Test("kvQuantizationBits only allows 4 or 8")
	func kvQuantBits() {
		let s = store()
		s.kvQuantizationBits = 4
		#expect(s.kvQuantizationBits == 4)

		s.kvQuantizationBits = 8
		#expect(s.kvQuantizationBits == 8)

		// Invalid values default to 4
		s.kvQuantizationBits = 2
		#expect(s.kvQuantizationBits == 4)

		s.kvQuantizationBits = 16
		#expect(s.kvQuantizationBits == 4)
	}

	@Test("kvCacheBudgetGB clamps to 0.5-128")
	func kvCacheBudgetClamping() {
		let s = store()
		s.kvCacheBudgetGB = 0.1
		#expect(s.kvCacheBudgetGB == 0.5)

		s.kvCacheBudgetGB = 64.0
		#expect(s.kvCacheBudgetGB == 64.0)

		s.kvCacheBudgetGB = 256.0
		#expect(s.kvCacheBudgetGB == 128.0)
	}

	// MARK: - Hub token masking

	@Test("hfTokenMasked masks token correctly")
	func hfTokenMasked() {
		let s = store()
		// Write directly via the accessor — no env var so it falls through to defaults
		s.hfToken = "huggingface_abc123xyz"

		// Token should be masked
		let masked = s.hfTokenMasked
		#expect(masked.starts(with: "hu"))
		#expect(masked.hasSuffix("yz"))
		#expect(masked.contains("••••"))
	}

	@Test("hfTokenMasked empty for short token")
	func hfTokenMaskedShort() {
		let s = store()
		s.hfToken = "ab"
		let masked = s.hfTokenMasked
		#expect(masked.isEmpty)
	}

	// MARK: - Reset

	@Test("resetToDefaults clears all keys")
	func resetToDefaults() {
		let s = store()
		// Set some values
		s.serverHost = "10.0.0.1"
		s.serverPort = 9999
		s.pollIntervalSec = 8

		// Reset
		s.resetToDefaults()

		// Should be back to defaults
		#expect(s.serverHost == "127.0.0.1")
		#expect(s.serverPort == 8080)
		#expect(s.pollIntervalSec >= 1 && s.pollIntervalSec <= 10)
	}
}
