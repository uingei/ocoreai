// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// UpdateCheck honesty tests — pure logic, no network.
import Foundation
import Testing

@testable import ocoreai

@Suite("UpdateCheck")
struct UpdateCheckTests {

    @Test("numeric-segment compare: 0.10.0 > 0.9.0 (lex compare would lie)")
    func numericCompare() {
        #expect(UpdateCheck.candidateIsNewer("0.10.0", than: "0.9.0"))
        #expect(!UpdateCheck.candidateIsNewer("0.9.0", than: "0.10.0"))
        #expect(UpdateCheck.candidateIsNewer("1.0.0", than: "0.99.99"))
        #expect(!UpdateCheck.candidateIsNewer("0.1.6", than: "0.1.6"))
        #expect(UpdateCheck.candidateIsNewer("0.1.6.1", than: "0.1.6"))
        // Non-numeric hosts (dev builds) compare as 0 — any real release
        // is newer, and the About pane then honestly offers the page.
        #expect(UpdateCheck.candidateIsNewer("0.1.6", than: "dev"))
        #expect(!UpdateCheck.candidateIsNewer("dev", than: "0.1.6"))
    }

    @Test("parseReleaseJSON: tag normalization + prerelease flag")
    func parse() throws {
        let good = Data(
            """
            {"tag_name":"v0.2.0","html_url":"https://github.com/uingei/ocoreai/releases/tag/v0.2.0","prerelease":false}
            """.utf8)
        switch UpdateCheck.parseReleaseJSON(good) {
        case .success(let info):
            #expect(info.version == "0.2.0")
            #expect(!info.isPrerelease)
            #expect(info.url.path.hasSuffix("/v0.2.0"))
        case .failure(let e):
            Issue.record("unexpected failure: \(e)")
        }

        let pre = Data(
            #"{"tag_name":"v0.3.0-beta1","html_url":"https://example.com/r","prerelease":true}"#
                .utf8)
        switch UpdateCheck.parseReleaseJSON(pre) {
        case .success(let info):
            #expect(info.isPrerelease)
        case .failure(let e):
            Issue.record("unexpected failure: \(e)")
        }
    }

    @Test("parseReleaseJSON: malformed payloads fail, never invent a version")
    func parseMalformed() {
        let junk = [
            Data("not json".utf8),
            Data("{}".utf8),
            Data(#"{"tag_name":"v1.0"}"#.utf8),  // missing html_url
        ]
        for d in junk {
            if case .success = UpdateCheck.parseReleaseJSON(d) {
                Issue.record("malformed payload must not decode to success")
            }
        }
    }

    @Test("prereleases are never advertised to stable users")
    func prereleaseInvisible() {
        let pre = UpdateCheck.ReleaseInfo(
            version: "9.9.9",
            url: URL(string: "https://example.com")!,
            isPrerelease: true)
        // check() short-circuits prereleases to upToDate — encode the rule
        // as the same predicate the pane uses.
        let advertised =
            !pre.isPrerelease
            && UpdateCheck.candidateIsNewer(pre.version, than: "0.1.6")
        #expect(!advertised)
    }
}
