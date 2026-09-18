// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ConfigSystem.swift — YAML config loader, saver, and hot-reload watcher
///
/// Responsibilities:
///   - Load ~/.ocoreai/config.yaml at startup
///   - Save changes back to disk
///   - Watch for file changes and emit reload events
///   - Environment variable override chain (OCOREAI_*)
///   - Default config generation on first run

import Foundation
import Logging
import Yams

/// File path for the config file.
let configDir = "\(NSHomeDirectory())/.ocoreai"
let configPath = "\(configDir)/config.yaml"

/// Environment variable prefix for overrides.
let envPrefix = "OCOREAI_"

// MARK: - ConfigSystem Actor

/// Shared configuration singleton with hot-reload support.
/// All config reads go through this actor — caller gets a Sendable copy.
actor ConfigSystem {
    private var config: AppConfig
    private let logger: Logger
    private var watcherTask: Task<Void, Never>?

    // MARK: - Init

    /// Create config system, load or generate default, validate.
    ///
    /// Failure order (hermes `de2d6a1b93` pattern — never clobber the user's file):
    ///   1. corrupt `configPath` → restore last-known-good snapshot if usable;
    ///   2. no usable snapshot     → generate defaults (fresh install only).
    static func create() async -> ConfigSystem {
        let system = ConfigSystem(config: AppConfig(), logger: Logger(label: "ocoreai.config"))
        do {
            if await system.load() {
                system.logger.info("Config loaded from \(configPath)")
            } else if let recovered = ConfigRecovery.restoreLastGood(
                forCorruptFileAt: configPath, logger: system.logger
            ) {
                await system.adopt(recovered)
            } else {
                try await system.saveDefault()
                system.logger.info("Default config generated at \(configPath)")
            }
        } catch {
            system.logger.warning("Config load/save failed: \(error) — using defaults")
        }
        return system
    }

    private init(config: AppConfig, logger: Logger) {
        self.config = config
        self.logger = logger
    }

    // MARK: - Load

    /// Read config from disk. Returns true if file exists and was parsed.
    func load() async -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: configPath) else { return false }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            guard let loaded = try? decodeVerifiedConfig(from: data) else {
                logger.warning("YAML did not decode to AppConfig")
                return false
            }
            var configCopy = loaded
            configCopy.applyEnvOverrides()
            try configCopy.validate()
            config = configCopy
            // Last-known-good snapshot (hermes `de2d6a1b93`): every successful
            // parse+validate leaves a recoverable copy for the next startup.
            try? ConfigRecovery.snapshotGood(fileAt: configPath, logger: logger)
            return true
        } catch {
            logger.warning("Config parse error: \(error)")
            return false
        }
    }

    /// Adopt an already-decoded+validated config (recovery path from
    /// `ConfigRecovery.restoreLastGood`).
    func adopt(_ adopted: AppConfig) {
        config = adopted
        do {
            try ConfigRecovery.snapshotGood(fileAt: configPath, logger: logger)
        } catch {
            logger.warning("Recovery snapshot failed: \(error)")
        }
    }

    // MARK: - Save

    /// Write current config to disk.
    /// After the write, the on-disk file is round-trip verified (decode +
    /// validate) — an unverified write must not refresh the last-known-good
    /// snapshot (hermes `de2d6a1b93`: the `good` copy is only ever a known-good
    /// parse).
    func save() async throws {
        let yaml = try YAMLEncoder().encode(config)
        try yaml.write(to: URL(fileURLWithPath: configPath), atomically: true, encoding: .utf8)
        ConfigRecovery.verifyAndSnapshot(newFileAt: configPath, logger: logger)
        logger.info("Config saved to \(configPath)")
    }

    /// Generate and save default config on first run.
    func saveDefault() async throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: configDir) {
            try fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        config = AppConfig()
        try await save()
    }

    // MARK: - Access

    /// Get current config (snapshot).
    func get() -> AppConfig {
        config
    }

    /// Update a specific section.
    func updateServer(_ section: ServerConfig) async {
        config.server = section
        try? await save()
    }

    func updateBackend(_ section: BackendConfig) async {
        config.backend = section
        try? await save()
    }

    func updateMemory(_ section: MemoryConfig) async {
        config.memory = section
        try? await save()
    }

    func updateMetrics(_ section: MetricsConfig) async {
        config.metrics = section
        try? await save()
    }

    func updateModel(_ id: String, entry: ModelConfigEntry) async {
        config.models[id] = entry
        try? await save()
    }

    // MARK: - Watch

    /// Start file watcher — poll-based, reloads if file changes.
    func startWatching() {
        stopWatching()
        logger.info("Config file watcher started")
        watcherTask = Task(priority: .utility) {
            var lastMod: TimeInterval? = self.configFileModificationDate()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                let current = self.configFileModificationDate()
                guard let current, let previous = lastMod, current > previous else { continue }
                lastMod = current
                if await self.load() {
                    logger.info("Config hot-reloaded from disk")
                }
            }
        }
    }

    func stopWatching() {
        watcherTask?.cancel()
        watcherTask = nil
    }

    nonisolated func shutdown() {
        logger.info("ConfigSystem shut down")
    }

    private func configFileModificationDate() -> TimeInterval? {
        (try? FileManager.default.attributesOfItem(atPath: configPath)[.modificationDate])
            as? TimeInterval
    }
}

// MARK: - Environment Override

extension AppConfig {
    /// Apply OCOREAI_* environment variable overrides (higher priority than YAML).
    mutating func applyEnvOverrides() {
        if let h = ProcessInfo.processInfo.environment["\(envPrefix)HOST"] {
            server.host = h
        }
        if let p = ProcessInfo.processInfo.environment["\(envPrefix)PORT"],
            let port = Int(p), (1 ... 65535).contains(port)
        {
            server.port = port
        }
        if let b = ProcessInfo.processInfo.environment["\(envPrefix)BACKEND"] {
            backend.preference = [b.lowercased()]
        }
        if let m = ProcessInfo.processInfo.environment["\(envPrefix)MAX_SESSIONS"],
            let v = Int(m), v > 0
        {
            backend.maxConcurrentSessions = v
        }
        if let p = ProcessInfo.processInfo.environment["\(envPrefix)APPROVAL_POLICY"],
            ApprovalPolicy(rawValue: p) != nil
        {
            agent.approvalPolicy = p.lowercased()
        }
        if let dm = ProcessInfo.processInfo.environment["\(envPrefix)DEFAULT_MODEL"],
            var entry = models["default"]
        {
            entry.modelId = dm
            models["default"] = entry
        }
        if ProcessInfo.processInfo.environment["\(envPrefix)MEMORY_ENABLED"] == "false" {
            memory.enabled = false
        }
    }
}
