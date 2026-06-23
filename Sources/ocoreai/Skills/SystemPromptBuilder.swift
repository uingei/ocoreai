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
        let skillSection = await buildSkillSection(categories: includeCategories)

        let parts: [String]
        if !skillSection.isEmpty {
            parts = [basePrompt, "", "# Available Skills\n", skillSection]
        } else {
            parts = [basePrompt]
        }

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
        if let registry = self.registry {
            let skills: [Skill]
            if let categories = categories, !categories.isEmpty {
                var filtered: [Skill] = []
                for category in categories {
                    filtered.append(contentsOf: await registry.lookupCategory(category))
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
        guard let registry = self.registry else { return "" }

        let skills: [Skill]
        if let categories = categories, !categories.isEmpty {
            var filtered: [Skill] = []
            for category in categories {
                filtered.append(contentsOf: await registry.lookupCategory(category))
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
        guard let reg = self.registry else { return [] }
        return await reg.list()
    }

    /// Build system prompt for a given model — injected into inference pipeline.
    func buildSystemPrompt() async -> String {
        await build()
    }
}
