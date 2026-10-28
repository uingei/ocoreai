// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ScriptedEngineTests — the model-free lane produces exactly what the script declares, and no more.
///
/// `ScriptedInference` is the seam that lets a wire-contract claim be decided without Metal (probe 37
/// proves the end-to-end shape); this suite pins the producer itself, where a mistake is a line number
/// instead of a server log. Every case leases `OCOREAI_SCRIPTED_ENGINE`: it is process-global, and a
/// value invented by a test must not survive into the next suite (`ProcessGlobalLease`).
import Foundation
import Testing

@testable import ocoreai

@Suite(.serialized)
struct ScriptedEngineTests {

    private static let envKey = ScriptedInference.environmentKey

    /// Writes a script to a unique temp path and points the process at it.
    private func writeScript(_ json: String, lease: ProcessGlobalLease) throws -> String {
        let path = NSTemporaryDirectory() + "ocoreai-script-\(UUID().uuidString).json"
        try Data(json.utf8).write(to: URL(fileURLWithPath: path))
        setenv(Self.envKey, path, 1)
        return path
    }

    /// The text payloads in arrival order, concatenated — order is part of the contract.
    private func text(of events: [InferenceEvent.Kind]) -> String {
        events.reduce("") { soFar, kind in
            if case .text(let chunk) = kind { return soFar + chunk }
            return soFar
        }
    }

    private func collect() async throws -> [InferenceEvent.Kind] {
        var out: [InferenceEvent.Kind] = []
        for try await event in ScriptedInference.stream() {
            out.append(event.kind)
        }
        return out
    }

    @Test("defaults are real — a one-segment script is legal")
    func minimalScriptIsLegal() throws {
        let lease = ProcessGlobalLease(envKeys: [Self.envKey])
        defer { lease.release() }
        _ = try writeScript(#"{"segments":["only one"]}"#, lease: lease)
        // A synthesized Decodable ignores property defaults and demanded every key, which made the
        // documented minimal script a 500 at the wire: this line is that regression.
        let script = try ScriptedInference.load()
        #expect(script.segments == ["only one"])
        #expect(script.reasoning == [])
        #expect(script.toolCalls.isEmpty)
        #expect(script.finishReason == "eos")
        #expect(script.promptTokens == nil)
        #expect(script.generatedTokens == nil)
    }

    @Test("the turn is the script, in order, with the declared counts")
    func streamMatchesTheScript() async throws {
        let lease = ProcessGlobalLease(envKeys: [Self.envKey])
        defer { lease.release() }
        _ = try writeScript(
            """
            {"reasoning":["think"],
             "segments":["A","B"],
             "toolCalls":[{"id":"c1","name":"read_file","arguments":"{\\"path\\":\\"x\\"}"}],
             "finishReason":"eos","promptTokens":7,"generatedTokens":12}
            """,
            lease: lease)
        let got = try await collect()
        #expect(got.count == 5, "reasoning + 2 text + 1 tool call + done, nothing invented")
        guard case .reasoning(let thought) = got[0] else {
            throw SubmissionFailure("event 0 is not reasoning: \(got[0])")
        }
        #expect(thought == "think")
        #expect(text(of: got) == "AB")
        guard case .toolCall(let call) = got[3] else {
            throw SubmissionFailure("event 3 is not a tool call: \(got[3])")
        }
        #expect(call.id == "c1")
        #expect(call.function.name == "read_file")
        #expect(call.function.arguments == "{\"path\":\"x\"}")
        guard
            case .done(
                let reason, let tokenCount, let promptTokenCount, _, _, _,
                let cachedPromptTokens, _, _, _) = got[4]
        else {
            throw SubmissionFailure("last event is not .done: \(got[4])")
        }
        #expect(reason == .eos)
        #expect(tokenCount == 12)
        #expect(promptTokenCount == 7)
        // Invariant 2: a replay reuses no prefix, so it must not arrive owning a cache claim.
        #expect(cachedPromptTokens == nil)
    }

    @Test("an unknown finishReason is a named error, never an empty turn")
    func unknownFinishReasonFailsLoudly() async throws {
        let lease = ProcessGlobalLease(envKeys: [Self.envKey])
        defer { lease.release() }
        _ = try writeScript(#"{"segments":["x"],"finishReason":"bogus"}"#, lease: lease)
        let got = try await collect()
        #expect(got.count == 2, "the text arrives, then the error — no silent .done")
        guard case .error(let message) = got[1] else {
            throw SubmissionFailure("expected .error, got \(got[1])")
        }
        #expect(message.contains("bogus"), "the message must name the offending value: \(message)")
        #expect(
            message.contains(ScriptedInference.environmentKey) || message.contains(".json"),
            "the message must name the script the operator can fix: \(message)")
    }

    @Test("a script that is not there reports the path it looked for")
    func missingScriptNamesThePath() async throws {
        let lease = ProcessGlobalLease(envKeys: [Self.envKey])
        defer { lease.release() }
        let path = NSTemporaryDirectory() + "ocoreai-script-\(UUID().uuidString).json"
        setenv(Self.envKey, path, 1)
        let got = try await collect()
        #expect(got.count == 1)
        guard case .error(let message) = got[0] else {
            throw SubmissionFailure("expected .error, got \(got[0])")
        }
        #expect(message.contains(path), "the refusal must carry the path: \(message)")
    }

    @Test("the switch is the environment, and only the environment")
    func switchIsTheEnvironmentAlone() {
        let lease = ProcessGlobalLease(envKeys: [Self.envKey])
        defer { lease.release() }
        unsetenv(Self.envKey)
        #expect(!ScriptedInference.isEnabled)
        setenv(Self.envKey, "   ", 1)
        #expect(
            !ScriptedInference.isEnabled, "blank is unset: a stray empty env must not arm the lane")
        setenv(Self.envKey, "/tmp/whatever.json", 1)
        #expect(ScriptedInference.isEnabled)
        // These two literals are what the wire publishes; the probe asserts them off the live
        // response, and this pins that the source of that string has not drifted.
        #expect(ScriptedInference.backendName == "scripted")
        #expect(ScriptedInference.modelId == "scripted-model")
    }
}

private struct SubmissionFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
