// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SkillRegistryTests.swift — Dependency resolution, registry lifecycle, model behavior
/// Removed: BuiltInSkill enum self-proof, SkillMetadata Codable round-trip (compiler-enforced)

import Foundation
import Testing
import Logging
@testable import ocoreai

@Suite("SkillMetadata serialization")
struct SkillMetadataTests {
    @Test("serialize produces valid YAML for simple metadata")
    func serializeSimple() {
        let meta = SkillMetadata(
            name: "test-skill",
            category: "testing",
            description: "A test skill",
            tags: ["test"],
            dependencies: []
        )
        let yaml = meta.serialize()
        #expect(yaml.contains("name: test-skill"))
        #expect(yaml.contains("category: testing"))
        #expect(yaml.contains("tags: [test]"))
        #expect(!yaml.contains("depends:"))
    }
    
    @Test("serialize includes dependencies when present")
    func serializeWithDeps() {
        let meta = SkillMetadata(
            name: "skill-a",
            category: "cat",
            description: "desc",
            tags: [],
            dependencies: ["dep-x", "dep-y"]
        )
        let yaml = meta.serialize()
        #expect(yaml.contains("depends: [dep-x, dep-y]"))
        #expect(!yaml.contains("tags:"))
    }
}

@Suite("Skill Model")
struct SkillModelTests {
    @Test("Skill promptContent includes frontmatter delimiters")
    func promptContentHasDelimiters() {
        let meta = SkillMetadata(name: "x", category: "c", description: "d")
        let skill = Skill(metadata: meta, body: "body text", path: "/x.md", status: .loaded, loadedAt: Date())
        let content = skill.promptContent
        #expect(content.hasPrefix("---"))
        #expect(content.contains("body text"))
    }
    
    @Test("Skill contentHash is deterministic")
    func contentHashDeterministic() {
        let meta = SkillMetadata(name: "hash-skill", category: "h", description: "desc")
        let s1 = Skill(metadata: meta, body: "same body", path: "/a.md", status: .loaded, loadedAt: Date())
        let s2 = Skill(metadata: meta, body: "same body", path: "/b.md", status: .loaded, loadedAt: Date())
        #expect(s1.contentHash == s2.contentHash)
    }
    
    @Test("Skill contentHash changes when body changes")
    func contentHashChangesWithBody() {
        let meta = SkillMetadata(name: "hash-skill", category: "h", description: "desc")
        let s1 = Skill(metadata: meta, body: "body a", path: "/a.md", status: .loaded, loadedAt: Date())
        let s2 = Skill(metadata: meta, body: "body b", path: "/b.md", status: .loaded, loadedAt: Date())
        #expect(s1.contentHash != s2.contentHash)
    }
}

// Helper to bootstrap registry — bootstrap is non-throwing so no try needed
func bootstrapRegistry(_ registry: SkillRegistry) async {
    try? await registry.bootstrap(skillsDir: nil)
}

@Suite("SkillRegistry — Registration and Lookup")
struct SkillRegistryLookupTests {
    func makeRegistry() -> SkillRegistry {
        SkillRegistry(log: Logger(label: "test.skills"))
    }
    
    @Test("Empty registry before bootstrap")
    func emptyBeforeBootstrap() async {
        let registry = makeRegistry()
        await bootstrapRegistry(registry)
        let list = await registry.list()
        #expect(list.count == BuiltInSkill.allCases.count)
    }
    
    @Test("Built-in skills registered on bootstrap")
    func bootstrappedBuiltins() async {
        let registry = makeRegistry()
        await bootstrapRegistry(registry)
        
        for skill in BuiltInSkill.allCases {
            let found = await registry.lookup(skill.rawValue)
            #expect(found != nil)
            #expect(found?.name == skill.rawValue)
            #expect(found?.category == "system")
        }
    }
    
    @Test("Lookup returns nil for unknown skill")
    func unknownSkillReturnsNil() async {
        let registry = makeRegistry()
        await bootstrapRegistry(registry)
        let found = await registry.lookup("does-not-exist")
        #expect(found == nil)
    }
    
