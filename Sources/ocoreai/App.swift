// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// App.swift — oCoreAI entry point, service lifecycle, and graceful shutdown
///
/// ### Startup Sequence:
/// 1. Initialize ``TokenizerManager``
/// 2. Create ``SchedulerActor`` (priority queue + OOMGuard)
/// 3. Create ``EnginePool`` (config-driven)
/// 4. Initialize ``MetricsRegistry`` (Prometheus-compatible)
/// 5. Build ``Application`` with ``AuthMiddleware`` + ``RateLimitMiddleware`` + Metrics
/// 6. Start gauge update task (active sessions / loaded models)
///
/// ### Shutdown Sequence:
/// - Signal → cancel gauge task → drain active inference sessions → release GPU/SSD cache → exit
/// - Hard timeout of 30 seconds prevents hung shutdown

import Foundation
import Hummingbird
import Logging
import ServiceLifecycle
#if mlx
	import MLX
#endif

// MARK: - Shared Engine Lifecycle (Unified for CLI + GUI)

/// Manages the inference engine, HTTP server, and graceful shutdown.
/// Safe to call from CLI main() or SwiftUI AppDelegate.
///
/// ### Dual-Channel Architecture:
/// - **Fast Path (UI):** SwiftUI views read ``enginePool`` / ``scheduler`` / ``sessionCompressor``
///   directly — zero HTTP serialization, ``AsyncStream``-driven streaming.
/// - **Bridge Path (External):** HTTP server on localhost:8080 for third-party agents.
///   Opt-in only; disabled by default for App Store compliance.
///
/// ### Lifecycle State Machine:
/// - 6-state machine (idle → starting → ready/degraded → stopping → idle)
/// - Circuit breaker prevents crash-loop (3 failures → cooldown 60s)
/// - Port conflict detection before HTTP server binding
@MainActor
public final class OcoreaiEngine {
	public static let shared = OcoreaiEngine()

	/// Lifecycle state machine — replaces `isRunning` + `engineReady` booleans
	private(set) var lifecycleState: EngineLifecycleState = .idle {
		didSet {
			logger.debug("Lifecycle: \\(oldValue) → \\(lifecycleState)")
		}
	}

	/// Backward-compatible alias — SwiftUI consumers still read `isRunning` for guard clauses
	var isRunning: Bool { lifecycleState != .idle && lifecycleState != .error }

	/// Backward-compatible alias — SwiftUI consumers still read `engineReady` for guard clauses
	var engineReady: Bool { lifecycleState.isHealthy }

	private var serverApp: (any ApplicationProtocol)?
	private var gaugeTask: Task<Void, Never>?
	private var cleanupTask: Task<Void, Never>?

	/// HTTP server task — tracked so stop() can cancel it.
	private var serverTask: Task<Void, Never>?

	/// Circuit breaker — prevents crash-loop by tracking consecutive startup failures
	private let circuitBreaker = EngineCircuitBreaker(
		maxConsecutiveFailures: 3,
		cooldownSeconds: 60
	)

	// MARK: - Public Accessors (Fast Path for SwiftUI)

	/// Direct accessor to the engine pool — SwiftUI UI bypasses HTTP entirely.
	var activeEnginePool: EnginePool? {
		enginePool
	}

	/// Direct accessor to the scheduler — SwiftUI can submit low-priority tasks.
	var activeScheduler: SchedulerActor? {
		scheduler
	}

	/// Direct accessor to session compressor — SwiftUI can persist/recall memory.
	var activeSessionCompressor: SessionCompressor? {
		_sessionCompressor
	}

	/// Direct accessor to system prompt builder — SwiftUI can build context.
	var activeSystemPromptBuilder: SystemPromptBuilder? {
		_systemPromptBuilder
	}

	/// Direct accessor to message builder — SwiftUI can assemble inference context.
	var activeMessageBuilder: MessageBuilder? {
		_messageBuilder
	}

	/// Direct accessor to the metrics registry — SwiftUI reads real-time metrics.
	var activeMetrics: MetricsRegistry? {
		metrics
	}

	/// Direct accessor to skill registry — SwiftUI can list/add/remove skills.
	var activeSkillRegistry: SkillRegistry? {
		_skillRegistry
	}

	/// Direct accessor to MCP bridge — SwiftUI can inspect external MCP servers.
	var activeMCPBridge: MCPBridge? {
		_mcpBridge
	}

	/// Direct accessor to tool registry — SwiftUI can list registered tools.
	var activeToolRegistry: ToolRegistry? {
		_toolRegistry
	}

