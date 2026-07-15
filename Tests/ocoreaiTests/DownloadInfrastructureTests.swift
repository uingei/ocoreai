// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Download infrastructure tests — real types, no mock fixtures.
///
/// Coverage:
///   - DownloadSemaphore: concurrency limit, duplicate rejection, cancellation
///   - OcoreaiDownloadProgress: state machine (start → update → finish)
///   - DownloadSSEEvent: factory methods produce valid payloads
///   - retryDelay: exponential backoff values match documented spec

import Testing
import Foundation
@testable import ocoreai

// MARK: - Helpers

/// Reset shared singletons to known state before each test.
/// DownloadSemaphore and OcoreaiDownloadProgress are singletons — tests must
/// clean state to avoid cross-test pollution.
private func resetDownloadState() {
  // Atomic reset — clears inFlight count and active set under the lock.
  DownloadSemaphore.shared._test_reset()
}

@MainActor
private func resetProgressState() {
  OcoreaiDownloadProgress.shared.clear()
}

// MARK: - DownloadSemaphore

@Suite("DownloadSemaphore — concurrency limiter", .serialized)
struct DownloadSemaphoreTests {

  init() { resetDownloadState() }

  @Test("tryAcquire grants slot when under limit")
  func tryAcquireOk() {
    defer { resetDownloadState() }
    #expect(DownloadSemaphore.shared.tryAcquire(for: "a") == .ok)
    DownloadSemaphore.shared.release(for: "a")
  }

  @Test("tryAcquire rejects duplicate model")
  func tryAcquireDuplicate() {
    defer { resetDownloadState() }
    #expect(DownloadSemaphore.shared.tryAcquire(for: "b") == .ok)
    #expect(DownloadSemaphore.shared.tryAcquire(for: "b") == .duplicate)
    DownloadSemaphore.shared.release(for: "b")
  }

  @Test("tryAcquire returns busy when all slots full")
  func tryAcquireBusy() {
    defer { resetDownloadState() }
    // Semaphore has maxConcurrent = 2
    let resultA = DownloadSemaphore.shared.tryAcquire(for: "x")
    let resultB = DownloadSemaphore.shared.tryAcquire(for: "y")
    let resultC = DownloadSemaphore.shared.tryAcquire(for: "z")

    #expect(resultA == .ok)
    #expect(resultB == .ok)
    #expect(resultC == .busy)

    DownloadSemaphore.shared.release(for: "x")
    DownloadSemaphore.shared.release(for: "y")
  }

  @Test("release frees slot for next caller")
  func releaseFreesSlot() {
    defer { resetDownloadState() }
    // Fill both slots
    #expect(DownloadSemaphore.shared.tryAcquire(for: "s1") == .ok)
    #expect(DownloadSemaphore.shared.tryAcquire(for: "s2") == .ok)
    // Third must be busy
    #expect(DownloadSemaphore.shared.tryAcquire(for: "s3") == .busy)

    // Release one → third should get through
    DownloadSemaphore.shared.release(for: "s1")
    #expect(DownloadSemaphore.shared.tryAcquire(for: "s3") == .ok)

    // Cleanup
    DownloadSemaphore.shared.release(for: "s2")
    DownloadSemaphore.shared.release(for: "s3")
  }

  @Test("acquireOrWait succeeds when slot available")
  func acquireOrWaitImmediate() async {
    defer { resetDownloadState() }
    let result = await DownloadSemaphore.shared.acquireOrWait(for: "wait-ok")
    #expect(result == true)
    DownloadSemaphore.shared.release(for: "wait-ok")
  }

  @Test("acquireOrWait detects duplicate and returns false")
  func acquireOrWaitDuplicate() async {
    defer { resetDownloadState() }
    #expect(DownloadSemaphore.shared.tryAcquire(for: "wait-dup") == .ok)
    let result = await DownloadSemaphore.shared.acquireOrWait(for: "wait-dup")
    #expect(result == false)
    DownloadSemaphore.shared.release(for: "wait-dup")
  }

  @Test("acquireOrWait waits then succeeds when slot frees up")
  func acquireOrWaitWaits() async {
    defer { resetDownloadState() }
    // Fill all slots
    #expect(DownloadSemaphore.shared.tryAcquire(for: "wait-blocker1") == .ok)
    #expect(DownloadSemaphore.shared.tryAcquire(for: "wait-blocker2") == .ok)

    // Spawn a waiter in background
    let waitTask = Task {
      await DownloadSemaphore.shared.acquireOrWait(for: "waiter")
    }

    // Give waiter time to start polling
    try? await Task.sleep(for: .milliseconds(200))

    // Free a slot
    DownloadSemaphore.shared.release(for: "wait-blocker1")

    // Waiter should succeed
    let result = await waitTask.result
    #expect(result.get() == true)

    // Cleanup
    DownloadSemaphore.shared.release(for: "waiter")
    DownloadSemaphore.shared.release(for: "wait-blocker2")
  }

