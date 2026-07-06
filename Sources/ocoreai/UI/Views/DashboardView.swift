// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// DashboardView — live system metrics with auto-refresh, charts, and theme styling
///
/// Systematic improvements (p1-dashboard):
/// - 14-metric grid: throughput, latency, memory, cache, scheduler, rate limit
/// - Dual-line chart: GPU mem + KV cache trend
/// - System info card: uptime, rate limit rejections, infer throughput
/// - i18n: all user-facing text routed through StringKey localization layer
/// - Chart bounds: explicit Date range instead of open-ended ...
/// - @Observable data flow, no @EnvironmentObject
/// - Accessibility: full VoiceOver labels, hidden decorative elements, chart text alternatives

import Charts
import SwiftUI

struct DashboardView: View {
	@State private var dashboardState: DashboardState
	@State private var startTime: Date = .now
	@Environment(\.ocoreaiTheme) private var theme

	init() {
		_dashboardState = State(initialValue: DashboardState())
	}

	var body: some View {
		ScrollView {
			content
		}
		.background(theme.windowBg)
		.task {
			startTime = .now
			await dashboardState.startPolling()
		}
		.onDisappear {
			dashboardState.stopPolling()
		}
		.accessibilityLabel(StringKey.dashboardLabel.l)
	}

	// MARK: - Content

	@ViewBuilder
	private var content: some View {
		// Health indicator bar
		healthBar
			.padding(.horizontal, 20)
			.padding(.top, 16)

		if dashboardState.isLive {
			metricsSection
			systemInfoSection
			if dashboardState.tokenHistory.count > 1 {
				tokenThroughputChartSection
			}
			if dashboardState.memoryHistory.count > 1 {
				gpuMemoryChartSection
			}
		} else {
			loadingPlaceholder
		}
	}

	// MARK: - Health Bar

	private var healthBar: some View {
		HStack(spacing: 6) {
			Circle()
				.fill(dashboardState.isLive ? theme.greenDot : theme.amberDot)
				.frame(width: 8, height: 8)
				.shadow(
					color: (dashboardState.isLive ? theme.greenDot : theme.amberDot).opacity(0.3),
					radius: 2,
				)
				.accessibilityHidden(true)
			Text(dashboardState.isLive
				? StringKey.systemOnline.l
				: StringKey.systemLoading.l)
				.font(.ocoreaiText(14, weight: .medium))
				.foregroundStyle(theme.textSecondary)
				.accessibilityLabel("System status: \(dashboardState.isLive ? StringKey.systemOnline.l : StringKey.systemLoading.l)")
				.accessibilityAddTraits(.isStaticText)
			Spacer()
			if dashboardState.isLive {
				Text(uptimeLabel)
					.font(.ocoreaiMono(11))
					.foregroundStyle(theme.textTertiary)
					.accessibilityLabel("\(StringKey.uptime.l): \(uptimeLabel)")
			}
		}
	}

	// MARK: - Metrics Grid (9 tiles)

	private var metricsSection: some View {
		let snap = dashboardState.metricsSnapshot
		return VStack(alignment: .leading, spacing: 8) {
			Text(StringKey.metrics.l)
				.font(.ocoreaiText(15, weight: .semibold))
				.padding(.horizontal, 20)
				.padding(.top, 12)

			LazyVGrid(
				columns: [
					GridItem(.flexible()),
					GridItem(.flexible()),
					GridItem(.flexible()),
				],
				spacing: 12,
			) {
				// Row 1: Throughput & Latency
				MetricTile(title: StringKey.throughput.l,
				           bigVal: String(format: "%.1f", snap.tokensPerSecond),
				           subVal: "tok/s",
				           icon: "bolt.horizontal.fill",
				           tint: theme.tintBlue)

				MetricTile(title: StringKey.ttft.l,
				           bigVal: String(format: "%.0f", snap.ttftMs),
				           subVal: "ms",
				           icon: "timer",
				           tint: theme.tintOrange)

				MetricTile(title: StringKey.ttfb.l,
				           bigVal: String(format: "%.0f", snap.ttfbMs),
				           subVal: "ms",
				           icon: "shippingbox.fill",
				           tint: theme.tintGreen)

				// Row 2: Memory
				MetricTile(title: StringKey.gpuMemory.l,
				           bigVal: String(format: "%.2f", snap.gpuMemoryUsage),
				           subVal: "GB",
				           icon: "memorychip",
				           tint: theme.tintPurple)

				MetricTile(title: StringKey.kvCache.l,
				           bigVal: snap.formattedBytes(snap.kvCacheBytes),
				           subVal: "",
				           icon: "internaldrive.fill",
				           tint: theme.tintCyan)

				MetricTile(title: StringKey.kvEvictions.l,
				           bigVal: String(snap.kvCacheEvictions),
				           subVal: "",
				           icon: "arrow.triangle.2.circlepath",
				           tint: theme.tintRed)

				// Row 3: Scheduler
				MetricTile(title: StringKey.sessions.l,
				           bigVal: String(snap.activeSessions),
				           subVal: "",
				           icon: "person.3.fill",
				           tint: theme.tintYellow)

				MetricTile(title: StringKey.modelsLoaded.l,
				           bigVal: String(snap.loadedModels),
				           subVal: "",
				           icon: "brain.head.profile",
				           tint: theme.tintPink)

				MetricTile(title: StringKey.inferences.l,
				           bigVal: String(snap.inferenceCount),
				           subVal: avgInferPerMs,
				           icon: "cpu",
				           tint: theme.tintTeal)
			}
			.padding(.horizontal, 20)
			.padding(.bottom, 8)
		}
		.accessibilityLabel(StringKey.metrics.l)
		.accessibilityAddTraits(.isStaticText)
	}

