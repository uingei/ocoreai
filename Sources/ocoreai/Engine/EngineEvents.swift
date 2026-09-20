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
        ///
        /// `cachedPromptTokens` (when non-nil) = prompt tokens served by a reused KV-cache
        /// prefix, upstream `GenerateCompletionInfo.cachedPromptTokenCount` (mlx-swift-lm
        /// pinned 604fae7, Evaluate.swift:2512 — ChatSession attributes it from its cache
        /// reuse decision). `0` = whole prompt prefilled (no reuse) — a known value, not
        /// "unknown"; nil = path without a GenerateCompletionInfo (guided/FM/CoreAI).
        case done(
            StopReason,
            tokenCount: Int?,
            promptTokenCount: Int? = nil,
            tokPerSec: Double? = nil,
            promptTokPerSec: Double? = nil,
            reasoningTokenCount: Int? = nil,
            cachedPromptTokens: Int? = nil,
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

        /// A dispatched tool call **finished** — carries the truthful outcome
        /// (success/failure) + condensed result summary + **measured** wall duration.
        ///
        /// Baseline: codex protocol surface treats tool output as a first-class event
        /// (`function_call_output`). Upstream mlx-swift-lm `Generation` has NO
        /// completion event (only `.toolCall` / `.rejectedToolCall`), so this is the
        /// ocoreai-owned surface that closes the GUI tool-card gap (resultSummary /
        /// durationMs). Emitted once per dispatch from `toolDispatchClosure` after the
        /// real `ToolRegistry.call` returns; **failure (denied / error) also surfaces**
        /// so the UI never shows a finished call as still-running, and repeated
        /// denials become visible to the user instead of a silent retry loop.
        case toolResult(ToolResultMeta)

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

/// Truthful outcome of one completed tool dispatch (see `Kind.toolResult`).
///
/// `durationMs` is the **measured** wall time around the real
/// `ToolRegistry.call` (not an estimate); `failure` is non-nil for denial or
/// handler-level errors so the UI can distinguish "ran and failed" from
/// "still running" instead of a call with a nil summary.
struct ToolResultMeta: Sendable, Codable {
    let id: String
    let name: String
    let resultSummary: String
    let durationMs: Double
    let failure: String?

    /// Condense a tool result into a UI-safe summary. Long outputs (file
    /// dumps, logs) are capped so a single card cannot dominate the transcript.
    static func summary(_ text: String, limit: Int = 200) -> String {
        let squashed = text.replacingOccurrences(of: "\n", with: " ")
        if squashed.count <= limit { return squashed }
        return String(squashed.prefix(limit)) + "…"
    }
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