	/// Direct accessor to audit trail — SwiftUI can browse tool call history.
	var activeAuditTrail: AuditTrail? {
		_auditTrail
	}

	/// Direct accessor to ContentGuard — safety filter for both paths.
	var activeContentGuard: ContentGuard? {
		_contentGuard
	}

	/// Direct accessor to complexity analyzer — SwiftUI can show reasoning depth.
	var activeComplexityAnalyzer: ComplexityAnalyzer? {
		_complexityAnalyzer
	}

	/// Direct accessor to thinking budget — SwiftUI can show thinking token status.
	var activeThinkingBudget: ThinkingBudget? {
		_thinkingBudget
	}

	private(set) var enginePool: EnginePool?
	private var _sessionCompressor: SessionCompressor?
	private var _systemPromptBuilder: SystemPromptBuilder?
	private var _messageBuilder: MessageBuilder?
	private(set) var metrics: MetricsRegistry?
	private(set) var scheduler: SchedulerActor?
	private var _skillRegistry: SkillRegistry?
	private var _mcpBridge: MCPBridge?
	private var _toolRegistry: ToolRegistry?
	private var _auditTrail: AuditTrail?
	private var _complexityAnalyzer: ComplexityAnalyzer?
	private var _thinkingBudget: ThinkingBudget?
	private var _contentGuard: ContentGuard?
	
	/// Config system — loaded at startup, hot-reload capable
	private var configSystem: ConfigSystem?
	/// Config snapshot — set on start, updated on hot-reload. Reads are same-actor.
	private var _configSnapshot: AppConfig = AppConfig()

	private let logger: Logger

	private init() {
		logger = Logger(label: "ocoreai")
	}

	/// Signal a startup failure — records failure in circuit breaker, transitions state.
	/// Call from any early-return path in `start()`.
	private func failStartup(_ message: String) {
		circuitBreaker.recordFailure()
		if circuitBreaker.isCircuitOpen {
			lifecycleState = .error
			logger.critical("Circuit breaker OPEN after \(circuitBreaker.failureCount) consecutive failures")
		} else {
			lifecycleState = .idle
		}
		logger.critical("Startup failed: \(message) — failures: \(circuitBreaker.failureCount)/\(circuitBreaker.maxFailures)")
	}

