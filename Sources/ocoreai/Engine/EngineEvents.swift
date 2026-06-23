// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// EngineEvents.swift — Inference cancellation token and event stream types
///
/// Extracted from EngineManager.swift — these two types are
/// imported across Engine/Models/Handlers as the contract between
/// the engine pool and the HTTP inference pipeline.

import Foundation

// MARK: - Cancellation Token

/// Lightweight cancellation token for propagating cancellation across task boundaries.
///
/// Used by SSE handlers to cancel inference running in unrelated root Tasks.
struct InferenceCancellation: Sendable {
    private let _token: Task<Void, Error>?

    /// Non-cancellable handle (used for non-stream endpoints)
    static let none: Self = .init()

    /// Cancellable handle — cancels underlying task when ``cancel()`` is called
    static func cancellable() -> Self {
        .init(_token: Task { () })
    }

    /// Check if this token has been cancelled
    /// - Returns: true if the cancel signal has been sent
    var isCancelled: Bool {
        _token?.isCancelled == true
    }

    /// Send cancellation signal to all holders of this token
    func cancel() {
        _token?.cancel()
    }

    private init(_token: Task<Void, Error>? = nil) {
        self._token = _token
    }
}

// MARK: - Inference Event

/// Unified event type streamed from the inference pipeline to the handler.
///
/// Events flow through ``AsyncThrowingStream`` so the HTTP layer can emit SSE chunks.
struct InferenceEvent: Sendable {
    /// Event kind discriminator
    enum Kind: Sendable {
        /// Generated token (`Int32` token ID — Core AI path)
        case token(Int32)

        /// Generated text chunk (MLX path — already decoded)
        case text(String)

        /// Generation complete (optional `StopReason`)
        case done(StopReason?)

        /// Fatal inference error
        case error(String)
    }

    /// Event payload
    var kind: Kind
}
