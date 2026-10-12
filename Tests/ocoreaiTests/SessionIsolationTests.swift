// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SessionIsolationTests — 没有 conversationId 的请求不得共用同一个会话。
///
/// 实机起因（10-12，`/v1/chat/completions`，gemma-4-e2b-it-4bit）：三条**互不相关**
/// 的单消息请求跑完后，第三条「我第一个问题是什么？」原样引用了第一条的问题；
/// `usage.prompt_tokens` 同时也与实际送入模型的上下文不符。根因是
/// `conversationId ?? "<model>:ephemeral"` 把所有无状态请求折进同一个 key，
/// 而复用的 `ChatSession` 自带 KV 与 transcript。
/// 本文件钉两件事：会话身份由内容派生（同会话稳定、跨会话互斥），
/// 以及复用闸门「缓存历史必须是来话的前缀」。

import Foundation
import MLXLMCommon
import Testing

@testable import ocoreai

@Suite("Session isolation", .serialized)
struct SessionIsolationTests {

    private func user(_ text: String) -> Chat.Message {
        Chat.Message(role: .user, content: text)
    }

    private func system(_ text: String) -> Chat.Message {
        Chat.Message(role: .system, content: text)
    }

    private func assistant(_ text: String) -> Chat.Message {
        Chat.Message(role: .assistant, content: text)
    }

    // MARK: - Conversation identity

    @Test("seed is FNV-1a-64 — pinned vectors, so on-disk snapshot names cannot drift")
    func seedVectors() {
        #expect(ConversationIdentity.seed(messages: []) == "cbf29ce484222325")
        #expect(ConversationIdentity.seed(messages: [user("hello")]) == "a430d84680aabd0b")
        #expect(
            ConversationIdentity.seed(
                messages: [user("What is 1234 plus 5678? Reply with only the number.")])
                == "fe16898c55977f24")
        #expect(
            ConversationIdentity.seed(
                messages: [user("What is 9 plus 1? Reply with only the number.")])
                == "e80cd3790237affa")
    }

    @Test("unrelated conversations get distinct identities")
    func distinctPerConversation() {
        let a = ConversationIdentity.seed(
            messages: [user("What is 1234 plus 5678? Reply with only the number.")])
        let b = ConversationIdentity.seed(
            messages: [user("What is 9 plus 1? Reply with only the number.")])
        #expect(a != b)
    }

    @Test("system prompt is not the conversation — leading USER message identifies it")
    func systemMessageSkipped() {
        let withSystem = ConversationIdentity.seed(
            messages: [system("You are a coding agent."), user("hello")])
        #expect(withSystem == "a430d84680aabd0b")
        // Two conversations that share one system prompt but differ in content stay apart.
        let other = ConversationIdentity.seed(
            messages: [system("You are a coding agent."), user("goodbye")])
        #expect(other != withSystem)
    }

    @Test("a stateless client that resends history keeps the same identity across turns")
    func identityStableAcrossTurns() {
        let turn1 = [user("Remember the codeword PARAPET for later. Acknowledge briefly.")]
        let turn2 = [
            turn1[0],
            assistant("Acknowledged. Codeword set to PARAPET."),
            user("And what was the codeword?"),
        ]
        #expect(
            ConversationIdentity.seed(messages: turn1) == "de06ddffe1802d71",
            "turn 1 identity")
        #expect(
            ConversationIdentity.seed(messages: turn2)
                == ConversationIdentity.seed(messages: turn1),
            "identity must not change when the conversation grows")
    }

    @Test("identity is deterministic across calls (no per-process hash seed)")
    func deterministic() {
        let first = ConversationIdentity.seed(messages: [user("hello")])
        #expect(first == ConversationIdentity.seed(messages: [user("hello")]))
    }

    // MARK: - Reuse gate

    @Test("continuation: incoming extends the whole cached history ⇒ reusable")
    func continuationReuses() {
        #expect(
            MLXSessionPool.canReusePooledSession(cachedMessageCount: 2, commonPrefixCount: 2)
                == true)
        #expect(
            MLXSessionPool.canReusePooledSession(cachedMessageCount: 4, commonPrefixCount: 5)
                == true)
    }

    @Test("fork or collision: session holds turns the caller never sent ⇒ refuse")
    func forkRefused() {
        // 10-12 live case: cached [u1, a1], incoming [u2] → common prefix 0 < 2
        #expect(
            MLXSessionPool.canReusePooledSession(cachedMessageCount: 2, commonPrefixCount: 0)
                == false)
        // Edited resend: cached [u1, a1, u2, a2], incoming [u1, a1, u2'] → 2 < 4
        #expect(
            MLXSessionPool.canReusePooledSession(cachedMessageCount: 4, commonPrefixCount: 2)
                == false)
    }

    @Test("empty cached history is always safe to serve")
    func emptyHistoryReusable() {
        #expect(
            MLXSessionPool.canReusePooledSession(cachedMessageCount: 0, commonPrefixCount: 0)
                == true)
    }
}
