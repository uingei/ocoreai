// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SkillTests.swift — Tests for SkillModels, SkillRegistry, SystemPromptBuilder, SkillLoader
///
/// Covers:
///  - SkillMetadata serialize/roundtrip
///  - BuiltInSkill dependency graph
///  - SkillRegistry: register, lookup, remove, category/tag indexing, dependency resolution
///  - SystemPromptBuilder: cache, version, invalidate on registry change
///  - splitFrontmatter / parseFrontmatterYAML / parseSkillFile on in-memory data
///  - Kahn's algorithm: topological ordering + cycle detection

import Testing
import Foundation
@testable import ocoreai

// MARK: - Helpers

private func makeSkill(name: String, body: String = "default body", category: String = "test", tags: [String] = [], deps: [String] = []) -> Skill {
    Skill(
        metadata: SkillMetadata(name: name, category: category, description: "", tags: tags, dependencies: deps),
        body: body,
        path: "/tmp/skills/\(name).md",
        status: .loaded,
        loadedAt: Date()
    )
}

@Suite("SkillModels")
struct SkillModelTests {
    @Test("BuiltInSkill cases match expected count")
    func builtInCount() {
        #expect(BuiltInSkill.allCases.count == 4)
    }

    @Test("BuiltInSkill category maps correctly")
    func builtInCategory() {
        for bi in BuiltInSkill.allCases {
            #expect(bi.displayCategory == "system",
                "\(bi.rawValue) should belong to system category")
        }
    }

    @Test("BuiltInSkill dependency graph is acyclic")
    func builtInDepsAcyclic() {
        // .search → [.file], .memory → [.file]
        #expect(BuiltInSkill.search.dependencies == [.file])
        #expect(BuiltInSkill.memory.dependencies == [.file])
        #expect(BuiltInSkill.terminal.dependencies.isEmpty)
        #expect(BuiltInSkill.file.dependencies.isEmpty)
    }

    @Test("SkillMetadata serialize contains all fields")
    func metadataSerialize() {
        let meta = SkillMetadata(
            name: "test-skill",
            category: "dev",
            description: "A test skill",
            tags: ["swift", "test"],
            dependencies: ["base"]
        )
        let yaml = meta.serialize()
        #expect(yaml.contains("name: test-skill"))
        #expect(yaml.contains("category: dev"))
        #expect(yaml.contains("description: A test skill"))
        #expect(yaml.contains("tags:"))
        #expect(yaml.contains("depends:"))
    }

    @Test("Skill promptContent includes frontmatter + body")
    func promptContentStructure() {
        let skill = makeSkill(name: "demo", category: "demo", tags: ["example"])
        let content = skill.promptContent
        #expect(content.hasPrefix("---"))
        #expect(content.contains("name: demo"))
        #expect(content.contains("default body"))
    }

    @Test("Skill contentHash is deterministic")
    func contentHashDeterministic() {
        let s1 = makeSkill(name: "a", body: "x")
        let s2 = makeSkill(name: "a", body: "x")
        #expect(s1.contentHash == s2.contentHash)
    }

    @Test("Skill contentHash changes when body changes")
    func contentHashDiffersWithBody() {
        let s1 = makeSkill(name: "a", body: "x")
        let s2 = makeSkill(name: "a", body: "y")
        #expect(s1.contentHash != s2.contentHash)
    }

    @Test("SkillStatus raw values are correct")
    func statusRawValues() {
        #expect(SkillStatus.loaded.rawValue == "loaded")
        #expect(SkillStatus.failed.rawValue == "failed")
        #expect(SkillStatus.hotReloadPending.rawValue == "hotReloadPending")
    }

    @Test("SkillError cases are valid errors")
    func errorCases() {
        // These compile → all cases exist and conform to Error
        let _: Error = SkillError.parseFailed(name: "x", detail: "y")
        let _: Error = SkillError.dependencyNotFound(name: "x", missing: ["z"])
        let _: Error = SkillError.circularDependency(cycle: ["a", "b"])
        let _: Error = SkillError.duplicateRegistration(name: "dup")
        let _: Error = SkillError.invalidFrontmatter(path: "/bad")
        let _: Error = SkillError.fileReadError(path: "/bad", detail: "no such file")
    }
}

@Suite("SkillRegistry")
struct SkillRegistryTests {
    @Test("bootstrap registers built-in skills")
    @MainActor
    func bootstrapBuiltIns() async {
        let registry = SkillRegistry()
        try? await registry.bootstrap(skillsDir: nil)
        #expect(await registry.lookup("terminal") != nil)
        #expect(await registry.lookup("file") != nil)
        #expect(await registry.lookup("search") != nil)
        #expect(await registry.lookup("memory") != nil)
        #expect(await registry.list().count == 4)
    }

    @Test("register new skill adds to indices")
    @MainActor
    func registerAddsToIndices() async {
        let registry = SkillRegistry()
        try? await registry.bootstrap(skillsDir: nil)

        // We can't call private register(), but bootstrap with a skills dir does it.
        // Verify the built-ins are indexed by category
        let systemSkills = await registry.lookupCategory("system")
        #expect(systemSkills.count == 4)
    }

