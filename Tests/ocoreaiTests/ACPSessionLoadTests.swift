import Foundation
import Testing

@testable import ocoreai

/// `session/load` against the real store: the v1 MUST is that the whole conversation
/// replays as `session/update` lines BEFORE the response arrives, each entry shaped like
/// the live delivery, and a recorded failure never replays as a completion.
@MainActor
@Suite("ACP session/load — 回放顺序、失败位、拒绝语", .serialized)
struct ACPSessionLoadTests {

    @MainActor
    private final class Capture {
        var lines: [Data] = []
    }

    private func openAgent() async throws -> (
        ACPAgent, Capture, SQLiteStore, SessionCompressor, String
    ) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_load_\(UUID().uuidString.prefix(8)).sqlite").path
        let store = SQLiteStore(path: path)
        try await store.open()
        let compressor = SessionCompressor(store: store, fts: FTS5Search(store: store))
        let capture = Capture()
        // The model list is injected so no assertion can ride on whatever this host's
        // disk holds: the load response carries a selector, and its value must be literal.
        let agent = ACPAgent(
            write: { capture.lines.append($0) },
            store: { compressor },
            models: { ["a/model-a", "b/model-b"] })
        agent.becomeReady()
        return (agent, capture, store, compressor, path)
    }

    private func cleanup(_ path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func objects(_ capture: Capture) -> [[String: Any]] {
        capture.lines.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private func waitFor(_ capture: Capture, count: Int) async throws {
        for _ in 0 ..< 500 {
            if capture.lines.count >= count { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let arrived = capture.lines.prefix(4).compactMap { String(data: $0, encoding: .utf8) }
        Issue.record(
            "only \(capture.lines.count) of \(count) promised lines arrived; first: \(arrived)")
    }

    @Test("replay streams every entry in order and only then answers with the model selector")
    func replayThenResponse() async throws {
        let lease = ProcessGlobalLease()
        defer { lease.release() }
        let (agent, capture, store, compressor, path) = try await openAgent()
        defer {
            Task { await store.close() }
            cleanup(path)
        }

        var record = ACPTurnRecord()
        record.assistantText = "done"
        record.reasoningText = "thinking"
        record.noteCall(id: "c1", name: "write_file", arguments: "{\"path\":\"x\"}")
        record.noteResult(id: "c1", summary: "OK", failed: false)
        record.noteCall(id: "c2", name: "exec", arguments: nil)
        record.noteResult(id: "c2", summary: "boom", failed: true)
        record.noteCall(id: "c3", name: "read_file", arguments: nil)
        try await ACPAgent.persistTurn(
            to: compressor, session: ACPSession(id: "acp-load1", cwd: NSTemporaryDirectory()),
            modelId: "m1", userText: "go", record: record)

        // The load moves the process-wide workspace anchor. This test holds a lease for
        // the operation; release clears the process-global slot before another suite runs.
        // An accepted load landing on a missing directory once poisoned another suite's cwd.
        let workDir = NSTemporaryDirectory()

        agent.receive(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#)
        let loadBody: [String: Any] = [
            "jsonrpc": "2.0", "id": 2, "method": "session/load",
            "params": ["sessionId": "acp-load1", "cwd": workDir, "mcpServers": [String]()],
        ]
        let loadLine = try #require(
            String(
                data: try JSONSerialization.data(withJSONObject: loadBody), encoding: .utf8))
        agent.receive(loadLine)
        // init + 8 updates (user, thought, message, 3×tool_call, 2×tool_call_update) + response.
        try await waitFor(capture, count: 10)
        let lines = objects(capture)

        let updates = lines.compactMap { line -> String? in
            guard line["method"] as? String == "session/update",
                let params = line["params"] as? [String: Any],
                let update = params["update"] as? [String: Any]
            else { return nil }
            return update["sessionUpdate"] as? String
        }
        #expect(
            updates
                == [
                    "user_message_chunk", "agent_thought_chunk", "agent_message_chunk",
                    "tool_call", "tool_call_update", "tool_call", "tool_call_update", "tool_call",
                ],
            "the whole conversation rides before the answer, in conversation order")
        let lastUpdateIndex = lines.lastIndex { ($0["method"] as? String) == "session/update" }
        #expect(lines.lastIndex(where: { $0["result"] != nil }) == lines.count - 1)
        #expect(
            (lastUpdateIndex ?? Int.max) < lines.count - 1,
            "the response must arrive after every entry has been streamed")
        let response = try #require(lines.last)
        // The stored row was written under "m1", which this machine's (injected) option
        // list no longer carries: the honest current value is the picker's first choice,
        // not a model the next turn could not load.
        let data = try #require(response["result"])
        let optionsJSON = try JSONSerialization.data(
            withJSONObject: try #require(
                (data as? [String: Any])?["configOptions"]))
        let options = try JSONDecoder().decode([ACPSessionConfigOption].self, from: optionsJSON)
        #expect(options.map(\.currentValue) == ["a/model-a"])
        #expect(options.first?.options.map(\.value) == ["a/model-a", "b/model-b"])

        // The failed call's update says failed; the unanswered call never closes.
        let toolUpdates = lines.compactMap { line -> [String: Any]? in
            guard let params = line["params"] as? [String: Any],
                let update = params["update"] as? [String: Any],
                update["sessionUpdate"] as? String == "tool_call_update"
            else { return nil }
            return update
        }
        #expect(toolUpdates.map { $0["status"] as? String } == ["completed", "failed"])
        let calls = lines.compactMap { line -> [String: Any]? in
            guard let params = line["params"] as? [String: Any],
                let update = params["update"] as? [String: Any],
                update["sessionUpdate"] as? String == "tool_call"
            else { return nil }
            return update
        }
        #expect(calls.map { $0["toolCallId"] as? String } == ["c1", "c2", "c3"])
        #expect(calls.allSatisfy { $0["status"] as? String == "pending" })
    }

    @Test("a conversation that switched models replays as one conversation, not its last shard")
    func splitAcrossModelRows() async throws {
        let lease = ProcessGlobalLease()
        defer { lease.release() }
        // `resolveSession` keys one client conversation as one row PER MODEL — the engine
        // partitions a conversation the same way — so a session that switched models owns
        // two rows. The v1 MUST is the whole conversation; replaying only the newest row
        // would silently delete everything the editor saw before the switch.
        let (agent, capture, store, compressor, path) = try await openAgent()
        defer {
            Task { await store.close() }
            cleanup(path)
        }

        var first = ACPTurnRecord()
        first.assistantText = "on the first model"
        try await ACPAgent.persistTurn(
            to: compressor, session: ACPSession(id: "acp-split", cwd: NSTemporaryDirectory()),
            modelId: "model-a", userText: "start", record: first)
        var second = ACPTurnRecord()
        second.assistantText = "on the second model"
        try await ACPAgent.persistTurn(
            to: compressor, session: ACPSession(id: "acp-split", cwd: NSTemporaryDirectory()),
            modelId: "model-b", userText: "switch", record: second)

        agent.receive(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#)
        agent.receive(
            #"{"jsonrpc":"2.0","id":2,"method":"session/load","params":{"sessionId":"acp-split","cwd":"\#(NSTemporaryDirectory())","mcpServers":[]}}"#
        )
        // init + 4 updates (user/assistant × 2 turns) + response.
        try await waitFor(capture, count: 6)
        let lines = objects(capture)
        var texts: [String] = []
        var roles: [String] = []
        for line in lines {
            guard line["method"] as? String == "session/update",
                let params = line["params"] as? [String: Any],
                let update = params["update"] as? [String: Any],
                let kind = update["sessionUpdate"] as? String,
                kind == "user_message_chunk" || kind == "agent_message_chunk"
            else { continue }
            roles.append(kind == "user_message_chunk" ? "user" : "assistant")
            let content = update["content"] as? [String: Any]
            texts.append((content?["text"] as? String) ?? "")
        }
        #expect(
            roles == ["user", "assistant", "user", "assistant"],
            "both model shards replay, in conversation order")
        #expect(
            texts == ["start", "on the first model", "switch", "on the second model"],
            "the pre-switch history is part of the conversation the editor re-opens")
    }

    @Test("unknown id, relative cwd, caller-supplied MCP servers: each refused by name")
    func refusals() async throws {
        let lease = ProcessGlobalLease()
        defer { lease.release() }
        let (agent, capture, store, _, path) = try await openAgent()
        defer {
            Task { await store.close() }
            cleanup(path)
        }
        // A refused load must not move the process-wide workspace anchor. This test holds
        // a lease because even its explicit sentinel write is process-global. Sampled red 11-25:
        // the pre-fix handler setDirectory'd before the store check, this file's own "/t"
        // poisoned another suite's spawn cwd through ExecTools.effectiveCwd.
        SessionWorkspace.setDirectory("/tmp")

        agent.receive(
            #"{"jsonrpc":"2.0","id":1,"method":"session/load","params":{"sessionId":"x","cwd":"/t"}}"#
        )
        let early = try #require(objects(capture).last)
        #expect(
            (early["error"] as? [String: Any])?["code"] as? Int == ACPFraming.invalidRequestCode)
        #expect(SessionWorkspace.currentDirectory() == "/tmp")

        agent.receive(
            #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":1}}"#)
        agent.receive(
            #"{"jsonrpc":"2.0","id":3,"method":"session/load","params":{"sessionId":"nope","cwd":"/t","mcpServers":[]}}"#
        )
        try await waitFor(capture, count: 3)
        let unknown = try #require(objects(capture).last)
        let unknownError = try #require(unknown["error"] as? [String: Any])
        #expect(unknownError["code"] as? Int == ACPFraming.invalidParamsCode)
        #expect((unknownError["message"] as? String)?.contains("nope") == true)
        #expect(
            SessionWorkspace.currentDirectory() == "/tmp",
            "an id the store never heard of must not relocate every other session's tools")

        agent.receive(
            #"{"jsonrpc":"2.0","id":4,"method":"session/load","params":{"sessionId":"nope","cwd":"relative"}}"#
        )
        try await waitFor(capture, count: 4)
        let relative = try #require(objects(capture).last)
        #expect(
            (relative["error"] as? [String: Any])?["code"] as? Int
                == ACPFraming.invalidParamsCode)

        agent.receive(
            #"{"jsonrpc":"2.0","id":5,"method":"session/load","params":{"sessionId":"nope","cwd":"/t","mcpServers":[{"name":"fs"}]}}"#
        )
        try await waitFor(capture, count: 5)
        let mcp = try #require(objects(capture).last)
        let mcpError = try #require(mcp["error"] as? [String: Any])
        #expect(mcpError["code"] as? Int == ACPFraming.invalidParamsCode)
        #expect((mcpError["message"] as? String)?.contains("1") == true)
    }
}
