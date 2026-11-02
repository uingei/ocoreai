// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Why a gate here: `/v1/models` gained `loadProgress` and the 503 `model_loading` body gained
/// the same measurement, on the strength of a measured wait — the shipping default checkpoint is
/// 3 550 670 554 B and fetched in 794 s at 4.5 MB/s while a waiter was released at the 120 s
/// window with nothing but "still loading" (CHANGELOG 11-01(101)). A field that says how far a
/// load has come is exactly the surface that rots silently: read the store under the wrong key
/// and it reports silence as absence, extrapolate an ETA off one sample and it publishes a guess
/// wearing a number, leave a clock behind after the slot frees and an idle pool keeps counting
/// seconds for a load that ended. Every assertion below is against a value a caller can observe
/// on the wire, not against the code that produced it.
///
/// The store is injected (`OcoreaiDownloadProgress(forTesting:)`) rather than seeded through
/// `.shared`: the real store is process-global, and a suite that writes it to test a reader races
/// every suite that reads it.

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing

@testable import ocoreai

@Suite("ModelLoadProgress — the load wait discloses only what it measured")
struct ModelLoadProgressHonestyTests {

    // MARK: - Fixtures

    private func emptyStore() -> OcoreaiDownloadProgress {
        OcoreaiDownloadProgress(forTesting: ())
    }

    /// A store tracking one transfer for `id`, with a second sample when the test needs a
    /// measured rate (throughput needs two samples spanning > 0.1 s, so this sleeps one).
    private func store(
        tracking id: String,
        completed: Int64,
        total: Int64,
        advancing: Bool = false,
    ) async throws -> OcoreaiDownloadProgress {
        let store = OcoreaiDownloadProgress(forTesting: ())
        store.start(modelId: id)
        store.updateBytes(completed: completed, total: total, for: id)
        if advancing {
            try await Task.sleep(for: .milliseconds(250))
            store.updateBytes(completed: completed + 4_000_000, total: total, for: id)
        }
        return store
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: - What measure() is allowed to say

    @Test("a load that has reported nothing says the wait, and invents nothing else")
    func reportsNothingAsNothing() throws {
        let measured = ModelLoadProgress.measure(
            modelId: "test/quiet", enteredAt: .now, store: emptyStore())
        #expect(measured.elapsedSeconds == 0)
        #expect(!measured.downloading, "an untracked id is not a transfer in flight")
        // Absent, not zero: `0 B of 0 B at 0 B/s` reads as a stalled fetch, and the reader
        // cannot tell that from a load that never entered the downloader.
        #expect(measured.bytesDownload == nil)
        #expect(measured.bytesTotal == nil)
        #expect(measured.bytesPerSecond == nil)
        #expect(measured.secondsRemainingEstimate == nil)
        #expect(
            measured.disclosureLine == "0s elapsed, weights on disk, no transfer in flight",
            "the negative is a sentence the caller can act on: \(measured.disclosureLine)")
    }