  @Test("acquireOrWait exits on task cancellation")
  func acquireOrWaitCancellation() async {
    defer { resetDownloadState() }
    // Fill all slots so waiter loops
    let a = DownloadSemaphore.shared.tryAcquire(for: "c1")
    let b = DownloadSemaphore.shared.tryAcquire(for: "c2")
    #expect(a == .ok && b == .ok)

    let cancelTask = Task {
      await DownloadSemaphore.shared.acquireOrWait(for: "cw")
    }

    // Give it time to enter the loop
    try? await Task.sleep(for: .milliseconds(300))

    // Cancel — task should see cancellation and return promptly
    cancelTask.cancel()

    // If cancellation works, result returns within ~500ms (one sleep cycle).
    // If broken (ignores cancellation), the task would hang indefinitely.
    let started = ContinuousClock.now
    let result = await cancelTask.result
    let elapsed = started.duration(to: ContinuousClock.now)

    // Task completed
    let completedValue = result.get()
    _ = completedValue
    // Completed relatively quickly (< 2s means cancellation was honored,
    // not that we waited for a blocker to release)
    #expect(elapsed < .seconds(2))

    // Release blockers
    DownloadSemaphore.shared.release(for: "c1")
    DownloadSemaphore.shared.release(for: "c2")
  }

  @Test("_inFlight never goes negative after multiple releases")
  func inFlightNonNegative() {
    defer { resetDownloadState() }
    #expect(DownloadSemaphore.shared.tryAcquire(for: "neg-test") == .ok)
    // Double release — should clamp to 0
    DownloadSemaphore.shared.release(for: "neg-test")
    DownloadSemaphore.shared.release(for: "neg-test")
    // Semaphore should still work normally after clamping
    #expect(DownloadSemaphore.shared.tryAcquire(for: "neg-ok") == .ok)
    DownloadSemaphore.shared.release(for: "neg-ok")
  }
}

// MARK: - OcoreaiDownloadProgress

@MainActor
@Suite("OcoreaiDownloadProgress — state machine")
struct DownloadProgressTests {

  init() { resetProgressState() }

  @Test("start creates active entry")
  func startCreatesEntry() {
    defer { OcoreaiDownloadProgress.shared.clear() }
    let progress = OcoreaiDownloadProgress.shared
    progress.start(modelId: "p-test")
    #expect(progress.isDownloading("p-test"))
    #expect(progress.progress(for: "p-test") != nil)
    progress.finish(modelId: "p-test", success: true)
  }

  @Test("start is idempotent — does not reset active progress")
  func startIdempotent() {
    defer { OcoreaiDownloadProgress.shared.clear() }
    let progress = OcoreaiDownloadProgress.shared
    progress.start(modelId: "idempotent")
    let p = Progress(totalUnitCount: 100)
    p.completedUnitCount = 50
    progress.update(p, for: "idempotent")
    progress.start(modelId: "idempotent")
    // Progress should still be at the updated value, not reset
    if let state = progress.progress(for: "idempotent") {
      #expect(state.fraction > 0)
    }
    progress.finish(modelId: "idempotent", success: true)
  }

  @Test("update sets fraction correctly")
  func updateFraction() {
    defer { OcoreaiDownloadProgress.shared.clear() }
    let progress = OcoreaiDownloadProgress.shared
    progress.start(modelId: "frac-test")

    let p = Progress(totalUnitCount: 100)
    p.completedUnitCount = 50
    progress.update(p, for: "frac-test")

    guard let state = progress.progress(for: "frac-test") else {
      Issue.record("state should exist after update")
      return
    }
    #expect(state.fraction == 0.5)
    #expect(state.active == true)
    #expect(state.completedFiles == 50)
    #expect(state.totalFiles == 100)

    progress.finish(modelId: "frac-test", success: true)
  }

  @Test("finish evicts the entry")
  func finishEvicts() {
    defer { OcoreaiDownloadProgress.shared.clear() }
    let progress = OcoreaiDownloadProgress.shared
    progress.start(modelId: "evict-test")
    #expect(progress.isDownloading("evict-test"))
    progress.finish(modelId: "evict-test", success: true)
    #expect(!progress.isDownloading("evict-test"))
    #expect(progress.progress(for: "evict-test") == nil)
  }

  @Test("finish with failure also evicts")
  func finishFailureEvicts() {
    defer { OcoreaiDownloadProgress.shared.clear() }
    let progress = OcoreaiDownloadProgress.shared
    progress.start(modelId: "fail-evict")
    progress.finish(modelId: "fail-evict", success: false)
    #expect(!progress.isDownloading("fail-evict"))
  }

