// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ScriptedInference.swift — a deterministic, model-free inference source behind the real wire.
///
/// Why: a contract claim (SSE framing, tool-call assembly, ledger booking, the fields a client
/// routes by) used to cost a Metal-backed model load, so every verdict took minutes and none of
/// them could be decided in the sandbox tier. The field's agent trees judge their loop against a
/// fake or mock provider instead; this is our version of that seam — the *model* is replaced, the
/// wire is not. Handlers, the tool-call parsers, the SSE writer, dispatch and the delivery ledgers
/// all still execute, so a green verdict here means the wire is green, not a mock server's echo.
///
/// Honesty (invariant 2): while this is on, `GET /v1/capabilities` reports `engineBackend:
/// "scripted"`, and `scripts/eval/run.sh` refuses to score the run. The events carry no timings
/// and no cache-reuse claim — `cachedPromptTokens` stays nil, because a script did not reuse a
/// prefix, it replayed a file.

import Foundation

enum ScriptedInference {

    /// Opt-in switch: the path to a script file. Unset means this code path never runs.
    static let environmentKey = "OCOREAI_SCRIPTED_ENGINE"

    /// The value `engineBackend` takes while a script is driving the wire.
    static let backendName = "scripted"

    /// The id a scripted turn answers to, resolvable only while a script is loaded. It is
    /// deliberately absent from `/v1/models`: nothing here is resident, and a list a client routes
    /// by must not gain a model that cannot be loaded.
    static let modelId = "scripted-model"

    /// The script. Every field is what a real turn would have *produced*; defaults keep a minimal
    /// script (one text segment) legal, and an unknown `finishReason` is an error rather than a
    /// silent fallback to `.eos`.
    struct Script: Decodable {
        /// Text deltas, in order — the same shape `.text` carries from the MLX lane.
        var segments: [String] = []
        /// Reasoning chunks, emitted before any text (upstream routes these separately).
        var reasoning: [String] = []
        /// Tool calls to hand to the real dispatch path.
        var toolCalls: [Call] = []
        /// One of the `StopReason` names: `eos`, `maxTokens`, `stopSequence`, `cancelled`.
        var finishReason: String = "eos"
        /// Declared counts, published as-is: they describe the script, not a measurement.
        var promptTokens: Int?
        var generatedTokens: Int?

        struct Call: Decodable {
            var id: String = ""
            var name: String
            var arguments: String = "{}"

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
                name = try c.decode(String.self, forKey: .name)
                arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? "{}"
            }

            private enum CodingKeys: String, CodingKey { case id, name, arguments }
        }

        // Written by hand because a synthesized Decodable ignores property defaults and demands every
        // key: without this, the documented "one text segment is a legal script" was a 500.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            segments = try c.decodeIfPresent([String].self, forKey: .segments) ?? []
            reasoning = try c.decodeIfPresent([String].self, forKey: .reasoning) ?? []
            toolCalls = try c.decodeIfPresent([Call].self, forKey: .toolCalls) ?? []
            finishReason = try c.decodeIfPresent(String.self, forKey: .finishReason) ?? "eos"
            promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens)
            generatedTokens = try c.decodeIfPresent(Int.self, forKey: .generatedTokens)
        }

        private enum CodingKeys: String, CodingKey {
            case segments, reasoning, toolCalls, finishReason, promptTokens, generatedTokens
        }
    }

    enum ScriptingError: Error, CustomStringConvertible {
        case missingFile(path: String)
        case undecodable(path: String, reason: String)
        case unknownFinishReason(name: String, path: String)

        var description: String {
            switch self {
            case .missingFile(let path): return "scripted engine: no script at \(path)"
            case .undecodable(let path, let reason):
                return "scripted engine: \(path) is not readable as a script (\(reason))"
            case .unknownFinishReason(let name, let path):
                // Every refusal names the file, or an operator running several scripts has to guess
                // which one to edit — the other two cases already do this.
                return "scripted engine: \(path) names finishReason \"\(name)\", which is not a"
                    + " StopReason case (eos | maxTokens | stopSequence | cancelled)"
            }
        }
    }

    private static var scriptPath: String? {
        let value = ProcessInfo.processInfo.environment[environmentKey]
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// True only when an operator pointed us at a script. Nothing else turns this on.
    static var isEnabled: Bool { scriptPath != nil }

    /// Reads the script fresh, so a probe can rewrite it between turns.
    static func load() throws -> Script {
        guard let path = scriptPath else {
            throw ScriptingError.missingFile(path: "<\(environmentKey) unset>")
        }
        let data: Data
        do {
            data = try Data(
                contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } catch {
            throw ScriptingError.missingFile(path: path)
        }
        do {
            return try JSONDecoder().decode(Script.self, from: data)
        } catch {
            throw ScriptingError.undecodable(path: path, reason: String(describing: error))
        }
    }

    private static func stopReason(_ name: String, path: String) -> Result<
        StopReason, ScriptingError
    > {
        switch name {
        case "eos": return .success(.eos)
        case "maxTokens", "max_tokens", "length": return .success(.maxTokens)
        case "stopSequence", "stop_sequence": return .success(.stopSequence)
        case "cancelled": return .success(.cancelled)
        default: return .failure(.unknownFinishReason(name: name, path: path))
        }
    }

    /// The turn, as the engine would have streamed it. Deterministic: no clock, no sampling, no
    /// I/O beyond reading the script once.
    static func stream() -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let script: Script
                do {
                    script = try load()
                } catch {
                    // A broken script is a loud failure, never an empty turn that looks finished.
                    continuation.yield(InferenceEvent(kind: .error(String(describing: error))))
                    continuation.finish()
                    return
                }
                for chunk in script.reasoning {
                    guard !Task.isCancelled else { break }
                    continuation.yield(InferenceEvent(kind: .reasoning(chunk)))
                }
                for chunk in script.segments {
                    guard !Task.isCancelled else { break }
                    continuation.yield(InferenceEvent(kind: .text(chunk)))
                }
                for call in script.toolCalls {
                    guard !Task.isCancelled else { break }
                    continuation.yield(
                        InferenceEvent(
                            kind: .toolCall(
                                ToolCall(
                                    id: call.id,
                                    type: "function",
                                    function: ToolCallFunction(
                                        name: call.name, arguments: call.arguments))))
                    )
                }
                let reason = stopReason(script.finishReason, path: scriptPath ?? "<unset>")
                switch reason {
                case .success(let reason):
                    continuation.yield(
                        InferenceEvent(
                            kind: .done(
                                reason,
                                tokenCount: script.generatedTokens,
                                promptTokenCount: script.promptTokens)))
                case .failure(let error):
                    continuation.yield(InferenceEvent(kind: .error(String(describing: error))))
                }
                continuation.finish()
            }
        }
    }

    /// A handle that carries no session: `_acquireSession` needs resident weights, and the point
    /// of this lane is that nothing is resident. `modelId` still flows through every log line and
    /// ledger key, so the records a turn produces look like any other turn's — the
    /// `engineBackend` field is what tells a reader they are scripted.
    static func handle(modelId: String, pool: EnginePool) -> EngineHandle {
        EngineHandle(modelId: modelId, sessionId: "scripted", pool: pool)
    }
}
