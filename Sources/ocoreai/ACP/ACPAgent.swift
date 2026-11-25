// Copyright © 2026 uingei.
// Licensed under MIT.
/// ACPAgent.swift. ocoreai as an Agent Client Protocol agent, driven over stdio.
///
/// The turn runs through `DirectInferenceClient.shared` — the same in-process seam the GUI's Fast
/// Path uses — so engine, tool loop and approval broker stay one set of mechanisms serving both
/// faces, never a second agent implementation beside the first. The engine boots windowless with the
/// HTTP bridge forced off, so an editor's subprocess never binds the port a `serve` already holds.
///
/// Stdout is the protocol: everything that is not an ACP message, including the boot line `serve`
/// prints, goes to stderr, because the spec states the agent MUST NOT write anything else there.

import Foundation
import Logging

#if os(macOS)
import AppKit
#endif

/// One ACP session of this process. The workspace anchor is set at `session/new` through the same
/// route `SessionManager` uses for a GUI session, so tool cwd follows the editor's project.
struct ACPSession: Equatable {
    let id: String
    let cwd: String
    /// The model this session answers with, a published `configOptions` value, set at
    /// session creation and moved by `session/set_config_option`. Nil only while no
    /// selector was publishable, and then `runTurn` answers on the configured default.
    var modelId: String? = nil
    /// A loaded conversation the engine in *this* process has never seen: the stored
    /// history that rides along on the first prompt so the model answers with its past.
    /// Consumed once; after that the engine's own session is the history.
    var refeed: [TranscriptEntry] = []
}

/// What one ACP turn actually showed the editor, collected alongside the live stream so the
/// stored rows are exactly what the client saw — including a turn the user stopped mid-answer.
struct ACPTurnRecord {
    struct Call {
        let id: String
        let name: String
        let arguments: String?
        var summary: String?
        var failed = false
    }

    var assistantText = ""
    var reasoningText = ""
    private(set) var calls: [Call] = []

    mutating func noteCall(id: String, name: String, arguments: String?) {
        calls.append(Call(id: id, name: name, arguments: arguments))
    }

    /// A result whose id matches nothing live still belongs to the conversation; dropping it
    /// would store a call that never ends. It rides as its own record instead.
    mutating func noteResult(id: String, summary: String, failed: Bool) {
        if let index = calls.firstIndex(where: { $0.id == id }) {
            calls[index].summary = summary
            calls[index].failed = failed
        } else {
            calls.append(Call(id: id, name: "", arguments: nil, summary: summary, failed: failed))
        }
    }

    func toolCallRecords() -> [ToolCallRecord] {
        calls.map { call in
            ToolCallRecord(
                callId: call.id, toolName: call.name,
                arguments: ChatState.parseToolArguments(call.arguments),
                resultSummary: call.summary, durationMs: nil,
                resultFailed: call.summary == nil ? nil : call.failed)
        }
    }
}

@MainActor
final class ACPAgent {

    private static let logger = Logger(label: "ocoreai.acp")

    /// Whether a turn can run yet. The engine boots asynchronously after the client has already
    /// started writing, so early messages are queued rather than dropped or answered with a guess.
    private enum EngineGate: Equatable {
        case starting
        case ready
        case blocked(reason: String)
    }

    private let write: (Data) -> Void
    private var gate: EngineGate = .starting
    private var queued: [String] = []
    private var initialized = false
    /// The version a client asked for that we could not accept, until an accepted handshake clears
    /// it. A client that ignores the negotiation still gets refused, with this number in the reason.
    private var declinedVersion: Int?
    private var sessions: [String: ACPSession] = [:]
    private var turnTasks: [String: Task<Void, Never>] = [:]
    private var turnCancellations: [String: InferenceCancellation] = [:]
    /// Start order, so an approval question is put to the turn that actually asked for it.
    private var turnOrder: [String] = []

    /// Permission requests this process sent the client and has not answered, keyed by the JSON-RPC
    /// id we sent, so one response line resumes exactly one parked tool call.
    private var permissionContinuations: [Int: CheckedContinuation<ACPPermissionOutcome, Never>] =
        [:]
    /// Starts above the range an editor counts its own request ids in, so an echoed id can never
    /// be ambiguous about which direction the message went.
    private var nextPermissionID = 100_000

    /// The session store, asked for when a method needs it rather than at boot: the engine
    /// opens the store while this face is already reading stdin. A test injects its own.
    private let store: @MainActor () -> SessionCompressor?

    /// The models the editor may choose, sorted: the union `GET /v1/models` publishes —
    /// disk-ready under the model root ∪ resident — plus the configured default, minus the
    /// embedder, which answers `/v1/embeddings` but cannot take a turn. A test injects its
    /// own list so its assertions are literals, not whatever sits on this host's disk.
    private let models: @MainActor () async -> [String]

    init(
        write: @escaping (Data) -> Void,
        store: @escaping @MainActor () -> SessionCompressor? = {
            OcoreaiEngine.shared.activeSessionCompressor
        },
        models: @escaping @MainActor () async -> [String] = {
            var ids: Set<String> = []
            let rootP = ModelStore.root.standardizedFileURL.path
            for ready in ModelStore.discoverReady()
            where ready.weightsDir.standardizedFileURL.path.hasPrefix(rootP + "/") {
                ids.insert(ModelStore.normalizeModelId(ready.id))
            }
            if let pool = OcoreaiEngine.shared.activeEnginePool {
                for entry in await pool.listModels() {
                    if let raw = entry["id"], !raw.isEmpty {
                        ids.insert(ModelStore.normalizeModelId(raw))
                    }
                }
                let configured = ModelStore.normalizeModelId(pool.config.defaultModelId)
                if !configured.isEmpty { ids.insert(configured) }
            }
            ids.remove(ModelStore.normalizeModelId(EmbeddingService.canonicalModelId))
            return ids.sorted()
        }
    ) {
        self.write = write
        self.store = store
        self.models = models
    }

