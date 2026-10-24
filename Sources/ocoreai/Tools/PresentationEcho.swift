// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Presentation-echo guard — the text a write tool is about to land may be *our own* tool output,
/// copied instead of the content the caller meant.
///
/// ### Why
/// `read_file` answers with `N|` prefixes and a `─── total_lines: … ───` footer (and a perception
/// header used to ride the tail of every tool result). Measured on the task scoreboard
/// (`scripts/eval/`, `copy-with-suffix`): read-then-write turns produced the tool result they had
/// been shown — `1|KERNEL-7-COPY` plus the footer — with the requested transformation applied
/// *inside* the copy, and both calls reported `OK`. Over k=6 that shape scored 0/13 at baseline,
/// and adding a sentence to the footer telling the caller not to copy it made the artefact bigger,
/// not smaller: the sentence was copied too. A hint aimed at the model is not a fix; the seam that
/// can decide this one is the write.
///
/// ### Ladder (one home, bounded end)
/// detect → repair when the removal cannot be a mistake → report what was refused otherwise.
/// A family alone that is self-identifying (this repo's footer, this repo's channel header) or
/// corroborated (`N|` prefixes with chrome beside them) gets removed and said out loud. Anything
/// that would empty the payload is never "repaired" — that would destroy content on a guess, so it
/// lands and comes back `OK-but-invalid` instead.
///
/// ### False-positive floor
/// A pipe-delimited table whose rows start `1|`, `3|` is content, not a read dump, and a test that
/// quotes the label `"total_lines: 3 (full)"` is not this repo's footer: both need the box-drawing
/// run, or consecutive numbering, before anything is touched.
import Foundation

enum PresentationEcho: Sendable {

    /// One family of presentational artefacts produced by this repo's own read surface.
    enum Artifact: String, Sendable, CaseIterable {
        /// `1|…`, `2|…` — `read_file`'s line-number prefixes.
        case numberedLines = "N| line numbers"
        /// `─── total_lines: … ───` — `read_file`'s window footer.
        case readFooter = "total_lines footer"
        /// `[System Perception]` — the perception channel header.
        case perceptionHeader = "[System Perception] channel header"
    }

    /// Where a family was seen. The line is 1-based, counting the payload itself.
    struct Finding: Sendable, Equatable {
        let artifact: Artifact
        let line: Int
    }

    /// What the write side decided about one payload: what it removed, and what it could not.
    struct Repair: Sendable, Equatable {
        let text: String
        let removed: [Finding]
        /// Chrome that was left in place because removing it would empty the payload.
        let remaining: [Finding]

        var didRepair: Bool { !removed.isEmpty }
        /// True when chrome is still in the bytes the caller asked for.
        var isUnrepaired: Bool { !remaining.isEmpty }
    }

    /// Every artefact family present, in declaration order; empty means the payload is clean.
    static func findings(in text: String) -> [Finding] {
        let lines = text.components(separatedBy: "\n")
        var numbers: [(line: Int, value: Int)] = []
        var found: [Finding] = []
        for artifact in Artifact.allCases {
            guard let line = firstLine(of: artifact, in: lines) else { continue }
            found.append(Finding(artifact: artifact, line: line))
        }
        for (index, rawLine) in lines.enumerated() {
            if let value = leadingLineNumber(rawLine.drop { $0 == " " || $0 == "\t" }) {
                numbers.append((index + 1, value))
            }
        }
        // Numbering is judged against the chrome found beside it: a lone `1|` line is a
        // pipe-delimited row as often as not, but a `1|` line under this repo's footer is a dump.
        let corroborated = found.contains { $0.artifact != .numberedLines }
        if let first = numbers.first, Self.isNumberedDump(numbers, corroborated: corroborated) {
            found.insert(Finding(artifact: .numberedLines, line: first.line), at: 0)
        }
        return found
    }

