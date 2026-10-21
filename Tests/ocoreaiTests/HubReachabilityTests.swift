// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! HubReachabilityTests.swift — the table that decides "ask the other hub, or refuse", pinned
//! by exact value, plus the scan proving the guard sits in front of the download.
//!
//! ### What this gates (measured 10-21, this host)
//! `huggingface.co` is a black hole here: `curl` against its API returns nothing even for a
//! repo that exists (`HTTP=000` at 8 s), while ModelScope answers a real 404 in 0.18 s. Before
//! the guard, `MLXBridge.loadFromHubWithFallback` handed the request to the HF client anyway: a
//! turn for an unresolvable id produced no answer after 300 s, and the id stayed in
//! `EnginePool.loadingModels` while it waited. Silence is the defect, so the gate is twofold —
//! the decision table pinned by value, and a scan pinning that the fallback download cannot be
//! reached before the guard has run. A refusal that a later refactor forgets to call is the
//! same bug with a green suite (invariant 1).
//!
//! ### Why `unreachable` is not `absent`
//! 404 means "this hub does not have it"; a timeout means "we could not ask". Collapsing them
//! would tell a caller on a blocked network that its model does not exist. They leave the
//! process as different cases (`modelNotFound` 404 / `modelUnavailable` 503), and that
//! distinction is asserted here rather than trusted to a call site's prose.

import Foundation
import Hummingbird
import Testing

@testable import ocoreai

@Suite("HubReachability — exact verdict table")
struct HubReachabilityVerdictTests {

    @Test("the budget is 8 s, named in code rather than inherited from a session default")
    static func budgetIsNamed() {
        #expect(HubReachability.probeTimeoutSeconds == 8)
    }

    @Test("2xx means the hub has it")
    static func successMeansPresent() {
        #expect(HubReachability.classify(.status(200)) == .present)
        #expect(HubReachability.classify(.status(201)) == .present)
        #expect(HubReachability.classify(.status(204)) == .present)
    }

    @Test("an auth challenge counts as present — the caller's own token may still fetch it")
    static func authChallengeMeansPresent() {
        #expect(HubReachability.classify(.status(401)) == .present)
        #expect(HubReachability.classify(.status(403)) == .present)
    }

    @Test("404 and 422 are definitive absence, and the status travels with the verdict")
    static func definitiveAbsence() {
        #expect(HubReachability.classify(.status(404)) == .absent(status: 404))
        #expect(HubReachability.classify(.status(422)) == .absent(status: 422))
    }

    @Test("throttle, timeout-shaped and server errors mean 'could not ask', never 'not here'")
    static func transientMeansUnreachable() {
        #expect(HubReachability.classify(.status(408)) == .unreachable(reason: "HTTP 408"))
        #expect(HubReachability.classify(.status(429)) == .unreachable(reason: "HTTP 429"))
        #expect(HubReachability.classify(.status(500)) == .unreachable(reason: "HTTP 500"))
        #expect(HubReachability.classify(.status(503)) == .unreachable(reason: "HTTP 503"))
    }

    @Test("a transport failure carries its reason through verbatim")
    static func transportCarriesReason() {
        #expect(
            HubReachability.classify(.transport("timed out"))
                == .unreachable(reason: "timed out"))
    }

    @Test("absent and unreachable are different verdicts — a 404 must not read as retryable")
    static func verdictsStayDistinct() {
        #expect(
            HubReachability.Verdict.absent(status: 404)
                != HubReachability.Verdict.unreachable(reason: "HTTP 404"))
        #expect(
            HubReachability.Verdict.present
                != HubReachability.Verdict.absent(status: 200))
    }

    @Test("a hub that cannot be reached at all answers promptly, and never throws")
    static func unreachableAnswersPromptly() async {
        // Port 1 on loopback: nothing binds a privileged port without root, so connect fails
        // immediately. This is the promise the header makes — a failure to ask is an answer,
        // delivered fast, not an exception and not a wait.
        let started = ContinuousClock.now
        let verdict = await HubReachability.probe(
            hub: .huggingFace, repoId: "no-such-org/no-such-model",
            hfEndpoint: "http://127.0.0.1:1")
        let elapsed = started.duration(to: ContinuousClock.now)
        switch verdict {
        case .unreachable(let reason):
            #expect(!reason.isEmpty, "an unreachable verdict with no reason names nothing")
            #expect(
                elapsed < .seconds(4),
                "the guard took \(elapsed) to learn nothing — it must fail fast, not wait")
        default:
            #expect(
                false,
                "a refused port produced \(verdict) — the probe must classify transport failure")
        }
    }
}

