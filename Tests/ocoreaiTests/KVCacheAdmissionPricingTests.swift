// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Admission pricing — a reservation must be priced by the model it reserves for.
///
/// `Scheduler/KVCacheBudget.swift` reserved 1024 B/token for every model on every request, a
/// number carried over from a weight-quantization heuristic. Probe 35 measures the default
/// checkpoint at 10,475 B/token (33,123,328 bytes across 3,162 tokens), so the gate under-reserved
/// 10× and admitted turns the engine then could not hold: the arithmetic that turns a budget check
/// into an OOM. Now `KVCachePriceLedger` prices a model from its own resident cache, the gate
/// consumes that price, and every decision says which basis it used.
///
/// The floor stays, and stays honest: an unpriced model still reserves at 1024 B/token and reports
/// `fallback`, so "we do not know this model's price" is visible instead of being a 10× bet.

import Foundation
import Testing

@testable import ocoreai

@Suite("Admission pricing — reserve at the measured price, say which basis")
struct KVCacheAdmissionPricingTests {

    /// The measured pair probe 35 prints for `mlx-community/gemma-4-e2b-it-4bit`.
    private static let measuredBytes = 33_123_328
    private static let measuredTokens = 3_162
    private static let measuredPrice = 10_475

    @Test("the ledger prices a token by floor division of the same pair the endpoint publishes")
    func ledgerPriceIsTheProbedQuotient() async {
        let modelId = "pricing-test/quotient"
        await KVCachePriceLedger.shared.record(
            modelId: modelId,
            residentBytes: Self.measuredBytes,
            processedTokens: Self.measuredTokens)
        defer { Task { await KVCachePriceLedger.shared.forget(modelId: modelId) } }

        #expect(await KVCachePriceLedger.shared.price(modelId: modelId) == Self.measuredPrice)
        #expect(Self.measuredBytes / Self.measuredTokens == Self.measuredPrice)
    }

    @Test(
        "incomplete measurements never become a price",
        arguments: [
            (bytes: 0, tokens: 3_162),
            (bytes: Self.measuredBytes, tokens: 0),
        ])
    func ledgerRefusesPartialMeasurements(bytes: Int, tokens: Int) async {
        let modelId = "pricing-test/partial-\(bytes)-\(tokens)"
        await KVCachePriceLedger.shared.record(
            modelId: modelId, residentBytes: bytes, processedTokens: tokens)
        defer { Task { await KVCachePriceLedger.shared.forget(modelId: modelId) } }

        #expect(await KVCachePriceLedger.shared.price(modelId: modelId) == nil)
    }

    @Test("precedence: unpriced → measured → unpriced again once the weights are gone")
    func precedenceMeasuredThenForget() async {
        let gate = AdmissionGate(memoryTracker: nil)
        let modelId = "pricing-test/precedence"
        defer { Task { await KVCachePriceLedger.shared.forget(modelId: modelId) } }

        let cold = await gate.effectiveBytesPerToken(modelId: modelId)
        #expect(cold.price == KVCacheBudget.bytesPerToken)
        #expect(cold.basis == AdmissionResult.unpricedBasis)

        await KVCachePriceLedger.shared.record(
            modelId: modelId,
            residentBytes: Self.measuredBytes,
            processedTokens: Self.measuredTokens)
        let warm = await gate.effectiveBytesPerToken(modelId: modelId)
        #expect(warm.price == UInt64(Self.measuredPrice))
        #expect(warm.basis == AdmissionResult.measuredBasis)

        // A reload may be a different checkpoint, so the price earned by the old weights dies
        // with them rather than pricing the next model that borrows the id.
        await KVCachePriceLedger.shared.forget(modelId: modelId)
        let reloaded = await gate.effectiveBytesPerToken(modelId: modelId)
        #expect(reloaded.price == KVCacheBudget.bytesPerToken)
        #expect(reloaded.basis == AdmissionResult.unpricedBasis)
    }