	/// Boot the engine core components (always runs) + optional HTTP server.
	///
	/// Fast Path components (EnginePool, Scheduler, SessionCompressor) are always
	/// initialized — SwiftUI views connect directly via `activeEnginePool` etc.
	///
	/// Bridge Path (HTTP server) is opt-in: disabled by default for App Store builds.
	/// Override via `OCOREAI_ENABLE_HTTP=1` environment variable or omit `#if appStore` trait.
	///
	/// Circuit breaker: if 3 consecutive startups fail, the circuit opens for 60s.
	/// Call `resetCircuitBreaker()` to unblock.
	public func start() async {
		// Lifecycle gate — prevent concurrent startup or restart while running/stopping
		guard lifecycleState != .starting && lifecycleState != .stopping else {
			if lifecycleState.isHealthy {
				logger.warning("Engine already running (state: \(lifecycleState))")
			} else {
				logger.warning("Engine startup blocked (state: \(lifecycleState))")
			}
			return
		}

		// Circuit breaker gate
		guard circuitBreaker.allowStart() else {
			let remaining = circuitBreaker.cooldownRemaining()
			logger.error("Circuit breaker open — startup blocked for \(remaining)s")
			lifecycleState = .error
			return
		}

		lifecycleState = .starting
		logger.info("oCoreAI booting...")

		let physicalMem = ModelConfigEntry.detectPhysicalMemory()
		let memBudget = ModelConfigEntry.computeMemoryBudget(physicalMemory: physicalMem)
		logger.info("Hardware: \(physicalMem / 1_073_741_824) GB RAM, budget: \(memBudget / 1_073_741_824) GB")

		// Set MLX memory cache limit early — prevents unbounded GPU memory growth
		#if mlx
			Memory.cacheLimit = Int(memBudget)
		#endif

		// Read hub tokens early — needed by BOTH Fast Path (UI) and Bridge Path (HTTP)
		// Must happen before EnginePool init so MLXModelLoader has the token for MS downloads
		// NOTE: ProcessInfo.setValue(forKey:) uses KVC, NOT environment vars — custom keys
		// throw NSUnknownKeyException. Tokens are passed via constructor chain instead.
		// Priority: env var > UserDefaults (persisted from Settings UI)
		let msToken: String? = ProcessInfo.processInfo.environment["MODELSCOPE_TOKEN"]
			?? UserDefaults.standard.string(forKey: "settings.hub.modelScopeToken")
		let hfToken: String? = ProcessInfo.processInfo.environment["HF_TOKEN"]
			?? UserDefaults.standard.string(forKey: "settings.hub.hfToken")

		let oomGuard = OOMGuard(log: logger)
		let memoryTracker = MemoryTracker(
			budgetBytes: memBudget,
			oomGuard: oomGuard,
			log: logger,
		)
		await memoryTracker.setOOMCallback { level in
			await oomGuard.respond(to: level)
		}

		var sqliteStore: SQLiteStore?
		do {
			sqliteStore = SQLiteStore()
			try await sqliteStore?.open()
			if let path = sqliteStore?.dbPathDescription {
				logger.info("SQLiteStore opened at: \(path)")
			}
		} catch {
			failStartup("SQLiteStore failed to open: \(error)")
			return
		}

		guard let store = sqliteStore else {
			failStartup("SQLiteStore initialization returned nil")
			return
		}

		let fts5Search = FTS5Search(store: store)

		// MARK: - Config System (YAML + env override + hot-reload)

		configSystem = await ConfigSystem.create()
		_configSnapshot = await configSystem?.get() ?? AppConfig()
		await configSystem?.startWatching()
		logger.info("ConfigSystem ready — snapshot loaded from \(configPath)")

		_skillRegistry = SkillRegistry(log: logger)
		_systemPromptBuilder = SystemPromptBuilder(
			basePrompt: "You are oCoreAI, an intelligent assistant running on macOS.",
		)
		do {
			try await _skillRegistry?.bootstrap(
				skillsDir: nil,
				systemPromptBuilder: _systemPromptBuilder!,
			)
			logger.info("SkillRegistry bootstrapped")
		} catch {
			logger.warning("SkillRegistry bootstrap failed: \\(error)")
		}

		// Wire SkillRegistry → SystemPromptBuilder bidirectional link
		// (bootstrap sets SkillRegistry.systemPromptBuilder; this sets the reverse)
		guard let skillRegistry = _skillRegistry,
			  let systemPromptBuilder = _systemPromptBuilder else {
			failStartup("Core components not initialized")
			return
		}
		await systemPromptBuilder.setRegistry(skillRegistry)

		_auditTrail = AuditTrail()
		guard let auditTrail = _auditTrail else { return failStartup("Failed to create audit trail") }
		_toolRegistry = ToolRegistry(auditTrail: auditTrail)

		// Bootstrap built-in tools (info, skills_list, skills_lookup, echo)
		guard let toolRegistry = _toolRegistry else { return failStartup("Failed to create tool registry") }
		guard let skRegistry = _skillRegistry else { return failStartup("Skill registry unavailable") }
		await bootstrapBuiltInTools(
			registry: toolRegistry,
			skillRegistry: skRegistry,
		)
		let mcpTransport = MCPStdioTransport(log: logger)
		_mcpBridge = MCPBridge(
			toolRegistry: toolRegistry,
			transport: mcpTransport,
		)

		let tokenizerManager = TokenizerManager()

		// MARK: - Scheduler Layer (Priority queue + OOM protection)

		scheduler = SchedulerActor(
			maxQueueSize: 128,
			memoryTracker: memoryTracker,
			oomGuard: oomGuard,
			log: logger,
		)

		let coreAILoadingConfig = CoreAILoadingConfig.production

		// Build engine config from ConfigSystem (or fallback to hard-coded defaults)
		let engineConfig = EnginePoolConfig(from: _configSnapshot, logger: logger)

		enginePool = EnginePool(
			config: engineConfig,
			logger: logger,
			tokenizerManager: tokenizerManager,
			pagedKVCacheConfig: .default,
			blockPoolConfig: .default,
			coreAILoadingConfig: coreAILoadingConfig,
			memoryTracker: memoryTracker,
			modelScopeToken: msToken,
			hfToken: hfToken,
		)
		// Build LLM summarizer callback for session compression
		_sessionCompressor = SessionCompressor(
			store: store,
			fts: fts5Search,
		)

		// MARK: - Complexity + Thinking Budget (for Fast Path + Bridge Path)

		_complexityAnalyzer = ComplexityAnalyzer()
		_thinkingBudget = ThinkingBudget()

		// MARK: - ContentGuard (safety filter from config)

		_contentGuard = ContentGuard(runtimeConfig: .init(from: _configSnapshot.safety))
		logger.info("ContentGuard initialized (safety filter active)")

		// MARK: - MessageBuilder (shared by Fast Path + Bridge Path)

		// guard: all components initialized above, safe to unwrap in normal flow
		guard let mbSystemPrompt = _systemPromptBuilder,
			  let mbCompressor = _sessionCompressor,
			  let mbAnalyzer = _complexityAnalyzer,
			  let mbBudget = _thinkingBudget else {
			failStartup("Core components not ready for MessageBuilder")
			return
		}
		_messageBuilder = MessageBuilder(
			systemPromptBuilder: mbSystemPrompt,
			sessionCompressor: mbCompressor,
			complexityAnalyzer: mbAnalyzer,
			thinkingBudget: mbBudget,
		)

		// MARK: - Summarizer (LLM-driven session compression)

		// SummarizerActor bridges SessionCompressor ↔ EnginePool without circular dependency.
		// Installed lazily — compression before install uses rule-based fallback.
		guard let saPool = enginePool,
			  let saBuilder = _messageBuilder else {
			failStartup("Engine / builder not ready for SummarizerActor")
			return
		}
		let summarizer = SummarizerActor(
			enginePool: saPool,
			messageBuilder: saBuilder,
			config: .default,
			log: logger,
		)
		await _sessionCompressor?.setSummarizer(summarizer.makeCallback())
		logger.info("SessionCompressor: LLM summarizer injected via SummarizerActor")

		metrics = MetricsRegistry()

		// MARK: - Fast Path Ready Signal

		// Engine core is now fully initialized. UI can start using direct accessors
		// even before (or without) the HTTP server starting.
		circuitBreaker.recordSuccess()
		lifecycleState = .ready
		logger.info("Engine core ready — Fast Path available for UI")

		// MARK: - Bridge Path: HTTP Server (opt-out via appStore trait)

		#if appStore
			logger.info("App Store build — Bridge Path (HTTP) disabled")
		#else
			logger.info("Development build — Bridge Path (HTTP) enabled")
			startHTTPServer()
		#endif
	}

