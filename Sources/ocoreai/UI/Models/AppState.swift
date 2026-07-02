// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Reactive global state — coordinates metrics polling, UI navigation, and theme updates.
///
/// @Observable pattern (Swift 5.9+): property-level change tracking,
/// no @Published needed. Observers auto-track mutations.

import Foundation
import Observation

@Observable
@MainActor
final class AppState {
	static let shared = AppState()

	var isConnected: Bool = false
	var currentMetrics: MetricsSnapshot = .empty
	var selectedTab: AppTab = .dashboard
	/// ScenePhase gate — true when app is active, false in background
	var isForeground: Bool = true

	/// Undo slot — set by any ViewModel before a destructive op, cleared after undo
	var undoAction: (@MainActor () -> Void)?

	/// Whether undo is available (for menu item enabling)
	var hasUndo: Bool {
		undoAction != nil
	}

	/// Execute undo and clear the slot
	func performUndo() {
		undoAction?()
		undoAction = nil
	}

	private let engine = OcoreaiEngine.shared
	private var metricsTask: Task<Void, Never>?
	/// Idempotency guard — initialize() is safe to call multiple times
	private var _initialized = false

	/// Read live metrics from EnginePool + MetricsRegistry (Fast Path, no HTTP)
	/// Combines engine summary with Prometheus-style metrics for full observability.
	private func pollMetrics() async -> MetricsSnapshot {
		let (pool, registry) = (
			OcoreaiEngine.shared.activeEnginePool,
			OcoreaiEngine.shared.activeMetrics,
		)

		// Fast path: get engine summary for core state
		let summary: EngineSummary
		if let pool {
			summary = await pool.engineSummary()
		} else {
			return .empty
		}

		// Parse metrics registry for detailed telemetry
		if let registry, let parsed = await MetricsSnapshot.parse(from: registry.export()) {
			return MetricsSnapshot(
				timestamp: .now,
				tokensPerSecond: parsed.tokensPerSecond,
				ttftMs: parsed.ttftMs,
				ttfbMs: parsed.ttfbMs,
				gpuMemoryUsage: parsed.gpuMemoryUsage,
				kvCacheBytes: parsed.kvCacheBytes,
				kvCacheEvictions: parsed.kvCacheEvictions,
				activeSessions: parsed.activeSessions,
				loadedModels: parsed.loadedModels,
				inferenceDurationMs: parsed.inferenceDurationMs,
				inferenceCount: parsed.inferenceCount,
				rateLimitRejections: parsed.rateLimitRejections,
			)
		}

		// Fallback: engine summary only
		return MetricsSnapshot(
			timestamp: .now,
			tokensPerSecond: 0,
			ttftMs: 0,
			ttfbMs: 0,
			gpuMemoryUsage: summary.gpuCacheGB,
			kvCacheBytes: 0,
			kvCacheEvictions: 0,
			activeSessions: summary.activeSessions,
			loadedModels: summary.loadedModels,
			inferenceDurationMs: 0,
			inferenceCount: 0,
			rateLimitRejections: 0,
		)
	}

	/// Called on app launch — start internal server + sync engine state
	/// Idempotent: safe to call multiple times (e.g., repeated onAppear in SwiftUI)
	func initialize() {
		guard !_initialized else { return }
		_initialized = true

		Task {
			await OcoreaiEngine.shared.start()
		}

		/// Fast Path: poll EnginePool directly (no HTTP, zero serialization)
		/// ScenePhase-gated: 1s in foreground, 10s in background.
		metricsTask = Task.detached { [weak self] in
			guard let self else { return }
			while !Task.isCancelled {
				await MainActor.run {
					// isConnected is based on engineReady, not loadedModels —
					// EnginePool starts empty (lazy model loading), so loadedModels == 0
					// does NOT mean the engine is down.
					self.isConnected = OcoreaiEngine.shared.engineReady
				}
				let snap = await pollMetrics()
				await MainActor.run {
					self.currentMetrics = snap
				}
				// ScenePhase gating: slow down in background
				let sleepNs: UInt64 = await MainActor.run { self.isForeground } ? 1_000_000_000 : 10_000_000_000
				try? await Task.sleep(nanoseconds: sleepNs)
			}
		}
	}



	/// Graceful shutdown on app termination
	func shutdown() {
		metricsTask?.cancel()
		metricsTask = nil
		Task.detached {
			await OcoreaiEngine.shared.stop()
		}
	}
}

// MARK: - Tab enum with sidebar grouping

enum AppTab: String, CaseIterable, Identifiable {
	case dashboard, chat, models, sessions, skills, system, settings, status

	var id: String {
		rawValue
	}

	var title: String {
		switch self {
		case .dashboard: StringKey.tabDashboard.l
		case .chat: StringKey.tabChat.l
		case .models: StringKey.tabModels.l
		case .settings: StringKey.tabSettings.l
		case .status: StringKey.tabStatus.l
		case .sessions: StringKey.tabSessions.l
		case .skills: StringKey.tabSkills.l
		case .system: StringKey.tabSystem.l
		}
	}

	var icon: String {
		switch self {
		case .dashboard: "chart.xyaxis.line"
		case .chat: "bubble.right"
		case .models: "brain.head.profile"
		case .settings: "gear"
		case .status: "info.circle"
		case .sessions: "text.page"
		case .skills: "wrench.and.screwdriver"
		case .system: "server.rack"
		}
	}

	// Sidebar section groups (omlx pattern)
	static var serverGroup: [AppTab] {
		[.dashboard, .chat]
	}

	static var modelGroup: [AppTab] {
		[.models]
	}

	static var generalGroup: [AppTab] {
		[.sessions, .skills, .system, .settings, .status]
	}
}
