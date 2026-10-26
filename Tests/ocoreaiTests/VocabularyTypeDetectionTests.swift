// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Vocabulary-encoding inference — the mechanism coreai-models #359 landed upstream, ported to
/// `Sources/ocoreai/Engine/GuidedGeneration/TokenizerInfo.swift`.
///
/// Before this, every grammar entry point defaulted to `.byteLevel`. SentencePiece
/// byte-fallback vocabularies (Gemma, Llama) encode a space as `▁` and carry all 256 `<0xHH>`
/// byte tokens; told they are byte-level, xgrammar maps token ids to the wrong strings and a
/// valid document such as `{"name": "Alice", "age": 7}` is rejected at its fourth token. Both
/// production callers (`CoreAIPipelinedEngine`, `ConstrainedDecodingStrategy`) take the
/// tokenizer initializer and stated no type, so they inherited the constant.
///
/// The enum deliberately lives outside the CoreAI gate, which is what lets these assertions run
/// on a macOS 26 host at all; the last test pins that split so a re-gate goes red.

import Foundation
import Testing

@testable import ocoreai

/// `<0xHH>` byte tokens over a byte range, in either case spelling.
private func byteTokens(_ range: Range<Int>, uppercase: Bool = true) -> [String] {
    range.map {
        uppercase ? String(format: "<0x%02X>", $0) : String(format: "<0x%02x>", $0)
    }
}

/// One vocabulary shape and the encoding its grammar must be compiled with.
private struct VocabCase: Sendable {
    let name: String
    let vocabulary: [String]
    let expected: VocabularyType
}

private let vocabCases: [VocabCase] = [
    VocabCase(
        name: "all 256 byte tokens", vocabulary: byteTokens(0 ..< 256), expected: .byteFallback
    ),
    VocabCase(name: "255 byte tokens", vocabulary: byteTokens(0 ..< 255), expected: .byteLevel),
    VocabCase(
        name: "no byte tokens (byte-level BPE)",
        vocabulary: ["<unk>", "Ġthe", "ā"],
        expected: .byteLevel
    ),
    VocabCase(name: "empty vocabulary", vocabulary: [], expected: .byteLevel),
    VocabCase(
        name: "gemma-like: byte tokens plus SentencePiece pieces",
        vocabulary: ["<pad>", "<s>"] + byteTokens(0 ..< 256) + ["▁the", "▁", "name", "\"", ":"],
        expected: .byteFallback
    ),
    VocabCase(
        name: "mixed-case byte tokens still reach 256 distinct bytes",
        vocabulary: byteTokens(0 ..< 128, uppercase: true)
            + byteTokens(128 ..< 256, uppercase: false)
            + ["<pad>", "▁the"],
        expected: .byteFallback
    ),
]

private func repoRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while root.path != "/",
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
    {
        root.deleteLastPathComponent()
    }
    #expect(root.path != "/", "repo root not found from \(#filePath)")
    return root
}

private func readSource(_ relative: String) throws -> String {
    try String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8)
}

private func count(_ needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

@Suite("VocabularyType detection — coreai-models #359")
struct VocabularyTypeDetectionTests {

    @Test("detection by vocabulary shape", arguments: vocabCases)
    fileprivate func detectByShape(_ testCase: VocabCase) {
        #expect(
            VocabularyType.detect(vocabulary: testCase.vocabulary) == testCase.expected,
            "\(testCase.name)"
        )
    }

    @Test("an all-uppercase and an all-lowercase byte vocabulary agree")
    func caseInsensitiveAgreement() {
        #expect(
            VocabularyType.detect(vocabulary: byteTokens(0 ..< 256, uppercase: true))
                == VocabularyType.detect(vocabulary: byteTokens(0 ..< 256, uppercase: false)),
            "the same 256 bytes must not read as two encodings"
        )
    }

    @Test("hex-shaped tokens of the wrong width are not counted as byte tokens")
    func hexShapeIsStrictlySixBytes() {
        let tooLong = (0 ..< 256).map { String(format: "<0x%04X>", $0) }
        let tooShort = (0 ..< 256).map { String(format: "0x%02X", $0) }
        #expect(VocabularyType.detect(vocabulary: tooLong) == .byteLevel)
        #expect(VocabularyType.detect(vocabulary: tooShort) == .byteLevel)
    }

    @Test("no entry point hardcodes an encoding default")
    func noHardcodedDefaultRemains() throws {
        let tokenizerInfo = try readSource(
            "Sources/ocoreai/Engine/GuidedGeneration/TokenizerInfo.swift")
        let session = try readSource(
            "Sources/ocoreai/Engine/GuidedGeneration/ConstrainedGenerationSession.swift")
        #expect(
            count("vocabType: VocabularyType = .", in: tokenizerInfo) == 0,
            "TokenizerInfo still defaults an encoding by constant"
        )
        #expect(
            count("vocabType: VocabularyType = .", in: session) == 0,
            "ConstrainedGenerationSession still defaults an encoding by constant"
        )
        // Its own premise: the scan must still see the resolution points whose absence it claims.
        #expect(
            count("VocabularyType.detect(", in: tokenizerInfo) >= 2,
            "the inference call sites vanished — this scan would pass vacuously"
        )
    }

    @Test("a tokenizer property is not gated on a backend axis")
    func vocabularyTypeLivesOutsideTheCoreAIGate() throws {
        let text = try readSource("Sources/ocoreai/Engine/GuidedGeneration/TokenizerInfo.swift")
        let lines = text.components(separatedBy: "\n")
        guard let enumLine = lines.firstIndex(where: { $0.contains("enum VocabularyType") }),
            let gateLine = lines.firstIndex(where: { $0.contains("#if canImport(CoreAI)") })
        else {
            Issue.record("the vocabulary enum or the CoreAI gate is gone from TokenizerInfo.swift")
            return
        }
        #expect(enumLine < gateLine, "VocabularyType sits inside the CoreAI gate again")
        #expect(
            !lines[enumLine].contains("@available"), "a pure enum must not carry a macOS 27 gate")
    }
}
