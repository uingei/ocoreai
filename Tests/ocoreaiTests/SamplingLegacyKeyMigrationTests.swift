import Foundation
// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SettingsStore 采样参数 **legacy-key 迁移** 回归。
///
/// 背景:GUI 早期版本按带来源前缀的 id 存采样参数
/// (`settings.model.params.mscope:org/name`),canonical 去重后统一读
/// bare key (`settings.model.params.org/name`)——老用户的自定义参数
/// 原本会静默丢失。`loadSamplingConfig` 现在回退到 legacy key 命中时
/// 自动 re-key 回 bare 并清旧 key。本测试精确锁定:
///   1) bare key 命中 → 直接读(不走回退)
///   2) 只有 legacy `mscope:` key → 读到 + **re-key 到 bare** + **legacy 被删**
///   3) 只有 legacy `hf:` key     → 同上
///   4) 都没有                   → `.default`
///   5) 读两次(迁移后)           → 第二次裸读 bare 仍是同一 config
import Testing

@testable import ocoreai

final class SamplingLegacyKeyMigrationTests {
    private let bareId = "mlx-community/Qwen3.5-4B-MLX-4bit"

    /// 每个用例用独立 suite,UserDefaults 隔离。
    @MainActor
    private func isolated() -> (SettingsStore, UserDefaults) {
        let name = "sampling.mig.\(UUID().uuidString)"
        let store = SettingsStore(defaults: UserDefaults(suiteName: name)!)
        return (store, UserDefaults(suiteName: name)!)
    }

    private func customConfig() -> ModelSamplingConfig {
        ModelSamplingConfig(temperature: 0.7, topK: 13)
    }

    private func key(_ id: String) -> String { "settings.model.params.\(id)" }

    @Test
    @MainActor
    func bareKeyHitReadsDirectly() async {
        let (store, defaults) = isolated()
        let cfg = customConfig()
        defaults.set(try! JSONEncoder().encode(cfg), forKey: key(bareId))
        let out = await store.loadSamplingConfig(for: bareId)
        #expect(out.topK == 13)
    }

    @Test
    @MainActor
    func legacyMscopeKeyReadsAndRekeys() async {
        let (store, defaults) = isolated()
        let cfg = customConfig()
        defaults.set(try! JSONEncoder().encode(cfg), forKey: key("mscope:" + bareId))
        let out = await store.loadSamplingConfig(for: bareId)
        #expect(out.topK == 13, "legacy mscope key 必须读到")
        // one-shot re-key: bare key 现在存在,legacy 被清除
        #expect(defaults.object(forKey: key(bareId)) != nil, "必须写入 bare key")
        #expect(defaults.object(forKey: key("mscope:" + bareId)) == nil, "legacy key 必须清除")
    }

    @Test
    @MainActor
    func rekeySurvivesSecondRead() async {
        let (store, _) = isolated()
        let cfg = customConfig()
        let defaults = UserDefaults(suiteName: "sampling.mig.second")!
        defaults.removePersistentDomain(forName: "sampling.mig.second")
        let s2 = SettingsStore(defaults: defaults)
        defaults.set(try! JSONEncoder().encode(cfg), forKey: key("hf:" + bareId))
        _ = await s2.loadSamplingConfig(for: bareId)  // 触发迁移
        let second = await s2.loadSamplingConfig(for: bareId)  // 第二次裸读
        #expect(second.topK == 13, "迁移后二次读必须仍命中")
    }

    @Test
    @MainActor
    func legacyHfKeyReadsAndRekeys() async {
        let (store, defaults) = isolated()
        let cfg = customConfig()
        defaults.set(try! JSONEncoder().encode(cfg), forKey: key("hf:" + bareId))
        let out = await store.loadSamplingConfig(for: bareId)
        #expect(out.topK == 13)
        #expect(defaults.object(forKey: key(bareId)) != nil)
        #expect(defaults.object(forKey: key("hf:" + bareId)) == nil)
    }

    @Test
    @MainActor
    func noKeysAnywhereReturnsDefault() async {
        let (store, _) = isolated()
        let out = await store.loadSamplingConfig(for: "mscope:nope/nope")
        #expect(out.isDefault)
    }
}