    @Test("a priced model reserves exactly its tokens at its own price")
    func admitReservesAtMeasuredPrice() async {
        let gate = AdmissionGate(memoryTracker: nil)
        let modelId = "pricing-test/reserve"
        await KVCachePriceLedger.shared.record(
            modelId: modelId,
            residentBytes: Self.measuredBytes,
            processedTokens: Self.measuredTokens)
        defer { Task { await KVCachePriceLedger.shared.forget(modelId: modelId) } }

        // The probe's own turn shape: 3,160 prompt tokens + 8 output tokens.
        await gate.admit("r-measured", inputTokens: 3_160, maxOutputTokens: 8, modelId: modelId)
        let state = await gate.state()
        #expect(state.reserved == UInt64(3_168 * Self.measuredPrice))

        // Same request, no priced model: the floor, and a decision that says so.
        let fallback = await gate.check(
            requestId: "r-unpriced",
            inputTokens: 3_160,
            maxOutputTokens: 8,
            modelId: "pricing-test/never-priced")
        #expect(fallback.kvBytesPerToken == KVCacheBudget.bytesPerToken)
        #expect(fallback.pricingBasis == AdmissionResult.unpricedBasis)
        #expect(
            Double(fallback.estimatedCostMB)
                == Double(UInt64(3_168 * Int(KVCacheBudget.bytesPerToken))) / (1024 * 1024))
    }

    @Test("a refusal states the price it reserved at, not just the shortfall")
    func rejectionCarriesItsBasis() async {
        let budget = UInt64(1) << 30  // 1 GiB cap
        let tracker = MemoryTracker(budgetBytes: budget, systemUsageOverride: { 60 << 30 })
        let gate = AdmissionGate(
            maxConcurrentPreFills: 16, memoryTracker: tracker)
        let modelId = "pricing-test/rejection"
        await KVCachePriceLedger.shared.record(
            modelId: modelId,
            residentBytes: Self.measuredBytes,
            processedTokens: Self.measuredTokens)
        defer { Task { await KVCachePriceLedger.shared.forget(modelId: modelId) } }

        // 100k tokens cost 1.0 GiB at the measured price, 102 MiB at the floor: the refusal the
        // floor never produced is exactly the one under-pricing hid.
        let result = await gate.check(
            requestId: "r-big",
            inputTokens: 50_000,
            maxOutputTokens: 50_000,
            modelId: modelId)
        #expect(!result.admitted)
        #expect(result.reason?.contains("Budget") ?? false)
        #expect(result.kvBytesPerToken == UInt64(Self.measuredPrice))
        #expect(result.pricingBasis == AdmissionResult.measuredBasis)
        #expect(
            result.estimatedCostMB
                == Double(UInt64(100_000 * Self.measuredPrice)) / (1024 * 1024))

        // And the same request at the floor still fits — the gate's answer is the price's answer.
        let sameAtFloor = await gate.check(
            requestId: "r-big-fallback",
            inputTokens: 50_000,
            maxOutputTokens: 50_000)
        #expect(sameAtFloor.admitted)
        #expect(sameAtFloor.pricingBasis == AdmissionResult.unpricedBasis)
    }

    @Test("a zero price cannot buy admission: the floor is the unknown's price")
    func budgetFloorsZeroPrice() {
        #expect(KVCacheBudget.bytes(3_168, bytesPerToken: 0) == UInt64(3_168 * 1_024))
        #expect(
            KVCacheBudget.bytes(3_168, bytesPerToken: UInt64(Self.measuredPrice))
                == UInt64(3_168 * Self.measuredPrice))
        #expect(KVCacheBudget.bytes(-5, bytesPerToken: UInt64(Self.measuredPrice)) == 0)
        #expect(KVCacheBudget.bytesPerToken == 1024)
    }

    @Test(
        "the dispatcher asks for the model's price at both seams, and never at the floor",
        arguments: [
            ("Sources/ocoreai/Scheduler/SchedulerActor.swift", "modelId: request.modelId", 2),
            ("Sources/ocoreai/Scheduler/AdmissionGate.swift", "effectiveBytesPerToken(modelId:", 2),
        ])
    func pricingIsWiredWhereTheDecisionHappens(
        _ relativePath: String, _ needle: String, _ floor: Int
    ) throws {
        let root = try Self.repoRoot()
        let text = try String(
            contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        let hits = text.split(separator: "\n").filter { $0.contains(needle) }
        #expect(
            hits.count >= floor,
            "\(relativePath) no longer contains \(needle) \(floor)x — pricing was cut off the path")

        if relativePath.hasSuffix("SchedulerActor.swift") {
            // The dispatcher's own reservation must carry the gate's price: the unpriced overload
            // back on this line would put the 10× bet back into the memory tracker's ledger.
            let unpriced = text.split(separator: "\n").filter {
                $0.contains("KVCacheBudget.bytes(request.tokenBudget)")
            }
            #expect(unpriced.isEmpty, "dispatcher reserves at the floor again: \(unpriced)")
        }
    }

    private static func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path)
            {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        struct NoRoot: Error, CustomStringConvertible {
            var description: String { "no package root above \(#filePath)" }
        }
        throw NoRoot()
    }
}
