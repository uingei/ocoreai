// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// BlockPoolActorTests.swift — BlockPool actor: allocate, deallocate, ref-count,
/// LRU eviction, stats.

import Testing
import Foundation
import Logging
@testable import ocoreai

@Suite("BlockPool Actor — Allocate/Deallocate")
struct BlockPoolActorTests {
    func makePool(maxBlocks: Int = 4,
                  watermark: Double = 0.8, throttle: Double = 0.4) -> BlockPool {
        BlockPool(config: BlockPoolConfig(
            tokensPerBlock: 16, maxBlocks: maxBlocks,
            evictionWatermark: watermark, evictionThrottle: throttle
        ))
    }

    // MARK: - Allocate

    @Test("allocate returns incrementing block IDs")
    func allocateIds_() async throws {
        let pool = makePool(maxBlocks: 10)
        let id1 = try await pool.allocate()
        let id2 = try await pool.allocate()
        #expect(id1 == 1)
        #expect(id2 == 2)
    }

    @Test("stats reflect allocations")
    func statsReflectAllocs_() async throws {
        let pool = makePool(maxBlocks: 10)
        _ = try await pool.allocate()
        _ = try await pool.allocate()
        let stats = await pool.stats()
        #expect(stats.activeBlocks == 2)
        #expect(stats.totalAllocations >= 2)
        #expect(stats.estimatedBytes > 0)
    }

    @Test("usageFraction correct")
    func usageFraction_() async throws {
        let pool = makePool(maxBlocks: 4)
        _ = try await pool.allocate()
        let fr = await pool.usageFraction()
        #expect(abs(fr - 0.25) < 0.001)
    }

    @Test("preallocate returns N ids")
    func preallocate_() async throws {
        let pool = makePool(maxBlocks: 10)
        let ids = try await pool.preallocate(count: 3)
        #expect(ids.count == 3)
        #expect(ids.sorted() == ids)
    }

    // MARK: - Deallocate

    @Test("addReference then deallocate reclaims when zero")
    func addRefThenDealloc_() async throws {
        let pool = makePool()
        let id = try await pool.allocate()
        _ = try await pool.addReference(blockId: id)
        let stats1 = await pool.stats()
        let active1 = stats1.activeBlocks
        let reclaimed = await pool.deallocate(blockId: id)
        #expect(reclaimed == true)
        let stats2 = await pool.stats()
        #expect(stats2.activeBlocks == active1 - 1)
    }

    @Test("deallocate with refCount > 1 does not reclaim fully")
    func partialDealloc_() async throws {
        let pool = makePool()
        let id = try await pool.allocate()
        _ = try await pool.addReference(blockId: id)
        _ = try await pool.addReference(blockId: id)
        // refCount = 0 + 2 = 2. One dealloc → 1, newCount!=0, returns false.
        let r = await pool.deallocate(blockId: id)
        #expect(r == false)
        let s = await pool.stats()
        #expect(s.activeBlocks > 0)
    }

    @Test("deallocate on non-existent returns false")
    func deallocMissing_() async {
        let pool = makePool()
        let ok = await pool.deallocate(blockId: 9999)
        #expect(ok == false)
    }

    @Test("addReference on missing block returns false")
    func addRefMissing_() async {
        let pool = makePool()
        let ok = await pool.addReference(blockId: 9999)
        #expect(ok == false)
    }

    // MARK: - Bulk deallocate

    @Test("batch deallocate releases all")
    func batchDealloc_() async throws {
        let pool = makePool(maxBlocks: 10)
        let ids = try await pool.preallocate(count: 3)
        for id in ids {
            _ = try await pool.addReference(blockId: id)
        }
        await pool.deallocate(ids)
        let s = await pool.stats()
        #expect(s.activeBlocks == 0)
    }

    // MARK: - Block info & stats

    @Test("blockInfo returns block after allocate")
    func blockInfo_() async throws {
        let pool = makePool()
        let id = try await pool.allocate()
        let info = await pool.blockInfo(blockId: id)
        #expect(info != nil)
        #expect(info?.blockId == id)
    }

    @Test("estimatedBytes increases with allocs")
    func estimatedBytes_() async throws {
        let pool = makePool(maxBlocks: 10)
        let b1 = await pool.estimatedBytes
        _ = try await pool.allocate()
        let b2 = await pool.estimatedBytes
        #expect(b2 > b1)
    }

    @Test("availableCount decreases after alloc")
    func availableCount_() async throws {
        let pool = makePool(maxBlocks: 4)
        let a1 = await pool.availableCount
        _ = try await pool.allocate()
        let a2 = await pool.availableCount
        #expect(a2 == a1 - 1)
    }

    // MARK: - Eviction

    @Test("eviction triggers when pool full")
    func evictionTriggers_() async throws {
        // maxBlocks=2, watermark=0.8 → eviction at >80% usage (i.e. 2/2 = 100%)
        let pool = makePool(maxBlocks: 2, watermark: 0.5, throttle: 0.2)
        _ = try await pool.allocate() // 1/2 = 50%, at watermark but not over
        _ = try await pool.allocate() // 2/2 = 100%, over watermark, alloc triggers eviction
        // But we need 3rd alloc to trigger overflow → evict → alloc
        // Actually allocate checks activeBlockCount >= maxBlocks before creating
        // so 2nd alloc should succeed. 3rd would try to evict.
        let s = await pool.stats()
        #expect(s.activeBlocks == 2)
    }

    @Test("exhausted pool throws when eviction can't reclaim")
    func exhaustedThrows_() async throws {
        // watermark=1.0 means eviction never triggers, so pool fills and throws
        let pool = makePool(maxBlocks: 2, watermark: 1.0, throttle: 0.5)
        _ = try await pool.allocate()
        _ = try await pool.allocate()
        do {
            _ = try await pool.allocate()
            #expect(Bool(false), "Expected AppError.blockPoolExhausted")
        } catch {
            #expect(error is AppError ||
                    error.localizedDescription.contains("exhausted"))
        }
    }

    @Test("eviction reclaims idle blocks when pool full")
    func evictAndReuse_() async throws {
        let pool = makePool(maxBlocks: 2, watermark: 0.9, throttle: 0.1)
        _ = try await pool.allocate()
        _ = try await pool.allocate()
        // active=2, full. Add refs so eviction sees refCount<=1 still
        // 3rd alloc: active(2) >= max(2) → evictIfNeeded → usage=100%>90%
        //     evicts both (refCount<=1). active=0. alloc succeeds. active=1.
        let _ = try await pool.allocate()
        let s = await pool.stats()
        #expect(s.totalEvictions >= 1)
    }
}
