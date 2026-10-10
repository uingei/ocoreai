// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// DirectWebSearch — model-free retrieval contract, locked offline.
/// The Bing fixture below is REAL captured cn.bing SERP markup (2026-10-11,
/// cookie session, query "黄金价格") — blocks minimized to the structural
/// essentials the parser depends on, titles/urls/snippets kept verbatim.
import Foundation
import Testing

@testable import ocoreai

@Suite("DirectWebSearch — engine spec (pure)")
struct DirectEngineSpecTests {
    @Test("default engine order is bing → ddg → mojeek")
    func defaultOrder() {
        #expect(DirectSearchEngine.all.map(\.name) == ["bing", "ddg", "mojeek"])
    }

    @Test("env override picks subset, preserves canonical order")
    func envOverride() {
        let e = DirectWebSearch.engines(environment: ["OCRE_SEARCH_ENGINES": "mojeek,bing"])
        #expect(e.map(\.name) == ["bing", "mojeek"])
        // Nonsense override → defaults (never zero engines).
        #expect(DirectWebSearch.engines(environment: ["OCRE_SEARCH_ENGINES": "nope"]).count == 3)
    }

    @Test("query is percent-encoded; count substituted")
    func encoding() {
        let bing = DirectSearchEngine.all[0]
        let url = bing.url(query: "今日 金价", count: 8)!
        #expect(url.absoluteString.contains("%E4%BB%8A%E6%97%A5%20%E9%87%91%E4%BB%B7"))
        #expect(!url.absoluteString.contains(" "))
        #expect(bing.url(query: "x", count: 5)!.absoluteString.contains("count=5"))
        // Bing needs the cookie warmup; ddg/mojeek don't.
        #expect(bing.warmupURL != nil)
    }
}

@Suite("DirectWebSearch — parsers (real captured SERP shapes)")
struct DirectParserTests {
    /// Real cn.bing organic blocks (2026-10-11 capture, minimized to the
    /// markup the parser reads; data verbatim).
    static let bingFixture = """
        <li class="b_algo" data-id iid=SERP.5318><h2><a h="ID=SERP,5164.1" href="https://www.huilvbiao.com/gold">今日金价 (实时更新),黄金价格, 最新国际黄金价格走势图_汇率表</a></h2><div class="b_caption"><p class="b_lineclamp2">17 小时之前 &nbsp;&#8212;&nbsp; 为您提供今日黄金价格，国内黄金价格，纽约期货国际金价，伦敦现货黄金价格今日最新数据行情及黄金价格走势图。</p></div></li>
        <li class="b_algo" data-id iid=SERP.5319><h2><a href="https://finance.sina.com.cn/futures/quotes/XAU.shtml">伦敦金（现货黄金）CFD (XAU)期货行情,新闻,报价_新浪财经 ...</a></h2><div class="b_caption"><p class="b_lineclamp2">提供伦敦金（现货黄金）CFD期货行情、新闻、报价、机构报告、评论及持仓分析等综合信息服务。</p></div></li>
        <li class="b_algo" data-id iid=SERP.5320><h2><a href="https://www.cngold.org/quote/gjs/">今日现货黄金价格 (最新现货金行情走势图分析)-行情中心</a></h2><div class="b_caption"><p class="b_lineclamp2">金投网行情中心为您提供及时的行情数据，包括今日现货黄金价格与最新现货黄金价格走势图等。</p></div></li>
        """

    @Test("real cn.bing blocks parse to hits with url+title+snippet")
    func bingReal() {
        let hits = DirectSearchParser.bing(html: Self.bingFixture)
        guard hits.count == 3 else {
            Issue.record("expected 3 hits, got \(hits.count)")
            return
        }
        #expect(hits[0].url == "https://www.huilvbiao.com/gold")
        #expect(hits[0].title.contains("黄金"))
        #expect(hits[1].title.contains("伦敦金"))
        // Entities decoded, tags stripped, no raw markup leaks.
        #expect(hits[0].snippet.contains("—"))
        #expect(!hits[0].snippet.contains("<"))
        #expect(!hits[0].snippet.contains("&amp;"))
    }

