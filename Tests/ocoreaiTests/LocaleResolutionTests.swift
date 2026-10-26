// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Locale resolution tests — the HIG contract for the language picker:
///   1. The picker lists only locales with a complete translation table.
///   2. A persisted user choice actually drives rendered strings.
///   3. First run / never-changed follows the system locale.
///
/// The voice axis (STT recognition + TTS voice + tool reports) consumes the
/// SAME persisted choice — locked here, in this one sequential test, because
/// `settings.app.locale` is a shared single key: concurrent tests writing it
/// interleave. This is the single writer/reader of that key under test.
///
/// These lock the behaviour that was previously broken: the picker
/// advertised 6 languages, rendered via the system locale regardless of
/// the user's choice, and defaulted to a hardcoded `.en`.

import Foundation
import Testing

@testable import ocoreai

private let localeDefaultsKey = "settings.app.locale"

@Suite("Locale — every delivered table is complete")
struct LocaleTableCompletenessTests {
    /// The invariant that was previously broken and undetected: a `StringKey`
    /// case can be declared and used in the UI while silently absent from a
    /// delivered table — then `localized(for:)` falls back to the wrong
    /// language (or the raw key) silently: no red test, no user-visible error.
    /// Lock: each delivered table maps EXACTLY the full key set, no extras.
    @Test("en (base) table covers every StringKey exactly once, no orphans")
    func baseTableSpansAllKeys() {
        let all = Set(StringKey.allCases)
        #expect(!all.isEmpty, "StringKey must not be empty")
        let covered = Set(L10nTables.base.keys)
        #expect(
            all == covered,
            "en table drift — missing: \(all.subtracting(covered).sorted { $0.rawValue < $1.rawValue }), orphan: \(covered.subtracting(all).sorted { $0.rawValue < $1.rawValue })"
        )
    }

    @Test("zhHans table covers every StringKey exactly once, no orphans")
    func zhTableSpansAllKeys() {
        let all = Set(StringKey.allCases)
        let covered = Set(L10nTables.zh.keys)
        #expect(
            all == covered,
            "zh table drift — missing: \(all.subtracting(covered).sorted { $0.rawValue < $1.rawValue }), orphan: \(covered.subtracting(all).sorted { $0.rawValue < $1.rawValue })"
        )
    }

    /// A delivered translation must be non-blank text — an empty string
    /// renders as an invisible UI label, strictly worse than the raw key.
    @Test("no delivered table contains a blank value")
    func noBlankValues() {
        for (key, value) in L10nTables.base {
            #expect(
                !value.trimmingCharacters(in: .whitespaces).isEmpty,
                "blank en value: \(key.rawValue)")
        }
        for (key, value) in L10nTables.zh {
            #expect(
                !value.trimmingCharacters(in: .whitespaces).isEmpty,
                "blank zh value: \(key.rawValue)")
        }
    }

    /// Parity where it must hold: any key translated to non-English text in
    /// zh must differ from the en text (a "translation" identical to the
    /// original en string is a copy, not a localization). Keys that are
    /// legitimately identical in both scripts (units, brand names) are
    /// allowed — this only fails keys that LOOK localized but aren't.
    @Test("zh values that contain CJK differ from their en counterpart")
    func localizedStringsActuallyLocalize() {
        for (key, zhValue) in L10nTables.zh {
            let hasCJK = zhValue.unicodeScalars.contains {
                $0.value >= 0x4E00 && $0.value <= 0x9FFF
            }
            if hasCJK, let enValue = L10nTables.base[key], enValue == zhValue {
                #expect(false, "zh value identical to en: \(key.rawValue) = \(zhValue)")
            }
        }
    }

    /// A translation that takes a different number of `%@` arguments than the
    /// base string silently drops content: `String(format:)` ignores the extra
    /// argument, so the two languages deliver different text from one call site.
    /// Arity is read off the resolved values, so a literal split across several
    /// concatenated lines counts correctly (parsing one line at a time is how a
    /// scan starts matching again after a refactor and quietly stops).
    @Test("en and zh agree on format-specifier arity for every key")
    func formatSpecifierArityMatchesAcrossDeliveredTables() {
        var mismatches: [String] = []
        var parameterized = 0
        for (key, enValue) in L10nTables.base {
            guard let zhValue = L10nTables.zh[key] else { continue }
            let enCount = Self.specifierCount(enValue)
            let zhCount = Self.specifierCount(zhValue)
            if enCount > 0 { parameterized += 1 }
            if enCount != zhCount {
                mismatches.append("\(key.rawValue): en=\(enCount) zh=\(zhCount)")
            }
        }
        #expect(mismatches == [], "specifier arity drift: \(mismatches)")
        #expect(
            parameterized >= 20,
            "the scan lost its subject: only \(parameterized) parameterized keys")
    }

    /// Copy has one home (`StringKey`); a literal typed into the GUI is copy
    /// that no locale can reach. Measured before this gate existed: 7 sites
    /// (`ApprovalNotifier` banner + the five quick-load model cards).
    /// `Security/` and `Reasoning/` keep CJK on purpose — those are matcher
    /// vocabularies (263 literals), not strings a user reads.
    @Test("the GUI holds no copy outside the string table")
    func guiHasNoCopyOutsideTheStringTable() throws {
        let root = try Self.repoRoot()
        let ui = root.appendingPathComponent("Sources/ocoreai/UI")
        let files = try Self.swiftFiles(in: ui)
        #expect(files.count >= 40, "the GUI scan found only \(files.count) files")
        var leaks: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in Self.cjkLiteralLines(in: source) {
                leaks.append("\(file.lastPathComponent):\(line)")
            }
        }
        #expect(leaks == [], "hardcoded copy in the GUI: \(leaks)")

        // The same scanner must still find copy where copy legitimately lives,
        // or a broken scan would pass vacuously.
        let table = root.appendingPathComponent(
            "Sources/ocoreai/Localization/Localization.swift")
        let tableSource = try String(contentsOf: table, encoding: .utf8)
        #expect(
            Self.cjkLiteralLines(in: tableSource).count >= 400,
            "the CJK scanner stopped matching — it finds no copy in the table either")
    }

    /// The consumer side: quick-load cards carry a key, and both delivered
    /// tables answer it with the model's own parameters and size, so a card
    /// cannot render blank or lose its size figure in one language.
    @Test("every quick-load card resolves its description in both tables")
    @MainActor
    func quickLoadCardsResolveTheirKeys() {
        let models = ModelManager.recommendedModels
        #expect(models.count == 5, "recommended list changed shape: \(models.count)")
        for rec in models {
            let en = rec.descriptionKey.localized(for: .en)
            let zh = rec.descriptionKey.localized(for: .zhHans)
            #expect(en.contains("4-bit"), "\(rec.id): en description lost its quantization")
            #expect(zh.contains("4-bit"), "\(rec.id): zh description lost its quantization")
            #expect(
                en.contains("MB") || en.contains("GB"),
                "\(rec.id): en description lost its size")
            #expect(
                zh.contains("MB") || zh.contains("GB"),
                "\(rec.id): zh description lost its size")
            #expect(en != zh, "\(rec.id): zh is a copy of en")
        }
    }

    /// `ocoreaiText`/`ocoreaiMono`/`ocoreaiDisplay` map a raw size onto a TextStep so Dynamic Type
    /// scales (Theme.swift). A `.system(size:)` literal pins the pixel size for every user, which the
    /// HIG duty this file is about does not allow. Measured before this gate: 7 sites, 6 of them in
    /// the very view the UI guide cites as the honest-empty-state pattern.
    @Test("the GUI scales its text instead of pinning pixel sizes")
    func guiUsesTheScaledFontSeam() throws {
        let ui = try Self.repoRoot().appendingPathComponent("Sources/ocoreai/UI")
        var pinned: [String] = []
        var scaled = 0
        for file in try Self.swiftFiles(in: ui) {
            let source = try String(contentsOf: file, encoding: .utf8)
            let rows = source.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, row) in rows.enumerated() {
                let text = String(row)
                if text.contains(".font(.system(size:") {
                    pinned.append("\(file.lastPathComponent):\(index + 1)")
                }
                if text.contains(".ocoreaiText(") || text.contains(".ocoreaiMono(")
                    || text.contains(".ocoreaiDisplay(")
                {
                    scaled += 1
                }
            }
        }
        #expect(pinned == [], "pixel-pinned fonts, Dynamic Type dead: \(pinned)")
        #expect(scaled >= 150, "the scaled seam fell out of use: only \(scaled) sites")
    }

    // MARK: - Scan helpers

    /// Count `String(format:)` conversions, ignoring `%%` and honouring the
    /// positional form (`%1$@`), which this table uses for reordered text.
    private static func specifierCount(_ value: String) -> Int {
        let chars = Array(value)
        let flags: Set<Character> = ["-", "+", " ", "#", "0"]
        let conversions: Set<Character> = [
            "l", "d", "u", "f", "x", "X", "o", "O", "e", "E", "g", "G", "c", "C", "s", "S", "a",
            "@",
        ]
        var count = 0
        var index = 0
        while index < chars.count {
            guard chars[index] == "%" else {
                index += 1
                continue
            }
            if index + 1 < chars.count, chars[index + 1] == "%" {
                index += 2
                continue
            }
            var cursor = index + 1
            while cursor < chars.count, flags.contains(chars[cursor]) { cursor += 1 }
            while cursor < chars.count, chars[cursor].isNumber { cursor += 1 }
            if cursor < chars.count, chars[cursor] == "$" { cursor += 1 }
            if cursor < chars.count, chars[cursor] == "." {
                cursor += 1
                while cursor < chars.count, chars[cursor].isNumber { cursor += 1 }
            }
            if cursor < chars.count, conversions.contains(chars[cursor]) { count += 1 }
            index = cursor + 1
        }
        return count
    }

    /// Line numbers (1-based) holding a CJK character inside a string literal.
    /// Comment syntax is honoured outside strings, so `// 中文` and `/// 中文`
    /// never count, and `"https://…"` never truncates the scan.
    private static func cjkLiteralLines(in source: String) -> [Int] {
        var lines: [Int] = []
        var insideBlockComment = false
        let rows = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, row) in rows.enumerated() {
            let chars = Array(row)
            var inString = false
            var escaped = false
            var found = false
            var index = 0
            while index < chars.count {
                let char = chars[index]
                if insideBlockComment {
                    if char == "*", index + 1 < chars.count, chars[index + 1] == "/" {
                        insideBlockComment = false
                        index += 2
                        continue
                    }
                    index += 1
                    continue
                }
                if !inString {
                    if char == "/", index + 1 < chars.count, chars[index + 1] == "/" { break }
                    if char == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                        insideBlockComment = true
                        index += 2
                        continue
                    }
                    if char == "\"" {
                        inString = true
                        escaped = false
                    }
                    index += 1
                    continue
                }
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                } else if isCJK(char) {
                    found = true
                }
                index += 1
            }
            if found { lines.append(offset + 1) }
        }
        return lines
    }

    private static func isCJK(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        return (0x4E00 ... 0x9FFF).contains(scalar.value)
            || (0x3040 ... 0x30FF).contains(scalar.value)
            || (0xAC00 ... 0xD7AF).contains(scalar.value)
    }

    /// The repo root is found by searching, not by counting path hops.
    private static func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path)
            {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    private static func swiftFiles(in directory: URL) throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }
}