	// MARK: - HTTP Server (Bridge Path, optional)

	/// Detect if a process is binding the given port. Uses /dev/tcp as a lightweight
	/// check (no shell dependency) — if the socket connects, something is listening.
	private static func isPortInUse(_ port: Int) -> Bool {
		let pipe = Pipe()
		let task = Process()
		task.launchPath = "/usr/sbin/lsof"
		task.arguments = ["-i:\(port)", "-sTCP:LISTEN", "-Fp"]
		task.standardOutput = pipe
		task.launch()
		task.waitUntilExit()
		let data = try? pipe.fileHandleForReading.readToEnd()
		let output = String(data: data ?? Data(), encoding: .utf8) ?? ""
		return !output.isEmpty
	}

	private func startHTTPServer() {
		guard let enginePool, let scheduler, let metrics,
			      let sessionCompressor = _sessionCompressor,
			      let systemPromptBuilder = _systemPromptBuilder,
			      let messageBuilder = _messageBuilder,
			      let mcpBridge = _mcpBridge,
			      let _ = _auditTrail,
			      let _ = _toolRegistry
		else { return }

		// Port conflict detection — refuse silent bind failures
		let serverPort = Int(ProcessInfo.processInfo.environment["OCOREAI_PORT"] ?? "8080") ?? 8080
		if Self.isPortInUse(serverPort) {
			logger.warning("Port \(serverPort) already in use — Bridge Path (HTTP) skipped")
			lifecycleState = .degraded
			return
		}

		let rateLimitProvider = RateLimitProvider(
			config: .init(
				globalRate: 200, globalBurst: 300,
				perModelRate: 30, perModelBurst: 45,
				perIPRate: 20, perIPBurst: 30,
				enabled: true,
			),
			logger: logger,
		)
		let authMiddleware = AuthMiddleware<OCoreAIContext>(config: .default, logger: logger)
		let rateLimitMiddleware = RateLimitMiddleware<OCoreAIContext>(
			provider: rateLimitProvider,
			logger: logger,
		)

		cleanupTask = Task {
			_ = await rateLimitProvider.cleanupPeriodically()
		}

		gaugeTask = Task {
			while !Task.isCancelled {
				do {
					try await Task.sleep(nanoseconds: 10_000_000_000)
				} catch { break }

				let summary = await enginePool.engineSummary()
				await metrics.updateActiveSessions(summary.activeSessions)
				await metrics.updateLoadedModels(summary.loadedModels)
				await metrics.updateKVGpuBytes(Int(summary.gpuCacheGB * 1_073_741_824))
			}
		}

		let hfToken = ProcessInfo.processInfo.environment["HF_TOKEN"]
			?? UserDefaults.standard.string(forKey: "settings.hub.hfToken")
		let msToken = ProcessInfo.processInfo.environment["MODELSCOPE_TOKEN"]
			?? UserDefaults.standard.string(forKey: "settings.hub.modelScopeToken")

		Task {
			do {
				let app = try await buildApplication(
					enginePool: enginePool,
					scheduler: scheduler,
					metrics: metrics,
					sessionCompressor: sessionCompressor,
					mcpBridge: mcpBridge,
					systemPromptBuilder: systemPromptBuilder,
					messageBuilder: messageBuilder,
					logger: logger,
					authMiddleware: authMiddleware,
					rateLimitMiddleware: rateLimitMiddleware,
					hfToken: hfToken,
					msToken: msToken,
				)
				self.serverApp = app

				let serverHost = ProcessInfo.processInfo.environment["OCOREAI_HOST"] ?? "127.0.0.1"
				let serverPort = ProcessInfo.processInfo.environment["OCOREAI_PORT"] ?? "8080"
				// Track server task so stop() can cancel it during shutdown
				self.serverTask = Task.detached(priority: .utility) {
					do {
						try await app.runService()
					} catch {
						Logger(label: "ocoreai").error("Server crashed: \(error)")
					}
				}

				logger.info("Engine booted on \(serverHost):\(serverPort)")
			} catch {
				logger.error("Application build error: \(error)")
			}
		}
	}

