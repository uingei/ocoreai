// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// BackendProtocol.swift — Inference backend abstraction
///
/// Protocol that every inference backend (CoreAI, MLX, stub) must satisfy.
/// EnginePool delegates loading and inference to the active backend
/// instead of containing conditional code.

import Foundation
import Logging

// MARK: - Backend Identity

/// Backend capability descriptor.
struct BackendDescriptor: Sendable {
    /// Human-readable backend name
    let name: String

    /// Whether this backend supports streaming token generation
    let supportsStreaming: Bool

    /// Whether this backend supports session pooling (KV cache reuse)
    let supportsSessionPool: Bool

    static let coreai = BackendDescriptor(name: "CoreAI", supportsStreaming: true, supportsSessionPool: false)
    static let mlx = BackendDescriptor(name: "MLXLLM", supportsStreaming: true, supportsSessionPool: true)
    static let stub = BackendDescriptor(name: "Stub", supportsStreaming: false, supportsSessionPool: false)
}

// MARK: - Protocol

/// Capability every inference backend must provide.
///
/// EnginePool delegates loading and inference to the active backend instead
/// of containing conditional backend code.
protocol BackendProtocol: Sendable {
    var descriptor: BackendDescriptor { get }

    func loadModel(modelId: String, configData: Data, modelURL: URL, logger: Logger) async throws -> BackendModelHandle

    func releaseModel(_ handle: BackendModelHandle)

    func generate(handle: BackendModelHandle, input: [Int32], sampling: SamplingConfiguration, options: InferenceOptions, completion: @Sendable (InferenceEvent) -> Void) async throws
}

// MARK: - Backend Model Handle (opaque)

/// Opaque handle returned by backend after model load.
/// Concrete backends store their internal pointer/struct here.
struct BackendModelHandle: @unchecked Sendable {
    let backendName: String
    var payload: NSObject
    init(backendName: String, payload: NSObject) {
        self.backendName = backendName
        self.payload = payload
    }
}
