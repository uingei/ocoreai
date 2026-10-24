// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// KV residency — the byte figure three surfaces publish must come from a cache, not a constant.
///
/// `/metrics` (`ocoreai_kv_cache_gpu_bytes`, `ocoreai_gpu_memory_gb`) and the dashboard's GPU
/// tile were all fed by `EnginePool.engineSummary()`, whose `gpuCacheGB` was the literal `0.0`:
/// a deployment that had allocated 31 MiB of KV still certified a zero-byte cache (probe 35,
/// repeat run for repeat). This suite pins the arithmetic, the refusal to claim on an empty
/// pool, and — because the whole point is that no constant may feed these surfaces again —
/// the absence of a hardcoded zero in the assembly that feeds them.

import Foundation
import Testing

@testable import ocoreai

@Suite("KV residency — bytes measured off the cache, never assumed")
struct KVCacheResidencyTests {
    @Test("nothing measured reads as not_observed, with no bytes and no price")
    func honestZero() {
        let subject = KVCacheResidencyObservation.notObserved
        #expect(subject.status == "not_observed")
        #expect(subject.residentBytes == 0)
        #expect(subject.residentSessions == 0)
        #expect(subject.processedTokens == 0)
        #expect(subject.bytesPerToken == nil)
    }

    @Test("the price is the quotient the probe measures, not a rounded guess")
    func measuredArithmeticIsExact() {
        // The numbers probe 35 prints for gemma-4-e2b-it-4bit at a 3160-token prompt:
        // 33,123,328 bytes across 3,162 processed tokens. Floor division, so the wire and the
        // probe cannot disagree by a rounding.
        let subject = KVCacheResidencyObservation.measured(
            residentBytes: 33_123_328,
            residentSessions: 1,
            processedTokens: 3_162)
        #expect(subject.status == "measured")
        #expect(subject.residentBytes == 33_123_328)
        #expect(subject.residentSessions == 1)
        #expect(subject.processedTokens == 3_162)
        #expect(subject.bytesPerToken == 10_475)
    }

    @Test(
        "an incomplete triple claims nothing",
        arguments: [
            (bytes: 0, sessions: 1, tokens: 1_024),
            (bytes: 8_388_608, sessions: 0, tokens: 1_024),
            (bytes: 8_388_608, sessions: 1, tokens: 0),
        ])
    func refusesPartialClaims(bytes: Int, sessions: Int, tokens: Int) {
        #expect(
            KVCacheResidencyObservation.measured(
                residentBytes: bytes,
                residentSessions: sessions,
                processedTokens: tokens) == .notObserved)
    }

    @Test("per-token price floors rather than rounds up")
    func floorsTheQuotient() {
        #expect(
            KVCacheResidencyObservation.measured(
                residentBytes: 10_000,
                residentSessions: 1,
                processedTokens: 3
            ).bytesPerToken == 3_333)
    }

    @Test("the wire keys are exactly the published contract")
    func wireKeysAreExact() throws {
        let data = try JSONEncoder().encode(
            KVCacheResidencyObservation.measured(
                residentBytes: 33_123_328,
                residentSessions: 1,
                processedTokens: 3_162))
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(
            Set(object.keys)
                == Set([
                    "status", "residentBytes", "residentSessions", "processedTokens",
                    "bytesPerToken",
                ]))
        #expect(object["status"] as? String == "measured")
        #expect(object["bytesPerToken"] as? Int == 10_475)

        let empty = try JSONEncoder().encode(KVCacheResidencyObservation.notObserved)
        let emptyObject = try #require(
            JSONSerialization.jsonObject(with: empty) as? [String: Any])
        #expect(emptyObject["status"] as? String == "not_observed")
        #expect(emptyObject["residentBytes"] as? Int == 0)
        // Unmeasured costs the key, not a null: Swift's synthesized Encodable drops nil
        // optionals, which is already this endpoint's shape for `prefixReuse.lastCached`.
        // `status` therefore carries the honesty, and it is never absent.
        #expect(
            Set(emptyObject.keys)
                == Set([
                    "status", "residentBytes", "residentSessions", "processedTokens",
                ]))
    }

    @Test(
        "no surface may feed KV bytes from a constant again",
        arguments: [
            ("Sources/ocoreai/Engine/EnginePool.swift", 2),  // derives it, then hands it over
            ("Sources/ocoreai/App.swift", 1),  // the gauge loop that publishes it
        ]
    )
    func assemblyFeedsNoHardcodedKVBytes(_ relativePath: String, _ floor: Int) throws {
        let root = try Self.repoRoot()
        let url = root.appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        // Floor the scan itself: a rename of the symbol must fail here, not pass vacuously.
        let mentions = text.split(separator: "\n").filter { $0.contains("gpuCacheGB") }
        #expect(
            mentions.count >= floor,
            "\(relativePath) no longer carries gpuCacheGB \(floor)x — the gauge was cut off")
        for line in mentions {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let assignsZero =
                trimmed.contains("= 0.0") || trimmed.contains("= 0,")
                || trimmed.contains("= 0\n") || trimmed.hasSuffix("= 0")
            #expect(
                !assignsZero,
                "\(relativePath) feeds KV bytes from a literal zero: \(trimmed)")
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