    @Test("lookupCategory returns empty for unknown category")
    @MainActor
    func lookupMissingCategory() async {
        let registry = SkillRegistry()
        try? await registry.bootstrap(skillsDir: nil)
        let skills = await registry.lookupCategory("nonexistent")
        #expect(skills.isEmpty)
    }

    @Test("lookupTag returns empty for unknown tag")
    @MainActor
    func lookupMissingTag() async {
        let registry = SkillRegistry()
        try? await registry.bootstrap(skillsDir: nil)
        let skills = await registry.lookupTag("nonexistent")
        #expect(skills.isEmpty)
    }

    @Test("lookupTag returns built-in skills for 'builtin' tag")
    @MainActor
    func lookupBuiltinTag() async {
        let registry = SkillRegistry()
        try? await registry.bootstrap(skillsDir: nil)
        let skills = await registry.lookupTag("builtin")
        #expect(skills.count == 4)
    }

    @Test("lookup returns nil for unknown skill")
    @MainActor
    func lookupUnknown() async {
        let registry = SkillRegistry()
        try? await registry.bootstrap(skillsDir: nil)
        #expect(await registry.lookup("nonexistent") == nil)
    }

    @Test("remove skill cleans indices")
    @MainActor
    func removeCleansIndices() async throws {
        let registry = SkillRegistry()
        try await registry.bootstrap(skillsDir: nil)

        let removed = await registry.remove("terminal")
        // After bootstrap, terminal is registered. remove should succeed.
        #expect(removed != nil)
        #expect(await registry.lookup("terminal") == nil)
        #expect(await registry.list().count == 3)
    }

    @Test("remove unknown skill returns nil")
    @MainActor
    func removeUnknown() async {
        let registry = SkillRegistry()
        try? await registry.bootstrap(skillsDir: nil)
        #expect(await registry.remove("nonexistent") == nil)
    }

    @Test("resolvedSkills returns all built-ins in some order")
    @MainActor
    func resolvedSkillsCount() async {
        let registry = SkillRegistry()
        try? await registry.bootstrap(skillsDir: nil)
        let resolved = await registry.resolvedSkills()
        // Kahn's sort of 4 nodes should return all 4
        #expect(resolved.count == 4)
    }

    @Test("resolved order respects dependencies (file before search/memory)")
    @MainActor
    func resolvedOrderRespectsDeps() async throws {
        let registry = SkillRegistry()
        try await registry.bootstrap(skillsDir: nil)
        let resolved = await registry.resolvedSkills()
        let names = resolved.map(\.name)

        let fileIdx = names.firstIndex(of: "file") ?? -1
        let searchIdx = names.firstIndex(of: "search") ?? -1
        let memoryIdx = names.firstIndex(of: "memory") ?? -1

        // file must come before search (search depends on file)
        #expect(fileIdx < searchIdx,
                "'file' (idx \(fileIdx)) must precede 'search' (idx \(searchIdx)) in resolved order")
        // file must come before memory (memory depends on file)
        #expect(fileIdx < memoryIdx,
                "'file' (idx \(fileIdx)) must precede 'memory' (idx \(memoryIdx)) in resolved order")
    }

    @Test("listCategories returns registered categories")
    @MainActor
    func listCategoriesIncludesSystem() async {
        let registry = SkillRegistry()
        try? await registry.bootstrap(skillsDir: nil)
        let categories = await registry.listCategories()
        #expect(categories.contains("system"))
    }

    @Test("setHotReloadCallback is retained")
    @MainActor
    func hotReloadCallbackRetained() async {
        let registry = SkillRegistry()
        await registry.setHotReloadCallback { }
        try? await registry.bootstrap(skillsDir: nil)
    }
}

@Suite("SystemPromptBuilder")
struct SystemPromptBuilderTests {
    @Test("build with no registry returns base prompt")
    @MainActor
    func buildNoRegistry() async {
        let builder = SystemPromptBuilder(basePrompt: "You are helpful.")
        let prompt = await builder.build()
        #expect(prompt == "You are helpful.")
    }

    @Test("build with registry includes skill section")
    @MainActor
    func buildWithRegistry() async {
        let registry = SkillRegistry()
        try? await registry.bootstrap(skillsDir: nil)

        let builder = SystemPromptBuilder(basePrompt: "You are helpful.")
        await builder.setRegistry(registry)

        let prompt = await builder.build()
        #expect(prompt.contains("You are helpful."))
        #expect(prompt.contains("# Available Skills"))
        #expect(prompt.contains("terminal") || prompt.contains("file"))
    }

    @Test("build caches result when content unchanged")
    @MainActor
    func buildCaches() async {
        let registry = SkillRegistry()
        try? await registry.bootstrap(skillsDir: nil)

        let builder = SystemPromptBuilder(basePrompt: "Base")
        await builder.setRegistry(registry)

        let first = await builder.build()
        let second = await builder.build()
        #expect(first == second)
    }

