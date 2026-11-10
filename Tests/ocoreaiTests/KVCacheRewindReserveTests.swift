// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
// The rewind reserve stopped being a bare constant: it is now a plan the endpoint states
// and an override the operator owns. The resolver takes the environment as a dictionary,
// so no test touches the process env — there is nothing to lease
// (ProcessGlobalLeaseDisciplineTests). Every row asserts exact wire values; the refused
// override rows assert the raw text is quoted, because a refused override that goes silent
// is the same class of lie as a flat-zero metrics series.

import Foundation
import MLXLMCommon
import Testing

@testable import ocoreai

private struct Row: Sendable {
    let raw: String?
    let tokens: Int
    let basis: String
    let requested: Bool
}

private let rows: [Row] = [
    Row(raw: nil, tokens: 1024, basis: "default", requested: true),
    Row(raw: "4096", tokens: 4096, basis: "environment", requested: true),
    Row(raw: "1", tokens: 1, basis: "environment", requested: true),
    Row(raw: "0", tokens: 0, basis: "off", requested: false),
    Row(raw: "-5", tokens: 1024, basis: "invalid_environment", requested: true),
    Row(raw: "1024x", tokens: 1024, basis: "invalid_environment", requested: true),
    Row(raw: "", tokens: 1024, basis: "invalid_environment", requested: true),
]

@Suite("KV rewind reserve resolution and wire")
struct KVCacheRewindReserveTests {

    @Test("the resolver decides every value shape exactly", arguments: rows)
    fileprivate func resolutionTable(_ row: Row) {
        var env: [String: String] = [:]
        if let raw = row.raw {
            env[KVCacheRewindReservePolicy.environmentVariable] = raw
        }
        let got = KVCacheRewindReservePolicy.resolve(environment: env)
        #expect(got.tokens == row.tokens)
        #expect(got.basis == row.basis)
        // The default basis never echoes an env value; every other basis quotes it —
        // including the refused override.
        #expect(got.rawEnvironment == row.raw)
    }

    @Test("the process-wide resolution is the pure resolver over the same environment")
    func globalResolutionMatchesThePureOne() {
        #expect(
            kvCacheRewindReserveResolution
                == KVCacheRewindReservePolicy.resolve(
                    environment: ProcessInfo.processInfo.environment),
            "the caches were built under a plan the resolver would not state — a second decision home"
        )
    }

    @Test("off degrades to no reserve requested, not to an error")
    func offIsADegradationNotAFailure() throws {
        #expect(makeKVCacheRewind(maxTokens: 0) == nil)
        #expect(makeKVCacheRewind(maxTokens: 1024) != nil)
    }

    @Test("the endpoint states the plan: requested, tokens, basis, quoted raw", arguments: rows)
    fileprivate func wireCarriesTheWholePlan(_ row: Row) throws {
        let wire = KVCacheStatusResponse.KVCacheRewindReserveWire(
            KVCacheRewindReservePolicy.Resolution(
                tokens: row.tokens, basis: row.basis, rawEnvironment: row.raw))
        let status = KVCacheStatus(cache: [KVCacheSimple()])
        let data = try JSONEncoder().encode(
            makeKVCacheStatusResponse(status, rewindReserve: wire))
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let published = try #require(obj["rewindReserve"] as? [String: Any])
        #expect(published["requested"] as? Bool == row.requested)
        #expect(published["tokens"] as? Int == row.tokens)
        #expect(published["basis"] as? String == row.basis)
        if let raw = row.raw {
            #expect(published["rawEnvironment"] as? String == raw)
        } else {
            // No env in play: the key is absent, not an empty string standing in for "nothing".
            #expect(published["rawEnvironment"] == nil)
        }
    }

    @Test("the knob is registered for the docs contract (P21 names it only when wired)")
    func environmentVariableNameIsExact() {
        #expect(
            KVCacheRewindReservePolicy.environmentVariable == "OCOREAI_KV_REWIND_RESERVE_TOKENS")
    }
}
