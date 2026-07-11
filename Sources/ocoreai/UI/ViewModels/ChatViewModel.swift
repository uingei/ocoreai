// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Chat ViewModel — manages streaming, loading/error states, and message history.
///
/// @Observable pattern (Swift 5.9+): property-level change tracking.
/// Fast Path: SwiftUI → DirectInferenceClient → EnginePool (zero HTTP).
/// Single source of truth for engine readiness: OcoreaiEngine.shared.engineReady.
///
/// ### Persistence (Phase 1 P0-1 fix):
/// - Every user/assistant message is persisted to SQLite via SessionCompressor.
/// - Session is created/reused per (modelId) pair.
/// - On `start()`, historical messages for the last-used session are loaded from SQLite.
/// - On `resetConversation()`, the session is cleared and a new one is created.

import Foundation
import Logging
import Observation
import SwiftUI

// MARK: - Chat Message

/// Unified hub source for model search (HF vs ModelScope)
enum HubSource: String, CaseIterable {
	case huggingFace = "HuggingFace"
	case modelScope = "ModelScope"
}

// Note: HFModelInfo and MSModelInfo have been replaced by HFHubModel and MSHubModel
// from HuggingFaceSearchClient and ModelScopeSearchClient respectively.

/// ChatMessage — UI-layer message type with optional structured content.
///
/// Design:
/// - `content: String` — flat text (legacy, SQLite-compatible, streaming accumulation)
/// - `parts: [TranscriptPart]?` — structured semantic blocks (text/reasoning/toolCall/image)
///   When present, `parts` is the source of truth for rendering; `content` is a fallback.
///
/// Backward compat: messages from DB restore or legacy code still set `content` only.
/// New code should populate `parts` when available (e.g., AgentLoop tool call logs,
/// reasoning traces). The `textContent` computed property joins parts into a flat
/// string for persistence and fallback rendering.
struct ChatMessage: Identifiable, Hashable {
	let id = UUID()
	let role: String
	let content: String /// Flat text — legacy + SQLite-compatible + streaming fallback
	let parts: [TranscriptPart]? /// Structured content — source of truth when present
	let timestamp: Date
	let imageURLs: [String] /// Base64 data URLs for inline preview

	/// Plain-text representation joining all parts for persistence and fallback.
	var textContent: String {
		if let partsParts = parts {
			return partsParts.compactMap {
				switch $0 {
				case .text(let t): return t
				case .reasoning(let r): return r
				case .toolCall(let tc): return "[Tool: \(tc.name)]"
				case .image: return nil
				}
			}.joined(separator: "\n")
		}
		return content
	}

	/// Whether this message has structured semantic parts for rich rendering.
	var hasParts: Bool {
		parts != nil && !(parts?.isEmpty ?? true)
	}

	/// Legacy initializer — sets flat content only (for SQLite restore, streaming)
	init(role: String, content: String, timestamp: Date = .now, imageURLs: [String] = []) {
		self.role = role
		self.content = content
		self.timestamp = timestamp
		self.imageURLs = imageURLs
		parts = nil
	}

	/// Structured initializer — builds parts from semantic blocks
	init(role: String, parts: [TranscriptPart], timestamp: Date = .now) {
		self.role = role
		self.content = TranscriptPartMessage(texts: parts).flatText // fallback for persistence
		self.parts = parts
		self.timestamp = timestamp
		self.imageURLs = []
	}
}

/// Helper to flatten TranscriptPart array into a plain string for compatibility.
private struct TranscriptPartMessage {
	let texts: [TranscriptPart]

	var flatText: String {
		texts.compactMap {
			switch $0 {
			case .text(let t): return t
			case .reasoning(let r): return r
			case .toolCall(let tc): return "[Tool: \(tc.name): \(tc.resultSummary ?? "")]"
			case .image: return nil
			}
		}.joined(separator: " ")
	}
}

// MARK: - Chat State

@Observable
@MainActor
final class ChatState {
	/// Logger for persistence operations
	private static let logger = Logger(label: "ocoreai.chat")

	/// Shared singleton — survives view recreation (tab switch, NavigationSplitView).
	/// @State<ChatState.shared> is the correct SwiftUI observation pattern, same as ModelManager.
	static let shared = ChatState()
	private init() {}

	var messages: [ChatMessage] = []
	var responseText: String = ""
	var errorMessage: String?
	var loading: Bool = false

	// Single source of truth — no separate health polling task
	var connected: Bool {
		OcoreaiEngine.shared.engineReady
	}



	// MARK: - Persistence state

	/// SQLite-backed session ID for the current conversation.
	/// nil means no session yet (will be created on first chat).
	private var sessionId: Int64?

	/// Current model for session scoping.
	private var activeModelId: String?

	/// SessionCompressor accessor — nil when engine not booted.
	private var compressor: SessionCompressor? {
		OcoreaiEngine.shared.activeSessionCompressor
	}

	// MARK: - Cancellation (P0-3: mid-stream interrupt)

