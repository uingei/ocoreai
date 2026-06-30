// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EngineConfigTests.swift — Engine pool configuration defaults from ConfigSystem
///
/// Coverage:
/// - EnginePoolConfig.default values
/// - AppConfig → EnginePoolConfig mapping with valid config
/// - nil AppConfig falls back to defaults (graceful degradation)

import Testing
import Logging
@testable import ocoreai

@Suite("EnginePoolConfig Defaults")
struct EngineConfigTests {
    
    @Test("default config has sane production values")
    func defaultConfig() {
        let config = EnginePoolConfig.default
        #expect(config.maxConcurrentSessions == 8)
        #expect(config.maxQueueSize == 32)
        #expect(config.warmupTokens == 4)
        #expect(config.inferenceTimeoutSeconds == 180)
        #expect(config.kvCacheConfig == nil)
        #expect(config.sessionPoolConfig != nil)
    }
    
    @Test("nil AppConfig falls back to defaults")
    func nilAppConfigFallsBack() {
        let logger = Logger(label: "test.config")
        let config = EnginePoolConfig(from: nil, logger: logger)
        #expect(config.maxConcurrentSessions == 8)
        #expect(config.maxQueueSize == 32)
        #expect(config.defaultModelId == EnginePoolConfig.default.defaultModelId)
    }
    
    @Test("AppConfig backend values respected")
    func fromValidAppConfig() {
        let appConfig = AppConfig()
        let logger = Logger(label: "test.config")
        let config = EnginePoolConfig(from: appConfig, logger: logger)
        // Backend values from AppConfig must map correctly
        #expect(config.maxConcurrentSessions >= 1)
        #expect(config.maxQueueSize > 0)
        #expect(config.warmupTokens == 4)
        #expect(config.inferenceTimeoutSeconds == 180)
    }
}
