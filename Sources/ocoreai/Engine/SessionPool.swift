// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// SessionPool.swift — ChatSession pooling for KV cache reuse across turns
//
// Provides per-conversation ChatSession pooling with LRU eviction and TTL-based expiry.
// On-disk KV cache persistence enables session resume across pool evictions.
//
// ### Architecture:
// - **SessionPoolConfig**: Pool configuration (always compiled, trait-agnostic)
// - **MLXSessionPool** (actor): Owns the session pool map, handles eviction,
//   acquire/create, on-disk cache save/restore, and hit-rate metrics.
// - **PooledChatSession** (struct): Metadata wrapper around a ChatSession
//   with last-access timestamp for LRU tracking.
//
// ### Integration:
// - EnginePool delegates to SessionPool via acquire/release
// - When a pooled session is reused, the KV cache (prompt context) is preserved.
// - TTL expiry + LRU cap prevent unbounded memory growth.
// - On eviction, KV cache is persisted to disk via ChatSession.saveCache(to:).
// - On cold pool miss, loadPromptCache(url:) restores from disk if available.

import CoreGraphics
import Foundation
import Logging
import MLXLLM
import MLXLMCommon

// MARK: - Configuration (trait-agnostic)

/// Session pool configuration — per-pool limits and TTL.
struct SessionPoolConfig {
    /// Whether conversation pooling is enabled.
    var enabled: Bool = true

    /// Time-to-live for an idle pooled session (seconds).
    var sessionTTLSeconds: Int = 600

    /// Maximum number of pooled sessions across all models.
    var maxSessions: Int = 16

    /// Log hit/miss metrics every N acquires for observability.
    var metricsLogInterval: Int = 100

    /// When true, KV cache of an evicted session is persisted to disk
    /// via ChatSession.saveCache(to:) so the session can be resumed
    /// later with loadPromptCache(url:) instead of cold-start.
    var persistCache: Bool = true

    /// Maximum total on-disk KV cache size in bytes. When the cache directory
    /// exceeds this budget, oldest cache files are pruned before new ones are saved.
    /// Set to 0 to disable capping (not recommended for long-running services).
    /// Default: 1 GiB (enough for ~8 concurrent 128K-context sessions at ~50MB/session).
    var persistCacheMaxBytes: UInt64 = 1_073_741_824  // 1 GiB

    /// Directory for on-disk KV cache files (nil = auto-derive)
    var cacheDirectory: URL?

    /// Idle seconds before an inline-media spool file may be collected (see ``MediaSpool``).
    /// Must exceed ``sessionTTLSeconds``: a conversation that has come back within its
    /// session TTL still cites the media its transcript names, and a sweep that deletes
    /// it resurrects the defect ``MediaSpool`` exists to close.
    var mediaIdleTTLSeconds: Int = 3600

    /// Byte budget for the inline-media spool. 0 disables the cap (not recommended:
    /// frame payloads are not small). Over budget, least-recently-cited files go first.
    var mediaMaxBytes: UInt64 = 512 * 1024 * 1024

    /// Policy handed to ``MediaSpool`` for its sweeps.
    var mediaPolicy: MediaSpool.Policy {
        MediaSpool.Policy(
            idleTTL: .seconds(Int64(max(mediaIdleTTLSeconds, sessionTTLSeconds + 60))),
            maxBytes: mediaMaxBytes
        )
    }

    /// Static fallback for cold-miss when caller passes nil processing (defensive;
    /// EngineInference always provides processing so this path is unreachable in practice).
    static let defaultResize: CGSize = .init(width: 1024, height: 1024)

    /// VLM image resize dimensions — fallback for callers that pass nil
    /// for the `processing` parameter.
    var vlmImageResize: CGSize = .init(width: 1024, height: 1024)

    /// Default configuration
    static let `default`: SessionPoolConfig = .init()
}

// MARK: - Pool Availability Policy

/// Whether this process starts a session pool at all.
///
/// ``SessionPoolConfig/enabled`` is the product's switch. `OCOREAI_SESSION_POOL=0`
/// (also `false` / `off` / `no`) forces pooling off for one run, and it exists so the
/// unpooled lane is reachable *on demand*: the other way into it is the HardwareRouter
/// degrading a turn under memory pressure, which nobody can schedule. That lane matters
/// because every pooled release path is a no-op without a pool — and until 10-20 the
/// video ledger recorded only inside one of them, so an answered video turn on this lane
/// left `/v1/models` publishing `not_observed` for a model that had just named the
/// colour of a clip (AGENTS.md invariant 2 runs both ways). Live gate: probe 17.
enum SessionPoolPolicy {
    /// Escape hatch naming this switch on the wire of the process environment.
    static let environmentVariable = "OCOREAI_SESSION_POOL"

    /// Values that mean "off". Anything else (including garbage) leaves pooling alone —
    /// a typo in an escape hatch must not silently change engine behaviour beyond what
    /// it asked for, and the boot log prints the raw value either way.
    private static let offValues: Set<String> = ["0", "false", "off", "no"]

    /// The raw value when the environment forces pooling off, else `nil`. The init logs
    /// this so an operator can tell a config decision from a debug escape hatch.
    static func environmentOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let raw = environment[environmentVariable] else { return nil }
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return offValues.contains(value) ? value : nil
    }

    /// Pooling runs only when the config asks for it *and* the environment does not
    /// veto it. A missing config is not a veto to invent one: no config, no pool.
    static func enabled(
        config: SessionPoolConfig?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let config, config.enabled else { return false }
        return environmentOverride(environment: environment) == nil
    }
}

// MARK: - Durable Identity

/// Deterministic 64-bit FNV-1a over UTF-8 bytes.
///
/// Anything that identifies cached work *across process launches* has to use this,
/// not `String.hashValue`: Swift seeds hashing per process, so a `hashValue` written
/// to disk is meaningless at the next launch — two runs of the same text disagree.
/// One algorithm here keeps the conversation seed, the message keys and the on-disk
/// manifest comparable with each other and with older files.
enum DurableHash {
    static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1_0000_0001_b3
        }
        return hash
    }

    /// `Int` projection for `Hashable` keys. `Int` is 64-bit across the whole
    /// supported matrix (macOS 14+ / iOS 17+), so no bits are lost.
    static func fingerprint(_ text: String) -> Int {
        Int(truncatingIfNeeded: fnv1a64(text))
    }
}

/// Lightweight message identity for prefix match without carrying full text.
struct MessageHistoryKey: Hashable, Sendable, Codable {
    let role: String
    /// Durable fingerprint of the content (see ``DurableHash``) — enough to detect
    /// content changes without storing full text, and stable across launches so it
    /// can travel with a persisted snapshot.
    let contentHash: Int
    /// Media-carrying turns cannot be reconciled with a restored snapshot: a vision
    /// encoder attends an image beside a cached prefix differently than cold
    /// (upstream `ChatSession.swift:701-707`), so these turns block disk reuse.
    // anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:703 image-bearing turn continues warm
    var hasMedia: Bool = false
    /// Tool traffic renders into the prompt as control text that a caller-supplied
    /// message list does not describe faithfully, so a ledger containing it is not
    /// something to bank a prefix skip on.
    var hasToolTraffic: Bool = false

    static func from(_ msg: Chat.Message) -> Self {
        Self(
            role: msg.role.rawValue,
            contentHash: DurableHash.fingerprint("\(msg.content)"),
            hasMedia: !msg.images.isEmpty || !msg.videos.isEmpty || !msg.audios.isEmpty,
            hasToolTraffic: msg.role == .tool || msg.tool != nil
        )
    }
}

/// Identity for a conversation that arrived without an explicit id.
enum ConversationIdentity {
    /// FNV-1a-64 (hex) over the leading user message.
    ///
    /// Deterministic on purpose: the pool names its on-disk KV snapshots after the
    /// key, so the identity has to resolve to the same name after a restart —
    /// Swift's `hashValue` is seeded per process and would orphan those files.
    static func seed(messages: [Chat.Message]) -> String {
        let leading = messages.first { $0.role == .user }.map { "\($0.content)" } ?? ""
        return String(format: "%016llx", DurableHash.fnv1a64(leading))
    }
}

/// Sidecar written next to a persisted KV snapshot, stating what that cache holds.
///
/// Upstream persists raw KV state only and says the caller owns the transcript:
/// "A restored raw cache therefore uses fragment-based continuation"
/// (`ChatSession.swift:1786-1790`) — the session continues from whatever tokens the
// anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:1787 A restored raw cache therefore uses
/// file happens to hold and cannot check them against a chat template. Accepting one
/// without proof re-attaches a previous conversation's context to a new request, so
/// this manifest is the proof, and no manifest means no reuse.
struct KVCacheManifest: Codable, Sendable {
    /// 2 — the manifest now names the KV-cache plan the snapshot was written under.
    ///
    /// A v1 file cannot state its reserve, and upstream will not realize a cache whose plan
    /// differs from the live generation parameters: `requirePlan` throws
    /// `kvCacheConfigurationChanged` (`ChatSession.swift:302`), which would surface as a
    // anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:302 throw ChatSessionError.kvCacheConfigurationChanged
    /// failed turn for every conversation that persisted before a plan change. Refusing the
    /// snapshot here turns that into what it actually is — one cold turn — and says so on
    /// the ledger instead of the error path.
    static let currentVersion = 2

