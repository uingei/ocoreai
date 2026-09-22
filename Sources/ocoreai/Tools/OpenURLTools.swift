// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Open URL — 「自主操作计算机」按 URL 路由到系统 handler app 的跨平台动作面。
///
/// 第一性: "深度适配 Apple 各平台 framework" + "iOS 17 深度适配" = agent 必须能
/// 通过 URL 触发 handler app:
///   http(s)→Safari/系统浏览器        mailto:→Mail         tel:→Phone/FaceTime
///   custom scheme→已注册 App        https://app.link/...→handler app (Universal Link)
/// 这是 iOS 上 agent → "外部 App" 的 **唯一主动通道**(无 NSWorkspace / CGEvent 面);
/// macOS 上与 `open_app`("按 App 名启动本地 GUI app")不同轴——open_url 是 "按 URL 路由"。
///
/// 跨平台 gate 判据(同 clipboard/system_info):
///   macOS 14  NSWorkspace.shared.open(url: URL) -> Bool     (非弃用, 10.15+)
///   iOS 17    UIApplication.shared.open(url: URL) async throws (非弃用, 10.0+, async 版 14+)
/// 双平台一等 → 跨平台注册(不 #if 到 macOS)。
///
/// 审批边界(安全原则: 拦边界不拦价值观):
///   open_url 启动外部 app + 跨进程副作用(网络/邮件/电话) → isDestructive: true
///   不判断 URL 内容类别(不拦"打开什么网站"), 只拦"副作用后果"这条边界。
///
/// Pure/Driver/Clients 三段分离(同 ClipboardTools)。零 as!/try!/fatalError。
import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Pure(双平台离线可测 — 不触 NSWorkspace/UIApplication 运行时)

enum OpenURL {
    enum ValidationError: Error, Equatable, Sendable {
        case empty
        case invalid(String)
        case missingScheme(String)
    }

    /// URL 验证: 非空 + 可 parse 为合法 URL + 有 scheme。纯, 精确可测。
    static func validate(_ raw: String) -> Result<URL, ValidationError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let url = URL(string: trimmed) else { return .failure(.invalid(trimmed)) }
        guard url.scheme != nil else { return .failure(.missingScheme(trimmed)) }
        return .success(url)
    }

    /// 纯 URL string（无 path/query 时）分类。用于测试 + driver 决策。
    static func urlCategory(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "http", "https": return "browser"
        case "mailto": return "email"
        case "tel", "sms": return "phone"
        case "itms-apps", "itms-services": return "ios-store"
        case "file": return "local-file"
        default: return "custom-scheme"
        }
    }

    /// 成功报告（含 category 让模型知道路由到了哪类 handler）。
    static func successReport(_ url: URL) -> String {
        let cat = urlCategory(url)
        let abs = url.absoluteString
        return "opened \(cat) URL: \(abs) (routed to system handler app)"
    }

    /// 失败报告（handler 拒绝 / 系统未找到 handler app）。
    static func failureReport(_ url: URL) -> String {
        "open FAILED — no system handler app for: \(url.absoluteString)"
    }
}

// MARK: - Driver(平台, 收口 MainActor)

enum OpenURLDriver {
    #if canImport(AppKit)
    /// macOS: NSWorkspace.shared.open(url) 同步 (非弃用, 10.15+)
    @MainActor static func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
    #elseif canImport(UIKit)
    /// iOS: UIApplication.shared.open(url) async throws (非弃用, 10.0+)
    @MainActor static func open(_ url: URL) async -> Bool {
        (try? await UIApplication.shared.open(url)) ?? false
    }
    #else
    @MainActor static func open(_ url: URL) -> Bool {
        false
    }
    #endif
}

// MARK: - Clients(双平台工具面)

enum OpenURLClient {
    static let toolName = "open_url"
    struct Args: Codable, Sendable { let url: String }

    static func toolEntry() -> ToolEntry {
        ToolEntry.typed(
            name: toolName,
            toolset: "computer",
            argsType: Args.self,
            description:
                "Open a URL via the system handler app (cross-platform). "
                + "Routes to the appropriate app based on URL scheme: "
                + "http(s)→browser, mailto:→Mail, tel:/sms:→Phone, custom scheme→registered handler. "
                + "On macOS: NSWorkspace.shared.open(url). On iOS: UIApplication.shared.open(url). "
                + "Changes system state (launches an external app), so it routes through the approval gate. "
                + "Use it to open links found in documents, web content, or user requests — "
                + "the only inter-app launch channel on iOS.",
            schema: ToolSchema(parameters: [
                "url": ToolParameter(
                    type: .string,
                    description:
                        "Full URL to open (must include scheme: https://, mailto:, tel:, etc.)"
                )
            ]),
            isDestructive: true
        ) { args in
            switch OpenURL.validate(args.url) {
            case .failure(.empty):
                return "open_url invalid: URL is empty"
            case .failure(.invalid(let raw)):
                return
                    "open_url invalid: cannot parse URL '\(raw)' — include a scheme (https://, mailto:, tel:, etc.)"
            case .failure(.missingScheme(let raw)):
                return
                    "open_url invalid: URL '\(raw)' has no scheme — add https:// or another valid scheme"
            case .success(let url):
                let ok = await OpenURLDriver.open(url)
                return ok ? OpenURL.successReport(url) : OpenURL.failureReport(url)
            }
        }
    }
}