  @Test("clear removes all entries")
  func clearAll() {
    OcoreaiDownloadProgress.shared.clear()
    let progress = OcoreaiDownloadProgress.shared
    progress.start(modelId: "a")
    progress.start(modelId: "b")
    #expect(progress.isDownloading("a") && progress.isDownloading("b"))
    progress.clear()
    #expect(!progress.isDownloading("a") && !progress.isDownloading("b"))
  }

  @Test("progress returns nil for unknown model")
  func progressNilForUnknown() {
    OcoreaiDownloadProgress.shared.clear()
    let progress = OcoreaiDownloadProgress.shared
    #expect(progress.progress(for: "nonexistent") == nil)
    #expect(!progress.isDownloading("nonexistent"))
  }
}

// MARK: - DownloadSSEEvent

@Suite("DownloadSSEEvent — factory methods")
struct DownloadSSEEventTests {

  @Test("progress event has correct fields")
  func progressEvent() {
    let event = DownloadSSEEvent.progress(
      "download-1", percentage: 42, totalBytes: 1000, transferredBytes: 420, eta: 10
    )
    #expect(event.downloadId == "download-1")
    #expect(event.eventType == "progress")
    #expect(event.percentage == 42)
    #expect(event.totalBytes == 1000)
    #expect(event.transferredBytes == 420)
    #expect(event.etaSeconds == 10)
    #expect(event.errorMessage == nil)
  }

  @Test("completed event has percentage 100")
  func completedEvent() {
    let event = DownloadSSEEvent.completed("download-2", cacheDir: "/tmp/cache")
    #expect(event.downloadId == "download-2")
    #expect(event.eventType == "completed")
    #expect(event.percentage == 100)
    #expect(event.cacheDir == "/tmp/cache")
    #expect(event.errorMessage == nil)
  }

  @Test("error event carries message")
  func errorEvent() {
    let event = DownloadSSEEvent.error("download-3", message: "Network failure")
    #expect(event.downloadId == "download-3")
    #expect(event.eventType == "error")
    #expect(event.errorMessage == "Network failure")
    #expect(event.percentage == nil)
  }

  @Test("DownloadSSEEvent round-trips through JSON")
  func jsonRoundTrip() throws {
    let original = DownloadSSEEvent.progress(
      "test", percentage: 75, totalBytes: 800, transferredBytes: 600, eta: 5
    )
    let encoder = JSONEncoder()
    let data = try encoder.encode(original)
    let decoded = try JSONDecoder().decode(DownloadSSEEvent.self, from: data)
    #expect(decoded.downloadId == original.downloadId)
    #expect(decoded.eventType == original.eventType)
    #expect(decoded.percentage == original.percentage)
    #expect(decoded.totalBytes == original.totalBytes)
  }
}

// MARK: - retryDelay

@Suite("retryDelay — exponential backoff values")
struct RetryDelayTests {

  @Test("attempt 0 base is ~2s (range 1-2)")
  func attempt0() {
    for _ in 0..<10 {
      let delay = retryDelay(attempt: 0)
      #expect(delay >= 1.0 && delay <= 2.0)
    }
  }

  @Test("attempt 1 base is ~4s (range 2-4)")
  func attempt1() {
    for _ in 0..<10 {
      let delay = retryDelay(attempt: 1)
      #expect(delay >= 2.0 && delay <= 4.0)
    }
  }

  @Test("attempt 2 base is ~8s (range 4-8)")
  func attempt2() {
    for _ in 0..<10 {
      let delay = retryDelay(attempt: 2)
      #expect(delay >= 4.0 && delay <= 8.0)
    }
  }

  @Test("capped by maxDelay")
  func maxDelay() {
    for _ in 0..<10 {
      let delay = retryDelay(attempt: 10, maxDelay: 5.0)
      #expect(delay <= 5.0)
    }
  }
}

// MARK: - isRetryable

@Suite("isRetryable — HTTP status classification")
struct IsRetryableTests {

  @Test("retryable: 408, 429, 500-599")
  func retryableCodes() {
    #expect(isRetryable(statusCode: 408))
    #expect(isRetryable(statusCode: 429))
    #expect(isRetryable(statusCode: 500))
    #expect(isRetryable(statusCode: 502))
    #expect(isRetryable(statusCode: 503))
    #expect(isRetryable(statusCode: 504))
    #expect(isRetryable(statusCode: 599))
  }

  @Test("not retryable: 400, 401, 404")
  func notRetryable() {
    #expect(!isRetryable(statusCode: 400))
    #expect(!isRetryable(statusCode: 401))
    #expect(!isRetryable(statusCode: 403))
    #expect(!isRetryable(statusCode: 404))
  }
}
