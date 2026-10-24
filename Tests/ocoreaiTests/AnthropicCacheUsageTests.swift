// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Anthropic prompt-usage accounting — a prompt is split the way Anthropic defines it,
/// `total == input_tokens + cache_read_input_tokens + cache_creation_input_tokens`, and the
/// cache-served part is published whenever the engine measured it.
///
/// Before this suite `cacheReadInputTokens` was a `nil` placeholder while the same
/// measurement reached an OpenAI client as `usage.prompt_tokens_details.cached_tokens`: one
/// warm turn cost 1000 tokens on one wire and read as 1000 uncached tokens on the other, so
/// prefix reuse was invisible to exactly the clients that budget by cache hits.
/// Three comparators split it this way: vllm `entrypoints/anthropic/serving.py:80-110`,
/// ollama `anthropic/anthropic.go:226-238`, splash `server/api_shapes.py:1221-1226`.

import Foundation
import Testing

@testable import ocoreai

private func jsonObject(_ data: Data) -> [String: Any] {
    (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
}

private func json(_ usage: AnthropicUsage) -> [String: Any] {
    jsonObject(try! JSONEncoder().encode(usage))
}

private func json(_ event: AnthropicStreamEvent) -> [String: Any] {
    jsonObject(try! JSONEncoder().encode(event))
}

private func repoRoot() -> URL {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while root.path != "/",
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
    {
        root.deleteLastPathComponent()
    }
    #expect(root.path != "/", "repo root not found from \(#filePath)")
    return root
}

@Suite("Anthropic usage — prompt split and cache disclosure")
struct AnthropicCacheUsageTests {

    /// The split, at exact values: uncached input plus cache read is the whole prompt.
    @Test(arguments: [(1000, 750, 250, 750), (400, 0, 400, 0), (64, 64, 0, 64)])
    func splitPublishesMeasuredReuse(
        total: Int, cacheRead: Int, expectedUncached: Int, expectedRead: Int
    ) {
        let usage = AnthropicUsage.split(
            totalPromptTokens: total, cacheRead: cacheRead, outputTokens: 33)
        #expect(usage.inputTokens == expectedUncached)
        #expect(usage.cacheReadInputTokens == expectedRead)
        #expect(usage.outputTokens == 33)
        #expect(usage.inputTokens + (usage.cacheReadInputTokens ?? 0) == total)
    }

    /// An unmeasured leg stays absent: absence is not a claimed zero.
    @Test func unmeasuredCacheStaysAbsent() {
        let usage = AnthropicUsage.split(
            totalPromptTokens: 412, cacheRead: nil, outputTokens: 8)
        #expect(usage.inputTokens == 412)
        #expect(usage.cacheReadInputTokens == nil)
        let keys = Set(json(usage).keys)
        #expect(keys == ["input_tokens", "output_tokens"])
    }

    /// A measured zero *is* a measurement, and is published — same vocabulary as
    /// `prompt_tokens_details.cached_tokens` on the OpenAI face.
    @Test func measuredZeroIsPublished() {
        let usage = AnthropicUsage.split(totalPromptTokens: 90, cacheRead: 0, outputTokens: 2)
        let keys = Set(json(usage).keys)
        #expect(keys == ["input_tokens", "output_tokens", "cache_read_input_tokens"])
    }

    /// A breakdown cannot exceed the whole it belongs to: a cached count above the prompt is
    /// clamped to it, and `input_tokens` bottoms out at zero instead of going negative.
    @Test(arguments: [(100, 250, 0, 100), (50, -7, 50, 0), (-20, 5, 0, 0)])
    func breakdownIsClampedToWhole(
        total: Int, cacheRead: Int, expectedUncached: Int, expectedRead: Int
    ) {
        let parts = AnthropicCacheUsage.split(totalPromptTokens: total, cacheRead: cacheRead)
        #expect(parts.uncached == expectedUncached)
        #expect(parts.cacheRead == expectedRead)
        #expect(parts.uncached + (parts.cacheRead ?? 0) == max(0, total))
    }

    /// No cache *write* is measured on this engine, so the key never appears — the face may
    /// not bill a write it cannot show.
    @Test func cacheCreationIsNeverClaimed() {
        let measured = json(
            AnthropicUsage.split(totalPromptTokens: 500, cacheRead: 500, outputTokens: 1))
        let unmeasured = json(
            AnthropicUsage.split(totalPromptTokens: 500, cacheRead: nil, outputTokens: 1))
        #expect(measured.keys.contains("cache_creation_input_tokens") == false)
        #expect(unmeasured.keys.contains("cache_creation_input_tokens") == false)
    }

    /// One number for one prompt, across both faces: `prompt_tokens` on the OpenAI wire is
    /// the whole, so it equals this face's `input + cache_read`, and the total an Anthropic
    /// client computes (`input + output + cache_read + cache_write`) equals `total_tokens`.
    @Test(arguments: [(1000, 750), (949, 949), (30, 0), (77, nil)])
    func bothFacesReportTheSamePrompt(total: Int, cacheRead: Int?) {
        let openAI = Usage(input: total, output: 40, cachedPromptTokens: cacheRead)
        let anthropic = AnthropicUsage.split(
            totalPromptTokens: total, cacheRead: cacheRead, outputTokens: 40)
        let read = anthropic.cacheReadInputTokens ?? 0
        #expect(openAI.input == anthropic.inputTokens + read)
        #expect(openAI.total == anthropic.inputTokens + anthropic.outputTokens + read)
    }

    /// The terminal stream event splits through the same home as the non-stream response, so
    /// a streamed turn reports what the unstreamed one would.
    @Test func streamTerminalMatchesNonStreamSplit() {
        let stop = AnthropicStreamEvent.messageStop(
            totalPromptTokens: 800, cacheRead: 600, outputTokens: 12)
        let streamed = json(stop)["usage"] as? [String: Any]
        #expect(streamed?["input_tokens"] as? Int == 200)
        #expect(streamed?["cache_read_input_tokens"] as? Int == 600)
        #expect(streamed?["output_tokens"] as? Int == 12)
    }

    /// Every `usage` this face builds goes through the split — a hand-built `AnthropicUsage`
    /// is where the identity would drift a second time. The scan floors its own mechanism
    /// with a control pattern that must still match.
    @Test func everyUsageAssemblyGoesThroughTheSplit() throws {
        let root = repoRoot()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/ocoreai/Handlers/AnthropicMessagesHandler.swift"),
            encoding: .utf8)
        let bypasses = AnthropicCacheUsageTests.count(of: "AnthropicUsage(", in: source)
        #expect(bypasses == 0, "hand-built AnthropicUsage bypasses the split")
        let splits = AnthropicCacheUsageTests.count(of: "AnthropicUsage.split(", in: source)
        #expect(splits == 2, "expected the non-stream and message_start assemblies, got \(splits)")
        // Both legs report the engine's measurement, not the pre-flight estimate.
        #expect(
            AnthropicCacheUsageTests.count(of: "cacheRead: observedCachedPromptTokens", in: source)
                == 2)
    }

    /// The placeholder comment is gone, and the scan proves it can see the key it replaced.
    @Test func placeholderIsRetiredAndScanStillMatches() throws {
        let root = repoRoot()
        let model = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/ocoreai/Models/AnthropicModels.swift"),
            encoding: .utf8)
        let placeholder = "reserved for future cache feature"
        #expect(AnthropicCacheUsageTests.count(of: placeholder, in: model) == 0)
        #expect(AnthropicCacheUsageTests.count(of: "cache_read_input_tokens", in: model) >= 2)
    }

    static func count(of needle: String, in haystack: String) -> Int {
        var n = 0
        var search = haystack.startIndex
        while let found = haystack.range(of: needle, range: search ..< haystack.endIndex) {
            n += 1
            search = found.upperBound
        }
        return n
    }
}
