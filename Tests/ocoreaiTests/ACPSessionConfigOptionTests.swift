import Foundation
import Testing

@testable import ocoreai

/// `session/new` must carry a model `configOptions` selector, and
/// `session/set_config_option` must answer with the full option state or refuse by name —
/// the v1 face the editor's model picker drives. Gated against the same live line shapes
/// probe 62 checks; here the option list is the test's own, so the compared values are
/// literals and never what happens to sit on this host's disk.
@MainActor
@Suite("ACP config options — model selector 上线、设置、拒绝语", .serialized)
struct ACPSessionConfigOptionTests {

    @MainActor
    private final class Capture {
        var lines: [Data] = []
    }

    /// No store is needed: session/new and session/set_config_option never read it, and a
    /// nil store keeps a wrong turn of these handlers visible as an internal error line.
    private func openAgent(models: [String]) -> (ACPAgent, Capture) {
        let capture = Capture()
        let agent = ACPAgent(
            write: { capture.lines.append($0) },
            store: { nil },
            models: { models })
        agent.becomeReady()
        return (agent, capture)
    }

    private func objects(_ capture: Capture) -> [[String: Any]] {
        capture.lines.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private func receive(_ agent: ACPAgent, _ line: String) {
        agent.receive(line)
    }

    @MainActor
    private func waitFor(_ capture: Capture, count: Int) async throws {
        for _ in 0 ..< 500 {
            if capture.lines.count >= count { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let arrived = capture.lines.prefix(4).compactMap { String(data: $0, encoding: .utf8) }
        Issue.record(
            "only \(capture.lines.count) of \(count) promised lines arrived; first: \(arrived)")
    }

    private let initializeLine =
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#

    @MainActor
    private func openSession(
        models: [String]
    ) async throws -> (ACPAgent, Capture, String) {
        let (agent, capture) = openAgent(models: models)
        receive(agent, initializeLine)
        receive(
            agent,
            #"{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}"#
        )
        try await waitFor(capture, count: 2)
        let result = try #require(objects(capture).last?["result"] as? [String: Any])
        let sessionId = try #require(result["sessionId"] as? String)
        return (agent, capture, sessionId)
    }

    /// The `configOptions` array decoded back through the wire type, so a field the agent
    /// renders under another name cannot satisfy the comparison.
    private func configOptions(from result: [String: Any]) throws -> [ACPSessionConfigOption] {
        let json = try #require(result["configOptions"])
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode([ACPSessionConfigOption].self, from: data)
    }

    @Test("session/new answers the model selector with the first choice as current")
    func newSessionCarriesModelOption() async throws {
        let (_, capture, _) = try await openSession(models: ["a/model-a", "b/model-b"])
        let result = try #require(objects(capture).last?["result"] as? [String: Any])
        let options = try configOptions(from: result)
        #expect(options.count == 1, "this build publishes exactly one selector: the model")
        let model = try #require(options.first)
        #expect(model.id == "model")
        #expect(model.name == "Model")
        #expect(model.category == "model")
        #expect(model.type == "select")
        // No engine is booted here, so there is no configured default: the honest current
        // value is the first published choice, and `runTurn` turns with exactly that.
        #expect(model.currentValue == "a/model-a")
        #expect(model.options.map { $0.value } == ["a/model-a", "b/model-b"])
        #expect(model.options.map { $0.name } == ["a/model-a", "b/model-b"])
    }

    @Test("set_config_option switches the model and answers with the full updated state")
    func setSwitchesAndAnswersFullState() async throws {
        let (agent, capture, sessionId) = try await openSession(
            models: ["a/model-a", "b/model-b"])
        receive(
            agent,
            #"{"jsonrpc":"2.0","id":3,"method":"session/set_config_option","params":{"sessionId":"\#(sessionId)","configId":"model","value":"b/model-b"}}"#
        )
        try await waitFor(capture, count: 3)
        let result = try #require(objects(capture).last?["result"] as? [String: Any])
        let options = try configOptions(from: result)
        let model = try #require(options.first)
        #expect(
            model.currentValue == "b/model-b",
            "the response carries the value the client just set")
        #expect(
            model.options.map { $0.value } == ["a/model-a", "b/model-b"],
            "the response is the COMPLETE option state, not a delta")
    }

    @Test(
        "unknown configId, unknown value, boolean value, foreign session: each refused by name")
    func refusals() async throws {
        let (agent, capture, sessionId) = try await openSession(
            models: ["a/model-a", "b/model-b"])

        receive(
            agent,
            #"{"jsonrpc":"2.0","id":4,"method":"session/set_config_option","params":{"sessionId":"\#(sessionId)","configId":"speed","value":"fast"}}"#
        )
        try await waitFor(capture, count: 3)
        var error = try #require(objects(capture).last?["error"] as? [String: Any])
        #expect(error["code"] as? Int == ACPFraming.invalidParamsCode)
        #expect(
            (error["message"] as? String)?.contains("speed") == true,
            "the refusal quotes the configId the client sent")

        receive(
            agent,
            #"{"jsonrpc":"2.0","id":5,"method":"session/set_config_option","params":{"sessionId":"\#(sessionId)","configId":"model","value":"zz/never-downloaded-4bit"}}"#
        )
        try await waitFor(capture, count: 4)
        error = try #require(objects(capture).last?["error"] as? [String: Any])
        #expect(error["code"] as? Int == ACPFraming.invalidParamsCode)
        #expect(
            (error["message"] as? String)?.contains("zz/never-downloaded-4bit") == true,
            "a value off the published list is refused by name — v1 requires one of options")

        receive(
            agent,
            #"{"jsonrpc":"2.0","id":6,"method":"session/set_config_option","params":{"sessionId":"\#(sessionId)","configId":"model","type":"boolean","value":true}}"#
        )
        try await waitFor(capture, count: 5)
        error = try #require(objects(capture).last?["error"] as? [String: Any])
        #expect(error["code"] as? Int == ACPFraming.invalidParamsCode)
        #expect(
            (error["message"] as? String)?.lowercased().contains("boolean") == true,
            "this build publishes no boolean option; the refusal says so instead of guessing")

        receive(
            agent,
            #"{"jsonrpc":"2.0","id":7,"method":"session/set_config_option","params":{"sessionId":"no-such-session","configId":"model","value":"a/model-a"}}"#
        )
        try await waitFor(capture, count: 6)
        error = try #require(objects(capture).last?["error"] as? [String: Any])
        #expect(error["code"] as? Int == ACPFraming.invalidParamsCode)
        #expect((error["message"] as? String)?.contains("no-such-session") == true)
    }

    @Test("set_config_option before the handshake is refused with the negotiation reason")
    func refusesBeforeInitialize() async throws {
        let (agent, capture) = openAgent(models: ["a/model-a"])
        receive(
            agent,
            #"{"jsonrpc":"2.0","id":9,"method":"session/set_config_option","params":{"sessionId":"x","configId":"model","value":"a/model-a"}}"#
        )
        try await waitFor(capture, count: 1)
        let error = try #require(objects(capture).last?["error"] as? [String: Any])
        #expect(error["code"] as? Int == ACPFraming.invalidRequestCode)
        #expect((error["message"] as? String)?.contains("initialize") == true)
    }
}
