// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// coreai-models #244 (d65a651) — "Fix pipelined engine crash with repetition
// penalty during prefill". Upstream bug: when `repetitionPenalty` is set,
// MPSGraphCompositeSampler compiles the graph with 6 feeds
// (logits, penalty, temperature, random, topP, minP), but the non-penalty
// encode() and encodeWithSlice() paths passed only 5 inputs, omitting the
// penalty tensor. MPSGraph then landed f32 temperature data where the f16
// penalty tensor was expected and crashed with
// "expected element type f16 but received f32".
//
// ocoreai in-tree copy (Engine/MPSGraphSamplers.swift) inherited the same bug.
// Fix (ported, "consume not reinvent"): a pre-allocated neutral penalty buffer
// (all 1.0 in f16) + buildInputs() ordering inputs by executable.feedTensors
// operation names. All three encode paths now feed the correct 6 tensors.
//
// This suite pins both the fix contract and the exact neutral value:
// 1. penaltyEnabled  → neutral buffer exists, every entry == 1.0 (exact f16 value).
// 2. !penaltyEnabled → no neutral buffer allocated (no allocation waste).
// 3. Non-penalty encode() on the penalty-enabled graph completes WITHOUT a
//    feed-type error (the crash class #244 fixes) and yields the argmax token.
// 4. Neutral feed is a true no-op: penalty-path token with an all-1.0 penalty
//    buffer == non-penalty-path token on identical logits (both argmax).
// 5. encodeWithSlice() (the prefill path — the actual #244 crash site)
//    completes on the penalty-enabled graph with the correct token.
//
// Guarded with `#if canImport(Metal)` + `#if canImport(CoreAI)` and
// `.enabled(if: MTLCreateSystemDefaultDevice() != nil)`: the samplers are in
// Engine/MPSGraphSamplers.swift (Metal + CoreAI, macOS 27 / iOS 27 only). On
// the macos-26 runner the CoreAI framework is absent → block not compiled,
// suite skipped. CI VMs without a GPU skip cleanly rather than fail.

import Foundation
import Metal
import Testing

#if canImport(Metal) && canImport(CoreAI)

@testable import ocoreai

private let testVocabSize = 512
private let testLogitIndex = 42
private let testLogitValue: Float16 = 10.0

@Suite(
    "MPSGraphCompositeSampler (#244 neutral penalty feed contract)",
    .enabled(if: MTLCreateSystemDefaultDevice() != nil)
)
struct CompositeSamplerNeutralFeedTests {
    // MARK: - Helpers

    @available(macOS 27.0, iOS 27.0, *)
    private static func fillLogits(_ buffer: MTLBuffer, vocabSize: Int) {
        let ptr = buffer.contents().assumingMemoryBound(to: Float16.self)
        for v in 0 ..< vocabSize { ptr[v] = Float16(0) }
        ptr[testLogitIndex] = testLogitValue
    }

