// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelGallerySyncTests.swift — the committed gallery is two copies of one GET, or a placeholder.
///
/// README's gallery block and `models.json` are both renders of one `GET /v1/models`
/// (`scripts/gen-model-gallery.sh`); a published table that rots is the surface claiming more
/// than the engine delivered (AGENTS.md invariant 2). This suite is the gate the README names:
/// the two committed copies agree cell-for-cell, every verdict word is one the wire can
/// actually publish (the vocabularies are bound to the ledger sources, not retyped), and before
/// the first measured refresh the README carries the placeholder verbatim and `models.json` is
/// absent. The comparator is exercised against synthetic drift so the green run is not vacuous.
import Foundation
import Testing

@testable import ocoreai

@Suite("The measured gallery's two committed copies never drift")
struct ModelGallerySyncTests {
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/ocoreaiTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    private static let startMarker = "<!-- gallery:start"
    private static let endMarker = "<!-- gallery:end -->"
    private static let tableHeader =
        "| model | vlm | context | tool calls | reasoning_effort | video |"
    private static let tableSeparator = "|---|---|---|---|---|---|"
    /// The README's committed state before any measured refresh; the placeholder is the contract
    /// `gen-model-gallery.sh` replaces, so it is pinned verbatim.
    static let placeholder =
        "No measured rows committed yet — run the command above against a measured server."

    private struct GalleryModel: Decodable {
        let id: String
        var contextLength: Int?
        var vlm: Bool?
        var toolCallDelivery: String?
        var reasoningEffort: String?
        var videoInput: String?
    }

    private struct GalleryFile: Decodable {
        let schema: String
        let generatedAt: String
        let source: String
        let models: [GalleryModel]
    }

    private enum State {
        case placeholder
        case measured(blocked: [String], json: GalleryFile)
    }

    private static func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private static func readmeLines() throws -> [String] {
        try read(repoRoot.appendingPathComponent("README.md"))
            .components(separatedBy: "\n")
    }

    /// The lines strictly between the marker comment lines. Throws when the pair is missing or
    /// inverted — the script refuses to write a README without them, so a broken pair is a red.
    private static func blockInterior(_ lines: [String]) throws -> [String] {
        guard let start = lines.firstIndex(where: { $0.contains(startMarker) }),
            let end = lines.firstIndex(where: { $0.contains(endMarker) }),
            start < end
        else {
            throw GalleryGateError("README gallery marker pair missing or inverted")
        }
        return Array(lines[(start + 1) ..< end])
    }

