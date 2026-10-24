// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// README pair parity — `README.md` and `README.zh.md` are one document in two languages, so
/// everything language-neutral in them must be identical: the skeleton a reader navigates, the
/// link targets that make a claim checkable, and the `OCOREAI_*` names a reader can set.
///
/// Measured before this suite: the Chinese README carried no `curl … /health` example, no
/// References line (eight links absent: Apple docs ×2, vLLM, vLLM-Metal, SGLang, omlx,
/// OpenClaw, Hermes Agent) and no `%2F` caveat — so a reader of one language could not
/// reach a single source behind the upstream claims, and could not check the one wire-shape
/// sharp edge this project documents. DeepSeek's harness keeps `.i18n.yaml` beside every doc
/// for this reason (`~/references/deepseek-harness/README.i18n.yaml`), and goose gates the
/// same drift for GUI strings (`ui/desktop/scripts/i18n-check.js`), whose extraction idea
/// `LocaleResolutionTests` already applies to this app's own chrome.
///
/// Every scan floors its own premises: a regex that stopped matching must fail, not pass.

import Foundation
import Testing

@testable import ocoreai

private func readmeRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while root.path != "/",
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
    {
        root.deleteLastPathComponent()
    }
    #expect(root.path != "/", "repo root not found from \(#filePath)")
    return root
}

private struct ReadmeSkeleton {
    let name: String
    let headings: Int
    let fences: Int
    let tableRows: Int
    let images: Int
    let urls: Set<String>
    let envKeys: Set<String>
}

private func matches(_ pattern: String, _ text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else {
        return []
    }
    let range = NSRange(text.startIndex ..< text.endIndex, in: text)
    return re.matches(in: text, range: range).compactMap { match in
        Range(match.range, in: text).map { String(text[$0]) }
    }
}

private func skeleton(_ root: URL, _ name: String) throws -> ReadmeSkeleton {
    let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    let lines = text.components(separatedBy: "\n")
    return ReadmeSkeleton(
        name: name,
        headings: lines.filter { $0.hasPrefix("### ") }.count,
        fences: text.components(separatedBy: "```").count / 2,
        tableRows: lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }.count,
        images: matches("!\\[", text).count,
        urls: Set(matches("https?://[^\\s)\\]>\"']+", text)),
        envKeys: Set(matches("OCOREAI_[A-Z0-9_]+", text)))
}

@Suite("README pair — one skeleton, one set of links, both languages")
struct ReadmePairParityTests {

    /// Both files exist and are big enough that "zero matches" cannot be mistaken for parity.
    @Test(arguments: ["README.md", "README.zh.md"])
    func bothReadmesAreThereToBeScanned(name: String) throws {
        let text = try String(
            contentsOf: readmeRoot().appendingPathComponent(name), encoding: .utf8)
        #expect(text.utf8.count > 5_000, "\(name) looks truncated — the parity below is vacuous")
    }

    /// The navigation skeleton: heading count, code blocks, table rows, images.
    @Test func skeletonIsIdentical() throws {
        let root = readmeRoot()
        let en = try skeleton(root, "README.md")
        let zh = try skeleton(root, "README.zh.md")
        #expect(en.headings >= 10, "heading scan found \(en.headings) — regex or file rotted")
        #expect(en.tableRows >= 50, "row scan found \(en.tableRows) — parity would be vacuous")
        #expect(en.images >= 3, "image scan found \(en.images) — screenshots stopped matching")
        #expect(en.fences >= 3, "fence scan found \(en.fences) — code blocks stopped matching")
        #expect(zh.headings == en.headings, "zh headings \(zh.headings), en \(en.headings)")
        #expect(zh.fences == en.fences, "zh code blocks \(zh.fences), en \(en.fences)")
        #expect(zh.tableRows == en.tableRows, "zh table rows \(zh.tableRows), en \(en.tableRows)")
        #expect(zh.images == en.images, "zh images \(zh.images), en \(en.images)")
    }

    /// Links are how a claim stays checkable; a reader of either language must reach the same
    /// sources. Set equality both ways, so neither side may gain a reference the other lacks.
    @Test func urlSetsAreIdentical() throws {
        let root = readmeRoot()
        let en = try skeleton(root, "README.md")
        let zh = try skeleton(root, "README.zh.md")
        #expect(en.urls.count >= 20, "url scan found \(en.urls.count) — pattern rotted")
        #expect(zh.urls.count >= 20, "url scan found \(zh.urls.count) — pattern rotted")
        let onlyEnLinks = en.urls.subtracting(zh.urls)
        let onlyZhLinks = zh.urls.subtracting(en.urls)
        #expect(onlyEnLinks.isEmpty, "linked only in README.md: \(onlyEnLinks.sorted())")
        #expect(onlyZhLinks.isEmpty, "linked only in README.zh.md: \(onlyZhLinks.sorted())")
    }

    /// `OCOREAI_*` is a config surface, not prose: both languages must name the same knobs.
    @Test func envKeySetsAreIdentical() throws {
        let root = readmeRoot()
        let en = try skeleton(root, "README.md")
        let zh = try skeleton(root, "README.zh.md")
        #expect(en.envKeys.count >= 3, "env scan found \(en.envKeys.count) — pattern rotted")
        let onlyEnKeys = en.envKeys.subtracting(zh.envKeys)
        let onlyZhKeys = zh.envKeys.subtracting(en.envKeys)
        #expect(onlyEnKeys.isEmpty, "documented only in English: \(onlyEnKeys.sorted())")
        #expect(onlyZhKeys.isEmpty, "documented only in Chinese: \(onlyZhKeys.sorted())")
    }

    /// A documented sharp edge is a warning the reader needs in the language they read: the
    /// percent-encoded model id (`org%2Fname`) is named on both sides or the caveat is missing
    /// for half the audience.
    @Test func percentEncodingCaveatIsOnBothSides() throws {
        let root = readmeRoot()
        let en = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let zh = try String(
            contentsOf: root.appendingPathComponent("README.zh.md"), encoding: .utf8)
        #expect(en.contains("%2F"), "README.md no longer names the %2F requirement")
        #expect(zh.contains("%2F"), "README.zh.md omits the %2F requirement README.md documents")
    }
}
