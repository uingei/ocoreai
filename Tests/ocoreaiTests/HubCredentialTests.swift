// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// HubCredentialTests.swift — the credential a hub request carries, and what a refusal says.
///
/// Why this has a gate: three sites used to write `if let token { "Bearer \(token)" }`, which
/// checks for nil and not for usable. The shapes that came out of that — `Bearer ` for a
/// whitespace-only stored token, a CR/LF inside the value from `MODELSCOPE_TOKEN="$(cat t.txt)"`,
/// and a 401 reported as `ModelScope API request failed: Optional<NSHTTPURLResponse>` with no
/// statement of whether a token was even sent — are all silent. Every assertion below is an exact
/// value, and every traversal floors its own size so a shrunk loop cannot pass
/// (AGENTS.md invariant 1).
///
/// No network here: the header is built by the same resolution the search client and the
/// downloader call, so the *decision* is pinnable as a value. What a live hub answers with is
/// probe territory, and is stated as not-covered rather than implied.

import Foundation
import Testing

@testable import ocoreai

/// The one way these tests obtain a `HubCredential`: its initialiser validates, so a token
/// here comes from the same classification the production call sites use.
private func credential(_ raw: String) throws -> HubCredential {
    try #require(HubCredentialResolution.classify(rawValue: raw).credential)
}

private func isAvailable(_ resolution: HubCredentialResolution) -> Bool {
    if case .available = resolution { return true }
    return false
}

private func isUnusable(_ resolution: HubCredentialResolution) -> Bool {
    if case .unusable = resolution { return true }
    return false
}

// MARK: - Classification

@Suite("HubCredentialResolution — one verdict per configured value")
struct HubCredentialClassificationTests {

    /// Everything a Settings field or an environment variable can hold, with the verdict it must
    /// produce. The two paste artifacts are the reason the type exists.
    @Test("every shape resolves to exactly one verdict, including the paste artifacts")
    func classifyEveryShape() throws {
        let token = try credential("ms-abc123")
        let cases: [(raw: String?, expected: HubCredentialResolution)] = [
            (nil, .absent),
            ("", .unusable(.blank)),
            ("   ", .unusable(.blank)),
            (" \t\n ", .unusable(.blank)),
            (" ms-abc123\n", .available(token)),
            ("ms-abc123", .available(token)),
            // Inside the value, whitespace is not a token character: refusing beats sending
            // something the caller never configured.
            ("ms abc", .unusable(.malformed)),
            ("ms-abc\r\nX-Injected: 1", .unusable(.malformed)),
            ("ms-abc\u{0000}", .unusable(.malformed)),
            ("ms-\u{4E2D}\u{6587}", .unusable(.malformed)),
        ]
        for testCase in cases {
            #expect(
                HubCredentialResolution.classify(rawValue: testCase.raw) == testCase.expected,
                "raw=\(String(describing: testCase.raw))")
        }
        // Floors: a classification that silently degenerated to one answer proves nothing.
        let verdicts = cases.map { HubCredentialResolution.classify(rawValue: $0.raw) }
        #expect(verdicts.count == 10)
        #expect(verdicts.filter(isAvailable).count == 2)
        #expect(verdicts.filter { $0 == .absent }.count == 1)
        #expect(verdicts.filter(isUnusable).count == 7)
    }

    @Test("the size ceiling prices a pasted blob, and the boundary is exact")
    func sizeCeilingIsExact() throws {
        let atLimit = String(repeating: "a", count: HubCredential.maxTokenCharacters)
        #expect(try credential(atLimit).token == atLimit)
        #expect(
            HubCredentialResolution.classify(rawValue: atLimit + "b") == .unusable(.oversized),
            "the ceiling is inclusive; one character past it is a blob")
        #expect(HubCredential.maxTokenCharacters == 4096)
    }

    /// The invariant the type exists for, asserted over every accepted value rather than one.
    @Test("headerValue is never partial, never split, and never keeps the pasted edges")
    func headerValueAlwaysComplete() throws {
        let accepted: [String] = [
            "ms-abc123", "  ms-abc123  ", "\nms-abc123\r\n", "hf_Ab1-._~+/",
            "eyJhbGciOi.eyJzdWIiOiIxIn0.c", String(repeating: "a", count: 4096),
        ]
        for raw in accepted {
            let value = try #require(HubCredentialResolution.classify(rawValue: raw).headerValue)
            #expect(value.hasPrefix("Bearer "))
            #expect(
                !value.contains("\r"), "a CR would end the header line: \(value.debugDescription)")
            #expect(
                !value.contains("\n"), "an LF would end the header line: \(value.debugDescription)")
            #expect(value != "Bearer", "a scheme with nothing after it is not authentication")
            #expect(value.count > "Bearer ".count)
            // Exactly the scheme separator, and nothing but printable ASCII after it: a second
            // space would end the token where the server reads it, a control character would
            // end the header line.
            #expect(value.filter { $0 == " " }.count == 1, "one separating space, never two")
            #expect(
                value.dropFirst("Bearer ".count).unicodeScalars.allSatisfy {
                    $0.value >= 0x21 && $0.value <= 0x7E
                },
                "the credential itself must be printable ASCII: \(value.debugDescription)")
        }
    }

    @Test("firstIllegalCharacter names the offending character and accepts real token shapes")
    func illegalCharacterDetection() {
        #expect(HubCredential.firstIllegalCharacter(in: "ms-abc_123.~+/=") == nil)
        #expect(HubCredential.firstIllegalCharacter(in: "a b") == " ")
        #expect(HubCredential.firstIllegalCharacter(in: "ab\u{0007}") == "\u{0007}")
        #expect(HubCredential.firstIllegalCharacter(in: "\u{4E2D}") != nil)
        #expect(HubCredential.firstIllegalCharacter(in: "") == nil)
    }
}

