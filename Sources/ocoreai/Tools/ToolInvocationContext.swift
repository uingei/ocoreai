// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! ToolInvocationContext.swift — which conversation owns the tool call that is running.
//!
//! ### Why this exists
//! A tool that *waits* has to know whose input can end the wait. `SteerQueue` is keyed by
//! conversation (`sessionId` or `<modelId>:ephemeral`), so a wake condition that ignores the
//! key would let one conversation's typing interrupt another conversation's agent — the same
//! cross-session leak this repo already closed on the session-pool side (`SessionIsolationTests`,
//! `ConversationIdentity.seed`). The engine knows the key at its dispatch site
//! (`EngineInference.swift`: `SteerQueue.shared.drain(sessionKey: convKey)`); the tool handler
//! signature is `(String) async throws -> String` and does not carry it.
//!
//! So the key travels as a task local, **set at one place**: ``ToolRegistry/call(_:arguments:caller:headless:conversationKey:)``,
//! the chokepoint every dispatch goes through (native MLX tool loop, MTP loop, GUI, MCP server).
//! Call sites hand in the key they already hold; no tool re-derives it from a model id, an env
//! var, or a global — those are the second-identity schemes that drift.
//!
//! ### What absent means
//! `nil` when the caller has no conversation, or when the lane has no mid-turn seam to deliver
//! to: an MCP `tools/call` from another process, the FoundationModels lane (no steer drain
//! inside its turn — a wake there would report an interruption whose text never reaches the
//! model), a proactive GUI read outside any turn, a unit harness. Tools must then *not* claim
//! the session-scoped behaviour: `sleep` runs its full duration and reports `Sleep completed.`
//! rather than inventing an interruption (AGENTS.md invariant 2 — the surface never claims more
//! than the engine delivered).

import Foundation

/// Session-scoped facts about the tool call executing on the current task.
enum ToolInvocationContext {
    /// The conversation key that owns this call — the exact string ``SteerQueue`` is keyed by,
    /// so "is input pending for this turn?" stays one dictionary lookup instead of a second
    /// identity scheme. Propagates to child tasks (`Task { }` inherits task locals), which is
    /// what lets a handler hop into an actor or a detached helper and still answer honestly.
    @TaskLocal static var conversationKey: String?
}
