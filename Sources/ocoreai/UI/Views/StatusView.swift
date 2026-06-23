// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// StatusView — real-time system status panel
/// omlx pattern: ViewModel + SectionHeader + StatusPill
/// @Observable pattern: AppState accessed via computed property (no @EnvironmentObject)
/// Accessibility: full VoiceOver labels on all rows

import SwiftUI

struct StatusView: View {
	private var appState: AppState { AppState.shared }
	@Environment(\.ocoreaiTheme) private var theme

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 24) {
				SectionHeader("System Status", subtitle: "Real-time backend metrics")

				LazyVStack(spacing: 8) {
					StatusRow(
						title: "Backend",
						value: appState.isConnected ? "Online" : "Offline",
						icon: "server.rack",
						tint: appState.isConnected ? theme.greenDot : theme.redDot,
						pill: appState.isConnected ? .running : .error
					)
					StatusRow(
						title: "Active Sessions",
						value: String(appState.currentMetrics.activeSessions),
						icon: "person.3.fill",
						tint: .green,
						pill: .running
					)
					StatusRow(
						title: "GPU Memory",
						value: String(format: "%.1f GB", appState.currentMetrics.gpuMemoryUsage),
						icon: "memorychip",
						tint: .purple,
						pill: .running
					)
					StatusRow(
						title: "Token Throughput",
						value: String(format: "%.1f tok/s", appState.currentMetrics.tokensPerSecond),
						icon: "bolt.horizontal.fill",
						tint: .blue,
						pill: .running
					)
					StatusRow(
						title: "TTFT",
						value: String(format: "%.0f ms", appState.currentMetrics.ttftMs),
						icon: "timer",
						tint: .orange,
						pill: .running
					)
				}
				Spacer(minLength: 16)
			}
			.padding(20)
		}
		.animation(.easeInOut(duration: 0.2), value: appState.currentMetrics)
		.background(theme.windowBg)
		.accessibilityLabel("System Status")
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
				.accessibilityLabel("Status: \(pill.stringValue)")
		}
		.modifier(theme.cardStyle())
		.accessibilityLabel("\(title): \(value)")
		.accessibilityAddTraits(.isStaticText)
	}
}

// MARK: - Accessibility Extension for SPStatus

extension SPStatus {
	var stringValue: String {
		switch self {
		case .running: return StringKey.statusRunning.l
		case .starting: return StringKey.statusStarting.l
		case .stopping: return StringKey.statusStopping.l
		case .stopped: return StringKey.statusStopped.l
		case .error: return StringKey.statusError.l
		case .custom(_, let label, _): return label
		}
	}
}
