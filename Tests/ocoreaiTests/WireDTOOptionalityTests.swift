// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// WireDTOOptionalityTests.swift — a default in Swift is not an optional on the wire.
///
/// Measured 10-20 by `scripts/probes/20-download-path-traversal.sh`: every body sent to
/// ``POST /v1/models/download`` — which is to say, every body that did not volunteer a refresh
/// flag nobody asked about — answered
///
///     400 {"error":{"message":"Coding key `useLatest` not found."}}
///
/// `DownloadModelRequest` declared `init(… useLatest: Bool = false)`, and the synthesized
/// `Decodable` asked for the key anyway. The endpoint had been unusable for spec-legal clients
/// since it was written, and every test in the repo passed: nothing decoded a body that omitted
/// the key (AGENTS.md § Wire DTOs states the rule; this file makes it a gate).
///
/// Two shapes hide this: a **property** default (`var n: Int = 4`) and an **init parameter**
/// default (`init(n: Int = 4)`). The scanner below looks for both, and proves it can see both on
/// synthetic samples before it is allowed to report zero on the real surface — a scan whose
/// pattern stopped matching would otherwise report the same clean number as a fixed bug
/// (CONTRIBUTING → "the gate asserts its own premises").

import Foundation
import Testing

@testable import ocoreai

// MARK: - Behaviour: omit the key, get the default

