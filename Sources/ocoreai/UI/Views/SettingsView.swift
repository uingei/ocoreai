// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Settings view — full panel: server, performance, KVCache, logs, app, about
/// omlx pattern: ViewModel + .task{} + Section/TextRow — cross-platform

import SwiftUI

struct SettingsView: View {
	@State private var settingsState: SettingsState
	@Environment(\.ocoreaiTheme) private var theme

	// Hub token local bindings — SecureField needs non-optional String
	@State private var _hfTokenField: String = ""
	@State private var _msTokenField: String = ""

	init() {
		_settingsState = State(initialValue: SettingsState())
		// Initialize token fields from persisted values — prevents empty→filled flicker
		_hfTokenField = SettingsStore.shared.hfToken ?? ""
		_msTokenField = SettingsStore.shared.modelScopeToken ?? ""
	}

	var body: some View {
		Form {
			serverSection
			modelSection
			hubTokenSection
			performanceSection
			kvCacheSection
			logsSection
			appSection
			aboutSection
			dangerSection
		}
		.formStyle(.grouped)
		.navigationTitle(StringKey.settingsTitle.l)
		.accessibilityLabel(StringKey.settingsTitle.l)
		.task {
			// Non-blocking: listModels() no longer runs on MainActor, so this yields control back to UI
			await settingsState.load()
		}
	}

	// MARK: - Server Connection

	private var serverSection: some View {
		Section {
			TextField(StringKey.serverAddress.l, text: $settingsState.serverHost)
				.accessibilityLabel(StringKey.serverAddress.l)
			TextField(StringKey.port.l, text: $settingsState.portField)
				.accessibilityLabel(StringKey.port.l)
			Button { Task { await settingsState.verifyConnection() } } label: {
				HStack {
					Spacer()
					if settingsState.verifying {
						ProgressView()
					} else {
						Text(StringKey.verifyConnection.l)
					}
					Spacer()
				}
			}
			.disabled(settingsState.verifying)
			.accessibilityLabel(StringKey.verifyConnection.l)
			.accessibilityHint(StringKey.ensureBackend.l)
			if settingsState.connected {
				Text(StringKey.connected.l).font(.ocoreaiText(12))
					.foregroundStyle(theme.greenDot)
			}
		} header: { Text(StringKey.serverSection.l) }
			footer: { Text(StringKey.ensureBackend.l) }
	}

	// MARK: - Model Selection

	private var modelSection: some View {
		Section {
			Picker(StringKey.modelsLoaded.l, selection: $settingsState.selectedModelID) {
				ForEach(settingsState.modelOptions, id: \.self) { m in
					Text(m).tag(m)
				}
			}
			.accessibilityLabel(StringKey.modelsLoaded.l)
		}
	}

	// MARK: - Hub Tokens

	private var hubTokenSection: some View {
		Section {
			VStack(alignment: .leading, spacing: 4) {
				HStack {
					Text(StringKey.hubHuggingFace.l)
						.font(.ocoreaiText(15))
					Spacer()
					if settingsState.hfTokenMasked.isEmpty {
						Text(StringKey.notConfigured.l)
							.font(.ocoreaiText(12))
							.foregroundStyle(.secondary)
					} else {
						Text(settingsState.hfTokenMasked)
							.font(.ocoreaiText(12))
							.foregroundStyle(theme.greenDot)
					}
				}
				SecureField(StringKey.enterTokenPlaceholder.l, text: $_hfTokenField)
					.onChange(of: _hfTokenField) { _, newValue in
						settingsState.hfToken = (newValue.isEmpty ? nil : newValue)
					}
			}

			VStack(alignment: .leading, spacing: 4) {
				HStack {
					Text(StringKey.hubModelScope.l)
						.font(.ocoreaiText(15))
					Spacer()
					if settingsState.modelScopeTokenMasked.isEmpty {
						Text(StringKey.notConfigured.l)
							.font(.ocoreaiText(12))
							.foregroundStyle(.secondary)
					} else {
						Text(settingsState.modelScopeTokenMasked)
							.font(.ocoreaiText(12))
							.foregroundStyle(theme.greenDot)
					}
				}
				SecureField(StringKey.enterTokenPlaceholder.l, text: $_msTokenField)
					.onChange(of: _msTokenField) { _, newValue in
						settingsState.modelScopeToken = (newValue.isEmpty ? nil : newValue)
					}
			}
		} header: {
			Text(StringKey.hubTokensTitle.l)
		} footer: {
			Text(StringKey.hubTokensHint.l)
		}
	}

