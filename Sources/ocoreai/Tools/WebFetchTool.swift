// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// WebFetchTool — 读取一个已知 URL 的渲染后内容,一等工具。
///
/// 与 `web_search` 的分工(两条正交轴,不混):
///   web_search — 不知道去哪个站点,拿到"答案文本"(后端=本地 ollama /v1/responses,不渲染)
///   web_fetch  — 已知具体 URL,拿到"页面渲染内容"(后端=WebKit WKWebView)。
///                JS 渲染站(如 developer.apple.com)纯 HTTP 拿不到真实 DOM,WebKit 能
///                (本机实证:CLI 进程 WKWebView 抓取该站,9277 字符标题/正文完整)。
/// 与 CDP 轴的分工:
///   codex `full_cdp_access`(browser_use.rs)是"驱动真实浏览器"(点击/登录态/复杂自动化),
///   WebKit 不支持 CDP,不进那条轴;web_fetch 只"读一个页面",不驱动、不批量,轻量本地读取。
///
/// 可测 seam(均可离线):
///   1. `WebFetchRequest.build`  — URL 规范化/拒绝(纯函数)
///   2. `WebFetchParser`         — 结果归一化/报告(纯函数)
///   3. `WebKitFetcher.fetch`    — WebKit 抓取(主线程 RunLoop pump,可用 data: URL 离线验证)
///
/// 后端配置(env,运行期可注入便于测试):
///   OCRE_FETCH_TIMEOUT — 默认 30 (秒,clamp 1...120)
///
/// 失败诚实:加载失败/超时/空页 → 返回 `error: ...` 文本(不造假、不吞),
/// 让模型自行降级(如改用 `exec_command curl` 或如实告知用户)。
import Foundation

#if canImport(AppKit)
import AppKit
#endif
#if canImport(WebKit)
import WebKit
#endif

// MARK: - DTO

/// web_fetch 抓取结果(纯数据,可测)。`error` 非 nil 表示抓取失败。
struct WebFetchResult: Sendable, Equatable {
    let title: String
    let body: String
    let error: String?
}

/// web_fetch 错误(诚实上报,不吞)。
enum WebFetchError: Error, LocalizedError, Equatable {
    case emptyURL
    case invalidURL(String)
    case unsupportedScheme(String)
    case missingHost
    case timeout(seconds: Int)
    case backendUnavailable(String)
    case loadFailed(reason: String)
    case emptyPage

    var errorDescription: String? {
        switch self {
        case .emptyURL: "url must be non-empty"
        case .invalidURL(let raw): "invalid url: \(raw)"
        case .unsupportedScheme(let scheme): "unsupported scheme: \(scheme) (仅支持 http/https)"
        case .missingHost: "url has no host"
        case .timeout(let seconds): "timed out after \(seconds)s"
        case .backendUnavailable(let reason): reason
        case .loadFailed(let reason): reason
        case .emptyPage: "页面加载完成但 body 为空(可能纯 canvas/iframe,或 JS 未渲染出内容)"
        }
    }
}

// MARK: - Request(纯函数,可测)

enum WebFetchRequest {
    struct Built: Sendable, Equatable {
        let urlString: String
        let timeoutSeconds: Int
    }

    /// 规范化/校验抓取目标。仅 http/https;timeout clamp 到 1...120 秒。
    static func build(urlString: String, timeoutSeconds: Int = 30) throws -> Built {
        let raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw WebFetchError.emptyURL }
        guard var c = URLComponents(string: raw), c.scheme != nil else {
            throw WebFetchError.invalidURL(raw)
        }
        guard let scheme = c.scheme?.lowercased(), !scheme.isEmpty else {
            throw WebFetchError.invalidURL(raw)
        }
        guard scheme == "http" || scheme == "https" else {
            throw WebFetchError.unsupportedScheme(scheme)
        }
        guard let host = c.host, !host.isEmpty else {
            throw WebFetchError.missingHost
        }
        // 规范化 scheme 为小写(URL scheme 大小写不敏感;统一输出便于缓存/去重/可测)
        c.scheme = scheme
        guard let canonical = c.url?.absoluteString else {
            throw WebFetchError.invalidURL(raw)
        }
        let timeout = max(1, min(timeoutSeconds, 120))
        return Built(urlString: canonical, timeoutSeconds: timeout)
    }
}

