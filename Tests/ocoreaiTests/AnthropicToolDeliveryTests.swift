// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AnthropicToolDeliveryTests.swift — `/v1/messages` must be able to deliver a tool call.
///
/// Live 10-19, `gemma-4-e2b-it-4bit`, temperature 0, with `tools:[get_weather]` and
/// "Use the get_weather tool to check the weather in Paris.":
/// `stop_reason:"end_turn"`, `content:[{"type":"text","text":"Which city are you
/// interested in? Please specify the city name."}]`. The model was never told the tool
/// existed in a form the engine reads, and a call it did make had no block to arrive in.
/// Four defects sat at one seam — declaration, event, response shape, schema — and none
/// of them had a gate: every tool test in the suite is written against the OpenAI face,
/// so the whole suite stayed green while this face answered prose. These tests pin all
/// four, and the source-scan guards assert their own premises so a scan that stopped
/// matching fails instead of passing vacuously.

import Foundation
import Testing

@testable import ocoreai

private struct MissingSource: Error, CustomStringConvertible {
    let path: String
    var description: String { "could not find \(path) walking up from the test file" }
}

/// Reads a repo source file by locating the root from this file's path, never by a fixed
/// number of `deletingLastPathComponent()` hops (`V1EndpointCatalogTests` carries the
/// failure this rule comes from).
private func source(_ relative: String) throws -> String {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0 ..< 6 {
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

private let handlerSource =
    "Sources/ocoreai/Handlers/AnthropicMessagesHandler.swift"
private let modelsSource =
    "Sources/ocoreai/Models/AnthropicModels.swift"

private func wireJSON<T: Encodable>(_ value: T) -> [String: Any] {
    let data = try! JSONEncoder().encode(value)
    return (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

private let weatherToolJSON =
    """
    {"name":"get_weather","description":"Get the weather for a city",\
    "input_schema":{"type":"object","properties":{"city":{"type":"string"}},\
    "required":["city"]}}
    """

@Suite("Anthropic tools — declaration reaches the engine")
struct AnthropicToolDeclarationTests {

    /// The four `tool_choice` variants, in the vocabulary our one forcing rule speaks.
    @Test(
        arguments: [
            (#"{"type":"auto"}"#, "auto"),
            (#"{"type":"none"}"#, "none"),
            (#"{"type":"any"}"#, "required"),
            (#"{"type":"tool","name":"get_weather"}"#, "function:get_weather"),
        ]
    )
    func toolChoiceVocabulary(json: String, vocabulary: String) throws {
        #expect(try decode(AnthropicToolChoice.self, json).openAIVocabulary == vocabulary)
    }

    /// A pinned choice carries its tool; the others carry none.
    @Test("only the pinned variant names a tool")
    func toolChoiceName() throws {
        let pinned = try decode(AnthropicToolChoice.self, #"{"type":"tool","name":"get_weather"}"#)
        #expect(pinned.name == "get_weather")
        #expect(try decode(AnthropicToolChoice.self, #"{"type":"auto"}"#).name == nil)
    }

    /// `any` must read as a demand, `auto`/`none` must not. Fire on the declaration
    /// instead and every declaring request loses its answer (round 18); never fire and
    /// `tool_choice:"any"` is decoration.
    @Test("the mapped vocabulary drives the shared forcing rule")
    func forcingFollowsDemand() throws {
        let tools = [try decode(AnthropicTool.self, weatherToolJSON).toOpenAITool()]
        let any = try decode(AnthropicToolChoice.self, #"{"type":"any"}"#).openAIVocabulary
        let auto = try decode(AnthropicToolChoice.self, #"{"type":"auto"}"#).openAIVocabulary
        let none = try decode(AnthropicToolChoice.self, #"{"type":"none"}"#).openAIVocabulary
        #expect(
            shouldConstrainOutput(declaredTools: tools, responseFormat: nil, toolChoice: any)
                == true)
        #expect(
            shouldConstrainOutput(declaredTools: tools, responseFormat: nil, toolChoice: auto)
                == false)
        #expect(
            shouldConstrainOutput(declaredTools: tools, responseFormat: nil, toolChoice: none)
                == false)
    }

    /// `input_schema` is a JSON Schema and the engine needs the whole of it: bare
    /// `properties` names no object and requires nothing, so a forced call could not be
    /// filled and the grammar lost the key the caller marked required.
    @Test("input_schema converts to a complete JSON Schema, not bare properties")
    func parametersKeepTypeAndRequired() throws {
        let tool = try decode(AnthropicTool.self, weatherToolJSON)
        let params = try #require(tool.toOpenAITool().function.parameters)
        let flattened = try #require(flattenJSONValue(params) as? [String: Any])
        #expect(flattened["type"] as? String == "object")
        #expect(flattened["required"] as? [String] == ["city"])
        let properties = try #require(flattened["properties"] as? [String: Any])
        let city = try #require(properties["city"] as? [String: Any])
        #expect(city["type"] as? String == "string")
    }

    /// A schema that names no keys stays an open object — `{"type":"object",
    /// "properties":{}}` would pin zero keys (round 19's `jsonObjectSchema`).
    @Test("an object schema with no keys stays open")
    func schemaWithoutKeysStaysOpen() throws {
        let tool = try decode(
            AnthropicTool.self, #"{"name":"now","input_schema":{"type":"object"}}"#)
        let params = try #require(tool.toOpenAITool().function.parameters)
        let flattened = try #require(flattenJSONValue(params) as? [String: Any])
        #expect(flattened["type"] as? String == "object")
        #expect(flattened.keys.contains("properties") == false)
        #expect(flattened.keys.contains("required") == false)
    }

    /// A caller that sent no schema at all gets no schema back — the server invents
    /// requirements nobody asked for, but still declares the tool by name so the model
    /// can call it and the caller can run it.
    @Test("a null input_schema invents no schema, and the tool stays declared")
    func nullSchemaInventsNothing() throws {
        let tool = try decode(AnthropicTool.self, #"{"name":"now","input_schema":null}"#)
        let converted = tool.toOpenAITool()
        #expect(converted.function.parameters == nil)
        #expect(converted.function.name == "now")
    }

    /// The key the grammar needs to know which arguments are mandatory. `AnyCodable`
    /// boxes `["city"]` as `[AnyCodable]`, so a naive `as? [String]` lost it and every
    /// constrained call was free to omit the one required argument.
    @Test("required survives the AnyCodable boxing")
    func requiredSurvivesBoxes() throws {
        let schema = try decode(
            AnthropicToolInputSchema.self,
            #"{"type":"object","properties":{"city":{"type":"string"},"unit":{"type":"string"}},"required":["city"]}"#
        )
        #expect(schema.required == ["city"])
        let flattened = try #require(
            flattenJSONValue(schema.toOpenAIParameters() ?? [:]) as? [String: Any])
        #expect(flattened["required"] as? [String] == ["city"])
        #expect(flattened.keys.contains("properties"))
    }

    /// The declaration the engine actually reads: caller specs with their schemas intact,
    /// so a tool this server does not register is still declarable and callable.
    @Test("the caller's spec survives into declaredToolSpecsJSON")
    func declaredSpecsCarrySchemas() throws {
        let tool = try decode(AnthropicTool.self, weatherToolJSON)
        let json = try #require(openAIToolSpecsJSON(from: [tool.toOpenAITool()]))
        let parsed = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let function = try #require(parsed.first?["function"] as? [String: Any])
        #expect(function["name"] as? String == "get_weather")
        let parameters = try #require(function["parameters"] as? [String: Any])
        #expect(parameters["required"] as? [String] == ["city"])
        #expect(parameters["type"] as? String == "object")
    }

    /// The request-level conversion carries the demand too, so the wire DTO and the
    /// engine options cannot disagree about whether a call was asked for.
    @Test("toChatCompletionRequest maps tools and tool_choice onto the internal request")
    func convertedRequestCarriesToolChoice() throws {
        let any = try decode(
            AnthropicMessageRequest.self,
            #"{"model":"m","max_tokens":32,"messages":[{"role":"user","content":"hi"}],"tools":[{"name":"get_weather"}],"tool_choice":{"type":"any"}}"#
        )
        let converted = try toChatCompletionRequest(any)
        #expect(converted.toolChoice == "required")
        #expect(converted.tools?.map { $0.function.name } == ["get_weather"])
        let none = try decode(
            AnthropicMessageRequest.self,
            #"{"model":"m","max_tokens":32,"messages":[{"role":"user","content":"hi"}],"tools":[{"name":"get_weather"}],"tool_choice":{"type":"none"}}"#
        )
        #expect(try toChatCompletionRequest(none).toolChoice == "none")
    }
}

@Suite("Anthropic tools — the response shapes clients read")
struct AnthropicToolResponseShapeTests {

    /// SDKs open a block from `content_block.type`; an event without `content_block`
    /// gives them nothing to open.
    @Test("content_block_start names a text block")
    func textBlockStartCarriesContentBlock() throws {
        let e = wireJSON(AnthropicStreamEvent.contentBlockStart(index: 0))
        #expect(e["type"] as? String == "content_block_start")
        #expect(e["index"] as? Int == 0)
        let block = try #require(e["content_block"] as? [String: Any])
        #expect(block["type"] as? String == "text")
        #expect(block["text"] as? String == "")
    }

    @Test("content_block_start names a tool_use block with id, name and empty input")
    func toolUseBlockStartShape() throws {
        let e = wireJSON(
            AnthropicStreamEvent.toolUseBlockStart(index: 1, id: "toolu_1", name: "get_weather"))
        #expect(e["type"] as? String == "content_block_start")
        #expect(e["index"] as? Int == 1)
        let block = try #require(e["content_block"] as? [String: Any])
        #expect(block["type"] as? String == "tool_use")
        #expect(block["id"] as? String == "toolu_1")
        #expect(block["name"] as? String == "get_weather")
        #expect((block["input"] as? [String: Any])?.isEmpty == true)
    }

    /// Anthropic's carrier for arguments is `input_json_delta`/`partial_json` — OpenAI's
    /// `function.arguments` for the same bytes.
    @Test("input_json_delta carries partial_json and no text key")
    func inputJsonDeltaShape() throws {
        let e = wireJSON(
            AnthropicStreamEvent.inputJsonDelta(index: 1, partialJson: #"{"city":"Paris"}"#))
        #expect(e["type"] as? String == "content_block_delta")
        #expect(e["index"] as? Int == 1)
        let d = try #require(e["delta"] as? [String: Any])
        #expect(d["type"] as? String == "input_json_delta")
        #expect(d["partial_json"] as? String == #"{"city":"Paris"}"#)
        #expect(d.keys.contains("text") == false)
    }

    @Test("a tool_use content block encodes id, name, input — and no text key")
    func toolUseBlockEncodes() {
        let input: [String: AnyCodable] = ["city": AnyCodable("Paris")]
        let e = wireJSON(
            AnthropicAssistantContent(toolUseId: "toolu_9", name: "get_weather", input: input))
        #expect(e["type"] as? String == "tool_use")
        #expect(e["id"] as? String == "toolu_9")
        #expect(e["name"] as? String == "get_weather")
        #expect((e["input"] as? [String: Any])?["city"] as? String == "Paris")
        #expect(e.keys.contains("text") == false)
    }

    @Test("a text content block encodes text — and no tool_use keys")
    func textBlockEncodesUnchanged() {
        let e = wireJSON(AnthropicAssistantContent(text: "hello"))
        #expect(e["type"] as? String == "text")
        #expect(e["text"] as? String == "hello")
        #expect(e.keys.contains("id") == false)
        #expect(e.keys.contains("name") == false)
        #expect(e.keys.contains("input") == false)
    }

    /// `input` must be an object. A payload that is not one is refused rather than
    /// laundered into `{}`: a client would otherwise execute a call with arguments the
    /// model never sent.
    @Test(
        arguments: [
            (#"{"city":"Paris"}"#, true),
            ("{}", true),
            ("not json", false),
            ("\"Paris\"", false),
            ("[1,2]", false),
            ("null", false),
        ]
    )
    func toolInputOnlyAcceptsObjects(raw: String, isObject: Bool) {
        let parsed = anthropicToolInput(fromJSON: raw)
        if isObject {
            #expect(parsed != nil, "\(raw) is a JSON object and must decode")
        } else {
            #expect(parsed == nil, "\(raw) is not a JSON object and must be refused")
        }
    }
}

@Suite("Anthropic tools — the handler wires the one tool path")
struct AnthropicToolPathSourceTests {

    /// The scan's own premises: the file it reads is the handler, and both modes are
    /// present in it. Without this, a renamed symbol or a moved file would make every
    /// guard below pass vacuously.
    @Test(
        "the source scan is looking at the real handler",
        arguments: [
            "private func nonStreamAnthropicResponse(",
            "private func streamAnthropicResponse(",
            "func buildAnthropicMessageList(",
        ]
    )
    func scanSeesTheHandler(marker: String) throws {
        let s = try source(handlerSource)
        #expect(s.contains(marker), "handler scan found no \(marker) — file or symbol moved")
    }

    /// Declaration: this face assembles the same options as the OpenAI face, from the
    /// same helpers. If any disappears, tools on this wire go back to being prompt
    /// decoration the engine never reads.
    @Test(
        "the handler declares the surface it was given",
        arguments: [
            "shouldConstrainOutput(",
            "grammarSchema: grammarSchema",
            "hasNativeTools: declaredTools?.isEmpty == false",
            "declaredToolNames: declaredToolNames",
            "declaredToolSpecsJSON: openAIToolSpecsJSON(from: declaredTools)",
        ]
    )
    func declarationAssembly(marker: String) throws {
        #expect(try source(handlerSource).contains(marker), "handler missing \(marker)")
    }

    /// The demand enters the internal request once, at the conversion, not a second time
    /// re-derived in the handler.
    @Test("the conversion carries the choice vocabulary")
    func modelsFileMapsChoice() throws {
        #expect(try source(modelsSource).contains("toolChoice: req.toolChoice?.openAIVocabulary"))
    }

    /// Both modes consume `.toolCall` — round 18's lesson was that SSE delivered while
    /// non-stream dropped. Exactly two sites, so a mode that drops it is a red test.
    @Test("both modes collect the engine's calls and record delivery")
    func bothModesCollectCalls() throws {
        let s = try source(handlerSource)
        #expect(s.components(separatedBy: "case .toolCall(let tc):").count - 1 == 2)
        #expect(
            s.components(separatedBy: "await enginePool.recordToolCallDelivery(").count - 1 == 2)
    }

    /// There is exactly one route by which a declared tool reaches the model. A second
    /// copy in system text is what let the model see a tool name with no parameters.
    @Test("tool definitions are not also injected as system text")
    func noSecondDeclarationTruth() throws {
        let s = try source(handlerSource)
        #expect(s.contains("Available tools:") == false)
        #expect(s.contains("You have access to the following tools:") == false)
    }
}

@Suite("Anthropic SSE — answer text never leaks as a tool call")
struct AnthropicStreamTextSettleTests {

    private func types(_ events: [AnthropicStreamEvent]) -> [String] {
        events.map { $0.type }
    }

    /// The measured shape of the leak: a calls-only grammar makes the model *write*
    /// `[{…}]`, and a writer that ships text as it arrives hands that JSON to the client
    /// as prose. So text starting `[`/`{` waits for the answer to settle.
    @Test("a payload-shaped answer is held, not streamed")
    func payloadShapedTextIsHeld() {
        var emitter = AnthropicStreamEmitter()
        let held = emitter.feedText("[\n  {\n    \"name\": \"get_weather\",")
        #expect(held.isEmpty, "a call payload must not leave as text deltas")
    }

    /// Prose has to keep streaming — holding every turn until EOS would trade a tool-call
    /// fix for first-token latency on the whole wire.
    @Test("prose releases immediately and keeps streaming")
    func proseStreams() {
        var emitter = AnthropicStreamEmitter()
        let first = emitter.feedText("Paris is")
        #expect(types(first) == ["content_block_start", "content_block_delta"])
        let next = emitter.feedText(" rainy.")
        #expect(types(next) == ["content_block_delta"], "an open text block keeps streaming")
    }

    /// A recognised call closes the prose block and takes the next index, so a turn with
    /// both stays addressable per Anthropic's block numbering.
    @Test("prose then a call gives the call its own block index")
    func proseThenCallNumbering() {
        var emitter = AnthropicStreamEmitter()
        _ = emitter.feedText("Checking now.")
        let events = emitter.emitToolCall(
            id: "toolu_1", name: "get_weather", arguments: "{\"city\":\"Paris\"}")
        let payload = events.map { wireJSON($0) }
        // The prose had already streamed, so this call closes it and opens its own block.
        #expect(
            payload.map { ($0["type"] as? String) ?? "?" }
                == ["content_block_stop", "content_block_start", "content_block_delta"])
        let stops = payload.filter { ($0["type"] as? String) == "content_block_stop" }
        #expect(stops.first?["index"] as? Int == 0, "the text block closed at index 0")
        let starts = payload.filter { ($0["type"] as? String) == "content_block_start" }
        #expect(starts.first?["index"] as? Int == 1, "the tool_use block opens at index 1")
        let block = starts.first?["content_block"] as? [String: Any]
        #expect(block?["type"] as? String == "tool_use")
    }

    /// The fix's whole point: when the settled answer turns out to be calls, the held
    /// text is dropped — a client gets the structured block and never a JSON blob to
    /// render as an answer.
    @Test("a settled payload is delivered as blocks, never as text")
    func settledPayloadNeverLeaks() {
        var emitter = AnthropicStreamEmitter()
        let payload =
            "[\n  {\n    \"name\": \"get_weather\",\n    \"arguments\": {\"city\":\"Paris\"}\n  }\n]"
        for piece in payload.map(String.init) {
            #expect(emitter.feedText(piece).isEmpty)
        }
        emitter.discardPendingText()
        let events =
            emitter.emitToolCall(
                id: "toolu_2", name: "get_weather", arguments: "{\"city\":\"Paris\"}")
            + emitter.close()
        var names: [String] = []
        var text = ""
        for event in events {
            let json = wireJSON(event)
            if let block = json["content_block"] as? [String: Any],
                block["type"] as? String == "tool_use"
            {
                names.append(block["name"] as? String ?? "")
            }
            if let delta = json["delta"] as? [String: Any] {
                text += delta["text"] as? String ?? delta["partial_json"] as? String ?? ""
            }
        }
        #expect(names == ["get_weather"], "the tool_use block names the tool")
        #expect(text == "{\"city\":\"Paris\"}", "arguments travel as partial_json only: \(text)")
        #expect(
            text.range(of: "\"name\"") == nil,
            "the raw call dialect must not reach the client as text: \(text)")
        #expect(types(events).last == "content_block_stop", "the tool_use block is closed")
    }

    /// A turn that produced nothing still gets one empty text block — strict SDKs index
    /// `content[0]` after opening a stream (vllm serving.py:879-883).
    @Test("an empty turn still opens and closes one text block")
    func emptyTurnKeepsOneBlock() {
        var emitter = AnthropicStreamEmitter()
        let events = emitter.ensureSomeBlock() + emitter.close()
        let payload = events.map { wireJSON($0) }
        #expect(
            payload.map { ($0["type"] as? String) ?? "?" }
                == ["content_block_start", "content_block_stop"])
        let block = payload.first?["content_block"] as? [String: Any]
        #expect(block?["type"] as? String == "text")
        #expect(block?["text"] as? String == "")
        #expect(payload.last?["index"] as? Int == 0)
    }

    /// Held prose that never became a call must not vanish with the stream.
    @Test("held prose is released at stream end")
    func heldProseIsReleased() {
        var emitter = AnthropicStreamEmitter()
        #expect(emitter.feedText("[").isEmpty, "a lone bracket is undecided")
        let events = emitter.flushText() + emitter.close()
        let payload = events.map { wireJSON($0) }
        #expect(
            payload.map { ($0["type"] as? String) ?? "?" }
                == ["content_block_start", "content_block_delta", "content_block_stop"])
        let delta = payload[1]["delta"] as? [String: Any]
        #expect(delta?["text"] as? String == "[")
    }
}