// MARK: - Resolution precedence

@Suite("HubCredentialResolution — env first, never a silent substitution")
struct HubCredentialResolutionTests {

    @Test("env wins over the stored value, per provider")
    func envBeatsStored() throws {
        let env = ["MODELSCOPE_TOKEN": "env-token", "HF_TOKEN": "hf-token"]
        #expect(
            HubCredentialResolution.resolve(source: .modelScope, env: env, stored: "saved")
                .credential?.token == "env-token")
        #expect(
            HubCredentialResolution.resolve(source: .huggingFace, env: env, stored: "saved")
                .credential?.token == "hf-token",
            "the other provider's variable must not answer for this one")
    }

    @Test("a stored value answers when the environment says nothing")
    func storedAnswersWhenEnvSilent() throws {
        #expect(
            HubCredentialResolution.resolve(source: .modelScope, env: [:], stored: "saved-token")
                == .available(try credential("saved-token")))
        #expect(
            HubCredentialResolution.resolve(source: .modelScope, env: [:], stored: nil) == .absent)
    }

    /// The deliberate choice, priced: an env var that is present but blank is refused rather
    /// than quietly replaced by the Settings token. Silent substitution would make
    /// `MODELSCOPE_TOKEN=""` — a runner's way of saying "no credentials here" — mean "use the
    /// token saved on this Mac", the one reading that variable must ever have.
    @Test("a blank env value is named, not swapped for the stored token")
    func blankEnvIsNotSilentlyReplaced() {
        let resolved = HubCredentialResolution.resolve(
            source: .modelScope, env: ["MODELSCOPE_TOKEN": "  "], stored: "saved-token")
        #expect(resolved == .unusable(.blank))
        #expect(resolved.credential == nil)
        #expect(
            resolved.stateText(source: .modelScope)
                == "no credential was offered (the configured value is blank (whitespace only))")
    }

    @Test("stateText states the measured credential state, one clause per case")
    func stateTextCoversEveryState() throws {
        #expect(
            HubCredentialResolution.available(try credential("tok")).stateText(source: .modelScope)
                == "an access token was offered")
        #expect(
            HubCredentialResolution.absent.stateText(source: .modelScope)
                == "no credential was offered (neither MODELSCOPE_TOKEN nor the Settings token is set)"
        )
        #expect(
            HubCredentialResolution.absent.stateText(source: .huggingFace).contains("HF_TOKEN"),
            "advice must name the variable this provider reads")
        let malformed = HubCredentialResolution.classify(rawValue: "a b").stateText(
            source: .modelScope)
        #expect(malformed.hasPrefix("no credential was offered ("))
        #expect(malformed.contains("whitespace or non-printable characters"))
    }
}

// MARK: - Refusal

/// Status codes for the agreement traversal, declared next to the test that walks them.
enum HubRejectionTestStatuses {
    static let all: [Int] = [
        301, 400, 401, 402, 403, 404, 407, 408, 409, 416, 429, 500, 501, 502, 503, 504, 599,
    ]
}

@Suite("HubRejection — what a hub refusal means, and what it says")
struct HubRejectionTests {

    private static let statuses = [
        200, 201, 204, 299, 301, 400, 401, 403, 404, 408, 409, 429, 500, 502, 503, 504, 599,
    ]