@Suite("HubReachability — the existence endpoint per hub")
struct HubReachabilityURLTests {

    private static func text(_ url: URL?) -> String { url?.absoluteString ?? "<nil>" }

    @Test("ModelScope's model API is the v1 models path")
    static func modelScopePath() {
        #expect(
            text(HubReachability.apiURL(hub: .modelScope, repoId: "org/name"))
                == "https://modelscope.cn/api/v1/models/org/name")
    }

    /// The probe must ask the mirror the operator configured, not the canonical host — the same
    /// rule `HFMirrorPolicy` was written for, on the other hub. `ModelScopeSearchClient` and
    /// `ModelScopeDownloader` already read `MODELSCOPE_ENDPOINT`; a probe that ignored it would
    /// ask one host and download from another.
    @Test("MODELSCOPE_ENDPOINT is what gets probed, trailing slash or not")
    static func modelScopeOverrideIsProbed() {
        #expect(
            text(
                HubReachability.apiURL(
                    hub: .modelScope, repoId: "Qwen/Qwen3-4B",
                    modelScopeEndpoint: "https://mirror.example.cn"))
                == "https://mirror.example.cn/api/v1/models/Qwen/Qwen3-4B")
        #expect(
            text(
                HubReachability.apiURL(
                    hub: .modelScope, repoId: "Qwen/Qwen3-4B",
                    modelScopeEndpoint: "https://mirror.example.cn/"))
                == "https://mirror.example.cn/api/v1/models/Qwen/Qwen3-4B")
        // Empty counts as unset, not "point here" — same rule as HF.
        #expect(
            text(
                HubReachability.apiURL(
                    hub: .modelScope, repoId: "org/name", modelScopeEndpoint: "  "))
                == "https://modelscope.cn/api/v1/models/org/name")
    }

    @Test("with no usable override Hugging Face is canonical — empty counts as no override")
    static func canonicalWhenNoOverride() {
        #expect(
            text(HubReachability.apiURL(hub: .huggingFace, repoId: "org/name"))
                == "https://huggingface.co/api/models/org/name")
        #expect(
            text(HubReachability.apiURL(hub: .huggingFace, repoId: "org/name", hfEndpoint: ""))
                == "https://huggingface.co/api/models/org/name")
        #expect(
            text(HubReachability.apiURL(hub: .huggingFace, repoId: "org/name", hfEndpoint: "  "))
                == "https://huggingface.co/api/models/org/name")
    }

    @Test("the mirror the operator chose is what gets probed, trailing slash or not")
    static func mirrorOverrideIsProbed() {
        #expect(
            text(
                HubReachability.apiURL(
                    hub: .huggingFace, repoId: "Qwen/Qwen3-4B",
                    hfEndpoint: "https://hf-mirror.com"))
                == "https://hf-mirror.com/api/models/Qwen/Qwen3-4B")
        #expect(
            text(
                HubReachability.apiURL(
                    hub: .huggingFace, repoId: "Qwen/Qwen3-4B",
                    hfEndpoint: "https://hf-mirror.com/"))
                == "https://hf-mirror.com/api/models/Qwen/Qwen3-4B")
    }
}

@Suite("AppError.modelUnavailable — transient, and it says so")
struct ModelUnavailableErrorTests {

    private static let error = AppError.modelUnavailable(
        modelId: "org/name",
        reason: "ModelScope: no record; Hugging Face unreachable (timed out). Retry later.")

    @Test("503, not 404 — the id may exist in a minute, and 404 says it never will")
    static func statusIsServiceUnavailable() {
        #expect(error.status == .serviceUnavailable)
        #expect(AppError.modelNotFound("org/name").status == .notFound)
    }

    @Test("the refusal names the model, both hubs, and the remedy")
    static func descriptionNamesEverything() {
        #expect(error.description.contains("org/name"), "no id in: \(error.description)")
        #expect(error.description.contains("ModelScope"), "no primary hub in: \(error.description)")
        #expect(
            error.description.contains("Hugging Face"), "no fallback hub in: \(error.description)")
        #expect(error.description.contains("Retry later"), "no remedy in: \(error.description)")
    }

    @Test("errorDescription mirrors description — the JSON body carries the same words")
    static func errorDescriptionMirrorsDescription() {
        #expect(error.errorDescription == error.description)
    }
}