	private var performanceSection: some View {
		Section {
			stepperLabel(StringKey.pollInterval.l, $settingsState.pollIntervalSec, 1 ... 10,
			             desc: StringKey.pollInterval.l)
			stepperLabel(StringKey.chartWindow.l, $settingsState.chartWindowSec, 30 ... 600,
			             desc: StringKey.chartWindowHint.l)
		} header: { Text(StringKey.performanceSection.l) }
	}

	// MARK: - KV Cache

	private var kvCacheSection: some View {
		Section {
			Toggle(StringKey.kvQuantToggle.l, isOn: $settingsState.kvQuantizationEnabled)
				.accessibilityLabel(StringKey.kvQuantToggle.l)
			if settingsState.kvQuantizationEnabled {
				Picker(StringKey.kvQuantBits.l, selection: $settingsState.kvQuantizationBits) {
					Text("4").tag(4)
					Text("8").tag(8)
				}
				.accessibilityLabel(StringKey.kvQuantBits.l)
				Text(StringKey.kvBudget.l)
					.font(.ocoreaiText(12)).foregroundStyle(.secondary)
				Slider(value: $settingsState.kvCacheBudgetGB, in: 0.5 ... 128,
				       step: 0.5)
				{
					Text(String(format: "%.1f GB", settingsState.kvCacheBudgetGB))
						.font(.ocoreaiMono(11)).foregroundStyle(.secondary)
				}
				.accessibilityLabel(StringKey.kvBudget.l)
			}
		} header: { Text(StringKey.kvCacheSection.l) }
			footer: { Text(StringKey.kvQuantToggleHint.l) }
	}

	// MARK: - Logs & Profiling

	private var logsSection: some View {
		Section {
			Picker(StringKey.logLevel.l, selection: $settingsState.logLevel) {
				ForEach(LogLevelRaw.allCases, id: \.self) {
					Text($0.displayName).tag($0)
				}
			}
			.tint(settingsState.logLevel.color)
			Toggle(StringKey.profileToggle.l, isOn: $settingsState.profileEnabled)
		} header: { Text(StringKey.logsSection.l) }
			footer: { Text(StringKey.profileToggleHint.l) }
	}

	// MARK: - App Preferences

	private var appSection: some View {
		Section {
			Picker(StringKey.localePicker.l, selection: $settingsState.appLocale) {
				ForEach(OCALocale.allCases, id: \.self) {
					Text($0.displayName).tag($0)
				}
			}
			Picker(StringKey.themeMode.l, selection: $settingsState.appThemeMode) {
				ForEach(ThemeModeRaw.allCases, id: \.self) {
					Label($0.displayName, systemImage: $0.systemName).tag($0)
				}
			}
		} header: { Text(StringKey.appSection.l) }
	}

	// MARK: - About

	private var aboutSection: some View {
		Section {
			VStack(spacing: 4) {
				Label(StringKey.aboutTitle.l, systemImage: "brain.fill")
					.font(.title2.bold())
				Text(StringKey.version.l)
					.font(.subheadline).foregroundStyle(.secondary)
				Text(StringKey.aboutVersion.l)
					.font(.caption).foregroundStyle(.secondary)
			}
			.frame(maxWidth: .infinity).padding(.vertical, 4)
		} header: { Text(StringKey.aboutSection.l) }
	}

	// MARK: - Danger Zone

	@State private var showingResetConfirmation = false

	private var dangerSection: some View {
		Section {
			Button(role: .destructive) { showingResetConfirmation = true } label: {
				Text(StringKey.resetSettings.l).frame(maxWidth: .infinity)
			}
			.tint(theme.redDot)
			.confirmationDialog(StringKey.resetConfirm.l, isPresented: $showingResetConfirmation) {
				Button(StringKey.resetSettings.l, role: .destructive) {
					settingsState.resetToDefaults()
				}
			}
		}
	}

	// MARK: - Helpers

	private func stepperLabel(_ title: String, _ value: Binding<Int>, _ range: ClosedRange<Int>,
	                          desc: String) -> some View
	{
		VStack(alignment: .leading, spacing: 4) {
			HStack {
				Text(title).font(.ocoreaiText(15))
				Spacer()
				Stepper("\(value.wrappedValue)s", value: value, in: range)
			}
			Text(desc).font(.ocoreaiText(12)).foregroundStyle(.secondary)
				.padding(.horizontal)
		}
	}
}