@Suite("Locale — picker only lists delivered locales")
struct LocaleAvailabilityTests {
    @Test("availableLocales is exactly en + zhHans (the two delivered tables)")
    func exactAvailableSet() {
        #expect(OCALocale.availableLocales.count == 2)
        #expect(OCALocale.availableLocales.contains(.en))
        #expect(OCALocale.availableLocales.contains(.zhHans))
        // The four not-yet-delivered locales must NOT be advertised.
        #expect(!OCALocale.availableLocales.contains(.ja))
        #expect(!OCALocale.availableLocales.contains(.ko))
        #expect(!OCALocale.availableLocales.contains(.fr))
        #expect(!OCALocale.availableLocales.contains(.es))
    }

    @Test("availableLocales has no duplicates and is en-first")
    func stableOrder() {
        #expect(OCALocale.availableLocales.first == .en)
        let counts = Dictionary(grouping: OCALocale.availableLocales, by: { $0 })
        #expect(counts.values.allSatisfy { $0.count == 1 })
    }

    /// The HIG full-table contract for the inference-meter / param-label keys:
    /// every key must resolve to a non-empty, locale-specific value in BOTH
    /// delivered locales (no silent fallback to the raw key, no drift).
    @Test("reasoning-effort label + reasoning/mtp meters resolve in en AND zhHans")
    func meterAndEffortKeysResolveInBothTables() {
        #expect(StringKey.reasoningEffortLabel.localized(for: .en) == "Reasoning Effort")
        #expect(StringKey.reasoningTokMeter.localized(for: .en) == "reasoning: %d tok")
        #expect(StringKey.mtpMeter.localized(for: .en) == "mtp: %d/%d")
        #expect(StringKey.reasoningEffortLabel.localized(for: .zhHans) == "推理强度")
        #expect(StringKey.reasoningTokMeter.localized(for: .zhHans) == "推理: %d tok")
        #expect(StringKey.mtpMeter.localized(for: .zhHans) == "mtp: %d/%d")
        // The format placeholders must survive localization so String(format:)
        // keeps working in both scripts.
        #expect(StringKey.reasoningTokMeter.localized(for: .en).contains("%d"))
        #expect(StringKey.reasoningTokMeter.localized(for: .zhHans).contains("%d"))
        #expect(StringKey.mtpMeter.localized(for: .en).contains("%d/%d"))
        #expect(StringKey.mtpMeter.localized(for: .zhHans).contains("%d/%d"))
    }