/// The placement rules. Every scan here floors its own hit count and proves its pattern against
/// a synthetic offender first, because a regex that stopped matching looks exactly like a clean
/// tree (invariant 1: a gate that cannot see its own premise rots silently).
@Suite("HubReachability — one guarded home, and the scan can see it")
struct HubGuardPlacementTests {

    private static let home = "Sources/ocoreai/Engine/MLXBridge.swift"
    private static let fmOnlyRoute = "Sources/ocoreai/Engine/EnginePool.swift"
    private static let guardPath = "Sources/ocoreai/Engine/HubReachability.swift"

    private static let probePattern = #"HubReachability\.probe\("#
    private static let downloadPattern = #"loadFromHub\(\s*fallback\b"#
    private static let choicePattern = #"HubProvider\s*=\s*\w+\s*==\s*\.modelScope\s*\?"#

    private struct Missing: Error, CustomStringConvertible {
        let what: String
        var description: String { "could not find \(what) walking up from \(#filePath)" }
    }

    /// Comment-aware code lines — prose is allowed to name the shape in order to forbid it.
    private static func codeLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter {
            line in
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            return !(trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*"))
        }
    }

    /// A file's code as one whitespace-collapsed string, plus the 1-based line each UTF-16 unit
    /// came from. Hub calls wrap across lines, so the decision is only visible flattened.
    private struct Scan {
        let path: String
        let code: [String]
        let flat: String
        let lineAt: [Int]

        func line(_ location: Int) -> Int {
            guard lineAt.indices.contains(location) else { return 0 }
            return lineAt[location]
        }
    }

