// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// System View — MCP servers, tools, audit trail, reasoning status
/// Accessibility: VoiceOver labels, hints, groups
/// Reduced Motion: all animations respect user preference

import SwiftUI

// reduceMotion is now provided by shared AnimationHelpers.swift
import AppKit

struct SystemView: View {
	@State private var viewModel = SystemState()
	@State private var showClearAlert = false

	@Environment(\.ocoreaiTheme) private var theme

	var body: some View {
		Form {
			mcpSection
			toolsSection
			auditSection
			reasoningSection
		}
		.formStyle(.grouped)
		.navigationTitle(StringKey.tabSystem.l)
		.toolbar {
			#if os(iOS)
				ToolbarItem(placement: .topBarTrailing) { refreshButton }
			#elseif os(macOS)
				ToolbarItem(placement: .automatic) { refreshButton }
			#endif
		}
		.overlay {
			if viewModel.isLoading {
				ProgressView(StringKey.loadingModels.l)
			}
		}
		.task {
			await viewModel.load()
		}
		.alert(StringKey.systemClearAudit.l, isPresented: $showClearAlert) {
			Button(StringKey.systemClearAudit.l, role: .destructive) {
				Task { await viewModel.clearAudit() }
			}
			Button(StringKey.tryAgain.l, role: .cancel) {}
		} message: {
			Text(StringKey.systemClearAuditConfirm.l)
		}
	}

	// MARK: - Refresh Button

	private var refreshButton: some View {
		Button {
			Task { await viewModel.refresh() }
		} label: {
			Image(systemName: "arrow.clockwise")
				.rotationEffect(.degrees(viewModel.refreshing ? 360 : 0))
				.animation(reduceMotion ? nil : (viewModel.refreshing ? .easeInOut(duration: 1).repeatForever(autoreverses: false) : nil), value: viewModel.refreshing)
		}
	}

	// MARK: - MCP Section

	@ViewBuilder
	private var mcpSection: some View {
		if viewModel.mcpEndpoints.isEmpty {
			Section {
				Text(StringKey.systemMCPEmpty.l)
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity)
			} header: {
				Text(StringKey.systemMCPSection.l)
			} footer: {
				EmptyView()
			}
		} else {
			ForEach(viewModel.mcpEndpoints) { endpoint in
				Section {
					LabeledContent(StringKey.systemMCPName.l) { Text(endpoint.name) }
					LabeledContent(StringKey.systemMCPCommand.l) {
						Text(endpoint.command).font(.ocoreaiMono(12))
					}
					LabeledContent(StringKey.systemAuditStatus.l) {
						HStack(spacing: 4) {
							StatusDot(isConnected: viewModel.isConnected(for: endpoint))
								.accessibilityHidden(true)
							Text(viewModel.isConnected(for: endpoint) ? StringKey.systemMCPConnected.l : StringKey.systemMCPDisconnected.l)
								.font(.ocoreaiText(12))
						}
					}
				} header: {
					Text(StringKey.systemMCPSection.l)
				} footer: {
					EmptyView()
				}
			}
		}
	}

	// MARK: - Tools Section

	@ViewBuilder
	private var toolsSection: some View {
		if viewModel.toolNames.isEmpty {
			Section {
				Text(StringKey.systemToolsEmpty.l)
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity)
			} header: {
				Text(StringKey.systemToolsSection.l)
			} footer: {
				EmptyView()
			}
		} else {
			Section {
				ForEach(Array(viewModel.toolNames.enumerated()), id: \.offset) { _, name in
					HStack(spacing: 8) {
						Image(systemName: "wrench")
							.foregroundStyle(theme.accent)
							.frame(width: 20)
							.accessibilityHidden(true)
						Text(name)
							.font(.ocoreaiText(13))
							.foregroundStyle(theme.text)
					}
					.accessibilityLabel(name)
				}
			} header: {
				Text(StringKey.systemToolsSection.l)
			} footer: {
				EmptyView()
			}
		}
	}

	// MARK: - Audit Section

	@ViewBuilder
	private var auditSection: some View {
		if viewModel.auditEntries.isEmpty {
			Section {
				Text(StringKey.systemAuditEmpty.l)
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity)
			} header: {
				Text(StringKey.systemAuditSection.l)
			} footer: {
				EmptyView()
			}
		} else {
			Section {
				ForEach(Array(viewModel.auditEntries.prefix(20).enumerated()), id: \.offset) { _, entry in
					VStack(alignment: .leading, spacing: 4) {
						HStack {
							Text(entry.toolName)
								.font(.ocoreaiText(13, weight: .medium))
								.foregroundStyle(theme.text)
							Spacer()
							Text(Self.durationString(entry.durationMs))
								.font(.ocoreaiMono(11))
								.foregroundStyle(theme.textSecondary)
						}
						HStack {
							AuditStatusPill(status: entry.status)
							Text(entry.caller)
								.font(.ocoreaiText(11))
								.foregroundStyle(theme.textSecondary)
						}
					}
					.padding(.vertical, 4)
					.accessibilityLabel("\(entry.toolName) · \(Self.durationString(entry.durationMs)) · \(entry.caller)")
				}
			} header: {
				Text(StringKey.systemAuditSection.l)
			} footer: {
				EmptyView()
			}
		}

		// Clear button in its own section
		Section {
			Button(role: .destructive) {
				showClearAlert = true
			} label: {
				Label(StringKey.systemClearAudit.l, systemImage: "trash")
					.frame(maxWidth: .infinity)
			}
		} footer: {
			EmptyView()
		}
	}

	// MARK: - Reasoning Section

	private var reasoningSection: some View {
		Section {
			LabeledContent(StringKey.systemComplexityScore.l) {
				Text(String(format: "%.2f", viewModel.globalComplexityScore))
			}
			LabeledContent(StringKey.systemThinkingBudget.l) {
				Text(Self.complexityBand(viewModel.globalComplexityScore))
			}
		} header: {
			Text(StringKey.systemReasoningSection.l)
		} footer: {
			EmptyView()
		}
		.accessibilityLabel(StringKey.systemReasoningSection.l)
	}

	// MARK: - Helpers

	private static func durationString(_ ms: Double) -> String {
		if ms < 1000 {
			String(format: "%.0f ms", ms)
		} else {
			String(format: "%.1f s", ms / 1000)
		}
	}

	private static func complexityBand(_ score: Double) -> String {
		if score < 0.3 { return StringKey.systemComplexityLow.l }
		if score < 0.6 { return StringKey.systemComplexityMedium.l }
		return StringKey.systemComplexityHigh.l
	}
}

// MARK: - Status Dot

private struct StatusDot: View {
	let isConnected: Bool

	var body: some View {
		Circle()
			.fill(isConnected ? Color.green : Color.gray)
			.frame(width: 8, height: 8)
	}
}

// MARK: - Audit Status Pill

private struct AuditStatusPill: View {
	let status: AuditEntry.AuditStatus

	var body: some View {
		Text(status.rawValue.uppercased())
			.font(.ocoreaiText(11))
			.padding(3)
			.background(statusColor, in: RoundedRectangle(cornerRadius: 3))
			.foregroundStyle(.white)
	}

	private var statusColor: Color {
		switch status {
		case .success: .green
		case .error: .red
		case .cancelled: .orange
		case .timeout: .orange
		}
	}
}
