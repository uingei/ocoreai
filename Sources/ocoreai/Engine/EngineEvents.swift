// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EngineEvents.swift — Inference cancellation token and event stream types
///
/// Extracted from EngineManager.swift — these two types are
/// imported across Engine/Models/Handlers as the contract between
/// the engine pool and the HTTP inference pipeline.

import Foundation
import MLXLMCommon

// MARK: - Cancellation Token

/// Lightweight cancellation token for propagating cancellation across task boundaries.
///
/// Thread-safe via `NSRecursiveLock` — no `@unchecked Sendable`, no raw pointers,
/// no manual lifetime management. Replaced the prior `os_unfair_lock` design.
final class CancellationFlag: @unchecked Sendable {
    private var _cancelled = false
    private let _lock = NSRecursiveLock()

    var isCancelled: Bool {
        _lock.lock()
        defer { _lock.unlock() }
        return _cancelled
    }

    func cancel() {
        _lock.lock()
        defer { _lock.unlock() }
        _cancelled = true
    }
}

/// Sentinel that bundles a cancellation flag with Sendable semantics.
///
/// `.none` for non-stream endpoints; `.cancellable()` for SSE/async streams
/// where client disconnect must stop GPU work.
struct InferenceCancellation: Sendable {
    private let _flag: CancellationFlag?

    /// Non-cancellable handle (used for non-stream endpoints)
    static let none: Self = .init()

    /// Cancellable handle — allocates a fresh flag
    static func cancellable() -> Self {
        .init(_flag: CancellationFlag())
    }

    /// Check if this token has been cancelled
    /// - Returns: true if the cancel signal has been sent
    var isCancelled: Bool {
        _flag?.isCancelled ?? false
    }

    /// Send cancellation signal to all holders of this token
    func cancel() {
        _flag?.cancel()
    }

    private init(_flag: CancellationFlag? = nil) {
        self._flag = _flag
    }
}

// MARK: - Inference Event

/// Unified event type streamed from the inference pipeline to the handler.
///
/// Events flow through ``AsyncThrowingStream`` so the HTTP layer can emit SSE chunks.
struct InferenceEvent {
    /// Event kind discriminator
    enum Kind {
        /// Generated token (`Int32` token ID — Core AI path)
        case token(Int32)

        /// Generated reasoning chunk (upstream ReasoningEventEmitter routed)
        case reasoning(String)

        /// Generated text chunk (MLX path — already decoded)
        case text(String)

        /// Generation complete metadata — carries actual token count from upstream
        /// when available. Essential for accurate token budgeting on MLX backend
        /// where `.chunk` = one-or-more tokens. Both promptTokPerSec and tokPerSec
        /// sourced from upstream GenerateCompletionInfo — not locally estimated.
        /// MTP/speculative decoding metrics (proposedDraftTokens, acceptedDraftTokens,
        /// passthroughReason) sourced from GenerateCompletionInfo when MTP iterates are active.
        case done(
            StopReason,
            tokenCount: Int?,
            tokPerSec: Double? = nil,
            promptTokPerSec: Double? = nil,
            reasoningTokenCount: Int? = nil,
            proposedDraftTokens: Int? = nil,
            acceptedDraftTokens: Int? = nil,
            passthroughReason: String? = nil
        )

        /// Fatal inference error
        case error(String)

        /// Structured tool call detected upstream by TextToolTokenLoopHandler.
        /// Carries the ocoreai ``ToolCall`` (from OpenAIModels) which is decoded from
        /// the upstream ``MLXLMCommon/ToolCall`` via `InferenceEvent.mlxToolCall(from:)`.
        case toolCall(ToolCall)

        /// Structured diagnostic: guided generation metadata.
        /// - grammarTerminated: true if the grammar constraint accepted the output
        ///   (JSON was completed and validated by the grammar).
        /// - incompleteOutput: true if maxTokens budget was exhausted before the model
        ///   could complete its response upstream (GuidedGenerationError.incompleteOutput).
        case guidedGenDiagnostic(grammarTerminated: Bool, incompleteOutput: Bool)

        /// Structured diagnostic: incomplete output signal from FM / MLX path.
        /// Upstream emitMetadata with "incompleteOutput": true — the model
        /// was cut off mid-response (budget exceeded, reasoning interrupted, etc.).
        case incompleteOutput(Bool)

        /// Compute channel identification for UI display.
        /// Identifies which inference pipeline produced this event:
        /// - .gpu: MLX Metal path or FM Executor path (macOS/iOS 27+)
        /// - .cpu: CPU fallback path
        /// - .ane: CoreAI engine path (ANE offload)
        case channel(ComputeChannel)

        /// Prefill progress update — emitted after each prefill chunk.
        /// Carries (processed, total) position counts from upstream
        /// PrefillParameters.progress so the HTTP/SSE layer can report
        /// prefill progress to the client in real-time.
        /// Upstream: PrefillParameters.swift L26-32.
        case prefillProgress(processed: Int, total: Int)
    }

    /// Event payload
    var kind: Kind
}

// MARK: - Upstream → ocoreai type bridge

extension InferenceEvent {
    /// Bridge: upstream `MLXLMCommon.ToolCall` (`[String: JSONValue]` arguments)
    /// → ocoreai `ToolCall` (JSON-string arguments).
    static func mlxToolCall(from mlx: MLXLMCommon.ToolCall) -> ToolCall {
        let argsJSON: String
        do {
            let mapped = mlx.function.arguments.mapValues { $0.anyValue }
            let data = try JSONSerialization.data(withJSONObject: mapped)
            argsJSON = String(decoding: data, as: UTF8.self)
        } catch {
            argsJSON = "{}"
        }
        return ToolCall(
            id: mlx.id ?? "",
            type: "function",
            function: ToolCallFunction(name: mlx.function.name, arguments: argsJSON)
        )
    }
}