    @Test("blocked/degraded SERP → zero hits, never a crash")
    func bingBlocked() {
        // cn.bing dictionary-jack page: no b_algo blocks at all.
        #expect(
            DirectSearchParser.bing(html: "<html><body><div id='b_results'></div></body></html>")
                .isEmpty)
        // b_algo but no http link → skipped honestly.
        #expect(
            DirectSearchParser.bing(
                html: "<li class=\"b_algo\"><h2><a href=\"/local\">x</a></h2></li>"
            )
            .isEmpty)
    }

    @Test("ddg parses result__a and unwraps uddg redirect")
    func ddg() {
        let html = """
            <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fgold&amp;rut=abc">Gold Today</a>
            <a class="result__snippet" href="#">Spot gold is <b>4133</b> USD.</a>
            """
        let hits = DirectSearchParser.ddg(html: html)
        #expect(hits.count == 1)
        #expect(hits[0].url == "https://example.com/gold")
        #expect(hits[0].title == "Gold Today")
        #expect(hits[0].snippet.contains("4133"))
    }

    @Test("mojeek parses ob links")
    func mojeek() {
        let hits = DirectSearchParser.mojeek(
            html: "<a class=\"ob\" href=\"https://x.io/a\">Alpha</a>")
        #expect(hits.count == 1)
        #expect(hits[0].url == "https://x.io/a")
        #expect(hits[0].title == "Alpha")
    }

    @Test("report shape: status + engine + cited hits, grep-stable")
    func report() {
        let o = DirectSearchOutcome(
            engine: "bing", query: "gold",
            hits: [DirectSearchHit(title: "金价网", url: "https://j.net", snippet: "4133 USD")],
            trail: ["ddg: HTTP 000"])
        let r = o.report
        #expect(r.contains("status: completed"))
        #expect(r.contains("engine: bing (direct, no model)"))
        #expect(r.contains("tried_first: ddg: HTTP 000"))
        #expect(r.contains("- 金价网"))
        #expect(r.contains("url: https://j.net"))
        #expect(r.contains("4133 USD"))
        // Empty is surfaced as empty — never disguised.
        #expect(
            DirectSearchOutcome(engine: "bing", query: "q", hits: [], trail: []).report
                .contains("results: (none"))
    }
}

@Suite("DirectWebSearch — honesty on failure paths")
struct DirectHonestyTests {
    @Test("empty query rejected before any network")
    func emptyQuery() async {
        do {
            _ = try await DirectWebSearch.search(query: "   ")
            Issue.record("should have thrown")
        } catch let e as DirectWebSearchError {
            if case .emptyQuery = e {} else { Issue.record("wrong error: \(e)") }
        } catch { Issue.record("wrong error type") }
    }

    @Test("total block carries full trail + degrade lever")
    func blockedTrail() {
        let err = DirectWebSearchError.blocked(
            query: "gold",
            trail: ["bing: HTTP 403", "ddg: connect: timed out"],
            lastError: "ddg: connect: timed out")
        let d = err.errorDescription ?? ""
        #expect(d.contains("all search engines blocked for 'gold'"))
        #expect(d.contains("bing: HTTP 403"))
        #expect(d.contains("OCRE_SEARCH_ENGINES"))
        #expect(d.contains("Last failure: ddg: connect: timed out"))
    }

    @Test("backend mode routes to ollama client and surfaces its honest error")
    func modeRouting() async {
        let out = await DirectWebSearch.runForTool(
            query: "anything",
            environment: [
                "OCRE_SEARCH_MODE": "backend",
                "OCRE_SEARCH_BASE_URL": "http://127.0.0.1:1/",
                "OCRE_SEARCH_PROBE_TIMEOUT": "1",
            ])
        #expect(out.hasPrefix("error:"))
        #expect(out.contains("offline") || out.contains("unreachable"))
    }

    @Test("native engine list never empty via override mistakes")
    func resilientEngineList() {
        #expect(
            DirectWebSearch.engines(environment: ["OCRE_SEARCH_ENGINES": " , "]).count == 3)
        // Known-only override resolves to exactly those.
        #expect(
            DirectWebSearch.engines(environment: ["OCRE_SEARCH_ENGINES": "ddg"]).map(\.name)
                == ["ddg"])
    }
}