    /// Bridges the one approval truth (`ApprovalBroker`, asked from because `ToolEntry.isDestructive`)
    /// to ACP's permission request. An ACP client can answer, so this lane is not headless and does
    /// not take the fail-closed deny the wire lanes take. The review surface stays the broker's: the
    /// snippet shown to the human is the payload the broker deemed reviewable.
    func attachApprovalBridge() async {
        guard let broker = OcoreaiEngine.shared.activeApprovalBroker else {
            Self.logger.warning("no approval broker — destructive tools will fail closed")
            return
        }
        await broker.setOnPending { [weak self] row in
            await self?.askClientAbout(row)
        }
    }

    /// Engine finished booting: replay what the client sent while it was warming.
    func becomeReady() {
        gate = .ready
        let pending = queued
        queued.removeAll()
        for line in pending { receive(line) }
    }

    /// Engine cannot boot (a second live instance holds the single-instance lock, most often).
    /// Every waiting request gets the cause and both exits, then the process leaves: an agent that
    /// stays alive while it cannot serve only moves the diagnosis onto the editor.
    func becomeBlocked(reason: String) {
        gate = .blocked(reason: reason)
        let pending = queued
        queued.removeAll()
        for line in pending { answerBlocked(line, reason: reason) }
        ACPStderr.log(reason)
        fflush(stdout)
        _exit(1)
    }

    private func answerBlocked(_ line: String, reason: String) {
        let id: ACPID?
        if case .success(let message) = ACPFraming.decode(line: line) {
            id = message.id
        } else {
            id = nil
        }
        write(ACPFraming.error(id: id, code: ACPFraming.internalErrorCode, message: reason))
    }

    /// Called once per line read from stdin.
    func receive(_ line: String) {
        switch gate {
        case .starting:
            queued.append(line)
            return
        case .blocked(let reason):
            answerBlocked(line, reason: reason)
            return
        case .ready:
            break
        }
        switch ACPFraming.decode(line: line) {
        case .failure(let error):
            write(
                ACPFraming.error(
                    id: nil, code: ACPFraming.parseErrorCode,
                    message: "acp: unreadable message (\(describe(error))) — each line must be one "
                        + "JSON-RPC object"))
        case .success(let message):
            dispatch(message)
        }
    }

    /// Stdin EOF: the client is gone, so nothing may stay parked behind it. The permission
    /// continuations are resumed here as well as the broker's, or a half-read approval request
    /// would keep this process's task alive after the editor that could answer it has exited.
    func clientGone() async {
        for task in turnTasks.values { task.cancel() }
        turnTasks.removeAll()
        for cancellation in turnCancellations.values { cancellation.cancel() }
        turnCancellations.removeAll()
        turnOrder.removeAll()
        for continuation in permissionContinuations.values {
            continuation.resume(
                returning: ACPPermissionOutcome(outcome: "cancelled", optionId: nil))
        }
        permissionContinuations.removeAll()
        await OcoreaiEngine.shared.activeApprovalBroker?.cancelAll()
    }

    // MARK: - Dispatch

    private func dispatch(_ message: ACPIncoming) {
        switch message.method {
        case "initialize": handleInitialize(message)
        case "session/new": handleNewSession(message)
        case "session/prompt": handlePrompt(message)
        case "session/cancel": handleCancel(message)
        case "session/list": handleListSessions(message)
        case "session/load": handleLoadSession(message)
        case "session/set_config_option": handleSetConfigOption(message)
        case "authenticate":
            fail(
                message, code: ACPFraming.methodNotFoundCode,
                "authenticate: this agent holds no credential to obtain — the model is local and "
                    + "initialize already answers \"authMethods\": []")
        case "session/resume", "session/close", "session/delete",
            "session/set_mode", "logout":
            fail(
                message, code: ACPFraming.methodNotFoundCode,
                "\(message.method): not offered by this build — agentCapabilities is the promise")
        default:
            fail(
                message, code: ACPFraming.methodNotFoundCode,
                "\(message.method): unknown method to this agent")
        }
    }

    private func fail(_ message: ACPIncoming, code: Int, _ reason: String) {
        guard let id = message.id else { return }  // A notification has nothing to answer.
        write(ACPFraming.error(id: id, code: code, message: reason))
    }

    /// Why a session method cannot run yet: either the handshake never came, or it was answered
    /// with a version this build does not speak and the client did not leave.
    private func notReadyReason(for method: String) -> String {
        if let asked = declinedVersion {
            return
                "\(method): initialize answered protocolVersion \(ACPMode.protocolVersion) to its "
                + "\(asked) and the client stayed — close the connection, or re-initialize with "
                + "\(ACPMode.protocolVersion)"
        }
        return "\(method) before initialize — the handshake comes first"
    }

    private func describe(_ error: ACPFramingError) -> String {
        switch error {
        case .notJSON: return "not JSON"
        case .notAnObject: return "JSON value is not an object"
        case .missingMethod: return "no \"method\" string"
        case .unsupportedID: return "unsupported \"id\""
        }
    }

    // MARK: - initialize

