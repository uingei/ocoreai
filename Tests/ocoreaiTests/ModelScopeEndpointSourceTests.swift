// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelScope 默认端点单一真源回归守卫(「两次数据不一致→不信任」的硬门)。
///
/// 背景:同一 `MODELSCOPE_ENDPOINT` 语义曾在三处给出两个不同默认域
/// (`SearchClient → modelscope.cn` vs `Downloader`/`HubConfigFetcher → www.`)。
/// 已收敛为 `ModelStore.modelScopeDefaultBaseURL` 单一真源;三处消费方
/// (`ModelScopeSearchClient` / `ModelScopeDownloader` / `HubConfigFetcher`)
/// 只通过该常量引用端点,不再自带字面量。
///
/// 本测试锁住不变量:
///   1. 真源默认值 = ModelScope 根域(精确值);
///   2. `HubConfigFetcher` 解析出的默认端点与真源一致(API 级);
///   3. **除真源 `ModelStore.swift` 外,`Sources/` 任何 .swift 都不得再出现
///      `modelscope.cn` 端点字面量** —— 谁再硬编码进别的文件,此测试即红。

import Foundation
import Testing

@testable import ocoreai

@Suite("ModelScope endpoint single-source regression guard")
struct ModelScopeEndpointSourceTests {

    // MARK: 1. 真源精确值

    @Test("canonical default base URL is the ModelScope root domain")
    func canonicalDefaultsMatchRootDomain() {
        #expect(ModelStore.modelScopeDefaultBaseURL == "https://modelscope.cn")
        let url = try? URL(string: ModelStore.modelScopeDefaultBaseURL)
        #expect(url?.host() == "modelscope.cn")
        #expect((url?.path.isEmpty) == true)  // 根域;`/api/v1` 前缀由消费方追加
    }

    // MARK: 2. API 级对齐:共享解析器与真源一致

    @Test("HubConfigFetcher resolves the same default endpoint (no drift)")
    func sharedResolverMatchesSingleSource() {
        // 未设 MODELSCOPE_ENDPOINT 时,解析结果必须等于真源默认。
        let endpoint = HubConfigFetcher.modelScopeEndpoint()
        #expect(endpoint == ModelStore.modelScopeDefaultBaseURL)
    }

    // MARK: 3. 全库字面量守卫:端点默认只允许出自单一真源文件

    @Test("no stray modelscope.cn literals outside ModelStore.swift")
    func singleSourceLiteralsOnly() {
        let fm = FileManager.default
        guard let sources = Self.findSourcesDir() else {
            // 找不到 Sources 树 → 显式失败而非静默通过(防守卫失效)。
            Issue.record("Sources/ 目录未找到,无法执行字面量守卫")
            return
        }
        guard
            let enumerator = fm.enumerator(
                at: sources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
            )
        else { return }

        // 只锁「双引号字符串字面量的 URL 默认值」,不误报注释/反引号里的域
        // (如 Downloader/HubConfig 文档注释的 `https://www.modelscope.cn`)。
        let pattern = "\"https?://[^\"\\n]*modelscope\\.cn"
        do {
            let re = try NSRegularExpression(pattern: pattern, options: [])
            let allowed = "ModelStore.swift"
            var offenders: [String] = []
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let name = url.lastPathComponent
                if name == allowed { continue }  // 单一真源:允许
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let ns = text as NSString
                let hits = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
                if !hits.isEmpty { offenders.append("\(name) (\(hits.count))") }
            }
            #expect(
                offenders.isEmpty,
                """
                ModelScope 端点字符串默认值泄漏到单一真源( ModelStore.swift)之外: \
                \(offenders.sorted().joined(separator: ", "))
                收敛方式:引用 `ModelStore.modelScopeDefaultBaseURL`,删除裸 URL 字面量。
                """)
        } catch {
            Issue.record("守卫正则编译失败: \(error)")
        }
    }

    // MARK: helper

    /// 定位 `Sources/`(不依赖运行时 cwd):
    /// 1. `SOURCE_ROOT` env(若指向包根);
    /// 2. 从当前目录向上爬,找到含 `Sources/` 且含 `Package.swift` 的包根;
    /// 3. 回退 exe 相对(3 级)与 cwd/Sources。
    private static func findSourcesDir() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let srcEnv = ProcessInfo.processInfo.environment["SOURCE_ROOT"] {
            candidates.append(URL(fileURLWithPath: srcEnv).appendingPathComponent("Sources"))
        }
        // 从 cwd 向上爬,找 "含 Sources/ 且 含 Package.swift" 的包根(最可靠)
        var dir = FileManager.default.currentDirectoryPath
        for _ in 0 ... 6 {
            let s = URL(fileURLWithPath: dir).appendingPathComponent("Sources")
            let manifest = URL(fileURLWithPath: dir).appendingPathComponent("Package.swift")
            if fm.fileExists(atPath: s.path), fm.fileExists(atPath: manifest.path) {
                return s
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        if !CommandLine.arguments.isEmpty {
            let exe = URL(fileURLWithPath: CommandLine.arguments[0])
            candidates.append(
                exe.deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent("Sources"))
        }
        candidates.append(URL(fileURLWithPath: "Sources"))
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources"))
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }
}
