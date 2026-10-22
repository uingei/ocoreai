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
            MLXSessionPool.canReusePooledSession(
                cachedMessageCount: 2, commonPrefixCount: 2, instructionsMatch: true,
                incomingMessageCount: 3, newestIncomingFromAssistant: false)
                == true)
        #expect(
            MLXSessionPool.canReusePooledSession(
                cachedMessageCount: 4, commonPrefixCount: 5, instructionsMatch: true,
                incomingMessageCount: 6, newestIncomingFromAssistant: false)
                == true)
    }

    @Test("fork or collision: session holds turns the caller never sent ⇒ refuse")
    func forkRefused() {
        // 10-12 live case: cached [u1, a1], incoming [u2] → common prefix 0 < 2
        #expect(
            MLXSessionPool.canReusePooledSession(
                cachedMessageCount: 2, commonPrefixCount: 0, instructionsMatch: true,
                incomingMessageCount: 1, newestIncomingFromAssistant: false)
                == false)
        // Edited resend: cached [u1, a1, u2, a2], incoming [u1, a1, u2'] → 2 < 4
        #expect(
            MLXSessionPool.canReusePooledSession(
                cachedMessageCount: 4, commonPrefixCount: 2, instructionsMatch: true,
                incomingMessageCount: 3, newestIncomingFromAssistant: false)
                == false)
    }

    @Test("empty cached history is always safe to serve")
    func emptyHistoryReusable() {
        // Nothing is skipped, so nothing can be stale — the feed still brings its own turn.
        #expect(
            MLXSessionPool.canReusePooledSession(
                cachedMessageCount: 0, commonPrefixCount: 0, instructionsMatch: true,
                incomingMessageCount: 1, newestIncomingFromAssistant: false)
                == true)
    }

    /// Measured 10-22 (probe 30): a verbatim repeat of a prompt left a ledger covering the
    /// whole feed, the turn was fed nothing, and the model answered end-of-turn at once —
    /// `200 + completion_tokens=1 + finish_reason=stop` for a request that asked for 150
    /// lines. A cache may be a *strict* prefix of the feed and nothing less.
    @Test("verbatim repeat: cache covers the whole feed ⇒ refuse, never feed nothing")
    func wholeFeedCoverageRefused() {
        #expect(
            MLXSessionPool.canReusePooledSession(
                cachedMessageCount: 1, commonPrefixCount: 1, instructionsMatch: true,
                incomingMessageCount: 1, newestIncomingFromAssistant: false)
                == false)
        #expect(
            MLXSessionPool.canReusePooledSession(
                cachedMessageCount: 2, commonPrefixCount: 2, instructionsMatch: true,
                incomingMessageCount: 2, newestIncomingFromAssistant: false)
                == false)
        // The other side: "continue what the assistant started" is exactly what a cache
        // holding that transcript answers, so a trailing-assistant feed keeps its warm session.
        #expect(
            MLXSessionPool.canReusePooledSession(
                cachedMessageCount: 2, commonPrefixCount: 2, instructionsMatch: true,
                incomingMessageCount: 2, newestIncomingFromAssistant: true)
                == true)
        // and the disk path names the same premise on the same shape
        #expect(
            SnapshotRefusal.cacheCoversWholeFeed(cached: 2).logText
                == "cached 2 covers the whole feed — nothing new to feed")
    }

    @Test("different instructions ⇒ refuse, even with an empty transcript")
    func changedInstructionsRefused() {
        // The shape a guided/tool turn leaves behind: it parks the session with an empty
        // transcript, so the prefix premise passes for anything — the identity of the
        // instruction set is the only thing standing between this turn and the previous
        // turn's system prompt.
        #expect(
            MLXSessionPool.canReusePooledSession(
                cachedMessageCount: 0, commonPrefixCount: 0, instructionsMatch: false,
                incomingMessageCount: 1, newestIncomingFromAssistant: false)
                == false)
        // A perfect continuation is still a different conversation's instruction list.
        #expect(
            MLXSessionPool.canReusePooledSession(
                cachedMessageCount: 4, commonPrefixCount: 5, instructionsMatch: false,
                incomingMessageCount: 6, newestIncomingFromAssistant: false)
                == false)
        // And the snapshot path reports which premise it failed.
        let manifest = KVCacheManifest(
            modelId: "m",
            instructionsHash: 1,
            messages: [
                MessageHistoryKey.from(user("hello")), MessageHistoryKey.from(assistant("hi")),
            ],
            rewindReserve: kvCacheRewindReserveTokens
        )
        #expect(
            manifest.reuseDecision(
                modelId: "m", instructionsHash: 2,
                incomingMessages: [MessageHistoryKey.from(user("hello"))],
                rewindReserve: kvCacheRewindReserveTokens)
                == .instructionsChanged)
    }

    // MARK: - Durable fingerprint

    @Test(
        "DurableHash is FNV-1a-64 — vectors cross-checked against an independent implementation"
    )
    func durableHashVectors() {
        #expect(DurableHash.fnv1a64("") == 0xcbf2_9ce4_8422_2325)
        #expect(DurableHash.fnv1a64("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(DurableHash.fnv1a64("hello") == 0xa430_d846_80aa_bd0b)
        #expect(DurableHash.fnv1a64("foobar") == 0x8594_4171_f739_67e8)
    }

    @Test("conversation seed, fingerprint and message keys are one algorithm")
    func identityLayersAgree() {
        #expect(
            ConversationIdentity.seed(messages: [user("hello")])
                == String(format: "%016llx", DurableHash.fnv1a64("hello")))
        #expect(
            MessageHistoryKey.from(user("hello")).contentHash == DurableHash.fingerprint("hello"))
    }

    @Test("media and tool turns are marked as unverifiable; plain text is not")
    func keyMarksUnverifiableTurns() {
        let plain = MessageHistoryKey.from(user("hello"))
        #expect(plain.hasMedia == false)
        #expect(plain.hasToolTraffic == false)

        let image = Chat.Message(
            role: .user, content: "look", images: [.url(URL(fileURLWithPath: "/tmp/x.png"))])
        #expect(MessageHistoryKey.from(image).hasMedia == true)
        let video = Chat.Message(
            role: .user, content: "clip",
            videos: [.init(source: .url(URL(fileURLWithPath: "/tmp/x.mp4")))])
        #expect(MessageHistoryKey.from(video).hasMedia == true)
        let audio = Chat.Message(
            role: .user, content: "clip",
            audios: [.init(source: .url(URL(fileURLWithPath: "/tmp/x.caf")))])
        #expect(MessageHistoryKey.from(audio).hasMedia == true)
        #expect(
            MessageHistoryKey.from(Chat.Message(role: .tool, content: "exit 0")).hasToolTraffic
                == true)
    }

    // MARK: - Prefix arithmetic

    private func ukey(_ text: String) -> MessageHistoryKey { MessageHistoryKey.from(user(text)) }

    private func akey(_ text: String) -> MessageHistoryKey {
        MessageHistoryKey.from(assistant(text))
    }

    @Test("longestCommonPrefixCount — boundaries")
    func prefixCountBoundaries() {
        let a = ukey("a")
        let b = ukey("b")
        let c = ukey("c")
        #expect(MessageHistoryKey.longestCommonPrefixCount(history: [], prefix: []) == 0)
        #expect(MessageHistoryKey.longestCommonPrefixCount(history: [], prefix: [a, b]) == 0)
        #expect(MessageHistoryKey.longestCommonPrefixCount(history: [a, b], prefix: []) == 0)
        #expect(
            MessageHistoryKey.longestCommonPrefixCount(history: [a, b], prefix: [a, b, c]) == 2)
        #expect(
            MessageHistoryKey.longestCommonPrefixCount(history: [a, b, c], prefix: [a, b]) == 2)
        #expect(MessageHistoryKey.longestCommonPrefixCount(history: [a, b], prefix: [b, a]) == 0)
        #expect(
            MessageHistoryKey.longestCommonPrefixCount(
                history: [a, b, c], prefix: [a, ukey("x"), c])
                == 1)
        // Same text under another role is a different turn.
        #expect(
            MessageHistoryKey.longestCommonPrefixCount(
                history: [akey("a")], prefix: [a]) == 0)
    }

    // MARK: - Persisted snapshot identity (manifest matrix)

    private func snapshot(
        _ keys: [MessageHistoryKey],
        model: String = "gemma-test",
        instructions: String = "sys prompt",
        reserve: Int = kvCacheRewindReserveTokens
    ) -> KVCacheManifest {
        KVCacheManifest(
            modelId: model,
            instructionsHash: DurableHash.fingerprint(instructions),
            messages: keys,
            rewindReserve: reserve)
    }

    private func decision(
        _ manifest: KVCacheManifest,
        model: String = "gemma-test",
        instructions: String = "sys prompt",
        incoming: [MessageHistoryKey],
        reserve: Int = kvCacheRewindReserveTokens
    ) -> SnapshotRefusal? {
        manifest.reuseDecision(
            modelId: model,
            instructionsHash: DurableHash.fingerprint(instructions),
            incomingMessages: incoming,
            rewindReserve: reserve)
    }

    @Test("accepts a continuation that replays everything the cache holds")
    func manifestAcceptsContinuation() {
        let cached = snapshot([ukey("u1"), akey("a1")])
        #expect(
            decision(cached, incoming: [ukey("u1"), akey("a1"), ukey("u2")]) == nil)
        // Exact replay (a stateless client resending the whole history) is accepted too.
        #expect(decision(cached, incoming: [ukey("u1"), akey("a1")]) == nil)
    }

    @Test("refuses an empty ledger — nothing states whose context the KV holds")
    func emptyLedgerUnusable() {
        let empty = snapshot([])
        #expect(empty.isUsable == false)
        #expect(decision(empty, incoming: [ukey("u1")]) == .unusableManifest)
    }

    @Test("refuses a manifest written by an older build")
    func legacyVersionUnusable() throws {
        let legacy = try #require(
            try? JSONDecoder().decode(
                KVCacheManifest.self,
                from: Data(
                    #"""
                    {"version":0,"modelId":"gemma-test","instructionsHash":7,"messages":[],
                    "rewindReserve":1024}
                    """#.utf8))
        )
        #expect(legacy.version != KVCacheManifest.currentVersion)
        #expect(legacy.isUsable == false)
        #expect(decision(legacy, incoming: [ukey("u1")]) == .unusableManifest)
    }

    @Test("refuses another model's cache — its KV encodes other embeddings")
    func modelMismatch() {
        let cached = snapshot([ukey("u1"), akey("a1")], model: "gemma-test")
        #expect(
            decision(cached, model: "qwen-test", incoming: [ukey("u1"), akey("a1")])
                == .modelMismatch(snapshot: "gemma-test", requested: "qwen-test"))
    }

    @Test("refuses a changed system prompt — the cached prefix never got sent")
    func instructionsChanged() {
        let cached = snapshot([ukey("u1"), akey("a1")], instructions: "sys prompt")
        #expect(
            decision(cached, instructions: "sys prompt v2", incoming: [ukey("u1"), akey("a1")])
                == .instructionsChanged)
    }

    @Test("refuses a media turn on either side — the pixels are not in the manifest")
    func mediaTurnRefused() {
        let imageKey = MessageHistoryKey.from(
            Chat.Message(
                role: .user, content: "look", images: [.url(URL(fileURLWithPath: "/tmp/x.png"))]))
        #expect(
            decision(snapshot([imageKey, akey("a1")]), incoming: [imageKey, akey("a1")])
                == .mediaTurn)
        #expect(
            decision(snapshot([ukey("u1")]), incoming: [ukey("u1"), imageKey]) == .mediaTurn)
    }

    @Test("refuses a fork — the cache holds turns the caller never sent")
    func forkRefusedByManifest() {
        // Unrelated next conversation: cached [u1, a1] vs incoming [u2]
        #expect(
            decision(snapshot([ukey("u1"), akey("a1")]), incoming: [ukey("u2")])
                == .notAPrefix(cached: 2, commonPrefix: 0))
        // Edit & resend: cached [u1, a1, u2, a2] vs incoming [u1, a1, u2']
        #expect(
            decision(
                snapshot([ukey("u1"), akey("a1"), ukey("u2"), akey("a2")]),
                incoming: [ukey("u1"), akey("a1"), ukey("u2 edited")])
                == .notAPrefix(cached: 4, commonPrefix: 2))
    }

    @Test("provenance outranks content: model mismatch reports before prefix arithmetic")
    func refusalPrecedence() {
        let cached = snapshot([ukey("u1")], model: "gemma-test")
        #expect(
            decision(cached, model: "qwen-test", incoming: [])
                == .modelMismatch(snapshot: "gemma-test", requested: "qwen-test"))
    }

    /// The KV-cache plan is part of the snapshot's identity: a sidecar that states another
    /// reserve describes rows this build cannot realize, and upstream says so at first token
    /// (`requirePlan` throws `kvCacheConfigurationChanged`, `ChatSession.swift:307`). Deciding
    /// that here turns a failed turn into what it is — one cold turn — and names it on the
    /// ledger instead of the error path.
    @Test("refuses a snapshot built under another KV-cache plan")
    func rewindReserveChangedRefused() {
        let cached = snapshot([ukey("u1"), akey("a1")], reserve: 0)
        #expect(
            decision(cached, incoming: [ukey("u1"), akey("a1")])
                == .rewindReserveChanged(snapshot: 0, requested: kvCacheRewindReserveTokens))
        #expect(
            decision(cached, incoming: [ukey("u1"), akey("a1")])?.ledgerReason
                == .rewindReserveChanged)
        // The reserve is the plan, not the identity: the model still reports first.
        #expect(
            decision(cached, model: "qwen-test", incoming: [ukey("u1")])
                == .modelMismatch(snapshot: "gemma-test", requested: "qwen-test"))
        // A matching plan still passes, so the field cannot refuse everything. The feed has
        // to be the continuation the cache is a prefix *of*: [u1] alone is divergence, not
        // a plan mismatch (that leg is `forkRefusedByManifest`).
        #expect(
            decision(snapshot([ukey("u1"), akey("a1")]), incoming: [ukey("u1"), akey("a1")])
                == nil)
    }

    /// Round trip, both directions of the upgrade: the reserve must survive encode/decode
    /// (a field that silently defaults to 0 would silently disable the rewind at the first
    /// reload, invisible to every correctness probe), and the byte shape shipped before the
    /// plan was recorded must fail to decode, which is what routes it to the cold path.
    @Test("the plan travels: v2 round-trips, a pre-plan sidecar does not decode")
    func manifestVersionRoundTrip() throws {
        let written = snapshot([ukey("u1"), akey("a1")])
        let data = try JSONEncoder().encode(written)
        let readBack = try #require(try? JSONDecoder().decode(KVCacheManifest.self, from: data))
        #expect(readBack.version == KVCacheManifest.currentVersion)
        #expect(readBack.modelId == written.modelId)
        #expect(readBack.instructionsHash == written.instructionsHash)
        #expect(readBack.messages == written.messages)
        #expect(readBack.rewindReserve == kvCacheRewindReserveTokens)

        // Verbatim shape of the sidecars builds before this shipped left on disk.
        let prePlan = """
            {"instructionsHash":1308216081840540159,"modelId":"mlx-community/gemma-4-e2b-it-4bit",\
            "messages":[{"contentHash":-4510834227904338520,"role":"user","hasMedia":false,\
            "hasToolTraffic":false}],"version":1}
            """
        #expect(
            (try? JSONDecoder().decode(KVCacheManifest.self, from: Data(prePlan.utf8))) == nil,
            "a sidecar that cannot state its plan must not decode as one")
    }

    @Test("every refusal names a reason the log can carry")
    func refusalLogText() {
        #expect(SnapshotRefusal.unusableManifest.logText == "no usable manifest")
        #expect(SnapshotRefusal.instructionsChanged.logText == "system prompt changed")
        #expect(SnapshotRefusal.mediaTurn.logText == "media turn cannot be re-verified")
        #expect(
            SnapshotRefusal.notAPrefix(cached: 2, commonPrefix: 0).logText
                == "cached 2 exceeds common prefix 0")
        #expect(
            SnapshotRefusal.modelMismatch(snapshot: "a", requested: "b").logText
                == "stamped model a, request wants b")
        #expect(
            SnapshotRefusal.rewindReserveChanged(snapshot: 0, requested: 1024).logText
                == "built with a 0-row rewind reserve, this build reserves 1024")
    }
}