    private func handleInitialize(_ message: ACPIncoming) {
        guard let params = message.params(as: ACPInitializeParams.self),
            let asked = params.protocolVersion
        else {
            fail(
                message, code: ACPFraming.invalidParamsCode,
                "initialize: needs \"\(ACPFraming.protocolVersionKey)\"")
            return
        }
        // v1 initialization is a negotiation, not a gate: on a version we do not speak we MUST
        // still answer with the latest one we support, and the client closes the connection if
        // that is unusable. A client that stays and prompts anyway gets the refusal below.
        initialized = asked == ACPMode.protocolVersion
        declinedVersion = initialized ? nil : asked
        write(
            ACPFraming.response(
                id: message.id ?? .number(0),
                result: ACPInitializeResult(
                    protocolVersion: ACPMode.protocolVersion,
                    agentCapabilities: ACPAgentCapabilities(
                        loadSession: true,
                        promptCapabilities: ACPPromptCapabilities(
                            image: false, audio: false, embeddedContext: true),
                        sessionCapabilities: ACPSessionCapabilities(list: [:])),
                    agentInfo: ACPImplementation(
                        name: "ocoreai", title: "ocoreai", version: AppInfo.shortVersion),
                    authMethods: [])))
    }

    // MARK: - session/new

    private func handleNewSession(_ message: ACPIncoming) {
        guard initialized else {
            fail(
                message, code: ACPFraming.invalidRequestCode,
                notReadyReason(for: "session/new"))
            return
        }
        guard let params = message.params(as: ACPNewSessionParams.self),
            let cwd = params.cwd, !cwd.isEmpty
        else {
            fail(
                message, code: ACPFraming.invalidParamsCode,
                "session/new: needs a non-empty \"cwd\" — tools run there, nothing is assumed")
            return
        }
        // Invariant 2: a caller that hands us MCP servers believes their tools exist. Connecting
        // them is unwired here, so refuse by name instead of opening a session that promises less.
        if let servers = params.mcpServers, !servers.isEmpty {
            fail(
                message, code: ACPFraming.invalidParamsCode,
                "session/new: this build connects none of the \(servers.count) caller-supplied "
                    + "MCP server(s) — send \"mcpServers\": [], or register them in ocoreai's own "
                    + "MCP config, which this agent does use")
            return
        }
        if let extra = params.additionalDirectories, !extra.isEmpty {
            fail(
                message, code: ACPFraming.invalidParamsCode,
                "session/new: tools are scoped to \"cwd\" here and will not silently widen to "
                    + "\(extra.count) additional directories")
            return
        }
        SessionWorkspace.setDirectory(cwd)
        let session = ACPSession(id: "acp-\(UUID().uuidString.prefix(8))", cwd: cwd)
        sessions[session.id] = session
        let requestId = message.id ?? .number(0)
        // The session registers synchronously — the very next stdin line can be its prompt —
        // and only the selector list takes the hop, so the prompt never races the option
        // state: no client can address this session before the response carries its id.
        Task { [weak self] in
            guard let self else { return }
            let options = await self.models()
            let current = Self.pickCurrentModel(
                options: options,
                configuredDefault:
                    OcoreaiEngine.shared.activeEnginePool?.config.defaultModelId ?? "")
            self.sessions[session.id]?.modelId = current
            self.write(
                ACPFraming.response(
                    id: requestId,
                    result: ACPNewSessionResult(
                        sessionId: session.id,
                        configOptions: Self.configOptions(
                            current: current, options: options))))
        }
    }

    // MARK: - session config options

    /// The only config option this build publishes. No agent capability gates `select`
    /// options in v1; publishing the option IS the promise, and `session/new` and
    /// `session/load` carry it, so the method needs no separate advertisement.
    nonisolated static let modelConfigID = "model"

    /// The model a new session answers with: the configured default when it is among the
    /// published choices (the default seam always inserts it, so that is the rule), else
    /// the first choice, else nothing — a machine serving no model promises no selector.
    nonisolated static func pickCurrentModel(
        options: [String], configuredDefault: String
    ) -> String? {
        let wanted = ModelStore.normalizeModelId(configuredDefault)
        if options.contains(wanted) { return wanted }
        return options.first
    }

    /// v1 `SessionConfigOption[]` for this build's single selector. `name` doubles as the
    /// choice label because the published id (`org/name`) is already the human-readable
    /// name the Models page shows.
    nonisolated static func configOptions(
        current: String?, options: [String]
    ) -> [ACPSessionConfigOption] {
        guard let current else { return [] }
        return [
            ACPSessionConfigOption(
                id: modelConfigID, name: "Model", category: "model", type: "select",
                currentValue: current,
                options: options.map { .init(value: $0, name: $0) }),
        ]
    }