    private struct GalleryGateError: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    private static func committedState() throws -> State {
        let interior = try blockInterior(readmeLines())
        let galleryURL = repoRoot.appendingPathComponent("models.json")
        let jsonExists = FileManager.default.fileExists(atPath: galleryURL.path)
        guard interior.contains(tableHeader) else {
            #expect(!jsonExists, "models.json exists but the README block carries no table header")
            #expect(
                interior == [placeholder],
                "pre-refresh README block must be the placeholder verbatim, got \(interior)")
            return .placeholder
        }
        #expect(jsonExists, "the README block carries table rows but models.json is absent")
        let data = try Data(contentsOf: galleryURL)
        let file = try JSONDecoder().decode(GalleryFile.self, from: data)
        #expect(file.schema == "ocoreai-gallery/1", "unexpected gallery schema: \(file.schema)")
        #expect(file.source == "GET /v1/models", "unexpected gallery source: \(file.source)")
        #expect(
            !file.models.isEmpty,
            "models.json with zero rows — the script refuses this, so a written one was hand-edited"
        )
        let headerIndex = interior.firstIndex(of: tableHeader)!
        #expect(
            interior[headerIndex + 1] == tableSeparator,
            "gallery header must be followed by \(tableSeparator)")
        let rows = Array(interior[(headerIndex + 2)...])
        return .measured(blocked: rows, json: file)
    }

    /// The script's cell projection (`str(v)`, absent `→ —`), reimplemented here deliberately:
    /// the offline gate prices the committed pair's agreement; re-running the script against a
    /// live server is the probe tier's job.
    private static func cell(_ value: (some Equatable)?) -> String {
        guard let value else { return "—" }
        if let bool = value as? Bool { return bool ? "True" : "False" }
        return String(describing: value)
    }

    private static func expectedRow(for model: GalleryModel) -> String {
        "| `\(model.id)` | \(cell(model.vlm)) | \(cell(model.contextLength)) | "
            + "\(cell(model.toolCallDelivery)) | \(cell(model.reasoningEffort)) | \(cell(model.videoInput)) |"
    }

    /// The drift report the main test asserts empty; kept as a function so the witness below
    /// can prove it reports synthetic drift instead of always returning nothing.
    private static func driftReport(rows: [String], models: [GalleryModel]) -> [String] {
        var report: [String] = []
        let expected = models.map(expectedRow(for:))
        if rows.count != expected.count {
            report.append("row count \(rows.count) != models.json count \(expected.count)")
        }
        for (index, row) in rows.enumerated() {
            guard index < expected.count else {
                report.append("README row \(index) has no models.json twin: \(row)")
                continue
            }
            if row != expected[index] {
                report.append(
                    "row \(index) drifted:\n  README: \(row)\n  json:   \(expected[index])")
            }
        }
        return report
    }

    @Test("README and the refresh script agree on the gallery marker and header contract")
    func markerContractSharedWithScript() throws {
        let script = try Self.read(
            Self.repoRoot.appendingPathComponent("scripts/gen-model-gallery.sh"))
        #expect(
            script.contains(Self.startMarker), "the script no longer writes \(Self.startMarker)")
        #expect(script.contains(Self.endMarker), "the script no longer writes \(Self.endMarker)")
        #expect(script.contains(Self.tableHeader), "the script's header drifted from the gate's")
    }

    @Test("the committed pair is placeholder-or-consistent, never half")
    func committedPairAgrees() throws {
        switch try Self.committedState() {
        case .placeholder:
            break
        case .measured(let rows, let json):
            #expect(
                json.models.map(\.id) == json.models.map(\.id).sorted(),
                "models.json rows are not sorted by id")
            let report = Self.driftReport(rows: rows, models: json.models)
            #expect(report.isEmpty, "gallery drift:\n\(report.joined(separator: "\n"))")
        }
    }

    @Test("every published verdict word is one the wire's own ledgers can emit")
    func verdictsAreWireVocabulary() throws {
        guard case .measured(_, let json) = try Self.committedState() else { return }
        let toolCallWords = [
            ToolCallDeliveryLedger.statusParsed,
            ToolCallDeliveryLedger.statusProseOnly,
            ToolCallDeliveryLedger.statusNotObserved,
        ]
        let effortWords = ReasoningEffortMode.allCases.map(\.wireMode)
        let videoWords = [
            VideoDeliveryLedger.statusDelivered, VideoDeliveryLedger.statusNotObserved,
        ]
        for model in json.models {
            if let word = model.toolCallDelivery {
                #expect(
                    toolCallWords.contains(word),
                    "\(model.id): toolCallDelivery `\(word)` is not wire vocabulary")
            }
            if let word = model.reasoningEffort {
                #expect(
                    effortWords.contains(word),
                    "\(model.id): reasoningEffort `\(word)` is not wire vocabulary")
            }
            if let word = model.videoInput {
                #expect(
                    videoWords.contains(word),
                    "\(model.id): videoInput `\(word)` is not wire vocabulary")
            }
        }
    }

    @Test("models.json is only ever the script's projection, never a hand-edited shape")
    func topLevelKeysAreTheScripts() throws {
        let galleryURL = Self.repoRoot.appendingPathComponent("models.json")
        guard FileManager.default.fileExists(atPath: galleryURL.path) else { return }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: galleryURL))
        let top = try #require(object as? [String: Any])
        #expect(
            Set(top.keys) == ["schema", "generatedAt", "source", "models"],
            "unexpected top-level keys: \(Set(top.keys))")
        let rows = try #require(top["models"] as? [[String: Any]])
        // The script's own KEYS projection — a key outside it cannot come from a script run.
        let allowed: Set<String> = [
            "id", "contextLength", "vlm", "capabilities",
            "toolCallDelivery", "toolCallEvidence",
            "reasoningEffort", "videoInput", "videoEvidence",
        ]
        for row in rows {
            let extra = Set(row.keys).subtracting(allowed)
            #expect(
                extra.isEmpty,
                "row `\(row["id"] ?? "?")` carries keys the script never writes: \(extra)")
        }
    }

    @Test("the drift comparator itself goes red on synthetic drift")
    func gateIsNotVacuous() throws {
        let model = GalleryModel(
            id: "a/b", contextLength: 4096, vlm: true, toolCallDelivery: "parsed",
            reasoningEffort: "honored", videoInput: nil)
        let row = Self.expectedRow(for: model)
        // Same pair: no report. This also pins the exact row shape the script emits.
        #expect(Self.driftReport(rows: [row], models: [model]).isEmpty)
        #expect(
            row == "| `a/b` | True | 4096 | parsed | honored | — |",
            "row projection drifted: \(row)")
        // One absent cell in json while the README shows a word: report.
        let stripped = GalleryModel(
            id: "a/b", contextLength: 4096, vlm: true, toolCallDelivery: "parsed",
            reasoningEffort: nil, videoInput: nil)
        #expect(!Self.driftReport(rows: [row], models: [stripped]).isEmpty)
        // Extra README row with no twin: report.
        #expect(!Self.driftReport(rows: [row, row], models: [model]).isEmpty)
        // Missing README row: report.
        #expect(!Self.driftReport(rows: [], models: [model]).isEmpty)
    }
}
