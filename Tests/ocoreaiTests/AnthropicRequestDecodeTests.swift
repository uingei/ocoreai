// AnthropicRequestDecodeTests.swift — Regression gate for POST /v1/messages request
// decoding. Anthropic marks `stream` optional (absent = false), so a spec-legal
// client that omits it must still decode. Live probe 10-13 (macOS 26):
// `{"model","max_tokens","messages"}` → HTTP 400 "Coding key `stream` not found."

import Foundation
import Testing

@testable import ocoreai

private struct MissingSource: Error, CustomStringConvertible {
    let path: String
    var description: String { "could not find \(path) walking up from the test file" }
}

/// Reads a repo source file by locating the root from this file's path — never a fixed
/// number of `deletingLastPathComponent()` hops, which is how a "passing" scan turns out
/// to have read nothing.
private func source(_ relative: String) throws -> String {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0 ..< 8 {
        let candidate = dir.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return try String(contentsOf: candidate, encoding: .utf8)
        }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    throw MissingSource(path: "\(dir.path)/\(relative)")
}

private let modelsSource = "Sources/ocoreai/Models/AnthropicModels.swift"
private let handlerSource = "Sources/ocoreai/Handlers/AnthropicMessagesHandler.swift"
private let routerSource = "Sources/ocoreai/Router/ChatCompletionsRouter.swift"

@Suite("AnthropicMessageRequest decoding — Anthropic optional fields")
struct AnthropicRequestDecodeTests {

    /// Absent `stream` decodes as "not set" and must reach the engine as false.
    @Test("stream omitted decodes and maps to false")
    func streamOmitted() throws {
        let json = """
            {"model":"m","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}
            """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: Data(json.utf8))
        #expect(req.model == "m")
        #expect(req.maxTokens == 16)
        #expect(req.stream == nil, "absent `stream` must not be a decode error")
        #expect(try toChatCompletionRequest(req).stream == false)
    }

    @Test("stream true and false decode as sent")
    func streamExplicit() throws {
        for (flag, expected) in [(true, true), (false, false)] {
            let json =
                "{\"model\":\"m\",\"stream\":\(flag),\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
            let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: Data(json.utf8))
            #expect(req.stream == expected)
            #expect(try toChatCompletionRequest(req).stream == expected)
        }
    }

    /// Anthropic `system` is `string | [text block]`; the SDK emits the block
    /// form whenever a system block carries `cache_control`. A `String?` field
    /// rejected it, which 400'd the whole body before the conversation could
    /// reach a server that was ready to serve it.
    @Test("system as a text-block array decodes and flattens")
    func systemAsTextBlocks() throws {
        let json = """
            {"model":"m","max_tokens":16,\
            "system":[{"type":"text","text":"be terse","cache_control":{"type":"ephemeral"}},\
            {"type":"text","text":"in English"}],\
            "messages":[{"role":"user","content":"hi"}]}
            """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: Data(json.utf8))
        #expect(req.system?.text == "be terse\nin English")
        #expect(try toChatCompletionRequest(req).system == "be terse\nin English")
    }

    @Test("system as a plain string keeps working, and absent stays absent")
    func systemAsStringOrAbsent() throws {
        let stringSystem =
            #"{"model":"m","max_tokens":16,"system":"be terse","messages":[{"role":"user","content":"hi"}]}"#
        let req = try JSONDecoder().decode(
            AnthropicMessageRequest.self, from: Data(stringSystem.utf8))
        #expect(req.system?.text == "be terse")
        #expect(try toChatCompletionRequest(req).system == "be terse")

        let absent = #"{"model":"m","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}"#
        let bare = try JSONDecoder().decode(
            AnthropicMessageRequest.self, from: Data(absent.utf8))
        #expect(bare.system == nil, "absent `system` must not be a decode error")
        #expect(try toChatCompletionRequest(bare).system == nil)
    }

    /// What the Anthropic mapping owns, decided offline: the conversation, with the agent
    /// context left for the shared assembly.
    ///
    /// `/v1/messages` and `/v1/messages/count_tokens` count ONE list — both routes call
    /// `buildAnthropicMessageList`, so a pre-flight cannot budget less than the request it
    /// precedes. That equality is structural (one builder, two callers; the call sites are
    /// pinned by the source scan in `AnthropicToolDeliveryTests`) and measured live by
    /// probe 13 §8, which asserts `count_tokens` equals the same request's own
    /// `usage.input_tokens`.
    ///
    /// `system` is NOT inserted here: it is the caller's system prompt, and the shared
    /// assembly composes it with the agent's own context in codex's precedence order
    /// (user instructions, then workspace/skills/memory) — the same field
    /// `/v1/chat/completions` uses, so both faces give the model the same product context.
    /// `tools[]` is not message text here either: it travels as the structured declaration.
    @Test("the mapping carries the conversation and hands system + tools to the shared assembly")
    func conversationMappingKeepsSystemAndToolsForTheSharedAssembly() throws {
        let json = """
            {"model":"m","max_tokens":16,"system":"be terse",\
            "tools":[{"name":"run_shell","description":"Run a shell command"}],\
            "messages":[{"role":"user","content":"ls"}]}
            """
        let req = try JSONDecoder().decode(AnthropicMessageRequest.self, from: Data(json.utf8))
        let built = try anthropicConversationMessages(request: req)
        #expect(built.map(\.role) == ["user"], "the mapping adds no system turn of its own")
        #expect(built.last?.textContent() == "ls")
        // …and neither declaration is lost on the way to the internal request.
        let internalRequest = try toChatCompletionRequest(req)
        #expect(internalRequest.system == "be terse", "the caller's system prompt is carried")
        #expect(
            internalRequest.tools?.map { $0.function.name } == ["run_shell"],
            "tools reach the engine as specs")
    }
}

