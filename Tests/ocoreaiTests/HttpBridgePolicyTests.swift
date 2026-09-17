import Foundation
// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
import Testing

@testable import ocoreai

/// HttpBridgePolicy 决策面钉住 — 编译期 trait × 运行时 env 的全组合。
///
/// 纯函数，全量覆盖（非抽样）。精确布尔断言（`#expect(true/false)` 对应
/// 具体 env 形态），拒绝 "some combo enabled" 式弱断言。
@Suite("HttpBridgePolicy — bridge path start decision matrix")
struct HttpBridgePolicyTests {

    // MARK: 非 appStore（开发 / 桥接交付形态）— 恒启用，不受 env 门控

    @Test("dev build — HTTP on (nil env)")
    func devNil() {
        let on = HttpBridgePolicy.shouldStart(appStoreCompiled: false, enableEnv: nil)
        #expect(on)
    }

    @Test("dev build — HTTP on (env=0 — dev surface is not opt-in-gated)")
    func devEnvZero() {
        let on = HttpBridgePolicy.shouldStart(appStoreCompiled: false, enableEnv: "0")
        #expect(on)
    }

    @Test("dev build — HTTP on (env=true / TRUE — dev surface always on)")
    func devEnvTrue() {
        let low = HttpBridgePolicy.shouldStart(appStoreCompiled: false, enableEnv: "true")
        let up = HttpBridgePolicy.shouldStart(appStoreCompiled: false, enableEnv: "TRUE")
        #expect(low && up)
    }

    // MARK: appStore（App Store 交付形态）— 合规默认关，fail-safe

    @Test("App Store — HTTP OFF by default (nil env) — the compliance baseline")
    func appStoreNil() {
        #expect(!HttpBridgePolicy.shouldStart(appStoreCompiled: true, enableEnv: nil))
    }

    @Test("App Store — HTTP OFF for env=0/false/garbage/empty (no silent on)")
    func appStoreOffForms() {
        #expect(!HttpBridgePolicy.shouldStart(appStoreCompiled: true, enableEnv: "0"))
        #expect(!HttpBridgePolicy.shouldStart(appStoreCompiled: true, enableEnv: "false"))
        #expect(!HttpBridgePolicy.shouldStart(appStoreCompiled: true, enableEnv: "nope"))
        #expect(!HttpBridgePolicy.shouldStart(appStoreCompiled: true, enableEnv: ""))
    }

    @Test("App Store — HTTP ON only for env=1 / true / TRUE (explicit opt-in, case-insensitive)")
    func appStoreOptIn() {
        #expect(HttpBridgePolicy.shouldStart(appStoreCompiled: true, enableEnv: "1"))
        #expect(HttpBridgePolicy.shouldStart(appStoreCompiled: true, enableEnv: "true"))
        #expect(HttpBridgePolicy.shouldStart(appStoreCompiled: true, enableEnv: "TRUE"))
    }

    // MARK: env var 名称契约（与 App.swift start() 文档面一致 — 防"文档承诺不存在的开关"复发）

    @Test("env var name contract = OCOREAI_ENABLE_HTTP (no typo)")
    func envVarName() {
        #expect(HttpBridgePolicy.envVar == "OCOREAI_ENABLE_HTTP")
    }

    @Test("App.swift doc surface references the env name (doc <-> code contract)")
    func envVarInAppSwiftDoc() throws {
        // 历史债：`OCOREAI_ENABLE_HTTP` 曾只是 App.swift:211 一句文档、零实现。
        // 契约面：env 名必须真实出现在 OcoreaiEngine 启动路径源码里。
        // 测试与源码同仓 — 用源码相对路径（Tests/ → Sources/）解析，
        // 不硬编码开发者机绝对路径（CI runner 无 /Users/t）。
        let testDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appSwift =
            testDir
            .deletingLastPathComponent()  // Tests/ocoreaiTests → Tests
            .deletingLastPathComponent()  // → 仓根
            .appendingPathComponent("Sources/ocoreai/App.swift")
        let text = try String(contentsOf: appSwift, encoding: .utf8)
        #expect(
            text.contains(HttpBridgePolicy.envVar),
            "App.swift must reference \(HttpBridgePolicy.envVar) (doc <-> code contract)")
    }
}