    private func handleSetConfigOption(_ message: ACPIncoming) {
        guard initialized else {
            fail(
                message, code: ACPFraming.invalidRequestCode,
                notReadyReason(for: "session/set_config_option"))
            return
        }
        guard let id = message.id else { return }  // a notification has nothing to answer
        guard let params = message.params(as: ACPSetConfigOptionParams.self),
            let sessionId = params.sessionId, let configId = params.configId
        else {
            fail(
                message, code: ACPFraming.invalidParamsCode,
                "session/set_config_option: needs \"sessionId\" and \"configId\"")
            return
        }
        guard sessions[sessionId] != nil else {
            fail(
                message, code: ACPFraming.invalidParamsCode,
                "session/set_config_option: \"\(sessionId)\" is not a session of this "
                    + "process — session/new opens one")
            return
        }
        guard configId == Self.modelConfigID else {
            fail(
                message, code: ACPFraming.invalidParamsCode,
                "session/set_config_option: \"\(configId)\" is not a config option of "
                    + "this agent — \"\(Self.modelConfigID)\" is the only id it publishes")
            return
        }
        // v1 allows a string or a boolean `value`, and which one arrived decides the
        // refusal, so the raw JSON answers that — a Decodable shape would blur them.
        guard let json = message.paramsJSON,
            let dict = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else {
            fail(
                message, code: ACPFraming.invalidParamsCode,
                "session/set_config_option: \"params\" are unreadable")
            return
        }
        // Foundation bridges JSON `true` to NSNumber, same as the id read on the inbound side.
        if let flag = dict["value"] as? NSNumber, String(cString: flag.objCType) == "c" {
            fail(
                message, code: ACPFraming.invalidParamsCode,
                "session/set_config_option: this agent publishes no boolean options — "
                    + "send a model id string for \"\(Self.modelConfigID)\"")
            return
        }
        guard let value = dict["value"] as? String else {
            fail(
                message, code: ACPFraming.invalidParamsCode,
                "session/set_config_option: \"value\" must be a model id string")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let options = await self.models()
            guard options.contains(value) else {
                self.write(
                    ACPFraming.error(
                        id: id, code: ACPFraming.invalidParamsCode,
                        message: "session/set_config_option: \"\(value)\" is not a model "
                            + "this machine can answer with — session/new configOptions "
                            + "carries the \(options.count) ids it can"))
                return
            }
            self.sessions[sessionId]?.modelId = value
            self.write(
                ACPFraming.response(
                    id: id,
                    result: ACPSetConfigOptionResult(
                        configOptions: Self.configOptions(
                            current: value, options: options))))
        }
    }

    // MARK: - session/list

    /// Rows per `session/list` page. The store caps nothing; the page size is this face's.
    static let listPageSize = 50

    private func handleListSessions(_ message: ACPIncoming) {
        guard initialized else {
            fail(
                message, code: ACPFraming.invalidRequestCode,
                notReadyReason(for: "session/list"))
            return
        }
        guard let id = message.id else { return }  // a notification has nothing to answer
        var cwd: String?
        var offset = 0
        // All params are optional; a present-but-unreadable one is refused, never defaulted.
        if let json = message.paramsJSON, json != Data("null".utf8) {
            guard let params = message.params(as: ACPListSessionsParams.self) else {
                fail(
                    message, code: ACPFraming.invalidParamsCode,
                    "session/list: \"cwd\" must be a string path and \"cursor\" a string token")
                return
            }
            if let requested = params.cwd {
                guard requested.hasPrefix("/") else {
                    fail(
                        message, code: ACPFraming.invalidParamsCode,
                        "session/list: \"cwd\" must be an absolute path, got \"\(requested)\"")
                    return
                }
                cwd = requested
            }
            if let token = params.cursor {
                guard let decoded = Self.decodeListCursor(token), decoded >= 0 else {
                    fail(
                        message, code: ACPFraming.invalidParamsCode,
                        "session/list: \"\(token)\" is not a cursor this agent issued — "
                            + "omit \"cursor\" for the first page")
                    return
                }
                offset = decoded
            }
        }
        guard let compressor = store() else {
            write(
                ACPFraming.error(
                    id: id, code: ACPFraming.internalErrorCode,
                    message: "session/list: no session store is open in this process"))
            return
        }
        let pageSize = Self.listPageSize
        Task { [weak self] in
            do {
                // Over-fetch one: a full page plus one row is what earns a nextCursor.
                let rows = try await compressor.listClientVisibleSessions(
                    limit: pageSize + 1, offset: offset, cwd: cwd)
                let more = rows.count > pageSize
                // One conversation can own a row per model (`resolveSession`'s keying);
                // the client knows one id, so the newest row per key is the entry.
                var seen: Set<String> = []
                var infos: [ACPSessionInfo] = []
                for row in rows.prefix(pageSize) {
                    guard let key = row.externalKey, let dir = row.workspaceDirectory,
                        !dir.isEmpty, seen.insert(key).inserted
                    else { continue }
                    infos.append(
                        ACPSessionInfo(
                            sessionId: key, cwd: dir, updatedAt: Self.iso8601(row.updatedAt)))
                }
                self?.write(
                    ACPFraming.response(
                        id: id,
                        result: ACPListSessionsResult(
                            sessions: infos,
                            nextCursor: more ? Self.listCursor(offset: offset + pageSize) : nil)))
            } catch {
                self?.write(
                    ACPFraming.error(
                        id: id, code: ACPFraming.internalErrorCode,
                        message: "session/list: the session store refused the query: "
                            + error.localizedDescription))
            }
        }
    }

    /// The client must treat cursors as opaque, so any reversible token is legal and
    /// offset-in-base64 is the smallest. The page size belongs to this agent and is stable
    /// across a pagination walk.
    nonisolated static func listCursor(offset: Int) -> String {
        Data("offset:\(offset)".utf8).base64EncodedString()
    }

    nonisolated static func decodeListCursor(_ token: String) -> Int? {
        guard let data = Data(base64Encoded: token),
            let text = String(data: data, encoding: .utf8),
            text.hasPrefix("offset:"),
            let value = Int(text.dropFirst("offset:".count))
        else { return nil }
        return value
    }

    nonisolated static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - session/load

    /// Replay page size. The v1 MUST is the *whole* conversation, so this walks to the
    /// end of the store rather than capping history at one page.
    static let replayPageSize = 200

