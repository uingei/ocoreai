// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause
// Provenance: coreai-models Samplers/RepetitionPenaltyGPUState.swift.
//   Absorbed: #490 12f3700 (forGeneration reuse-if-idle + matches + defaultWindowSize, ported 11-12).

import Foundation
import Metal

/// Manages per-pipeline-depth penalty buffers for GPU repetition penalty.
///
/// Uses a split design to avoid races between GPU reads and CPU writes:
/// - `recordToken()`: updates only the CPU-side ring buffer (no MTLBuffer writes)
/// - `buffer(forStep:)`: writes the full penalty state to a specific buffer
///   slot, called at encode time when the gate guarantees that slot is not in use
///
/// Thread safety: relies on MPSGraph runAsync completions being dispatched in
/// submission order on a single MTLCommandQueue (observed behavior, validated by
/// `MPSGraphCompletionOrderingTests`). The gate further ensures that
/// `buffer(forStep:)` does not overlap with `recordToken` for the same slot.
///
/// ocoreai (deployment macOS 14) — not upstream coreai-models (27-only SDK) —
/// gates this into the `@available(macOS 27.0)` CoreAI/Metal sampler family:
/// the class throws `MPSGraphSamplerError` (27.0-gated, MPSGraphSamplers.swift:1407),
/// so an ungated declaration referencing it fails the macos-26 (27-not) build gate.
/// Mirrors every sibling sampler (MPSGraphArgmaxSampler, MPSGraphCompositeSampler,
/// CoreAIPipelinedEngine — all 27.0-gated).
@available(macOS 27.0, iOS 27.0, *)
final class RepetitionPenaltyGPUState: @unchecked Sendable {
    static let defaultWindowSize = 256

    let penaltyBuffers: [MTLBuffer]
    let vocabSize: Int
    let pipelineDepth: Int
    let penalty: Float16
    let windowSize: Int

    private var ring: [Int32]
    private var writeIndex: Int = 0
    private var count: Int = 0
    private var refCounts: [Int32: Int] = [:]
    private var dirtyTokens: [(added: [Int32], evicted: [Int32])]

    init(device: MTLDevice, vocabSize: Int, pipelineDepth: Int, penalty: Double, windowSize: Int?)
        throws
    {
        self.vocabSize = vocabSize
        self.pipelineDepth = pipelineDepth
        self.penalty = Float16(penalty)
        self.windowSize = windowSize ?? Self.defaultWindowSize

        let bufferSize = vocabSize * MemoryLayout<Float16>.size
        var buffers: [MTLBuffer] = []
        for _ in 0 ..< pipelineDepth {
            guard let buffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)
            else {
                throw MPSGraphSamplerError.bufferAllocationFailed
            }
            let ptr = buffer.contents().assumingMemoryBound(to: Float16.self)
            for i in 0 ..< vocabSize {
                ptr[i] = Float16(1.0)
            }
            buffers.append(buffer)
        }
        self.penaltyBuffers = buffers
        self.ring = [Int32](repeating: -1, count: self.windowSize)
        self.dirtyTokens = Array(repeating: (added: [], evicted: []), count: pipelineDepth)
    }

    /// Get the penalty buffer for a given step after syncing pending changes.
    ///
    /// Called at encode time. The gate guarantees this slot's previous GPU read
    /// has completed, so writing to it is safe.
    func buffer(forStep step: Int) -> MTLBuffer {
        let slot = step % pipelineDepth
        let buf = penaltyBuffers[slot]
        let ptr = buf.contents().assumingMemoryBound(to: Float16.self)

        let dirty = dirtyTokens[slot]
        // Apply final state by CURRENT refcount, not list order. A token can sit
        // in BOTH `added` and `evicted` within one flush interval (recorded,
        // then evicted before this slot flushed) — the two-pass "evicted then
        // added" apply order leaves a stale penalty on a token that has left
        // the window, and it is never cleared (token is out of the ring, so it
        // can never be evicted again). Refcount > 0 at flush time is the
        // authoritative in-window state.
        // Contract: RepetitionPenaltyGPUStateTests "window limits which tokens
        // remain penalized".
        var touched: Set<Int32> = []
        for tokenId in dirty.evicted { touched.insert(tokenId) }
        for tokenId in dirty.added { touched.insert(tokenId) }
        for tokenId in touched {
            ptr[Int(tokenId)] = refCounts[tokenId, default: 0] > 0 ? penalty : Float16(1.0)
        }
        dirtyTokens[slot] = (added: [], evicted: [])

        return buf
    }

    /// Record a newly generated token (CPU-side bookkeeping only).
    ///
    /// Called from the completion callback. Does NOT write to MTLBuffers directly.
    /// Instead, queues changes to be applied per-slot at the next `buffer(forStep:)` call.
    func recordToken(_ token: Int32) {
        guard token >= 0 && Int(token) < vocabSize else { return }

        var evictedToken: Int32 = -1
        if count == windowSize {
            let evictSlot = writeIndex
            let candidate = ring[evictSlot]
            if candidate >= 0 {
                refCounts[candidate, default: 0] -= 1
                if refCounts[candidate, default: 0] <= 0 {
                    refCounts.removeValue(forKey: candidate)
                    evictedToken = candidate
                }
            }
        } else {
            count += 1
        }

        ring[writeIndex] = token
        writeIndex = (writeIndex + 1) % windowSize
        refCounts[token, default: 0] += 1

        for i in 0 ..< pipelineDepth {
            if evictedToken >= 0 {
                dirtyTokens[i].evicted.append(evictedToken)
            }
            dirtyTokens[i].added.append(token)
        }
    }

    /// State for a new generation: nil without a penalty, `existing` reset when idle and matching, else a new one.
    static func forGeneration(
        reusing existing: RepetitionPenaltyGPUState?,
        existingIsIdle: Bool,
        device: MTLDevice,
        vocabSize: Int,
        pipelineDepth: Int,
        penalty: Double?,
        windowSize: Int?
    ) throws -> RepetitionPenaltyGPUState? {
        guard let penalty else { return nil }
        if let existing, existingIsIdle,
            existing.matches(
                vocabSize: vocabSize, pipelineDepth: pipelineDepth, penalty: penalty,
                windowSize: windowSize)
        {
            existing.reset()
            return existing
        }
        return try RepetitionPenaltyGPUState(
            device: device, vocabSize: vocabSize, pipelineDepth: pipelineDepth, penalty: penalty,
            windowSize: windowSize)
    }

    /// Whether this state was built for the given shape, penalty and window.
    func matches(vocabSize: Int, pipelineDepth: Int, penalty: Double, windowSize: Int?) -> Bool {
        self.vocabSize == vocabSize && self.pipelineDepth == pipelineDepth
            && self.penalty == Float16(penalty)
            && self.windowSize == (windowSize ?? Self.defaultWindowSize)
    }

    /// Restores neutral buffers and empty history. Requires no step in flight.
    func reset() {
        for buf in penaltyBuffers {
            let ptr = buf.contents().assumingMemoryBound(to: Float16.self)
            for i in 0 ..< vocabSize {
                ptr[i] = Float16(1.0)
            }
        }
        ring = [Int32](repeating: -1, count: windowSize)
        writeIndex = 0
        count = 0
        refCounts.removeAll(keepingCapacity: true)
        dirtyTokens = Array(repeating: (added: [], evicted: []), count: pipelineDepth)
    }
}
