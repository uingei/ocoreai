// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// APIClient — HTTP bridge between SwiftUI and ocoreai server.
///
/// All UI views interact via this class. Server base URL defaults to localhost:8080.
/// @Observable pattern (Swift 5.9+): property-level change tracking.

import Foundation

// MARK: - API Client

@MainActor
final class APIClient: Observable {
    static let shared = APIClient()

    var serverReady: Bool = false
    var error: String?

    private let baseURL: URL
    private let session: URLSession
    private var probeTask: Task<Void, Never>?

    private init(port: Int = 8080) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)") ?? {
            fatalError("[APIClient] Invalid base URL for port \(port)")
        }()
        let conf = URLSessionConfiguration.default
        conf.timeoutIntervalForRequest = 30
        conf.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: conf)

        // Watch server readiness
        probeTask = Task.detached { [weak self] in
            guard let self else { return }
            await self.probeLoop()
        }
    }

    /// Cancel background probe (called on app shutdown / view disappearance)
    func stopProbing() {
        probeTask?.cancel()
        probeTask = nil
    }

    // MARK: - Readiness

    /// Probe /health endpoint every 2s until server answers (or 30s timeout)
    private func probeLoop() async {
        for _ in 0..<15 {
            guard !Task.isCancelled else { break }
            do {
                let (_, response) = try await session.data(from: baseURL.appendingPathComponent("/health"))
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    await MainActor.run { self.serverReady = true }
                    return
                }
            } catch {
                // SilenceReason.healthCheck: server not ready yet during probe loop
            }
            // SilenceReason.gcdCancel: Task.sleep cancellation is expected
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    // MARK: - Health

    @discardableResult
    func getHealth() async -> Bool {
        do {
            let (_, response) = try await session.data(from: baseURL.appendingPathComponent("/health"))
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            await MainActor.run { self.error = "Health check failed: \(error.localizedDescription)" }
            return false
        }
    }

    // MARK: - Models

    struct ModelEntry: Codable, Hashable, Sendable {
        let id: String
        let `object`: String
        let created: Int
        let owned_by: String
    }

    /// List models — runs off-main-actor to avoid blocking UI.
    /// Returns empty array on failure (server down, timeout, etc).
    func listModels() async -> [ModelEntry] {
        // Use a short-lived session with aggressive timeout for UI calls
        let quickConf = URLSessionConfiguration.ephemeral
        quickConf.timeoutIntervalForRequest = 5
        quickConf.timeoutIntervalForResource = 5
        let quick = URLSession(configuration: quickConf)
        
        do {
            let url = baseURL.appendingPathComponent("/v1/models")
            let (data, _) = try await quick.data(from: url)
            let resp = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return resp.data
        } catch {
            await MainActor.run { self.error = "Models list failed: \(error.localizedDescription)" }
            return []
        }
    }

    private struct ModelsResponse: Codable {
        let data: [ModelEntry]
        let object: String
    }

    // MARK: - Chat

    @MainActor
    func chatComplete(
        _ messages: [ChatMessage],
        _ model: String = "default"
    ) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { [self] in
                do {
                    let body = ChatRequest(
                        messages: messages.map { $0.toRequestBody() },
                        stream: true,
                        model: model
                    )
                    let encoder = JSONEncoder()
                    guard let json = try? encoder.encode(body) else {
                        continuation.finish(throwing: ChatError.invalidPayload)
                        return
                    }

                    var req = URLRequest(url: self.baseURL.appendingPathComponent("/v1/chat/completions"))
                    req.httpMethod = "POST"
                    req.httpBody = json
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    // Collect full response, then parse SSE lines
                    let (data, resp) = try await self.session.data(for: req)

                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                        continuation.finish(throwing: ChatError.serverError(
                            resp as? HTTPURLResponse
                        ))
                        return
                    }

                    let text = String(decoding: data, as: UTF8.self)
                    var buffer = ""
                    for line in text.split(separator: "\n") {
                        let lineStr = String(line)
                        guard lineStr.hasPrefix("data: "), lineStr != "data: [DONE]" else { continue }
                        let str = String(lineStr.dropFirst(6))
                        guard let lineData = str.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: lineData),
                              let delta = chunk.choices?.first?.delta.content else { continue }
                        buffer += delta
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    struct StreamChunk: Codable {
        let choices: [Choice]?
    }
    struct Choice: Codable {
        let delta: Delta
    }
    struct Delta: Codable {
        let content: String?
    }
}

// MARK: - Request/Response types

// Note: ChatMessage struct is now shared from ChatViewModel.swift
// APIClient uses it directly; toRequestBody is available via extension below.

extension ChatMessage {
    func toRequestBody() -> [String: String] {
        ["role": role, "content": content]
    }
}

struct ChatRequest: Codable {
    let messages: [[String: String]]
    let stream: Bool
    let model: String
}

// MARK: - Errors

enum ChatError: LocalizedError {
    case invalidPayload
    case serverError(HTTPURLResponse?)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .invalidPayload: return "Invalid chat payload"
        case .serverError(let r): return "Server error (HTTP \(String(describing: r?.statusCode)))"
        case .network(let e): return "Network: \(e.localizedDescription)"
        }
    }
}
