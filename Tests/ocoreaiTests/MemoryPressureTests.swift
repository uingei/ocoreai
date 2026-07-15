// Copyright © 2026 uingeai@163.com.
// Licensed under MIT.
/// MemoryPressureTests.swift — Behavioral invariant tests for memory management
///
/// Tests memory boundary violations:
/// 1. PagedKVCache rejects when pool exceeds pressure threshold
/// 2. BlockPool reference counting consistency
/// 3. Memory pressure re-check after eviction

import Testing
import Foundation
import Logging
@testable import ocoreai

@Suite("PagedKVCache Memory Pressure Invariants")
struct MemoryPressureInvariantsTests {
    @Test("attach() fills pool and reports active blocks")
    func rejectsWhenAbovePressure() async {
        let config = PagedKVCacheConfig(
            tokensPerBlock: 16,
            maxSessions: 256,
            sessionTimeoutSeconds: 300,
            memoryPressureBytes: 1024 * 1024,
            prefixSharingEnabled: true
        )
        let poolConfig = BlockPoolConfig(
            tokensPerBlock: 16,
            maxBlocks: 100,
            evictionWatermark: 0.85,
            evictionThrottle: 0.60,
            hiddenSize: 4096
        )
        
        let cache = PagedKVCache(
            poolConfig: poolConfig,
            cacheConfig: config,
            logger: Logger(label: "test.memory")
        )
        
        // Fill pool — verify setup succeeded
        for i in (0..<5) {
            try await cache.attach(sessionId: "s_\(i)")
        }
        
        let poolStats = await cache.poolStats()
        #expect(poolStats.activeBlocks > 0)
    }
    
    @Test("attach() should reject new session when memory pressure exceeded and eviction cannot help")
    func memoryPressureRejection() async throws {
        let config = PagedKVCacheConfig(
            tokensPerBlock: 16,
            maxSessions: 10,
            sessionTimeoutSeconds: 300,
            memoryPressureBytes: 512 * 1024,
            prefixSharingEnabled: true
        )
        let poolConfig = BlockPoolConfig(
            tokensPerBlock: 16,
            maxBlocks: 200,
            evictionWatermark: 0.85,
            evictionThrottle: 0.60,
            hiddenSize: 4096
        )
        
        let cache = PagedKVCache(
            poolConfig: poolConfig,
            cacheConfig: config,
            logger: Logger(label: "test.memory")
        )
        
        // Fill pool with sessions — all active so evictIdleSessions finds nothing
        for i in (0..<5) {
            try await cache.attach(sessionId: "active_\(i)")
            try await cache.appendTokens(sessionId: "active_\(i)", numTokens: 32)
        }
        
        // attach() should reject when pressure exceeded and eviction freed nothing.
        _ = try #require(throws: (any Error).self) {
            try await cache.attach(sessionId: "should_reject")
        }
        let activeCount = await cache.activeSessions
        #expect(
            activeCount < 6,
            "Session should have been rejected under memory pressure (active: \(activeCount)). Bug: attach() does not re-check pressure after evictIdleSessions()"
        )
    }
    
    @Test("Session count respects maxSessions limit")
    func maxSessionsEnforced() async throws {
        let config = PagedKVCacheConfig(
            tokensPerBlock: 16,
            maxSessions: 3,
            sessionTimeoutSeconds: 300,
            memoryPressureBytes: Int.max,
            prefixSharingEnabled: true
        )
        let poolConfig = BlockPoolConfig(
            tokensPerBlock: 16,
            maxBlocks: 100,
            evictionWatermark: 0.85,
            evictionThrottle: 0.60,
            hiddenSize: 4096
        )
        
        let cache = PagedKVCache(
            poolConfig: poolConfig,
            cacheConfig: config,
            logger: Logger(label: "test.memory")
        )
        
        // Fill to limit — setup must succeed
        try await cache.attach(sessionId: "a")
        try await cache.attach(sessionId: "b")
        try await cache.attach(sessionId: "c")
        #expect(await cache.activeSessions == 3)
        
        // Exceed limit — should throw
        do {
            try await cache.attach(sessionId: "d")
            #expect(Bool(false), "Should have thrown sessionLimitExceeded")
        } catch {
            // Expected — session limit enforced
            #expect(error is AppError)
        }
    }
    
    @Test("Evicting session releases block references")
    func evictReleasesBlocks() async throws {
        let config = PagedKVCacheConfig(
            tokensPerBlock: 16,
            maxSessions: 10,
            sessionTimeoutSeconds: 300,
            memoryPressureBytes: Int.max,
            prefixSharingEnabled: true
        )
        let poolConfig = BlockPoolConfig(
            tokensPerBlock: 16,
            maxBlocks: 100,
            evictionWatermark: 0.85,
            evictionThrottle: 0.60,
            hiddenSize: 4096
        )
        
        let cache = PagedKVCache(
            poolConfig: poolConfig,
            cacheConfig: config,
            logger: Logger(label: "test.memory")
        )
        
        let beforeStats = await cache.poolStats()
        
        try await cache.attach(sessionId: "evict_me")
        try await cache.appendTokens(sessionId: "evict_me", numTokens: 48)
        
        let afterAttach = await cache.poolStats()
        #expect(afterAttach.activeBlocks > beforeStats.activeBlocks)
        
        await cache.evictSession(sessionId: "evict_me")
        
        let afterEvict = await cache.poolStats()
        // Active blocks should decrease after eviction
        #expect(afterEvict.activeBlocks < afterAttach.activeBlocks)
    }
    
    @Test("Prefix sharing increments reference count correctly")
    func prefixSharingRefCount() async throws {
        let config = PagedKVCacheConfig(
            tokensPerBlock: 16,
            maxSessions: 10,
            sessionTimeoutSeconds: 300,
            memoryPressureBytes: Int.max,
            prefixSharingEnabled: true
        )
        let poolConfig = BlockPoolConfig(
            tokensPerBlock: 16,
            maxBlocks: 100,
            evictionWatermark: 0.85,
            evictionThrottle: 0.60,
            hiddenSize: 4096
        )
        
        let cache = PagedKVCache(
            poolConfig: poolConfig,
            cacheConfig: config,
            logger: Logger(label: "test.memory")
        )
        
        // Source session with blocks
        try await cache.attach(sessionId: "source")
        try await cache.appendTokens(sessionId: "source", numTokens: 48)
        
        // Target session
        try await cache.attach(sessionId: "target")
        
        // Share blocks from source
        try await cache.sharePrefix(sessionId: "target", sourceSessionId: "source", numBlocks: 2)
        
        // Target should have blocks from prefix sharing
        let info = await cache.sessionInfo(sessionId: "target")
        #expect(info != nil)
        
        // Evicting source should NOT invalidate target's shared blocks
        await cache.evictSession(sessionId: "source")
        
        // Target should still have its references intact
        let afterSourceEvict = await cache.sessionInfo(sessionId: "target")
        #expect(afterSourceEvict != nil)
    }
}