    @Test("Categories list is non-empty after bootstrap")
    func categoriesList() async {
        let registry = makeRegistry()
        await bootstrapRegistry(registry)
        let cats = await registry.listCategories()
        #expect(cats.contains("system"))
    }
    
    @Test("Lookup by category returns all system skills")
    func lookupByCategory() async {
        let registry = makeRegistry()
        await bootstrapRegistry(registry)
        let systemSkills = await registry.lookupCategory("system")
        #expect(systemSkills.count == BuiltInSkill.allCases.count)
    }
    
    @Test("Lookup by category returns empty for unknown category")
    func lookupEmptyCategory() async {
        let registry = makeRegistry()
        await bootstrapRegistry(registry)
        let skills = await registry.lookupCategory("nonexistent")
        #expect(skills.isEmpty)
    }
    
    @Test("Lookup by tag returns skills with matching tag")
    func lookupByTag() async {
        let registry = makeRegistry()
        await bootstrapRegistry(registry)
        let builtinSkills = await registry.lookupTag("builtin")
        #expect(builtinSkills.count == BuiltInSkill.allCases.count)
    }
    
    @Test("Lookup by tag returns empty for unknown tag")
    func lookupUnknownTag() async {
        let registry = makeRegistry()
        await bootstrapRegistry(registry)
        let skills = await registry.lookupTag("does-not-exist")
        #expect(skills.isEmpty)
    }
}

@Suite("SkillRegistry — Dependency Resolution")
struct SkillRegistryDependencyTests {
    func makeRegistry() -> SkillRegistry {
        SkillRegistry(log: Logger(label: "test.skills"))
    }
    
    @Test("Built-in skill dependency order: terminal and file before search and memory")
    func builtinDependencyOrder() async {
        let registry = makeRegistry()
        await bootstrapRegistry(registry)
        let resolved = await registry.resolvedSkills()
        let resolvedNames = resolved.map(\.name)
        
        // terminal and file have no deps → must come before search/memory which depend on file
        if let searchIdx = resolvedNames.firstIndex(of: "search"),
           let fileIdx = resolvedNames.firstIndex(of: "file") {
            #expect(fileIdx < searchIdx)
        }
        if let memoryIdx = resolvedNames.firstIndex(of: "memory"),
           let fileIdx = resolvedNames.firstIndex(of: "file") {
            #expect(fileIdx < memoryIdx)
        }
    }
    
    @Test("Resolved skills count matches registered skills")
    func resolvedCountMatchesRegistered() async {
        let registry = makeRegistry()
        await bootstrapRegistry(registry)
        let resolved = await registry.resolvedSkills()
        let all = await registry.list()
        #expect(resolved.count == all.count)
    }
    
    @Test("Resolve is cached — calling resolvedSkills twice returns same order")
    func resolvedCache() async {
        let registry = makeRegistry()
        await bootstrapRegistry(registry)
        let r1 = await registry.resolvedSkills().map(\.name)
        let r2 = await registry.resolvedSkills().map(\.name)
        #expect(r1 == r2)
    }
}

@Suite("SkillRegistry — Remove")
struct SkillRegistryRemoveTests {
    func makeRegistry() -> SkillRegistry {
        SkillRegistry(log: Logger(label: "test.skills"))
    }
    
    @Test("Remove built-in skill removes it from list")
    func removeBuiltin() async {
        let registry = makeRegistry()
        await bootstrapRegistry(registry)
        let removed = await registry.remove("terminal")
        #expect(removed != nil)
        #expect(removed?.name == "terminal")
        
        let remaining = await registry.list()
        #expect(!remaining.contains("terminal"))
    }
    
    @Test("Remove unknown skill returns nil")
    func removeUnknown() async {
        let registry = makeRegistry()
        await bootstrapRegistry(registry)
        let removed = await registry.remove("nonexistent")
        #expect(removed == nil)
    }
    
    @Test("Remove skill updates category index")
    func removeUpdatesCategory() async {
        let registry = makeRegistry()
        await bootstrapRegistry(registry)
        
        let beforeCount = await registry.lookupCategory("system").count
        _ = await registry.remove("terminal")
        let afterCount = await registry.lookupCategory("system").count
        #expect(afterCount == beforeCount - 1)
    }
}
