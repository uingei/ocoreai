// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// BuiltInTools — registers essential tools into ToolRegistry on boot.
///
/// Each tool corresponds to a real capability (info, skill lookup, audit query).
import Foundation

/// Parse a JSON argument string and extract a key as String.
private func parseArgKey(_ args: String, key: String) -> String? {
	guard let data = args.data(using: .utf8),
	      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
	else {
		return nil
	}
	return dict[key]
}

/// Bootstrap the tool registry with built-in tools.
///
/// - Parameters:
///   - registry: The tool registry to populate.
///   - skillRegistry: Optional skill registry for skill-related tools.
func bootstrapBuiltInTools(
	registry: ToolRegistry,
	skillRegistry: SkillRegistry? = nil,
) async {
	// ── info ────────────────────────────────────────────────────────────────
	try? await registry.register(ToolEntry(
		name: "info",
		toolset: "system",
		schema: ToolSchema(parameters: ["topic": .string]),
		handler: { args in
			let topic = parseArgKey(args, key: "topic") ?? "status"
			return switch topic {
			case "status": "ocoreai runtime v0.7.0 — healthy"
			case "version": "0.7.0"
			case "uptime": "uptime: \(ProcessInfo.processInfo.systemUptime)"
			default: "topic '\(topic)' not recognized"
			}
		},
	))

	// ── skills_list ────────────────────────────────────────────────────────
	if let sr = skillRegistry {
		try? await registry.register(ToolEntry(
			name: "skills_list",
			toolset: "skills",
			schema: ToolSchema(parameters: ["category": .string]),
			handler: { [sr] args in
				let category = parseArgKey(args, key: "category")
				let names: [String] = if let cat = category, !cat.isEmpty {
					await sr.lookupCategory(cat).map(\.name)
				} else {
					await sr.list()
				}
				if names.isEmpty {
					return "no skills found"
				}
				return names.joined(separator: ", ")
			},
		))
	}

	// ── skills_lookup ──────────────────────────────────────────────────────
	if let sr = skillRegistry {
		try? await registry.register(ToolEntry(
			name: "skills_lookup",
			toolset: "skills",
			schema: ToolSchema(parameters: ["name": .string]),
			handler: { [sr] args in
				let name = parseArgKey(args, key: "name") ?? ""
				guard !name.isEmpty else { return "error: name required" }
				guard let skill = await sr.lookup(name) else {
					return "skill '\(name)' not found"
				}
				return "\(skill.name)\n\(skill.description)\nCategory: \(skill.category)"
			},
		))
	}

	// ── echo ────────────────────────────────────────────────────────────────
	try? await registry.register(ToolEntry(
		name: "echo",
		toolset: "debug",
		schema: ToolSchema(parameters: ["message": .string]),
		handler: { args in
			parseArgKey(args, key: "message") ?? ""
		},
		isDestructive: false,
	))
}
