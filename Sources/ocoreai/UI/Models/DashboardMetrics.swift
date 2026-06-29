// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Prometheus metrics bridge — polls /metrics endpoint, feeds Dashboard.
///
/// @Observable pattern (Swift 5.9+): property-level change tracking.

import Foundation

/// Flat DTO from Prometheus text format
struct MetricsSnapshot: Equatable {
	let timestamp: Date
	// — Throughput —
	let tokensPerSecond: Double
	let ttftMs: Double
	let ttfbMs: Double
	// — Memory —
	let gpuMemoryUsage: Double
	let kvCacheBytes: Int64
	let kvCacheEvictions: Int64
	// — Scheduler —
	let activeSessions: Int
	let loadedModels: Int
	let inferenceDurationMs: Double
	let inferenceCount: Int64
	// — Rate limit —
	let rateLimitRejections: Int64

	static var empty: MetricsSnapshot {
		MetricsSnapshot(
			timestamp: .now,
			tokensPerSecond: 0,
			ttftMs: 0,
			ttfbMs: 0,
			gpuMemoryUsage: 0,
			kvCacheBytes: 0,
			kvCacheEvictions: 0,
			activeSessions: 0,
			loadedModels: 0,
			inferenceDurationMs: 0,
			inferenceCount: 0,
			rateLimitRejections: 0,
		)
	}
}

/// Bridge that polls local API and publishes metrics snapshots via Task loop.
@Observable
@MainActor
final class MetricsBridge {
	var metricsSnapshot: MetricsSnapshot = .empty

	private let url: URL
	private var pollingTask: Task<Void, Never>?

	init(url: URL? = nil) {
		self.url = url ?? Self.defaultURL
	}

	// MARK: - Fallback URL

	private static let defaultURL: URL = {
		guard let url = URL(string: "http://localhost:8080/metrics") else {
			// Unreachable — "http://localhost:8080/metrics" is a syntactically valid URL literal.
			// fatalError satisfies the exhaustiveness check; will never execute at runtime.
			fatalError("[MetricsBridge] Default metrics URL invalid")
		}
		return url
	}()

	func startPolling(interval: TimeInterval = 1.0) {
		stopPolling()
		pollingTask = Task.detached(priority: .utility) {
			while !Task.isCancelled {
				do {
					try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
				} catch { break }

				let snapshot = await Result<MetricsSnapshot, Error>.withLogAsync(
					service: "MetricsBridge",
					context: "metrics_poll",
				) { try await Self.fetchMetrics(from: self.url) }
				if let snap = snapshot {
					await MainActor.run {
						self.metricsSnapshot = snap
					}
				}
			}
		}
	}

	func stopPolling() {
		pollingTask?.cancel()
		pollingTask = nil
	}

	private static func fetchMetrics(from url: URL) async throws -> MetricsSnapshot {
		let (data, response) = try await URLSession.shared.data(from: url)
		guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
			return .empty
		}
		guard let text = String(data: data, encoding: .utf8) else {
			return .empty
		}
		guard let parsed = MetricsSnapshot.parse(from: text) else {
			return .empty
		}
		return parsed
	}
}

// MARK: - Prometheus text format parser

extension MetricsSnapshot {
	static func parse(from text: String) -> MetricsSnapshot? {
		var tokPerSec: Double = 0
		var ttft: Double = 0
		var ttfb: Double = 0
		var gpuMem: Double = 0
		var kvBytes: Int64 = 0
		var kvEvictions: Int64 = 0
		var sessions = 0
		var models = 0
		var infDurationMs: Double = 0
		var infCount: Int64 = 0
		var rateRejections: Int64 = 0

		for line in text.split(separator: "\n") {
			let parts = line.split(separator: " ", maxSplits: 1)
			guard parts.count >= 2, !line.hasPrefix("#") else { continue }
			let metricName = String(parts[0])
			let valueStr = String(parts[1])
			guard let value = Double(valueStr) else { continue }

			switch metricName {
			// Throughput
			case "ocoreai_tokens_per_second": tokPerSec = value
			case "ocoreai_ttft_ms": ttft = value
			// TTFB histogram sum (total seconds) / count
			case "ocoreai_ttfb_seconds_sum":
				if infCount > 0 { ttfb = value * 1000.0 / Double(infCount) }
			// Memory
			case "ocoreai_gpu_memory_gb": gpuMem = value
			case "ocoreai_kv_cache_gpu_bytes": kvBytes = Int64(value)
			case "ocoreai_kv_cache_evictions_total": kvEvictions = Int64(value)
			// Scheduler
			case "ocoreai_active_sessions", "ocoreai_engine_pool_active_sessions": sessions = Int(value)
			case "ocoreai_engine_pool_loaded_models": models = Int(value)
			// Inference histogram
			case "ocoreai_inference_duration_seconds_sum": infDurationMs = value * 1000.0
			case "ocoreai_inference_duration_seconds_count": infCount = Int64(value)
			// Rate limit
			case "ocoreai_rate_limit_rejections_total": rateRejections = Int64(value)
			default: break
			}
		}

		// Fallback: if TTFB not in histogram, use TTFT
		if ttfb == 0 { ttfb = ttft }

		return MetricsSnapshot(
			timestamp: .now,
			tokensPerSecond: tokPerSec,
			ttftMs: ttft,
			ttfbMs: ttfb,
			gpuMemoryUsage: gpuMem,
			kvCacheBytes: kvBytes,
			kvCacheEvictions: kvEvictions,
			activeSessions: sessions,
			loadedModels: models,
			inferenceDurationMs: infDurationMs,
			inferenceCount: infCount,
			rateLimitRejections: rateRejections,
		)
	}

	// Helper: format bytes to human-readable string
	func formattedBytes(_ bytes: Int64) -> String {
		let gb = Double(bytes) / 1_073_741_824.0
		if gb >= 1.0 { return String(format: "%.1f GB", gb) }
		let mb = Double(bytes) / 1_048_576.0
		return String(format: "%.1f MB", mb)
	}
}