	/// Cancellation token for the active inference stream.
	/// When non-nil, a stream is in progress and can be cancelled.
	private var currentCancellation: InferenceCancellation?

	/// Cancel the current inference stream immediately.
	/// Safe to call multiple times and when no stream is active.
	func cancelInference() {
		currentCancellation?.cancel()
		currentCancellation = nil
		loading = false

		// P0-3 UX: Preserve the partial response instead of instantly blanking the screen.
		// The user can still see what was generated before interruption.
		if !responseText.isEmpty {
			messages.append(ChatMessage(role: "assistant", content: responseText + " [Interrupted]"))
			responseText = ""
		}
	}

	// MARK: - Model lifecycle (P0-2: hot-switch)

	/// Called when the user switches the model selector.
	/// Unloads the old model from EnginePool to free GPU memory.
	func onModelChanged(newModelId: String) {
		// Cancel any in-flight inference before switching
		cancelInference()

		// Unload the old model if it differs from the new one
		if let oldModel = activeModelId, oldModel != newModelId {
			Task { [oldModel] in
				guard let pool = OcoreaiEngine.shared.activeEnginePool else { return }
				await pool.unloadModel(oldModel)
			}
		}
	}

	// MARK: - Undo support

	/// Snapshot capture before destructive operations (max one level).
	private var undoSnapshot: [ChatMessage]?
	private var undoResponseText: String?
	/// Undo snapshot: error message text
	private var undoErrorMessage: String?

	/// Returns true if there is an undoable action available.
	var hasUndo: Bool {
		undoSnapshot != nil
	}

	// MARK: - Lifecycle

	/// Start session: load historical messages from SQLite for the last-used session.
	func start() {
		Task { @MainActor [weak self] in
			guard let self else { return }
			await loadHistory()
		}
	}

	func stop() {}

	// MARK: - Persistence

	/// Load messages from SQLite for the current session (if any).
	/// Idempotent — skips if messages already present (singleton survived view recreation).
	private func loadHistory() async {
		// Skip reload if messages already in memory
		guard messages.isEmpty else { return }
		guard let compressor, let sid = sessionId else { return }
		do {
			let dbMessages = try await compressor.getMessages(sid, limit: nil, offset: 0)
			// Messages come in reverse chronological order from DB — reverse for display
			let chronMessages = dbMessages.reversed().map { fromMessageModel($0) }
			messages = chronMessages
		} catch {
			// Non-fatal: fall back to empty in-memory state
			Self.logger.warning("Failed to load chat history: \(error.localizedDescription)")
		}
	}

	/// Create or reuse a persistent session for the given model.
	/// Reuses existing session if the model hasn't changed.
	private func ensureSession(for modelId: String) async {
		guard let compressor else { return }
		if sessionId != nil, activeModelId == modelId {
			return // Session already exists for this model
		}
		do {
			// Clean up old session model association before creating new one
			activeModelId = modelId
			sessionId = try await compressor.createSession(modelId: modelId)
		} catch {
			// Non-fatal: continue with in-memory mode
			Self.logger.warning("Failed to create session: \(error.localizedDescription)")
		}
	}

	/// Persist a single message to SQLite.
	private func persistMessage(role: String, content: String) async {
		guard let compressor, let sid = sessionId else { return }
		do {
			try await compressor.addMessage(
				sessionId: sid,
				role: role,
				content: content,
				tokenCount: estimateTokens(content),
			)
		} catch {
			// Non-fatal: message still exists in memory
			Self.logger.warning("Failed to persist \(role) message: \(error.localizedDescription)")
		}
	}

	/// Rough token estimate: ~4 chars per token for English, ~2 for CJK.
	private nonisolated func estimateTokens(_ text: String) -> Int {
		max(1, text.utf8.count / 3)
	}

	/// Convert DB MessageModel to our ChatMessage.
	private nonisolated func fromMessageModel(_ mm: MessageModel) -> ChatMessage {
		ChatMessage(role: mm.role, content: mm.content, timestamp: mm.createdAt)
	}

	// MARK: - Chat (Fast Path)

	/// User-provided image attachment for multimodal input.
	struct AttachedImage: Identifiable {
		let id = UUID()
		let dataURL: String /// Base64 data URL (data:image/png;base64,...)
	}