    @Test("a 2xx is not a refusal, and every other status is")
    func onlyNonSuccessIsARefusal() {
        let offered = HubCredentialResolution.classify(rawValue: "tok")
        var accepted = 0
        var refused = 0
        for status in Self.statuses {
            let rejection = HubRejection.classify(
                statusCode: status, credential: offered, source: .modelScope)
            if (200 ... 299).contains(status) {
                #expect(rejection == nil, "HTTP \(status) is success, not a refusal")
                accepted += 1
            } else {
                #expect(rejection?.statusCode == status)
                refused += 1
            }
        }
        #expect(accepted == 4, "the traversal stopped covering success codes")
        #expect(refused == 13, "the traversal stopped covering failures")
    }

    /// Two homes decide one question: `isRetryable(statusCode:)` decides whether to send again,
    /// `HubRejection` decides whether to call it transient. If they disagree, the advice tells
    /// the user to wait while the retry loop never does (or the reverse) — so the two are
    /// traversed together instead of trusted to agree.
    @Test(arguments: HubRejectionTestStatuses.all)
    func HubRejectionAgreesWithRetryClassifier(_ status: Int) {
        let offered = HubCredentialResolution.classify(rawValue: "tok")
        guard
            let rejection = HubRejection.classify(
                statusCode: status, credential: offered, source: .modelScope)
        else {
            Issue.record("HTTP \(status) vanished from the classifier")
            return
        }
        #expect(
            rejection.isTransient == isRetryable(statusCode: status),
            "HTTP \(status): advice says \(rejection.kind.rawValue) while the retry loop disagrees")
    }

    @Test("401 and 403 are the credential kinds, and neither is transient")
    func authStatusesAreTerminalCredentialKind() {
        let offered = HubCredentialResolution.classify(rawValue: "tok")
        #expect(
            HubRejection.classify(statusCode: 401, credential: offered, source: .modelScope)?.kind
                == .credentialRefused)
        #expect(
            HubRejection.classify(statusCode: 403, credential: offered, source: .modelScope)?.kind
                == .accessDenied)
        #expect(
            HubRejection.classify(statusCode: 401, credential: offered, source: .modelScope)?
                .isTransient == false)
    }

    @Test("advice names whether a credential was offered — and never contains the token")
    func adviceIsHonestAndLeakFree() throws {
        let secret = "ms-SUPERSECRETtoken123"
        let offeredAdvice = try #require(
            HubRejection.classify(
                statusCode: 401, credential: .classify(rawValue: secret), source: .modelScope)?
                .advice)
        #expect(offeredAdvice.contains("ModelScope refused authentication (HTTP 401)"))
        #expect(offeredAdvice.contains("an access token was offered and refused"))
        #expect(offeredAdvice.contains("MODELSCOPE_TOKEN"))
        #expect(!offeredAdvice.contains(secret), "advice is user-visible text: never the secret")

        let absentAdvice = try #require(
            HubRejection.classify(statusCode: 403, credential: .absent, source: .modelScope)?.advice
        )
        #expect(absentAdvice.contains("denied access"))
        #expect(absentAdvice.contains("no credential was offered"))

        let unusableAdvice = try #require(
            HubRejection.classify(
                statusCode: 401, credential: .classify(rawValue: "bad token"), source: .huggingFace)?
                .advice)
        #expect(unusableAdvice.contains("no credential was offered"))
        #expect(unusableAdvice.contains("HF_TOKEN"))

        // A 404 is not an auth problem: quoting a credential clause there trains the reader to
        // skip the half that matters.
        let missingAdvice = try #require(
            HubRejection.classify(statusCode: 404, credential: .absent, source: .modelScope)?.advice
        )
        #expect(missingAdvice.contains("returned HTTP 404"))
        #expect(!missingAdvice.contains("credential"), "404 must not read as an auth failure")
    }

    @Test("the downloader's error text carries repo, status and advice in that order")
    func downloaderErrorText() {
        let rejection = HubRejection.classify(
            statusCode: 401, credential: .classify(rawValue: "tok"), source: .modelScope)
        let text = DownloaderError.credentialRejected(
            repoId: "Qwen/My-Gated", statusCode: 401, advice: rejection?.advice ?? ""
        )
        .localizedDescription
        #expect(text.hasPrefix("ModelScope refused access to 'Qwen/My-Gated' (HTTP 401): "))
        #expect(text.contains("an access token was offered and refused"))
        // Terminal by construction in `withRetry` (only apiError/downloadFailed retry), and the
        // status classifier must say the same thing out loud.
        #expect(isRetryable(statusCode: 401) == false)
        #expect(isRetryable(statusCode: 403) == false)
    }

    @Test("the search client's refusal reads as a status plus advice, not a response object")
    func searchClientErrorText() {
        #expect(
            MSError.refused(statusCode: 403, advice: "no credential was offered")
                .localizedDescription
                == "ModelScope API request failed (HTTP 403) — no credential was offered")
        #expect(
            MSError.refused(statusCode: 0, advice: nil).localizedDescription
                == "ModelScope API request failed (HTTP 0)")
    }
}

