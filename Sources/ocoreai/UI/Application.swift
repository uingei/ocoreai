// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Application entry point — macOS 15+ / iOS 17+ / iPadOS 17+
///
/// HIG-compliant structure:
///   • macOS: single-instance Window (not WindowGroup), standard title bar
///   • NavigationSplitView: sidebar + detail (two-column)
///   • Settings via Cmd+, (CommandGroup replacing: .appSettings)
///   • Sidebar driven by AppState.selectedTab (single source of truth)
///   • Keyboard shortcuts localized via StringKey.l
///
/// @Observable pattern: AppState is now Observable; accessed as computed property.

import SwiftUI

@main
struct OcoreaiApp: App {
	#if os(macOS)
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	#endif

	var body: some Scene {
		#if os(macOS)
		// macOS: single-instance window — HIG compliant
		Window("ocoreai", id: "main") {
			OcoreaiShellView()
		}
		.windowResizability(.contentSize)
		.windowStyle(.titleBar)
		// Settings via Cmd+, — macOS standard
		.commands {
			CommandGroup(replacing: .newItem) {}
			CommandGroup(replacing: .undoRedo) {
				Button(StringKey.undoAction.l, action: { AppState.shared.performUndo() })
					.disabled(!AppState.shared.hasUndo)
					.keyboardShortcut("z", modifiers: .command)
			}
			CommandGroup(replacing: .appSettings) {
				Button(StringKey.tabSettings.l) {
					AppState.shared.selectedTab = .settings
				}
			}
			CommandMenu(StringKey.navigationTitle.l) {
				Button(StringKey.tabDashboard.l) {
					AppState.shared.selectedTab = .dashboard
				}
				.keyboardShortcut("1")
				Button(StringKey.tabChat.l) {
					AppState.shared.selectedTab = .chat
				}
				.keyboardShortcut("2")
				Button(StringKey.tabModels.l) {
					AppState.shared.selectedTab = .models
				}
				.keyboardShortcut("3")
				Button(StringKey.tabStatus.l) {
					AppState.shared.selectedTab = .status
				}
				.keyboardShortcut("4")
			}
		}
		#else
		WindowGroup {
			OcoreaiShellView()
		}
		#endif
	}
}

/// Root Shell View — two-column: sidebar + detail, HIG compliant

struct OcoreaiShellView: View {
	// swiftlint:disable:next identifier_name
	@Environment(\.colorScheme) private var colorScheme
	// swiftlint:disable:next identifier_name
	@Environment(\.scenePhase) private var scenePhase
	@State private var theme = OcoreaiTheme.theme(from: .light)
	@Bindable private var appState = AppState.shared

	var body: some View {
		NavigationSplitView {
			SidebarView()
				.navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
		} detail: {
			TabDetailView()
		}
		.navigationSplitViewStyle(.balanced)
		// swiftlint:disable:next identifier_name
		.environment(\.ocoreaiTheme, theme)
		.onChange(of: colorScheme) { _, scheme in
			theme = OcoreaiTheme.theme(from: scheme)
		}
		// ScenePhase gating: tell AppState whether we're in foreground/background
		.onChange(of: scenePhase) { _, phase in
			appState.isForeground = (phase == .active)
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
		.accessibilityLabel(StringKey.appLabel.l)
		.frame(minWidth: 580, minHeight: 420)
	}
}

// MARK: - Detail Router

private struct TabDetailView: View {
	@Bindable private var appState = AppState.shared

	var body: some View {
		content
			.navigationTitle(appState.selectedTab.title)
			.accessibilityLabel("\(appState.selectedTab.title) \(StringKey.appTitle.l)")
	}

	@ViewBuilder
	private var content: some View {
		switch appState.selectedTab {
		case .dashboard: DashboardView()
			case .chat:      ChatView()
			case .models:    ModelView()
			case .sessions:  SessionView()
			case .skills:    SkillsView()
			case .system:    SystemView()
			case .settings:  SettingsView()
			case .status:    StatusView()
		}
	}

	// MARK: - Empty View for initial state
	struct EmptyContent: View {
		var body: some View {
			ContentUnavailableView(
				"ocoreai",
					systemImage: "brain.fill",
				description: Text(StringKey.selectPanel.l)
			)
			.accessibilityLabel(StringKey.noPanelSelected.l)
		}
	}
}

// MARK: - Sidebar

private struct SidebarView: View {
	@Bindable private var appState = AppState.shared

	var body: some View {
		List(selection: $appState.selectedTab) {
			sidebarSection(icon: "server.rack", title: StringKey.sectionServer.l, tabs: AppTab.serverGroup)
			sidebarSection(icon: "brain.head.profile", title: StringKey.sectionModels.l, tabs: AppTab.modelGroup)
			sidebarSection(icon: "gearshape.2", title: StringKey.sectionGeneral.l, tabs: AppTab.generalGroup)
		}
		.listStyle(.sidebar)
		.accessibilityLabel(StringKey.sidebarNavigation.l)
	}

	private func sidebarSection(icon: String, title: String, tabs: [AppTab]) -> some View {
		Section {
			ForEach(tabs) { tab in
				SidebarRow(tab: tab, active: appState.selectedTab == tab)
					.tag(tab)
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
		.accessibilityAction(named: "\(StringKey.selectTab.l) \(tab.title)") {
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

// MARK: - macOS App Delegate
#if os(macOS)
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationDidFinishLaunching(_ notification: Notification) {
		// System-managed appearance — auto dark/light
	}
}
#endif
