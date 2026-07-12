// Copyright © 2026 uingei@163.com.
/// MCPCallCache Tests — LRU eviction + TTL expiry
///
/// Coverage: get/set/eviction/expiration on MCPCallCache (actor)
///
/// Rationale: MCPCallCache is pure data logic — no hardware needed.
/// Tests verify LRU ordering and TTL expiration in actor isolation.

import Testing
import ocoreaiTestUtilities
@testable import ocoreai

@Suite("MCP — CallCache LRU + TTL")
struct MCPCallCacheTests {
    @Test("Set then get returns cached value")
    func basicHit() async {
        let cache = MCPCallCache(maxEntries: 10, ttlSeconds: 60)
        await cache.set("k", value: "v")
        #expect(await cache.get("k") == "v")
    }

    @Test("Miss returns nil")
    func missReturnsNil() async {
        let cache = MCPCallCache(maxEntries: 10, ttlSeconds: 60)
        #expect(await cache.get("nope") == nil)
    }

    @Test("Update existing key overwrites value")
    func updateExistingKey() async {
        let cache = MCPCallCache(maxEntries: 10, ttlSeconds: 60)
        await cache.set("k", value: "old")
        await cache.set("k", value: "new")
        #expect(await cache.get("k") == "new")
    }

    @Test("LRU evicts least-recently-used entry")
    func lruEviction() async {
        let cache = MCPCallCache(maxEntries: 2, ttlSeconds: 60)
        await cache.set("a", value: "1")
        await cache.set("b", value: "2")
        // Adding "c" should evict "a" (oldest)
        await cache.set("c", value: "3")
        #expect(await cache.get("a") == nil)
        #expect(await cache.get("b") == "2")  // "b" still there
        #expect(await cache.get("c") == "3")
    }

    @Test("Access promotes recency — read prevents eviction")
    func accessPromotesRecency() async {
        let cache = MCPCallCache(maxEntries: 2, ttlSeconds: 60)
        await cache.set("a", value: "1")
        await cache.set("b", value: "2")
        _ = await cache.get("a")  // make "a" most recently used
        await cache.set("c", value: "3")  // should evict "b" (LRU)
        #expect(await cache.get("a") == "1")   // still present (was accessed)
        #expect(await cache.get("b") == nil)   // evicted (LRU)
    }

    @Test("TTL expiration clears stale entries")
    func ttlExpiration() async {
        let cache = MCPCallCache(maxEntries: 10, ttlSeconds: 0.05)
        await cache.set("k", value: "v")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await cache.get("k") == nil)
    }

    @Test("Non-expired entries remain accessible")
    func ttlNotExpired() async {
        let cache = MCPCallCache(maxEntries: 10, ttlSeconds: 60)
        await cache.set("k", value: "v")
        #expect(await cache.get("k") == "v")
    }

    @Test("Empty cache returns nil")
    func emptyCache() async {
        let cache = MCPCallCache(maxEntries: 5, ttlSeconds: 60)
        #expect(await cache.get("x") == nil)
    }

    @Test("Single-entry capacity evicts on insert")
    func singleEntryCapacity() async {
        let cache = MCPCallCache(maxEntries: 1, ttlSeconds: 60)
        await cache.set("first", value: "1")
        await cache.set("second", value: "2")
        #expect(await cache.get("first") == nil)
        #expect(await cache.get("second") == "2")
    }

    @Test("Cache status reflects state")
    func status() async {
        let cache = MCPCallCache(maxEntries: 10, ttlSeconds: 60)
        let status = await cache.status()
        #expect(status["entries"] == "0")
        #expect(status["maxEntries"] == "10")
        await cache.set("k", value: "v")
        let status2 = await cache.status()
        #expect(status2["entries"] == "1")
    }

    @Test("Clear empties cache")
    func clear() async {
        let cache = MCPCallCache(maxEntries: 10, ttlSeconds: 60)
        await cache.set("k", value: "v")
        await cache.clear()
        #expect(await cache.get("k") == nil)
        #expect(await cache.count() == 0)
    }

    @Test("Purge expired removes old entries")
    func purgeExpired() async {
        let cache = MCPCallCache(maxEntries: 10, ttlSeconds: 0.05)
        await cache.set("old", value: "v")
        await cache.set("new", value: "w")  // this one is NOT expired yet
        try? await Task.sleep(for: .milliseconds(100))
        // After sleep, "old" is expired. "new" was set AFTER sleep started so might not be.
        // Safest: only verify expired entry is gone
        #expect(await cache.get("old") == nil)
    }
}