    private func handleLoadSession(_ message: ACPIncoming) {
        guard initialized else {
            fail(
                message, code: ACPFraming.invalidRequestCode,
                notReadyReason(for: "session/load"))
            return
        }
        guard let id = message.id else { return }
        guard let params = message.params(as: ACPLoadSessionParams.self),
            let sessionId = params.sessionId, !sessionId.isEmpty,
            let cwd = params.cwd, cwd.hasPrefix("/")
        else {
            fail(
                message, code: ACPFraming.invalidParamsCode,
                "session/load: needs \"sessionId\" and an absolute \"cwd\" — the same "
                    + "shape session/new opened with")
            return
        }
        if let servers = params.mcpServers, !servers.isEmpty {
            fail(
                message, code: ACPFraming.invalidParamsCode,
                "session/load: this build connects none of the \(servers.count) "
                    + "caller-supplied MCP server(s) — send \"mcpServers\": []")
            return
        }
        if let extra = params.additionalDirectories, !extra.isEmpty {
            fail(
                message, code: ACPFraming.invalidParamsCode,
                "session/load: tools are scoped to \"cwd\" here and will not silently "
                    + "widen to \(extra.count) additional directories")
            return
        }
        guard let compressor = store() else {
            write(
                ACPFraming.error(
                    id: id, code: ACPFraming.internalErrorCode,
                    message: "session/load: no session store is open in this process"))
            return
        }
        let pageSize = Self.replayPageSize
        Task { [weak self] in
            guard let self else { return }
            do {
                // One client key spans one row per model (`resolveSession`'s keying), so the
                // whole conversation is the union of its shards, oldest first; the newest
                // shard names the model the re-opened conversation answers with now.
                let rows = try await compressor.clientSessionRows(externalKey: sessionId)
                guard let newest = rows.first else {
                    self.write(
                        ACPFraming.error(
                            id: id, code: ACPFraming.invalidParamsCode,
                            message: "session/load: nothing in this store answers to "
                                + "\"\(sessionId)\" — session/list answers with the ids that can load"
                        ))
                    return
                }
                // The anchor moves only for a load that was accepted: a refused or unknown
                // id must not relocate where every other session's tools run.
                SessionWorkspace.setDirectory(cwd)
                var refeed: [TranscriptEntry] = []
                var offset = 0
                let shardIds = rows.map { $0.id }.reversed()
                // The response goes out only after every entry has been streamed (v1 MUST).
                while true {
                    let page = try await compressor.replayRows(
                        sessionIds: Array(shardIds), limit: pageSize, offset: offset)
                    for stored in page {
                        self.replay(sessionId: sessionId, stored: stored, refeed: &refeed)
                    }
                    if page.count < pageSize { break }
                    offset += pageSize
                }
                // The newest shard names the model the re-opened conversation answers
                // with; if this machine no longer serves it, the honest current value is
                // the picker's first choice, not a model the next turn cannot load.
                let options = await self.models()
                let stored = ModelStore.normalizeModelId(newest.modelId)
                let current =
                    options.contains(stored) ? stored
                    : Self.pickCurrentModel(
                        options: options,
                        configuredDefault:
                            OcoreaiEngine.shared.activeEnginePool?.config
                                .defaultModelId ?? "")
                self.sessions[sessionId] = ACPSession(
                    id: sessionId, cwd: cwd, modelId: current, refeed: refeed)
                self.write(
                    ACPFraming.response(
                        id: id,
                        result: ACPLoadSessionResult(
                            configOptions: Self.configOptions(
                                current: current, options: options))))
            } catch {
                self.write(
                    ACPFraming.error(
                        id: id, code: ACPFraming.internalErrorCode,
                        message: "session/load: the session store refused the read: "
                            + error.localizedDescription))
            }
        }
    }

    /// One stored row becomes exactly the `session/update` lines the live stream once sent:
    /// thought before reply, each tool call opened then closed with the status its record
    /// actually earned (a recorded failure never replays as a completion).
    private func replay(
        sessionId: String, stored row: MessageModel,
        refeed: inout [TranscriptEntry]
    ) {
        switch row.role {
        case "user":
            guard !row.content.isEmpty else { return }
            update(
                sessionId,
                [
                    "sessionUpdate": "user_message_chunk", "messageId": "u-\(row.id)",
                    "content": ["type": "text", "text": row.content],
                ])
            refeed.append(TranscriptEntry(role: "user", content: row.content))
        case "assistant":
            if let thought = row.reasoning, !thought.isEmpty {
                update(
                    sessionId,
                    [
                        "sessionUpdate": "agent_thought_chunk", "messageId": "t-\(row.id)",
                        "content": ["type": "text", "text": thought],
                    ])
            }
            if !row.content.isEmpty {
                update(
                    sessionId,
                    [
                        "sessionUpdate": "agent_message_chunk", "messageId": "m-\(row.id)",
                        "content": ["type": "text", "text": row.content],
                    ])
                refeed.append(TranscriptEntry(role: "assistant", content: row.content))
            }
            for record in row.toolCalls ?? [] {
                update(
                    sessionId,
                    [
                        "sessionUpdate": "tool_call", "toolCallId": record.callId,
                        "title": record.toolName, "name": record.toolName,
                        "status": "pending", "rawInput": record.arguments,
                    ])
                guard let summary = record.resultSummary else { continue }
                update(
                    sessionId,
                    [
                        "sessionUpdate": "tool_call_update", "toolCallId": record.callId,
                        "status": record.resultFailed == true ? "failed" : "completed",
                        "content": [
                            [
                                "type": "content",
                                "content": ["type": "text", "text": summary],
                            ]
                        ],
                    ])
            }
        default:
            break
        }
    }

    // MARK: - session/prompt

