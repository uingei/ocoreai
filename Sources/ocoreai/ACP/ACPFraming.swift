// Copyright © 2026 uingei.
// Licensed under MIT.
/// ACPFraming.swift. The ACP wire shape: newline-delimited JSON-RPC 2.0, both directions.
///
/// Pure codec — no I/O, no engine — so every rule the spec states in the imperative is testable
/// without booting anything: messages are delimited by newlines and must not carry embedded
/// newlines, and a message that cannot be read is answered, never dropped.

import Foundation

// MARK: - Identity

/// JSON-RPC request id. ACP clients send integers; the spec permits strings, and an id we cannot
/// echo back is a response the client can never match, so an unsupported id is a refusal.
enum ACPID: Equatable, Sendable {
    case number(Int)
    case text(String)

    var jsonObject: Any {
        switch self {
        case .number(let n): return NSNumber(value: n)
        case .text(let s): return s
        }
    }
}

/// One message read from the client. `id == nil` is a notification (no response is expected).
struct ACPIncoming: Equatable, Sendable {
    let id: ACPID?
    let method: String
    let paramsJSON: Data?

    /// Decodes this message's params into the fixed-shape type for its method.
    /// `nil` means the params are absent or do not match — the caller answers with
    /// ``ACPFraming/invalidParamsCode`` naming the method, never with a default.
    func params<T: Decodable>(as _: T.Type) -> T? {
        guard let paramsJSON else { return nil }
        return try? JSONDecoder().decode(T.self, from: paramsJSON)
    }
}

enum ACPFramingError: Error, Equatable, Sendable {
    case notJSON
    case notAnObject
    case missingMethod
    case unsupportedID
}

// MARK: - Codec

enum ACPFraming {
    static let parseErrorCode = -32700
    static let invalidRequestCode = -32600
    static let methodNotFoundCode = -32601
    static let invalidParamsCode = -32602
    static let internalErrorCode = -32603

    /// Protocol version field name, kept single-homed because both directions read it.
    static let protocolVersionKey = "protocolVersion"

    // MARK: Read side

    /// Takes the first complete message out of `buffer`, leaving any partial tail in place. ACP
    /// delimits by newline and forbids embedded newlines, so one call yields at most one message.
    /// A `\r` before the newline is dropped.
    static func completeLine(from buffer: inout Data) -> String? {
        guard let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let chunk = buffer.subdata(in: buffer.startIndex ..< newlineIndex)
        buffer.removeSubrange(buffer.startIndex ... newlineIndex)
        var text = String(data: chunk, encoding: .utf8) ?? ""
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }

    static func decode(line: String) -> Result<ACPIncoming, ACPFramingError> {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(.notJSON) }
        guard let data = trimmed.data(using: .utf8) else { return .failure(.notJSON) }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(.notJSON)
        }
        guard let dict = object as? [String: Any] else { return .failure(.notAnObject) }
        guard let method = dict["method"] as? String else { return .failure(.missingMethod) }
        let id: ACPID?
        if dict["id"] == nil {
            id = nil  // A notification.
        } else if let string = dict["id"] as? String {
            // Text first: Foundation's NSNumber cast accepts some strings, and an id rewritten as
            // a number is a response the client cannot match.
            id = .text(string)
        } else if let number = dict["id"] as? NSNumber {
            // Foundation bridges JSON `true` to NSNumber, so an id of `true` would echo back as the
            // number 1 and the client could never match the response. JSON numbers are never
            // char-typed; a char here is a boolean.
            if String(cString: number.objCType) == "c" { return .failure(.unsupportedID) }
            id = .number(number.intValue)
        } else {
            // An id we cannot echo back is a response the client can never match.
            return .failure(.unsupportedID)
        }
        let params = dict["params"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        return .success(ACPIncoming(id: id, method: method, paramsJSON: params))
    }

    // MARK: Write side

    /// One protocol line: the payload plus its terminating newline, nothing else.
    private static func line(_ payload: [String: Any]) -> Data {
        var body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        body.append(UInt8(ascii: "\n"))
        return body
    }

    static func response(id: ACPID, result: some Encodable) -> Data {
        let body = (try? JSONEncoder().encode(result)) ?? Data("{}".utf8)
        let object = (try? JSONSerialization.jsonObject(with: body)) ?? [:]
        return line(["jsonrpc": "2.0", "id": id.jsonObject, "result": object])
    }

    static func notification(method: String, params: [String: Any]) -> Data {
        line(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// A request WE send the client. ACP's agent→client methods (`session/request_permission`) are
    /// requests, not notifications: a client answers only a message carrying an id, and echoes that
    /// id back, so a permission line without one parks the tool call forever.
    static func request(id: ACPID, method: String, params: [String: Any]) -> Data {
        line(["jsonrpc": "2.0", "id": id.jsonObject, "method": method, "params": params])
    }

    static func error(id: ACPID?, code: Int, message: String) -> Data {
        line([
            "jsonrpc": "2.0",
            "id": id.map(\.jsonObject) ?? NSNull(),
            "error": ["code": code, "message": message],
        ])
    }

    /// A line that answers a request *we* sent (it carries no `method`). `nil` means the line is
    /// not a response, so the caller routes it to the method dispatcher instead.
    static func decodeResponse(line: String) -> ACPResponseEnvelope? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            dict["method"] == nil,
            dict["result"] != nil || dict["error"] != nil,
            let rawID = dict["id"]
        else { return nil }
        let id: ACPID
        if let string = rawID as? String {
            id = .text(string)
        } else if let number = rawID as? NSNumber {
            id = .number(number.intValue)
        } else {
            return nil
        }
        let error = dict["error"] as? [String: Any]
        return ACPResponseEnvelope(
            id: id,
            resultJSON: dict["result"].flatMap { try? JSONSerialization.data(withJSONObject: $0) },
            errorCode: error?["code"] as? Int,
            errorMessage: error?["message"] as? String)
    }
}

