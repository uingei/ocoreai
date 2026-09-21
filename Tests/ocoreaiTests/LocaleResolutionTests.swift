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
