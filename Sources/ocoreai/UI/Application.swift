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
            // .windowResizability(.default) is the macOS standard — .contentSize
            // can cause window activation issues with TextField focus (radar 91608726)
            .windowStyle(.titleBar)
            .windowResizability(.minSize)
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
                    Button(StringKey.tabSessions.l) {
                        AppState.shared.selectedTab = .sessions
                    }
                    .keyboardShortcut("5")
                    Button(StringKey.tabSkills.l) {
                        AppState.shared.selectedTab = .skills
                    }
                    .keyboardShortcut("6")
                    Button(StringKey.tabSystem.l) {
                        AppState.shared.selectedTab = .system
                    }
                    .keyboardShortcut("7")
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    // P1-fix: derive theme directly from colorScheme — eliminates one-frame white flash
    // where @State initialized from hardcoded .light
    private var theme: OcoreaiTheme {
        OcoreaiTheme.theme(from: colorScheme)
    }
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
        // P1-fix: ScenePhase .inactive (command-tab, alert popup) should not throttle
        // polling — only background truly means the user isn't looking.
        .onChange(of: scenePhase) { _, phase in
            appState.isForeground = (phase != .background)
        }
        .onAppear {
            appState.initialize()
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
        case .chat: ChatView()
        case .models: ModelView()
        case .sessions: SessionView()
        case .skills: SkillsView()
        case .system: SystemView()
        case .settings: SettingsView()
        case .status: StatusView()
        }
    }

}

// MARK: - Sidebar

private struct SidebarView: View {
    @Bindable private var appState = AppState.shared

    var body: some View {
        List(selection: $appState.selectedTab) {
            sidebarSection(icon: "server.rack", title: StringKey.sectionServer.l, tabs: AppTab.serverGroup)
            sidebarSection(icon: "brain.head.profile", title: StringKey.sectionWorkflow.l, tabs: AppTab.workflowGroup)
            sidebarSection(icon: "gearshape.2", title: StringKey.sectionSystem.l, tabs: AppTab.systemGroup)
        }
        .listStyle(.sidebar)
        .accessibilityLabel(StringKey.sidebarNavigation.l)
    }

    private func sidebarSection(icon: String, title: String, tabs: [AppTab]) -> some View {
        Section {
            ForEach(tabs) { tab in
                SidebarRow(tab: tab)
                    .tag(tab)
            }
        } header: {
            SectionHeaderLabel(icon: icon, title: title)
        }
    }
}

private struct SidebarRow: View {
    let tab: AppTab

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tab.icon)
                .font(.ocoreaiText(14, weight: .medium))
                .frame(width: 22, height: 22)
                .symbolRenderingMode(.monochrome)
            Text(tab.title)
                .font(.ocoreaiText(14))
        }
        .accessibilityLabel(tab.title)
        // List(selection:) already provides selection state, accent highlighting,
        // and VoiceOver traits — no need to duplicate those responsibilities.
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
        func applicationDidFinishLaunching(_: Notification) {
            // Register global crash handlers early — captures inference OOM, segfault, etc.
            registerGlobalCrashHandlers()

            // MARK: - HF Hub Environment Configuration

            // Disable xet (Rust-based) downloader to prevent cooperative cancellation failure.
            // xet swallows Python exceptions in its Rust frame, causing Task cancellation to hang.
            // Disable xet backend to avoid HuggingFace cache corruption on macOS (MLX upstream pattern).
            setenv("HF_HUB_DISABLE_XET", "1", 1)

            // HF_ENDPOINT: allow mirror/proxy override for restricted regions.
            // If set, #hubDownloader() picks it up automatically.
            // If HF_ENDPOINT_MIRROR is set, override HF_ENDPOINT.
            if let mirror = ProcessInfo.processInfo.environment["HF_ENDPOINT_MIRROR"] {
                setenv("HF_ENDPOINT", mirror, 1)
            }

            // macOS HIG: activate application so it becomes key window immediately
            // This prevents the terminal/console from stealing keyboard focus
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)

            // Ensure the main window becomes key & ordered front
            if let mainWindow = NSApp.mainWindow {
                mainWindow.makeKeyAndOrderFront(nil)
            }
        }
    }
#endif
