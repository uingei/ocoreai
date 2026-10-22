// Copyright © 2026 uingei.
// Licensed under MIT.
/// ChatStateSendPathTests.swift — the GUI's send seam, executed.
///
/// Before this file every GUI test called a *logic helper* (`cleanMessages`,
/// `displayText`, `parseToolArguments`, the steer badge). Nothing in `Tests/`
/// had ever called `ChatState.chat(...)` — the one method that turns a composer
/// keystroke into an engine request — and nothing had ever read
/// `OcoreaiEngine.shared.activeEnginePool` (both greps: 0 hits in `Tests/`
/// at HEAD `2a9bff4`). So "the GUI can send" was an inference from the HTTP probes,
/// not a verified fact: the GUI reaches the engine through
/// `DirectInferenceClient`, not HTTP (`ChatViewModel.swift:1120`), so no probe
/// ever exercised that path.
///
/// Test 1 runs everywhere and gates invariant 2 (the surface never claims more
/// than the engine delivered) on the GUI face: with no engine, an ask must fail
/// *visibly* — bubble kept, error shown, nothing fabricated, composer not
/// wedged (`loading` reset is the common exit at `ChatViewModel.swift:1437`).
///
/// Test 2 is the live half: opt-in (`OCOREAI_GUI_LIVE=1`), same skip convention
/// as `CoreAILiveGenerateTests` — a real turn through the seam, and the SQLite
/// round-trip that the GUI transcript is actually built from.
///
/// No window, no Accessibility: `osascript` System Events hangs >30 s on this
/// host, and pixels have been refused since 10-23, so the evidence here is the
/// state the user would see plus the rows the UI reads back.

import Foundation
import Testing

@testable import ocoreai

@Suite("ChatState send path: GUI → engine seam")
struct ChatStateSendPathTests {

    private static var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["OCOREAI_GUI_LIVE"] == "1"
    }

    @MainActor
    @Test(
        "no engine: an ask fails honest — bubble kept, error shown, nothing fabricated"
    )
    func engineAbsentFailsHonest() async {
        guard OcoreaiEngine.shared.activeEnginePool == nil else {
            print("[GUI-SEND] SKIP — an engine pool is live in this process")
            return
        }
        let state = ChatState()
        state.resetForTesting()
        let marker = "OCOREAI_GUI_SEAM_NOENGINE"

        await state.chat(marker, model: "no-such-model-for-this-gate")

        // The ask is never silently dropped: the bubble is there before the wire.
        #expect(state.messages.count == 1)
        #expect(state.messages.first?.role == "user")
        #expect(state.messages.first?.content == marker)
        // Invariant 2: it must say it failed, and must not invent an answer.
        #expect(state.errorMessage != nil, "a dead send must surface an error, not silence")
        #expect(
            state.responseText.isEmpty, "no fabricated reply on a turn that never reached an engine"
        )
        // The composer must be usable again — `loading` stuck true makes the GUI deaf.
        #expect(state.loading == false)
        #expect(state.inferencePhase == nil)
        state.resetForTesting()
    }

    @MainActor
    @Test(
        "live: a GUI turn reaches the engine, answers, and round-trips through SQLite",
        .timeLimit(.minutes(4))
    )
    func liveGuiTurnReachesEngine() async throws {
        guard Self.liveEnabled else {
            print("[GUI-SEND-LIVE] SKIP — OCOREAI_GUI_LIVE=1 boots the engine (needs a model)")
            return
        }
        let engine = OcoreaiEngine.shared
        await engine.start()
        var waited: Double = 0
        while engine.activeEnginePool == nil && waited < 120 {
            try await Task.sleep(for: .milliseconds(250))
            waited += 0.25
        }
        // EnginePool is an actor: `config` is actor-isolated, so this hop is explicit.
        if let pool = engine.activeEnginePool {
            let model = await pool.config.defaultModelId
            let state = ChatState()
            state.resetForTesting()
            let marker = "Reply with exactly OCOREAI_GUI_SEAM_OK and nothing else."

            // Live telemetry is cleared at the common exit (`ChatViewModel.swift:1438`), so the
            // only honest way to check the TTFT wiring is to sample it DURING the turn — which
            // is what the GUI's badge reads while streaming. A 20 ms poll can miss a value that
            // only the final chunk carries, so tok/s is reported, not asserted.
            let sampler = Task { @MainActor () -> (ttft: Double?, tps: Double?) in
                var ttft: Double?
                var tps: Double?
                while !Task.isCancelled {
                    if let value = state.currentTTFTMs { ttft = value }
                    if let value = state.currentTokPerSec { tps = value }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                return (ttft, tps)
            }
            await state.chat(marker, model: model)
            sampler.cancel()
            let seen = await sampler.value
            print(
                "[GUI-SEND-LIVE] model=\(model) ttft=\(String(describing: seen.ttft)) "
                    + "tps=\(String(describing: seen.tps)) "
                    + "promptTps=\(String(describing: state.currentPromptTokPerSec)) "
                    + "chars=\(state.responseText.count)")

            #expect(state.errorMessage == nil, "live turn failed: \(state.errorMessage ?? "")")
            #expect(!state.responseText.isEmpty, "the seam returned no text")
            #expect(state.loading == false)
            #expect(seen.ttft != nil, "no TTFT reached the GUI during the turn")
            // The transcript the GUI displays is rebuilt from SQLite, so prove the rows.
            if let compressor = engine.activeSessionCompressor {
                var sawUser = false
                var sawAssistant = false
                for session in try await compressor.listSessions(modelId: model, limit: 5) {
                    let rows = try await compressor.getMessages(session.id, limit: 10)
                    if rows.contains(where: {
                        $0.role == "user" && $0.content.contains("OCOREAI_GUI_SEAM_OK")
                    }) {
                        sawUser = true
                        sawAssistant = rows.contains {
                            $0.role == "assistant" && !$0.content.isEmpty && $0.tokenCount > 0
                        }
                        break
                    }
                }
                #expect(sawUser, "the GUI's user message never reached the messages table")
                #expect(sawAssistant, "the GUI's assistant reply never reached the messages table")
            } else {
                Issue.record("session compressor absent — the GUI transcript has no store")
            }
            state.resetForTesting()
        } else {
            Issue.record("engine pool never came up within \(waited)s — no default model")
        }
        // Single exit: release the single-instance flock and the GPU for the next run.
        await engine.stop()
    }
}
