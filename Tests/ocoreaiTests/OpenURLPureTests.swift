// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// OpenURL Pure 段(双平台离线可测, 不触 NSWorkspace/UIApplication 运行时):
// validate(空/无 scheme/合法) / urlCategory(scheme 路由) / report(成功) — 精确值断言, 禁 count>0 弱断言。
import Foundation
import Testing

@testable import ocoreai

struct OpenURLPureTests {

    /// 从 Result 提取 failure case(精确匹配, 不用 `.failure == .x` 语法)。
    private func failureCase(_ r: Result<URL, OpenURL.ValidationError>) -> OpenURL.ValidationError?
    {
        if case .failure(let e) = r { return e }
        return nil
    }

    /// 从 Result 提取 success case。
    private func successCase(_ r: Result<URL, OpenURL.ValidationError>) -> URL? {
        if case .success(let u) = r { return u }
        return nil
    }

    @Test("validate: 空串/纯空白 → .empty")
    func validateEmpty() {
        #expect(failureCase(OpenURL.validate("")) == .empty)
        #expect(failureCase(OpenURL.validate("   \n\t")) == .empty)
        #expect(successCase(OpenURL.validate("")) == nil)
    }

    @Test("validate: 无 scheme 裸 host → .missingScheme")
    func validateMissingScheme() {
        #expect(failureCase(OpenURL.validate("example.com")) == .missingScheme("example.com"))
        #expect(successCase(OpenURL.validate("example.com")) == nil)
    }

    @Test("validate: 合法 http(s)/mailto/tel/custom scheme → success + 正确解析")
    func validateSuccess() {
        #expect(
            successCase(OpenURL.validate("https://example.com/a?b=1"))?.absoluteString
                == "https://example.com/a?b=1")
        #expect(successCase(OpenURL.validate("mailto:user@example.com"))?.scheme == "mailto")
        #expect(successCase(OpenURL.validate("tel:+15551234567"))?.scheme == "tel")
        #expect(successCase(OpenURL.validate("myapp://deep/link?x=2"))?.scheme == "myapp")
        #expect(failureCase(OpenURL.validate("https://ok.com")) == nil)
    }

    @Test("urlCategory: scheme→路由类别(大小写归一化)")
    func urlCategoryRoutes() {
        #expect(OpenURL.urlCategory(URL(string: "https://x.com")!) == "browser")
        #expect(OpenURL.urlCategory(URL(string: "http://x.com")!) == "browser")
        #expect(OpenURL.urlCategory(URL(string: "HTTPS://x.com")!) == "browser")
        #expect(OpenURL.urlCategory(URL(string: "mailto:a@b.com")!) == "email")
        #expect(OpenURL.urlCategory(URL(string: "tel:5551234")!) == "phone")
        #expect(OpenURL.urlCategory(URL(string: "sms:5551234")!) == "phone")
        #expect(OpenURL.urlCategory(URL(string: "myapp://x")!) == "custom-scheme")
        #expect(OpenURL.urlCategory(URL(string: "itms-apps://x")!) == "ios-store")
        #expect(OpenURL.urlCategory(URL(string: "itms-services://x")!) == "ios-store")
        #expect(OpenURL.urlCategory(URL(string: "file:///etc/passwd")!) == "local-file")
    }

    @Test("successReport: 类别 + 完整 URL + handler 标记(精确全文)")
    func successReportExact() {
        let r = OpenURL.successReport(URL(string: "mailto:a@b.com")!)
        #expect(r == "opened email URL: mailto:a@b.com (routed to system handler app)")
    }

    @Test("failureReport: 诚实报无 handler(精确全文)")
    func failureReportExact() {
        let r = OpenURL.failureReport(URL(string: "ghost-scheme://x")!)
        #expect(r == "open FAILED — no system handler app for: ghost-scheme://x")
    }
}