// MARK: - Provider identity

@Suite("HubSource identity — the variables advice names are the ones the app reads")
struct HubSourceCredentialIdentityTests {

    /// Advice tells the user to set `MODELSCOPE_TOKEN`. That sentence is only true if this
    /// process really reads that variable — and reads it **once**. Two spellings of
    /// `env["MODELSCOPE_TOKEN"] ?? stored` is how "env vars take precedence" (a promise the
    /// Settings UI makes in its own label text) starts meaning different things on different
    /// surfaces: the startup path and `SettingsStore` each carried their own copy until 10-21.
    /// So the scan asserts both halves — the variable is read somewhere, and it is read in
    /// exactly one file, the precedence home — and proves it can see a hit at all before it is
    /// allowed to report zero (CONTRIBUTING: a gate asserts its own premises).
    @Test("each env var is named in exactly one file, and read by exactly one expression")
    func envVarIsReadOnce() throws {
        let root = try hubCredentialRepoRoot()
        let files = try hubCredentialSwiftFiles(root: root)
        let home = "Sources/ocoreai/Models/HubCredential.swift"
        // Positive controls, both directions: the scanner must find a literal read it is meant
        // to forbid, and must find the name where it is allowed. Without these, "0 offenders"
        // and "exactly 1 home" are both satisfiable by a needle that matches nothing.
        #expect(
            HubCredentialTestScan.count(
                #"environment["MODELSCOPE_TOKEN"]"#,
                in: #"let t = ProcessInfo.processInfo.environment["MODELSCOPE_TOKEN"] ?? u"#) == 1,
            "the scan cannot see a literal env read — every zero it reports is meaningless")
        #expect(
            HubCredentialTestScan.count(
                "MODELSCOPE_TOKEN", in: #"case .modelScope: return "MODELSCOPE_TOKEN""#) == 1)
        #expect(
            HubCredentialTestScan.count(
                "env[source.envVar]",
                in: try String(contentsOf: root.appendingPathComponent(home), encoding: .utf8))
                == 1,
            "precedence() no longer reads the environment through the provider's own name")
        var scannedFiles = 0
        for source in HubSource.allCases {
            var nameHomes: [String: Int] = [:]
            var directReads: [String] = []
            for file in files {
                let text = try String(
                    contentsOf: root.appendingPathComponent(file), encoding: .utf8)
                let named = HubCredentialTestScan.count("\"\(source.envVar)\"", in: text)
                if named > 0 { nameHomes[file] = named }
                if HubCredentialTestScan.count("environment[\"\(source.envVar)\"]", in: text) > 0 {
                    directReads.append(file)
                }
                scannedFiles += 1
            }
            #expect(
                nameHomes == [home: 1],
                "\(source.envVar) is declared in \(nameHomes) — a second declaration is a second truth about where a token comes from"
            )
            #expect(
                directReads.isEmpty,
                "\(source.envVar) is read directly in \(directReads) — bypassing precedence() lets the startup path and the Settings surface disagree about which value wins"
            )
            #expect(source.envVar.uppercased() == source.envVar)
            #expect(!source.envVar.contains(" "))
        }
        #expect(HubSource.allCases.count == 2)
        #expect(
            scannedFiles >= 200,
            "the scan covered \(scannedFiles) Sources files; a scan that shrank cannot prove singleness"
        )
    }

    /// The other half of "one home": callers ask instead of re-spelling. A site that reads
    /// `UserDefaults` for a hub token by literal key name is a second storage truth, so the
    /// startup path must route through `precedence` + `HubSource.userDefaultsKey`.
    @Test("token read sites call the shared rule, and the storage key has one home")
    func readSitesRouteThroughTheSharedRule() throws {
        let root = try hubCredentialRepoRoot()
        var precedenceSites = 0
        var resolveSites = 0
        // file -> the token keys it re-spells, for the failure message.
        var spelledKeys: [String: [String]] = [:]
        // Positive control for the needle below: the same scan must find each declared key
        // where it is declared, or "zero elsewhere" means the scan stopped matching.
        var foundAtTheDeclaringStore = 0
        let storeFile = "Sources/ocoreai/UI/ViewModels/SettingsStore.swift"
        let tokenKeys = HubSource.allCases.map { "\"\($0.userDefaultsKey)\"" }
        for file in try hubCredentialSwiftFiles(root: root) {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            precedenceSites += HubCredentialTestScan.count(
                "HubCredentialResolution.precedence(", in: text)
            resolveSites += HubCredentialTestScan.count(
                "HubCredentialResolution.resolve(source:", in: text)
            let declaringHomes: Set<String> = [
                "Sources/ocoreai/Models/HubCredential.swift",
                storeFile,
            ]
            if file == storeFile {
                foundAtTheDeclaringStore = HubCredentialTestScan.countAll(tokenKeys, in: text)
            }
            if !declaringHomes.contains(file) {
                let hits = tokenKeys.filter { HubCredentialTestScan.count($0, in: text) > 0 }
                if !hits.isEmpty {
                    spelledKeys[file] = hits
                }
            }
        }
        // 2 (SettingsStore getters) + 2 (startup path, both server and UI shapes).
        #expect(
            precedenceSites >= 4,
            "only \(precedenceSites) site(s) consult precedence(); the rule was re-spelled somewhere"
        )
        // 3 wire-edge sites: downloader, search client, config fetcher.
        #expect(
            resolveSites >= 3,
            "only \(resolveSites) wire site(s) resolve() a credential — a partial token could reach the header through a site that never asked"
        )
        // The needle sees what it claims to see before "0 elsewhere" is allowed to mean anything.
        #expect(
            foundAtTheDeclaringStore >= HubSource.allCases.count,
            "the scan found \(foundAtTheDeclaringStore) of \(HubSource.allCases.count) persisted token keys in \(storeFile) — the declaring store must name each key it stores"
        )
        // `SettingsStore.Key` declares the persisted names and `HubSource.userDefaultsKey`
        // restates them for the advice text; the third test pins that the two agree. Anything
        // else quoting one is a third truth about where a token is stored. Scoped to the token
        // keys and not to the `settings.hub.` prefix: that prefix also carries
        // `useHFMirror`, whose one home is `Config/HFMirrorPolicy.swift` (`persistedKey`,
        // pinned against `SettingsStore.Key.useHFMirror.rawValue` by HFMirrorPolicyTests) —
        // a different lever, not a second token store.
        #expect(
            spelledKeys.isEmpty,
            "\(spelledKeys) file(s) beyond the declaring pair re-spell a persisted token key"
        )
    }

    /// The advice text and the persisted name must be the same string, or "set it in Settings"
    /// points at a key this process never reads.
    @Test("userDefaultsKey is the name SettingsStore actually stores under")
    func userDefaultsKeyMatchesTheStore() throws {
        let root = try hubCredentialRepoRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/ocoreai/UI/ViewModels/SettingsStore.swift"),
            encoding: .utf8)
        for source in HubSource.allCases {
            #expect(
                HubCredentialTestScan.count("\"\(source.userDefaultsKey)\"", in: store) >= 1,
                "\(source.userDefaultsKey) is the declared key but SettingsStore never names it")
            #expect(source.userDefaultsKey.hasPrefix("settings.hub."))
        }
    }

    /// Every `.swift` under `Sources/` — the scan's own domain, so a moved file cannot hide a
    /// second read site by falling outside a hardcoded two-file list.
    private func hubCredentialSwiftFiles(root: URL) throws -> [String] {
        let base = root.appendingPathComponent("Sources")
        guard
            let enumerator = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw HubCredentialScanFailure(path: base.path)
        }
        var files: [String] = []
        let prefix = root.path + "/"
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(String(url.path.dropFirst(prefix.count)))
        }
        return files.sorted()
    }
}

/// The counting primitive, factored out so a test can point it at a synthetic sample and prove
/// it finds what it claims to find before trusting it with the tree.
private enum HubCredentialTestScan {
    static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// How many of `needles` occur at least once in `text` — the count of *distinct keys
    /// present*, which is what a positive control needs (occurrences would pass on one key
    /// written twice).
    static func countAll(_ needles: [String], in text: String) -> Int {
        needles.filter { count($0, in: text) > 0 }.count
    }
}

/// Resolves the repo root by walking up until a known file appears — a fixed
/// `deletingLastPathComponent()` hop count lands on `Tests/`, where every scan "passes" on ENOENT.
private func hubCredentialRepoRoot() throws -> URL {
    let marker = "Sources/ocoreai/Models/HubCredential.swift"
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0 ..< 6 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(marker).path) {
            return dir
        }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    throw HubCredentialScanFailure(path: "\(dir.path)/\(marker)")
}

struct HubCredentialScanFailure: Error, CustomStringConvertible {
    let path: String
    var description: String { "no repo file at \(path) (walked up from \(#filePath))" }
}
