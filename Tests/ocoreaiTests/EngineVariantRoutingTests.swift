// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// #146/#170 alignment — EngineFactory variant routing (dynamic → pipelined,
// aligned with upstream coreai-models `EngineFactory`; ocoreai removed the
// sequential-fallback layer so auto-detect is honored directly).
//
// Gated with `#if canImport(CoreAI)`: the real `struct EngineFactory` lives in
// CoreAIEngine.swift `#if canImport(CoreAI)` (L61), while a same-named
// fallback `enum EngineFactory` lives in InferenceStubs.swift
// `#if !canImport(CoreAI)` (L464). On a non-CoreAI runner (macos-26, no
// CoreAI framework in SDK 26.5) the name resolves to the stub enum, which
// has no `Variant` — so this suite must NOT compile there. Same convention as
// RepetitionPenaltyGPUStateTests.swift (canImport = compile gate; the
// macos-26 runner skips the block).
//
// Inside the gate, `struct EngineFactory` is @available(macOS 27.0, iOS 27.0, *)
// and the deployment target is macOS 14 / iOS 17, so every test body guards
// with #available(macOS 27.0) — @Suite/@Test macros can NOT carry @available
// (ocoreai-dev skill §6.1).

import Foundation
import Testing

#if canImport(CoreAI)

@testable import ocoreai

@Suite("EngineFactory variant routing (B: no-fallback, aligned with upstream)")
struct EngineVariantRoutingTests {

    // Runtime availability guard (the compile gate is the #if above, so this
    // only gates on OS version — a plain func, never a stored Sendable-risky
    // closure in a static let under Swift 6 strict concurrency).
    private static func isAvailable() -> Bool {
        if #available(macOS 27.0, iOS 27.0, *) { return true }
        return false
    }

    private func isFailure(_ r: Result<EngineFactory.Variant, Error>) -> Bool {
        if case .failure = r { return true }
        return false
    }

    // MARK: auto-detect (override == nil / "auto" / "default")

    @Test("auto-detect: dynamic → pipelined (GPU), no fallback to sequential")
    func dynamicAutoDetectsPipelined() {
        guard Self.isAvailable() else { return }
        #expect(
            try! EngineFactory.resolveVariant(override: nil, detectedStructure: .dynamic)
                == .pipelined)
        #expect(
            try! EngineFactory.resolveVariant(override: "auto", detectedStructure: .dynamic)
                == .pipelined)
        #expect(
            try! EngineFactory.resolveVariant(override: "default", detectedStructure: .dynamic)
                == .pipelined)
    }

    @Test("auto-detect: chunkedStatic → staticShape (ANE)")
    func chunkedStaticAutoDetectsStaticShape() {
        guard Self.isAvailable() else { return }
        #expect(
            try! EngineFactory.resolveVariant(override: nil, detectedStructure: .chunkedStatic)
                == .staticShape)
    }

    @Test("auto-detect: unknown → sequential")
    func unknownAutoDetectsSequential() {
        guard Self.isAvailable() else { return }
        #expect(
            try! EngineFactory.resolveVariant(override: nil, detectedStructure: .unknown)
                == .sequential)
    }

    // MARK: override path

    @Test("override: explicit coreai-sequential wins on dynamic structure")
    func explicitSequentialOverride() {
        guard Self.isAvailable() else { return }
        #expect(
            try! EngineFactory.resolveVariant(
                override: "coreai-sequential", detectedStructure: .dynamic) == .sequential)
    }

    @Test("override: coreai-pipelined on chunkedStatic → throws (incompatible)")
    func pipelinedOnChunkedStaticThrows() {
        guard Self.isAvailable() else { return }
        let result: Result<EngineFactory.Variant, Error> = Result {
            try EngineFactory.resolveVariant(
                override: "coreai-pipelined", detectedStructure: .chunkedStatic)
        }
        #expect(self.isFailure(result), "expected throw, got \(result)")
        if case .failure(let err) = result {
            #expect(err is InferenceError)
        }
    }

    @Test("override: static-shape on dynamic → throws (incompatible)")
    func staticShapeOnDynamicThrows() {
        guard Self.isAvailable() else { return }
        let result: Result<EngineFactory.Variant, Error> = Result {
            try EngineFactory.resolveVariant(override: "static-shape", detectedStructure: .dynamic)
        }
        #expect(self.isFailure(result), "expected throw, got \(result)")
    }

    @Test("override: unknown variant string → throws")
    func unknownVariantStringThrows() {
        guard Self.isAvailable() else { return }
        let result: Result<EngineFactory.Variant, Error> = Result {
            try EngineFactory.resolveVariant(
                override: "turbo-fan-9000", detectedStructure: .dynamic)
        }
        #expect(self.isFailure(result), "expected throw, got \(result)")
    }

    // MARK: full compatibility table (matches upstream EngineFactory)

    @Test("compatibility table matches upstream EngineFactory")
    func fullCompatibilityTable() {
        guard Self.isAvailable() else { return }
        #expect(
            EngineFactory.checkVariantCompatibility(variant: .sequential, structure: .dynamic)
                .compatible)
        #expect(
            EngineFactory.checkVariantCompatibility(
                variant: .staticShape, structure: .chunkedStatic
            ).compatible)
        #expect(
            EngineFactory.checkVariantCompatibility(variant: .staticShape, structure: .dynamic)
                .compatible == false)
        #expect(
            EngineFactory.checkVariantCompatibility(variant: .pipelined, structure: .chunkedStatic)
                .compatible == false)
        #expect(
            EngineFactory.checkVariantCompatibility(variant: .sequential, structure: .chunkedStatic)
                .compatible == false)
        #expect(
            EngineFactory.checkVariantCompatibility(variant: .sequential, structure: .unknown)
                .compatible)
        #expect(
            EngineFactory.checkVariantCompatibility(variant: .pipelined, structure: .unknown)
                .compatible)
        #expect(
            EngineFactory.checkVariantCompatibility(variant: .staticShape, structure: .unknown)
                .compatible)
    }
}

#endif  // canImport(CoreAI)
