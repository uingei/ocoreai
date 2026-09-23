// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// StateHandler fix — `GrowingNDArrayState.ensureCapacity` (KV growth) and
// `reset()` now move/zero state explicitly, aligned with upstream
// coreai-models `StateHandler+NDArray.swift` (copyCache / zeroFillNDArray, #268).
//
// Root cause fixed: the old `ensureCapacity` allocated a fresh NDArray on growth
// WITHOUT copying the already-encoded K/V rows, and `reset()` relied on the
// allocator zero-initialing. On the CoreAI sequential path any KV growth
// (chunked prefill: prompt > ~2*chunkSize; multi-turn history; long decode past
// the initial capacity) therefore silently dropped context; and BFloat16 KV
// models (gpt-oss-style) could trap on the typed-view path.
//
// These tests pin the data-movement contract at the primitive level, on the
// SAME shape convention `GrowingNDArrayState` uses — `[1,1,1,capacity]` with
// capacity as the last (growing) axis (`KVCacheFactory.detectSequenceDim` / the
// many `resolvingDynamicDimensions([... , capacity])` call sites).
//
// Guarded `#if canImport(CoreAI)` (identical to NDArrayHelpersAlignmentTests);
// each body carries `#available(macOS 27.0, *)` (the @Test macro does not
// accept @available — same convention as NDArrayHelpersAlignmentTests).

import Foundation
import Testing

#if canImport(CoreAI)
import CoreAI

@testable import ocoreai

@Suite("StateHandler growth/reset (KV cache data preservation)")
struct StateHandlerGrowthTests {

    /// Layout for every case here: `[1,1,1,capacity]`, capacity = last axis (3).
    /// This is exactly `StateHandlerFactory`'s resolved shape and is what
    /// `copyStateCache`, called with `sequenceDimIndex` (= 3), is expected to
    /// preserve.

    // MARK: - copyStateCache (growth preserves existing rows)

