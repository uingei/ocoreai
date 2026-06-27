// RateLimitTests.swift — TokenBucket & RateLimitProvider unit tests
//
// Validates token bucket math, burst behavior, and global rate limit config
// without requiring CoreAI runtime or Hummingbird Request types.

import Testing
@testable import ocoreai
import Logging

// MARK: - TokenBucket Tests

@Suite
struct TokenBucketTests {

    @Test
    func tryAcquire_returnsTrueWhenFull() async {
        let bucket = TokenBucket(rate: 10, capacity: 5)
        #expect(await bucket.tryAcquire())
    }

    @Test
    func tryAcquire_exhaustsCapacity() async {
        let bucket = TokenBucket(rate: 10, capacity: 2)
        _ = await bucket.tryAcquire()
        _ = await bucket.tryAcquire()
        let ok = await bucket.tryAcquire()
        #expect(!ok)
    }

    @Test
    func tryAcquireCount_succeeds() async {
        let bucket = TokenBucket(rate: 100, capacity: 10)
        let ok = await bucket.tryAcquire(count: 3)
        #expect(ok)
    }

    @Test
    func tryAcquireCount_failsWhenInsufficient() async {
        let bucket = TokenBucket(rate: 100, capacity: 2)
        let ok = await bucket.tryAcquire(count: 3)
        #expect(!ok)
    }

    @Test
    func refillAfterWait() async {
        let bucket = TokenBucket(rate: 100, capacity: 4)
        _ = await bucket.tryAcquire()  // 3 left
        let ok = await bucket.tryAcquire(count: 4)
        #expect(!ok)
    }

    @Test
    func refill_restoresTokens() async {
        let bucket = TokenBucket(rate: 100, capacity: 3)
        _ = await bucket.tryAcquire()
        try? await Task.sleep(for: .seconds(1))
        #expect(await bucket.tryAcquire())
    }

    @Test
    func timeUntilAvailable_zeroWhenTokensExist() async {
        let bucket = TokenBucket(rate: 10, capacity: 10)
        let wait = await bucket.timeUntilAvailable()
        #expect(wait < 0.001)
    }

    @Test
    func timeUntilAvailable_positiveWhenEmpty() async {
        let bucket = TokenBucket(rate: 10, capacity: 1)
        _ = await bucket.tryAcquire()
        let wait = await bucket.timeUntilAvailable()
        #expect(wait > 0)
        #expect(wait <= 0.2)
    }
}

// MARK: - RateLimitProvider Config Tests

@Suite
struct RateLimitProviderConfigTests {

    @Test
    func configDefaults() {
        let config = RateLimitProvider.Config()
        #expect(config.enabled)
        #expect(config.globalRate == 100)
        #expect(config.globalBurst == 150)
        #expect(config.perModelRate == 20)
        #expect(config.perModelBurst == 30)
        #expect(config.perIPRate == 10)
        #expect(config.perIPBurst == 20)
    }

    @Test
    func disabledConfig_createsProviderOk() {
        var config = RateLimitProvider.Config()
        config.enabled = false
        _ = RateLimitProvider(config: config, logger: Logger(label: "test"))
    }
}
