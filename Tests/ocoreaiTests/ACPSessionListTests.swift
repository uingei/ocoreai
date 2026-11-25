import Foundation
import Testing

@testable import ocoreai

/// `session/list` against the real store: only sessions the client can actually re-open are
/// shown, pagination is cursor-based, and a cursor this agent never issued is refused rather
/// than defaulted to page one (a wrong page is a wrong answer, not a slower right one).
@MainActor
@Suite("ACP session/list — 可见性、分页、cursor 校验", .serialized)
struct ACPSessionListTests {

    @MainActor
    private final class Capture {
        var lines: [Data] = []
    }

    private func makeAgent() async throws -> (
        ACPAgent, Capture, SQLiteStore, SessionCompressor, String
    ) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_list_\(UUID().uuidString.prefix(8)).sqlite").path
        let store = SQLiteStore(path: path)
        try await store.open()
        let compressor = SessionCompressor(store: store, fts: FTS5Search(store: store))
        let capture = Capture()
        let agent = ACPAgent(
            write: { capture.lines.append($0) },
            store: { compressor })
        agent.becomeReady()
        agent.receive(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#)
        return (agent, capture, store, compressor, path)
    }

    private func cleanup(_ path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// The list handler answers from an actor hop; poll until the line lands or time out.
    private func awaitResponse(_ capture: Capture, count: Int = 2) async throws -> [String: Any] {
        for _ in 0 ..< 250 {
            if capture.lines.count >= count { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let object = try #require(
            capture.lines.last.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            })
        return object
    }

    @Test(
        "uninitialized is refused with the handshake-first reason; empty store answers with an empty list"
    )
    func handshakeAndEmpty() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocoreai_list_\(UUID().uuidString.prefix(8)).sqlite").path
        let store = SQLiteStore(path: path)
        try await store.open()
        defer { Task { await store.close() } }
        let capture = Capture()
        let compressor = SessionCompressor(store: store, fts: FTS5Search(store: store))
        let agent = ACPAgent(write: { capture.lines.append($0) }, store: { compressor })
        agent.becomeReady()
        agent.receive(#"{"jsonrpc":"2.0","id":9,"method":"session/list","params":{}}"#)
        let early = try #require(
            capture.lines.last.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            })
        let error = try #require(early["error"] as? [String: Any])
        #expect(error["code"] as? Int == ACPFraming.invalidRequestCode)
        #expect((error["message"] as? String)?.contains("initialize") == true)

        agent.receive(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#)
        agent.receive(#"{"jsonrpc":"2.0","id":2,"method":"session/list","params":{}}"#)
        let answer = try await awaitResponse(capture, count: 3)
        let result = try #require(answer["result"] as? [String: Any])
        let listed = try #require(result["sessions"] as? [Any])
        #expect(listed.isEmpty, "no sessions is an empty list, never an error")
        #expect(result["nextCursor"] == nil, "an empty first page has no next page")
    }

    @Test("only rows with a key AND a recorded cwd are visible; dedup keeps one entry per key")
    func visibilityAndDedup() async throws {
        let (agent, capture, store, compressor, path) = try await makeAgent()
        defer {
            Task { await store.close() }
            cleanup(path)
        }

        // Visible: a persisted ACP turn (key + cwd by construction).
        var record = ACPTurnRecord()
        record.assistantText = "answer"
        try await ACPAgent.persistTurn(
            to: compressor, session: ACPSession(id: "acp-visible", cwd: "/tmp/proj-a"),
            modelId: "m1", userText: "q", record: record)
        // Invisible: a GUI row (no key, no cwd).
        _ = try await compressor.createSession(modelId: "gui")
        // Invisible: key but no cwd recorded.
        let keyless = try await compressor.createSession(modelId: "m1", externalKey: "wire-key")
        #expect(try await compressor.getSession(keyless)?.workspaceDirectory == nil)
        // Dedup: a second model row under the visible key.
        _ = try await compressor.resolveSession(externalKey: "acp-visible", modelId: "m2")

        agent.receive(#"{"jsonrpc":"2.0","id":2,"method":"session/list","params":{}}"#)
        let answer = try await awaitResponse(capture, count: 2)
        let result = try #require(answer["result"] as? [String: Any])
        let sessions = try #require(result["sessions"] as? [[String: Any]])
        #expect(
            sessions.map { $0["sessionId"] as? String } == ["acp-visible"],
            "GUI rows and cwd-less rows stay unlisted; the duplicate key collapses to one entry")
        let entry = try #require(sessions.first)
        #expect(entry["cwd"] as? String == "/tmp/proj-a")
        let updatedAt = try #require(entry["updatedAt"] as? String)
        #expect(updatedAt.contains("T"), "updatedAt is an ISO 8601 string, got \(updatedAt)")
    }

    @Test("a relative cwd and a foreign cursor are both refused by name with -32602")
    func refusals() async throws {
        let (agent, capture, store, _, path) = try await makeAgent()
        defer {
            Task { await store.close() }
            cleanup(path)
        }

        agent.receive(
            #"{"jsonrpc":"2.0","id":3,"method":"session/list","params":{"cwd":"relative/path"}}"#)
        let relative = try await awaitResponse(capture, count: 2)
        let relativeError = try #require(relative["error"] as? [String: Any])
        #expect(relativeError["code"] as? Int == ACPFraming.invalidParamsCode)
        #expect((relativeError["message"] as? String)?.contains("absolute") == true)

        let forged = Data("page:7".utf8).base64EncodedString()
        agent.receive(
            #"{"jsonrpc":"2.0","id":4,"method":"session/list","params":{"cursor":""#
                + forged + "\"}}")
        let forgedAnswer = try await awaitResponse(capture, count: 3)
        let forgedError = try #require(forgedAnswer["error"] as? [String: Any])
        #expect(forgedError["code"] as? Int == ACPFraming.invalidParamsCode)
        #expect((forgedError["message"] as? String)?.contains("cursor") == true)
    }

    @Test("the cursor this agent issued round-trips to the offset it names")
    func cursorRoundTrip() {
        let token = ACPAgent.listCursor(offset: 150)
        #expect(ACPAgent.decodeListCursor(token) == 150)
        #expect(ACPAgent.decodeListCursor("bm90LWEtY3Vyc29y") == nil)
    }
}