	/// Send chat message via Fast Path — bypasses HTTP entirely.
	///
	/// Flow: ChatMessage → multimodal context capture → Message (typed, may include
	///       image parts) → DirectInferenceClient.stream()
	///       → EnginePool.acquire() → generateFromMessages()
	///       → AsyncStream<InferenceEvent> → UI update → TTS (if speaker enabled)
	///
	/// Multimodal integration:
	/// - If camera/screen capture is enabled, visual context is captured before inference
	///   and injected as ContentPart.imageUrl parts in the user message.
	/// - If speaker is enabled, the final response is spoken via AudioIO TTS.
	/// - User-provided image attachments (via attach button) are merged as ContentPart.imageUrl
	///
	/// Fix: Filter out interrupted assistant messages from the inference context.
	/// Interrupted messages (ending with "[Interrupted]") are kept in UI history
	/// for display but excluded from the model's conversation context to prevent
	/// degraded inference quality from partial responses.
	func chat(_ text: String, model: String, attachments: [AttachedImage] = []) async {
		// Ensure persistent session exists
		await ensureSession(for: model)

		// MARK: - Multimodal context capture
		// Capture visual context (camera + screen) if enabled before inference
		let mmState = MultimodalState.shared
		let mmContext = await mmState.captureContext()

		// Merge user attachment images into multimodal context
		let allContext: [(name: String, dataURL: String)] = {
			var merged = mmContext
			for att in attachments {
				merged.append(("attachment", att.dataURL))
			}
			return merged
		}()

		// Push and persist user message (text only for persistence)
		// Store attachment data URLs for inline preview
		let attachmentURLs = attachments.map { $0.dataURL }
		let userMsg = ChatMessage(role: "user", content: text, imageURLs: attachmentURLs)
		messages.append(userMsg)
		await persistMessage(role: "user", content: text)

		responseText = ""
		loading = true
		errorMessage = nil

		// P0-3: Create cancellable token for mid-stream interrupt
		let cancellation = InferenceCancellation.cancellable()
		currentCancellation = cancellation

		do {
		// Build InferenceRequest — exclude interrupted messages and system messages
		// to prevent partial responses degrading the model's context.
		let cleanMessages = messages
			.filter { $0.role != "system" && !$0.content.hasSuffix(" [Interrupted]") }

		// Convert to typed Messages — last user message gets multimodal parts if available
		let typedMessages: [Message] = {
			var result: [Message] = []
			let count = cleanMessages.count
			for (idx, msg) in cleanMessages.enumerated() {
				// If this is the last user message AND we have multimodal context,
				// inject images as ContentPart.imageUrl parts
				let isLastUserMsg = (msg.role == "user") && (idx == count - 1) && !allContext.isEmpty
				if isLastUserMsg {
					var parts: [ContentPart] = [ContentPart(type: "text", text: msg.content, imageUrl: nil)]
					for ctx in allContext {
						parts.append(ContentPart(
							type: "image_url",
							text: nil,
							imageUrl: ContentPart.ImageURL(url: ctx.dataURL)
						))
					}
					result.append(Message(role: "user", content: .parts(parts)))
				} else {
					result.append(Message(role: msg.role, content: .text(msg.content)))
				}
			}
			return result
		}()

			let request = InferenceRequest(
				modelId: model,
				messages: typedMessages,
				sessionId: "chat-\(UUID().uuidString.prefix(8))",
				cancellation: cancellation,
			)

			// Stream via Fast Path
			for await chunk in try await DirectInferenceClient.shared.stream(request: request) {
				// P0-3: respect cancellation from both the token and outer Task
				guard !cancellation.isCancelled, !Task.isCancelled else { break }
				if !chunk.text.isEmpty {
					responseText += chunk.text
				}
				if chunk.isComplete {
					// Conversation complete — append and persist to history
					if !responseText.isEmpty {
						let assistantMsg = ChatMessage(role: "assistant", content: responseText)
						messages.append(assistantMsg)
						await persistMessage(role: "assistant", content: responseText)

						// MARK: - Post-inference TTS
						// If speaker is enabled, speak the final response
						mmState.speakIfEnabled(responseText)
					}
				}
			}
			// If interrupted mid-stream but accumulated text exists, save it
			if Task.isCancelled || cancellation.isCancelled {
				if !responseText.isEmpty {
					let assistantMsg = ChatMessage(role: "assistant", content: responseText + " [Interrupted]")
					messages.append(assistantMsg)
					await persistMessage(role: "assistant", content: assistantMsg.content)
				}
			}
			// Finalize cancellation handle
			currentCancellation = nil
		} catch {
			self.errorMessage = error.localizedDescription
			// Clear streaming preview on error — the error banner shows the message
			responseText = ""
			currentCancellation = nil
		}
		loading = false
	}

	func loadModels() async -> [String] {
		guard let pool = OcoreaiEngine.shared.activeEnginePool else { return [] }
		let models = await pool.listModels()
		return models.map { $0["id"] ?? "unknown" }
	}

	/// Snapshot current state, then clear the conversation.
	func resetConversation() {
		undoSnapshot = messages
		undoResponseText = responseText
		undoErrorMessage = errorMessage
		messages = []
		responseText = ""
		errorMessage = nil
		// Register undo with AppState for Cmd+Z access
		AppState.shared.undoAction = { [weak self] in self?.undoReset() }
	}

	/// Restore from the last snapshot if one exists.
	func undoReset() {
		guard let snapshot = undoSnapshot else { return }
		messages = snapshot
		responseText = undoResponseText ?? ""
		errorMessage = undoErrorMessage
		undoSnapshot = nil
		undoResponseText = nil
		undoErrorMessage = nil
	}
}