    /// Strip the chrome the ladder can prove, and say what was stripped.
    static func repair(_ text: String) -> Repair {
        let found = findings(in: text)
        guard !found.isEmpty else { return Repair(text: text, removed: [], remaining: []) }

        let families = Set(found.map(\.artifact))
        let stripPrefixes = families.contains(.numberedLines)

        var removed: [Finding] = []
        var kept: [String] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let bare = line.drop { $0 == " " || $0 == "\t" }
            if isFooterLine(bare) {
                removed.append(Finding(artifact: .readFooter, line: index + 1))
                continue
            }
            if isHeaderLine(bare) {
                removed.append(Finding(artifact: .perceptionHeader, line: index + 1))
                continue
            }
            if stripPrefixes, let content = stripLineNumber(bare) {
                if !removed.contains(where: { $0.artifact == .numberedLines }) {
                    removed.append(Finding(artifact: .numberedLines, line: index + 1))
                }
                kept.append(content)
            } else {
                kept.append(line)
            }
        }

        let candidate = kept.joined(separator: "\n")
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Chrome was the whole payload: stripping it would leave an empty file, which is a
            // claim about the caller's intent, not a recovery. Land the bytes and say so.
            return Repair(text: text, removed: [], remaining: found)
        }
        return Repair(text: candidate, removed: removed, remaining: [])
    }

    /// `""` when nothing was found; otherwise the verdict clause with the mechanical fact.
    static func suffix(_ repair: Repair) -> String {
        if repair.isUnrepaired {
            return
                " | presentation-echo: \(names(repair.remaining)) — that is read_file's display and"
                + " it is the whole payload, so nothing was stripped. Rewrite with the file content"
                + " the task asked for."
        }
        guard repair.didRepair else { return "" }
        return
            " | presentation-echo repaired: stripped \(names(repair.removed)) — read_file's display,"
            + " not file content. The file now holds the text without it; write it again with the"
            + " chrome back only if it was really meant to be there."
    }

    private static func names(_ findings: [Finding]) -> String {
        findings.map { "\($0.artifact.rawValue) at line \($0.line)" }.joined(separator: ", ")
    }

    private static func firstLine(
        of artifact: Artifact, in lines: [String]
    ) -> Int? {
        for (index, line) in lines.enumerated() {
            let bare = line.drop { $0 == " " || $0 == "\t" }
            let hit: Bool
            switch artifact {
            case .readFooter: hit = isFooterLine(bare)
            case .perceptionHeader: hit = isHeaderLine(bare)
            case .numberedLines: hit = false  // needs the sequence, not one line
            }
            if hit { return index + 1 }
        }
        return nil
    }

    private static func isFooterLine(_ line: Substring) -> Bool {
        line.contains("total_lines:") && line.contains("───")
    }

    private static func isHeaderLine(_ line: Substring) -> Bool {
        line.hasPrefix("[System Perception]")
    }

    /// The integer in a leading `N|` prefix, or `nil` when the line has none.
    private static func leadingLineNumber(_ line: Substring) -> Int? {
        var digits = ""
        for character in line {
            if character.isNumber { digits.append(character) } else { break }
        }
        guard !digits.isEmpty, line.hasPrefix(digits + "|") else { return nil }
        return Int(digits)
    }

    /// The content after a `N|` prefix.
    private static func stripLineNumber(_ line: Substring) -> String? {
        leadingLineNumber(line) == nil ? nil : String(line.drop { $0 != "|" }.dropFirst())
    }

    /// Corroborated numbering needs only one line; uncorroborated numbering has to run strictly
    /// increasing by one, so a table with an integer column that skips a number stays content.
    private static func isNumberedDump(
        _ numbers: [(line: Int, value: Int)], corroborated: Bool
    ) -> Bool {
        if corroborated { return !numbers.isEmpty }
        guard numbers.count >= 2 else { return false }
        for index in 1 ..< numbers.count
        where numbers[index].value != numbers[index - 1].value + 1 {
            return false
        }
        return true
    }
}
