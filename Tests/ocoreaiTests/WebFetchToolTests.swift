// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// `web_fetch` 工具 — 精确值测试。
///
/// 覆盖三类 seam(均可离线、无真实网络):
///   1. `WebFetchRequest.build`   — http/https 接受,其他 scheme/空串/无 host 拒绝,timeout clamp。
///   2. `WebFetchParser`          — 归一化 trim、空页归一为 emptyPage、报告格式。
///   3. `WebFetchClient.runForTool` — 注入 fake backend,契约化"成功→ok 报告 / 失败→error 文本"。
///
/// 基准实证: WKWebView CLI 进程抓取 developer.apple.com → TITLE "Foundation Models |
/// Apple Developer Documentation", BODY_CHARS 9277, 0 error。
/// 工具面契约: name=web_fetch, toolset=web, parameters url:string + timeout:integer。

import Foundation
import Testing

@testable import ocoreai

/// 文件级假 backend — 供 parser/client 测试复用(离线,不发网络)。
struct FakeWebFetchBackend: WebFetchBackend {
    let result: WebFetchResult
    nonisolated func fetch(_ req: WebFetchRequest.Built) async -> WebFetchResult { result }
}

@Suite("web_fetch request construction")
struct WebFetchRequestTests {

    @Test
    func acceptsHttpsURL() throws {
        let b = try WebFetchRequest.build(
            urlString: "https://developer.apple.com/documentation", timeoutSeconds: 30)
        #expect(b.urlString == "https://developer.apple.com/documentation")
        #expect(b.timeoutSeconds == 30)
    }

    @Test
    func trimsWhitespaceAndNormalizesSchemeCase() throws {
        // URLComponents 规范化 scheme 为小写(RFC 3986)
        let b = try WebFetchRequest.build(urlString: "  HTTPS://Example.com  ", timeoutSeconds: 30)
        #expect(b.urlString == "https://Example.com")
    }

    @Test
    func rejectsEmptyURL() {
        #expect(throws: WebFetchError.emptyURL) {
            _ = try WebFetchRequest.build(urlString: "   ", timeoutSeconds: 30)
        }
    }

    @Test
    func rejectsNonHTTPSSchemes() {
        #expect(throws: WebFetchError.unsupportedScheme("file")) {
            _ = try WebFetchRequest.build(urlString: "file:///etc/passwd", timeoutSeconds: 30)
        }
        #expect(throws: WebFetchError.unsupportedScheme("ftp")) {
            _ = try WebFetchRequest.build(urlString: "ftp://example.com/x", timeoutSeconds: 30)
        }
        #expect(throws: WebFetchError.unsupportedScheme("javascript")) {
            _ = try WebFetchRequest.build(urlString: "javascript:alert(1)", timeoutSeconds: 30)
        }
    }

    @Test
    func rejectsMissingHost() {
        #expect(throws: WebFetchError.missingHost) {
            _ = try WebFetchRequest.build(urlString: "https://", timeoutSeconds: 30)
        }
    }

    @Test
    func clampsTimeoutToRange() throws {
        let tooLow = try WebFetchRequest.build(urlString: "https://x/", timeoutSeconds: 0)
        #expect(tooLow.timeoutSeconds == 1)
        let tooHigh = try WebFetchRequest.build(urlString: "https://x/", timeoutSeconds: 9999)
        #expect(tooHigh.timeoutSeconds == 120)
        let inRange = try WebFetchRequest.build(urlString: "https://x/", timeoutSeconds: 45)
        #expect(inRange.timeoutSeconds == 45)
    }
}

@Suite("web_fetch parser")
struct WebFetchParserTests {

    @Test
    func normalizesTitleAndBodyTrimmingWhitespace() {
        let r = WebFetchParser.normalize(title: "  hi  \n", body: "  body\n", failure: nil)
        #expect(r.title == "hi")
        #expect(r.body == "body")
        #expect(r.error == nil)
    }

    @Test
    func emptyPageBecomesExplicitError() async throws {
        // 模拟"加载成功但 body 为空"——WebFetchClient.fetch 归一为 emptyPage
        let b = try WebFetchRequest.build(
            urlString: "https://canvas-only.example.com/", timeoutSeconds: 5)
        let backend = FakeWebFetchBackend(result: WebFetchResult(title: "T", body: "", error: nil))
        let r = try await WebFetchClient.fetch(
            urlString: b.urlString, timeoutSeconds: 5, backend: backend, environment: [:])
        #expect(r.error?.contains("canvas/iframe") == true)
        #expect(r.body.isEmpty)
    }

    @Test
    func reportOnSuccessHasExactShape() {
        let r = WebFetchResult(title: "T", body: String(repeating: "a", count: 1200), error: nil)
        let out = WebFetchParser.report(r, maxBodyChars: 1000)
        #expect(out.hasPrefix("status: ok"))
        #expect(out.contains("body_chars: 1200"))
        #expect(out.contains("--- BODY ---"))
        #expect(out.contains("…(已截断: total 1200 chars)"))
        #expect(!out.contains(String(repeating: "a", count: 1200)), "must not leak full body")
    }

    @Test
    func reportOnFailureSurfacesReasonVerbatim() {
        let r = WebFetchResult(title: "", body: "", error: "navigation failed: not found")
        let out = WebFetchParser.report(r, maxBodyChars: 100)
        #expect(out.contains("status: error"))
        #expect(out.contains("reason: navigation failed: not found"))
    }
}

@Suite("web_fetch client contract (fake backend)")
struct WebFetchClientContractTests {

    @Test
    func successYieldsOKBlock() async throws {
        let backend = FakeWebFetchBackend(
            result: WebFetchResult(title: "Hello", body: "world of text", error: nil))
        let r = try await WebFetchClient.fetch(
            urlString: "https://x.example/", timeoutSeconds: 5, backend: backend, environment: [:])
        #expect(r.error == nil)
        #expect(r.title == "Hello")
        #expect(r.body == "world of text")
    }

    @Test
    func failureYieldsErrorText() async {
        let backend = FakeWebFetchBackend(
            result: WebFetchResult(title: "", body: "", error: "ERR_CONNECTION_REFUSED"))
        let text = await WebFetchClient.runForTool(
            url: "https://unreachable.example/", timeout: 5, backend: backend, environment: [:])
        #expect(text.hasPrefix("error:"))
        #expect(text.contains("ERR_CONNECTION_REFUSED"))
    }

    @Test
    func invalidURLShortCircuitsWithoutBackend() async {
        // 校验先于后端 — 不依赖 WebKit 是否存在,不发网络
        let text = await WebFetchClient.runForTool(
            url: "not-a-url", timeout: 5, backend: nil, environment: [:])
        #expect(text.hasPrefix("error:"))
        #expect(text.contains("url"))
    }
}