    /// VoiceOver label templates: the three previously-hardcoded English
    /// words (Channel / Code block / Load) were the last unlocalized a11y
    /// strings. Lock their exact resolution in BOTH tables.
    @Test("a11y channel / code-block / load labels resolve in en AND zhHans")
    func a11yLabelTemplatesResolveInBothTables() {
        #expect(StringKey.a11yComputeChannel.localized(for: .en) == "Channel")
        #expect(StringKey.a11yCodeBlock.localized(for: .en) == "Code block")
        #expect(StringKey.a11yLoadModel.localized(for: .en) == "Load")
        #expect(StringKey.a11yComputeChannel.localized(for: .zhHans) == "通道")
        #expect(StringKey.a11yCodeBlock.localized(for: .zhHans) == "代码块")
        #expect(StringKey.a11yLoadModel.localized(for: .zhHans) == "加载")
        // None may fall back to the raw key or be empty (silent-missing guard).
        for key in [StringKey.a11yComputeChannel, StringKey.a11yCodeBlock, StringKey.a11yLoadModel]
        {
            #expect(!key.localized(for: .en).isEmpty)
            #expect(!key.localized(for: .zhHans).isEmpty)
            #expect(key.localized(for: .en) != key.rawValue)
            #expect(key.localized(for: .zhHans) != key.rawValue)
        }
    }
}