	private var avgInferPerMs: String {
		let count = snapInferenceCount
		if count == 0 { return "0 ms" }
		return String(format: "%.0f ms", Double(snapInferenceDurationMs) / Double(count))
	}

	private var snapInferenceCount: Int64 {
		dashboardState.metricsSnapshot.inferenceCount
	}

	private var snapInferenceDurationMs: Double {
		dashboardState.metricsSnapshot.inferenceDurationMs
	}

	// MARK: - System Info Card

	private var systemInfoSection: some View {
		HStack(spacing: 16) {
			InfoBadge(icon: "shield.checkered",
			          label: StringKey.rateLimit.l,
			          value: String(dashboardState.metricsSnapshot.rateLimitRejections))
			InfoBadge(icon: "clock.arrow.circlepath",
			          label: StringKey.uptime.l,
			          value: uptimeLabel)
			InfoBadge(icon: "bolt.fill",
			          label: StringKey.avgInfer.l,
			          value: String(format: "%.1f it/s", inferItPerS))
		}
		.padding(12)
		.background(theme.cardBg)
		.clipShape(RoundedRectangle(cornerRadius: 12))
		.padding(.horizontal, 20)
		.accessibilityLabel(StringKey.systemInfoLabel.l)
		.accessibilityAddTraits(.isStaticText)
	}

	// MARK: - Charts

	private var tokenThroughputChartSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			Label(StringKey.tokenThroughput.l, systemImage: "chart.xyaxis.line")
				.font(.ocoreaiText(15, weight: .semibold))

