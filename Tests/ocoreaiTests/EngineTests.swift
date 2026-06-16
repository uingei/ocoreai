// EngineTests.swift — Struct-level unit tests for EngineManager types
//
// Tests configuration validation, event type correctness, and struct defaults.
// Does NOT require CoreAI runtime — all types are trait-independent.

@testable import ocoreai
import Foundation
import XCTest

// MARK: - EnginePoolConfig Tests

final class EnginePoolConfigTests: XCTestCase {

    func test_defaultConfigIsReasonable() {
        let config = EnginePoolConfig.default
        XCTAssertGreaterThan(config.maxConcurrentSessions, 0, "maxConcurrentSessions must be positive")
        XCTAssertGreaterThan(config.maxQueueSize, 0, "maxQueueSize must be positive")
        XCTAssertGreaterThan(config.warmupTokens, 0, "warmupTokens must be positive")
    }

    func test_configMutatesCorrectly() {
        var config = EnginePoolConfig.default
        config.maxConcurrentSessions = 16
        config.maxQueueSize = 64
        config.warmupTokens = 8
        config.kvCacheConfig = nil
        XCTAssertEqual(config.maxConcurrentSessions, 16)
        XCTAssertEqual(config.maxQueueSize, 64)
        XCTAssertEqual(config.warmupTokens, 8)
    }

    func test_customConfig() throws {
        let config = EnginePoolConfig(
            maxConcurrentSessions: 4,
            maxQueueSize: 16,
            modelConfigPath: "/tmp/models/config.json",
            modelDirectory: "/tmp/models",
            warmupTokens: 2,
            kvCacheConfig: nil
        )
        XCTAssertEqual(config.maxConcurrentSessions, 4)
        XCTAssertEqual(config.maxQueueSize, 16)
        XCTAssertEqual(config.warmupTokens, 2)
        XCTAssertNil(config.kvCacheConfig)
    }
}

// MARK: - InferenceEvent Tests

final class InferenceEventTests: XCTestCase {

    func test_tokenEvent() {
        let event = InferenceEvent(kind: .token(42))
        switch event.kind {
        case .token(let id):
            XCTAssertEqual(id, 42)
        default:
            XCTFail("Expected token event")
        }
    }

    func test_doneEventWithReason() {
        let event = InferenceEvent(kind: .done("stop" as String))
        switch event.kind {
        case .done(let reason):
            XCTAssertEqual(reason, "stop")
        default:
            XCTFail("Expected done event")
        }
    }

    func test_doneEventNil() {
        // done with nil reason is valid
        let event = InferenceEvent(kind: .done(nil as String?))
        switch event.kind {
        case .done(let reason):
            XCTAssertNil(reason)
        default:
            XCTFail("Expected done event")
        }
    }

    func test_errorEvent() {
        let message = "GPU out of memory"
        let event = InferenceEvent(kind: .error(message))
        switch event.kind {
        case .error(let msg):
            XCTAssertEqual(msg, message)
        default:
            XCTFail("Expected error event")
        }
    }
}