    private func handlePrompt(_ message: ACPIncoming) {
        guard initialized else {
            fail(
                message, code: ACPFraming.invalidRequestCode,
                notReadyReason(for: "session/prompt"))
            return
        }
        guard let id = message.id else {
            Self.logger.info("session/prompt arrived as a notification — nothing to answer")
            return
        }
        guard let params = message.params(as: ACPPromptParams.self),
            let sessionId = params.sessionId, sessions[sessionId] != nil
        else {
            fail(
                message, code: ACPFraming.invalidParamsCode,
                "session/prompt: \"sessionId\" is not a session of this process")
            return
        }
        guard let prompt = params.prompt, let text = renderPrompt(prompt) else {
            fail(
                message, code: ACPFraming.invalidParamsCode,
                promptRefusal ?? "session/prompt: needs a \"prompt\" array")
            return
        }
        let cancellation = InferenceCancellation.cancellable()
        turnCancellations[sessionId] = cancellation
        turnOrder.append(sessionId)
        // A loaded session's stored history rides on its first prompt; after that the
        // engine's own conversation is the history, so the refeed is consumed here.
        let refeed = sessions[sessionId]?.refeed ?? []
        sessions[sessionId]?.refeed = []
        turnTasks[sessionId] = Task { [weak self] in
            await self?.runTurn(
                id: id, sessionId: sessionId, text: text, cancellation: cancellation,
                refeed: refeed)
        }
    }

    /// Set when `renderPrompt` declines, so the wire answers with the reason instead of a bare
    /// "invalid params".
    private var promptRefusal: String?

    /// Text and embedded-context blocks become the turn's words; any other block type is refused by
    /// name. `initialize` answers `image: false, audio: false`, so a client that sends one is out of
    /// contract already, and a silently dropped image is the surface claiming more than it delivered.
    private func renderPrompt(_ blocks: [ACPPromptBlock]) -> String? {
        promptRefusal = nil
        var pieces: [String] = []
        for block in blocks {
            switch block.type {
            case "text":
                if let text = block.text, !text.isEmpty { pieces.append(text) }
            case "resource":
                if let embedded = block.resource?.text, !embedded.isEmpty {
                    pieces.append("«\(block.resource?.uri ?? "resource")»\n\(embedded)")
                } else if let uri = block.resource?.uri {
                    promptRefusal =
                        "prompt carries a resource with no embedded text (\(uri)) and "
                        + "this agent fetches no URIs of its own"
                    return nil
                }
            case "resource_link":
                promptRefusal =
                    "prompt carries a resource_link; this agent declares "
                    + "embeddedContext only — send the content as a \"resource\" block"
                return nil
            default:
                promptRefusal =
                    "prompt block type \"\(block.type ?? "missing")\" is not accepted "
                    + "(initialize answers image: false, audio: false)"
                return nil
            }
        }
        guard !pieces.isEmpty else {
            promptRefusal = "session/prompt: no text content to act on"
            return nil
        }
        return pieces.joined(separator: "\n\n")
    }

    private func runTurn(
        id: ACPID, sessionId: String, text: String, cancellation: InferenceCancellation,
        refeed: [TranscriptEntry] = []
    ) async {
        defer {
            turnTasks[sessionId] = nil
            turnCancellations[sessionId] = nil
            turnOrder.removeAll { $0 == sessionId }
        }
        guard let pool = OcoreaiEngine.shared.activeEnginePool else {
            write(
                ACPFraming.error(
                    id: id, code: ACPFraming.internalErrorCode,
                    message: "engine is not ready (lifecycle: "
                        + OcoreaiEngine.shared.lifecycleState.rawValue + ")"))
            return
        }
        // The session's chosen model wins; the configured default is the fallback only for
        // the no-selector build (a machine that serves no model at all).
        let model = sessions[sessionId]?.modelId ?? pool.config.defaultModelId
        guard !model.isEmpty else {
            write(
                ACPFraming.error(
                    id: id, code: ACPFraming.internalErrorCode,
                    message: "no default model is configured — pick one on the app's Models page"))
            return
        }
        let declared = await OcoreaiEngine.shared.activeToolRegistry?.toToolDefs()
        // Same arm choice as the GUI seam; the ACP session id is the engine's convKey here, so
        // a tool_search hit in this session re-enters the next turn's declarations.
        let reachable = SettingsStore.shared.toolSurfaceReachableEnabled
        let tools = ToolSurfaceCuration.apply(
            declared,
            enabled: SettingsStore.shared.toolSurfaceCurationEnabled,
            reachable: reachable,
            discovered: reachable
                ? await ToolSurfaceDiscovery.shared.names(for: sessionId) : [])
        var transcript = refeed.map { Message(role: $0.role, content: $0.content) }
        transcript.append(Message(role: "user", content: text))
        let request = InferenceRequest(
            modelId: model,
            messages: transcript,
            tools: tools,
            sessionId: sessionId,
            cancellation: cancellation)

        var payload: Data
        var finish = "stop"
        var engineWords: String?
        var record = ACPTurnRecord()
        do {
            for await chunk in try await DirectInferenceClient.shared.stream(request: request) {
                emit(sessionId: sessionId, chunk: chunk, record: &record)
                if let error = chunk.error { engineWords = error }
                if let reason = chunk.stopReason { finish = reason }
                if Task.isCancelled || cancellation.isCancelled { break }
            }
            if let words = engineWords {
                payload = ACPFraming.error(
                    id: id, code: ACPFraming.internalErrorCode, message: words)
            } else {
                payload = ACPFraming.response(
                    id: id,
                    result: ACPPromptResult(
                        stopReason: ACPStopReason.map(
                            finish, cancelled: cancellation.isCancelled || Task.isCancelled)))
            }
        } catch {
            // The failure report carries the framework's own words, never a bare "turn failed".
            // v1 `notice` updates go only to clients that advertised `session.notices`, and this
            // build reads no client capabilities, so the cause travels on the JSON-RPC error (the
            // contract channel for a failed turn) and on stderr, where the editor shows the log.
            let cause = error.localizedDescription
            ACPStderr.log("turn failed: \(cause)")
            payload = ACPFraming.error(id: id, code: ACPFraming.internalErrorCode, message: cause)
        }
        // Store before answering: what the editor reads back must be as durable as what it
        // just read. A failed store does not retroactively fail a delivered turn (the GUI and
        // wire lanes treat it the same way), but it says so on stderr, where the editor shows logs.
        if let compressor = store(), let session = sessions[sessionId] {
            do {
                try await Self.persistTurn(
                    to: compressor, session: session, modelId: model, userText: text,
                    record: record)
            } catch {
                ACPStderr.log("turn not stored: \(error.localizedDescription)")
            }
        }
        write(payload)
    }

