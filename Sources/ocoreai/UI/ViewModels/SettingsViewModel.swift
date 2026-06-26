// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Settings ViewModel — bridges SettingsStore (UserDefaults persistence)
/// with transient UI state (verify status, model list).
///
/// @Observable pattern (Swift 5.9+): property-level change tracking.
///
/// Architecture:
///   SettingsView  ←  SettingsState  ←  SettingsStore  ←  UserDefaults
///   (read-only)    (bridge + state)  (typed accessor)

import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class SettingsState {
	// MARK: - Server Connection (persisted via SettingsStore)

	var serverHost: String {
		didSet { SettingsStore.shared.serverHost = serverHost }
	}

	var serverPort: Int {
		didSet { SettingsStore.shared.serverPort = serverPort }
	}

	var portField: String {
		get { String(serverPort) }
		set {
			if let p = Int(newValue), p > 0, p < 65536 {
				serverPort = p
			}
		}
	}

	// MARK: - Performance Settings

	var pollIntervalSec: Int {
		didSet { SettingsStore.shared.pollIntervalSec = pollIntervalSec }
	}

	var chartWindowSec: Int {
		didSet { SettingsStore.shared.chartWindowSec = chartWindowSec }
	}

	// MARK: - KV Cache Settings

	var kvQuantizationEnabled: Bool {
		didSet { SettingsStore.shared.kvQuantizationEnabled = kvQuantizationEnabled }
	}

	var kvQuantizationBits: Int {
		didSet { SettingsStore.shared.kvQuantizationBits = kvQuantizationBits }
	}

	var kvCacheBudgetGB: Double {
		didSet { SettingsStore.shared.kvCacheBudgetGB = kvCacheBudgetGB }
	}

	// MARK: - Logs & Profiling

	var logLevel: LogLevelRaw {
		didSet { SettingsStore.shared.logLevel = logLevel }
	}

	var profileEnabled: Bool {
		didSet { SettingsStore.shared.profileEnabled = profileEnabled }
	}

	// MARK: - App Preferences

	var appLocale: OCALocale {
		didSet { SettingsStore.shared.appLocale = appLocale }
	}

	var appThemeMode: ThemeModeRaw {
		didSet { SettingsStore.shared.appThemeMode = appThemeMode }
	}

	// MARK: - Transient UI State (not persisted)

	var verifying: Bool = false
	var connected: Bool = false
	var verifyMessage: String?
	var errorMessage: String?

	// Model picker options
	var selectedModelID: String = ""
	var modelOptions: [String] = []

	// MARK: - Undo support

	private var undoSettings: SettingsSnapshot?
	var hasUndo: Bool {
		undoSettings != nil
	}

	// MARK: - Init

	init() {
		// Load from disk — must assign default first for Swift init rules with @Observable macro
		serverHost = SettingsStore.shared.serverHost
		serverPort = SettingsStore.shared.serverPort
		pollIntervalSec = SettingsStore.shared.pollIntervalSec
		chartWindowSec = SettingsStore.shared.chartWindowSec
		kvQuantizationEnabled = SettingsStore.shared.kvQuantizationEnabled
		kvQuantizationBits = SettingsStore.shared.kvQuantizationBits
		kvCacheBudgetGB = SettingsStore.shared.kvCacheBudgetGB
		logLevel = SettingsStore.shared.logLevel
		profileEnabled = SettingsStore.shared.profileEnabled
		appLocale = SettingsStore.shared.appLocale
		appThemeMode = SettingsStore.shared.appThemeMode
	}

	// MARK: - Lifecycle

	/// Load settings on screen appear
	func load() async {
		await loadModels()
	}

	private func loadModels() async {
		guard let pool = OcoreaiEngine.shared.activeEnginePool else {
			modelOptions = [""]
			return
		}
		let entries = await pool.listModels()
		modelOptions = entries.map { $0["id"] ?? "unknown" }
		if modelOptions.isEmpty { modelOptions = [""] }
		if !modelOptions.contains(selectedModelID) {
			selectedModelID = modelOptions.first ?? ""
		}
	}

	/// Check connection via Fast Path (EnginePool ready)
	func verifyConnection() async {
		verifying = true
		verifyMessage = nil
		errorMessage = nil
		let ready = OcoreaiEngine.shared.activeEnginePool != nil
		connected = ready
		verifyMessage = ready ? nil : "Engine not initialized"
		verifying = false
	}

	/// Snapshot current settings, then reset all to defaults.
	func resetToDefaults() {
		undoSettings = SettingsSnapshot(from: self)
		SettingsStore.shared.resetToDefaults()
		// Reload from store
		serverHost = SettingsStore.shared.serverHost
		serverPort = SettingsStore.shared.serverPort
		pollIntervalSec = SettingsStore.shared.pollIntervalSec
		chartWindowSec = SettingsStore.shared.chartWindowSec
		kvQuantizationEnabled = SettingsStore.shared.kvQuantizationEnabled
		kvQuantizationBits = SettingsStore.shared.kvQuantizationBits
		kvCacheBudgetGB = SettingsStore.shared.kvCacheBudgetGB
		logLevel = SettingsStore.shared.logLevel
		profileEnabled = SettingsStore.shared.profileEnabled
		appLocale = SettingsStore.shared.appLocale
		appThemeMode = SettingsStore.shared.appThemeMode
		errorMessage = "Settings reset to defaults"
		// Register undo with AppState for Cmd+Z access
		AppState.shared.undoAction = { [weak self] in self?.undoResetToDefaults() }
	}

	/// Restore from the last snapshot if one exists.
	func undoResetToDefaults() {
		guard let snapshot = undoSettings else { return }
		snapshot.apply(to: self)
		undoSettings = nil
	}
}

