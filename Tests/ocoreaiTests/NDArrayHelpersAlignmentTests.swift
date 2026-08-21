// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// F1 — `fillNDArray` / `readNDArray` correctness on both the fast (row-major
// contiguous) and the stride-aware (padding) paths. Aligned with upstream
// coreai-models `CoreAIShared/Runtime/NDArray+Helpers.swift` @ 684ae8e
// — the old ocoreai local impl indexed `ptr[i]` and dropped the `strides`
// closure param, silently mis-reading GPU-aligned 4D+ tensors.
//
// Guarded with `#available(macOS 27)` in each test body (the @Suite / @Test
// macros do not accept @available — see PerformanceMetricsTests.swift).
//
// Whole suite wrapped in `#if canImport(CoreAI)` — identical guard as the
// source files (CoreAIStubs.swift:6, NDArrayHelpers.swift:4).  On the
// macos-26 runner (Xcode 26.6 / SDK 26.5) the CoreAI framework is absent, so
// NDArray / Span / fillNDArray / readNDArray do not exist and there is
// nothing to test; the compiler skips the block entirely.

import Foundation
import Testing

#if canImport(CoreAI)
import CoreAI

@testable import ocoreai

@Suite("NDArray fill/read helpers (F1 stride-aware alignment)")
struct NDArrayHelpersAlignmentTests {

    /// [2,3] fast path — each row is a different value sequence so a naive
    /// `ptr[i]` implementation that ignored strides would still pass (2D is
    /// physically contiguous), which is *why* we also add the 4D case.
    @Test("2D [2,3] fill/read roundtrip matches a row-major identity fill")
    func twoDimensionalContiguousRoundTrip() {
        guard #available(macOS 27.0, *) else { return }
        var a = NDArray(shape: [2, 3], scalarType: .float32)
        fillNDArray(&a, as: Float.self, count: 6) { Float($0) * 10 }
        let got = readNDArray(a, as: Float.self, count: 6)
        #expect(got == [0, 10, 20, 30, 40, 50])
    }

    /// [4,2,3] = 24 elems, 3D fast path.
    @Test("3D [4,2,3] fill/read roundtrip preserves 24 elements in order")
    func threeDimensionalRoundTrip() {
        guard #available(macOS 27.0, *) else { return }
        let n = 4 * 2 * 3
        var a = NDArray(shape: [4, 2, 3], scalarType: .float32)
        fillNDArray(&a, as: Float.self, count: n) { Float($0) }
        let expected = (0 ..< n).map { Float($0) }
        #expect(readNDArray(a, as: Float.self, count: n) == expected)
    }

    /// [2,2,2,2] = 16 elems, rank-4 fast path.
    @Test("4D [2,2,2,2] fill/read roundtrip preserves 16 elements in order")
    func fourDimensionalRoundTrip() {
        guard #available(macOS 27.0, *) else { return }
        let n = 2 * 2 * 2 * 2
        var a = NDArray(shape: [2, 2, 2, 2], scalarType: .float32)
        fillNDArray(&a, as: Float.self, count: n) { Float($0) }
        let expected = (0 ..< n).map { Float($0) }
        #expect(readNDArray(a, as: Float.self, count: n) == expected)
    }

    /// A `readNDArray` with `count < total` returns only the first `count`
    /// logical elements (fast path is a straight prefix read; the stride-aware
    /// slow path walks row-major indices for `count` steps — either way the
    /// prefix is what a `[shape]` producer expects).
    @Test("readNDArray honors count as a prefix of the logical element walk")
    func prefixCount() {
        guard #available(macOS 27.0, *) else { return }
        var a = NDArray(shape: [3, 4], scalarType: .float32)
        fillNDArray(&a, as: Float.self, count: 12) { 100 + Float($0) }
        let prefix = readNDArray(a, as: Float.self, count: 5)
        #expect(prefix == [100, 101, 102, 103, 104])
    }
}

#endif