    /// Append one ACP turn to the store the app's session pages read, so an editor
    /// conversation outlives the editor. The key is the ACP session id (one row per
    /// conversation and model, `resolveSession`'s existing rule) and the editor's cwd rides
    /// `workspace_directory`, the one home a session's cwd has.
    nonisolated static func persistTurn(
        to compressor: SessionCompressor, session: ACPSession, modelId: String,
        userText: String, record: ACPTurnRecord
    ) async throws {
        let rowId = try await compressor.resolveSession(externalKey: session.id, modelId: modelId)
        try await compressor.bindWorkspace(session.cwd, for: rowId)
        _ = try await compressor.addMessage(
            sessionId: rowId, role: "user", content: userText,
            tokenCount: TokenEstimate.promptTokens(userText))
        let calls = record.toolCallRecords()
        let hasReasoning = !record.reasoningText.isEmpty
        guard !record.assistantText.isEmpty || hasReasoning || !calls.isEmpty else { return }
        _ = try await compressor.addMessage(
            sessionId: rowId, role: "assistant", content: record.assistantText,
            tokenCount: TokenEstimate.promptTokens(record.assistantText),
            toolCalls: calls.isEmpty ? nil : calls,
            reasoning: hasReasoning ? record.reasoningText : nil)
    }

    private func emit(sessionId: String, chunk: DirectChatChunk, record: inout ACPTurnRecord) {
        if let thought = chunk.reasoningContent, !thought.isEmpty {
            record.reasoningText += thought
            update(
                sessionId,
                [
                    "sessionUpdate": "agent_thought_chunk",
                    "content": ["type": "text", "text": thought],
                ])
        }
        if let text = chunk.text, !text.isEmpty {
            record.assistantText += text
            update(
                sessionId,
                [
                    "sessionUpdate": "agent_message_chunk",
                    "content": ["type": "text", "text": text],
                ])
        }
        switch chunk.metadata {
        case .toolCall(let call):
            record.noteCall(id: call.id, name: call.name, arguments: call.arguments)
            // rawInput is any JSON value: the parsed object renders readable in an editor, and
            // arguments that are not JSON ride as their own string rather than being dropped.
            let rawInput: Any
            if let arguments = call.arguments,
                let parsed = try? JSONSerialization.jsonObject(
                    with: Data(arguments.utf8), options: [.fragmentsAllowed])
            {
                rawInput = parsed
            } else {
                rawInput = call.arguments ?? ""
            }
            update(
                sessionId,
                [
                    "sessionUpdate": "tool_call",
                    "toolCallId": call.id,
                    "title": call.name,
                    "name": call.name,
                    "status": "in_progress",
                    "rawInput": rawInput,
                ])
        case .toolResult(let result):
            record.noteResult(
                id: result.id, summary: result.resultSummary, failed: result.failure != nil)
            update(
                sessionId,
                [
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": result.id,
                    "status": result.failure == nil ? "completed" : "failed",
                    "content": [
                        [
                            "type": "content",
                            "content": ["type": "text", "text": result.resultSummary],
                        ]
                    ],
                ])
        default:
            break
        }
    }

    private func update(_ sessionId: String, _ update: [String: Any]) {
        write(
            ACPFraming.notification(
                method: "session/update",
                params: ["sessionId": sessionId, "update": update]))
    }

    // MARK: - Cancellation

    private func handleCancel(_ message: ACPIncoming) {
        guard let params = message.params(as: ACPCancelParams.self),
            let sessionId = params.sessionId
        else { return }
        turnCancellations[sessionId]?.cancel()
        turnTasks[sessionId]?.cancel()
    }

    // MARK: - Permissions

    /// Puts one parked call to the editor, then resolves the broker's own request. An answer we
    /// cannot map denies: a tool never runs on a word we could not read.
    private func askClientAbout(_ row: PendingApproval) async {
        guard let sessionId = turnOrder.last else {
            _ = await OcoreaiEngine.shared.activeApprovalBroker?.resolve(
                id: row.id,
                decision: .denied(reason: "no ACP turn is running to ask about"))
            return
        }
        let requestID = nextPermissionID
        nextPermissionID += 1
        let outcome: ACPPermissionOutcome = await withCheckedContinuation { continuation in
            permissionContinuations[requestID] = continuation
            write(
                ACPFraming.request(
                    id: .number(requestID),
                    method: "session/request_permission",
                    params: Self.permissionRequestParams(sessionId: sessionId, row: row)))
        }
        let decision: ApprovalDecision
        switch outcome.outcome {
        case "selected" where outcome.optionId == "allow-once": decision = .approved
        case "selected" where outcome.optionId == "allow-session": decision = .approvedForSession
        case "selected": decision = .denied(reason: "denied by the editor")
        default: decision = .denied(reason: "the editor cancelled the approval request")
        }
        _ = await OcoreaiEngine.shared.activeApprovalBroker?.resolve(id: row.id, decision: decision)
    }

