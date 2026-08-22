// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// #176 alignment — `RepetitionPenaltyGPUState` (GPU penalty buffer ring,
// ported verbatim from upstream coreai-models `Samplers/RepetitionPenaltyGPUState.swift`).
//
// Upstream test source: `Tests/LanguageModelsTests/CoreAIPipelinedTests.swift`
// ("MPSGraph completion ordering" suite — guards the submission-order assumption
// `RepetitionPenaltyGPUState` relies on) plus the state-class contract itself.
//
// Guarded with `#if canImport(Metal)` + `#if canImport(CoreAI)`:
// RepetitionPenaltyGPUState and MPSGraphArgmaxSampler are in
// Engine/MPSGraphSamplers.swift (Metal + CoreAI). On the macos-26 runner the
// CoreAI framework is absent → block not compiled, suite skipped (same
// convention as RepetitionPenaltyProcessorTests.swift).
//
// Requires a Metal device (MTLCreateSystemDefaultDevice) → .enabled(if:) guard
// so CI VMs without a GPU skip cleanly rather than fail.

import Foundation
import Metal
import Testing

#if canImport(Metal) && canImport(CoreAI)

@testable import ocoreai

private let testVocabSize = 512
private let testPipelineDepth = 2
private let testPenalty: Double = 1.3
private let testWindowSize = 8

// MARK: - RepetitionPenaltyGPUState contract

@Suite(
    "RepetitionPenaltyGPUState (#176 GPU penalty buffer)",
    .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct RepetitionPenaltyGPUStateTests {
    @Suite("buffer(forStep:) applies sign-independent penalty marks")
    struct BufferTests {
        @available(macOS 27.0, iOS 27.0, *)
        private func makeState(depth: Int = testPipelineDepth, window: Int? = testWindowSize) throws
            -> (state: RepetitionPenaltyGPUState, device: MTLDevice)
        {
            let device = try #require(MTLCreateSystemDefaultDevice())
            let state = try RepetitionPenaltyGPUState(
                device: device, vocabSize: testVocabSize, pipelineDepth: depth,
                penalty: testPenalty, windowSize: window)
            return (state, device)
        }

        @Test("fresh state buffers are all 1.0 (no-op penalty)")
        func freshBuffersAreNoop() throws {
            guard #available(macOS 27.0, iOS 27.0, *) else { return }
            let (state, _) = try makeState()
            for step in 0 ..< testPipelineDepth {
                let buf = state.buffer(forStep: step)
                let ptr = buf.contents().assumingMemoryBound(to: Float16.self)
                for i in stride(from: 0, to: testVocabSize, by: 17) {
                    #expect(ptr[i] == 1.0, "vocab \(i) should be 1.0, got \(ptr[i])")
                }
            }
        }

        @Test("recorded token is penalized in the next buffer(forStep:) write")
        func recordedTokenIsPenalized() throws {
            guard #available(macOS 27.0, iOS 27.0, *) else { return }
            let (state, _) = try makeState()
            let target: Int32 = 42
            state.recordToken(target)
            for step in 0 ..< testPipelineDepth {
                let buf = state.buffer(forStep: step)
                let ptr = buf.contents().assumingMemoryBound(to: Float16.self)
                #expect(
                    ptr[Int(target)] == Float16(testPenalty),
                    "vocab \(target) should be penalized in step \(step), got \(ptr[Int(target)])")
                // a neighboring token must NOT be penalized
                #expect(ptr[Int(target) + 1] == 1.0)
            }
        }

        @Test("duplicate recordings do not double-mark; eviction clears the mark")
        func dedupAndEviction() throws {
            guard #available(macOS 27.0, iOS 27.0, *) else { return }
            let window: Int? = 3
            let (state, _) = try makeState(window: window)
            let a: Int32 = 7
            let b: Int32 = 8
            state.recordToken(a)
            state.recordToken(b)
            state.recordToken(a)  // duplicate
            let buf = state.buffer(forStep: 0)
            let ptr = buf.contents().assumingMemoryBound(to: Float16.self)
            #expect(ptr[Int(a)] == Float16(testPenalty))
            #expect(ptr[Int(b)] == Float16(testPenalty))

            // Evict `b`: record two more tokens so the window (size 3) drops the
            // oldest entry (b, which was recorded second).
            state.recordToken(99)
            state.recordToken(100)
            let buf2 = state.buffer(forStep: 0)
            let ptr2 = buf2.contents().assumingMemoryBound(to: Float16.self)
            #expect(ptr2[Int(a)] == Float16(testPenalty), "a still in window, stays penalized")
            #expect(
                ptr2[Int(b)] == 1.0,
                "b evicted from window, must be un-penalized (1.0), got \(ptr2[Int(b)])")
        }

        @Test("window limits which tokens remain penalized")
        func windowScoping() throws {
            guard #available(macOS 27.0, iOS 27.0, *) else { return }
            let (state, _) = try makeState(window: 2)
            state.recordToken(11)
            state.recordToken(12)
            state.recordToken(13)  // evicts 11 (window=2 keeps {12,13})
            let buf = state.buffer(forStep: 1)
            let ptr = buf.contents().assumingMemoryBound(to: Float16.self)
            #expect(ptr[11] == 1.0, "11 evicted → 1.0")
            #expect(ptr[12] == Float16(testPenalty))
            #expect(ptr[13] == Float16(testPenalty))
        }

        @Test("out-of-range token IDs are ignored (no crash, no mark)")
        func outOfRangeIgnored() throws {
            guard #available(macOS 27.0, iOS 27.0, *) else { return }
            let (state, _) = try makeState()
            state.recordToken(-1)
            state.recordToken(Int32(testVocabSize))
            state.recordToken(Int32.max)
            let buf = state.buffer(forStep: 0)
            // buffer must be all 1.0 — nothing was recorded
            let ptr = buf.contents().assumingMemoryBound(to: Float16.self)
            #expect(ptr[0] == 1.0)
            #expect(ptr[Int(testVocabSize) - 1] == 1.0)
        }

        @Test("reset() clears all buffers and internal state")
        func resetClearsAll() throws {
            guard #available(macOS 27.0, iOS 27.0, *) else { return }
            let (state, _) = try makeState()
            state.recordToken(5)
            state.recordToken(6)
            state.reset()
            for step in 0 ..< testPipelineDepth {
                let buf = state.buffer(forStep: step)
                let ptr = buf.contents().assumingMemoryBound(to: Float16.self)
                #expect(ptr[5] == 1.0, "step \(step) vocab 5 not cleared")
                #expect(ptr[6] == 1.0, "step \(step) vocab 6 not cleared")
            }
        }
    }
}

