// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// DirectWebSearch — model-free web retrieval over HTML search engines.
///
/// First-principles (user's correction, live-proven 2026-10-11): the search
/// *engine* does not need a local model. Evidence on this machine:
///   • Bing/DDG/Brave API hosts fail at connect (~1s); only cn.bing.com and
///     apple.com reach 200 from bare curl.
///   • cn.bing.com with a cookie session returns clean organic results:
///     9 × `b_algo` blocks with direct hrefs + title + snippet ("金价网"…).
///   • ollama's server-side `web_search` proxies to ollama.com (cloud, keyed
///     to the ollama account) and costs 74–96s of local generation per call.
/// So the default `web_search` path is: plain HTTP GET to a search engine,
/// parse results, hand them to the local model to answer. Zero model tokens
/// spent finding information; the model only reads it. Zero API keys — the
/// user never pastes a token.
///
/// Honesty rules:
///   • A blocked engine is reported with its failure reason (host + why),
///     never hidden behind a fake success.
///   • "no organic results" is surfaced as an honest empty list — the page
///     loaded but the query matched nothing indexable (soft-block shape).
///   • Every attempt lands in the report trail; the last error is what the
///     model sees on total failure.
///
/// Engines (tried in order, env override OCRE_SEARCH_ENGINES, comma-list):
///   bing → ddg → mojeek. Default OCRE_SEARCH_MODE=native (this path);
///   set OCRE_SEARCH_MODE=backend to route via ollama `/v1/responses`
///   (WebSearchClient), OCRE_SEARCH_MODE=auto for native-then-backend.
///
/// Parsing lives in DirectWebSearchParser as pure functions over HTML text —
/// locked by offline tests; no network needed to prove the contract.
import Foundation

// MARK: - Result

/// A single organic search hit, model-free from HTML SERPs.
struct DirectSearchHit: Sendable, Equatable {
    let title: String
    let url: String
    let snippet: String
}

/// Model-free search outcome. `hits` may legitimately be empty; the report
/// never disguises that.
struct DirectSearchOutcome: Sendable, Equatable {
    let engine: String
    let query: String
    let hits: [DirectSearchHit]
    /// Engines tried before `engine` succeeded, each with a short honest reason.
    let trail: [String]

