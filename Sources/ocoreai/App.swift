// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// App.swift — oCoreAI entry point, service lifecycle, and graceful shutdown
///
/// ### Startup Sequence:
/// 1. Initialize ``TokenizerManager``
/// 2. Create ``EnginePool`` (config-driven)
/// 3. Initialize ``MetricsRegistry`` (Prometheus-compatible)
/// 4. Build ``Application`` with ``AuthMiddleware`` + ``RateLimitMiddleware`` + Metrics
/// 5. Start gauge update task (active sessions / loaded models)
///
/// ### Shutdown Sequence:
/// - Signal → cancel gauge task → drain active inference sessions → release GPU/SSD cache → exit
/// - Hard timeout of 30 seconds prevents hung shutdown

import Hummingbird
import Logging
import ServiceLifecycle
import Foundation

// MARK: - Entry Point

/// Main application struct — ``@main`` entry point.
@main
struct App {
    /// Application-scoped logger
    static let logger = Logger(label: "ocoreai")

    /// Main entry point — boot engine pool, wire middleware, start HTTP server.
    static func main() async throws {
        logger.info("oCoreAI booting...")

        // 1. Shared tokenizer registry
        let tokenizerManager = TokenizerManager()

        // 2. Engine pool with lifecycle management
        let coreAILoadingConfig = CoreAILoadingConfig.production

        let enginePool = EnginePool(
            config: .default,
            logger: logger,
            tokenizerManager: tokenizerManager,
            kvCacheConfig: KVCacheManager.Config.default,
            coreAILoadingConfig: coreAILoadingConfig
        )

        // 3. Metrics registry (Prometheus-compatible, actor-isolated)
        let metrics = MetricsRegistry()

        // 4. Middleware
        let rateLimitProvider = RateLimitProvider(
            config: .init(
                globalRate: 200, globalBurst: 300,
                perModelRate: 30, perModelBurst: 45,
                perIPRate: 20, perIPBurst: 30,
                enabled: true
            ),
            logger: logger
        )
        let authMiddleware = AuthMiddleware<OCoreAIContext>(config: .default, logger: logger)
        let rateLimitMiddleware = RateLimitMiddleware<OCoreAIContext>(
            provider: rateLimitProvider,
            logger: logger
        )

        // 4b. Start bucket cleanup task (cancel on shutdown)
        let rateLimitCleanupTask = rateLimitProvider.cleanupPeriodically()

        // 5. Background gauge update task
        let gaugeTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    break
                }
                let summary = await enginePool.engineSummary()
                await metrics.updateActiveSessions(summary.activeSessions)
                await metrics.updateLoadedModels(summary.loadedModels)
                // P6: Update KV cache GPU bytes gauge with actual data
                await metrics.updateKVGpuBytes(Int(summary.gpuCacheGB * 1_073_741_824))
            }
        }

        // 6. Read download tokens
        let hfToken = Environment.get("HF_TOKEN")
        let msToken = Environment.get("MODELSCOPE_TOKEN")

        // 7. Build and run application
        do {
            let app = try await buildApplication(
                enginePool: enginePool,
                metrics: metrics,
                logger: logger,
                authMiddleware: authMiddleware,
                rateLimitMiddleware: rateLimitMiddleware,
                hfToken: hfToken,
                msToken: msToken
            )
            try await app.runService()
        } catch {
            logger.error("Application error: \(error)")
        }

        // 8. Graceful shutdown — runs after runService exits (graceful signal or error)
        rateLimitCleanupTask.cancel()
        gaugeTask.cancel()
        logger.info("Shutdown signal received, draining active sessions...")
        do {
            try await withTimeout(seconds: 30) {
                await enginePool.shutdown()
            }
            logger.info("Engine pool shut down cleanly")
        } catch {
            logger.error("Shutdown error: \(error)")
        }
    }
}

// MARK: - Timeout Wrapper

/// Run an async block with a hard timeout — throws on expiry.
private func withTimeout<R: Sendable>(seconds: Double, block: @escaping @Sendable () async throws -> R) async throws -> R {
    try await withThrowingTaskGroup(of: R.self) { group in
        group.addTask { try await block() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw AppShutdownError("Shutdown timed out after \(seconds)s")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - Application Builder

/// Build the ``Application`` instance with middleware stack and network config.
///
/// Middleware is added to the ``Router`` instance before route registration.
///
/// - Parameters:
///   - enginePool: Shared engine pool actor
///   - metrics: Shared metrics registry
///   - logger: Application logger
///   - authMiddleware: Auth middleware instance
///   - rateLimitMiddleware: Rate limit middleware instance
/// - Returns: Configured Application instance
func buildApplication(
    enginePool: EnginePool,
    metrics: MetricsRegistry,
    logger: Logger,
    authMiddleware: AuthMiddleware<OCoreAIContext>,
    rateLimitMiddleware: RateLimitMiddleware<OCoreAIContext>,
    hfToken: String? = nil,
    msToken: String? = nil
) async throws -> some ApplicationProtocol {
    let router = buildRouter(
        enginePool: enginePool,
        metrics: metrics,
        logger: logger,
        authMiddleware: authMiddleware,
        rateLimitMiddleware: rateLimitMiddleware,
        hfToken: hfToken,
        msToken: msToken
    )
    let host = Environment.get("OCOREAI_HOST") ?? "127.0.0.1"
    let port = Int(Environment.get("OCOREAI_PORT") ?? "8000") ?? 8000

    return Application(
        router: router,
        server: .http1(),
        configuration: .init(address: .hostname(host, port: port)),
        logger: logger
    )
}

// MARK: - Environment Helpers

/// Lightweight environment variable accessor.
enum Environment {
    /// Read an environment variable by key.
    static func get(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    /// Required environment variable — asserts that the key exists and is non-empty.
    static func require(_ key: String, expected: String? = nil) -> String {
        let val = ProcessInfo.processInfo.environment[key] ?? ""
        precondition(!val.isEmpty, "Required environment variable '\(key)' is not set")
        if let expected = expected {
            precondition(val == expected, "Variable '\(key)' expected '\(expected)', got '\(val)'")
        }
        return val
    }
}

// MARK: - Shutdown Error

/// Structured shutdown error implementing ``LocalizedError``.
struct AppShutdownError: Error, LocalizedError, CustomStringConvertible {
    /// Error description string
    let description: String

    init(_ msg: String) {
        self.description = msg
    }

    /// ``LocalizedError`` error description
    var errorDescription: String? { description }
}