// MARK: - Key coverage: a declared wire key must arrive, and must be read

/// Two ways for a wire field to be a lie, both live here at some point:
///   * declared in `CodingKeys` and never decoded — the client's bytes are dropped on the
///     floor (`CompletionRequestKeyCoverageTests` gates the same axis one DTO over);
///   * decoded into a property that nothing reads — the field arrives and dies. That second
///     one is what this DTO carried twice on 10-31: `user_id` (decoded, read nowhere), and
///     `response_format` one property deeper (decoded, then overwritten by a literal `nil`
///     at all three sites that could have used it). Both answered 200 with the client's
///     request unkept and nothing said so.
///
/// The property list is read off the real `CodingKeys` block, not typed in here: a list
/// maintained by hand drifts the day a key is added, which is the event under test.
@Suite("AnthropicMessageRequest keys — declared keys arrive, and are read")
struct AnthropicMessageRequestKeyCoverageTests {

    /// A body carrying every declared key, each value distinct from its default. Built by
    /// serializing a dictionary: hand-spliced JSON is where a missing comma becomes a test
    /// that decodes nothing and asserts nothing.
    private static func bodyWithEveryKey() throws -> Data {
        let schema: [String: Any] = ["type": "object"]
        let format: [String: Any] = ["type": "json_schema", "schema": schema]
        let tool: [String: Any] = ["name": "run_shell", "description": "Run a shell command"]
        let fields: [String: Any] = [
            "model": "cov-model",
            "system": "be terse",
            "messages": [["role": "user", "content": "7 * 8?"]],
            "temperature": 0.25,
            "top_p": 0.5,
            "top_k": 21,
            "max_tokens": 99,
            "stop_sequences": ["\n\n"],
            "tools": [tool],
            "tool_choice": ["type": "any"],
            "stream": true,
            "output_config": ["format": format],
            "thinking": ["type": "disabled"],
            "metadata": ["session_id": "s-1"],
        ]
        return try JSONSerialization.data(withJSONObject: fields)
    }