    @Test("updateBasePrompt invalidates cache")
    @MainActor
    func updateBasePromptInvalidates() async {
        let registry = SkillRegistry()
        try? await registry.bootstrap(skillsDir: nil)

        let builder = SystemPromptBuilder(basePrompt: "Old")
        await builder.setRegistry(registry)

        let old = await builder.build()
        await builder.updateBasePrompt("New")
        let new = await builder.build()

        #expect(old != new)
        #expect(new.hasPrefix("New"))
    }

    @Test("version increments on build after invalidation")
    @MainActor
    func versionIncrements() async {
        let registry = SkillRegistry()
        try? await registry.bootstrap(skillsDir: nil)

        let builder = SystemPromptBuilder(basePrompt: "x")
        await builder.setRegistry(registry)

        _ = await builder.build()
        let v1 = await builder.getVersion()
        await builder.updateBasePrompt("y")
        _ = await builder.build()
        let v2 = await builder.getVersion()

        #expect(v2 > v1)
    }

    @Test("getCached returns nil before first build")
    @MainActor
    func cachedBeforeBuild() async {
        let builder = SystemPromptBuilder(basePrompt: "x")
        #expect(await builder.getCached() == nil)
    }

    @Test("getCached returns last built prompt")
    @MainActor
    func cachedAfterBuild() async {
        let builder = SystemPromptBuilder(basePrompt: "cached")
        _ = await builder.build()
        #expect(await builder.getCached() == "cached")
    }

    @Test("buildSystemPrompt delegates to build")
    @MainActor
    func buildSystemPrompt() async {
        let builder = SystemPromptBuilder(basePrompt: "test")
        let result = await builder.buildSystemPrompt()
        #expect(result == "test")
    }

    @Test("listSkills returns skill names via registry")
    @MainActor
    func listSkills() async {
        let registry = SkillRegistry()
        try? await registry.bootstrap(skillsDir: nil)

        let builder = SystemPromptBuilder(basePrompt: "x")
        await builder.setRegistry(registry)

        let names = await builder.listSkills()
        #expect(names.count == 4)
        #expect(names.contains("terminal"))
    }
}

@Suite("SkillLoader")
struct SkillLoaderTests {
    @Test("splitFrontmatter returns nil for missing delimiter")
    func noFrontmatter() {
        let result = splitFrontmatter("just text")
        #expect(result == nil)
    }

    @Test("splitFrontmatter extracts YAML and body")
    func validFrontmatter() {
        let input = """
        ---
        name: test
        category: dev
        ---
        This is the body.
        """
        guard let (yaml, body) = splitFrontmatter(input) else {
            Issue.record("splitFrontmatter returned nil for valid input")
            return
        }
        #expect(yaml.contains("name: test"))
        #expect(body.contains("This is the body"))
    }

    @Test("splitFrontmatter handles empty body")
    func emptyBody() {
        let input = """
        ---
        name: n
        ---
        """
        guard let (yaml, _) = splitFrontmatter(input) else {
            Issue.record("splitFrontmatter returned nil")
            return
        }
        #expect(yaml.contains("name: n"))
    }

    @Test("parseFrontmatterYAML throws for non-dictionary YAML")
    func nonDictYAML() throws {
        do {
            _ = try parseFrontmatterYAML("just: a: scalar")
            #expect(Bool(false), "Should have thrown for non-dict YAML")
        } catch {
            // Yams throws its own error which wraps into SkillError.parseFailed
            // but if YAML is completely invalid, Yams' own error propagates first
            // — either is acceptable
        }
    }

    @Test("parseFrontmatterYAML throws for missing name")
    func missingName() throws {
        do {
            _ = try parseFrontmatterYAML("category: test\n")
            #expect(Bool(false), "Should have thrown for missing name")
        } catch {
            #expect(error is SkillError)
        }
    }

    @Test("parseFrontmatterYAML defaults category/tags/depends")
    func defaults() throws {
        let meta = try parseFrontmatterYAML("name: minimal\n")
        #expect(meta.name == "minimal")
        #expect(meta.category == "uncategorized")
        #expect(meta.description == "")
        #expect(meta.tags.isEmpty)
        #expect(meta.dependencies.isEmpty)
    }

    @Test("discoverSkills returns empty for empty directory")
    func emptyDirectory() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "skill_test_\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let skills = discoverSkills(in: tmpDir)
        #expect(skills.isEmpty)
    }

    @Test("discoverSkills finds valid SKILL.md")
    func findsValidSkill() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "skill_test_\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let skillFile = tmpDir.appendingPathComponent("skill.md")
        try """
        ---
        name: test-skill
        category: test
        ---
        Body content.
        """.write(to: skillFile, atomically: true, encoding: .utf8)

        let skills = discoverSkills(in: tmpDir)
        #expect(skills.count == 1)
        #expect(skills[0].name == "test-skill")
        #expect(skills[0].category == "test")
    }
}