// MARK: - Settings Snapshot for undo

extension SettingsState {
	@MainActor
	struct SettingsSnapshot {
		let serverHost: String
		let serverPort: Int
		let pollIntervalSec: Int
		let chartWindowSec: Int
		let kvQuantizationEnabled: Bool
		let kvQuantizationBits: Int
		let kvCacheBudgetGB: Double
		let logLevel: LogLevelRaw
		let profileEnabled: Bool
		let appLocale: OCALocale
		let appThemeMode: ThemeModeRaw

		init(from state: SettingsState) {
			serverHost = state.serverHost
			serverPort = state.serverPort
			pollIntervalSec = state.pollIntervalSec
			chartWindowSec = state.chartWindowSec
			kvQuantizationEnabled = state.kvQuantizationEnabled
			kvQuantizationBits = state.kvQuantizationBits
			kvCacheBudgetGB = state.kvCacheBudgetGB
			logLevel = state.logLevel
			profileEnabled = state.profileEnabled
			appLocale = state.appLocale
			appThemeMode = state.appThemeMode
		}

		func apply(to state: SettingsState) {
			state.serverHost = serverHost
			state.serverPort = serverPort
			state.pollIntervalSec = pollIntervalSec
			state.chartWindowSec = chartWindowSec
			state.kvQuantizationEnabled = kvQuantizationEnabled
			state.kvQuantizationBits = kvQuantizationBits
			state.kvCacheBudgetGB = kvCacheBudgetGB
			state.logLevel = logLevel
			state.profileEnabled = profileEnabled
			state.appLocale = appLocale
			state.appThemeMode = appThemeMode
			// Persist to disk
			SettingsStore.shared.serverHost = serverHost
			SettingsStore.shared.serverPort = serverPort
			SettingsStore.shared.pollIntervalSec = pollIntervalSec
			SettingsStore.shared.chartWindowSec = chartWindowSec
			SettingsStore.shared.kvQuantizationEnabled = kvQuantizationEnabled
			SettingsStore.shared.kvQuantizationBits = kvQuantizationBits
			SettingsStore.shared.kvCacheBudgetGB = kvCacheBudgetGB
			SettingsStore.shared.logLevel = logLevel
			SettingsStore.shared.profileEnabled = profileEnabled
			SettingsStore.shared.appLocale = appLocale
			SettingsStore.shared.appThemeMode = appThemeMode
		}
	}
}