// MARK: - Parser(纯函数,可测)

enum WebFetchParser {
    /// 归一化标题/正文(两侧空白),失败原样保留(诚实,不吞)。
    static func normalize(
        title: String, body: String, failure: String?
    ) -> WebFetchResult {
        WebFetchResult(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            error: failure?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 面向 LLM 的紧凑多行报告(tool-result 消费用,风格对齐 web_search.report)。
    static func report(_ r: WebFetchResult, maxBodyChars: Int) -> String {
        if let error = r.error, !error.isEmpty {
            var lines: [String] = ["status: error", "reason: \(error)"]
            if !r.title.isEmpty { lines.append("title: \(r.title)") }
            if !r.body.isEmpty { lines.append("body_head:\n\(String(r.body.prefix(500)))") }
            return lines.joined(separator: "\n")
        }
        let bodyToUse =
            r.body.count > maxBodyChars
            ? String(r.body.prefix(maxBodyChars)) + "\n…(已截断: total \(r.body.count) chars)"
            : r.body
        let lines: [String] = [
            "status: ok",
            "title: \(r.title.isEmpty ? "(untitled)" : r.title)",
            "body_chars: \(r.body.count)",
            "--- BODY ---",
            bodyToUse,
        ]
        return lines.joined(separator: "\n")
    }
}

// MARK: - WebKit 抓取(主线程,可注入)

/// WebKit 抓取后端接口 — 便于测试替换(离线 fake)。
protocol WebFetchBackend: Sendable {
    func fetch(_ req: WebFetchRequest.Built) async -> WebFetchResult
}

#if canImport(WebKit)
/// WKWebView + 主线程 RunLoop 泵循环。
/// WebKit 的导航/JS 回调经主线程 RunLoop 投递,WKWebView 须在主线程创建,
/// 故把「创建 + 泵循环」整体放进 `MainActor.run`(非隔离 async 方法 → 主线程同步跑)。
/// 非 GUI 上下文(如 CLI 进程)实测同样可行;GUI app 主线程常转更稳。
final class WebKitBackend: WebFetchBackend {
    nonisolated func fetch(_ req: WebFetchRequest.Built) async -> WebFetchResult {
        await MainActor.run { () -> WebFetchResult in
            Self.performFetchOnMain(req)
        }
    }

    @MainActor
    static func performFetchOnMain(_ req: WebFetchRequest.Built) -> WebFetchResult {
        final class Delegate: NSObject, WKNavigationDelegate {
            var title = ""
            var body = ""
            var failure: String?
            var settled = false

            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                webView.evaluateJavaScript("document.title") { value, evalError in
                    if let s = value as? String { self.title = s }
                    if let e = evalError { self.failure = e.localizedDescription }
                    webView.evaluateJavaScript(
                        "document.body ? document.body.innerText : '(no body)'"
                    ) { value, evalError in
                        if let s = value as? String { self.body = s }
                        if let e = evalError {
                            self.failure =
                                (self.failure.map { $0 + "; " } ?? "") + e.localizedDescription
                        }
                        self.settled = true
                    }
                }
            }

            func webView(
                _ webView: WKWebView, didFail navigation: WKNavigation!,
                withError error: Error
            ) {
                self.failure = error.localizedDescription
                self.settled = true
            }

            func webView(
                _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                withError error: Error
            ) {
                self.failure = "navigation failed: \(error.localizedDescription)"
                self.settled = true
            }
        }

        let delegate = Delegate()
        let web = WKWebView(frame: .zero)
        web.navigationDelegate = delegate
        guard let url = URL(string: req.urlString) else {
            return WebFetchResult(title: "", body: "", error: "invalid URL")
        }
        web.load(URLRequest(url: url))

        let deadline = Date().addingTimeInterval(TimeInterval(req.timeoutSeconds))
        while !delegate.settled {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if Date() > deadline {
                return WebFetchParser.normalize(
                    title: delegate.title, body: delegate.body,
                    failure: WebFetchError.timeout(seconds: req.timeoutSeconds).errorDescription)
            }
        }
        return WebFetchParser.normalize(
            title: delegate.title, body: delegate.body, failure: delegate.failure)
    }
}
#endif

// MARK: - Client(async,env 注入可测)

enum WebFetchClient {
    static let defaultMaxBodyChars = 50_000

