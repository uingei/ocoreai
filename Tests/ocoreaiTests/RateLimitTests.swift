// RateLimitTests.swift — TokenBucket & RateLimitProvider unit tests
//
// Validates token bucket math, burst behavior, and global rate limit config
// without requiring CoreAI runtime or Hummingbird Request types.

@testable import ocoreai
import Logging
import XCTest

// MARK: - TokenBucket Tests

final class TokenBucketTests: XCTestCase {

    func test_tryAcquire_returnsTrueWhenFull() async {
        let bucket = TokenBucket(rate: 10, capacity: 5)
        let ok = await bucket.tryAcquire()
        XCTAssertTrue(ok)
    }

    func test_tryAcquire_exhaustsCapacity() async {
        let bucket = TokenBucket(rate: 0.001, capacity: 3)
        let results = await bucket.acquireN(4)
        XCTAssertEqual(results, [true, true, true, false])
    }

    func test_tryAcquireCount_succeeds() async {
        let bucket = TokenBucket(rate: 100, capacity: 10)
        XCTAssertTrue(await bucket.tryAcquire(count: 3))
    }

    func test_tryAcquireCount_failsWhenInsufficient() async {
        let bucket = TokenBucket(rate: 100, capacity: 2)
        XCTAssertFalse(await bucket.tryAcquire(count: 3))
    }

    func test_tryAcquireCount_failsWhenPartial() async {
        let bucket = TokenBucket(rate: 100, capacity: 4)
        _ = await bucket.tryAcquire()  // 3 left
        XCTAssertFalse(await bucket.tryAcquire(count: 4))
    }

    func test_refill_restoresTokensAfterWait() async {
        let bucket = TokenBucket(rate: 100, capacity: 2)
        _ = await bucket.tryAcquire()
        _ = await bucket.tryAcquire()
        try? await Task.sleep(for: .seconds(1))
        XCTAssertTrue(await bucket.tryAcquire())
    }

    func test_timeUntilAvailable_zeroWhenTokensExist() async {
        let bucket = TokenBucket(rate: 10, capacity: 10)
        let wait = await bucket.timeUntilAvailable()
        XCTAssertEqual(wait, 0, accuracy: 0.001)
    }

    func test_timeUntilAvailable_positiveWhenEmpty() async {
        let bucket = TokenBucket(rate: 10, capacity: 1)
        _ = await bucket.tryAcquire()
        let wait = await bucket.timeUntilAvailable()
        XCTAssertGreaterThan(wait, 0)
        XCTAssertLessThanOrEqual(wait, 0.2)
    }
}

extension TokenBucket {
    func acquireN(_ n: Int) -> [Bool] {
        var results: [Bool] = []
        for _ in 0..<n { results.append(tryAcquire()) }
        return results
    }
}

// MARK: - RateLimitProvider Config Tests

final class RateLimitProviderConfigTests: XCTestCase {

    func test_configDefaults() {
        let config = RateLimitProvider.Config()
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.globalRate, 100)
        XCTAssertEqual(config.globalBurst, 150)
        XCTAssertEqual(config.perModelRate, 20)
        XCTAssertEqual(config.perModelBurst, 30)
        XCTAssertEqual(config.perIPRate, 10)
        XCTAssertEqual(config.perIPBurst, 20)
    }

    func test_disabledConfig_createsProviderOk() {
        var config = RateLimitProvider.Config()
        config.enabled = false
        _ = RateLimitProvider(config: config, logger: Logger(label: "test"))
    }
}
