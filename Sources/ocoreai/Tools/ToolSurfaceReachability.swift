// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ToolSurfaceReachability.swift. The reachable half of the tool surface: a deferred tool is not
/// declared, its name and description are, and a `tool_search` hit becomes declared on the next turn.
///
/// The shape is the field's, read at the shipped sites 11-24 (not invented here): goose hands a small
/// model `name + description and no parameter schema` (`oi-kit-local-inference/…/tool_parsing.rs:4`,
/// `tool_emulation.rs:61-71`) and pi keeps `deferred` tools undeclared behind a BM25 `tool_search`
/// that loads matches into the active set (`packages/coding-agent/src/extensions/tool-search/tool.ts:1-21`).
/// The economics this prices (measured 11-24 against a live `GET /v1/tools`): all 40 declarations are
/// 23 997 B; the measured 6-tool arm is 4 302 B; the deferred 34 as name+description cost 9 060 B.
/// So a reachable turn is resident-cheap and pays one search call for a schema it actually needs.
///
/// Pure functions only — no registry, no engine, no settings — so the ranking is assertable to the
/// score, and the byte claim is re-greppable from the doc above. The flag and the per-session
/// discovered set live at the seams that own them, not here.
import Foundation

enum ToolSurfaceReachability {
    /// The one tool a reachable turn declares besides the core. Registered only while the flag is on,
    /// so an off build's surface is byte-identical to today's.
    static let searchToolName = "tool_search"
    /// pi's `DEFAULT_TOOL_SEARCH_LIMIT`; same reason — a bigger list re-buys the bytes this saves.
    static let defaultLimit = 8

    struct Match: Equatable, Sendable {
        let name: String
        let score: Double
    }

    // MARK: Searchable text

    /// The text a deferred tool is found by: its name, its description, and the schema's property
    /// names and descriptions. Same document pi ranks (`tool.ts:24-30`) — the parameter names are
    /// often the only words that say what the tool touches (`generate_video`'s `prompt`, `aspect_ratio`).
    static func searchableText(_ def: ToolDef) -> String {
        var parts = [def.function.name]
        if let description = def.function.description, !description.isEmpty {
            parts.append(description)
        }
        if let parameters = def.function.parameters,
            let data = try? JSONEncoder().encode(parameters),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let properties = object["properties"] as? [String: Any]
        {
            for key in properties.keys.sorted() {
                parts.append(key.replacingOccurrences(of: "_", with: " "))
                if let field = properties[key] as? [String: Any],
                    let fieldDescription = field["description"] as? String
                {
                    parts.append(fieldDescription)
                }
            }
        }
        return parts.joined(separator: " ")
    }

    /// Lowercased word tokens, splitting snake_case and camelCase. No stemmer: with ≤40 documents a
    /// stemmer buys recall the stop list already covers, and it costs the reader a lookup per word.
    static func tokens(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var previousJoined = false
        for character in text {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty {
                    pieces.append(current)
                    current = ""
                }
                previousJoined = false
                continue
            }
            if character.isUppercase && previousJoined && !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current.append(character.lowercased())
            previousJoined = character.isLowercase || character.isNumber
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.filter { $0.count > 1 && !stopWords.contains($0) }
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is", "it", "of",
        "on", "or", "that", "the", "this", "to", "with", "you", "your",
    ]

    // MARK: Ranking

    /// Okapi BM25 (k1 1.2, b 0.75) over the deferred documents, newest-idf first and ties broken by
    /// name ascending so the same query returns the same list every run (byte-determinism is a
    /// standing gate here, not a nicety).
    static func rank(
        query: String, in defs: [ToolDef], excluding declared: Set<String> = [],
        limit: Int = defaultLimit
    ) -> [Match] {
        let documents = defs.filter { !declared.contains($0.function.name) }
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty, !documents.isEmpty else { return [] }
        let tokenized = documents.map { tokens(searchableText($0)) }
        let counts = tokenized.map { doc -> [String: Int] in
            var map: [String: Int] = [:]
            for token in doc { map[token, default: 0] += 1 }
            return map
        }
        let lengths = tokenized.map(\.count)
        let average = Double(lengths.reduce(0, +)) / Double(lengths.count)
        let k1 = 1.2
        let b = 0.75
        var scores = [Double](repeating: 0, count: documents.count)
        // Deduplicate in first-occurrence order, never via `Set` iteration: Dictionary and Set
        // carry per-instance hash salt, so a Set's order can differ between two builds of the
        // same elements in one process — and token order moves the last bits of the Double
        // sum, which is exactly the byte-determinism this rank promises.
        var seenTokens = Set<String>()
        for token in queryTokens where seenTokens.insert(token).inserted {
            let withToken = counts.filter { $0[token] != nil }.count
            guard withToken > 0 else { continue }
            let idf = log(
                1 + (Double(documents.count) - Double(withToken) + 0.5) / (Double(withToken) + 0.5))
            for index in counts.indices {
                guard let frequency = counts[index][token] else { continue }
                let tf = Double(frequency) * (k1 + 1)
                let norm =
                    tf
                    / (Double(frequency) + k1
                        * (1 - b + b * Double(lengths[index]) / max(average, 1)))
                scores[index] += idf * norm
            }
        }
        var matches: [Match] = []
        for (index, score) in scores.enumerated() where score > 0 {
            matches.append(Match(name: documents[index].function.name, score: score))
        }
        matches.sort { $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name }
        return Array(matches.prefix(limit))
    }

    // MARK: Composition

    /// The core arm's full definitions plus every discovered name, in registry order. A discovered
    /// name the registry no longer has is absent, never a dangling declaration.
    static func residentSurface(
        all defs: [ToolDef], core: Set<String>, discovered: Set<String>
    ) -> [ToolDef] {
        defs.filter { core.contains($0.function.name) || discovered.contains($0.function.name) }
    }

    /// What a deferred tool stays on the prompt: `name: description`, one per line, registry order,
    /// core and discovered names excluded. The line is the whole cost of reachability (measured
    /// 9 060 B for the 34 deferred tools, against 19 695 B for the same tools' schemas).
    static func compactListing(
        all defs: [ToolDef], core: Set<String>, discovered: Set<String>
    ) -> String {
        defs.filter {
            !core.contains($0.function.name) && !discovered.contains($0.function.name)
        }
        .map { def in
            let description = (def.function.description ?? "").replacingOccurrences(
                of: "\n", with: " ")
            return "- \(def.function.name): \(description)"
        }
        .joined(separator: "\n")
    }
}