@Suite("Locale — user choice is honored")
struct LocaleUserChoiceTests {
    private var defaults: UserDefaults { .standard }

    func cleanKey() {
        defaults.removeObject(forKey: localeDefaultsKey)
    }

    /// One sequentially-executed test (single task → no concurrent test can
    /// interleave on the shared `settings.app.locale` key). Walks the state
    /// machine zh → en → undelivered(ja) → cleared and asserts each step,
    /// including the voice-axis consumers of the same choice.
    @Test("StringKey.l + userSelected() + voice axis follow the persisted choice")
    func honorsChoiceSequentially() async {
        cleanKey()

        // 1. User picks zh → both the resolver and inline `.l` render zh.
        defaults.set(OCALocale.zhHans.rawValue, forKey: localeDefaultsKey)
        #expect(OCALocale.userSelected() == .zhHans)
        #expect(StringKey.systemOnline.l == "系统在线")
        // An explicit en request must still override the user's choice.
        #expect(StringKey.systemOnline.localized(for: .en) == "System Online")
        // Voice axis: STT recognition is script-accurate (zh-Hans, not the
        // bare "zh"), and the `speak` report carries the app's locale tag.
        #expect(TranscribeAudio.build(locale: nil, maxChars: nil).localeIdentifier == "zh-Hans")
        #expect(
            await SpeakClient.runForTool(text: "你好", backend: FakeTTS())
                == "speak OK — 2 chars enqueued (locale=zh-Hans)")

        // 2. User picks en → renders the base (en) table, voice axis follows.
        defaults.set(OCALocale.en.rawValue, forKey: localeDefaultsKey)
        #expect(OCALocale.userSelected() == .en)
        #expect(StringKey.systemOnline.l == "System Online")
        #expect(TranscribeAudio.build(locale: nil, maxChars: nil).localeIdentifier == "en")
        // TTS voice selection consumes the bare ISO code (the AVSpeech voice
        // ladder resolves "zh"/"en", never a script tag — probing confirmed
        // "zh-Hans" would match no voice and fall to any personal voice).
        #expect(OCALocale.zhHans.languageCode == "zh")
        #expect(OCALocale.en.languageCode == "en")

        // 3. Undelivered choice (ja) → not served (would be dead UI), fall back.
        defaults.set(OCALocale.ja.rawValue, forKey: localeDefaultsKey)
        #expect(OCALocale.userSelected() == OCALocale.systemLocale())

        // 4. Cleared → back to the system locale.
        defaults.removeObject(forKey: localeDefaultsKey)
        #expect(OCALocale.userSelected() == OCALocale.systemLocale())
    }
}
