import Foundation
import Testing

@testable import ocoreai

/// Circuit-breaker predicate for the embedding cold-load path.
///
/// Live evidence 10-06: huggingface.co unreachable while the app was in use
/// → every chat message re-ran the full two-candidate download timeout
/// (~6s/message, warning storm every ~3s for hours). The fix is a
/// fail-fast cooldown in `EmbeddingService.ensureContainer()`; the
/// throttle *predicate* is pure and pinned here without needing network.
@Suite("EmbeddingService load circuit breaker")
struct EmbeddingCircuitBreakerTests {

    @Test("no failure recorded → never throttled")
    func noFailureNeverThrottled() {
        #expect(
            !EmbeddingService.shouldThrottleLoad(
                lastFailure: nil, now: Date(), cooldown: 300))
    }

    @Test("failure inside cooldown → throttled (exact boundaries)")
    func insideCooldownThrottled() {
        let failure = Date(timeIntervalSince1970: 1_000)
        // 1s before failure+cooldown window still open
        #expect(
            EmbeddingService.shouldThrottleLoad(
                lastFailure: failure,
                now: Date(timeIntervalSince1970: 1_299), cooldown: 300))
        // exactly at window close → probe allowed again (self-healing)
        #expect(
            !EmbeddingService.shouldThrottleLoad(
                lastFailure: failure,
                now: Date(timeIntervalSince1970: 1_300), cooldown: 300))
    }

    @Test("failure past cooldown → probe allowed")
    func pastCooldownAllowsProbe() {
        let failure = Date(timeIntervalSince1970: 1_000)
        #expect(
            !EmbeddingService.shouldThrottleLoad(
                lastFailure: failure,
                now: Date(timeIntervalSince1970: 1_301), cooldown: 300))
    }

    @Test("configured window is 300s (5 min)")
    func cooldownWindowValue() {
        #expect(EmbeddingService.reloadCooldown == 300)
    }

    @Test("throttled error message carries remaining seconds")
    func throttledErrorMessage() {
        let err = EmbeddingService.EmbeddingError.loadingThrottled(remaining: 42)
        #expect(err.errorDescription?.contains("42") == true)
    }
}
