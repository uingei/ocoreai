// Copyright 2026 uingei@163.com.
// Licensed under MIT.
//
// Ported copy-first from coreai-models (Apple, BSD-3-Clause) —
// Sources/CoreAILanguageModels/TextGeneration/LogProbabilities.swift (8cec4f8).
// Per-token log probability with optional top-K alternatives, Accelerate
// vectorized log-sum-exp. Aligned with the upstream three-repo discipline:
// the algorithm is the main-axis source, not a local invention.
//
// Gated to CoreAI: the algorithm consumes `LogitsScalarType` (logits vectors),
// which only exists inside the CoreAI engine tree (#if canImport(CoreAI) in
// CoreAIEngine.swift). Upstream this file lives in CoreAILanguageModels, a
// module built only with the CoreAI engine (LogitsScalarType in-module). The
// single-module equivalent of that isolation is this gate — ungated, the type
// is unresolvable on runners without CoreAI and the build fails. Consumers
// (CompletionsHandler loglikelihood path) are likewise CoreAI-gated.

#if canImport(CoreAI)

import Accelerate
import Foundation

/// Per-token log probability with optional top-K alternatives.
/// Aligned with upstream `CoreAILanguageModels.LogProbabilities`.
struct LogProbabilities: Sendable {
    struct Entry: Sendable {
        let tokenId: Int32
        let value: Double
        let alternatives: [(tokenId: Int32, value: Double)]
    }

    let entries: [Entry]

    var sum: Double {
        entries.reduce(0) { $0 + ($1.value.isFinite ? $1.value : 0) }
    }

    var mean: Double {
        let finite = entries.filter(\.value.isFinite)
        return finite.isEmpty ? 0 : finite.reduce(0) { $0 + $1.value } / Double(finite.count)
    }

    var perplexity: Double {
        exp(-mean)
    }

    /// Compute per-token log probabilities from raw logits and target token IDs.
    ///
    /// For each position, applies log-softmax to the logit vector and extracts
    /// the log probability of the target token plus the top-K alternatives.
    ///
    /// Uses Accelerate framework for vectorized exp/max operations (10-30×
    /// faster than scalar loops for large vocabularies).
    ///
    /// - Parameters:
    ///   - logits: Per-position logit vectors `[positions][vocabSize]`
    ///   - targets: Token ID at each position
    ///   - topK: Number of top alternatives to include (0 for none)
    static func compute(
        logits: [[LogitsScalarType]],
        targets: [Int32],
        topK: Int = 0
    ) -> LogProbabilities {
        var entries: [Entry] = []
        entries.reserveCapacity(min(logits.count, targets.count))

        for (logitVec, targetToken) in zip(logits, targets) {
            let tokenIndex = Int(targetToken)
            guard tokenIndex >= 0 && tokenIndex < logitVec.count else {
                entries.append(Entry(tokenId: targetToken, value: -.infinity, alternatives: []))
                continue
            }

            let vocabSize = logitVec.count
            let (logSumExp, floatBuffer) = computeLogSumExpVectorized(logitVec)

            let targetLogProb: Double
            if logSumExp.isInfinite {
                // +Inf logits: tokens with +Inf get log-prob 0, others get -Inf
                targetLogProb = Double(floatBuffer[tokenIndex]).isInfinite ? 0.0 : -.infinity
            } else {
                let raw = Double(floatBuffer[tokenIndex]) - logSumExp
                targetLogProb = raw.isNaN ? 0.0 : raw
            }

            var alts: [(tokenId: Int32, value: Double)] = []
            if topK > 0 {
                alts = findTopK(floatBuffer, k: topK, logSumExp: logSumExp, vocabSize: vocabSize)
            }

            entries.append(Entry(tokenId: targetToken, value: targetLogProb, alternatives: alts))
        }

        return LogProbabilities(entries: entries)
    }

    /// Vectorized log-sum-exp using Accelerate.
    /// Returns (logSumExp, floatBuffer) where floatBuffer is the Float32-converted logits.
    private static func computeLogSumExpVectorized(
        _ logits: [LogitsScalarType]
    ) -> (Double, [Float]) {
        let count = logits.count

        // Float16 → Float32 via vImageConvert_Planar16FtoPlanarF (Accelerate)
        var floatBuffer = [Float](repeating: 0, count: count)
        logits.withUnsafeBufferPointer { src in
            src.baseAddress!.withMemoryRebound(to: UInt16.self, capacity: count) { halfPtr in
                floatBuffer.withUnsafeMutableBufferPointer { dst in
                    var bufferSrc = vImage_Buffer(
                        data: UnsafeMutableRawPointer(mutating: halfPtr),
                        height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                    var bufferDst = vImage_Buffer(
                        data: dst.baseAddress!, height: 1,
                        width: vImagePixelCount(count), rowBytes: count * 4)
                    vImageConvert_Planar16FtoPlanarF(&bufferSrc, &bufferDst, 0)
                }
            }
        }

        var maxVal: Float = 0
        vDSP_maxv(floatBuffer, 1, &maxVal, vDSP_Length(count))

        if maxVal.isInfinite {
            return (Double.infinity, floatBuffer)
        }

        // log-sum-exp with temporary stack buffers
        var negMax = -maxVal
        let countLen = vDSP_Length(count)
        var countInt32 = Int32(count)

        return withUnsafeTemporaryAllocation(of: Float.self, capacity: count) { shiftedBuf in
            vDSP_vsadd(floatBuffer, 1, &negMax, shiftedBuf.baseAddress!, 1, countLen)

            return withUnsafeTemporaryAllocation(of: Float.self, capacity: count) { expBuf in
                vvexpf(expBuf.baseAddress!, shiftedBuf.baseAddress!, &countInt32)

                var sumExp: Float = 0
                vDSP_sve(expBuf.baseAddress!, 1, &sumExp, countLen)

                let logSumExp = Double(maxVal) + Double(log(sumExp))
                return (logSumExp, floatBuffer)
            }
        }
    }

    /// Find top-K elements using a min-heap (O(n log K) for small K).
    private static func findTopK(
        _ floatBuffer: [Float],
        k: Int,
        logSumExp: Double,
        vocabSize: Int
    ) -> [(tokenId: Int32, value: Double)] {
        let actualK = min(k, vocabSize)

        if actualK == 1 {
            // O(n) argmax via vDSP
            var maxVal: Float = 0
            var maxIdx: vDSP_Length = 0
            vDSP_maxvi(floatBuffer, 1, &maxVal, &maxIdx, vDSP_Length(vocabSize))
            return [(tokenId: Int32(maxIdx), value: Double(maxVal) - logSumExp)]
        }

        // For small K (typically 5-20), use a min-heap of size K.
        var topK: [(idx: Int, val: Float)] = []
        topK.reserveCapacity(actualK)

        for i in 0 ..< vocabSize {
            let val = floatBuffer[i]
            if topK.count < actualK {
                topK.append((idx: i, val: val))
                if topK.count == actualK {
                    topK.sort { $0.val < $1.val }
                }
            } else if val > topK[0].val {
                topK[0] = (idx: i, val: val)
                topK.sort { $0.val < $1.val }
            }
        }

        // Return sorted descending
        return topK.reversed().map { (tokenId: Int32($0.idx), value: Double($0.val) - logSumExp) }
    }
}

#endif  // canImport(CoreAI)