    let version: Int
    let modelId: String
    /// Fingerprint of the system instructions the cache was built under. A changed
    /// system prompt means the cached prefix encodes text this request never sent.
    let instructionsHash: Int
    /// Rows per rotating cache this snapshot was built with (`kvCacheRewindReserveTokens`).
    /// Part of the plan, not a preference: 0 and 1024 describe caches that are not
    /// interchangeable, because only the latter can rewind into retained history.
    let rewindReserve: Int

    /// The messages the KV cache represents, in render order.
    let messages: [MessageHistoryKey]

    init(
        modelId: String,
        instructionsHash: Int,
        messages: [MessageHistoryKey],
        rewindReserve: Int
    ) {
        self.version = Self.currentVersion
        self.modelId = modelId
        self.instructionsHash = instructionsHash
        self.rewindReserve = rewindReserve
        self.messages = messages
    }

    /// Refuse any snapshot we cannot fully account for, including files written by
    /// an older build (whose hashes came from the per-process seed).
    var isUsable: Bool {
        version == Self.currentVersion && !modelId.isEmpty && !messages.isEmpty
    }

    /// Whether this snapshot may serve the given request, and why not.
    ///
    /// Pure - no filesystem, no MLX - so the whole refusal matrix is pinned by
    /// `SessionIsolationTests` instead of being inferred from a live run.
    /// A refusal is not "try later": the caller deletes the snapshot.
    func reuseDecision(
        modelId requestedModelId: String,
        instructionsHash requestedInstructionsHash: Int,
        incomingMessages: [MessageHistoryKey],
        rewindReserve requestedRewindReserve: Int
    ) -> SnapshotRefusal? {
        guard isUsable else { return .unusableManifest }
        guard modelId == requestedModelId else {
            return .modelMismatch(snapshot: modelId, requested: requestedModelId)
        }
        // Identity first, then the plan the bytes were produced under: a cache that cannot
        // be realized under today's parameters is not a stale prefix, it is an error
        // waiting at first token.
        guard rewindReserve == requestedRewindReserve else {
            return .rewindReserveChanged(
                snapshot: rewindReserve, requested: requestedRewindReserve)
        }
        // Recorded here, decided once — by ``MLXSessionPool/canReusePooledSession(cachedMessageCount:commonPrefixCount:instructionsMatch:incomingMessageCount:newestIncomingFromAssistant:)``
        // below, the same gate the in-memory pool consults. Two copies of the rule is how
        // one of them drifts.
        let instructionsMatch = instructionsHash == requestedInstructionsHash
        // A vision encoder attends an image beside a cached prefix differently than
        // cold (upstream `ChatSession.swift:701-707`), and the pixels are not in the
        // anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:703 image-bearing turn continues warm
        // manifest, so a media turn on either side is unverifiable.
        guard !messages.contains(where: \.hasMedia),
            !incomingMessages.contains(where: \.hasMedia)
        else {
            return .mediaTurn
        }
        let common = MessageHistoryKey.longestCommonPrefixCount(
            history: messages,
            prefix: incomingMessages
        )
        guard
            MLXSessionPool.canReusePooledSession(
                cachedMessageCount: messages.count,
                commonPrefixCount: common,
                instructionsMatch: instructionsMatch,
                incomingMessageCount: incomingMessages.count,
                newestIncomingFromAssistant: incomingMessages.last?.role == "assistant"
            )
        else {
            // The gate decides; this reports which of its premises the snapshot failed.
            if !instructionsMatch { return .instructionsChanged }
            return common < messages.count
                ? .notAPrefix(cached: messages.count, commonPrefix: common)
                : .cacheCoversWholeFeed(cached: messages.count)
        }
        return nil
    }
}

/// Why a persisted KV snapshot was refused. `nil` means accepted, so every variant
/// names something a caller cannot repair by waiting.
enum SnapshotRefusal: Equatable, Sendable {
    /// No sidecar, unreadable, or written by a build whose hashes came from the
    /// per-process seed - nothing identifies where the cache came from.
    case unusableManifest
    /// The cache was built for a different model: its KV encodes another model's
    /// embeddings and positions.
    case modelMismatch(snapshot: String, requested: String)
    /// The system prompt changed, so the cached prefix contains text this request
    /// never sent.
    case instructionsChanged
    /// Image/video/audio turns are not described by the manifest, so the tokens the
    /// cache actually holds cannot be checked against it.
    case mediaTurn
    /// The cache holds turns the caller never sent - a fork (edit & resend), a
    /// compacted history, or an identity collision.
    case notAPrefix(cached: Int, commonPrefix: Int)
    /// The manifest covers the caller's whole feed including its newest message — a cache is
    /// only written after an answer, so it has already answered that message. See
    /// ``ReuseRefusalReason/cacheCoversWholeFeed``.
    case cacheCoversWholeFeed(cached: Int)
    /// The snapshot was written under a different KV-cache plan (here: a different rewind
    /// reserve). Its rows cannot be realized under today's parameters, so it is dropped
    /// rather than handed to a session that would fail the turn.
    case rewindReserveChanged(snapshot: Int, requested: Int)

    /// One-line reason for the log, so a dropped cache is explainable after the fact.
    var logText: String {
        switch self {
        case .unusableManifest: return "no usable manifest"
        case .modelMismatch(let snapshot, let requested):
            return "stamped model \(snapshot), request wants \(requested)"
        case .instructionsChanged: return "system prompt changed"
        case .mediaTurn: return "media turn cannot be re-verified"
        case .notAPrefix(let cached, let commonPrefix):
            return "cached \(cached) exceeds common prefix \(commonPrefix)"
        case .cacheCoversWholeFeed(let cached):
            return "cached \(cached) covers the whole feed — nothing new to feed"
        case .rewindReserveChanged(let snapshot, let requested):
            return "built with a \(snapshot)-row rewind reserve, this build reserves \(requested)"
        }
    }

}

extension MessageHistoryKey {
    /// Longest run of identical messages at the head of both sequences.
    ///
    /// A mismatch at position *i* means the cache represents a different context from
    /// *i* onward, so the caller must prefill from there.
    static func longestCommonPrefixCount(
        history: [MessageHistoryKey],
        prefix: [MessageHistoryKey]
    ) -> Int {
        let minCount = Swift.min(history.count, prefix.count)
        for i in 0 ..< minCount where history[i] != prefix[i] {
            return i
        }
        return minCount
    }
}

/// Metadata wrapper around a ChatSession with LRU tracking and message history
/// for prompt prefix-level cache reuse decisions.
///
/// ``@unchecked Sendable``: this struct lives exclusively inside
/// ``MLXSessionPool`` actor — all reads and mutations are actor-isolated,
/// so cross-thread access never occurs. The `ChatSession` itself is not
/// formally Sendable but is only accessed via the actor.
///
/// KV cache state is managed entirely by ChatSession internally —
/// we only track access time for TTL/LRU eviction.
struct PooledChatSession: @unchecked Sendable {
    /// The underlying MLX chat session (holds KV cache)
    let session: ChatSession

    /// Timestamp of last access
    var lastAccessedAt: ContinuousClock.Instant

    /// On-disk cache file URL for this session (nil if never persisted).
    var cacheFileURL: URL?

    /// Fingerprint of the system instructions this session's cache was built under
    /// (``DurableHash``). Recorded at acquire so an evicted session can be persisted
    /// with the identity a later restore has to match.
    var instructionsHash: Int = 0

    /// Model this session belongs to, kept so a persisted snapshot can state its
    /// provenance without parsing the pool key.
    var modelId: String = ""

    /// Rendered message history keys for prefix matching.
    /// Each entry corresponds to a role+content pair that contributed tokens to the KV cache.
    /// On acquire, we compare new messages against this to find the longest common prefix.
    var messageHistory: [MessageHistoryKey] = []

    /// KV bytes this session's cache holds in RAM, measured at the last release.
    ///
    /// Travels with the entry on purpose: the pool *is* the resident set, so a number stored
    /// here is freed at every removal site for free, while a side ledger would rot upward the
    /// first time an eviction forgot to decrement it. 0 = never measured, not "empty cache".
    var residentKVBytes: Int = 0

    /// Tokens the measured cache provably held (`KVCacheStatus.processedTokenCount`).
    var residentKVTokens: Int = 0

