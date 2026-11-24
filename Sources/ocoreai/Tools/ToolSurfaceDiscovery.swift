// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ToolSurfaceDiscovery.swift. The per-conversation discovered set of the reachable tool surface:
/// the names a `tool_search` call found, which the lane that builds the turn's declarations turns
/// into declarations on the next turn (pi's load, `tool.ts:1-21`).
///
/// The store is keyed by the conversation key the dispatch already carries
/// (``ToolInvocationContext/conversationKey``: the GUI's `inferenceSessionId`, the ACP session id,
/// the wire lane's `modelId:anon:` seed). No lane re-mints an identity. A set recorded under a key
/// nobody reads (a wire lane whose caller declares its own surface) is dead weight, not a lie: the
/// `tool_search` result only claims the record happened, never that some surface will declare it.
///
/// Lifetime: one small name set per conversation, newest kept. The key is minted per conversation
/// and never reused, so eviction is a byte-budget cleanup, not correctness.
import Foundation

actor ToolSurfaceDiscovery {
    static let shared = ToolSurfaceDiscovery()

    /// Conversations remembered at most. Each entry is a handful of names; the cap exists so a
    /// long-lived server cannot grow this without bound (same discipline as `MediaSpool`'s budget).
    static let maxConversations = 256

    private var byConversation: [String: Set<String>] = [:]
    /// Insertion order, oldest first — the eviction queue.
    private var order: [String] = []

    /// What this conversation has discovered; empty when the key is nil (no conversation, no set).
    func names(for conversationKey: String?) -> Set<String> {
        guard let conversationKey else { return [] }
        return byConversation[conversationKey] ?? []
    }

    /// Union, never replace: a second search adds to what the first found.
    func record(_ names: Set<String>, for conversationKey: String) {
        if byConversation[conversationKey] == nil {
            order.append(conversationKey)
            while order.count > Self.maxConversations {
                byConversation.removeValue(forKey: order.removeFirst())
            }
        }
        byConversation[conversationKey, default: []].formUnion(names)
    }

    /// Forget one conversation (test seams and a lane that ends its session early).
    func clear(_ conversationKey: String) {
        if byConversation.removeValue(forKey: conversationKey) != nil {
            order.removeAll { $0 == conversationKey }
        }
    }
}
