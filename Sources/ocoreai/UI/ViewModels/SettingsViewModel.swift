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
import SwiftUI

@MainActor
final class SettingsState: Observable {
    // MARK: - Server Connection (persisted via SettingsStore)

    private var store = SettingsStore.shared

    var serverHost: String {
        get { store.serverHost }
        set { store.serverHost = newValue }
    }

    var serverPort: Int {
        get { store.serverPort }
        set { store.serverPort = newValue }
    }

    var portField: String {
        get { String(serverPort) }
        set {
            if let p = Int(newValue), p > 0 && p < 65536 {
                serverPort = p
            }
        }
    }

    // MARK: - Performance Settings

    var pollIntervalSec: Int {
        get { store.pollIntervalSec }
        set { store.pollIntervalSec = newValue }
    }

    var chartWindowSec: Int {
        get { store.chartWindowSec }
        set { store.chartWindowSec = newValue }
    }

    // MARK: - KV Cache Settings

    var kvQuantizationEnabled: Bool {
        get { store.kvQuantizationEnabled }
        set { store.kvQuantizationEnabled = newValue }
    }

    var kvQuantizationBits: Int {
        get { store.kvQuantizationBits }
        set { store.kvQuantizationBits = newValue }
    }

    var kvCacheBudgetGB: Double {
        get { store.kvCacheBudgetGB }
        set { store.kvCacheBudgetGB = newValue }
    }

    // MARK: - Logs & Profiling

    var logLevel: LogLevelRaw {
        get { store.logLevel }
        set { store.logLevel = newValue }
    }

    var profileEnabled: Bool {
        get { store.profileEnabled }
        set { store.profileEnabled = newValue }
    }

    // MARK: - App Preferences

    var appLocale: OCALocale {
        get { store.appLocale }
        set {
            store.appLocale = newValue
        }
    }

    var appThemeMode: ThemeModeRaw {
        get { store.appThemeMode }
        set { store.appThemeMode = newValue }
    }

    // MARK: - Transient UI State (not persisted)

    var verifying: Bool = false
    var connected: Bool = false
    var verifyMessage: String?
    var errorMessage: String?

    // Model picker options
    var selectedModelID: String = ""
    var modelOptions: [String] = []

    // MARK: - Internal

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    // MARK: - Lifecycle

    /// Load settings on screen appear
    func load() async {
        await loadModels()
    }

    private func loadModels() async {
        let entries = await client.listModels()
        modelOptions = entries.map(\.id)
        if modelOptions.isEmpty { modelOptions = [""] }
        if !modelOptions.contains(selectedModelID) {
            selectedModelID = modelOptions.first ?? ""
        }
    }

    /// Verify server connection
    func verifyConnection() async {
        verifying = true
        verifyMessage = nil
        errorMessage = nil
        let healthy = await client.getHealth()
        connected = healthy
        verifyMessage = healthy ? nil : "Server not responding"
        verifying = false
    }

    /// Reset all settings to defaults
    func resetToDefaults() {
        store.resetToDefaults()
        errorMessage = "Settings reset to defaults"
    }
}
