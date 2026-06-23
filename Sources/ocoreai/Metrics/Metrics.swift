// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Metrics.swift — Prometheus-compatible metrics registry and exporter
///
/// ### Design:
/// - Thread-safe metric collectors via `ManagedAtomic` / `actor` isolation
/// - Standard Prometheus text format: `text/plain; version=0.0.4`
/// - No external dependency (swift-prometheus not required)
///
/// ### Metrics Exposed:
/// - `ocoreai_http_requests_total` (Counter, labeled by method/path/status)
/// - `ocoreai_inference_duration_seconds` (Histogram)
/// - `ocoreai_inference_tokens_total` (Counter, labeled by kind=prompt|generated)
/// - `ocoreai_engine_pool_active_sessions` (Gauge)
/// - `ocoreai_engine_pool_loaded_models` (Gauge)
/// - `ocoreai_kv_cache_gpu_bytes` (Gauge)
/// - `ocoreai_kv_cache_evictions_total` (Counter)
/// - `ocoreai_ttfb_seconds` (Histogram — time to first byte)

import Atomics
import Foundation
import Logging

// MARK: - Metrics Registry (Actor-Isolated)

/// Thread-safe metrics registry exposed via ``GET /metrics``.
///
/// All mutations go through actor mailbox; reads return snapshots.
actor MetricsRegistry {

    // MARK: - Counters

    /// Cumulative HTTP request count, keyed by (method, path, status_code).
    private var httpRequests: [String: UInt64] = [:]

    /// Cumulative token counts, keyed by kind ("prompt" or "generated").
    private var tokenCounts: [String: UInt64] = [:]

    /// Cumulative KV cache eviction count.
    private var kvCacheEvictions: UInt64 = 0

    /// Cumulative auth failure count.
    private var authFailures: UInt64 = 0

    /// Cumulative model load count (successful loads).
    private var modelLoads: UInt64 = 0

    /// Cumulative model load failure count.
    private var modelLoadFailures: UInt64 = 0

    /// Cumulative rate limit rejections.
    private var rateLimitRejections: UInt64 = 0

    // MARK: - Gauges (point-in-time)

    /// Current active session count.
    private var activeSessions: Int = 0

    /// Current loaded model count.
    private var loadedModels: Int = 0

    /// Current GPU KV cache bytes.
    private var kvCacheGpuBytes: Int = 0

    // MARK: - Histogram Buckets

    /// Predefined histogram buckets for inference duration (seconds): [0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, +Inf]
    private static let inferenceBuckets: [Double] = [
        0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0
    ]

    /// Predefined histogram buckets for TTFB (seconds): [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0]
    private static let ttfbBuckets: [Double] = [
        0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0
    ]

    /// Inference duration histogram bucket counts.
    private var inferenceBucketCounts: [Double: UInt64]

    /// Inference duration histogram sum (seconds).
    private var inferenceDurationSum: Double = 0

    /// Inference duration histogram sample count.
    private var inferenceDurationCount: UInt64 = 0

    /// TTFB histogram bucket counts.
    private var ttfbBucketCounts: [Double: UInt64]

    /// TTFB histogram sum (seconds).
    private var ttfbSum: Double = 0

    /// TTFB histogram sample count.
    private var ttfbCount: UInt64 = 0

    // MARK: - Initialization

    /// Create an empty metrics registry.
    init() {
        self.inferenceBucketCounts = Dictionary(uniqueKeysWithValues: Self.inferenceBuckets.map { ($0, UInt64(0)) })
        self.ttfbBucketCounts = Dictionary(uniqueKeysWithValues: Self.ttfbBuckets.map { ($0, UInt64(0)) })
    }

    // MARK: - Counter Operations

    /// Increment HTTP request counter for a given (method, path, status) tuple.
    ///
    /// - Parameters:
    ///   - method: HTTP method (GET, POST, etc.)
    ///   - path: Route path (e.g. "/v1/chat/completions")
    ///   - status: HTTP status code (e.g. 200)
    func incrementHTTPRequest(method: String, path: String, status: Int) {
        let key = "\(method)|\(path)|\(status)"
        httpRequests[key, default: 0] &+= 1
    }

    /// Increment token counter by kind.
    ///
    /// - Parameters:
    ///   - kind: Token kind ("prompt" or "generated")
    ///   - count: Number of tokens to add
    func incrementTokens(kind: String, count: Int) {
        precondition(count >= 0, "token count must be non-negative")
        tokenCounts[kind, default: 0] &+= UInt64(count)
    }

    /// Increment KV cache eviction counter.
    func incrementKVEviction() {
        kvCacheEvictions &+= 1
    }

    /// Record an authentication failure.
    func recordAuthFailure() {
        authFailures &+= 1
    }

    /// Record a successful model load.
    func recordModelLoad() {
        modelLoads &+= 1
    }

    /// Record a model load failure.
    func recordModelLoadFailure() {
        modelLoadFailures &+= 1
    }

    /// Record a rate limit rejection.
    func recordRateLimitRejection() {
        rateLimitRejections &+= 1
    }

    // MARK: - Gauge Updates

    /// Update active session gauge.
    ///
    /// - Parameter value: Current active session count
    func updateActiveSessions(_ value: Int) {
        precondition(value >= 0, "active sessions must be non-negative")
        activeSessions = value
    }

    /// Update loaded models gauge.
    ///
    /// - Parameter value: Current loaded model count
    func updateLoadedModels(_ value: Int) {
        precondition(value >= 0, "loaded models must be non-negative")
        loadedModels = value
    }

    /// Update KV cache GPU bytes gauge.
    ///
    /// - Parameter value: Current GPU KV cache size in bytes
    func updateKVGpuBytes(_ value: Int) {
        precondition(value >= 0, "gpu bytes must be non-negative")
        kvCacheGpuBytes = value
    }

    // MARK: - Histogram Observations

    /// Observe a simple inference duration sample.
    ///
    /// Updates bucket counts, sum, and count atomically.
    ///
    /// - Parameter seconds: Inference duration in seconds
    func observeInferenceDuration(_ seconds: Double) {
        precondition(seconds >= 0, "duration must be non-negative")
        observeInferenceDuration(ms: seconds * 1000, inputTokens: 0, outputTokens: 0, ttfbMs: "0", modelId: "N/A")
    }

    /// Observe an inference duration sample with full metadata.
    ///
    /// Updates histogram buckets, counters, and TTFB tracking in one call.
    /// Used by both streaming and non-streaming handlers.
    ///
    /// - Parameters:
    ///   - ms: Inference duration in milliseconds
    ///   - inputTokens: Number of prompt (input) tokens
    ///   - outputTokens: Number of generated (output) tokens
    ///   - ttfbMs: Time-to-first-byte in milliseconds (string for logging)
    ///   - modelId: Model identifier for labeling
    func observeInferenceDuration(ms: Double, inputTokens: Int, outputTokens: Int, ttfbMs: String, modelId: String) {
        let seconds = ms / 1000.0
        precondition(seconds >= 0, "duration must be non-negative")
        inferenceDurationSum += seconds
        inferenceDurationCount &+= 1
        for bucket in Self.inferenceBuckets {
            if seconds <= bucket {
                inferenceBucketCounts[bucket, default: 0] &+= 1
            }
        }
        // Track token counts
        if inputTokens > 0 {
            incrementTokens(kind: "prompt", count: inputTokens)
        }
        if outputTokens > 0 {
            incrementTokens(kind: "generated", count: outputTokens)
        }
        // Track TTFB
        if let ttfbSeconds = Double(ttfbMs), ttfbSeconds > 0 {
            observeTTFB(ttfbSeconds / 1000.0)
        }
    }

    /// Observe a TTFB (time-to-first-byte) sample.
    ///
    /// - Parameter seconds: TTFB duration in seconds
    func observeTTFB(_ seconds: Double) {
        precondition(seconds >= 0, "ttfb must be non-negative")
        ttfbSum += seconds
        ttfbCount &+= 1
        for bucket in Self.ttfbBuckets {
            if seconds <= bucket {
                ttfbBucketCounts[bucket, default: 0] &+= 1
            }
        }
    }

    // MARK: - Prometheus Export

    /// Export all metrics in Prometheus text format (`text/plain; version=0.0.4`).
    ///
    /// - Returns: Formatted Prometheus metric string
    func export() -> String {
        var lines: [String] = []
        lines.append("# HELP ocoreai_build Info about ocoreai build.")
        lines.append("# TYPE ocoreai_build gauge")
        lines.append("ocoreai_build{version=\"1.0.0\"} 1")
        lines.append("")

        // HTTP Requests Counter
        lines.append("# HELP ocoreai_http_requests_total Total HTTP requests by method, path, and status.")
        lines.append("# TYPE ocoreai_http_requests_total counter")
        for (key, value) in httpRequests.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: "|", maxSplits: 2)
            if parts.count == 3 {
                lines.append(
                    "ocoreai_http_requests_total{method=\"\(parts[0])\",path=\"\(parts[1])\",status=\"\(parts[2])\"} \(value)"
                )
            }
        }
        lines.append("")

        // Inference Tokens Counter
        lines.append("# HELP ocoreai_inference_tokens_total Total tokens processed by kind.")
        lines.append("# TYPE ocoreai_inference_tokens_total counter")
        for (kind, value) in tokenCounts.sorted(by: { $0.key < $1.key }) {
            lines.append("ocoreai_inference_tokens_total{kind=\"\(kind)\"} \(value)")
        }
        lines.append("")

        // Active Sessions Gauge
        lines.append("# HELP ocoreai_engine_pool_active_sessions Current active inference sessions.")
        lines.append("# TYPE ocoreai_engine_pool_active_sessions gauge")
        lines.append("ocoreai_engine_pool_active_sessions \(activeSessions)")
        lines.append("")

        // Loaded Models Gauge
        lines.append("# HELP ocoreai_engine_pool_loaded_models Current loaded model count.")
        lines.append("# TYPE ocoreai_engine_pool_loaded_models gauge")
        lines.append("ocoreai_engine_pool_loaded_models \(loadedModels)")
        lines.append("")

        // KV Cache GPU Bytes Gauge
        lines.append("# HELP ocoreai_kv_cache_gpu_bytes Current GPU KV cache size in bytes.")
        lines.append("# TYPE ocoreai_kv_cache_gpu_bytes gauge")
        lines.append("ocoreai_kv_cache_gpu_bytes \(kvCacheGpuBytes)")
        lines.append("")

        // KV Cache Evictions Counter
        lines.append("# HELP ocoreai_kv_cache_evictions_total Total KV cache eviction events.")
        lines.append("# TYPE ocoreai_kv_cache_evictions_total counter")
        lines.append("ocoreai_kv_cache_evictions_total \(kvCacheEvictions)")
        lines.append("")

        // Auth Failures Counter
        lines.append("# HELP ocoreai_auth_failures_total Total authentication failures.")
        lines.append("# TYPE ocoreai_auth_failures_total counter")
        lines.append("ocoreai_auth_failures_total \(authFailures)")
        lines.append("")

        // Model Load Failures Counter
        lines.append("# HELP ocoreai_model_load_failures_total Total model load failures.")
        lines.append("# TYPE ocoreai_model_load_failures_total counter")
        lines.append("ocoreai_model_load_failures_total \(modelLoadFailures)")
        lines.append("")

        // Rate Limit Rejections Counter
        lines.append("# HELP ocoreai_rate_limit_rejections_total Total rate limit rejections.")
        lines.append("# TYPE ocoreai_rate_limit_rejections_total counter")
        lines.append("ocoreai_rate_limit_rejections_total \(rateLimitRejections)")
        lines.append("")

        // Inference Duration Histogram
        lines.append("# HELP ocoreai_inference_duration_seconds Inference duration in seconds.")
        lines.append("# TYPE ocoreai_inference_duration_seconds histogram")
        var cumCount: UInt64 = 0
        for bucket in Self.inferenceBuckets {
            if let count = inferenceBucketCounts[bucket] {
                cumCount += count
                lines.append("ocoreai_inference_duration_seconds_bucket{le=\"\(bucket)\"} \(cumCount)")
            }
        }
        lines.append("ocoreai_inference_duration_seconds_bucket{le=\"+Inf\"} \(inferenceDurationCount)")
        lines.append("ocoreai_inference_duration_seconds_sum \(String(format: "%.6f", inferenceDurationSum))")
        lines.append("ocoreai_inference_duration_seconds_count \(inferenceDurationCount)")
        lines.append("")

        // TTFB Histogram
        lines.append("# HELP ocoreai_ttfb_seconds Time to first byte in seconds.")
        lines.append("# TYPE ocoreai_ttfb_seconds histogram")
        cumCount = 0
        for bucket in Self.ttfbBuckets {
            if let count = ttfbBucketCounts[bucket] {
                cumCount += count
                lines.append("ocoreai_ttfb_seconds_bucket{le=\"\(bucket)\"} \(cumCount)")
            }
        }
        lines.append("ocoreai_ttfb_seconds_bucket{le=\"+Inf\"} \(ttfbCount)")
        lines.append("ocoreai_ttfb_seconds_sum \(String(format: "%.6f", ttfbSum))")
        lines.append("ocoreai_ttfb_seconds_count \(ttfbCount)")
        lines.append("")

        // MARK: - Dashboard compatibility (flat gauge aliases)
        // These are simple aliases consumed by the SwiftUI Dashboard MetricsSnapshot parser.
        // Production dashboards should parse the native histogram/gauge above instead.

        // tokens_per_second: estimated from inference duration histogram (count / sum)
        let averageThroughput: Double
        if inferenceDurationCount > 0, inferenceDurationSum > 0 {
            averageThroughput = Double(inferenceDurationCount) / inferenceDurationSum
        } else {
            averageThroughput = 0
        }
        lines.append("# HELP ocoreai_tokens_per_second Estimated inference throughput (tok/s).")
        lines.append("# TYPE ocoreai_tokens_per_second gauge")
        lines.append(String(format: "ocoreai_tokens_per_second %.2f", averageThroughput))
        lines.append("")

        // ttft_ms: average TTFB in milliseconds
        let averageTtftMs: Double
        if ttfbCount > 0 {
            averageTtftMs = (ttfbSum / Double(ttfbCount)) * 1000
        } else {
            averageTtftMs = 0
        }
        lines.append("# HELP ocoreai_ttft_ms Average time-to-first-token in milliseconds.")
        lines.append("# TYPE ocoreai_ttft_ms gauge")
        lines.append(String(format: "ocoreai_ttft_ms %.2f", averageTtftMs))
        lines.append("")

        // gpu_memory_gb: KV cache bytes converted to GB
        let gpuMemoryGB = Double(kvCacheGpuBytes) / 1_073_741_824.0
        lines.append("# HELP ocoreai_gpu_memory_gb GPU memory for KV cache in gigabytes.")
        lines.append("# TYPE ocoreai_gpu_memory_gb gauge")
        lines.append(String(format: "ocoreai_gpu_memory_gb %.3f", gpuMemoryGB))
        lines.append("")

        // active_sessions: alias for engine_pool_active_sessions
        lines.append("# HELP ocoreai_active_sessions Alias for engine_pool active sessions.")
        lines.append("# TYPE ocoreai_active_sessions gauge")
        lines.append("ocoreai_active_sessions \(activeSessions)")
        lines.append("")

        return lines.joined(separator: "\n")
    }
}