@Suite("Optional keys decode when absent — exact values")
struct WireDTOOptionalityTests {

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test("POST /v1/models/download: only `model` is required")
    func downloadRequestMinimumBody() throws {
        let r = try Self.decode(
            DownloadModelRequest.self, #"{"model":"mlx-community/gemma-4-e2b"}"#)
        #expect(r.model == "mlx-community/gemma-4-e2b")
        #expect(r.provider == nil)
        #expect(r.revision == nil)
        #expect(r.useLatest == false)
        #expect(r.effectiveProvider == "hf")
    }

    @Test("…and the optional keys still decode to what was sent")
    func downloadRequestFullBody() throws {
        let r = try Self.decode(
            DownloadModelRequest.self,
            #"{"model":"Qwen/Qwen2.5-7B-Instruct","provider":"mscope","revision":"master","useLatest":true}"#
        )
        #expect(r.effectiveProvider == "mscope")
        #expect(r.revision == "master")
        #expect(r.useLatest == true)
    }

    @Test("…but a body without `model` is still refused")
    func downloadRequestStillRequiresModel() {
        #expect(throws: (any Error).self) {
            try Self.decode(DownloadModelRequest.self, #"{"provider":"hf"}"#)
        }
    }

    @Test("POST /v1/train/eval: batch_size / max_batches are optional")
    func evalRequestMinimumBody() throws {
        let r = try Self.decode(EvalRequest.self, #"{"model":"m","dataset":["a"]}"#)
        #expect(r.batchSize == 4)
        #expect(r.maxBatches == 0)
        let sent = try Self.decode(
            EvalRequest.self,
            #"{"model":"m","dataset":["a"],"batch_size":8,"max_batches":3}"#)
        #expect(sent.batchSize == 8)
        #expect(sent.maxBatches == 3)
    }

    @Test(
        "POST /v1/train: lora / hyperparams objects are optional, and so is everything inside them")
    func trainRequestMinimumBody() throws {
        let r = try Self.decode(
            TrainRequest.self, #"{"model":"m","trainingData":{"inline":["x"]}}"#)
        #expect(r.lora.rank == 8)
        #expect(r.lora.scale == 20.0)
        #expect(r.lora.numLayers == 4)
        #expect(r.hyperparams.iterations == 1000)
        #expect(r.hyperparams.saveEvery == 200)
        #expect(r.validationData == nil)

        let partial = try Self.decode(
            TrainRequest.self,
            #"{"model":"m","trainingData":{"inline":["x"]},"lora":{},"hyperparams":{"iterations":7}}"#
        )
        #expect(partial.lora.rank == 8, "an empty lora object takes every default")
        #expect(partial.hyperparams.iterations == 7)
        #expect(partial.hyperparams.learningRate == 0.00001)
    }

    /// `stream_options` is where this bites the OpenAI face hardest: the object is legal and its
    /// one field is optional, so `{}` used to 400 the *whole chat request*.
    @Test("chat: `stream_options:{}` decodes instead of killing the request")
    func emptyStreamOptionsDecodes() throws {
        let r = try Self.decode(
            ChatCompletionRequest.self,
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"stream":true,"stream_options":{}}"#
        )
        #expect(r.stream == true)
        #expect(r.streamOptions?.includeUsage == false)

        let withUsage = try Self.decode(
            ChatCompletionRequest.self,
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"stream":true,"stream_options":{"include_usage":true}}"#
        )
        #expect(withUsage.streamOptions?.includeUsage == true)
    }
}

// MARK: - The class, scanned

@Suite("Inbound DTO surface has no un-honoured defaults")
struct WireDTOScanTests {

    /// Files that may define a request body the router decodes. Narrow on purpose (fast, and a
    /// DTO living elsewhere makes this test say so rather than silently scanning less).
    private static func candidateFiles() throws -> [URL] {
        let root = try repoRoot()
        var files: [URL] = []
        for sub in ["Sources/ocoreai/Models", "Sources/ocoreai/Handlers", "Sources/ocoreai/Router"]
        {
            let dir = root.appendingPathComponent(sub)
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
            else {
                throw MissingPath(path: dir.path)
            }
            files.append(
                contentsOf: entries.filter { $0.hasSuffix(".swift") }
                    .map { dir.appendingPathComponent($0) })
        }
        return files
    }

    private struct MissingPath: Error, CustomStringConvertible {
        let path: String
        var description: String { "no such directory walking up from \(#filePath): \(path)" }
    }

    private static func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 6 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(
                    "Sources/ocoreai/Router/ChatCompletionsRouter.swift"
                ).path)
            {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw MissingPath(path: "Sources/ocoreai/Router/ChatCompletionsRouter.swift")
    }

    /// Every type the router actually decodes — the inbound surface, read from the router rather
    /// than hand-copied (a hand-copied list is a second truth that drifts).
    static func inboundDTOs() throws -> [String] {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent(
                "Sources/ocoreai/Router/ChatCompletionsRouter.swift"),
            encoding: .utf8)
        let re = try NSRegularExpression(pattern: #"as:\s*([A-Za-z0-9_]+)\.self"#)
        let range = NSRange(source.startIndex..., in: source)
        var seen = Set<String>()
        var out: [String] = []
        for match in re.matches(in: source, range: range) {
            guard match.numberOfRanges == 2,
                let r = Range(match.range(at: 1), in: source)
            else { continue }
            let name = String(source[r])
            if seen.insert(name).inserted { out.append(name) }
        }
        return out.sorted()
    }

    /// The struct body of `name`, by brace matching from its declaration line.
    static func structBody(named name: String, in source: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"struct\s+\#(name)\b[^\n{]*\{"#) else {
            return nil
        }
        let range = NSRange(source.startIndex..., in: source)
        guard let match = re.firstMatch(in: source, range: range),
            let open = Range(match.range, in: source).map({ $0.upperBound })
        else { return nil }
        var depth = 0
        var idx = source.index(before: open)
        while idx < source.endIndex {
            if source[idx] == "{" {
                depth += 1
            } else if source[idx] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open ..< idx]) }
            }
            source.formIndex(after: &idx)
        }
        return nil
    }

    private static let propertyDefault =
        #"^\s+(?:public |private |fileprivate |internal )?(?:var|let)\s+(\w+)\s*:\s*([^=\n]+?)\s*=\s*[^=\n]"#
    private static let initParamDefault = #"(\w+)\s*:\s*([^=,()]+?)\s*=\s*"#

    /// Fields whose absence the synthesized decoder would refuse, despite a default promising it
    /// would not. Both shapes count: a property default and an init-parameter default.
    static func unhonouredDefaults(in body: String) -> [String] {
        if body.contains("init(from") { return [] }  // hand-decoded: init(from:) owns the contract
        var out: [String] = []
        func scan(_ pattern: String, _ tag: String, _ text: String) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            else { return }
            let range = NSRange(text.startIndex..., in: text)
            for match in re.matches(in: text, range: range) {
                guard match.numberOfRanges == 3,
                    let nameR = Range(match.range(at: 1), in: text),
                    let typeR = Range(match.range(at: 2), in: text)
                else { continue }
                let type = String(text[typeR]).trimmingCharacters(in: .whitespaces)
                guard !type.hasSuffix("?") else { continue }
                out.append("\(tag):\(String(text[nameR]))")
            }
        }
        scan(propertyDefault, "property", body)
        // init(...) parameter lists, found by paren matching so nested generics don't confuse it.
        guard let initRe = try? NSRegularExpression(pattern: #"\b(?:init|subscript)\s*\("#) else {
            return out.sorted()
        }
        let full = NSRange(body.startIndex..., in: body)
        for match in initRe.matches(in: body, range: full) {
            guard let open = Range(match.range, in: body).map({ $0.upperBound }) else { continue }
            var depth = 0
            var idx = body.index(before: open)
            while idx < body.endIndex {
                if body[idx] == "(" {
                    depth += 1
                } else if body[idx] == ")" {
                    depth -= 1
                    if depth == 0 {
                        scan(initParamDefault, "initParam", String(body[open ..< idx]))
                        break
                    }
                }
                body.formIndex(after: &idx)
            }
        }
        return out.sorted()
    }

    /// The scanner must see both shapes. Without this, "zero violations" is indistinguishable from
    /// "the regex stopped matching" — the exact state this file was written into.
    @Test("self-test: the scanner sees a property default AND an init-parameter default")
    func scannerSeesBothShapes() {
        let propertyShape = """
            struct FakeOne: Codable {
                var flag: Bool = false
            }
            """
        let initShape = """
            struct FakeTwo: Codable {
                var count: Int
                init(count: Int = 4) { self.count = count }
            }
            """
        #expect(Self.unhonouredDefaults(in: propertyShape) == ["property:flag"])
        #expect(Self.unhonouredDefaults(in: initShape) == ["initParam:count"])
        // And it does not invent violations where the contract is honest.
        let honest = """
            struct FakeThree: Codable {
                var flag: Bool
                enum CodingKeys: String, CodingKey { case flag }
                init(from decoder: Decoder) throws {
                    flag = try decoder.decodeIfPresent(Bool.self, forKey: .flag) ?? false
                }
            }
            """
        #expect(Self.unhonouredDefaults(in: honest) == [])
    }

    @Test("no inbound DTO promises a default the decoder will not honour")
    func inboundSurfaceIsClean() throws {
        let dtos = try Self.inboundDTOs()
        #expect(dtos.count >= 13, "the router scan found only \(dtos.count) inbound DTOs")

        let files = try Self.candidateFiles()
        #expect(
            files.count >= 10, "DTO scan walked \(files.count) files — expected the Models/ set")

        var bodies: [String: String] = [:]
        var offenders: [String] = []
        var scanned = 0
        for name in dtos {
            for file in files {
                guard let source = try? String(contentsOf: file, encoding: .utf8),
                    source.contains("struct \(name)")
                else { continue }
                guard let body = Self.structBody(named: name, in: source) else { continue }
                bodies[name] = body
                scanned += 1
                let bad = Self.unhonouredDefaults(in: body)
                if !bad.isEmpty { offenders.append("\(name) ← \(bad.joined(separator: ", "))") }
                break
            }
        }
        // Premise floor: every named DTO must have been located, or "clean" means nothing.
        #expect(scanned == dtos.count, "bodies not found for: \(dtos.filter { bodies[$0] == nil })")
        #expect(bodies.values.contains { $0.contains("decodeIfPresent") })
        #expect(
            offenders.isEmpty,
            "un-honoured wire defaults: \(offenders.joined(separator: " | "))")
    }
}