    /// Inline media files this conversation's transcript cites (see ``MediaSpool``).
    ///
    /// The pool owns these bytes because the pool owns the transcript that names them:
    /// upstream re-reads that transcript on every later turn, so they must survive the
    /// request that wrote them and die with the session that cites them.
    var mediaFiles: [URL] = []
}

/// Result of acquiring a session, with prefix match details.
struct AcquireResult {
    /// The pooled session (or fresh session on miss)
    let pooled: PooledChatSession

    /// Whether a prefixed cache was found (partial or full match).
    /// When false, this is a cold start — caller must pass full history.
    let isHit: Bool

    /// Number of messages that already match the cached prefix.
    /// Caller should only pass messages[divergenceIndex...] to avoid redundant prefill.
    /// - 0: no cached prefix (cold miss)
    /// - < messages.count: partial prefix match (pass suffix)
    /// - == messages.count: full match (only new messages needed, but pool hit means nothing new yet)
    let divergenceIndex: Int

    /// Set when this turn was refused but the resident cache can be rewound onto the
    /// conversation that arrived instead of being rebuilt. `pooled` above still answers
    /// this turn correctly (cold), so a caller that ignores this field keeps the old
    /// behaviour; a caller that takes it forks ``PooledRewind/source`` and prefers the fork.
    let rewind: PooledRewind?

    init(
        pooled: PooledChatSession,
        isHit: Bool,
        divergenceIndex: Int,
        rewind: PooledRewind? = nil
    ) {
        self.pooled = pooled
        self.isHit = isHit
        self.divergenceIndex = divergenceIndex
        self.rewind = rewind
    }
}

/// A resident KV cache that can be rewound onto a conversation that diverged from it.
///
/// The pool cannot fork on the caller's behalf: ``ChatSession/fork(history:)`` takes
/// `[Chat.Message]`, which is not `Sendable`, so a transcript cannot cross into the pool
/// actor. The pool therefore decides *whether* a rewind is sound (``
/// MLXSessionPool/rewindHistoryEnd``) and hands the boundary to the caller, who owns the
/// messages and performs the fork.
struct PooledRewind {
    /// The session whose cache still holds the shared prefix. Not the session `acquire`
    /// returned: taking this offer means forking this one and preferring the fork.
    let source: PooledChatSession

    /// How many leading messages the fork should hold — the longest prefix this turn and
    /// that cache agree on. The caller then feeds `messages[historyEnd...]`.
    let historyEnd: Int
}

// MARK: - Session Pool Actor

