// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SkillModels.swift — Skill data types for the skill system
///
/// Represents a SKILL.md file: YAML frontmatter metadata + markdown body content.
/// Supports dependency tracking and built-in skill enumeration.

import Foundation

/// Skill loading status — tracks lifecycle of each registered skill.
enum SkillStatus: String, Codable {
	case loaded
	case failed
	case hotReloadPending
}

/// Skill-specific errors covering parse issues, dependency cycles, and filesystem failures.
enum SkillError: Error {
	case parseFailed(name: String, detail: String)
	case dependencyNotFound(name: String, missing: [String])
	case circularDependency(cycle: [String])
	case fileReadError(path: String, detail: String)
	case duplicateRegistration(name: String)
	case invalidFrontmatter(path: String)
}

/// Built-in skills shipped with ocoreai — always available regardless of disk skills.
enum BuiltInSkill: String, CaseIterable {
	case terminal
	case file
	case search
	case memory
}

extension BuiltInSkill {
	var displayCategory: String {
		switch self {
		case .terminal: "system"
		case .file: "system"
		case .search: "system"
		case .memory: "system"
		}
	}

	var description: String {
		switch self {
		case .terminal: "Shell command execution and process management"
		case .file: "File read/write/search operations"
		case .search: "Web and file content search"
		case .memory: "Session memory and persistent storage"
		}
	}

	var dependencies: [BuiltInSkill] {
		switch self {
		case .terminal: []
		case .file: []
		case .search: [.file]
		case .memory: [.file]
		}
	}
}

/// YAML frontmatter parsed from SKILL.md header.
struct SkillMetadata: Codable {
	let name: String
	let category: String
	let description: String
	let tags: [String]
	let dependencies: [String]

	enum CodingKeys: String, CodingKey {
		case name
		case category
		case description
		case tags
		case dependencies = "depends"
	}

	init(name: String, category: String, description: String, tags: [String] = [], dependencies: [String] = []) {
		self.name = name
		self.category = category
		self.description = description
		self.tags = tags
		self.dependencies = dependencies
	}
}

/// A skill loaded from a SKILL.md file — metadata + markdown body content.
struct Skill {
	let metadata: SkillMetadata
	let body: String
	let path: String
	var status: SkillStatus
	let loadedAt: Date

	var name: String {
		metadata.name
	}

	var category: String {
		metadata.category
	}

	var description: String {
		metadata.description
	}

	var dependencyNames: [String] {
		metadata.dependencies
	}

	/// Full skill content for injection into system prompt
	var promptContent: String {
		"---\n" + metadata.serialize() + "---\n\n" + body
	}

	/// Hash for change detection — covers metadata + body
	var contentHash: String {
		let combined = name + category + body
		var hasher = Hasher()
		hasher.combine(combined)
		return String(hasher.finalize())
	}
}

extension SkillMetadata {
	/// Serialize SkillMetadata back to YAML for frontmatter.
	func serialize() -> String {
		var lines: [String] = [
			"name: \(name)",
			"category: \(category)",
			"description: \(description)",
		]
		if !tags.isEmpty {
			lines.append("tags: [\(tags.joined(separator: ", "))]")
		}
		if !dependencies.isEmpty {
			lines.append("depends: [\(dependencies.joined(separator: ", "))]")
		}
		return lines.joined(separator: "\n")
	}
}