    /// The request's params, v1 shape: `sessionId`, `toolCall` (required `toolCallId`), `options`
    /// whose kinds are exactly three of the schema's four `PermissionOptionKind` words.
    nonisolated static func permissionRequestParams(
        sessionId: String, row: PendingApproval
    ) -> [String: Any] {
        [
            "sessionId": sessionId,
            "toolCall": [
                "toolCallId": "approval-\(row.id.uuidString.prefix(8))",
                "title": "\(row.toolName): \(row.snippet)",
                "rawInput": row.arguments,
            ],
            "options": [
                ["optionId": "allow-once", "name": "Allow once", "kind": "allow_once"],
                [
                    "optionId": "allow-session", "name": "Allow for this session",
                    "kind": "allow_always",
                ],
                ["optionId": "reject", "name": "Deny", "kind": "reject_once"],
            ],
        ]
    }

    /// A response line (it carries no `method`) answers one permission request we sent.
    func receiveResponse(_ response: ACPResponseEnvelope) {
        guard case .number(let requestID) = response.id,
            let continuation = permissionContinuations.removeValue(forKey: requestID)
        else { return }
        guard response.errorCode == nil, let data = response.resultJSON,
            let decoded = try? JSONDecoder().decode(ACPPermissionResult.self, from: data)
        else {
            continuation.resume(
                returning: ACPPermissionOutcome(outcome: "cancelled", optionId: nil))
            return
        }
        continuation.resume(returning: decoded.outcome)
    }
}

struct ACPCancelParams: Decodable {
    let sessionId: String?
}

// MARK: - Runtime

#if os(macOS)
@MainActor
enum ACPAgentRuntime {

    /// Boot the engine windowless with the bridge off, then speak ACP on stdio until EOF.
    static func run() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        registerGlobalCrashHandlers()
        setenv("HF_HUB_DISABLE_XET", "1", 1)
        HFMirrorPolicy.apply()
        HeadlessRuntime.installShutdownSignal()

        let agent = ACPAgent(write: ACPStdout.write)
        ACPStdin.start(
            onLine: { line in agent.receive(line) },
            onResponse: { response in agent.receiveResponse(response) },
            onEOF: {
                Task { @MainActor in
                    await agent.clientGone()
                    HeadlessRuntime.beginShutdown(reason: "stdin EOF")
                }
            })

        Task {
            await OcoreaiEngine.shared.start(serveHTTP: false)
            if OcoreaiEngine.shared.lifecycleState == .error {
                agent.becomeBlocked(
                    reason: "engine could not start (lifecycle: error). Another ocoreai holds this "
                        + "machine's engine — quit the app or the `serve` on this box, or set "
                        + "OCOREAI_ALLOW_MULTI_INSTANCE=1 to run both and contend for GPU memory.")
                return
            }
            await agent.attachApprovalBridge()
            agent.becomeReady()
            ACPStderr.log("ready — speaking ACP \(ACPMode.protocolVersion) on stdio")
        }

        NSApplication.shared.run()
    }
}

/// Stdout is reserved for protocol messages, so this is the only writer allowed there.
enum ACPStdout {
    static func write(_ data: Data) {
        FileHandle.standardOutput.write(data)
        fflush(stdout)
    }
}

enum ACPStderr {
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("ocoreai acp: \(message)\n".utf8))
        fflush(stderr)
    }
}

/// Leftover bytes of a partially received message. Owned by the reader thread alone, and handed
/// out only as whole lines, so no other actor ever sees a half message.
private final class ACPReadBuffer: @unchecked Sendable {
    private var pending = Data()

    /// Appends what was just read and returns every message the buffer can now complete.
    func drain(_ incoming: Data) -> [String] {
        pending.append(incoming)
        var lines: [String] = []
        while let next = ACPFraming.completeLine(from: &pending) {
            lines.append(next)
        }
        return lines
    }
}

/// Line reader for stdin: one thread, one buffer, one newline-delimited message at a time, and each
/// line handed to the main actor in arrival order. Order is the point. `initialize` answered after
/// `session/new` is a session that was never negotiated, so lines are not fanned out to tasks.
/// EOF means the client left, the same convention `serve` already honours.
enum ACPStdin {
    static func start(
        onLine: @escaping @MainActor @Sendable (String) -> Void,
        onResponse: @escaping @MainActor @Sendable (ACPResponseEnvelope) -> Void,
        onEOF: @escaping @MainActor @Sendable () -> Void
    ) {
        let buffer = ACPReadBuffer()
        Thread.detachNewThread {
            let fd = FileHandle.standardInput.fileDescriptor
            var scratch = [UInt8](repeating: 0, count: 65_536)
            let capacity = scratch.count
            while true {
                // One read(2), not FileHandle.readData(ofLength:). That call fills its buffer or
                // hits EOF, so on a live pipe it returns nothing until the client hangs up: measured
                // 11-24, an editor's first request sat unread while the agent reported itself ready.
                let count = scratch.withUnsafeMutableBytes { raw in
                    Darwin.read(fd, raw.baseAddress, capacity)
                }
                if count == 0 {
                    DispatchQueue.main.sync { MainActor.assumeIsolated { onEOF() } }
                    return
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    DispatchQueue.main.sync { MainActor.assumeIsolated { onEOF() } }
                    return
                }
                for line in buffer.drain(Data(bytes: scratch, count: count)) {
                    // A response carries no "method", so the answer to a request we sent goes to the
                    // parked continuation instead of the method dispatcher.
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated {
                            if let response = ACPFraming.decodeResponse(line: line) {
                                onResponse(response)
                            } else {
                                onLine(line)
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif
