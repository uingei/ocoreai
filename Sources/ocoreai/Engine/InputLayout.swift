// Copyright 2026 Apple Inc.
//
// Absorbed from coreai-models 27a66f9 (#227, fix #212) — 2026-09-07.
// BSD-3-Clause (Apple Inc.). Upstream: swift/Sources/CoreAILanguageModels/Handlers/InputLayout.swift.
//
// Ocoreai adaptation:
//  - Uses ocoreai's `InferenceRuntimeError` (Engine/CoreAIStubs.swift, pure Foundation error enum,
//    no @available — only compiled when #if canImport(CoreAI) succeeds, matching upstream).
//  - `analyze(model:functionName:config:)` takes ocoreai's internal `InternalModelConfig`,
//    so it is internal (not public). The pure-logic `analyze(inputNames:...)` overload is the
//    testable surface — it builds the policies from raw descriptor info without a model.
//  - Gated only by `#if canImport(CoreAI)` (CoreAI framework = macOS 27 SDK). All consumers are
//    already in the CoreAI-gated engine files, so no per-member @available is needed here,
//    matching upstream.
//
// #212: S=1 bundles (Qwen3.5 GDN) have a *static* `[1, 1, vocab]` logits descriptor.
// The old pipelined engine sized `GrowingLogitsBuffer` to 256 rows against that static
// descriptor → buffer size mismatch → crash at init. `InputLayout` detects the fixed
// seqLen at init and pins both `initialCapacity` and `maxCapacity` to 1, so the
// buffer matches the descriptor contract exactly.

#if canImport(CoreAI)
import CoreAI

/// Shared descriptor analysis, built once at engine init.
///
/// Encapsulates name resolution and shape policies (query, logits, position, prefill)
/// so engines no longer duplicate descriptor inspection or get the logic wrong.
public struct InputLayout: Sendable {
    public let inputIdsName: String
    public let positionIdsName: String
    public let logitsName: String

    public let queryPolicy: QueryPolicy
    public let logitsPolicy: LogitsPolicy
    public let positionPolicy: PositionPolicy
    public let prefillPolicy: PrefillPolicy

    public enum QueryPolicy: Sendable, Equatable {
        case dynamic
        case fixed(Int)
    }

    public enum LogitsPolicy: Sendable, Equatable {
        case dynamic
        case fixed(seqLen: Int)
    }

    public enum PositionPolicy: Sendable, Equatable {
        case full
        case compact
    }

    public enum PrefillPolicy: Sendable, Equatable {
        case prefillGraph
        case chunk(threshold: Int, chunkSize: Int)
    }
}

extension InputLayout {

    /// Analyze a model function descriptor and derive all shape/name policies.
    /// Availability-gated: the `AIModel` parameter and descriptor API are CoreAI
    /// (macOS 27+). Callers are the 27-gated engines.
    @available(macOS 27.0, iOS 27.0, *)
    static func analyze(
        model: AIModel,
        functionName: String,
        config: InternalModelConfig,
        useCompactPositionIds: Bool
    ) throws -> InputLayout {
        guard let descriptor = model.functionDescriptor(for: functionName) else {
            throw InferenceRuntimeError.invalidArgument(
                "Cannot find function '\(functionName)' in model")
        }
        guard !descriptor.outputNames.isEmpty else {
            throw InferenceRuntimeError.invalidOutputType(
                "Expected at least 1 output, got 0")
        }

        // Resolve input names from candidates (handles in_new_token_ids, pos_ids, etc.)
        let inputIdsName = try resolveRequired(
            from: descriptor.inputNames,
            candidates: knownInputIdNames,
            label: "input_ids")
        let logitsName = descriptor.outputNames[0]

        // Detect fixed (static) sequence lengths from the descriptor shapes.
        // shape[1] == seqLen; negative or zero means dynamic.
        let inputIdsSeqLen: Int?
        if case .ndArray(let desc) = descriptor.inputDescriptor(of: inputIdsName),
            desc.shape.count >= 2, desc.shape[1] > 0
        {
            inputIdsSeqLen = desc.shape[1]
        } else {
            inputIdsSeqLen = nil
        }

        let logitsSeqLen: Int?
        if case .ndArray(let desc) = descriptor.outputDescriptor(of: logitsName),
            desc.shape.count >= 2, desc.shape[1] > 0
        {
            logitsSeqLen = desc.shape[1]
        } else {
            logitsSeqLen = nil
        }

        let hasPrefillGraph = model.functionDescriptor(for: prefillGraphFunctionName) != nil

        return try analyze(
            inputNames: descriptor.inputNames,
            outputNames: descriptor.outputNames,
            inputIdsSeqLen: inputIdsSeqLen,
            logitsSeqLen: logitsSeqLen,
            chunkThreshold: config.chunkThreshold,
            chunkSize: config.prefillChunkSize,
            hasPrefillGraph: hasPrefillGraph,
            useCompactPositionIds: useCompactPositionIds)
    }

    /// Pure-logic analyze (testable without a model).
    static func analyze(
        inputNames: [String],
        outputNames: [String],
        inputIdsSeqLen: Int?,
        logitsSeqLen: Int?,
        chunkThreshold: Int,
        chunkSize: Int,
        hasPrefillGraph: Bool,
        useCompactPositionIds: Bool
    ) throws -> InputLayout {
        guard !outputNames.isEmpty else {
            throw InferenceRuntimeError.invalidOutputType(
                "Expected at least 1 output, got 0")
        }

        let inputIdsName = try resolveRequired(
            from: inputNames, candidates: knownInputIdNames, label: "input_ids")
        let positionIdsName = try resolveRequired(
            from: inputNames, candidates: knownPositionIdNames, label: "position_ids")
        let logitsName = outputNames[0]

        let queryPolicy: QueryPolicy =
            if let s = inputIdsSeqLen, s > 0 { .fixed(s) } else { .dynamic }

        let logitsPolicy: LogitsPolicy =
            if let s = logitsSeqLen, s > 0 { .fixed(seqLen: s) } else { .dynamic }

        let positionPolicy: PositionPolicy = useCompactPositionIds ? .compact : .full

        let prefillPolicy: PrefillPolicy
        if hasPrefillGraph {
            prefillPolicy = .prefillGraph
        } else if case .fixed(let q) = queryPolicy {
            // Static S=1 bundles: prefill is exactly the fixed query width; no threshold.
            prefillPolicy = .chunk(threshold: q, chunkSize: q)
        } else {
            prefillPolicy = .chunk(threshold: chunkThreshold, chunkSize: chunkSize)
        }

        return InputLayout(
            inputIdsName: inputIdsName,
            positionIdsName: positionIdsName,
            logitsName: logitsName,
            queryPolicy: queryPolicy,
            logitsPolicy: logitsPolicy,
            positionPolicy: positionPolicy,
            prefillPolicy: prefillPolicy)
    }

    static let knownInputIdNames = ["input_ids", "in_new_token_ids"]
    static let knownPositionIdNames = ["position_ids", "pos_ids"]

    static func resolveRequired(
        from names: [String], candidates: [String], label: String
    ) throws -> String {
        for c in candidates where names.contains(c) { return c }
        throw InferenceRuntimeError.invalidState(
            "No \(label) input found. Expected one of \(candidates), got \(names)")
    }
}

#endif
