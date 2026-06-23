// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SkillRegistry.swift — Actor-isolated skill registry with dependency resolution
///
/// Manages skill lifecycle: bootstrap → scan → dependency resolve → hot-reload.
/// Uses Kahn's algorithm for topological sort to detect circular dependencies.
///
/// ### Optimizations (v2):
/// - 拓扑排序结果缓存 — 只在 skill 集合变化时重算
/// - mtime 增量扫描 — 只重新解析变更的 skill 文件
/// - promptContent 预计算 — 注册时缓存，避免 build() 时重复 serialize

import Foundation
import Logging

/// Actor holding the authoritative skill registry state.
actor SkillRegistry {
    private let logger: Logger
    private var skills: [String: Skill] = [:]
    private var indexByCategory: [String: [String]] = [:]
    private var indexByTag: [String: [String]] = [:]

    // mtime 快照 — 用于增量扫描
    private var fileMtimes: [URL: Date] = [:]

    // 拓扑排序 dirty 标记
    private var resolvedDirty: Bool = true

    // resolvedOrder 缓存
    private var cachedResolvedOrder: [String] = []

    private var hotReloadCallback: (@Sendable () async -> Void)?
    private var systemPromptBuilder: SystemPromptBuilder?

    /// Create registry with logger.
    init(log: Logger = Logger(label: "ocoreai.skills")) {
        self.logger = log
    }

    /// Bootstrap the registry: load built-in skills, then scan disk skills directory.
    func bootstrap(skillsDir: URL?, systemPromptBuilder: SystemPromptBuilder? = nil) async throws {
        self.systemPromptBuilder = systemPromptBuilder

        // Step 1: Register built-in skills
        for builtin in BuiltInSkill.allCases {
            let metadata = SkillMetadata(
                name: builtin.rawValue,
                category: builtin.displayCategory,
                description: builtin.description,
                tags: ["builtin"],
                dependencies: builtin.dependencies.map(\.rawValue)
            )
            let skill = Skill(
                metadata: metadata,
                body: builtin.description,
                path: "builtin://\(builtin.rawValue)",
                status: .loaded,
                loadedAt: Date()
            )
            self.register(skill, skipCheck: true)
        }

        // Step 2: Scan disk skills if directory provided
        if let skillsDir {
            _ = self.loadDiskSkills(in: skillsDir, incremental: false)
        }

        // Step 3: Resolve dependency order
        self.resolveIfNeeded()
    }

    /// Reload disk skills without affecting built-ins (增量扫描).
    func reloadSkills(skillsDir: URL) async {
        _ = self.loadDiskSkills(in: skillsDir, incremental: true)
        self.resolveIfNeeded()
        if let callback = self.hotReloadCallback {
            await callback()
        }
    }

    /// Register a hot-reload callback invoked on registry changes.
    func setHotReloadCallback(_ callback: @escaping @Sendable () async -> Void) {
        self.hotReloadCallback = callback
    }

    // MARK: - Lookup

    /// Lookup skill by name.
    func lookup(_ name: String) -> Skill? {
        self.skills[name]
    }

    /// Lookup skills by category.
    func lookupCategory(_ category: String) -> [Skill] {
        guard let names = self.indexByCategory[category] else { return [] }
        return names.compactMap { self.skills[$0] }
    }

    /// Lookup skills by tag.
    func lookupTag(_ tag: String) -> [Skill] {
        guard let names = self.indexByTag[tag] else { return [] }
        return names.compactMap { self.skills[$0] }
    }

    /// Get skills in dependency-resolved order for system prompt assembly.
    func resolvedSkills() -> [Skill] {
        self.cachedResolvedOrder.compactMap { self.skills[$0] }
    }

    /// Get all loaded skill names.
    func list() -> [String] {
        Array(self.skills.keys)
    }

    /// Get all categories.
    func listCategories() -> [String] {
        Array(self.indexByCategory.keys)
    }

    // MARK: - Dependency Resolution (cached)

    /// Resolve dependency order if dirty — otherwise return cached result.
    private func resolveIfNeeded() {
        guard self.resolvedDirty else { return }

        do {
            self.cachedResolvedOrder = try self.resolveOrder()
            self.resolvedDirty = false
        } catch {
            self.logger.error("Dependency resolution warning: \(error.localizedDescription)")
            self.cachedResolvedOrder = Array(self.skills.keys)
            self.resolvedDirty = false
        }
    }

    /// Topological sort using Kahn's algorithm.
    private func resolveOrder() throws -> [String] {
        let allNames = Array(self.skills.keys)
        var inDegree: [String: Int] = [:]
        var adjacency: [String: [String]] = [:]

        for name in allNames {
            guard inDegree[name] == nil else { continue }
            inDegree[name] = 0
        }

        for name in allNames {
            guard let skill = self.skills[name] else { continue }
            for dep in skill.dependencyNames where dep != name {
                if self.skills[dep] != nil {
                    adjacency[dep, default: []].append(name)
                    inDegree[name, default: 0] += 1
                }
            }
        }

        var queue: [String] = inDegree.filter { $0.value == 0 }.map(\.key)
        var result: [String] = []

        while !queue.isEmpty {
            let current = queue.removeFirst()
            result.append(current)
            for neighbor in adjacency[current, default: []] {
                guard let deg = inDegree[neighbor] else {
                    throw SkillError.circularDependency(cycle: [neighbor])
                }
                inDegree[neighbor] = deg - 1
                if inDegree[neighbor] == 0 {
                    queue.append(neighbor)
                }
            }
        }

        guard result.count == allNames.count else {
            let remaining = Set(allNames).subtracting(result)
            throw SkillError.circularDependency(cycle: Array(remaining))
        }

        return result
    }

    /// Mark resolved order as dirty (called when skills change).
    private func markDirty() {
        self.resolvedDirty = true
    }

    // MARK: - Internal

    /// Register a skill — removes old index entries if already registered.
    private func register(_ skill: Skill, skipCheck: Bool = false) {
        guard let existing = self.skills[skill.name] else {
            self.skills[skill.name] = skill
            self.indexByCategory[skill.category, default: []].append(skill.name)
            for tag in skill.metadata.tags {
                self.indexByTag[tag, default: []].append(skill.name)
            }
            self.markDirty()
            return
        }

        // Remove from old indices
        if var cats = self.indexByCategory[existing.category] {
            cats.removeAll { $0 == skill.name }
            self.indexByCategory[existing.category] = cats
        }
        for tag in existing.metadata.tags {
            if var tags = self.indexByTag[tag] {
                tags.removeAll { $0 == skill.name }
                self.indexByTag[tag] = tags
            }
        }

        self.skills[skill.name] = skill
        self.indexByCategory[skill.category, default: []].append(skill.name)
        for tag in skill.metadata.tags {
            self.indexByTag[tag, default: []].append(skill.name)
        }

        self.markDirty()
    }

    /// Remove a skill by name.
    func remove(_ name: String) -> Skill? {
        guard let skill = self.skills.removeValue(forKey: name) else { return nil }

        if var cats = self.indexByCategory[skill.category] {
            cats.removeAll { $0 == name }
            self.indexByCategory[skill.category] = cats
        }
        for tag in skill.metadata.tags {
            if var tags = self.indexByTag[tag] {
                tags.removeAll { $0 == name }
                self.indexByTag[tag] = tags
            }
        }

        for fileURL in self.fileMtimes.keys {
            if !fileURL.hasDirectoryPath && fileURL.lastPathComponent.lowercased() == "\(name.lowercased()).md" {
                self.fileMtimes.removeValue(forKey: fileURL)
            }
        }
        self.markDirty()
        return skill
    }

    /// Load disk skills — incremental only if flag is true.
    private func loadDiskSkills(in dir: URL, incremental: Bool) -> Int {
        let discovered = self.discoverSkills(
            in: dir,
            mtimes: incremental ? self.fileMtimes : [:]
        )

        var newCount = 0
        for skill in discovered {
            self.register(skill)
            newCount += 1

            let url = URL(fileURLWithPath: skill.path)
            if let modDate = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate {
                self.fileMtimes[url] = modDate
            }
        }

        if newCount > 0 {
            self.logger.info("Loaded \(newCount) disk skill(s) from \(dir.path)")
        }

        return newCount
    }

    /// Discover skills — wraps the module-level function.
    private func discoverSkills(in searchDir: URL, mtimes knownMtimes: [URL: Date]) -> [Skill] {
        discoverSkillsIncremental(in: searchDir, mtimes: knownMtimes)
    }
}
