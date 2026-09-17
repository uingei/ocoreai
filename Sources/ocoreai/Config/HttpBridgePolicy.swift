// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// HttpBridgePolicy.swift — 桥路（HTTP server）启动策略
///
/// 纯函数决策，单一事实源。`OcoreaiEngine.start()` 消费它；因纯函数
/// 不带 `#if appStore`，在任意 trait 下都可被测试钉住（trait 分支
/// 只决定传入 `appStoreCompiled: true` 与否，逻辑本身可全量覆盖）。
///
/// 语义：
///   • 非 appStore（开发构建）：桥路恒启用（HTTP 是开发/桥接交付面）。
///   • appStore（App Store 交付）：默认关闭（审核合规）。仅当显式
///     `OCOREAI_ENABLE_HTTP`=1/true 时开启——显式 opt-in，绝不因
///     未设默认值而意外启动（fail-safe）。

enum HttpBridgePolicy {
    /// 运行时覆盖开关名（文档承诺的 env var，`App.swift` start() 文档面）。
    static let envVar = "OCOREAI_ENABLE_HTTP"

    /// 决定桥路是否启动。
    /// - Parameters:
    ///   - appStoreCompiled: 编译期 trait 面（`#if appStore` 下传 `true`）。
    ///   - enableEnv: 运行时环境变量值（`OCOREAI_ENABLE_HTTP`，未设为 `nil`）。
    /// - Returns: `true` = 启动 HTTP 桥路。
    static func shouldStart(appStoreCompiled: Bool, enableEnv: String?) -> Bool {
        if !appStoreCompiled {
            // 开发构建：桥路恒启用（HTTP 是开发面，无需 env 开关）。
            return true
        }
        // appStore：默认关。显式 opt-in 才开——"1"/"true"（大小写不敏感），
        // 其余值（"0"/"false"/任意串/nil）一律关，fail-safe。
        guard let v = enableEnv?.lowercased() else {
            return false
        }
        return v == "1" || v == "true"
    }
}
