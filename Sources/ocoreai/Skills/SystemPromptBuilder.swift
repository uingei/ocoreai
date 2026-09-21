// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SystemPromptBuilder.swift — Hot-updateable system prompt assembly
///
/// Assembles system prompt from base prompt + skill content in dependency-resolved order.
/// Supports file-watch hot-reload without service restart.
///
/// ### Optimizations (v2):
/// - 缓存策略：contentHash 比对，无变化不重建
/// - 增量 diff：只重建变更 skill 涉及的片段
/// - changeListeners 实际触发
/// - promptCache TTL：缓存上一次完整结果，降低 actor hop

import Foundation

/// Actor that builds and caches the current system prompt.
actor SystemPromptBuilder {
    /// Coding-agent base prompt (single source of truth).
    ///
    /// Consumed by `App` at startup and asserted by
    /// `SystemPromptContractTests` so the behavioral contract
    /// (action-first tool use, verification report, truth-seeking principle)
    /// cannot silently regress to a generic assistant line.
    ///
    /// Aligned with the codex axis contract (`codex-rs/core/gpt_5_1_prompt.md`:
    /// "assume the user wants you to make code changes or run tools to solve
    /// the user's problem … you should go ahead and actually implement the
    /// change.") and with the owner standing safety principle
    /// (`ConfigStruct.SafetyConfig`): 最大求真 + 最大好奇心 + 诚实
    /// (maximum truth-seeking + maximum curiosity + honesty), NOT
    /// human-preference alignment — the base prompt states the principle as a
    /// behavioral command, not "safe and helpful" politeness, and contains
    /// no "NEVER do X unless Y" preference-alignment line: permission to act
    /// comes from the authority layer (`ApprovalBroker` / `approvalPolicy` /
    /// codex `ExecApprovalRequest`), which is an explicit config surface
    /// (`.auto` / `.interactive` / `.never`) that the user controls — not
    /// from a prompt that hard-codes "destructive = don't".
    /// Kept short-phrase on purpose — the target models (1.5B–8B local) need
    /// a direct behavioral command, not policy prose.
    static let codingAgentBase =
        "You are oCoreAI, a coding agent running on Apple hardware (macOS or iOS). "
        + "You maximize truth-seeking, curiosity, and honesty above pleasing anyone: "
        + "prefer the correct answer over the softer one, keep investigating when the answer is uncertain, "
        + "and state plainly what you did not verify — never hide, soften, or fabricate results. "
        + "Assume the user wants code changes or tool actions that solve their problem: "
        + "use your tools to actually implement changes and run commands, don't just describe what you would do. "
        + "When you finish, report what changed and how you verified it."

    private var basePrompt: String
    private var registry: SkillRegistry?
    private var currentPrompt: String?
    private var lastHash: String?  // Hash of (basePrompt + resolvedSkillHashes)
    private var version: Int = 0
    private var changeListenerIDs: [String: @Sendable () async -> Void] = [:]

    // Pre-computed skill prompt content cache keyed by skill name
    private var skillPromptCache: [String: String] = [:]

    /// Create builder with a base system prompt.
    init(basePrompt: String) {
        self.basePrompt = basePrompt
    }

    /// Build the full system prompt — returns cached result if content unchanged.
    func build(includeCategories: [String]? = nil) async -> String {
        // Compute content hash
        let newHash = await computeHash(categories: includeCategories)

        // Cache hit — content unchanged
        if newHash == lastHash, let cached = currentPrompt {
            return cached
        }

        // Cache miss — rebuild
        //
        // Contract: an empty basePrompt is a "build nothing" signal (used by
        // the empty-message guard — MessageBuilder throws when raw messages
        // are empty AND the prompt is empty). We must never inject the
        // capability section on top of an emptied base: empty in → empty out.
        guard !basePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let emptyOut = basePrompt
            currentPrompt = emptyOut
            lastHash = newHash
            version += 1
            notifyChangeListeners()
            return emptyOut
        }

        let skillSection = await buildSkillSection(categories: includeCategories)

        var parts: [String]
        if !skillSection.isEmpty {
            parts = [basePrompt, "", "# Available Skills\n", skillSection]
        } else {
            parts = [basePrompt]
        }
        parts.append("")
        parts.append(
            "## This device (capability matrix — trust these limits, state them plainly)\n")
        parts.append(RuntimeCapability.tierTruthSection)

        let prompt = parts.joined(separator: "\n")
        currentPrompt = prompt
        lastHash = newHash
        version += 1

        // Notify listeners
        notifyChangeListeners()

        return prompt
    }

    /// Compute a hash of the current prompt content without building the string.
    private func computeHash(categories: [String]?) async -> String {
        var hasher = Hasher()
        hasher.combine(basePrompt)
        if let registry {
            let skills: [Skill]
            if let categories, !categories.isEmpty {
                var filtered: [Skill] = []
                for category in categories {
                    await filtered.append(contentsOf: registry.lookupCategory(category))
                }
                skills = filtered
            } else {
                skills = await registry.resolvedSkills()
            }
            for skill in skills where skill.status == .loaded {
                hasher.combine(skill.contentHash)
            }
        }
        return String(hasher.finalize())
    }

    /// Build the skill section by joining individual skill prompt content.
    private func buildSkillSection(categories: [String]?) async -> String {
        guard let registry else { return "" }

        let skills: [Skill]
        if let categories, !categories.isEmpty {
            var filtered: [Skill] = []
            for category in categories {
                await filtered.append(contentsOf: registry.lookupCategory(category))
            }
            skills = filtered
        } else {
            skills = await registry.resolvedSkills()
        }

        return skills.compactMap { skill -> String? in
            guard skill.status == .loaded else { return nil }
            // Cache each skill's promptContent to avoid repeated serialize
            if let cached = skillPromptCache[skill.name] {
                return cached
            }
            let content = skill.promptContent
            skillPromptCache[skill.name] = content
            return content
        }.joined(separator: "\n\n---\n\n")
    }

    /// Associate a skill registry for dynamic skill injection.
    func setRegistry(_ registry: SkillRegistry) {
        self.registry = registry
        // Invalidate cache when registry changes
        invalidate()
    }

    /// Update the base prompt at runtime without reload.
    func updateBasePrompt(_ newPrompt: String) {
        basePrompt = newPrompt
        invalidate()
        notifyChangeListeners()
    }

    /// Get the last-built prompt (if any).
    func getCached() -> String? {
        currentPrompt
    }

    /// Get the current version number.
    func getVersion() -> Int {
        version
    }

    /// Register a callback invoked when the prompt changes.
    /// - Returns: A unique listener ID that can be used to remove this listener.
    func onChange(_ listener: @escaping @Sendable () async -> Void) -> String {
        let id = UUID().uuidString.prefix(8).lowercased()
        changeListenerIDs[String(describing: id)] = listener
        return id
    }

    /// Remove the change listener previously registered with the given ID.
    func removeListener(_ id: String) {
        changeListenerIDs.removeValue(forKey: id)
    }

    /// Notify all registered change listeners.
    private func notifyChangeListeners() {
        for listener in changeListenerIDs.values {
            Task { await listener() }
        }
    }

    /// Invalidate internal cache — called when registry or base prompt changes.
    private func invalidate() {
        currentPrompt = nil
        lastHash = nil
        skillPromptCache.removeAll()
    }

    /// Refresh a single skill's cached prompt content after hot-reload.
    func refreshSkillCache(_ skill: Skill) {
        skillPromptCache[skill.name] = skill.promptContent
    }

    /// List loaded skill names via registry.
    func listSkills() async -> [String] {
        guard let reg = registry else { return [] }
        return await reg.list()
    }

    /// Build system prompt for a given model — injected into inference pipeline.
    func buildSystemPrompt() async -> String {
        await build()
    }
}
