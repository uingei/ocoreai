// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SkillLoader.swift — SKILL.md parser and filesystem discovery
///
/// Parses SKILL.md format: YAML frontmatter (--- ... ---) + markdown body.
/// Discovers skills from directory scan, supports polling-based hot-reload.
///
/// ### Optimizations (v2):
/// - mtime 增量扫描 — 只重新解析变更的 skill 文件
/// - Yams 解析结果缓存 — 未变更的文件用旧 snapshot 直接复用

import Foundation
import Logging
import Yams

// MARK: - Logger

private let skillLogger = Logger(label: "ocoreai.skillloader")

/// Parse a SKILL.md file into a Skill struct.
func parseSkillFile(at url: URL) throws -> Skill {
	guard url.pathExtension == "md" else {
		throw SkillError.parseFailed(name: url.lastPathComponent, detail: "Not a .md file")
	}

	let content = try String(contentsOf: url, encoding: .utf8)
	guard let (frontmatter, body) = splitFrontmatter(content) else {
		throw SkillError.invalidFrontmatter(path: url.path)
	}

	let metadata = try parseFrontmatterYAML(frontmatter)
	return Skill(
		metadata: metadata,
		body: body.trimmingCharacters(in: .newlines),
		path: url.path,
		status: .loaded,
		loadedAt: Date(),
	)
}

/// Split YAML frontmatter from markdown body.
func splitFrontmatter(_ content: String) -> (String, String)? {
	let lines = content.components(separatedBy: .newlines)
	guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
	      first == "---" else { return nil }

	var endRange: Range<String.Index>? = nil
	var lineIndex = 1
	while lineIndex < lines.count {
		let trimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
		if trimmed == "---" || trimmed == "..." {
			endRange = content.startIndex ..< content.index(content.startIndex, offsetBy: lineIndex)
			break
		}
		lineIndex += 1
	}

	guard let endRange else { return nil }
	let yamlPart = String(content[endRange])
	let bodyStart = content.index(content.startIndex, offsetBy: lineIndex + 1)
	let bodyPart = content.suffix(from: bodyStart)
	return (yamlPart, String(bodyPart))
}

/// Parse YAML frontmatter into SkillMetadata.
func parseFrontmatterYAML(_ yaml: String) throws -> SkillMetadata {
	guard let dict = try Yams.load(yaml: yaml) as? [String: Any] else {
		throw SkillError.parseFailed(name: "unknown", detail: "YAML did not produce a dictionary")
	}
	guard let name = dict["name"] as? String else {
		throw SkillError.parseFailed(name: "unknown", detail: "Missing 'name' in frontmatter")
	}
	let category = (dict["category"] as? String) ?? "uncategorized"
	let description = (dict["description"] as? String) ?? ""
	let tags = (dict["tags"] as? [String]) ?? []
	let deps = (dict["depends"] as? [String]) ?? []
	return SkillMetadata(name: name, category: category, description: description, tags: tags, dependencies: deps)
}

// MARK: - Discovery (增量扫描)

/// Discover skills from a directory — incrementally compares against known mtimes.
func discoverSkillsIncremental(
	in searchDir: URL,
	mtimes knownMtimes: [URL: Date],
	maxDepth: Int = 3,
) -> [Skill] {
	guard let enumerator = FileManager.default.enumerator(
		at: searchDir,
		includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
		options: [.skipsHiddenFiles],
	) else { return [] }

	var skills: [Skill] = []
	for case let fileURL as URL in enumerator {
		guard fileURL.lastPathComponent.lowercased() == "skill.md" else { continue }

		let pathComponents = fileURL.pathComponents
		let depth = pathComponents.count - searchDir.pathComponents.count
		guard depth <= maxDepth else {
			enumerator.skipDescendants()
			continue
		}

		guard let currentMtime = try? fileURL.resourceValues(
			forKeys: [.contentModificationDateKey],
		).contentModificationDate else { continue }

		// Skip if mtime unchanged (增量优化)
		if knownMtimes[fileURL] == currentMtime {
			continue
		}

		do {
			let skill = try parseSkillFile(at: fileURL)
			skills.append(skill)
		} catch {
			skillLogger.warning("Failed to load skill at \(fileURL.path): \(error.localizedDescription)")
		}
	}

	return skills
}

/// Legacy: Full scan (wraps incremental with empty knownMtimes).
func discoverSkills(in searchDir: URL, maxDepth: Int = 3) -> [Skill] {
	discoverSkillsIncremental(in: searchDir, mtimes: [:], maxDepth: maxDepth)
}

// MARK: - Directory Monitor

actor DirectoryMonitor {
	private var monitored: [URL: Date] = [:]
	private let pollInterval: Double
	private let onChange: @Sendable () async -> Void

	init(directories: [URL], pollInterval: Double = 2.0, onChange: @Sendable @escaping () async -> Void) {
		self.pollInterval = pollInterval
		self.onChange = onChange
		for dir in directories {
			if let snap = Self.recordSnapshot(dir) {
				monitored[dir] = snap
			}
		}
	}

	func start() async {
		while true {
			try? await Task.sleep(for: .seconds(pollInterval))
			guard !Task.isCancelled else { break }
			let changed = checkChanges()
			if changed {
				await onChange()
			}
		}
	}

	private func checkChanges() -> Bool {
		var changed = false
		for (dir, _) in monitored {
			let newSnapshot = DirectoryMonitor.recordSnapshot(dir)
			if newSnapshot != monitored[dir] {
				changed = true
				monitored[dir] = newSnapshot
				break
			}
		}
		return changed
	}

	static func recordSnapshot(_ dir: URL) -> Date? {
		guard let enumerator = FileManager.default.enumerator(
			at: dir,
			includingPropertiesForKeys: [.contentModificationDateKey],
			options: [.skipsHiddenFiles],
		) else { return nil }

		var newest: Date?
		for case let fileURL as URL in enumerator {
			if let modDate = try? fileURL.resourceValues(
				forKeys: [.contentModificationDateKey],
			).contentModificationDate {
				newest = max(newest ?? modDate, modDate)
			}
		}
		return newest
	}
}