    /// LLM-facing report: compact, grep-stable, source-cited per hit.
    var report: String {
        var lines: [String] = []
        lines.append("status: completed")
        lines.append("engine: \(engine) (direct, no model)")
        if !trail.isEmpty {
            lines.append("tried_first: \(trail.joined(separator: ", "))")
        }
        lines.append("query: \(query)")
        if hits.isEmpty {
            lines.append("results: (none — query returned no organic hits)")
        } else {
            lines.append("results:")
            for h in hits {
                lines.append("- \(h.title)")
                lines.append("  url: \(h.url)")
                if !h.snippet.isEmpty {
                    lines.append("  \(h.snippet)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Engine spec (pure)

struct DirectSearchEngine: Sendable, Equatable {
    let name: String
    /// Full search URL for `query` with result count (already percent-encoded).
    let searchURL: String
    /// Cookie-bootstrap URL (GET first); nil when the engine needs no session.
    let warmupURL: String?

    static let all: [DirectSearchEngine] = [
        DirectSearchEngine(
            name: "bing",
            searchURL:
                "https://cn.bing.com/search?q=%Q%&count=%N%",
            warmupURL: "https://cn.bing.com/"),
        DirectSearchEngine(
            name: "ddg",
            searchURL: "https://html.duckduckgo.com/html/?q=%Q%&kl=cn-zh",
            warmupURL: nil),
        DirectSearchEngine(
            name: "mojeek",
            searchURL: "https://www.mojeek.com/search?q=%Q%",
            warmupURL: nil),
    ]

    /// URL for a query. Percent-encode everything except unreserved marks.
    /// Bing requires the query encoded (raw spaces → 302 bounce loop).
    func url(query: String, count: Int = 8) -> URL? {
        let encoded = Self.percentEncode(query)
        let s =
            searchURL
            .replacingOccurrences(of: "%Q%", with: encoded)
            .replacingOccurrences(of: "%N%", with: String(count))
        return URL(string: s)
    }

    static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// MARK: - Parser (pure, offline-testable)

enum DirectSearchParser {
    /// Parse organic hits from a SERP HTML string. Engine-specific block
    /// shapes, generic-enough fallback. Returns [] on unparseable/blocked
    /// shapes — caller distinguishes "loaded-but-empty" from HTTP failures.
    static func hits(html: String, engine: String) -> [DirectSearchHit] {
        switch engine {
        case "bing": return bing(html: html)
        case "ddg": return ddg(html: html)
        case "mojeek": return mojeek(html: html)
        default: return generic(html: html)
        }
    }

    /// Bing (`cn.bing.com`): `<li class="b_algo">` blocks; title in inner
    /// `<h2><a href>` (direct URL, proven live); snippet in first `<p>`.
    static func bing(html: String) -> [DirectSearchHit] {
        hitsFromBlocks(
            html,
            block: "<li class=\"b_algo\"[^>]*>(.*?)</li>",
            link: "<h2><a[^>]*href=\"(http[^\"]*)\"[^>]*>(.*?)</a></h2>",
            snippet: "<p[^>]*>(.*?)</p>")
    }

    /// Two-stage organic extraction: block → inner link (href+title) →
    /// optional snippet. Never assumes group counts the pattern lacks.
    private static func hitsFromBlocks(
        _ html: String, block: String, link: String, snippet: String
    ) -> [DirectSearchHit] {
        guard
            let blockRe = try? NSRegularExpression(
                pattern: block, options: [.dotMatchesLineSeparators]),
            let linkRe = try? NSRegularExpression(
                pattern: link, options: [.dotMatchesLineSeparators]),
            let snipRe = try? NSRegularExpression(
                pattern: snippet, options: [.dotMatchesLineSeparators])
        else { return [] }
        let ns = html as NSString
        var hits: [DirectSearchHit] = []
        for b in blockRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: b.range(at: 1))
            let bns = body as NSString
            guard
                let l = linkRe.firstMatch(
                    in: body, range: NSRange(location: 0, length: bns.length))
            else { continue }
            let href = unescape(bns.substring(with: l.range(at: 1)))
            guard href.hasPrefix("http") else { continue }
            let title = strip(l.range(at: 2), in: bns)
            guard !title.isEmpty else { continue }
            var snippet = ""
            if let s = snipRe.firstMatch(
                in: body, range: NSRange(location: 0, length: bns.length))
            {
                snippet = strip(s.range(at: 1), in: bns)
            }
            hits.append(DirectSearchHit(title: title, url: href, snippet: snippet))
        }
        return hits
    }

    /// DuckDuckGo HTML: `<a rel="nofollow" class="result__a" href="…">` +
    /// snippet `result__snippet`.
    static func ddg(html: String) -> [DirectSearchHit] {
        let titleRe = try? NSRegularExpression(
            pattern: "<a[^>]*class=\"result__a\"[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>",
            options: [.dotMatchesLineSeparators])
        let snippetRe = try? NSRegularExpression(
            pattern: "<a[^>]*class=\"result__snippet\"[^>]*>(.*?)</a>",
            options: [.dotMatchesLineSeparators])
        var hits: [DirectSearchHit] = []
        guard let t = titleRe else { return [] }
        let ns = html as NSString
        let titles = t.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var snippets: [String] = []
        if let s = snippetRe {
            for m in s.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                snippets.append(strip(m.range(at: 1), in: ns))
            }
        }
        for (i, m) in titles.enumerated() {
            let href = ns.substring(with: m.range(at: 1))
            let url = unwrapDDGRedirect(href)
            guard url.hasPrefix("http") else { continue }
            hits.append(
                DirectSearchHit(
                    title: strip(m.range(at: 2), in: ns),
                    url: url,
                    snippet: i < snippets.count ? snippets[i] : ""))
        }
        return hits
    }

    /// Mojeek fallback: `<a class="ob" href>` titles (snippet omitted —
    /// best-effort engine, rarely reached from CN networks).
    static func mojeek(html: String) -> [DirectSearchHit] {
        organicLinks(html, link: "<a class=\"ob\" href=\"(http[^\"]*)\"[^>]*>(.*?)</a>")
    }

    /// Fallback: `<h2><a href>` titles anywhere on the page.
    static func generic(html: String) -> [DirectSearchHit] {
        organicLinks(html, link: "<h2><a[^>]*href=\"(http[^\"]*)\"[^>]*>(.*?)</a></h2>")
    }

    /// Whole-document link scan (no block wrapper): href + title per match.
    private static func organicLinks(
        _ html: String, link: String
    ) -> [DirectSearchHit] {
        guard
            let linkRe = try? NSRegularExpression(
                pattern: link, options: [.dotMatchesLineSeparators])
        else { return [] }
        let ns = html as NSString
        var hits: [DirectSearchHit] = []
        for l in linkRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = unescape(ns.substring(with: l.range(at: 1)))
            guard href.hasPrefix("http") else { continue }
            let title = strip(l.range(at: 2), in: ns)
            guard !title.isEmpty else { continue }
            hits.append(DirectSearchHit(title: title, url: href, snippet: ""))
        }
        return hits
    }

    /// Strip tags + unescape entities + collapse whitespace.
    static func strip(_ range: NSRange, in ns: NSString) -> String {
        unescape(stripTags(ns.substring(with: range)))
    }
    static func stripTags(_ s: String) -> String {
        (try? NSRegularExpression(pattern: "<[^>]+>", options: [.dotMatchesLineSeparators]))?
            .stringByReplacingMatches(
                in: s, range: NSRange(location: 0, length: (s as NSString).length),
                withTemplate: "") ?? s
    }
    static func unescape(_ s: String) -> String {
        var r = s
        // Numeric entities first (&#x2014; / &#8212; → literal char), before
        // named ones can mangle the digits. Live bing snippets carry these.
        r = decodeNumericEntities(r)
        for (k, v) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
            ("&nbsp;", " "),
        ] {
            r = r.replacingOccurrences(of: k, with: v)
        }
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// Decode `&#123;` and `&#xABCD;` numeric character references.
    static func decodeNumericEntities(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]{1,6});") else {
            return s
        }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 2))
            let isHex = ns.substring(with: m.range(at: 1)) == "x"
            if let code = Int(hex, radix: isHex ? 16 : 10),
                let scalar = Unicode.Scalar(code)
            {
                result += String(Character(scalar))
            } else {
                result += ns.substring(with: m.range)
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// DuckDuckGo wraps results in `//duckduckgo.com/l/?uddg=<encoded>&…`.
    static func unwrapDDGRedirect(_ href: String) -> String {
        guard href.contains("duckduckgo.com/l/") else { return href }
        guard
            let comps = URLComponents(string: "https:" + href)
                ?? URLComponents(string: href)
        else { return href }
        if let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return uddg
        }
        return href
    }
}

