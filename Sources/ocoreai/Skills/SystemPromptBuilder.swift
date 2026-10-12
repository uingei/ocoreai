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
    /// Coding-agent base prompt (single source of truth; name = legacy, the
    /// identity is the canonical sentence the owner states (09-27, 3rd restatement,
    /// final): "an agent for open models, natively local, built for creativity,
    /// work, and code", with the 09-27 fuller elaboration "a complete agentic
    /// system designed for coding and knowledge work" attached as a non-conflicting
    /// companion phrase. Both phrasings coexist; the owner sentence leads —
    /// per AGENTS.md "What it is" and README headline.
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
    /// Identity + honesty — valid on EVERY turn, tools present or not.
    static let codingAgentIdentity =
        "You are oCoreAI — an agent for open models, natively local, built for creativity, work, and code; "
        + "a complete agentic system designed for coding and knowledge work. "
        + "You maximize truth-seeking, curiosity, and honesty above pleasing anyone: "
        + "prefer the correct answer over the softer one, keep investigating when the answer is uncertain, "
        + "and state plainly what you did not verify — never hide, soften, or fabricate results."

    /// Action-first directive — valid ONLY when this turn actually has tools.
    ///
    /// The claim-discipline sentence is not decoration. Live on 2026-10-12 with
    /// `web_search` declared, gemma-4-e2b-it-4bit answered "I have searched the
    /// web for the latest MLX release notes… (Source: https://mlx.studio/)" with
    /// NO tool call dispatched — a narrated action plus invented citations. A
    /// narrative that sounds like a completed action is the most expensive failure
    /// mode for an agent product, so the rule is stated operationally rather than
    /// as a value: claiming an action requires having called the tool and seen the
    /// result. (Paired with ``noToolsDirective`` for the zero-tool case.)
    static let toolActionDirective =
        "Assume the user wants code changes or tool actions that solve their problem: "
        + "use your tools to actually implement changes and run commands, don't just describe what you would do. "
        + "When you finish, report what changed and how you verified it. "
        + "Claiming an action requires having called the tool and seen its result: never say you "
        + "searched, fetched, ran, read, or changed anything unless a tool result in this "
        + "conversation says so — narration that sounds like a completed action is not one."

    /// Zero-tool directive — what to do instead, plus an explicit ban on
    /// simulating tools. Required, not decorative: with the action-first line
    /// still present and no tools bound, a live gemma-4-e2b-it-4bit turn
    /// (2026-10-12, `tools` absent → engine resolved a zero surface) answered
    /// "count from 1 to 60" with a fabricated transcript —
    /// `terminal\ncommand: "seq 1 60"\nstdout: "1 2 3 …"` — i.e. invented
    /// command output presented as fact, the exact failure the identity line
    /// forbids. A model told to "run commands" will simulate them when it can't.
    static let noToolsDirective =
        "This conversation gives you no tools: answer directly from your own knowledge and reasoning. "
        + "Never pretend to run a command, never invent tool output, terminal transcripts, diffs, or file "
        + "contents — text that reads like an executed command is a fabrication, not a result."

    /// Base prompt for a turn whose tool surface is known.
    static func basePrompt(hasTools: Bool) -> String {
        hasTools
            ? codingAgentIdentity + " " + toolActionDirective
            : codingAgentIdentity + " " + noToolsDirective
    }

    /// Legacy alias: the with-tools composition. Kept as the named source of
    /// truth for the action-first contract (`SystemPromptContractTests`); the
    /// per-turn text comes from ``basePrompt(hasTools:)``.
    static let codingAgentBase = basePrompt(hasTools: true)

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
    func build(includeCategories: [String]? = nil, hasTools: Bool = true) async -> String {
        // Compute content hash
        let newHash = await computeHash(categories: includeCategories, hasTools: hasTools)

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
        // Division of labour: `basePrompt` carries IDENTITY only; the tool
        // directive is chosen here, per turn, from the surface the turn actually
        // has. Default `hasTools: true` keeps the pre-existing wording for
        // callers that state nothing about tools; the production path
        // (`MessageBuilder`) always passes the real surface.
        let base = basePrompt + " " + (hasTools ? Self.toolActionDirective : Self.noToolsDirective)
        if !skillSection.isEmpty {
            parts = [base, "", "# Available Skills\n", skillSection]
        } else {
            parts = [base]
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
    private func computeHash(categories: [String]?, hasTools: Bool) async -> String {
        var hasher = Hasher()
        hasher.combine(basePrompt)
        // The tool surface changes the prompt text, so it must be part of the
        // cache key or an agentic turn could serve a cached no-tools prompt
        // (and vice versa) on the very next request to the same builder.
        hasher.combine(hasTools)
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
    ///
    /// `hasTools` must reflect the tool surface this turn can actually execute:
    /// it decides whether the model is told to act with tools or to answer
    /// without them (see ``noToolsDirective``).
    func buildSystemPrompt(hasTools: Bool = true) async -> String {
        await build(hasTools: hasTools)
    }
}
