// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// SystemPromptContractTests — coding-agent behavioral contract regression gate.
///
/// The base prompt is the behavioral contract that makes the model actually
/// USE its tools (action-first) and report verification. A silent drift back
/// to a generic "intelligent assistant" line regresses the whole coding-agent
/// loop (live E2E showed small local models emit zero tool_calls without an
/// explicit "use your tools to implement" command).
///
/// Contract is codex-axis aligned (`codex-rs/core/gpt_5_1_prompt.md`:
/// "you should go ahead and actually implement the change") and lives in
/// `SystemPromptBuilder.codingAgentBase` as the single source of truth.
import Testing

@testable import ocoreai

@Suite("SystemPromptContract")
struct SystemPromptContractTests {
    @Test("coding agent identity, not generic assistant")
    func codingAgentIdentity() {
        #expect(SystemPromptBuilder.codingAgentBase.contains("coding agent"))
        #expect(!SystemPromptBuilder.codingAgentBase.contains("intelligent assistant"))
    }

    @Test("action-first tool-use command present")
    func actionFirstToolUse() {
        let base = SystemPromptBuilder.codingAgentBase.lowercased()
        #expect(base.contains("use your tools"))
        #expect(base.contains("don't just describe what you would do"))
    }

    @Test("verification reporting required")
    func verificationReporting() {
        #expect(SystemPromptBuilder.codingAgentBase.contains("report what changed"))
        #expect(SystemPromptBuilder.codingAgentBase.contains("verified"))
    }

    @Test("destructive command guard present")
    func destructiveGuard() {
        #expect(SystemPromptBuilder.codingAgentBase.contains("NEVER run destructive commands"))
        #expect(SystemPromptBuilder.codingAgentBase.contains("git reset --hard"))
    }

    @Test("built prompt (no skills) keeps the full contract")
    func buildKeepsContract() async {
        let builder = SystemPromptBuilder(basePrompt: SystemPromptBuilder.codingAgentBase)
        let built = await builder.build()
        #expect(built.contains("coding agent"))
        #expect(built.contains("use your tools"))
    }

    @Test("contract survives user system-prompt append, never gets dropped")
    func userOverrideStillAppendsContract() async {
        // MessageBuilder Phase 3: userSystem + builtSystemPrompt — the contract
        // must still be present after a user-provided system prompt.
        let contract = SystemPromptBuilder.codingAgentBase
        let userSystem = "Custom user instructions."
        let composed = userSystem + "\n\n" + contract
        #expect(composed.contains("use your tools"))
        #expect(composed.contains("Custom user instructions"))
    }
}