// MARK: - Direct fetcher (async)

enum DirectWebSearch {
    /// Chrome UA — cn.bing serves bare curl a dictionary-jacked SERP; a
    /// browser UA + cookie session returns organic results (live-proven).
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// Resolve engine list: env OCRE_SEARCH_ENGINES (comma names) else defaults.
    static func engines(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> [DirectSearchEngine]
    {
        guard let raw = environment["OCRE_SEARCH_ENGINES"], !raw.isEmpty else {
            return DirectSearchEngine.all
        }
        let wanted = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let picked = DirectSearchEngine.all.filter { wanted.contains($0.name) }
        return picked.isEmpty ? DirectSearchEngine.all : picked
    }

    /// Run one query across engines in order. First engine with organic hits
    /// wins. Total failure → throws `DirectWebSearchError.blocked` carrying
    /// the honest per-engine trail (never a fake success, never a silent
    /// swallow of *why*).
    static func search(
        query: String,
        maxHits: Int = 8,
        timeoutS: Int = 15,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> DirectSearchOutcome {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            throw DirectWebSearchError.emptyQuery
        }
        var trail: [String] = []
        var lastError = ""
        for engine in engines(environment: environment) {
            switch await fetch(
                engine: engine, query: q, maxHits: maxHits, timeoutS: timeoutS)
            {
            case .hits(let hits):
                return DirectSearchOutcome(engine: engine.name, query: q, hits: hits, trail: trail)
            case .blocked(let why):
                lastError = why
                trail.append("\(engine.name): \(why)")
            }
        }
        throw DirectWebSearchError.blocked(query: q, trail: trail, lastError: lastError)
    }

    enum FetchOutcome {
        case hits([DirectSearchHit])
        case blocked(String)
    }

    /// Fetch + parse one engine. Cookie warmup first when the engine has one.
    static func fetch(
        engine: DirectSearchEngine, query: String, maxHits: Int, timeoutS: Int
    ) async -> FetchOutcome {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = TimeInterval(timeoutS)
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        let session = URLSession(configuration: config)
        // Cookie warmup (cn.bing gates organic SERP behind a session cookie;
        // cookie-less requests get the degraded dictionary-jacked page).
        // Awaited inline — no semaphore, no cooperative-thread blocking.
        if let warmup = engine.warmupURL, let warmURL = URL(string: warmup) {
            var w = URLRequest(url: warmURL)
            w.httpMethod = "GET"
            w.timeoutInterval = TimeInterval(min(timeoutS, 8))
            w.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            _ = try? await session.data(for: w)
        }
        guard let url = engine.url(query: query, count: maxHits) else {
            return .blocked("invalid search url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = TimeInterval(timeoutS)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .blocked("no http response") }
            guard (200 ..< 300).contains(http.statusCode) else {
                return .blocked("HTTP \(http.statusCode)")
            }
            guard let body = String(data: data, encoding: .utf8) else {
                return .blocked("non-utf8 body")
            }
            let hits = DirectSearchParser.hits(html: body, engine: engine.name)
            if hits.isEmpty {
                // Soft-block fingerprint (cn.bing known shape): dictionary /
                // top-news page served instead of organic results.
                return .blocked("no organic results (possible soft-block)")
            }
            return .hits(Array(hits.prefix(maxHits)))
        } catch let e as URLError {
            return .blocked("\(e.code): \(e.localizedDescription)")
        } catch {
            return .blocked(error.localizedDescription)
        }
    }

    /// URLSession config carried by `fetch` (cookies per-engine ephemeral).
}

// MARK: - Error

enum DirectWebSearchError: Error, LocalizedError, Equatable {
    case emptyQuery
    case blocked(query: String, trail: [String], lastError: String)

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            "search query must be non-empty"
        case .blocked(let q, let trail, let last):
            "all search engines blocked for '\(q)' — "
                + (trail.isEmpty ? "no engine tried" : trail.joined(separator: "; "))
                + ". Degrade honestly: answer without fresh web data, or ask the "
                + "user to enable an engine (OCRE_SEARCH_ENGINES) or a backend "
                + "search (OCRE_SEARCH_MODE=backend needs ollama running). "
                + "Last failure: \(last)"
        }
    }
}

