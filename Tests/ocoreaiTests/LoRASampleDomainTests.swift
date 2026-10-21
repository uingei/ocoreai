// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//! LoRASampleDomainTests.swift — the LoRA dataset rule decided by exact values, plus the
//! scan proving both wire faces actually route through it.
//!
//! The rule exists because a 1-token sample gives the batch iterator nothing to predict and
//! traps inside mlx (`LoRASampleDomain` header, mlx-swift-lm #683). A refusal that the
//! endpoint forgets to call is the same bug with a gate that says nothing, so the surface
//! half of this file counts call sites rather than trusting the handler's prose.

import Foundation
import Testing

@testable import ocoreai

@Suite("LoRASampleDomain — exact refusal decisions")
struct LoRASampleDomainValueTests {

    /// Stub token counter: one token per space-separated run, so every number asserted here
    /// is written down rather than borrowed from a vocabulary this test does not own. (The
    /// production call sites pass the model's real tokenizer — that part cannot be stubbed
    /// without a download, and the probe measures it live.)
    private static func wordCount(_ text: String) -> Int {
        text.split(separator: " ").count
    }

    @Test("the floor is two tokens — one to read, one to predict")
    static func floorIsTwo() {
        #expect(LoRASampleDomain.minimumTokensPerSample == 2)
    }

    @Test("usable datasets produce no violation")
    static func usableDatasets() {
        #expect(
            LoRASampleDomain.firstViolation(dataset: [], label: "dataset", tokenCount: wordCount)
                == nil)
        #expect(
            LoRASampleDomain.firstViolation(
                dataset: ["hello world"], label: "dataset", tokenCount: wordCount) == nil)
        #expect(
            LoRASampleDomain.firstViolation(
                dataset: ["a b", "c d e"], label: "validationData", tokenCount: wordCount) == nil)
    }

    @Test("a one-token sample is refused with its dataset and position")
    static func oneTokenSample() {
        let violation = LoRASampleDomain.firstViolation(
            dataset: ["solo"], label: "trainingData", tokenCount: wordCount)
        #expect(
            violation
                == LoRASampleDomain.Violation(
                    dataset: "trainingData", index: 0, tokenCount: 1))
    }

    @Test("only the first bad sample is named, and it is the one at its own index")
    static func firstBadSampleWins() {
        let violation = LoRASampleDomain.firstViolation(
            dataset: ["fine here", "bad", "also bad"], label: "validationData",
            tokenCount: wordCount)
        #expect(violation?.index == 1)
        #expect(violation?.tokenCount == 1)
        #expect(violation?.dataset == "validationData")
    }

    @Test("an empty string counts as zero tokens and is refused")
    static func emptyStringIsZeroTokens() {
        let violation = LoRASampleDomain.firstViolation(
            dataset: ["fine text", ""], label: "dataset", tokenCount: wordCount)
        #expect(
            violation
                == LoRASampleDomain.Violation(dataset: "dataset", index: 1, tokenCount: 0))
    }

    @Test("the message names field, position, what arrived, and what to send")
    static func messageShape() {
        let singular = LoRASampleDomain.Violation(dataset: "dataset", index: 0, tokenCount: 1)
        #expect(
            LoRASampleDomain.message(for: singular)
                == "dataset[0] encodes to 1 token; each sample needs >= 2 — one to read, one to predict."
        )
        let plural = LoRASampleDomain.Violation(dataset: "trainingData", index: 3, tokenCount: 0)
        #expect(
            LoRASampleDomain.message(for: plural)
                == "trainingData[3] encodes to 0 tokens; each sample needs >= 2 — one to read, one to predict."
        )
    }
}

@Suite("LoRASampleDomain — both wire faces route through the one home")
struct LoRASampleDomainSurfaceTests {

    private static let handler = "Sources/ocoreai/Handlers/LLMLifecycleHandler.swift"
    private static let pool = "Sources/ocoreai/Engine/EnginePool.swift"

    private struct Missing: Error, CustomStringConvertible {
        let what: String
        var description: String { "could not find \(what) walking up from \(#filePath)" }
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

    /// Comment-aware code lines: prose may name a forbidden shape in order to forbid it.
    private static func codeLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter {
            line in
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            return !(trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*"))
        }
    }

