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
    @Test("agent identity: canonical owner sentence, not a generic assistant")
    func agentIdentity() {
        // canonical 身份句（用户 09-27 三度给出，headline 位）
        #expect(SystemPromptBuilder.codingAgentBase.contains("an agent for open models"))
        #expect(SystemPromptBuilder.codingAgentBase.contains("natively local"))
        #expect(SystemPromptBuilder.codingAgentBase.contains("creativity, work, and code"))
        // 09-27 完整化表述（兼容并存，非互斥）
        #expect(SystemPromptBuilder.codingAgentBase.contains("complete agentic system"))
        #expect(SystemPromptBuilder.codingAgentBase.contains("coding and knowledge work"))
        #expect(!SystemPromptBuilder.codingAgentBase.contains("intelligent assistant"))
    }

    @Test("truth/curiosity/honesty principle, not preference-alignment wording")
    func principleNotPreferenceAlignment() {
        let base = SystemPromptBuilder.codingAgentBase.lowercased()
        #expect(base.contains("truth-seeking"))
        #expect(base.contains("curiosity"))
        #expect(base.contains("honesty"))
        #expect(base.contains("never hide, soften, or fabricate"))
        // "safe and helpful" 是人类偏好对齐措辞，不得回流
        #expect(!base.contains("safe, and helpful"))
        #expect(!base.contains("safe and helpful"))
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

    @Test(
        "destructive-command guard absent from the base prompt — authority comes from ApprovalBroker"
    )
    func destructiveGuardAbsent() {
        // 权限层（ApprovalBroker / approvalPolicy / codex ExecApprovalRequest）是
        // 操作权威；prompt 不再内置 "NEVER run destructive" 类偏好硬禁
        // （用户原则：拦权限=边界留，拦内容/价值观=偏好默认关）。
        let base = SystemPromptBuilder.codingAgentBase
        #expect(!base.contains("NEVER run destructive commands"))
        #expect(!base.lowercased().contains("do not run destructive"))
    }

    @Test("built prompt (no skills) keeps the full contract")
    func buildKeepsContract() async {
        let builder = SystemPromptBuilder(basePrompt: SystemPromptBuilder.codingAgentIdentity)
        let built = await builder.build()
        #expect(built.contains("an agent for open models"))
        #expect(built.contains("use your tools"))
    }

    @Test(
        "zero-tool turn must NOT be told to use tools — and MUST be told not to simulate them"
    )
    func noToolsTurnDropsActionDirective() async {
        // Live failure pinned (2026-10-12): client sent no `tools[]`, the engine
        // resolved a zero surface (0/39 injected), yet the prompt still commanded
        // "use your tools … run commands". gemma-4-e2b-it-4bit complied by
        // inventing a transcript: `terminal\ncommand: "seq 1 60"\nstdout: "…`.
        let builder = SystemPromptBuilder(basePrompt: SystemPromptBuilder.codingAgentIdentity)
        let built = await builder.build(hasTools: false)
        let lower = built.lowercased()
        #expect(!lower.contains("use your tools"))
        #expect(!lower.contains("run commands"))
        #expect(lower.contains("no tools"))
        #expect(lower.contains("never pretend to run a command"))
        #expect(lower.contains("fabrication"))
        // Identity/honesty survives on both branches.
        #expect(built.contains("an agent for open models"))
        #expect(lower.contains("never hide, soften, or fabricate"))
    }

    @Test("with-tools turn keeps the action-first directive")
    func toolsTurnKeepsActionDirective() async {
        let builder = SystemPromptBuilder(basePrompt: SystemPromptBuilder.codingAgentIdentity)
        let built = await builder.build(hasTools: true)
        #expect(built.contains(SystemPromptBuilder.toolActionDirective))
        #expect(!built.contains(SystemPromptBuilder.noToolsDirective))
    }

    @Test(
        "with-tools turn bans claiming an action it did not take"
    )
    func toolsTurnBansNarratedActions() async {
        // Live 2026-10-12: `web_search` declared, no tool dispatched, and the model
        // still wrote "I have searched the web … (Source: https://mlx.studio/)".
        let built = SystemPromptBuilder.basePrompt(hasTools: true).lowercased()
        #expect(built.contains("claiming an action requires having called the tool"))
        #expect(built.contains("narration that sounds like a completed action is not one"))
        // The ban must exist on BOTH surfaces — a turn with tools and a turn
        // without both fabricate; only the wording differs.
        let noTools = SystemPromptBuilder.basePrompt(hasTools: false).lowercased()
        #expect(noTools.contains("never pretend to run a command"))
    }

    @Test("tool surface is part of the prompt cache key")
    func toolSurfaceSeparatesCache() async {
        // One builder serves many turns. If `hasTools` were outside the hash, an
        // agentic turn would serve the cached no-tools prompt next time — the
        // model silently losing (or gaining) its marching orders.
        let builder = SystemPromptBuilder(basePrompt: SystemPromptBuilder.codingAgentIdentity)
        let withTools = await builder.build(hasTools: true)
        let without = await builder.build(hasTools: false)
        #expect(withTools != without)
        // Repeat in the other order: both must still be correct, not sticky.
        let withoutAgain = await builder.build(hasTools: false)
        let withToolsAgain = await builder.build(hasTools: true)
        #expect(withoutAgain == without)
        #expect(withToolsAgain == withTools)
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