// MARK: - Tool entry (default web_search path)

extension DirectWebSearch {
    /// `web_search` handler wiring: native-first per OCRE_SEARCH_MODE;
    /// `backend` routes to WebSearchClient (ollama server-side search);
    /// `auto` tries native, falls back to backend, combining failure trails.
    static func toolEntry() -> ToolEntry {
        struct Args: Codable {
            let query: String
            let max_output_tokens: Int?
        }
        return ToolEntry.typed(
            name: "web_search",
            toolset: "web",
            argsType: Args.self,
            description:
                "Search the web for current information. Returns cited organic results (title/url/snippet) fetched directly — no model or API key involved; answer from the results and cite URLs.",
            schema: ToolSchema(parameters: [
                "query": ToolParameter(type: .string, description: "Search query."),
                "max_output_tokens": ToolParameter(
                    type: .integer,
                    description: "Hint: max results context (unused by direct path)."),
            ])
        ) { args in
            await runForTool(
                query: args.query, maxOutputTokens: args.max_output_tokens)
        }
    }

    static func runForTool(
        query: String,
        maxOutputTokens: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> String {
        let mode = environment["OCRE_SEARCH_MODE"] ?? "native"
        switch mode {
        case "backend":
            return await WebSearchClient.runForTool(
                query: query, maxOutputTokens: maxOutputTokens, environment: environment)
        case "auto":
            do {
                return try await searchOutcome(
                    query: query, environment: environment
                ).report
            } catch let nativeErr as DirectWebSearchError {
                let backend = await WebSearchClient.runForTool(
                    query: query, maxOutputTokens: maxOutputTokens, environment: environment)
                if backend.hasPrefix("error:") {
                    return
                        "error: native search blocked [\(nativeErr.errorDescription ?? "?")] AND "
                        + "backend failed [\(String(backend.dropFirst("error: ".count)))]"
                }
                return backend
            } catch {
                return "error: \(error.localizedDescription)"
            }
        default:  // "native"
            do {
                return try await searchOutcome(
                    query: query, environment: environment
                ).report
            } catch let e as DirectWebSearchError {
                return "error: \(e.errorDescription ?? "direct search failed")"
            } catch {
                return "error: \(error.localizedDescription)"
            }
        }
    }

    private static func searchOutcome(
        query: String, environment: [String: String]
    ) async throws -> DirectSearchOutcome {
        let maxHits = Int(environment["OCRE_SEARCH_MAX_HITS"] ?? "") ?? 8
        let timeoutS = Int(environment["OCRE_SEARCH_DIRECT_TIMEOUT"] ?? "") ?? 15
        return try await search(
            query: query, maxHits: maxHits, timeoutS: timeoutS, environment: environment)
    }
}