    private static func swiftSources() throws -> [(path: String, code: [String])] {
        let root = try repoRoot()
        guard
            let enumerator = FileManager.default.enumerator(
                at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
        else { throw Missing(what: "Sources/ enumerator") }
        var out: [(String, [String])] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            out.append((String(url.path.dropFirst(root.path.count + 1)), codeLines(text)))
        }
        return out
    }

    private static func count(_ pattern: String, in lines: [String]) -> Int {
        lines.reduce(0) { total, line in total + (line.contains(pattern) ? 1 : 0) }
    }

    /// Every zero-tolerance count here self-proves its own pattern first (invariant 1): a
    /// scan that stopped matching reports a clean tree, which is the failure it exists to
    /// catch. Expectations carry counts and paths only — Swift Testing prints the operands of
    /// a failed expectation, and a gate that dumps files into CI gets muted.
    @Test("train and evaluate both gate their samples, and neither resolves the model alone")
    static func bothFacesRouteThroughTheHome() throws {
        let patterns = [
            "LoRASampleDomain.firstViolation",
            "LoRAModelSupport.rejection(for:",
            "LoRATrain.train(",
            "LoRATrain.evaluate(",
            "enginePool.mlxContainer(modelId:",
            "getMLXModelAndTokenizer",
        ]
        let selfProof = [
            "if let v = LoRASampleDomain.firstViolation(dataset: rows, label: l, tokenCount: f) {",
            "if let r = LoRAModelSupport.rejection(for: ctx.model) { throw AppError.invalidRequest(r) }",
            "try LoRATrain.train(model: m, train: rows)",
            "let loss = LoRATrain.evaluate(model: m, dataset: rows)",
            "let container = try await enginePool.mlxContainer(modelId: id)",
            "guard let c = await enginePool.getMLXModelAndTokenizer(modelId: id) else { return }",
        ]
        for pattern in patterns {
            #expect(
                selfProof.contains { $0.contains(pattern) },
                "the instrument cannot see its own pattern — \(pattern)")
        }

        let files = try swiftSources()
        #expect(
            files.count >= 150, "only \(files.count) Swift sources scanned — the walk is broken")
        let handlerLines = try files.first { $0.path == handler }!.code
        let poolLines = try files.first { $0.path == pool }!.code

        // Two faces, two guards: the train face loops over train + validation with one call,
        // the eval face calls once. Adding a third LoRA face without a guard trips this.
        #expect(
            count("LoRASampleDomain.firstViolation", in: handlerLines) == 2,
            "every LoRA face must gate its samples — found \(count("LoRASampleDomain.firstViolation", in: handlerLines))"
        )
        #expect(count("LoRATrain.train(", in: handlerLines) == 1)
        #expect(count("LoRATrain.evaluate(", in: handlerLines) == 1)

        // Both faces ask the capability question the loss will answer with `as!`. Same
        // count as the LoRA calls: a third face added without the guard trips this.
        #expect(
            count("LoRAModelSupport.rejection(for:", in: handlerLines) == 2,
            "both LoRA faces must check capability before touching the engine — found \(count("LoRAModelSupport.rejection(for:", in: handlerLines))"
        )

        // Both faces resolve the model through the one load-on-demand home, and the
        // residency-only lookup is gone from the wire layer (it is what refused a model that
        // exists: /v1/models advertised it while /health reported loadedModels: 0).
        #expect(
            count("enginePool.mlxContainer(modelId:", in: handlerLines) == 2,
            "both LoRA faces must resolve through mlxContainer — found \(count("enginePool.mlxContainer(modelId:", in: handlerLines))"
        )
        #expect(
            count("getMLXModelAndTokenizer", in: handlerLines) == 0,
            "the residency-only lookup is back on the wire layer")
        #expect(
            count("getMLXModelAndTokenizer", in: poolLines) == 0,
            "the residency-only accessor should not survive in the pool either")

        // One lazy-load home, shared rather than duplicated.
        #expect(count("func ensureModelLoaded(modelId:", in: poolLines) == 1)
        #expect(count("func mlxContainer(modelId:", in: poolLines) == 1)
        #expect(
            count("try await ensureModelLoaded(modelId: modelId)", in: poolLines) == 2,
            "acquire(model:) and mlxContainer(modelId:) must share the load path")
    }
}
