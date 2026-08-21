// Copyright 2026 Apple Inc. (BSD-3-Clause) — resolvedStrides helper from CoreAIShared
// Copied for use within CoreAIPipelinedEngine's @available scope.

#if canImport(CoreAI)
import CoreAI

/// Resolve strides from an NDArrayDescriptor for a given concrete shape.
@available(macOS 27.0, iOS 27.0, *)
func resolvedStrides(descriptor: NDArrayDescriptor, shape: [Int]) throws -> [Int] {
    let resolved = descriptor.resolvingDynamicDimensions(shape)
    return resolved.preferredStrides
}

/// Product of the elements of a `Span<Int>` — used to compute the flat capacity
/// from an `NDArray` shape. `Span` doesn't conform to `Sequence` (non-escapable
/// by design), so `.reduce` isn't available.
///
/// Copied for the `fillNDArray` / `readNDArray` bound checks, matching upstream
/// `NDArray+Helpers.swift` (CoreAIShared).
@available(macOS 27.0, iOS 27.0, *)
extension Span where Element == Int {
    var product: Int {
        var result = 1
        for i in 0 ..< count {
            result *= self[i]
        }
        return result
    }
}

/// Check whether a shape+strides pair represents a contiguous row-major layout.
///
/// Fast-path predicate for `fillNDArray` / `readNDArray`: when true the
/// underlying buffer can be indexed linearly (`ptr[i]`); otherwise the
/// stride-aware walk in those helpers is required to land on the correct
/// element for GPU-aligned (non-contiguous) 4D+ tensors.
@available(macOS 27.0, iOS 27.0, *)
func isContiguousRowMajor(shape: Span<Int>, strides: Span<Int>) -> Bool {
    let rank = shape.count
    var expectedStride = 1
    for d in (0 ..< rank).reversed() {
        if strides[d] != expectedStride { return false }
        expectedStride *= shape[d]
    }
    return true
}
#endif
