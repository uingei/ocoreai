// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// StatusView — real-time system status panel
/// ViewModel + SectionHeader + StatusPill + StatusRow
/// @Observable pattern. i18n via StringKey. Accessibility: full VoiceOver.

import SwiftUI

struct StatusView: View {
    // Observation: reading @Observable public properties in body via `let`
    // establishes reactive dependencies (SE-0403). No property wrapper needed.
    private let appState = AppState.shared

    @Environment(\.ocoreaiTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionHeader(StringKey.dashboardTitle.l, subtitle: StringKey.loadingMetrics.l)

                LazyVStack(spacing: 8) {
                    StatusRow(
                        title: StringKey.backend.l,
                        value: appState.isConnected ? StringKey.systemOnline.l : StringKey.disconnected.l,
                        icon: "server.rack",
                        tint: appState.isConnected ? theme.greenDot : theme.redDot,
                        pill: appState.isConnected ? SPStatus.running : SPStatus.error,
                    )
                    StatusRow(
                        title: StringKey.sessions.l,
                        value: String(appState.currentMetrics.activeSessions),
                        icon: "person.3.fill",
                        tint: theme.greenDot,
                        pill: SPStatus.running,
                    )
                    StatusRow(
                        title: StringKey.gpuMemory.l,
                        value: String(format: "%.1f GB", appState.currentMetrics.gpuMemoryUsage),
                        icon: "memorychip",
                        tint: theme.tintPurple,
                        pill: SPStatus.running,
                    )
                    StatusRow(
                        title: StringKey.throughput.l,
                        value: String(format: "%.1f tok/s", appState.currentMetrics.tokensPerSecond),
                        icon: "bolt.horizontal.fill",
                        tint: theme.tintBlue,
                        pill: SPStatus.running,
                    )
                    StatusRow(
                        title: StringKey.ttft.l,
                        value: String(format: "%.0f ms", appState.currentMetrics.ttftMs),
                        icon: "timer",
                        tint: theme.tintOrange,
                        pill: SPStatus.running,
                    )
                }
                Spacer(minLength: 16)
            }
            .padding(20)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: appState.currentMetrics)
        .background(theme.windowBg)
        .accessibilityLabel(StringKey.dashboardTitle.l)
    }
}

// MARK: - Reusable Status Row

struct StatusRow: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color
    let pill: SPStatus

    @Environment(\.ocoreaiTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.1))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.ocoreaiText(13, weight: .medium))
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.ocoreaiText(11))
                    .foregroundStyle(theme.textSecondary)
                Text(value)
                    .font(.ocoreaiMono(14))
                    .fontWeight(.semibold)
            }

            Spacer()

            StatusPill(status: pill, compact: true)
                .accessibilityLabel("\(StringKey.a11yStatus.l): \(pill.label)")
        }
        .modifier(theme.cardStyle())
        .accessibilityLabel("\(title): \(value)")
        .accessibilityAddTraits(.isStaticText)
    }
}
