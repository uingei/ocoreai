// Copyright 2026 Apple Inc. (BSD-3-clause upstream)
// Adapted for ocoreai — aligned with coreai-models HEAD a5ece33
//
// Shared inference types: InferenceRuntimeError, fillNDArray, readNDArray,
// lastTokenLogits.
//
// All gated behind #if canImport(CoreAI) + @available(macOS 27, iOS 27).

import Foundation

#if canImport(CoreAI)
import CoreAI

@available(macOS 27.0, iOS 27.0, *)
public enum InferenceRuntimeError: Error, LocalizedError {
    case functionNotFound(String)
    case modelNotFound(String)
    case modelLoadingFailed(String)
    case invalidState(String)
    case invalidArgument(String)
    case logitsExtractionFailed
    case invalidInputType(String)
    case invalidOutputType(String)
    case unsupportedLogitsType(String)
    case unsupportedTokenType(String)
    case contextLengthExceeded(Int, Int)
    case unsupportedEngine(String)
    case unsupportedEngineVariant(String)
    case bufferAllocationFailed(String)
    case genericError(String)

    public var errorDescription: String? {
        switch self {
        case .functionNotFound(let name):
            return "Function '\(name)' not found in model"
        case .modelNotFound(let path):
            return "Model not found at '\(path)'"
        case .modelLoadingFailed(let msg):
            return "Model loading failed: \(msg)"
        case .invalidState(let msg):
            return "Invalid model state: \(msg)"
        case .invalidArgument(let msg):
            return "Invalid argument: \(msg)"
        case .logitsExtractionFailed:
            return "Failed to extract logits from model output"
        case .invalidInputType(let msg):
            return "Invalid input type: \(msg)"
        case .invalidOutputType(let msg):
            return "Invalid output type: \(msg)"
        case .unsupportedLogitsType(let msg):
            return "Unsupported logits type: \(msg)"
        case .unsupportedTokenType(let msg):
            return "Unsupported token type: \(msg)"
        case .contextLengthExceeded(let current, let max):
            return "Context length \(current) exceeded maximum of \(max)"
        case .unsupportedEngine(let msg):
            return "Unsupported engine: \(msg)"
        case .unsupportedEngineVariant(let msg):
            return "Unsupported engine variant: \(msg)"
        case .bufferAllocationFailed(let msg):
            return "Buffer allocation failed: \(msg)"
        case .genericError(let msg):
            return msg
        }
    }
}

// MARK: - NDArray Fill Helpers (aligned with upstream NDArray+Helpers.swift)

@available(macOS 27.0, iOS 27.0, *)
func fillNDArray<T: BitwiseCopyable>(
    _ array: inout NDArray,
    as type: T.Type,
    with elements: some Collection<T>
) {
    var view = array.mutableView(as: type)
    view.copyElements(fromContentsOf: elements)
}

@available(macOS 27.0, iOS 27.0, *)
func fillNDArray<T: BitwiseCopyable>(
    _ array: inout NDArray,
    as type: T.Type,
    count: Int,
    using generator: (Int) -> T
) {
    var view = array.mutableView(as: type)
    view.withUnsafeMutablePointer { ptr, shape, _ in
        for i in 0 ..< count {
            ptr[i] = generator(i)
        }
    }
}

// MARK: - NDArray Read Helper

@available(macOS 27.0, iOS 27.0, *)
func readNDArray<T: BitwiseCopyable>(
    _ array: NDArray,
    as type: T.Type,
    count: Int
) -> [T] {
    var result = [T]()
    result.reserveCapacity(count)
    array.view(as: type).withUnsafePointer { ptr, shape, _ in
        for i in 0 ..< count {
            result.append(ptr[i])
        }
    }
    return result
}

// MARK: - Logits Utilities (aligned with upstream KVCacheShared.swift)

@available(macOS 27.0, iOS 27.0, *)
func lastTokenLogits(from logitBuffer: [LogitsScalarType], vocabSize: Int) -> [LogitsScalarType] {
    guard logitBuffer.count > vocabSize else { return logitBuffer }
    let tokensInBuffer = logitBuffer.count / vocabSize
    let lastTokenOffset = (tokensInBuffer - 1) * vocabSize
    return Array(logitBuffer[lastTokenOffset ..< (lastTokenOffset + vocabSize)])
}

#endif  // canImport(CoreAI)
