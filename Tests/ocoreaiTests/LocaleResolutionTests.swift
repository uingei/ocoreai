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
