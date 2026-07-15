// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// ModelIdentity.swift — Unified model identity for HuggingFace / ModelScope / local sources
//
// Problems this solves:
//   1. Prefix rules (mscope:, hf:, huggingface:) duplicated in 4+ places
//   2. String interpolation prone to typos — no compile-time safety
//   3. Progress key alignment breaks when prefix stripping logic diverges

import Foundation

/// Strongly-typed model identity — replaces the prefix-based string convention.
///
/// - huggingFace(repoId:) — e.g. "mlx-community/Qwen3.5-4B"
/// - modelScope(repoId:) — e.g. "Qwen/Qwen2.5-7B-Instruct"
/// - local(path:) — filesystem path
///
/// The ``prefixedId`` property produces the EnginePool-compatible string
/// (e.g. "mscope:Qwen/Qwen2.5-7B-Instruct") — this is the single place
/// where prefix concatenation happens.
struct ModelIdentity: Identifiable, Hashable, Codable, Sendable {
    let id: String

    enum Source: Hashable, Codable, Sendable {
        case huggingFace(repoId: String)
        case modelScope(repoId: String)
        case local(path: String)
    }

    var source: Source

    init(id: String, source: Source) {
        self.id = id
        self.source = source
    }

    /// Create from HuggingFace repo ID.
    static func huggingFace(_ repoId: String) -> ModelIdentity {
        ModelIdentity(id: repoId, source: .huggingFace(repoId: repoId))
    }

    /// Create from ModelScope repo ID.
    static func modelScope(_ repoId: String) -> ModelIdentity {
        ModelIdentity(id: repoId, source: .modelScope(repoId: repoId))
    }

    /// Create from local filesystem path.
    static func local(_ path: String) -> ModelIdentity {
        ModelIdentity(id: path, source: .local(path: path))
    }

    /// EnginePool-compatible model ID with hub prefix.
    /// EnginePool.loadModel reads `hf:` prefix to route config fetch
    /// and MLXModelLoader to HuggingFace vs ModelScope.
    var prefixedId: String {
        switch source {
        case .huggingFace:
            return "hf:" + id
        case .modelScope:
            return "mscope:" + id
        case .local:
            return id
        }
    }

    /// Plain repo ID without any prefix. Used for progress key alignment
    /// and display purposes.
    var repoId: String { id }

    /// HubSource equivalent for picker bindings.
    var hubSource: HubSource {
        switch source {
        case .huggingFace: return .huggingFace
        case .modelScope: return .modelScope
        case .local: return .huggingFace
        }
    }

    // MARK: - Parsing

    /// Parse a raw model ID string into a ModelIdentity.
    ///
    /// Priority: mscope: prefix > hf:/huggingface: prefix > contains "/" (assumed HF) > local fallback.
    /// This is the ONLY place prefix rules are defined.
    static func parse(_ raw: String) -> ModelIdentity {
        parse(raw, hub: nil)
    }

    /// Parse with an optional Hub source override.
    /// When `hub` is provided and the raw string has no explicit prefix,
    /// the override decides whether a bare "org/repo" belongs to that Hub.
    static func parse(_ raw: String, hub: HubSource?) -> ModelIdentity {
        // mscope: prefix → ModelScope
        if raw.hasPrefix("mscope:") {
            let repoId = String(raw.dropFirst(7))
            return modelScope(repoId)
        }
        // hf: prefix → HuggingFace
        if raw.hasPrefix("hf:") {
            let repoId = String(raw.dropFirst(3))
            return huggingFace(repoId)
        }
        // huggingface: prefix → HuggingFace
        if raw.hasPrefix("huggingface:") {
            let repoId = String(raw.dropFirst(12))
            return huggingFace(repoId)
        }
        // Bare "org/repo" → use hub override if available, else default HF
        if raw.contains("/") && !raw.hasPrefix("/") && !raw.hasPrefix("~/") {
            if hub == .modelScope {
                return modelScope(raw)
            }
            return huggingFace(raw)
        }
        // Absolute or tilde path → local
        if raw.hasPrefix("/") || raw.hasPrefix("~/") {
            return local(raw)
        }
        // Single component — treat as local fallback
        return local(raw)
    }
}

/// Extract the progress key from any modelId string.
/// Strips legacy prefixes (mscope:, hf:, huggingface:) for backward compatibility;
/// new code should use bare repo IDs with an explicit source parameter.
extension String {
    var progressKey: String {
        if self.hasPrefix("mscope:") { return String(self.dropFirst(7)) }
        if self.hasPrefix("hf:") { return String(self.dropFirst(3)) }
        if self.hasPrefix("huggingface:") { return String(self.dropFirst(12)) }
        return self
    }
}