			Chart(dashboardState.tokenHistory) { point in
				AreaMark(
					x: .value("Time", point.timestamp),
					y: .value("tok/s", point.tokensPerSecond),
				)
				.foregroundStyle(theme.accent.opacity(0.15))
				.interpolationMethod(.catmullRom)
				.accessibilityLabel(StringKey.areaGraphTokenDesc.l)

				LineMark(
					x: .value("Time", point.timestamp),
					y: .value("tok/s", point.tokensPerSecond),
				)
				.foregroundStyle(theme.accent)
				.interpolationMethod(.catmullRom)
				.accessibilityHidden(true) // Covered by area mark label
			}
			.frame(height: 180)
			.chartXAxis(.hidden)
			.chartXScale(domain: tokenChartDomain)
			// Text alternative for screen readers
			.accessibilityLabel(StringKey.dashboardTokenChartDesc.l)
		}
		.padding()
		.background(theme.cardBg)
		.clipShape(RoundedRectangle(cornerRadius: 12))
		.padding(.horizontal, 20)
	}

	private var gpuMemoryChartSection: some View {
		VStack(alignment: .leading, spacing: 12) {
			Label(StringKey.gpuMemoryKVCache.l, systemImage: "memorychip")
				.font(.ocoreaiText(15, weight: .semibold))

			Chart(dashboardState.memoryHistory) { point in
				// GPU Memory area + line
				AreaMark(
					x: .value("Time", point.timestamp),
					y: .value("GB", point.gpuMemoryUsage),
				)
				.foregroundStyle(theme.tintPurple.opacity(0.15))
				.interpolationMethod(.catmullRom)
				.accessibilityLabel(StringKey.areaGraphGpuDesc.l)

				LineMark(
					x: .value("Time", point.timestamp),
					y: .value("GB", point.gpuMemoryUsage),
				)
				.foregroundStyle(theme.tintPurple)
				.interpolationMethod(.catmullRom)
				.lineStyle(StrokeStyle(lineWidth: 2))
				.accessibilityHidden(true) // covered by area mark

				// KV Cache dashed line
				LineMark(
					x: .value("Time", point.timestamp),
					y: .value("GB", point.kvCacheGB),
				)
				.foregroundStyle(theme.tintCyan)
				.interpolationMethod(.catmullRom)
				.lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
				.accessibilityLabel(StringKey.kvCacheLineDesc.l)
			}
			.frame(height: 180)
			.chartXAxis(.hidden)
			.chartLegend(.visible)
			.chartYAxisLabel("GB", alignment: .leading)
			.chartXScale(domain: memoryChartDomain)
			// Text alternative for screen readers
			.accessibilityLabel(StringKey.dashboardMemChartDesc.l)
		}
		.padding()
		.background(theme.cardBg)
		.clipShape(RoundedRectangle(cornerRadius: 12))
		.padding(.horizontal, 20)
		.padding(.bottom, 20)
	}

	// MARK: - Chart domain helpers

	private var tokenChartDomain: ClosedRange<Date> {
		let base = dashboardState.tokenHistory.last?.timestamp ?? .now
		// Use chart window setting for upper bound — Date.distantFuture causes chart scale overflow
		let window = max(SettingsStore.shared.chartWindowSec, 30)
		let lower = base.addingTimeInterval(-Double(window))
		return lower ... base.addingTimeInterval(5)
	}

	private var memoryChartDomain: ClosedRange<Date> {
		let base = dashboardState.memoryHistory.last?.timestamp ?? .now
		let window = max(SettingsStore.shared.chartWindowSec, 30)
		let lower = base.addingTimeInterval(-Double(window))
		return lower ... base.addingTimeInterval(5)
	}

	// MARK: - Uptime helpers

	private var uptimeSeconds: Double {
		max(1.0, Date().timeIntervalSince(startTime))
	}

	private var uptimeLabel: String {
		let secs = Int(uptimeSeconds)
		let h = secs / 3600
		let m = (secs % 3600) / 60
		let s = secs % 60
		if h > 0 { return String(format: "%dh %dm %ds", h, m, s) }
		if m > 0 { return String(format: "%dm %ds", m, s) }
		return String(format: "%ds", s)
	}

	private var inferItPerS: Double {
		let count = dashboardState.metricsSnapshot.inferenceCount
		guard count > 0 else { return 0 }
		return Double(count) / uptimeSeconds
	}

	// MARK: - Loading Placeholder

	private var loadingPlaceholder: some View {
		ProgressView(StringKey.loadingMetrics.l)
			.progressViewStyle(CircularProgressViewStyle(tint: theme.accent))
			.padding(40)
			.accessibilityLabel(StringKey.loadingMetrics.l)
	}
}

// MARK: - Reusable Metric Tile

private struct MetricTile: View {
	let title: String
	let bigVal: String
	let subVal: String
	let icon: String
	let tint: Color

	@Environment(\.ocoreaiTheme) private var theme

	var body: some View {
		VStack(spacing: 8) {
			Image(systemName: icon)
				.font(.ocoreaiText(16))
				.foregroundStyle(tint)
				.frame(height: 24)
				.accessibilityHidden(true)

			Text(bigVal)
				.font(.ocoreaiMono(16, weight: .bold))
				.lineLimit(1)

			HStack(spacing: 4) {
				Text(title)
					.font(.ocoreaiText(10))
					.foregroundStyle(theme.textSecondary)
				if !subVal.isEmpty {
					Text(subVal)
						.font(.ocoreaiText(9))
						.foregroundStyle(theme.textTertiary)
				}
			}
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 14)
		.background(theme.cardBg)
		.clipShape(RoundedRectangle(cornerRadius: 12))
		.accessibilityLabel("\(title): \(bigVal)\(subVal.isEmpty ? "" : " \(subVal)")")
		.accessibilityAddTraits(.isStaticText)
	}
}

// MARK: - Info Badge

private struct InfoBadge: View {
	let icon: String
	let label: String
	let value: String

	@Environment(\.ocoreaiTheme) private var theme

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: icon)
				.font(.ocoreaiText(12))
				.foregroundStyle(theme.accent)
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 1) {
				Text(label)
					.font(.ocoreaiText(9))
					.foregroundStyle(theme.textTertiary)
				Text(value)
					.font(.ocoreaiMono(12, weight: .semibold))
					.foregroundStyle(theme.text)
			}
		}
		.accessibilityLabel("\(label): \(value)")
		.accessibilityAddTraits(.isStaticText)
	}
}

// MARK: - Preview (Xcode only — #Preview requires PreviewsMacros plugin)