    @Test("every declared wire key lands on its property, not on a default")
    func allDeclaredKeysDecode() throws {
        let req = try JSONDecoder().decode(
            AnthropicMessageRequest.self, from: Self.bodyWithEveryKey())
        #expect(req.model == "cov-model")
        #expect(req.system?.text == "be terse")
        #expect(req.messages.count == 1)
        #expect(req.temperature == 0.25)
        #expect(req.topP == 0.5)
        #expect(req.topK == 21)
        #expect(req.maxTokens == 99)
        #expect(req.stopSequences == ["\n\n"])
        #expect(req.tools?.first?.name == "run_shell")
        #expect(req.toolChoice?.type == "any")
        #expect(req.stream == true)
        #expect(req.outputConfig?.format?.type == "json_schema")
        #expect(req.thinking?.type == "disabled")
        #expect(req.metadata?.sessionId == "s-1")
    }

    @Test("an absent key stays unset — the floor under the test above")
    func absentKeysStayUnset() throws {
        let minimal =
            #"{"model":"m","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}"#
        let req = try JSONDecoder().decode(
            AnthropicMessageRequest.self, from: Data(minimal.utf8))
        #expect(req.system == nil)
        #expect(req.temperature == nil)
        #expect(req.topP == nil)
        #expect(req.topK == nil)
        #expect(req.stopSequences == nil)
        #expect(req.tools == nil)
        #expect(req.toolChoice == nil)
        #expect(req.stream == nil)
        #expect(req.outputConfig == nil)
        #expect(req.thinking == nil)
        #expect(req.metadata == nil)
    }

    /// The second half: a property nothing reads is the same lie as a key nothing decodes.
    /// The consumer set is closed and small — this DTO is decoded in the router, translated
    /// in the model file, and served by the handler — so those three files are exactly where
    /// a read of one of its keys can live. Reads are matched on the binding that holds the
    /// decoded value, not on a bare `.key`: the handler has an OpenAI request in scope too,
    /// and `chatRequest.temperature` would otherwise stand in for a read that is not there.
    @Test("no declared key is decoded into a property nothing reads")
    func everyDeclaredKeyIsRead() throws {
        let names = try Self.declaredKeys()
        #expect(names.count >= 12, "the scan found \(names.count) keys: \(names)")

        var haystacks: [String] = []
        for file in [modelsSource, handlerSource, routerSource] {
            let text = try source(file)
            #expect(
                text.contains("AnthropicMessageRequest"),
                "\(file) no longer mentions this DTO — is it still a consumer?")
            haystacks.append(try Self.codeOnly(text))
        }

        var unread: [String] = []
        for name in names {
            let pattern = "(?:anthropicRequest|countRequest|request|req)\\.\(name)\\b"
            let read = haystacks.contains { hay in
                Self.matches(pattern, in: hay)
            }
            if !read { unread.append(name) }
        }
        let verdict =
            "decoded and unread is a field a client can set with no effect and no word: "
            + "\(unread). If a consumer renamed its binding, add it to the pattern above."
        #expect(unread.isEmpty, Comment(rawValue: verdict))
    }

    /// The property names declared by `AnthropicMessageRequest`'s own `CodingKeys`, read off
    /// the source (comments excluded, same convention as the `git grep` claim markers).
    private static func declaredKeys() throws -> [String] {
        let lines = try source(modelsSource).components(separatedBy: "\n")
        var inStruct = false
        var inKeys = false
        var names: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.hasPrefix("*") { continue }
            if !inStruct {
                if line.hasPrefix("struct AnthropicMessageRequest") { inStruct = true }
                continue
            }
            if raw == "}" { break }
            if !inKeys {
                if line.hasPrefix("enum CodingKeys") { inKeys = true }
                continue
            }
            if raw == "    }" { break }
            guard line.hasPrefix("case ") else { continue }
            for part in line.dropFirst(5).components(separatedBy: ",") {
                let token = part.trimmingCharacters(in: .whitespaces)
                let declared = token.components(separatedBy: "=").first ?? token
                let name = declared.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { names.append(name) }
            }
        }
        return names
    }

    /// Comment lines out of a source file: prose that names a field is not a read of it.
    private static func codeOnly(_ text: String) throws -> String {
        text.components(separatedBy: "\n")
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("//") && !t.hasPrefix("*") && !t.hasPrefix("/*")
            }
            .joined(separator: "\n")
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard
            let re = try? NSRegularExpression(
                pattern: pattern, options: [.anchorsMatchLines])
        else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
