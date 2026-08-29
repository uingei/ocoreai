// Copyright 2026 Apple Inc. (BSD-3-Clause)
// Copied from coreai-models, wrapped in struct for @available compatibility.
// Provenance: aligned with coreai-models Handlers/StateHandler+Encode.swift @ a5ece33 (2026-08-18 audit: 0 commits changed this file a5ece33..21dc8ad — anchor current).

#if canImport(CoreAI)
import CoreAI
import Metal

@available(macOS 27.0, iOS 27.0, *)
enum _CoreAIEncodeHelpers {
    /// Encode an inference step with KV cache states, optional additional MTLBuffer
    /// states, and logits output.
    static func encodeWithStates(
        function: InferenceFunction,
        inputs: [String: InferenceFunction.AsyncValue],
        keyState: inout InferenceFunction.AsyncMutableValue,
        keyCacheName: String,
        valState: inout InferenceFunction.AsyncMutableValue,
        valueCacheName: String,
        additionalStates: FixedMTLBufferState?,
        logitsBuffer: MTLBuffer,
        logitsName: String,
        logitsShape: [Int],
        logitsStrides: [Int],
        computeStream: ComputeStream
    ) throws {
        var asyncStates = InferenceFunction.AsyncMutableViews()
        asyncStates.insert(&keyState, for: keyCacheName)
        asyncStates.insert(&valState, for: valueCacheName)
        additionalStates?.bind(into: &asyncStates)

        var logitsOutput = unsafe InferenceFunction.AsyncMutableValue(
            unsafeBuffer: logitsBuffer, byteOffset: 0,
            scalarType: .float16, shape: logitsShape, strides: logitsStrides)
        var asyncOutputs = InferenceFunction.AsyncMutableViews()
        asyncOutputs.insert(&logitsOutput, for: logitsName)
        let _ = try function.encode(
            inputs: inputs, states: consume asyncStates,
            outputViews: consume asyncOutputs, to: computeStream)
    }

    /// Encode an inference step that declares no outputs — for the `prefill` graph, which
    /// only fills KV cache states and produces no logits.
    static func encodeWithStatesNoOutputs(
        function: InferenceFunction,
        inputs: [String: InferenceFunction.AsyncValue],
        keyState: inout InferenceFunction.AsyncMutableValue,
        keyCacheName: String,
        valState: inout InferenceFunction.AsyncMutableValue,
        valueCacheName: String,
        additionalStates: FixedMTLBufferState?,
        computeStream: ComputeStream
    ) throws {
        var asyncStates = InferenceFunction.AsyncMutableViews()
        asyncStates.insert(&keyState, for: keyCacheName)
        asyncStates.insert(&valState, for: valueCacheName)
        additionalStates?.bind(into: &asyncStates)

        let _ = try function.encode(
            inputs: inputs, states: consume asyncStates,
            outputViews: InferenceFunction.AsyncMutableViews(), to: computeStream)
    }
}
#endif