/// A client's answer to one of our requests.
struct ACPResponseEnvelope: Equatable, Sendable {
    let id: ACPID
    let resultJSON: Data?
    let errorCode: Int?
    let errorMessage: String?
}

// MARK: - Params (read side, fixed shapes only)

struct ACPInitializeParams: Decodable, Equatable {
    let protocolVersion: Int?
    let clientInfo: ACPImplementation?
}

struct ACPNewSessionParams: Decodable, Equatable {
    let cwd: String?
    let mcpServers: [ACPMCPServer]?
    let additionalDirectories: [String]?
}

struct ACPMCPServer: Decodable, Equatable {
    let name: String?
}

struct ACPPromptParams: Decodable, Equatable {
    let sessionId: String?
    let prompt: [ACPPromptBlock]?
}

/// A prompt block, read as far as this build consumes one. `image`/`audio` decode but are refused
/// by name at the turn, because `initialize` answers `image: false, audio: false`.
struct ACPPromptBlock: Decodable, Equatable {
    let type: String?
    let text: String?
    let resource: ACPResource?
}

struct ACPResource: Decodable, Equatable {
    let uri: String?
    let text: String?
}

// MARK: - Results (write side)

struct ACPImplementation: Codable, Equatable {
    let name: String
    let title: String?
    let version: String
}

struct ACPPromptCapabilities: Codable, Equatable {
    let image: Bool
    let audio: Bool
    let embeddedContext: Bool
}

struct ACPAgentCapabilities: Codable, Equatable {
    let loadSession: Bool
    let promptCapabilities: ACPPromptCapabilities
}

struct ACPInitializeResult: Codable, Equatable {
    let protocolVersion: Int
    let agentCapabilities: ACPAgentCapabilities
    let agentInfo: ACPImplementation
    /// Empty on purpose: this product has no account and no key, and the ACP Registry's listing
    /// rule (at least one auth method, plus macOS+Linux+Windows binaries) is why it is not
    /// installable from there. A registry entry is not refused by us; it is unreachable.
    let authMethods: [String]
}

struct ACPNewSessionResult: Codable, Equatable {
    let sessionId: String
}

struct ACPPromptResult: Codable, Equatable {
    let stopReason: String
}

// MARK: - Outgoing requests (agent → client)

struct ACPPermissionOption: Codable, Equatable {
    let optionId: String
    let name: String
    let kind: String
}

struct ACPPermissionOutcome: Decodable, Equatable {
    /// `{"outcome":"selected","optionId":…}` or `{"outcome":"cancelled"}`.
    let outcome: String
    let optionId: String?
}

/// The `result` object of a `session/request_permission` answer wraps the outcome one level deep.
struct ACPPermissionResult: Decodable, Equatable {
    let outcome: ACPPermissionOutcome
}

/// Turn-end words. Our lane says `stop | length | cancelled | error`; ACP says
/// `end_turn | max_tokens | max_turn_requests | refusal | cancelled`. `error` never reaches this
/// table: a failed turn is answered with a JSON-RPC error carrying the cause, not as a clean stop.
/// An unrecognised word lands on `end_turn`, because a turn that reported nothing wrong finished.
enum ACPStopReason {
    static func map(_ ours: String, cancelled: Bool) -> String {
        if cancelled { return "cancelled" }
        switch ours {
        case "length": return "max_tokens"
        case "cancelled": return "cancelled"
        default: return "end_turn"
        }
    }
}
