// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Application entry point — macOS 15+ / iOS 17+ / iPadOS 17+
///
/// Mirrors omlx shell pattern:
///   • @NSApplicationDelegateAdaptor for menubar/launch
///   • NavigationSplitView with sidebar · quick metrics · detail
///   • Sidebar driven by AppState.selectedTab (single source of truth)
///
/// @Observable pattern: AppState is now Observable; accessed as computed property.

import SwiftUI
#if os(iOS)
import UIKit
#endif

@main
struct OcoreaiApp: App {
	#if os(macOS)
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	#endif

	var body: some Scene {
		WindowGroup {
			OcoreaiShellView()
		}
		#if os(macOS)
		.windowStyle(.hiddenTitleBar)
		#endif
	}
}

// MARK: - Root Shell View

struct OcoreaiShellView: View {
	// swiftlint:disable:next identifier_name
	@Environment(\.colorScheme) private var colorScheme
	@State private var theme = OcoreaiTheme.theme(from: .light)

	private var appState: AppState { AppState.shared }

	var body: some View {
		NavigationSplitView {
			SidebarView()
				.navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
		} content: {
			metricsColumn
		} detail: {
			TabDetailView()
		}
		.navigationSplitViewStyle(.balanced)
		// swiftlint:disable:next identifier_name
		.environment(\.ocoreaiTheme, theme)
		.onChange(of: colorScheme) { _, scheme in
			theme = OcoreaiTheme.theme(from: scheme)
		}
		.onAppear {
			// Initial sync in case colorScheme changed before view appeared
			theme = OcoreaiTheme.theme(from: colorScheme)
			appState.initialize()
			appState.bindMetrics()
		}
		.onDisappear {
			appState.shutdown()
		}
		.accessibilityLabel("ocoreai")
	}

	private var metricsColumn: some View {
		OverviewMetricsView()
	}
}

// MARK: - Detail Router

private struct TabDetailView: View {
	private var appState: AppState { AppState.shared }

	var body: some View {
		content
			.navigationTitle(appState.selectedTab.title)
			.accessibilityLabel("\(appState.selectedTab.title) panel")
	}

	@ViewBuilder
	private var content: some View {
		switch appState.selectedTab {
		case .dashboard: DashboardView()
		case .chat:      ChatView()
		case .models:    ModelView()
		case .settings:  SettingsView()
		case .status:    StatusView()
		}
	}

	// MARK: - Empty View for initial state
	struct EmptyContent: View {
		var body: some View {
			ContentUnavailableView(
				"ocoreai",
				systemImage: "brain.cuda",
				description: Text(StringKey.selectPanel.l)
			)
			.accessibilityLabel("No panel selected")
		}
	}
}

// MARK: - Sidebar

private struct SidebarView: View {
	private var appState: AppState { AppState.shared }

	var body: some View {
		List {
			sidebarSection(icon: "server.rack", title: "Server", tabs: AppTab.serverGroup)
			sidebarSection(icon: "brain.head.profile", title: "Models", tabs: AppTab.modelGroup)
			sidebarSection(icon: "gearshape.2", title: "General", tabs: AppTab.generalGroup)
		}
		.listStyle(.sidebar)
		.accessibilityLabel("Navigation")
	}

	private func sidebarSection(icon: String, title: String, tabs: [AppTab]) -> some View {
		Section {
			ForEach(tabs) { tab in
				SidebarRow(tab: tab, active: appState.selectedTab == tab)
					.onTapGesture {
						appState.selectedTab = tab
					}
			}
		} header: {
			SectionHeaderLabel(icon: icon, title: title)
		}
	}
}

private struct SidebarRow: View {
	let tab: AppTab
	let active: Bool

	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: tab.icon)
				.font(.ocoreaiText(14, weight: .medium))
				.frame(width: 22, height: 22)
				.foregroundStyle(active ? .accentColor : Color.primary)
				.accessibilityHidden(true) // Redundant with label
			Text(tab.title)
				.font(.ocoreaiText(14))
		}
		.accessibilityLabel("\(tab.title)")
		.accessibilityAddTraits(active ? [.isSelected] : [])
		.accessibilityAction(named: "Select \(tab.title)") {
			AppState.shared.selectedTab = tab
		}
	}
}

private struct SectionHeaderLabel: View {
	let icon: String
	let title: String

	var body: some View {
		Label(title, systemImage: icon)
			.font(.ocoreaiText(11, weight: .semibold))
			.foregroundStyle(.secondary)
			.textCase(.uppercase)
			.kerning(0.6)
			.listRowSeparator(.hidden)
			.listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
			.listRowBackground(Color.clear)
	}
}

// MARK: - Quick Metrics (cross-platform: macOS 15+, iOS 17+, iPadOS 17+)

private struct OverviewMetricsView: View {
	private var appState: AppState { AppState.shared }

	var body: some View {
		ScrollView {
			LazyVStack(spacing: 10) {
				QuickMetricTile(
					value: String(format: "%.0f", appState.currentMetrics.tokensPerSecond),
					unit: "tok/s",
					label: "Throughput",
					icon: "bolt.horizontal.fill",
					tint: .blue
				)
				QuickMetricTile(
					value: String(format: "%.1f", appState.currentMetrics.gpuMemoryUsage),
					unit: "GB",
					label: "GPU Memory",
					icon: "memorychip",
					tint: .purple
				)
				QuickMetricTile(
					value: String(appState.currentMetrics.activeSessions),
					unit: "",
					label: "Sessions",
					icon: "person.3.fill",
					tint: .green
				)
				QuickMetricTile(
					value: appState.isConnected ? "Active" : "Idle",
					unit: "",
					label: "Status",
					icon: appState.isConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
					tint: appState.isConnected ? .green : .orange
				)
			}
			.padding()
		}
		.navigationTitle("Overview")
		.accessibilityLabel("System Overview")
	}
}

struct QuickMetricTile: View {
	let value: String
	let unit: String
	let label: String
	let icon: String
	let tint: Color

	var body: some View {
		HStack(spacing: 12) {
			ZStack {
				Circle()
					.fill(tint.opacity(0.12))
					.frame(width: 36, height: 36)
				Image(systemName: icon)
						.font(.ocoreaiText(15, weight: .medium))
						.foregroundStyle(tint)
					.accessibilityHidden(true)
				}
				VStack(alignment: .leading, spacing: 2) {
					Text(label)
						.font(.ocoreaiText(11))
						.foregroundStyle(.secondary)
					HStack(spacing: 4) {
						Text(value)
							.font(.ocoreaiMono(14, weight: .semibold))
						if !unit.isEmpty {
							Text(unit)
								.font(.ocoreaiText(10))
								.foregroundStyle(.secondary)
						}
					}
			}
		}
		.padding(.vertical, 4)
		.accessibilityLabel("\(label): \(value)\(unit.isEmpty ? "" : " \(unit)")")
		.accessibilityAddTraits(.isStaticText)
	}
}

// MARK: - macOS App Delegate

#if os(macOS)
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ notification: Notification) {
		// System-managed appearance — auto dark/light
	}
}
#endif