	/// Graceful shutdown
	public func stop() async {
		guard lifecycleState.isHealthy || lifecycleState.isTransitioning else {
			logger.warning("Engine not running (state: \(lifecycleState))")
			return
		}

		lifecycleState = .stopping

		serverTask?.cancel()
		cleanupTask?.cancel()
		gaugeTask?.cancel()

		logger.info("Shutdown signal received, draining active sessions...")

		do {
			try await withTimeout(seconds: 30) { [weak self] in
				guard let self else { return }
				await enginePool?.shutdown()
			}
			logger.info("Engine pool shut down cleanly")
		} catch {
			logger.error("Shutdown error: \(error)")
		}

		serverApp = nil
		enginePool = nil
		metrics = nil
		scheduler = nil

		// MARK: - Config cleanup

		await configSystem?.stopWatching()
		configSystem?.shutdown()
		self.configSystem = nil

		lifecycleState = .idle
		logger.info("oCoreAI shut down complete")
	}
}

// MARK: - Timeout Wrapper

private func withTimeout<R: Sendable>(seconds: Double, block: @escaping @Sendable () async throws -> R) async throws -> R {
	try await withThrowingTaskGroup(of: R.self) { group in
		group.addTask { try await block() }
		group.addTask {
			try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
			throw AppShutdownError("Shutdown timed out after \(seconds)s")
		}
		guard let result = try await group.next() else {
			throw AppShutdownError("Shutdown timed out after \(seconds)s")
		}
		group.cancelAll()
		return result
	}
}

// MARK: - Application Builder

func buildApplication(
	enginePool: EnginePool,
	scheduler: SchedulerActor,
	metrics: MetricsRegistry,
	sessionCompressor: SessionCompressor,
	mcpBridge: MCPBridge,
	systemPromptBuilder: SystemPromptBuilder,
	messageBuilder: MessageBuilder,
	logger: Logger,
	authMiddleware: AuthMiddleware<OCoreAIContext>,
	rateLimitMiddleware: RateLimitMiddleware<OCoreAIContext>,
	hfToken: String? = nil,
	msToken: String? = nil,
) async throws -> some ApplicationProtocol {
	let router = buildRouter(
		enginePool: enginePool,
		scheduler: scheduler,
		metrics: metrics,
		sessionCompressor: sessionCompressor,
		mcpBridge: mcpBridge,
		systemPromptBuilder: systemPromptBuilder,
		messageBuilder: messageBuilder,
		logger: logger,
		authMiddleware: authMiddleware,
		rateLimitMiddleware: rateLimitMiddleware,
		hfToken: hfToken,
		msToken: msToken,
	)
	let host = ProcessInfo.processInfo.environment["OCOREAI_HOST"] ?? "127.0.0.1"
	let port = Int(ProcessInfo.processInfo.environment["OCOREAI_PORT"] ?? "8080") ?? 8080

	return Application(
		router: router,
		server: .http1(),
		configuration: .init(address: .hostname(host, port: port)),
		logger: logger,
	)
}

struct AppShutdownError: Error, LocalizedError, CustomStringConvertible {
	let description: String
	init(_ msg: String) {
		description = msg
	}

	var errorDescription: String? {
		description
	}
}
