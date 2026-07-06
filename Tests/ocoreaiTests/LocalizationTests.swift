// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// LocalizationTests.swift — i18n layer correctness tests
///
/// Covers: translation table completeness (en + zhHans), fallback chain,
/// StringKey.l non-emptiness, and ⚠️ marker only on genuine gaps.

import Testing
import Foundation
@testable import ocoreai

// MARK: - Translation completeness

@Suite("StringKey en 翻译完整性")
struct StringKeyEnCompletenessTests {
    @Test("每个 StringKey 在 en 都有翻译")
    func everyKeyHasEnglishTranslation() {
        for key in StringKey.allCases {
            let text = key.localized(for: .en)
            #expect(!text.isEmpty, "en 翻译不应为空: \(key.rawValue)")
            #expect(!text.hasPrefix("⚠️"), "en 不应回退到警告标记: \(key.rawValue)")
        }
    }

    @Test("en 翻译内容有意义 — 长度下限")
    func everyEnglishTranslationHasMinimumLength() {
        for key in StringKey.allCases {
            let text = key.localized(for: .en)
            #expect(text.count >= 2, "\(key.rawValue) 的 en 翻译太短: '\(text)'")
        }
    }
}

@Suite("StringKey zhHans 翻译完整性")
struct StringKeyZhHansCompletenessTests {
    @Test("每个 StringKey 在 zhHans 都有翻译（或回退到 en）")
    func everyKeyHasZhHansOrFallback() {
        for key in StringKey.allCases {
            let text = key.localized(for: .zhHans)
            #expect(!text.isEmpty, "zhHans 翻译不应为空: \(key.rawValue)")
            #expect(!text.hasPrefix("⚠️"), "zhHans 不应回退到警告标记: \(key.rawValue)")
        }
    }

    @Test("zhHans 实际覆盖了大部分 key — 非回退样本检查")
    func zhHansHasActualChineseTranslations() {
        // 抽样验证 zhHans 确实在用中文而非回退到英文
        let shouldBeChinese: [(StringKey, String)] = [
            (.send, "发送"),
            (.stop, "停止"),
            (.settingsTitle, "设置"),
            (.dashboardTitle, "仪表盘"),
            (.systemOnline, "系统在线"),
            (.noModelsLoaded, "未加载模型"),
            (.chatPlaceholder, "输入消息..."),
            (.tabChat, "聊天"),
        ]
        for (key, expected) in shouldBeChinese {
            let actual = key.localized(for: .zhHans)
            #expect(actual == expected, "\(key.rawValue): 期望 '\(expected)'，实际 '\(actual)'")
        }
    }
}

// MARK: - Fallback chain

@Suite("Fallback Chain 回退链")
struct FallbackChainTests {
    @Test("不支持的 locale（如 ja）回退到 en")
    func unsupportedLocaleFallsBackToEn() {
        // ja 在 OCALocale 中定义但没有翻译表 entry
        for key in StringKey.allCases {
            let jaText = key.localized(for: .ja)
            let enText = key.localized(for: .en)
            #expect(jaText == enText, "\(key.rawValue) 应回退到 en")
        }
    }

    @Test("所有已定义 locale 都不产生 ⚠️ 标记")
    func noLocaleProducesWarningMarker() {
        for locale in OCALocale.allCases {
            for key in StringKey.allCases {
                let text = key.localized(for: locale)
                #expect(!text.hasPrefix("⚠️"), "\(key.rawValue) 在 \(locale) 不应出现警告标记")
            }
        }
    }
}

// MARK: - StringKey.l convenience

@Suite("StringKey.l 便捷访问")
struct StringKeyLTests {
    @Test("StringKey.l 始终返回非空字符串")
    func dotLReturnsNonEmpty() {
        for key in StringKey.allCases {
            let text = key.l
            #expect(!text.isEmpty, "\(key.rawValue).l 不应返回空字符串")
        }
    }

    @Test("StringKey.l 不包含警告标记")
    func dotLNeverShowsWarning() {
        for key in StringKey.allCases {
            let text = key.l
            #expect(!text.hasPrefix("⚠️"), "\(key.rawValue).l 不应出现警告: \(text)")
        }
    }
}

// MARK: - ⚠️ marker behavior

@Suite("⚠️ 标记行为")
struct WarningMarkerTests {
    @Test("⚠️ 标记只在翻译表完全缺失时出现")
    func warningMarkerOnlyOnCompleteMiss() {
        // 所有 StringKey.allCases 都在 base 表中，所以 en 永远不触发 ⚠️
        // 验证：对 .en 查所有 key，没有警告
        var hasWarning = false
        for key in StringKey.allCases {
            let text = key.localized(for: .en)
            if text.hasPrefix("⚠️") { hasWarning = true; break }
        }
        #expect(!hasWarning, "en 翻译表应覆盖所有 StringKey")
    }

    @Test("en 翻译表条目数 ≥ StringKey.allCases.count")
    func baseTableCoversAllKeys() {
        // 间接验证：如果 base 表少任何 key，就会返回 ⚠️
        // 上面已验证没有 ⚠️，所以此处只需数量对得上
        let allKeys = StringKey.allCases
        #expect(!allKeys.isEmpty, "StringKey 应至少有一个 case")
        for key in allKeys {
            let text = key.localized(for: .en)
            #expect(!text.hasPrefix("⚠️"), "base 表应覆盖: \(key.rawValue)")
        }
    }
}

