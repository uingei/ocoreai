// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// BlockPoolTests.swift — Paged KV Cache: config, KVBlock, BlockTable value types.
///
/// Actor tests are in BlockPoolActorTests.swift.

import Testing
import Foundation
import Logging
@testable import ocoreai

@Suite("BlockPoolConfig Defaults")
struct BlockPoolConfigTests {
    @Test("default config has reasonable values")
    func defaults_() {
        let cfg = BlockPoolConfig.default
        #expect(cfg.tokensPerBlock == 16)
        #expect(cfg.maxBlocks == 65536)
        #expect(cfg.evictionWatermark == 0.85)
        #expect(cfg.evictionThrottle == 0.60)
        #expect(cfg.hiddenSize == 4096)
    }

    @Test("custom config preserves values")
    func customConfig() {
        let cfg = BlockPoolConfig(tokensPerBlock: 32, maxBlocks: 1000,
                                  evictionWatermark: 0.9, evictionThrottle: 0.7, hiddenSize: 8192)
        #expect(cfg.tokensPerBlock == 32)
        #expect(cfg.maxBlocks == 1000)
        #expect(cfg.hiddenSize == 8192)
    }
}

@Suite("KVBlock Lifecycle")
struct KVBlockTests {
    @Test("new block has correct initial state")
    func newBlock_() {
        let b = KVBlock(blockId: 1, estimatedBytes: 1024)
        #expect(b.refCount == 0)
        #expect(b.tokensUsed == 0)
        #expect(b.estimatedBytes == 1024)
    }

    @Test("addTokens increments and caps at capacity")
    func addTokens_() {
        var b = KVBlock(blockId: 1, estimatedBytes: 1024)
        b.addTokens(5, capacity: 16); #expect(b.tokensUsed == 5)
        b.addTokens(12, capacity: 16); #expect(b.tokensUsed == 16)
    }

    @Test("isFull returns correct state")
    func isFull_() {
        var b = KVBlock(blockId: 1, estimatedBytes: 1024)
        #expect(!b.isFull(capacity: 16))
        b.addTokens(16, capacity: 16); #expect(b.isFull(capacity: 16))
    }

    @Test("remainingCapacity returns correct value")
    func remainingCapacity_() {
        var b = KVBlock(blockId: 1, estimatedBytes: 1024)
        #expect(b.remainingCapacity(capacity: 16) == 16)
        b.addTokens(10, capacity: 16); #expect(b.remainingCapacity(capacity: 16) == 6)
    }

    @Test("equality by blockId")
    func equalityAndHash() {
        let b1 = KVBlock(blockId: 42, estimatedBytes: 1024)
        let b2 = KVBlock(blockId: 42, estimatedBytes: 2048)
        let b3 = KVBlock(blockId: 99, estimatedBytes: 1024)
        #expect(b1 == b2); #expect(!(b1 == b3))
    }
}

@Suite("BlockTable Operations")
struct BlockTableTests {
    @Test("new table is empty")
    func newTable_() {
        let t = BlockTable(sessionId: "s1")
        #expect(t.blocksUsed == 0); #expect(t.totalTokens == 0)
        #expect(t.lastBlockId == nil)
    }

    @Test("appending blocks works correctly")
    func appending_() {
        var t = BlockTable(sessionId: "s1")
        t = t.appending(blockId: 10, tokenCount: 16)
        #expect(t.blocksUsed == 1); #expect(t.totalTokens == 16)
        t = t.appending(blockId: 20, tokenCount: 8)
        #expect(t.blocksUsed == 2); #expect(t.totalTokens == 24)
        #expect(t.lastBlockId == 20)
    }

    @Test("trimming trailing blocks works")
    func trimming_() {
        var t = BlockTable(sessionId: "s1")
        t = t.appending(blockId: 10, tokenCount: 16)
        t = t.appending(blockId: 20, tokenCount: 16)
        t = t.appending(blockId: 30, tokenCount: 8)
        let trimmed = t.trimmingTrailingBlocks(1)
        #expect(trimmed.blocksUsed == 2); #expect(trimmed.totalTokens == 32)
    }

    @Test("keeping prefix works")
    func keepingPrefix_() {
        var t = BlockTable(sessionId: "s1")
        t = t.appending(blockId: 10, tokenCount: 16)
        t = t.appending(blockId: 20, tokenCount: 16)
        t = t.appending(blockId: 30, tokenCount: 8)
        let p = t.keepingPrefix(upTo: 1)
        #expect(p.blocksUsed == 1); #expect(p.totalTokens == 16)
    }

    @Test("hasPrefix returns true for matching prefix")
    func hasPrefix_() {
        var t = BlockTable(sessionId: "s1")
        t = t.appending(blockId: 10, tokenCount: 16)
        t = t.appending(blockId: 20, tokenCount: 16)
        var ok = BlockTable(sessionId: "s2")
        ok = ok.appending(blockId: 10, tokenCount: 16)
        #expect(t.hasPrefix(ok) == true)
        var wrong = BlockTable(sessionId: "s3")
        wrong = wrong.appending(blockId: 99, tokenCount: 16)
        #expect(t.hasPrefix(wrong) == false)
    }

    @Test("lastBlockFull and lastBlockRemaining")
    func lastBlockState() {
        var t = BlockTable(sessionId: "s1")
        #expect(!t.lastBlockFull(capacity: 16))
        #expect(t.lastBlockRemaining(capacity: 16) == 0)
        t = t.appending(blockId: 10, tokenCount: 10)
        #expect(!t.lastBlockFull(capacity: 16))
        #expect(t.lastBlockRemaining(capacity: 16) == 6)
        t = t.appending(blockId: 20, tokenCount: 16)
        #expect(t.lastBlockFull(capacity: 16))
    }
}