    @Test("the downloader keys on the prefix-stripped id — every source spelling resolves")
    func everySourceSpellingResolves() async throws {
        // `MLXBridge.loadFromHub` starts the store entry on the stripped repo id so the GUI can
        // query it; a reader that asked with the engine's prefixed id found nothing and published
        // that silence.
        let store = try await store(tracking: "org/x", completed: 1_234, total: 4_000)
        for spelling in ["org/x", "hf:org/x", "huggingface:org/x", "mscope:org/x"] {
            let measured = ModelLoadProgress.measure(
                modelId: spelling, enteredAt: .now, store: store)
            #expect(
                measured.bytesDownload == 1_234,
                "`\(spelling)` resolved to nothing — the disclosure would report silence")
        }
    }

    @Test("an ETA needs a rate AND a declared total; either one absent and it stays absent")
    func etaNeedsBothNumbers() async throws {
        // Total declared, no rate: the HF lane polls the cache directory, so the first tick
        // knows the size and nothing about speed.
        let sizeOnly = ModelLoadProgress.measure(
            modelId: "org/x", enteredAt: .now,
            store: try await store(tracking: "org/x", completed: 1_000, total: 9_000))
        #expect(sizeOnly.bytesTotal == 9_000)
        #expect(sizeOnly.secondsRemainingEstimate == nil, "an ETA off one sample is a guess")

        // Rate measured, no size declared: `totalBytes` is 0 before the first report, and a 0
        // total would otherwise publish as "0 B expected, ~0s remaining".
        let rateOnly = ModelLoadProgress.measure(
            modelId: "org/x", enteredAt: .now,
            store: try await store(
                tracking: "org/x", completed: 1_000_000, total: 0, advancing: true))
        #expect(rateOnly.bytesPerSecond != nil, "fixture did not produce a measured rate")
        #expect(rateOnly.bytesTotal == nil, "an undeclared size must not arrive as 0")
        #expect(rateOnly.secondsRemainingEstimate == nil)
        #expect(
            rateOnly.disclosureLine.contains("\(rateOnly.bytesDownload!) B")
                && !rateOnly.disclosureLine.contains("of 0 B"),
            "the byte count publishes without a fake denominator: \(rateOnly.disclosureLine)")
        #expect(
            !sizeOnly.disclosureLine.contains("~") && !rateOnly.disclosureLine.contains("~"),
            "an unearned ETA reached the sentence")
    }

    @Test("with both numbers present the ETA is the remaining bytes over the measured rate")
    func etaIsRemainingOverMeasuredRate() async throws {
        let measured = ModelLoadProgress.measure(
            modelId: "org/x", enteredAt: .now,
            store: try await store(
                tracking: "org/x", completed: 1_000_000, total: 3_550_670_554, advancing: true))
        let total = try #require(measured.bytesTotal)
        let done = try #require(measured.bytesDownload)
        let rate = try #require(measured.bytesPerSecond)
        let eta = try #require(measured.secondsRemainingEstimate, "two measured numbers, no ETA")
        #expect(rate > 0)
        // Exact value, derived from the two numbers this measurement itself reports — never a
        // constant copied from the code under test. Rounded up: an ETA that under-states the
        // wait sends the caller back early.
        #expect(
            eta == Int((Double(total - done) / Double(rate)).rounded(.up)),
            "ETA \(eta) is not remaining/rate for \(done)/\(total) at \(rate)")
        #expect(measured.disclosureLine.contains("~\(eta)s remaining"))
    }

    @Test("a finished transfer stops being reported as one in flight")
    func finishedTransferIsNotInFlight() async throws {
        let store = try await store(tracking: "org/x", completed: 9_000, total: 9_000)
        store.finish(modelId: "org/x", success: true)
        let measured = ModelLoadProgress.measure(
            modelId: "hf:org/x", enteredAt: .now, store: store)
        // `finish` evicts the entry, so the map/specialize/warm window reads as weights already on
        // disk — the honest reading — and not as bytes still landing.
        #expect(!measured.downloading)
        #expect(measured.bytesDownload == nil)
    }

    @Test("the clock starts when the id enters the slot, not when the request arrived")
    func clockIsClockedAtTheSlot() async throws {
        let entered = ContinuousClock.now
        let measured = ModelLoadProgress.measure(
            modelId: "test/clock", enteredAt: entered, store: emptyStore())
        #expect(measured.elapsedSeconds == 0, "a fresh clock must not lead the load")
        try await Task.sleep(for: .seconds(1))
        let later = ModelLoadProgress.measure(
            modelId: "test/clock", enteredAt: entered, store: emptyStore())
        #expect(
            (1 ... 3).contains(later.elapsedSeconds),
            "the wait was clocked as \(later.elapsedSeconds)s against a 1 s window")
    }

    // MARK: - The two wire shapes

    @Test("the 503 envelope carries exactly the keys this measurement backs")
    func refusalCarriesOnlyBackedKeys() async throws {
        let full = ModelLoadProgress.measure(
            modelId: "org/x", enteredAt: .now,
            store: try await store(
                tracking: "org/x", completed: 2_000_000, total: 3_550_670_554, advancing: true))
        let fullKeys = Set(full.refusalDetailKeys.keys)
        #expect(
            fullKeys.isSubset(of: [
                "downloading", "elapsed_seconds", "bytes_download", "bytes_total",
                "bytes_per_second", "seconds_remaining_estimate",
            ]),
            "a key left this type without a number behind it: \(fullKeys)")
        #expect(fullKeys.contains("downloading") && fullKeys.contains("elapsed_seconds"))
        if full.secondsRemainingEstimate != nil {
            #expect(fullKeys.contains("seconds_remaining_estimate"))
        }

        // The bare refusal: the two keys that are always true, and no byte fields a client
        // could read as an empty download.
        let quiet = ModelLoadProgress.measure(
            modelId: "test/quiet", enteredAt: .now, store: emptyStore())
        #expect(Set(quiet.refusalDetailKeys.keys) == ["downloading", "elapsed_seconds"])
        #expect(quiet.refusalDetailKeys["elapsed_seconds"] as? Int == 0)
    }

    @Test("the `/v1/models` row follows this object's camelCase and stays off every ready row")
    func dtoKeyShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let loading = ModelObject(id: "m", state: "loading")
        let quietJSON = String(data: try encoder.encode(loading), encoding: .utf8) ?? ""
        #expect(!quietJSON.contains("loadProgress"), "nil progress must not appear: \(quietJSON)")

        var withProgress = loading
        withProgress.loadProgress = ModelLoadProgress(
            elapsedSeconds: 7, downloading: false, bytesDownload: nil, bytesTotal: nil,
            bytesPerSecond: nil, secondsRemainingEstimate: nil)
        let JSON = String(data: try encoder.encode(withProgress), encoding: .utf8) ?? ""
        #expect(
            JSON.contains("\"loadProgress\":{\"downloading\":false,\"elapsedSeconds\":7}"),
            "wire keys wrong: \(JSON)")
    }

    @Test("`/v1/models` publishes the row for a load in flight, measured off the pool")
    func wireRowFromALiveRouter() async throws {
        let db = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlp_\(UUID().uuidString.prefix(8)).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: db) }

        var config = EnginePoolConfig.default
        config.defaultModelId = ""
        let pool = EnginePool(
            config: config, logger: Logger(label: "test.loadprogress.wire"),
            tokenizerManager: TokenizerManager())
        let store = SQLiteStore(path: db)
        try await store.open()
        defer { Task { try? await store.close() } }
        let fts = FTS5Search(store: store)
        let compressor = SessionCompressor(store: store, fts: fts)
        let messageBuilder = MessageBuilder(
            systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
            sessionCompressor: compressor,
            complexityAnalyzer: ComplexityAnalyzer(),
            thinkingBudget: ThinkingBudget()
        )
        let app = try await buildApplication(
            enginePool: pool,
            scheduler: SchedulerActor(
                maxQueueSize: 4, memoryTracker: nil, log: Logger(label: "test.loadprogress.wire")),
            metrics: MetricsRegistry(),
            sessionCompressor: compressor,
            semanticSearch: nil,
            mcpBridge: MCPBridge(
                toolRegistry: ToolRegistry(log: Logger(label: "test.loadprogress.wire")),
                transport: MCPStdioTransport(log: Logger(label: "test.loadprogress.wire"))),
            systemPromptBuilder: SystemPromptBuilder(basePrompt: "test"),
            messageBuilder: messageBuilder,
            logger: Logger(label: "test.loadprogress.wire"),
            authMiddleware: AuthMiddleware<OCoreAIContext>(
                config: .default, logger: Logger(label: "test.loadprogress.wire")),
            rateLimitMiddleware: RateLimitMiddleware(
                provider: RateLimitProvider(
                    config: RateLimitProvider.Config(
                        globalRate: 1000, globalBurst: 2000, perModelRate: 500, perModelBurst: 1000,
                        perIPRate: 500, perIPBurst: 1000, enabled: true),
                    logger: Logger(label: "test.loadprogress.wire")),
                logger: Logger(label: "test.loadprogress.wire")),
            hfToken: nil,
            msToken: nil
        )

        // A load slot with no downloader entry behind it — the prewarm/map/warm window, and the
        // shape a caller meets on a warm cache. Nothing here touches Metal.
        await pool.setLoadingForTesting("test/in-flight", loading: true)
        defer { Task { await pool.setLoadingForTesting("test/in-flight", loading: false) } }

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get) { response in
                #expect(response.status == .ok)
                let body =
                    response.body.getString(at: 0, length: response.body.readableBytes) ?? ""
                let rows =
                    ((try? JSONSerialization.jsonObject(with: Data(body.utf8)))
                    as? [String: Any])?["data"] as? [[String: Any]] ?? []
                let found = rows.first { ($0["id"] as? String) == "test/in-flight" }
                let row = try #require(found, "the loading row never reached the wire: \(body)")
                #expect(row["state"] as? String == "loading")
                let progress = try #require(
                    row["loadProgress"] as? [String: Any],
                    "a loading row reached the wire with no measurement attached")
                #expect(progress["downloading"] as? Bool == false)
                #expect(progress["elapsedSeconds"] is Int)
                #expect(
                    progress["bytesTotal"] == nil && progress["secondsRemainingEstimate"] == nil,
                    "the row bundled bytes it never measured: \(progress)")
                // The negative half: a ready row carrying progress would read as a load that
                // never ended, and `download_required` is not a load in flight either.
                for ready in rows where (ready["id"] as? String) != "test/in-flight" {
                    #expect(
                        ready["loadProgress"] == nil,
                        "a non-loading row published progress: \(ready)")
                }
            }
        }
    }

    // MARK: - The pool owns the clock

    @Test("the snapshot answers both spellings and drops the load when the slot frees")
    func snapshotKeysAndLifetime() async throws {
        var config = EnginePoolConfig.default
        config.defaultModelId = ""
        let pool = EnginePool(
            config: config, logger: Logger(label: "test.loadprogress.pool"),
            tokenizerManager: TokenizerManager())

        let snapshot = await pool.loadProgressSnapshot()
        #expect(snapshot.isEmpty, "an idle pool published a load it was not paying for")

        await pool.setLoadingForTesting("hf:test/clock", loading: true)
        let during = await pool.loadProgressSnapshot()
        // `/v1/models` strips the source prefix off the id it publishes; a snapshot keyed one way
        // answers nil for whichever spelling the row carries.
        #expect(during["hf:test/clock"] != nil)
        #expect(during["test/clock"] != nil)

        await pool.setLoadingForTesting("hf:test/clock", loading: false)
        let after = await pool.loadProgressSnapshot()
        #expect(after.isEmpty, "a stale clock keeps ticking: \(after.keys)")
    }

    @Test("the wait window is a policy field carrying the value it always had")
    func waitWindowIsConfigurableAtItsDefault() {
        // 120 s was hard-coded in `acquire` before it was a field; adopting the field must not
        // have moved the window, or every waiter silently changed its mind.
        #expect(EnginePoolConfig.default.loadWaitSeconds == 120)
        let fromApp = EnginePoolConfig(
            from: AppConfig(), logger: Logger(label: "test.loadprogress"))
        #expect(fromApp.loadWaitSeconds == 120)
    }
}