    @available(macOS 27.0, iOS 27.0, *)
    private static func wait(_ queue: MTLCommandQueue) throws {
        let sema = DispatchSemaphore(value: 0)
        guard let cmdBuf = queue.makeCommandBuffer() else { return }
        cmdBuf.addCompletedHandler { _ in sema.signal() }
        cmdBuf.commit()
        try #require(
            sema.wait(timeout: .now() + 30) == .success,
            "GPU command buffer timed out")
    }

    // MARK: - 1. Neutral buffer exists and is all 1.0 (exact value)

    @Test("neutral penalty buffer is allocated when penaltyEnabled and is 1.0 exactly")
    func neutralBufferAllOnes() throws {
        guard #available(macOS 27.0, iOS 27.0, *) else { return }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let sampler = try MPSGraphCompositeSampler(
            device: device, vocabSize: testVocabSize, penaltyEnabled: true)

        let buf = try #require(sampler.testingOnlyNeutralPenaltyBuffer)
        let ptr = buf.contents().assumingMemoryBound(to: UInt16.self)
        for v in 0 ..< testVocabSize {
            #expect(
                ptr[v] == 0x3C00,
                "neutral penalty entry \(v) must be 1.0 (0x3C00 in f16), got 0x\(String(ptr[v], radix: 16))"
            )
        }
    }

    // MARK: - 2. No allocation when penalty is off

    @Test("no neutral penalty buffer when penaltyEnabled is false")
    func noNeutralBufferDisabled() throws {
        guard #available(macOS 27.0, iOS 27.0, *) else { return }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let sampler = try MPSGraphCompositeSampler(
            device: device, vocabSize: testVocabSize, penaltyEnabled: false)
        #expect(
            sampler.testingOnlyNeutralPenaltyBuffer == nil,
            "penalty disabled → no neutral buffer should be allocated")
    }

    // MARK: - 3. Non-penalty encode on penalty-enabled graph (crash class)

    @Test("non-penalty encode path feeds the neutral tensor and returns argmax")
    @available(macOS 27.0, iOS 27.0, *)
    func nonPenaltyPathCompletes() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let sampler = try MPSGraphCompositeSampler(
            device: device, vocabSize: testVocabSize, penaltyEnabled: true)
        sampler.testingOnlyRandomOverride = 0.3

        guard
            let logitsBuffer = device.makeBuffer(
                length: testVocabSize * MemoryLayout<UInt16>.size,
                options: .storageModeShared),
            let outputBuffer = device.makeBuffer(
                length: MemoryLayout<Int32>.size, options: .storageModeShared)
        else {
            Issue.record("buffer allocation failed")
            return
        }
        Self.fillLogits(logitsBuffer, vocabSize: testVocabSize)

        let done = DispatchSemaphore(value: 0)
        var token: Int32 = -1
        var failed = false
        sampler.encode(
            to: queue,
            logitsBuffer: logitsBuffer,
            logitsOffset: 0,
            outputBuffer: outputBuffer,
            outputOffset: 0,
            completion: { t, error in
                token = t
                failed = (error != nil)
                done.signal()
            })
        try #require(done.wait(timeout: .now() + 30) == .success)
        try Self.wait(queue)
        #expect(!failed, "non-penalty path must not error (the #244 crash class)")
        #expect(
            token == Int32(testLogitIndex),
            "argmax token expected (\(testLogitIndex)), got \(token)")
    }

    // MARK: - 4. Neutral feed is a no-op (parity across the two paths)

    @Test("neutral-penalty feed yields the same token as the explicit-1.0 penalty feed")
    @available(macOS 27.0, iOS 27.0, *)
    func neutralFeedIsNoop() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let sampler = try MPSGraphCompositeSampler(
            device: device, vocabSize: testVocabSize, penaltyEnabled: true)
        sampler.testingOnlyRandomOverride = 0.3

        guard
            let logitsBuffer = device.makeBuffer(
                length: testVocabSize * MemoryLayout<UInt16>.size,
                options: .storageModeShared),
            let penaltyBuffer = device.makeBuffer(
                length: testVocabSize * MemoryLayout<UInt16>.size,
                options: .storageModeShared),
            let outA = device.makeBuffer(
                length: MemoryLayout<Int32>.size, options: .storageModeShared),
            let outB = device.makeBuffer(
                length: MemoryLayout<Int32>.size, options: .storageModeShared)
        else {
            Issue.record("buffer allocation failed")
            return
        }
        Self.fillLogits(logitsBuffer, vocabSize: testVocabSize)

        // Explicit penalty buffer: all 1.0 == the neutral value → identical math.
        let pptr = penaltyBuffer.contents().assumingMemoryBound(to: UInt16.self)
        for v in 0 ..< testVocabSize { pptr[v] = 0x3C00 }

        // Path A: non-penalty encode (neutral feed).
        var tokenA: Int32 = -1
        let semA = DispatchSemaphore(value: 0)
        sampler.encode(
            to: queue, logitsBuffer: logitsBuffer, logitsOffset: 0,
            outputBuffer: outA, outputOffset: 0,
            completion: { token, error in
                tokenA = token
                if error == nil { semA.signal() }
            })
        try #require(semA.wait(timeout: .now() + 30) == .success)

        // Path B: penalty encode with an all-1.0 buffer.
        var tokenB: Int32 = -1
        let semB = DispatchSemaphore(value: 0)
        sampler.encode(
            to: queue, logitsBuffer: logitsBuffer, logitsOffset: 0,
            penaltyBuffer: penaltyBuffer,
            outputBuffer: outB, outputOffset: 0,
            completion: { token, error in
                tokenB = token
                if error == nil { semB.signal() }
            })
        try #require(semB.wait(timeout: .now() + 30) == .success)
        try Self.wait(queue)

        #expect(
            tokenA == tokenB,
            "neutral feed (\(tokenA)) must equal all-1.0 penalty feed (\(tokenB))")
        #expect(tokenA == Int32(testLogitIndex), "both paths must land on the argmax")
    }

    // MARK: - 5. encodeWithSlice (prefill) on penalty-enabled graph

    @Test("encodeWithSlice (prefill path) completes on the penalty-enabled graph")
    @available(macOS 27.0, iOS 27.0, *)
    func prefillSlicePathCompletes() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let sampler = try MPSGraphCompositeSampler(
            device: device, vocabSize: testVocabSize, penaltyEnabled: true)
        sampler.testingOnlyRandomOverride = 0.3

        // queryLength 3: logits packed as 3 × [vocabSize] f16 rows; the slice
        // blit copies the last row (offset (3-1)*vocab), so put the hot logit
        // in the LAST row only.
        let rows = 3
        guard
            let logitsBuffer = device.makeBuffer(
                length: rows * testVocabSize * MemoryLayout<UInt16>.size,
                options: .storageModeShared),
            let outputBuffer = device.makeBuffer(
                length: MemoryLayout<Int32>.size, options: .storageModeShared)
        else {
            Issue.record("buffer allocation failed")
            return
        }
        let ptr = logitsBuffer.contents().assumingMemoryBound(to: Float16.self)
        for row in 0 ..< rows {
            for v in 0 ..< testVocabSize { ptr[row * testVocabSize + v] = Float16(0) }
        }
        for v in 0 ..< testVocabSize { ptr[(rows - 2) * testVocabSize + v] = Float16(0) }
        ptr[(rows - 1) * testVocabSize + testLogitIndex] = testLogitValue

        let done = DispatchSemaphore(value: 0)
        var token: Int32 = -1
        var failed = false
        sampler.encodeWithSlice(
            to: queue,
            logitsBuffer: logitsBuffer,
            queryLength: rows,
            outputBuffer: outputBuffer,
            outputOffset: 0,
            completion: { t, error in
                token = t
                failed = (error != nil)
                done.signal()
            })
        try #require(done.wait(timeout: .now() + 30) == .success)
        try Self.wait(queue)
        #expect(!failed, "prefill slice path must not error (the #244 crash site)")
        #expect(
            token == Int32(testLogitIndex),
            "prefill path must return the last-row argmax, got \(token)")
    }
}

#endif