    private static func scan(_ path: String, _ code: [String]) -> Scan {
        var text = ""
        var lineAt: [Int] = []
        for (index, line) in code.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if !text.isEmpty {
                text += " "
                lineAt.append(0)
            }
            text += trimmed
            lineAt.append(contentsOf: repeatElement(index + 1, count: trimmed.utf16.count))
        }
        return Scan(path: path, code: code, flat: text, lineAt: lineAt)
    }

    private static func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        while dir.path != "/" {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Sources/ocoreai").path),
                FileManager.default.fileExists(atPath: dir.appendingPathComponent("Tests").path)
            {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw Missing(what: "repo root (Sources/ocoreai + Tests)")
    }

    private static func allSwiftSources() throws -> [Scan] {
        let root = try repoRoot()
        guard
            let enumerator = FileManager.default.enumerator(
                at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
        else { throw Missing(what: "Sources/ enumerator") }
        var out: [Scan] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            out.append(scan(String(url.path.dropFirst(root.path.count + 1)), codeLines(text)))
        }
        return out
    }

    private static func locations(_ pattern: String, _ text: String) throws -> [Int] {
        let regex = try NSRegularExpression(pattern: pattern)
        let span = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.matches(in: text, range: span).map { $0.range.location }
    }

    /// Every fallback download must sit at or after the guard. A route with no download needs no
    /// guard; a download with no guard, or in front of it, is the defect. Line granularity is
    /// deliberate: the guard and the download on one line read left-to-right, so `>=` is correct.
    private static func guardedDownloads(probeLines: [Int], downloadLines: [Int]) -> Bool {
        guard let firstProbe = probeLines.min() else { return downloadLines.isEmpty }
        return downloadLines.allSatisfy { $0 >= firstProbe }
    }

    /// 1-based line numbers inside an `#if FoundationModelsIntegration …` branch.
    private static func foundationModelsGatedLines(_ code: [String]) -> Set<Int> {
        var open: [Bool] = []
        var gated: Set<Int> = []
        for (index, line) in code.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") {
                open.append(trimmed.contains("FoundationModelsIntegration"))
            } else if trimmed.hasPrefix("#endif") {
                open.removeLast()
            } else if trimmed.hasPrefix("#else") || trimmed.hasPrefix("#elseif") {
                if !open.isEmpty { open[open.count - 1] = false }
            } else if open.contains(true) {
                gated.insert(index + 1)
            }
        }
        return gated
    }

    enum Route: Equatable {
        /// Nothing to decide here.
        case irrelevant
        /// Picks a fallback hub and asks it only after the reachability guard has run.
        case guarded
        /// Picks a fallback hub on the FoundationModels-only route (this host cannot compile it).
        case foundationModelsOnly
        /// Picks a fallback hub and downloads from it without asking anything first.
        case ungarded
    }

    /// The whole classification, per file, in line numbers. Note the shape of the real home: the
    /// provider is *selected* before the guard (line N) and the *download* follows the guard
    /// (line N+k) — selecting a fallback is not the risk, spending a request on it is.
    private static func route(
        probeLines: [Int], choiceLines: [Int], downloadLines: [Int], gated: Set<Int> = []
    ) -> Route {
        let sites = choiceLines + downloadLines
        if sites.isEmpty { return .irrelevant }
        if sites.allSatisfy({ gated.contains($0) }) { return .foundationModelsOnly }
        if guardedDownloads(probeLines: probeLines, downloadLines: downloadLines) {
            return .guarded
        }
        return .ungarded
    }

    /// The instruments prove themselves before they judge the tree: each pattern must see a
    /// synthetic offender and miss a benign look-alike, and the ordering/region logic must answer
    /// differently for the shapes it exists to tell apart.
    @Test("the scan's own patterns, ordering and region logic still work")
    static func instrumentsProveThemselves() throws {
        #expect(
            try locations(
                probePattern,
                "switch await HubReachability.probe( hub: fallbackHub, repoId: repoId) {"
            ).count
                == 1,
            "the instrument cannot see the guard it counts")
        // Negative controls: a pattern that matched everything would pass the tree scan
        // vacuously. The doc reference names the constant, not the call; the primary hub call
        // takes `provider`, not the fallback; and a UI label picks a display string.
        #expect(
            try locations(probePattern, "see HubReachability.probeTimeoutSeconds for the budget")
                .isEmpty,
            "the guard pattern also matches a reference to the timeout constant")
        #expect(
            try locations(
                downloadPattern,
                "return try await loadFromHub( fallback, repoId: repoId, modelId: modelId)"
            ).count
                == 1,
            "the instrument cannot see the fallback download")
        #expect(
            try locations(
                downloadPattern,
                "return try await loadFromHub( provider, repoId: repoId, modelId: modelId)"
            )
            .isEmpty,
            "the download pattern must not count the primary hub call as a fallback")
        #expect(
            try locations(
                choicePattern,
                "let fallback: HubProvider = provider == .modelScope ? .huggingFace : .modelScope"
            )
            .count == 1,
            "the instrument cannot see a fallback-provider selection")
        #expect(
            try locations(choicePattern, "hub == .huggingFace ? \"Hugging Face\" : \"ModelScope\",")
                .isEmpty,
            "the selection pattern must not count a display string as a provider choice")

        // The shape of today's home: select the fallback, ask, then download.
        #expect(
            route(probeLines: [3], choiceLines: [1], downloadLines: [4]) == .guarded,
            "the home's own shape must classify as guarded")
        #expect(
            route(probeLines: [5], choiceLines: [1], downloadLines: [2]) == .ungarded,
            "a download in front of the guard must classify as ungarded")
        #expect(
            route(probeLines: [], choiceLines: [1], downloadLines: [2]) == .ungarded,
            "a fallback with no guard at all must classify as ungarded")
        #expect(
            route(probeLines: [2], choiceLines: [1], downloadLines: []) == .guarded,
            "a guard with nothing to guard is fine — it must not read as ungarded")
        #expect(
            route(probeLines: [], choiceLines: [2], downloadLines: [3], gated: [2, 3])
                == .foundationModelsOnly,
            "an FM-only route must be recognised as such, not counted as a live defect")
        #expect(
            foundationModelsGatedLines([
                "#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)",
                "let fb: HubProvider = a == .modelScope ? .huggingFace : .modelScope",
                "#else",
                "let fb2: HubProvider = a == .modelScope ? .huggingFace : .modelScope",
                "#endif",
                "let fb3: HubProvider = a == .modelScope ? .huggingFace : .modelScope",
            ]) == [2],
            "the region scan cannot tell an FM-only line from one that compiles here")
    }

    @Test("the guard has exactly one home, in the loader that owns the fallback")
    static func guardHasOneHome() throws {
        let files = try allSwiftSources()
        #expect(
            files.count >= 150, "only \(files.count) Swift sources scanned — the walk is broken")

        let hosts = try files.filter { try locations(probePattern, $0.flat).count > 0 }
        #expect(
            hosts.map(\.path) == [home],
            "the reachability guard must live exactly once, in the loader with the fallback: \(hosts.map(\.path))"
        )
    }

    /// `ModelScopeEndpointSourceTests` forbids bare ModelScope URL literals outside
    /// `ModelStore.swift`; this pins that the guard joined that single source instead of quietly
    /// re-spelling a host (the `www` alias resolves too — which is precisely why a second
    /// spelling survives review until a probe asks a host the downloader never uses).
    @Test("the guard names no hub host of its own — it joins the existing single sources")
    static func guardNamesNoHostLiteral() throws {
        let files = try allSwiftSources()
        guard let guardFile = files.first(where: { $0.path == guardPath }) else {
            throw Missing(what: guardPath)
        }
        let hostLiteral = #"https?://"#
        let offender = "return URL(string: \"https://www.modelscope.cn/api/v1/models/x\")"
        #expect(
            try locations(hostLiteral, offender).count == 1,
            "the instrument cannot see a host literal")
        let hits = try guardFile.code.flatMap { try locations(hostLiteral, $0) }
        #expect(
            hits.isEmpty,
            "the guard re-spells a hub host instead of using the single source")
        let joined = guardFile.code.joined(separator: "\n")
        #expect(
            joined.contains("ModelStore.modelScopeDefaultBaseURL"),
            "ModelScope must come from the single source, not a local default")
        #expect(
            joined.contains("HFMirrorPolicy.canonical"),
            "Hugging Face must come from the mirror policy, not a local default")
    }

    @Test("the fallback download sits behind the guard, never in front of it")
    static func fallbackSitsBehindGuard() throws {
        let files = try allSwiftSources()
        let homeFile = files.first { $0.path == home }
        guard let homeFile else { throw Missing(what: home) }
        let probe = try locations(probePattern, homeFile.flat).map { homeFile.line($0) }
        let downloads = try locations(downloadPattern, homeFile.flat).map { homeFile.line($0) }
        #expect(probe.count == 1, "expected one guard call in the home, got \(probe.count)")
        #expect(
            downloads.count >= 1,
            "the fallback download vanished from the home — the guard has nothing left to guard")
        #expect(
            guardedDownloads(probeLines: probe, downloadLines: downloads),
            "the fallback download is back in front of the guard: lines \(downloads) vs guard \(probe)"
        )
    }

    /// Every place that picks "the other hub" must either ask before downloading or be on the
    /// FoundationModels-only route. That route is measured, not assumed: CLT SDK 26.5 declares
    /// FoundationModels `-user-module-version 1.5.2`, so `canImport(FoundationModels, _version: 2)`
    /// compiles the block out (`swiftc` on this host prints FM_V2_FALSE), while SDK 27 declares
    /// 2.0.68.1.402 and compiles it in — the duplicate there is a macOS-27-only route this box
    /// cannot run, and it is registered in AGENTS.md § Open. The last expectation pins that
    /// register: fix the route without updating the register and this goes red too.
    @Test("no hub fallback on a route this host compiles is ungarded")
    static func noUnguardedFallback() throws {
        let files = try allSwiftSources()
        var ungarded: [String] = []
        var guarded: [String] = []
        var fmOnly: [String] = []
        for file in files {
            let probe = try locations(probePattern, file.flat).map { file.line($0) }
            let choices = try locations(choicePattern, file.flat).map { file.line($0) }
            let downloads = try locations(downloadPattern, file.flat).map { file.line($0) }
            let verdict = route(
                probeLines: probe, choiceLines: choices, downloadLines: downloads,
                gated: foundationModelsGatedLines(file.code))
            switch verdict {
            case .irrelevant: break
            case .guarded: guarded.append(file.path)
            case .foundationModelsOnly: fmOnly.append(file.path)
            case .ungarded:
                ungarded.append("\(file.path):\(choices + downloads)")
            }
        }
        #expect(ungarded.isEmpty, "an ungarded hub fallback is back on a live route — \(ungarded)")
        #expect(
            guarded == [home],
            "exactly the loader with the fallback may fall back after asking: \(guarded)")
        #expect(
            fmOnly == [fmOnlyRoute],
            "the FM/macOS-27 duplicate is registered in AGENTS.md § Open — a change here means the register is stale: \(fmOnly)"
        )
    }
}