/// Actor-owned pool of ChatSession instances keyed by
/// (modelId, conversationId). Handles TTL expiry + LRU eviction + on-disk KV cache.
actor MLXSessionPool {
    // MARK: - State

    private let config: SessionPoolConfig
    private let logger: Logger
    private var pool: [String: PooledChatSession] = [:]

    // On-disk KV cache storage
    private let cacheDirectory: URL

    /// Where inline media (data-URL audio/video) cited by this pool's conversations is
    /// kept. Follows ``cacheDirectory`` so a caller that redirects one redirects both.
    private let mediaDirectory: URL

    // Hit-rate metrics
    private var hitCount = 0
    private var missCount = 0
    private var totalAcquireAttempts = 0
    /// Which rule turned a warm session away, per model, and how often a cold turn arrived
    /// while another session for the same model already held its prefix
    /// (ReuseRefusalLedger.swift). Counts only: no decision here consults it.
    private var reuseRefusals = ReuseRefusalLedger()

    /// Model IDs whose pooled sessions are exempt from TTL/LRU eviction
    /// (set from EnginePool via ``setPinnedModels``). Critical pressure (level 3) ignores this.
    private var pinnedModelIds: Set<String> = []

    // MARK: - Initialization

    init(config: SessionPoolConfig, logger: Logger, cacheDirectory argCacheDir: URL? = nil) {
        self.config = config
        self.logger = logger

        // Derive cache directory from config or default — cross-platform
        cacheDirectory =
            argCacheDir ?? config.cacheDirectory
            ?? {
                let dir: URL
                if let supportURL = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask,
                ).first?.appendingPathComponent("ocoreai/cache") {
                    dir = supportURL
                } else {
                    dir = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("ocoreai/cache")
                }
                return dir.appendingPathComponent("kvcache")
            }()

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true,
        )

        // Inline media lives next to the KV cache and follows whatever the caller
        // redirected it to; $OCOREAI_MEDIA_SPOOL still wins (see MediaSpool.directory).
        mediaDirectory = MediaSpool.directory(
            fallback: cacheDirectory.deletingLastPathComponent().appendingPathComponent("media"))
        try? FileManager.default.createDirectory(
            at: mediaDirectory, withIntermediateDirectories: true,
        )

        logger.info(
            """
            MLXSessionPool initialized: maxSessions=\(config.maxSessions), \
            ttl=\(config.sessionTTLSeconds)s, persist=\(config.persistCache)
            """
        )
    }

    // MARK: - Acquire / Create

    /// Acquire a ChatSession for the given (model, conversation) key.
    ///
    /// If a pooled session exists and is within TTL, it is returned and removed
    /// from the pool (borrow pattern). The caller must release() after inference.
    ///
    /// If no pooled session exists (or it expired), the pool attempts to restore
    /// from on-disk KV cache. If that fails, a new session is created.
    ///
    /// Prompt prefix match (`prefixMessages`) is checked against the session's
    /// ``PooledChatSession/messageHistory`` to find the longest common message
    /// prefix.  The caller should only ``prefixMessages[divergenceIndex...]``
    /// to ``ChatSession`` — the cached KV context already represents the
    /// matched portion.
    ///
    /// - Note: On cold miss, `prefixMessages` is recorded into the session's
    ///   history so the next turn can benefit from prefix matching.  The caller
    ///   should pass the same messages that go to ``ChatSession``.
    ///
    /// - Parameters:
    ///   - prefixMessages: Rendered messages for this turn, used for prefix matching.
    ///     Pass nil if the caller only needs a session-level hit/miss.
    ///   - instructions: System prompt via ChatSession's `instructions:` parameter
    ///   - processing: VLM resize config. Aligned across all inference paths
    ///     to avoid inconsistent per-image token counts.
    ///   - prefixMessages: Rendered message keys for this turn, used for prefix matching.
    ///     Convert `[Chat.Message]` to `[MessageHistoryKey]` before calling across actor boundary.
    func acquire(
        from modelContainer: MLXLMCommon.ModelContainer,
        modelId: String,
        conversationId: String,
        genParams: MLXLMCommon.GenerateParameters,
        speculativeDecoding: MLXLMCommon.SpeculativeDecodingConfig? = nil,
        instructions: String? = nil,
        processing: MLXLMCommon.UserInput.Processing? = nil,
        prefixMessages: [MessageHistoryKey]? = nil,
        rewindUsable: Bool,
    ) async -> AcquireResult {
        // 1. Expire stale sessions
        await evictExpired()

        // 1b. Collect inline media no live conversation cites any more. This is the
        // backstop for what the pool's own map cannot see: files orphaned when a process
        // died before releasing them, plus the byte budget. One directory listing per
        // acquire, scoped to the files MediaSpool wrote.
        let mediaSweep = MediaSpool.sweep(policy: config.mediaPolicy, in: mediaDirectory)
        if mediaSweep.removedTotal > 0 {
            logger.info(
                "Media spool collected \(mediaSweep.removedTotal) file(s) (\(mediaSweep.bytesFreed) bytes: \(mediaSweep.removedIdle) idle, \(mediaSweep.removedOverBudget) over budget); \(MediaSpool.totalBytes(in: mediaDirectory)) remain"
            )
        }

        // 2. Build pool key
        let key = poolKey(modelId: modelId, conversationId: conversationId)

        // Identity of the instruction set this turn will render under. Computed before the
        // hit check because a reused session carries the instructions it was *created* with:
        // `ChatSession.instructions` is a stored property the processor prepends at prefill,
        // so a session that survives into a turn with different instructions answers under
        // the old ones. The disk path already refused on exactly this (``reuseDecision`` →
        // `.instructionsChanged`); the in-memory path is the same conversation and owes the
        // same rule.
        let instructionsFP = DurableHash.fingerprint(instructions ?? "")

        // 3. Try hit — with prefix match
        // A refusal that has a resumable cache behind it survives to the miss return below,
        // where the caller can still take it (see ``AcquireResult/rewind``).
        var pendingRewind: PooledRewind?
        if let pooled = pool[key] {
            let divergence: Int
            if let prefix = prefixMessages {
                divergence = MessageHistoryKey.longestCommonPrefixCount(
                    history: pooled.messageHistory,
                    prefix: prefix
                )
            } else {
                divergence = 0
            }

            // A pooled ChatSession is stateful — its KV already contains
            // `messageHistory`. Reuse is sound ONLY while the incoming conversation
            // still extends that exact history. When the common prefix is shorter,
            // the session holds turns this caller never sent, and answering from it
            // leaks another conversation's context: observed 10-12, three
            // independent one-message /v1/chat/completions calls, where the third
            // quoted the first question verbatim. Same rule covers an edited
            // resend — the old KV describes the pre-edit conversation.
            // So this session may not answer the turn. Whether its cache is
            // nevertheless worth keeping is a second question, answered below
            // (``rewindHistoryEnd``): when it is, the caller gets the offer and this turn
            // still falls through to a clean session, so nothing here depends on the
            // caller taking it.
            let instructionsMatch = pooled.instructionsHash == instructionsFP
            if !Self.canReusePooledSession(
                cachedMessageCount: pooled.messageHistory.count,
                commonPrefixCount: divergence,
                instructionsMatch: instructionsMatch,
                // No ledger for this turn means no claim to contradict: the caller feeds the
                // whole transcript, so the coverage premise cannot be the blocker.
                incomingMessageCount: prefixMessages?.count ?? .max,
                newestIncomingFromAssistant: prefixMessages?.last?.role == "assistant"
            ) {
                // Refusing to *answer* from this cache is not the same as throwing it away,
                // and the two questions have different answers. The rule above says no,
                // correctly: these KV rows describe the conversation before this caller
                // replaced part of it. Upstream's `fork(history:)`
                // (ChatSession.swift:1723 at pin 991266ad3) answers the other question — may
                // the cache be rewound onto the conversation the caller did send? — with a
                // session that holds that transcript and "keeps only the part of the cache
                // that its prompt starts with, and prefills the rest". Its boundary is the
                // token-level common prefix, and upstream verifies the trim landed before
                // trusting it (the verify-and-downgrade block that opens at
                // ChatSession.swift:1270). Editing a past turn is the most common state change a
                // anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:1272 Verify and downgrade to a rebuild
                // coding-agent UI makes, and every such turn used to re-prefill everything:
                // measured 10-21 (probe 27, gemma-4-e2b-it-4bit, one session) a warm
                // appended turn reused 734 of 758 tokens while the edited resend reused 0.
                //
                // The fork cannot be performed here: `Chat.Message` is not `Sendable`
                // (Chat.swift:14 — it carries `UserInput.Image`, UserInput.swift:131), so a
                // transcript cannot cross into this actor. That is also why this file matches
                // conversations on `MessageHistoryKey` rather than on messages. So the pool
                // hands the caller the resumable session plus the boundary, and the caller
                // forks in its own isolation region (`EngineInference.swift`).
                //
                // Everything below still runs unchanged: this turn is served by a clean
                // session, so a caller that ignores the offer behaves exactly as before.
                // No offer when this turn cannot spend one: the guided-gen and MTP lanes build
                // their own KV cache and hand the slot back before generating, so an offer
                // here would be declined by the only caller that could take it — while this
                // site had already dropped the entry, deleted the snapshot and skipped the
                // `reuseRefusals` booking for a refusal the turn did in fact pay. The caller
                // decides the lane (`EnginePool.bypassesPooledChatSession`) and says so here,
                // so the log line, the ledger and the fork all describe the same turn.
                let rewindOffer = Self.rewindHistoryEnd(
                    cachedMessageCount: pooled.messageHistory.count,
                    commonPrefixCount: divergence,
                    incomingMessageCount: prefixMessages?.count,
                    instructionsMatch: instructionsMatch,
                    carriesMedia: (prefixMessages?.contains { $0.hasMedia } ?? false)
                        || pooled.messageHistory.contains { $0.hasMedia },
                    laneCanSpend: rewindUsable
                )
                if let rewindOffer {
                    pendingRewind = PooledRewind(source: pooled, historyEnd: rewindOffer)
                    logger.info(
                        "Session pool REWIND offered for \(key): this conversation diverges at message \(rewindOffer)/\(pooled.messageHistory.count) — the resident cache can be rewound onto the shared prefix instead of re-prefilling it"
                    )
                }
                pool[key] = nil
                // A discarded conversation no longer needs the bytes its transcript
                // named. Anything a still-live session also cites is left alone.
                releaseMedia(of: [pooled])
                // A diverged conversation invalidates the snapshot on disk too: leaving
                // it there would let the next pool miss for this key revive the same
                // stale context.
                deleteCachedSession(key: key)
                // Counted at the site that already decided, from the same two premises, in
                // the same precedence (`ReuseRefusalReason.decide`) - so the log line, the wire
                // counter and the gate cannot drift into three spellings of one refusal.
                //
                // Not counted when a rewind was offered: a turn whose cache survives is not a
                // refusal, and publishing one for it would report a full rebuild the engine
                // did not perform (AGENTS.md invariant 2 — the surface may not state more
                // than the engine delivered). That holds only because an offer is made when
                // the turn can spend it: `rewindUsable` comes from the caller's lane, and
                // `SessionRewindOnDivergenceTests` pins both that the offer is gated on it
                // and that exactly one fork site exists to take it with.
                if rewindOffer == nil,
                    let reason = ReuseRefusalReason.decide(
                        instructionsMatch: instructionsMatch,
                        cachedMessageCount: pooled.messageHistory.count,
                        commonPrefixCount: divergence,
                        incomingMessageCount: prefixMessages?.count ?? .max,
                        newestIncomingFromAssistant: prefixMessages?.last?.role == "assistant"
                    )
                {
                    reuseRefusals.record(modelId: modelId, reason: reason)
                }
                var refusalReasons: [String] = []
                if !instructionsMatch {
                    refusalReasons.append("instructions changed")
                }
                if divergence < pooled.messageHistory.count {
                    refusalReasons.append(
                        "cached history \(pooled.messageHistory.count) exceeds common prefix \(divergence)"
                    )
                }
                if let feed = prefixMessages?.count, divergence >= feed,
                    prefixMessages?.last?.role != "assistant"
                {
                    refusalReasons.append(
                        "cached history \(pooled.messageHistory.count) covers this turn's whole \(feed)-message feed"
                    )
                }
                // info, not debug: the HIT counterpart is info, and a refusal is the reason a
                // turn costs a full prefill. A refusal whose cause only shows up when somebody
                // raises the log level is an explanation nobody gets at the moment it matters.
                logger.info(
                    "Session pool entry \(key) not reusable: \(refusalReasons.joined(separator: "; ")) — \(rewindOffer == nil ? "building a clean session" : "cache kept for a rewind instead of discarded")"
                )
            } else {
                pool[key] = nil
                hitCount += 1
                totalAcquireAttempts += 1
                logHitRateIfNeeded()
                // Hand back this turn's knobs, not the ones the session was born with.
                // Sampling lives on the session, not on the call: upstream captures
                // `ChatSession.generateParameters` when a stream starts
                // (`ChatSession.swift:361`, capture list at `:1037-1043`), so a reused
                // anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:361 public var generateParameters
                // anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:1040 generateParameters = parameters
                // session that keeps turn 1's parameters answers turn 2 under turn 1's
                // `max_tokens`/`temperature`/`seed` — measured, and named in
                // ``staleSamplingFields``. Cache-affecting changes stay upstream's job
                // (`ChatSession.swift:1108-1122` rebuilds from its retained transcript).
                // anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:1114 rebuild the cache from it
                let overriddenFields = Self.staleSamplingFields(
                    before: pooled.session.generateParameters,
                    after: genParams
                )
                pooled.session.generateParameters = genParams
                if !overriddenFields.isEmpty {
                    logger.info(
                        "Session pool HIT \(key) — this turn overrides the knobs it was created with: \(overriddenFields.joined(separator: ","))"
                    )
                }
                if divergence > 0 {
                    // What this line can honestly claim is about the *feed*: the
                    // caller withholds `divergence` messages this session's transcript
                    // already holds. Whether the KV cache skipped a prefill is not
                    // knowable here — upstream decides it and reports it on
                    // GenerateCompletionInfo.cachedPromptTokenCount, and this call site
                    // deliberately does not restate that verdict: a second hand-written
                    // copy of the number is exactly the drift this repo keeps naming.
                    // EngineInference.accountPrefixReuse logs it per turn and
                    // PrefixReuseLedger publishes it per model. Measured 10-16 at pin
                    // 6e338e5 (gemma-4-e2b-it-4bit, 3-turn same-session, probe 01):
                    // 710/730 and 733/749 tokens reused — but that is upstream's answer
                    // for that day's revision, read from the wire, not a promise this
                    // line may make.
                    logger.info(
                        "Session pool HIT: \(key) — \(divergence)/\(prefixMessages?.count ?? 0) messages already in this session's transcript, withholding them from this feed"
                    )
                } else {
                    logger.debug("Session pool HIT: \(key), divergence=0")
                }
                return AcquireResult(
                    pooled: pooled,
                    isHit: divergence > 0,
                    divergenceIndex: divergence
                )
            }
        }

        // 4. Pool miss — try restore from disk, but only for the conversation the
        // snapshot provably belongs to. `restoreValidatedSession` refuses (and
        // deletes) anything it cannot account for.
        let cacheURL = cacheFileURL(key: key)
        if config.persistCache,
            let incoming = prefixMessages,
            let restored = restoreValidatedSession(
                from: modelContainer,
                cacheURL: cacheURL,
                genParams: genParams,
                speculativeDecoding: speculativeDecoding,
                processing: processing,
                modelId: modelId,
                instructionsHash: instructionsFP,
                incomingMessages: incoming
            )
        {
            let (restoredSession, manifest) = restored
            let reusedCount = manifest.messages.count
            let diskPooled = PooledChatSession(
                session: restoredSession,
                lastAccessedAt: ContinuousClock.now,
                cacheFileURL: cacheURL,
                instructionsHash: instructionsFP,
                modelId: modelId,
                messageHistory: manifest.messages
            )
            hitCount += 1
            totalAcquireAttempts += 1
            logHitRateIfNeeded()
            logger.info(
                "Session RESTORED from disk cache: \(key) — \(reusedCount) cached message(s), feeding the suffix"
            )
            return AcquireResult(
                pooled: diskPooled,
                isHit: true,
                divergenceIndex: reusedCount
            )
        }

        // 5. Cold miss — create fresh session with instructions + processing
        // components: custom logitProcessorFactory for grammar-constrained decoding.
        // Penalty enforcement is automatic via GenerateParameters.processor().
        let freshSession = ChatSession(
            modelContainer,
            instructions: instructions,
            speculativeDecoding: speculativeDecoding,
            generateParameters: genParams,
            components: .init(),
            processing: processing ?? .init(resize: config.vlmImageResize),
        )
        let cacheFile = cacheFileURL(key: key)
        let freshPooled = PooledChatSession(
            session: freshSession,
            lastAccessedAt: ContinuousClock.now,
            cacheFileURL: cacheFile,
            instructionsHash: instructionsFP,
            modelId: modelId,
            messageHistory: []
        )
        // Opportunity accounting, nothing more. The sessions this scans are other
        // conversations' (this key's own entry was either handed back above or dropped as
        // unreusable), and no decision about which session answers this turn reads the
        // result - the pool still keys sessions by conversation.
        if let feed = prefixMessages {
            let candidates = pool.values.compactMap { entry -> CrossConversationPrefix.Candidate? in
                guard entry.modelId == modelId else { return nil }
                return CrossConversationPrefix.Candidate(
                    messageHistory: entry.messageHistory,
                    instructionsHash: entry.instructionsHash)
            }
            if let overlap = CrossConversationPrefix.best(
                feed: feed,
                instructionsHash: instructionsFP,
                candidates: candidates
            ) {
                reuseRefusals.recordOpportunity(modelId: modelId, overlap: overlap)
                logger.info(
                    "Cross-conversation prefix opportunity for \(key): \(overlap.messagesInCommon)/\(overlap.feedMessages) message(s) of this feed are already resident in another session for \(modelId) - counted, not reused: the pool keys sessions by conversation and no rewind reserve is requested"
                )
            }
        }
        missCount += 1
        totalAcquireAttempts += 1
        logHitRateIfNeeded()
        logger.debug("Session pool MISS: \(key)")
        return AcquireResult(
            pooled: freshPooled,
            isHit: false,
            divergenceIndex: 0,
            rewind: pendingRewind
        )
    }

    /// Return a session back to the pool after inference completes.
    ///
    /// - Parameters:
    ///   - pooled: session to return
    ///   - modelId: model identifier
    ///   - conversationId: conversation identifier
    ///   - assistantMessage: Lightweight key of the assistant response appended to the conversation,
    ///     used to extend the message history for prefix matching on the next turn.
    ///     Convert the assistant `Chat.Message` to `MessageHistoryKey` before calling across actor boundary.
    ///     Pass nil for guided gen / tool paths or when generation was cancelled.
    func release(
        pooled: PooledChatSession,
        modelId: String,
        conversationId: String,
        promptMessages: [MessageHistoryKey]? = nil,
        assistantMessage: MessageHistoryKey? = nil,
        mediaFiles: [URL] = [],
    ) async {
        let key = poolKey(modelId: modelId, conversationId: conversationId)
        // Clear tools + toolDispatch + additionalContext to prevent cross-session leakage.
        // Without this, a pooled session reused by a different request could carry over
        // tool specs, dispatch closures, or reasoning context from the previous caller.
        pooled.session.tools = nil
        pooled.session.toolDispatch = nil
        pooled.session.additionalContext = nil
        // synchronize KV cache before returning to pool — ensures any async GPU
        // cache operations from the last stream are flushed. Without this, a
        // reused pooled session could serve stale cache state.
        await pooled.session.synchronize()

        // Price this session's cache while its lock is free. `cacheStatus()` comes back
        // `.realized` once a turn has run, and its per-layer `memoryBytes` are allocated
        // bytes read off the cache's own arrays — the only per-model KV price that is not a
        // guess. A failed read claims nothing: the entry keeps 0, which reads as
        // `not_observed` rather than as a zero-byte cache.
        var measuredBytes = 0
        var measuredTokens = 0
        do {
            let residency = KVCacheResidency(status: try await pooled.session.cacheStatus())
            measuredBytes = residency.residentBytes
            measuredTokens = residency.processedTokens
        } catch {
            logger.debug(
                "KV residency [\(modelId)] not measured: \(error.localizedDescription)")
        }
        // Fold the same measurement into the per-model price the admission gate reserves at.
        // One read, two consumers: a model never priced keeps the fallback and says so.
        await KVCachePriceLedger.shared.record(
            modelId: modelId,
            residentBytes: measuredBytes,
            processedTokens: measuredTokens)

        // The ledger records what the KV cache provably represents after this turn.
        // Before this, nothing ever wrote the prompt side into it — only the assistant
        // key was appended — so a legitimate second turn compared as "cached 1 message
        // vs common prefix 0", failed the reuse gate, and re-prefilled the whole
        // conversation (measured 10-13: 4505-token prompt = 1.219s, then 1.247s and
        // 1.178s on the following turns instead of a warm continuation).
        //
        // Trust it only when the turn completed with an answer and the prompt was
        // plain text. A tool round-trip renders control text into the prompt that this
        // list cannot name, and a ledger longer than the cache would make the next turn
        // skip prefill for tokens that were never cached — silent context loss. An
        // unprovable turn claims nothing: reuse still happens, it just hands the full
        // history back to ChatSession, which reconciles it against its own transcript.
        var entryToPool = pooled
        entryToPool.residentKVBytes = measuredBytes
        entryToPool.residentKVTokens = measuredTokens
        if let promptMessages, let assistantMessage,
            !promptMessages.contains(where: { $0.hasMedia || $0.hasToolTraffic })
        {
            entryToPool.messageHistory = promptMessages + [assistantMessage]
        } else {
            entryToPool.messageHistory = []
        }

        // This turn's inline media joins what the conversation cites, and every cited
        // file is re-touched: the conversation is alive, so everything its transcript
        // reads must stay. Idle-ness is therefore session activity, not upload time —
        // which is what keeps the sweep's TTL honest (see MediaSpool).
        if !mediaFiles.isEmpty {
            var owned = entryToPool.mediaFiles
            for url in mediaFiles where !owned.contains(url) { owned.append(url) }
            entryToPool.mediaFiles = owned
        }
        MediaSpool.touch(entryToPool.mediaFiles, in: mediaDirectory)

        pool[key] = entryToPool

        // LRU eviction if pool exceeds max
        if pool.count > config.maxSessions {
            await evictLRU()
        }
    }

    // MARK: - Memory Pressure Response

    /// React to system-level memory pressure by aggressively evicting pooled sessions.
    ///
    /// Called from HardwareRouter's pressure callback in EnginePool.
    ///
    /// - Parameters:
    ///   - level: 0-3 pressure level from HardwareRouter.
    ///     Level 2+ (serious) → evict sessions older than aggressiveTTL.
    ///     Level 3 (critical) → evict all sessions immediately.
    ///   - trigger: "thermal" or "memory" pressure source for observability.
    func onMemoryPressure(level: Int, trigger: String) async {
        guard level >= 2 else {
            return  // nominal/fair — no action
        }

        let now = ContinuousClock.now
        let before = pool.count
        let persistFlag = config.persistCache

        if level >= 3 {
            // Critical: flush everything to disk and clear pool
            logger.warning(
                "Critical \(trigger) pressure (level 3) — flushing entire session pool (\(before) sessions)"
            )
            let allEntries = pool.map { ($0.key, $0.value) }
            pool.removeAll()
            releaseMedia(of: allEntries.map(\.1))
            for (key, entry) in allEntries {
                if persistFlag {
                    persistEntry(entry, key: key, reason: "pressure flush")
                }
            }
        } else {
            // Serious (level 2): aggressive TTL — evict anything older than 60s
            let aggressiveTTL = Duration.seconds(60)
            let entriesToRemove: [(key: String, entry: PooledChatSession)] = pool.compactMap {
                key, entry in
                let expired = entry.lastAccessedAt.duration(to: now) >= aggressiveTTL
                return expired ? (key, entry) : nil
            }
            logger.warning(
                "Serious \(trigger) pressure (level 2) — aggressive eviction (\(entriesToRemove.count) sessions >60s)"
            )
            for (key, entry) in entriesToRemove {
                if persistFlag {
                    persistEntry(entry, key: key, reason: "pressure")
                }
                pool.removeValue(forKey: key)
            }
            releaseMedia(of: entriesToRemove.map(\.entry))
        }
        let removed = before - pool.count
        if removed > 0 {
            logger.info("Pressure evicted \(removed) session(s) (\(pool.count) remain)")
        }
    }

    // MARK: - Eviction with on-disk persistence

    /// Remove expired sessions based on TTL, persisting their KV cache to disk before eviction.
    private func evictExpired() async {
        let now = ContinuousClock.now
        let ttl = Duration.seconds(config.sessionTTLSeconds)
        let before = pool.count
        let persistFlag = config.persistCache
        let entriesToRemove: [(key: String, entry: PooledChatSession)] = pool.compactMap {
            key, entry in
            // Pinned models stay resident regardless of TTL (omlx is_pinned).
            if isPinnedExempt(poolKey: key, pinnedIDs: pinnedModelIds) {
                return nil
            }
            let expired = entry.lastAccessedAt.duration(to: now) >= ttl
            return expired ? (key, entry) : nil
        }

        for (key, entry) in entriesToRemove {
            if persistFlag {
                persistEntry(entry, key: key, reason: "TTL")
            }
            logger.debug("Evicted expired session: \(key)")
            pool.removeValue(forKey: key)
        }
        releaseMedia(of: entriesToRemove.map(\.entry))
        let removed = before - pool.count
        if removed > 0 {
            logger.info("Expired \(removed) session(s) from pool (\(pool.count) remain)")
        }
    }

    /// Remove the least-recently-used session when pool exceeds max capacity,
    /// persisting its KV cache to disk before eviction.
    private func evictLRU() async {
        // Pinned models are exempt — find the oldest among non-pinned only.
        let candidates = pool.filter { key, _ in
            !isPinnedExempt(poolKey: key, pinnedIDs: pinnedModelIds)
        }
        guard
            let oldestItem = candidates.min(by: {
                $0.value.lastAccessedAt < $1.value.lastAccessedAt
            })
        else {
            return  // pool is over-cap but every resident is pinned
        }
        let oldestKey = oldestItem.key
        let entry = oldestItem.value
        // Remove from pool first to shrink actor mailbox window
        pool.removeValue(forKey: oldestKey)
        releaseMedia(of: [entry])
        if config.persistCache {
            persistEntry(entry, key: oldestKey, reason: "LRU")
        }
        logger.info("LRU evicted: \(oldestKey) (pool: \(pool.count))")
    }

    /// Persist one evicted session: the raw KV snapshot plus the manifest that states
    /// what it represents.
    ///
    /// Off the actor mailbox because `saveCache` can take seconds for a large cache.
    /// The manifest is written only after the cache itself succeeded, so an unpaired
    /// cache file can never present itself as a resumable conversation; a failed
    /// manifest leaves an orphan that the restore path refuses and deletes.
    private func persistEntry(_ entry: PooledChatSession, key: String, reason: String) {
        guard let cacheURL = entry.cacheFileURL else { return }
        enforceDiskBudget()
        let manifest = KVCacheManifest(
            modelId: entry.modelId,
            instructionsHash: entry.instructionsHash,
            messages: entry.messageHistory,
            rewindReserve: kvCacheRewindReserveTokens
        )
        let log = self.logger
        _ = Task.detached(priority: .utility) { [entry, log, cacheURL, manifest] in
            do {
                try await entry.session.saveCache(to: cacheURL)
                if manifest.isUsable {
                    try? self.writeManifest(manifest, for: cacheURL)
                    log.debug("Saved KV cache (\(reason)): \(cacheURL.lastPathComponent)")
                } else {
                    // Nothing to identify it by — save nothing rather than a snapshot
                    // a later turn could pick up without proof of where it came from.
                    try? FileManager.default.removeItem(at: cacheURL)
                    log.debug("Skipped KV cache (\(reason)): unattributed conversation")
                }
            } catch {
                log.warning(
                    "Failed to save KV cache (\(reason)): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - On-disk KV cache I/O

    /// Restore a ChatSession from on-disk KV cache, but only after proving the
    /// snapshot belongs to the conversation asking for it.
    ///
    /// Upstream persists raw KV state and leaves the transcript to the caller
    /// (`ChatSession.swift:1786-1790`): a restored session continues from whatever
    // anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:1787 A restored raw cache therefore uses
    /// tokens the file happens to hold, with no chat template to reconcile against.
    /// Accepting one without proof grafts a previous conversation's context onto a
    /// new request, so every refusal here is also a deletion — a snapshot this build
    /// cannot vouch for never comes back.
    ///
    /// Refuses (and removes the files) when the snapshot is absent, unreadable,
    /// stamped with a different model or system prompt, media-bearing, or not a
    /// prefix of the incoming conversation.
    private func restoreValidatedSession(
        from modelContainer: MLXLMCommon.ModelContainer,
        cacheURL: URL,
        genParams: MLXLMCommon.GenerateParameters,
        speculativeDecoding: MLXLMCommon.SpeculativeDecodingConfig?,
        processing: MLXLMCommon.UserInput.Processing?,
        modelId: String,
        instructionsHash: Int,
        incomingMessages: [MessageHistoryKey],
    ) -> (ChatSession, KVCacheManifest)? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            return nil
        }
        // A cache without a decodable sidecar has no identity: nothing states which
        // conversation its tokens came from. Delete it rather than leave an orphan
        // that every later turn has to refuse again.
        guard let manifest = readManifest(for: cacheURL) else {
            discardCachedSession(
                cacheURL: cacheURL, why: SnapshotRefusal.unusableManifest.logText
            )
            return nil
        }
        if let refusal = manifest.reuseDecision(
            modelId: modelId,
            instructionsHash: instructionsHash,
            incomingMessages: incomingMessages,
            rewindReserve: kvCacheRewindReserveTokens
        ) {
            reuseRefusals.record(modelId: modelId, reason: refusal.ledgerReason)
            discardCachedSession(cacheURL: cacheURL, why: refusal.logText)
            return nil
        }
        do {
            // Use loadPromptCacheSnapshot to keep model state alongside KV cache.
            // Upstream 5c1d95a: models like Qwen-VL store continuation anchors in
            // LMOutput.State; without the state key the next turn would continue
            // from position 0 instead of the cached prefix, silently corrupting output.
            let snapshot = try MLXLMCommon.loadPromptCacheSnapshot(url: cacheURL)
            guard !snapshot.cache.isEmpty else { return nil }
            let restoredTokenCount = snapshot.cache.first?.offset ?? 0
            logger.info(
                "Restoring KV cache snapshot: \(cacheURL.lastPathComponent) tokens=\(restoredTokenCount) state=\(snapshot.state != nil) messages=\(manifest.messages.count)"
            )
            let session = ChatSession(
                modelContainer,
                instructions: nil,  // snapshot cache already encodes system prompt
                promptCache: snapshot,
                speculativeDecoding: speculativeDecoding,
                generateParameters: genParams,
                components: .init(),
                processing: processing ?? .init(resize: config.vlmImageResize),
            )
            return (session, manifest)
        } catch {
            logger.warning(
                "Cache restore failed (\(cacheURL.lastPathComponent)): \(error.localizedDescription)"
            )
            deleteCacheFiles(cacheURL: cacheURL)
            return nil
        }
    }

    // MARK: - Snapshot identity files

    /// Manifest sidecar for a cache file: `x.safetensors` → `x.safetensors.manifest.json`.
    nonisolated private func manifestURL(for cacheURL: URL) -> URL {
        URL(fileURLWithPath: cacheURL.path + ".manifest.json")
    }

    private func readManifest(for cacheURL: URL) -> KVCacheManifest? {
        guard let data = try? Data(contentsOf: manifestURL(for: cacheURL)) else { return nil }
        return try? JSONDecoder().decode(KVCacheManifest.self, from: data)
    }

    /// Write the manifest atomically, so a half-written sidecar can never present
    /// itself as a valid identity.
    nonisolated private func writeManifest(
        _ manifest: KVCacheManifest,
        for cacheURL: URL
    ) throws {
        let target = manifestURL(for: cacheURL)
        try JSONEncoder().encode(manifest).write(to: target, options: .atomic)
    }

    nonisolated private func deleteCacheFiles(cacheURL: URL) {
        for url in [cacheURL, manifestURL(for: cacheURL)] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func discardCachedSession(cacheURL: URL, why: String) {
        deleteCacheFiles(cacheURL: cacheURL)
        logger.info(
            "KV snapshot discarded (\(cacheURL.lastPathComponent)): \(why) — cold build, nothing reused"
        )
    }

    /// Drop the on-disk twin of a rejected in-memory session: it is stale by the
    /// same argument, and leaving it would let a later pool miss revive that context.
    private func deleteCachedSession(key: String) {
        deleteCacheFiles(cacheURL: cacheFileURL(key: key))
    }

    /// Cache file path for a pool key
    private func cacheFileURL(key: String) -> URL {
        // Sanitize key to avoid URL-unfriendly chars
        let safeKey = key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        // MLX dispatches its loader on the file extension (`MLX/IO.swift`) and only
        // recognises `safetensors` here — upstream documents the snapshot as a
        // `.safetensors` file (`KVCache.swift:2102`). With a `.mlx` suffix every save
        // anchor:mlx-swift-lm Libraries/MLXLMCommon/KVCache.swift:2102 The URL to the
        // failed "Unknown extension mlx", so this persistence never wrote a byte.
        return cacheDirectory.appendingPathComponent(safeKey + ".safetensors")
    }

    // MARK: - Disk Budget

    /// Total size of all on-disk KV cache files (bytes).
    private func diskCacheTotalBytes() -> UInt64 {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: cacheDirectory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
            )
        else {
            return 0
        }
        var total: UInt64 = 0
        for url in urls {
            if let attrs = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]) {
                total += UInt64(attrs.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Evict oldest on-disk cache files until total usage is at or below budget.
    /// Used before persisting a new cache to prevent unbounded disk growth.
    private func enforceDiskBudget() {
        let budget = config.persistCacheMaxBytes
        guard budget > 0 else { return }  // 0 = no cap
        let current: UInt64 = diskCacheTotalBytes()
        guard current > budget else { return }  // already under budget

        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: cacheDirectory, includingPropertiesForKeys: [.contentAccessDateKey]
            )
        else {
            return
        }

        // Sort by last access date (oldest first) to evict LRU
        let sorted = urls.sorted {
            let da =
                (try? $0.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate)
                ?? .distantPast
            let db =
                (try? $1.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate)
                ?? .distantPast
            return da < db
        }

        for url in sorted {
            guard diskCacheTotalBytes() > budget else { break }
            do {
                try FileManager.default.removeItem(at: url)
                logger.debug("Pruned cache file to enforce budget: \(url.lastPathComponent)")
            } catch {
                logger.warning("Failed to prune cache file: \(error.localizedDescription)")
            }
        }

        // Orphaned manifests (cache pruned or save failed) are useless on their own;
        // sweep them so the directory cannot accumulate identity files. The suffix is
        // two extensions long, so strip it by hand rather than via
        // `deletingPathExtension()`, which would only remove `.json`.
        let manifestSuffix = ".manifest.json"
        let orphans = urls.filter {
            $0.lastPathComponent.hasSuffix(manifestSuffix)
                && !FileManager.default.fileExists(
                    atPath: String($0.path.dropLast(manifestSuffix.count)))
        }
        for orphan in orphans {
            try? FileManager.default.removeItem(at: orphan)
        }
    }

    // MARK: - Inspection

    /// Current pool size
    var pooledCount: Int {
        pool.count
    }

    /// Pool size and hit-rate snapshot for metrics
    func stats() -> (count: Int, hitRate: Double) {
        let total = hitCount + missCount
        let rate = total > 0 ? Double(hitCount) / Double(total) * 100.0 : 0.0
        return (count: pool.count, hitRate: rate)
    }

    /// Force-clear the pool (e.g. during shutdown or model unload)
    /// Does NOT delete on-disk cache files.
    func clear() {
        let count = pool.count
        releaseMedia(of: Array(pool.values))
        pool.removeAll()
        hitCount = 0
        missCount = 0
        totalAcquireAttempts = 0
        logger.info("Session pool cleared (\(count) sessions evicted)")
    }

    /// Clear only sessions for a specific model (during model unload)
    func clear(modelId: String) {
        let keysToRemove: [String] = pool.compactMap { key, _ in
            key.hasPrefix("\(modelId):") ? key : nil
        }
        releaseMedia(of: keysToRemove.compactMap { pool[$0] })
        for key in keysToRemove {
            pool.removeValue(forKey: key)
        }
        // The refusals were counted against sessions that no longer exist; keeping the
        // tally would publish a number that outlives what it measured.
        reuseRefusals.forget(modelId: modelId)
    }

    /// What this pool has counted about reuse refusals for one model - counts taken at
    /// the sites where the existing rules already said no (ReuseRefusalLedger.swift).
    /// Published on `GET /v1/models/:model/kv-cache`; before any refusal it is an empty
    /// set, never a prediction that reuse would fail.
    func reuseRefusalObservation(modelId: String) -> ReuseRefusalObservation {
        reuseRefusals.observation(modelId: modelId)
    }

    /// What this model's resident sessions are holding in KV bytes, as measured on release.
    func residencyObservation(modelId: String) -> KVCacheResidencyObservation {
        var bytes = 0
        var tokens = 0
        var sessions = 0
        for entry in pool.values where entry.modelId == modelId {
            // An entry that never got priced contributes nothing: `measured` on a set of
            // unpriced caches would be a claim about bytes nobody read.
            guard entry.residentKVBytes > 0 else { continue }
            bytes += entry.residentKVBytes
            tokens += entry.residentKVTokens
            sessions += 1
        }
        return KVCacheResidencyObservation.measured(
            residentBytes: bytes,
            residentSessions: sessions,
            processedTokens: tokens)
    }

    /// KV bytes held by every resident session across every model — the process-wide figure
    /// `/metrics` publishes. Zero honestly means "no priced cache is resident".
    var residentKVBytesTotal: Int {
        pool.values.reduce(0) { $0 + $1.residentKVBytes }
    }

    // MARK: - Helpers

    private func poolKey(modelId: String, conversationId convId: String) -> String {
        "\(modelId):\(convId)"
    }

    /// Release the inline media that conversations leaving the pool cited.
    ///
    /// Call this *after* the entries are out of ``pool``: what remains in the pool is the
    /// keep-set, because content-addressed files can be cited by more than one live
    /// conversation and a file another session still reads must not be deleted.
    private func releaseMedia(of entries: [PooledChatSession]) {
        let leaving = entries.flatMap(\.mediaFiles)
        guard !leaving.isEmpty else { return }
        let keeping = Set(pool.values.flatMap(\.mediaFiles))
        MediaSpool.discard(leaving, keeping: keeping, in: mediaDirectory)
    }

    /// Reuse rule, kept pure so it can be pinned without an MLX container:
    /// a pooled session may serve a new request only when the incoming conversation
    /// extends everything the session already holds. `commonPrefixCount <
    /// cachedMessageCount` means the session contains turns the caller never sent.
    ///
    /// This is not a perf heuristic that can be loosened for a faster hit: the caller
    /// acts on the returned index by *withholding* `messages[0..<divergenceIndex]`
    /// from the model (`EngineInference.swift:3148`), so a cache credited with turns
    /// it was never asked about costs the user their real context — and when the
    /// credit exceeds the incoming message count, the slice `messages[n...]` traps.
    /// A bypass here was briefly tried on 10-13 to observe upstream's own transcript
    /// reconciliation; it turned `SessionIsolationTests.forkRefused` red and is closed.
    ///
    /// `instructionsMatch` is the second premise, and it is not a perf nicety: the session
    /// renders its stored `instructions` at prefill, so a session whose instruction set has
    /// since changed (the client rewrote its system message; this server advertises tools on
    /// one turn and not the next; perception context arrived) would answer this turn under an
    /// instruction list the caller never sent. The disk path has refused on this identity
    /// since it was written (``SnapshotRefusal/instructionsChanged``); the in-memory path
    /// consults the same gate now, so one rule has one home.
    /// Sound when the cached history is a prefix of this turn's feed **and** the feed still
    /// has something for that cache to answer.
    ///
    /// The second clause is the part that was missing (measured 10-22): a ledger whose length
    /// equals the feed claims the cache already holds the caller's newest message. If that
    /// message is one to answer (user/tool), the cache must have answered it already, so the
    /// turn gets fed nothing — and a session fed nothing emits end-of-turn at once while the
    /// request leaves as a success (`200 + completion_tokens=1 + finish_reason=stop`,
    /// reproduced by asking the same prompt twice). Refuse that shape: no skip, full prefill.
    ///
    /// When the feed's newest message is from the assistant the request is "continue this
    /// draft", and a cache holding exactly that transcript is the answer to it — feeding
    /// nothing is correct there, so a trailing-assistant feed keeps its warm session.
    nonisolated static func canReusePooledSession(
        cachedMessageCount: Int,
        commonPrefixCount: Int,
        instructionsMatch: Bool,
        incomingMessageCount: Int,
        newestIncomingFromAssistant: Bool
    ) -> Bool {
        instructionsMatch
            && commonPrefixCount >= cachedMessageCount
            && (commonPrefixCount < incomingMessageCount || newestIncomingFromAssistant)
    }

    /// Rewind boundary for a diverged conversation, or nil when it must be discarded.
    ///
    /// The pair to ``canReusePooledSession``, and it answers a different question. That rule
    /// asks "may this turn be answered from the cache as it stands?" — still no, and it must
    /// stay no: the cache holds turns this caller replaced. This asks "may the cache be
    /// rewound onto the conversation the caller *did* send, before answering?" — the question
    /// upstream's `ChatSession.fork(history:)` exists to take (ChatSession.swift:1723 at pin
    /// 991266ad3), whose trim boundary is the token-level common prefix and which verifies
    /// the trim landed before trusting it. Kept pure and off the MLX path so the whole table
    /// is pinned by `SessionRewindOnDivergenceTests` without a live model.
    ///
    /// Three premises, one home:
    /// - `instructionsMatch`: a session renders the instructions it was *created* with, so a
    ///   rewound fork would still answer under the old instruction list.
    /// - `incomingMessageCount > commonPrefixCount`: past the shared prefix the caller must
    ///   have something to say. The 10-12 cross-talk shape is a same-key resend of an
    ///   already-answered turn (`incoming == commonPrefix`); rewinding there would leave the
    ///   turn no new message and the caller no answer, so it keeps the discard path.
    /// - `!carriesMedia`: a media placeholder is the same tokens for different pixels, so
    ///   shared tokens cannot prove a shared prefix, and upstream refuses to reconcile those
    ///   (ChatSession.swift:330-347) — the fork would start cold while this line claimed a
    // anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:346 return .history(history)
    ///   rewind.
    /// - `laneCanSpend`: this turn generates through the pooled `ChatSession`. Guided gen and
    ///   MTP build their own KV cache and release the slot before generating, so a rewind
    ///   handed to those turns is never spent — and the refusal this site skips when it
    ///   offers would then be a refusal the turn did pay (measured 10-22: an edited resend
    ///   carrying `response_format: json_object` logged a rewind and re-prefilled all 753
    ///   tokens). The caller decides the lane; this axis keeps the offer and the ledger one
    ///   story.
    nonisolated static func rewindHistoryEnd(
        cachedMessageCount: Int,
        commonPrefixCount: Int,
        incomingMessageCount: Int?,
        instructionsMatch: Bool,
        carriesMedia: Bool,
        laneCanSpend: Bool
    ) -> Int? {
        guard laneCanSpend,
            instructionsMatch,
            !carriesMedia,
            commonPrefixCount >= 0,
            commonPrefixCount < cachedMessageCount,
            let incomingMessageCount,
            incomingMessageCount > commonPrefixCount
        else { return nil }
        return commonPrefixCount
    }

    /// Which per-turn generation knobs differ between what a pooled session currently
    /// carries and what this turn asked for.
    ///
    /// Pure, so the field set is pinned by `PooledParameterDriftTests` rather than
    /// inferred from a live run (and the scan floors its own premise there).
    ///
    /// Why this exists: sampling does not travel with the call. Upstream reads the
    /// session's *stored* parameters when a stream starts
    /// (`ChatSession.swift:361` declares `public var generateParameters`, and `streamMap`
    // anchor:mlx-swift-lm Libraries/MLXLMCommon/ChatSession.swift:361 public var generateParameters
    /// captures that property in its task capture list at `:1037-1043`), so handing a pooled
    /// session back untouched means the next turn on that conversation generates under the
    /// previous turn's knobs. Measured 10-19 on this host
    /// (`mlx-community/gemma-4-e2b-it-4bit`, temp 0, two turns on one session): a
    /// `response_format: json_object` turn at `max_tokens=64` left 64 behind, and the next
    /// turn asked for 8 and spent 64 with `finish_reason=length` — 370 characters of text
    /// cut mid-sentence — against `Assembled prompt … wireMaxTokens=8` and
    /// `Generation budget: maxTokens=8` in the same log. A `tools[]` turn at 64 leaked the
    /// same way; a session whose first turn was plain text honoured 8. The asymmetry is
    /// the giveaway: plain turns update the pool's transcript, so the next turn fails
    /// ``canReusePooledSession`` and gets a clean session, while a guided/tool turn
    /// releases with `assistantMessage: nil` (EngineInference's guided/MTP early release),
    /// which parks the session with an empty transcript — and an empty transcript reuses
    /// against anything.
    ///
    /// The cache-affecting fields (`maxKVSize`, `kvBits`, `kvGroupSize`,
    /// `quantizedKVStart`, `kvScheme`, `kvCache`) are deliberately absent: upstream
    /// reconciles those itself, rebuilding the cache from its retained transcript when the
    /// plan moves (`ChatSession.swift:1108-1122`), so a change there is not silently lost
    /// and naming it here would claim a defect upstream already handles.
    nonisolated static func staleSamplingFields(
        before stored: MLXLMCommon.GenerateParameters,
        after incoming: MLXLMCommon.GenerateParameters
    ) -> [String] {
        var fields: [String] = []
        if stored.maxTokens != incoming.maxTokens { fields.append("maxTokens") }
        if stored.temperature != incoming.temperature { fields.append("temperature") }
        if stored.topP != incoming.topP { fields.append("topP") }
        if stored.topK != incoming.topK { fields.append("topK") }
        if stored.minP != incoming.minP { fields.append("minP") }
        if stored.seed != incoming.seed { fields.append("seed") }
        if stored.logProbabilities != incoming.logProbabilities {
            fields.append("logProbabilities")
        }
        if stored.repetitionPenalty != incoming.repetitionPenalty {
            fields.append("repetitionPenalty")
        }
        if stored.repetitionContextSize != incoming.repetitionContextSize {
            fields.append("repetitionContextSize")
        }
        if stored.presencePenalty != incoming.presencePenalty {
            fields.append("presencePenalty")
        }
        if stored.presenceContextSize != incoming.presenceContextSize {
            fields.append("presenceContextSize")
        }
        if stored.frequencyPenalty != incoming.frequencyPenalty {
            fields.append("frequencyPenalty")
        }
        if stored.frequencyContextSize != incoming.frequencyContextSize {
            fields.append("frequencyContextSize")
        }
        if stored.prefill.stepSize != incoming.prefill.stepSize {
            fields.append("prefillStepSize")
        }
        if stored.toolCallPolicy != incoming.toolCallPolicy {
            fields.append("toolCallPolicy")
        }
        return fields
    }

    /// Update the set of model IDs whose sessions are exempt from TTL/LRU eviction.
    /// Called by ``EnginePool`` whenever per-model config is updated via PATCH.
    /// Critical memory pressure (level 3) still flushes everything regardless.
    func setPinnedModels(_ ids: Set<String>) {
        pinnedModelIds = ids
        if !ids.isEmpty {
            logger.info("Pinned models updated: \(ids.sorted())")
        }
    }
    private func logHitRateIfNeeded() {
        guard totalAcquireAttempts % config.metricsLogInterval == 0,
            totalAcquireAttempts > 0
        else { return }
        let total = hitCount + missCount
        let rate = total > 0 ? Double(hitCount) / Double(total) * 100.0 : 0.0
        logger.info(
            "Session pool stats after \(total) acquires: \(pool.count) pooled, hit rate \(String(format: "%.1f%%", rate))",
        )
    }
}

// MARK: - Pure Pinning helper (top-level, testable without an actor instance)

/// Check whether a pool key's model is pinned (exempt from TTL/LRU eviction).
///
/// Pure key-string comparison — no ChatSession or actor dependency, so it is
/// directly unit-testable. Returns `false` for malformed keys or empty pin sets
/// (conservative: an unmatched key is treated as evictable).
package func isPinnedExempt(poolKey key: String, pinnedIDs: Set<String>) -> Bool {
    guard !pinnedIDs.isEmpty else {
        return false
    }
    guard let mid = key.split(separator: ":").first.map(String.init) else {
        return false
    }
    return pinnedIDs.contains(mid)
}