// MARK: - MPSGraph Completion Ordering Sentinel
/// Validates that MPSGraphExecutable.runAsync completions are dispatched in
/// submission order on a single MTLCommandQueue. Not documented by Apple, but
/// relied upon by RepetitionPenaltyGPUState (recordToken is called from these
/// completions without extra synchronization). If this fails, GPUState needs a lock.
@Suite(
    "MPSGraph completion ordering (#176 dependency)",
    .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MPSGraphCompletionOrderingTests {
    static let vocabSize = 512

    @Test("completions fire in submission order on a single command queue")
    func completionsAreSerial() async throws {
        guard #available(macOS 27.0, iOS 27.0, *) else { return }
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        guard let queue = device.makeCommandQueue() else {
            Issue.record("no MTLCommandQueue")
            return
        }
        let sampler = MPSGraphArgmaxSampler(device: device, vocabSize: Self.vocabSize)

        let stepCount = 16
        // Mutex<[Int]> to record completion order thread-safely.
        final class OrderBox: @unchecked Sendable {
            let lock = NSLock()
            var order: [Int] = []
            func append(_ i: Int) {
                lock.lock()
                defer { lock.unlock() }
                order.append(i)
            }
            func snapshot() -> [Int] {
                lock.lock()
                defer { lock.unlock() }
                return order
            }
        }
        let orderRecord = OrderBox()

        for i in 0 ..< stepCount {
            guard
                let logitsBuffer = device.makeBuffer(
                    length: Self.vocabSize * MemoryLayout<Float16>.size, options: .storageModeShared
                )
            else {
                Issue.record("no logits buffer")
                return
            }
            let ptr = logitsBuffer.contents().assumingMemoryBound(to: Float16.self)
            for v in 0 ..< Self.vocabSize { ptr[v] = Float16(0) }
            ptr[i % Self.vocabSize] = Float16(10.0)

            guard
                let outputBuffer = device.makeBuffer(
                    length: MemoryLayout<Int32>.size, options: .storageModeShared)
            else {
                Issue.record("no output buffer")
                return
            }

            sampler.encode(
                to: queue,
                logitsBuffer: logitsBuffer,
                logitsOffset: 0,
                outputBuffer: outputBuffer,
                outputOffset: 0,
                applyBitmask: false,
                completion: { _, _ in
                    orderRecord.append(i)
                }
            )
        }

        // Wait for all completions via a sentinel command buffer.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            guard let cmdBuf = queue.makeCommandBuffer() else {
                cont.resume()
                return
            }
            cmdBuf.addCompletedHandler { _ in cont.resume() }
            cmdBuf.commit()
        }

        let observed = orderRecord.snapshot()
        #expect(
            observed == Array(0 ..< stepCount),
            "Completions not in submission order — RepetitionPenaltyGPUState needs a lock")
    }
}

#endif
