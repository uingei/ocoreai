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
#endif
