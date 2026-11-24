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
    private var sessions: [String: ACPSession] = [:]
    private var turnTasks: [String: Task<Void, Never>] = [:]
    private var turnCancellations: [String: InferenceCancellation] = [:]
    /// Start order, so an approval question is put to the turn that actually asked for it.
    private var turnOrder: [String] = []

    /// Permission requests this process sent the client and has not answered, keyed by the JSON-RPC
    /// id we sent, so one response line resumes exactly one parked tool call.
    private var permissionContinuations: [Int: CheckedContinuation<ACPPermissionOutcome, Never>] =
        [:]
    private var nextPermissionID = 100_000

    init(write: @escaping (Data) -> Void) {
        self.write = write
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
        case "authenticate":
            fail(
                message, code: ACPFraming.methodNotFoundCode,
                "authenticate: this agent holds no credential to obtain — the model is local and "
                    + "initialize already answers \"authMethods\": []")
        case "session/load", "session/resume", "session/list", "session/close", "session/delete",
            "session/set_mode", "session/set_config_option", "logout":
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
        guard asked == ACPMode.protocolVersion else {
            fail(
                message, code: ACPFraming.invalidParamsCode,
                "initialize: protocolVersion \(asked) is not spoken here — this agent speaks "
                    + "\(ACPMode.protocolVersion)")
            return
        }
        initialized = true
        write(
            ACPFraming.response(
                id: message.id ?? .number(0),
                result: ACPInitializeResult(
                    protocolVersion: ACPMode.protocolVersion,
                    agentCapabilities: ACPAgentCapabilities(
                        loadSession: false,
                        promptCapabilities: ACPPromptCapabilities(
                            image: false, audio: false, embeddedContext: true)),
                    agentInfo: ACPImplementation(
                        name: "ocoreai", title: "ocoreai", version: AppInfo.shortVersion),
                    authMethods: [])))
    }

    // MARK: - session/new

    private func handleNewSession(_ message: ACPIncoming) {
        guard initialized else {
            fail(
                message, code: ACPFraming.invalidRequestCode,
                "session/new before initialize — the handshake comes first")
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
        write(
            ACPFraming.response(
                id: message.id ?? .number(0), result: ACPNewSessionResult(sessionId: session.id)))
    }

    // MARK: - session/prompt

    private func handlePrompt(_ message: ACPIncoming) {
        guard initialized else {
            fail(message, code: ACPFraming.invalidRequestCode, "session/prompt before initialize")
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
        turnTasks[sessionId] = Task { [weak self] in
            await self?.runTurn(
                id: id, sessionId: sessionId, text: text, cancellation: cancellation)
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
        id: ACPID, sessionId: String, text: String, cancellation: InferenceCancellation
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
        let model = pool.config.defaultModelId
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
        let request = InferenceRequest(
            modelId: model,
            messages: [Message(role: "user", content: text)],
            tools: tools,
            sessionId: sessionId,
            cancellation: cancellation)

        var payload: Data
        var finish = "stop"
        var engineWords: String?
        do {
            for await chunk in try await DirectInferenceClient.shared.stream(request: request) {
                emit(sessionId: sessionId, chunk: chunk)
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
            let cause = error.localizedDescription
            write(
                ACPFraming.notification(
                    method: "session/update",
                    params: [
                        "sessionId": sessionId,
                        "update": [
                            "sessionUpdate": "notice", "severity": "error",
                            "title": "Turn failed", "description": cause,
                        ],
                    ]))
            payload = ACPFraming.error(id: id, code: ACPFraming.internalErrorCode, message: cause)
        }
        write(payload)
    }

    private func emit(sessionId: String, chunk: DirectChatChunk) {
        if let thought = chunk.reasoningContent, !thought.isEmpty {
            update(
                sessionId,
                [
                    "sessionUpdate": "agent_thought_chunk",
                    "content": ["type": "text", "text": thought],
                ])
        }
        if let text = chunk.text, !text.isEmpty {
            update(
                sessionId,
                [
                    "sessionUpdate": "agent_message_chunk",
                    "content": ["type": "text", "text": text],
                ])
        }
        switch chunk.metadata {
        case .toolCall(let call):
            update(
                sessionId,
                [
                    "sessionUpdate": "tool_call",
                    "toolCallId": call.id,
                    "title": call.name,
                    "name": call.name,
                    "status": "in_progress",
                    "rawInput": call.arguments ?? "",
                ])
        case .toolResult(let result):
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
                ACPFraming.notification(
                    method: "session/request_permission",
                    params: [
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
                    ]))
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