    /// 执行一次 web fetch。environment 注入(env 可测,不 monkeypatch ProcessInfo)。
    /// - Returns: 解析/归一化后的结果(失败时 `error` 字段非 nil,不吞)。
    /// - Throws: `WebFetchError`(请求校验/后端的同步失败)。
    static func fetch(
        urlString: String,
        timeoutSeconds: Int = 30,
        backend: (any WebFetchBackend)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) async throws -> WebFetchResult {
        let built = try WebFetchRequest.build(
            urlString: urlString,
            timeoutSeconds: Int(environment["OCRE_FETCH_TIMEOUT"] ?? "") ?? timeoutSeconds)

        let resolved: any WebFetchBackend
        if let backend {
            resolved = backend
        } else {
            #if canImport(WebKit)
            resolved = WebKitBackend()
            #else
            throw WebFetchError.backendUnavailable(
                "WebKit 不可用(需要 Apple 平台 SDK);可用 exec_command curl 代替")
            #endif
        }

        let result = await resolved.fetch(built)
        // 空页归一为 emptyPage 错误(诚实,不静默返回空串)
        if result.error == nil && result.body.isEmpty {
            return WebFetchResult(
                title: result.title, body: result.body,
                error: WebFetchError.emptyPage.errorDescription)
        }
        return result
    }

    /// 面向 tool handler:成功返回报告,失败返回 `error: ...` 文本(诚实,供模型降级)。
    static func runForTool(
        url: String,
        timeout: Int? = nil,
        backend: (any WebFetchBackend)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
    ) async -> String {
        do {
            let result = try await fetch(
                urlString: url,
                timeoutSeconds: timeout ?? 30,
                backend: backend,
                environment: environment)
            if let error = result.error, !error.isEmpty {
                var parts: [String] = ["error: \(error)"]
                if !result.title.isEmpty { parts.append("title: \(result.title)") }
                return parts.joined(separator: "\n")
            }
            return WebFetchParser.report(result, maxBodyChars: defaultMaxBodyChars)
        } catch let e as WebFetchError {
            return "error: \(e.errorDescription ?? "unknown web_fetch error")"
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Tool 注册

extension WebFetchClient {
    /// `web_fetch` ToolEntry — 已知 URL 的网页内容读取。
    static func toolEntry() -> ToolEntry {
        struct WebFetchArgs: Codable {
            let url: String
            let timeout: Int?
        }
        return ToolEntry.typed(
            name: "web_fetch",
            toolset: "web",
            argsType: WebFetchArgs.self,
            description:
                "Read the rendered content of a known http(s) URL via WebKit (WKWebView). "
                + "Use for a specific page (API docs, JS-rendered docs, a search result link). "
                + "Read-only: no clicking/forms/login; not for bulk crawling. "
                + "For discovery use web_search first.",
            schema: ToolSchema(parameters: [
                "url": ToolParameter(type: .string, description: "Full http(s) URL to fetch."),
                "timeout": ToolParameter(
                    type: .integer,
                    description: "Optional timeout in seconds (1...120, default 30)."),
            ])
        ) { args in
            await WebFetchClient.runForTool(url: args.url, timeout: args.timeout)
        }
    }
}
