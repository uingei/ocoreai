// Copyright 2026 Apple Inc. (BSD-3-Clause upstream)
//
// Absorbed from coreai-models 27a66f9 (#227, fix #212) swift/Tests/LanguageModelsTests/
// InputLayoutTests.swift (2026-09-07, copy-first; ocoreai adaptation: the pure-logic
// `InputLayout.analyze(inputNames:...)` / `resolveRequired` are @available(macOS 27,
// iOS 27)-gated (they build the 27-gated struct and throw the 27-gated error), and
// `@Suite`/`@Test` macros cannot carry `@available`, so each test body opens with a
// `guard #available` early-return — same convention as PrefillGraphTests.swift.
//
/// Locks the #212 decision: a static `[1,1,vocab]` (S=1 / GDN) descriptor must pin the
/// prefill chunk width to the fixed query length and the logits policy to `.fixed(1)`,
/// instead of inheriting a dynamic prompt-size threshold. Also guards the input-name
/// resolution (in_new_token_ids / pos_ids) that both engines rely on.

import Foundation
import Testing

#if canImport(CoreAI)

@testable import ocoreai

@Suite("InputLayout (#212)")
struct InputLayoutTests {
    let standardInputs = ["input_ids", "position_ids"]
    let standardOutputs = ["logits"]

    // MARK: - Name resolution

    @Test("Resolves alternate names and throws on unknown")
    func nameResolution() {
        guard #available(macOS 27.0, iOS 27.0, *) else { return }
        let alt = try? InputLayout.resolveRequired(
            from: ["in_new_token_ids", "pos_ids"],
            candidates: InputLayout.knownInputIdNames,
            label: "input_ids")
        #expect(alt == "in_new_token_ids")

        let unknown = try? InputLayout.resolveRequired(
            from: ["tokens", "positions"],
            candidates: InputLayout.knownInputIdNames,
            label: "input_ids")
        #expect(unknown == nil)  // throws → nil
    }

    // MARK: - Dynamic model

    @Test("Dynamic model: dynamic policies and standard names")
    func dynamicDefaults() {
        guard #available(macOS 27.0, iOS 27.0, *) else { return }
        let layout = try? analyze(nil, logitsSeqLen: nil, hasPrefillGraph: false)
        #expect(layout?.queryPolicy == .dynamic)
        #expect(layout?.logitsPolicy == .dynamic)
        #expect(layout?.positionPolicy == .full)
        #expect(layout?.prefillPolicy == .chunk(threshold: 1024, chunkSize: 512))
        #expect(layout?.inputIdsName == "input_ids")
        #expect(layout?.positionIdsName == "position_ids")
        #expect(layout?.logitsName == "logits")
    }

    // MARK: - #212: static S=1

    @Test("Static S=1: prefill chunks at 1 (the #212 core fix)")
    func staticS1() {
        guard #available(macOS 27.0, iOS 27.0, *) else { return }
        let layout = try? analyze(1, logitsSeqLen: 1, hasPrefillGraph: false)
        #expect(layout?.queryPolicy == .fixed(1))
        #expect(layout?.logitsPolicy == .fixed(seqLen: 1))
        // The decisive one: prefill must be chunked at the fixed width, NOT at the
        // dynamic 1024 threshold.
        #expect(layout?.prefillPolicy == .chunk(threshold: 1, chunkSize: 1))
    }

    @Test("Asymmetric: static input, dynamic logits — still chunks at 1")
    func asymmetricStaticInput() {
        guard #available(macOS 27.0, iOS 27.0, *) else { return }
        let layout = try? analyze(1, logitsSeqLen: nil, hasPrefillGraph: false)
        #expect(layout?.queryPolicy == .fixed(1))
        #expect(layout?.logitsPolicy == .dynamic)
        #expect(layout?.prefillPolicy == .chunk(threshold: 1, chunkSize: 1))
    }

    // MARK: - Prefill graph override

    @Test("Prefill graph overrides the chunk policy even for S=1")
    func prefillGraphOverrides() {
        guard #available(macOS 27.0, iOS 27.0, *) else { return }
        let dynamic = try? analyze(nil, logitsSeqLen: nil, hasPrefillGraph: true)
        #expect(dynamic?.prefillPolicy == .prefillGraph)

        let s1 = try? analyze(1, logitsSeqLen: 1, hasPrefillGraph: true)
        #expect(s1?.prefillPolicy == .prefillGraph)
    }

    // MARK: - Errors

    @Test("Throws on empty outputs or missing position_ids")
    func throwsOnBadDescriptor() {
        guard #available(macOS 27.0, iOS 27.0, *) else { return }
        #expect(
            (try? analyze(nil, logitsSeqLen: nil, hasPrefillGraph: false, outputNames: [])) == nil)

        // input_ids present but no position_ids → resolveRequired(position_ids) throws.
        let noPos = try? InputLayout.analyze(
            inputNames: ["input_ids"], outputNames: ["logits"],
            inputIdsSeqLen: nil, logitsSeqLen: nil,
            chunkThreshold: 1024, chunkSize: 512,
            hasPrefillGraph: false, useCompactPositionIds: false)
        #expect(noPos == nil)
    }

    @Test("inputIdsSeqLen=0 treated as dynamic")
    func zeroSeqLenIsDynamic() {
        guard #available(macOS 27.0, iOS 27.0, *) else { return }
        let layout = try? analyze(0, logitsSeqLen: nil, hasPrefillGraph: false)
        #expect(layout?.queryPolicy == .dynamic)
    }

    @Test("Compact position policy is respected")
    func compactPositions() {
        guard #available(macOS 27.0, iOS 27.0, *) else { return }
        let layout =
            (try? InputLayout.analyze(
                inputNames: standardInputs, outputNames: standardOutputs,
                inputIdsSeqLen: nil, logitsSeqLen: nil,
                chunkThreshold: 1024, chunkSize: 512,
                hasPrefillGraph: false, useCompactPositionIds: true))
        #expect(layout?.positionPolicy == .compact)
    }

    // MARK: - Helper

    private func analyze(
        _ inputIdsSeqLen: Int?,
        logitsSeqLen: Int? = nil,
        hasPrefillGraph: Bool = false,
        outputNames: [String]? = nil
    ) throws -> InputLayout {
        try InputLayout.analyze(
            inputNames: standardInputs,
            outputNames: outputNames ?? standardOutputs,
            inputIdsSeqLen: inputIdsSeqLen,
            logitsSeqLen: logitsSeqLen,
            chunkThreshold: 1024, chunkSize: 512,
            hasPrefillGraph: hasPrefillGraph, useCompactPositionIds: false)
    }
}

#endif