    /// The core of the fix: on growth the old rows survive in the new buffer.
    /// A regressed "just allocate a fresh buffer" impl leaves the destination
    /// zero and fails this.
    @Test("copyStateCache (Float32) preserves existing rows when growing [1,1,1,old]→[1,1,1,new]")
    func float32PreservesRowsOnGrow() {
        guard #available(macOS 27.0, *) else { return }
        let oldCap = 8
        let newCap = 32
        var src = NDArray(shape: [1, 1, 1, oldCap], scalarType: .float32)
        fillNDArray(&src, as: Float.self, count: oldCap) { Float(100) + Float($0) }
        let expectedOld = (0 ..< oldCap).map { Float(100) + Float($0) }

        var dst = NDArray(shape: [1, 1, 1, newCap], scalarType: .float32)
        copyStateCache(from: src, to: &dst, sequenceDim: 3)

        let got = readNDArray(dst, as: Float.self, count: newCap)
        #expect(
            Array(got[0 ..< expectedOld.count]) == expectedOld,
            "existing KV rows must survive growth")
    }

    /// Same preservation on the 16-bit raw-view path.
    @Test("copyStateCache (Float16) preserves existing rows when growing")
    func float16PreservesRowsOnGrow() {
        guard #available(macOS 27.0, *) else { return }
        let oldCap = 8
        let newCap = 64
        var src = NDArray(shape: [1, 1, 1, oldCap], scalarType: .float16)
        fillNDArray(&src, as: Float16.self, count: oldCap) { 1.0 + Float16($0) }
        let expectedOld = (0 ..< oldCap).map { 1.0 + Float16($0) }

        var dst = NDArray(shape: [1, 1, 1, newCap], scalarType: .float16)
        copyStateCache(from: src, to: &dst, sequenceDim: 3)

        let got = readNDArray(dst, as: Float16.self, count: newCap)
        #expect(
            Array(got[0 ..< expectedOld.count]) == expectedOld,
            "existing KV rows must survive growth")
    }

    /// BFloat16 is the class upstream fixed in #268 (a typed view traps; our
    /// copy is a raw byte copy). Verify the copy works AND never traps on bf16.
    @Test(
        "copyStateCache (BFloat16) preserves existing rows without the typed-view trap (#268 path)")
    func bfloat16PreservesRowsOnGrow() {
        guard #available(macOS 27.0, *) else { return }
        let oldCap = 8
        let newCap = 32
        var src = NDArray(shape: [1, 1, 1, oldCap], scalarType: .bfloat16)
        // Distinct bf16 bit values so a no-op copy (all-zero dst) is detectable.
        src.mutableRawView().withUnsafeMutableBytes { ptr, _, _ in
            let u16 = ptr.assumingMemoryBound(to: UInt16.self)
            for i in 0 ..< oldCap { u16[i] = UInt16(0x4000 + i) }
        }

        var dst = NDArray(shape: [1, 1, 1, newCap], scalarType: .bfloat16)
        copyStateCache(from: src, to: &dst, sequenceDim: 3)

        var ok = true
        dst.rawView().withUnsafeBytes { ptr, _, _ in
            let u16 = ptr.assumingMemoryBound(to: UInt16.self)
            for i in 0 ..< oldCap {
                if u16[i] != UInt16(0x4000 + i) {
                    ok = false
                    break
                }
            }
        }
        #expect(
            ok, "existing BFloat16 KV rows must survive growth (raw byte copy, no typed-view trap)")
    }

    /// Guard: the helper must not copy past the source (no out-of-bounds read)
    /// when the destination is larger — it copies exactly `oldCap` elements.
    @Test("copyStateCache (Float32) copies exactly the old rows, never beyond the source")
    func noOutOfBoundsCopy() {
        guard #available(macOS 27.0, *) else { return }
        let oldCap = 4
        let newCap = 512
        var src = NDArray(shape: [1, 1, 1, oldCap], scalarType: .float32)
        fillNDArray(&src, as: Float.self, count: oldCap) { Float(50) + Float($0) }
        let expectedOld = (0 ..< oldCap).map { Float(50) + Float($0) }

        var dst = NDArray(shape: [1, 1, 1, newCap], scalarType: .float32)
        copyStateCache(from: src, to: &dst, sequenceDim: 3)

        let got = readNDArray(dst, as: Float.self, count: newCap)
        #expect(Array(got[0 ..< expectedOld.count]) == expectedOld)
        // The remainder was freshly allocated (zero), NOT copied from source.
        #expect(
            got[oldCap...].allSatisfy { $0 == 0 },
            "only the old `oldCap` rows are copied; the rest stays the fresh allocation")
    }

    // MARK: - zeroFillNDArray (reset zeroes, every scalar type)

    @Test("zeroFillNDArray (Float32) zeroes the whole tensor")
    func zeroFillFloat32() {
        guard #available(macOS 27.0, *) else { return }
        var a = NDArray(shape: [1, 1, 1, 16], scalarType: .float32)
        fillNDArray(&a, as: Float.self, count: 16) { _ in 1.0 }
        zeroFillNDArray(&a)
        #expect(
            readNDArray(a, as: Float.self, count: 16).allSatisfy { $0 == 0 },
            "reset() must zero the state, not leave stale bytes")
    }

    @Test("zeroFillNDArray (Float16) zeroes the whole tensor")
    func zeroFillFloat16() {
        guard #available(macOS 27.0, *) else { return }
        var a = NDArray(shape: [1, 1, 1, 16], scalarType: .float16)
        fillNDArray(&a, as: Float16.self, count: 16) { _ in 1.0 }
        zeroFillNDArray(&a)
        #expect(
            readNDArray(a, as: Float16.self, count: 16).allSatisfy { $0 == 0 },
            "reset() must zero the state, not leave stale bytes")
    }

    @Test(
        "zeroFillNDArray (BFloat16) zeroes the whole tensor without the typed-view trap (#268 path)"
    )
    func zeroFillBfloat16() {
        guard #available(macOS 27.0, *) else { return }
        var a = NDArray(shape: [1, 1, 1, 16], scalarType: .bfloat16)
        a.mutableRawView().withUnsafeMutableBytes { ptr, _, _ in
            let u16 = ptr.assumingMemoryBound(to: UInt16.self)
            for i in 0 ..< 16 { u16[i] = 0x3F80 }  // 1.0 in bf16
        }
        zeroFillNDArray(&a)
        var nonzero = false
        a.rawView().withUnsafeBytes { ptr, _, _ in
            let u16 = ptr.assumingMemoryBound(to: UInt16.self)
            for i in 0 ..< 16 {
                if u16[i] != 0 {
                    nonzero = true
                    break
                }
            }
        }
        #expect(
            !nonzero,
            "reset() must zero a BFloat16 state (all-zero bit pattern, no typed-view trap)")
    }
}

#endif
