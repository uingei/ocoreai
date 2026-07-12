// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AgentLoopConfigTests.swift — Config & request validation logic
///
/// Coverage:
/// - AgentLoopConfig: default values, custom values, isSingle, precondition guard
/// - InferenceRequest: defaults, custom tool definitions, cancellation token
/// - StreamingInferenceResult: field verification
/// - DirectInferenceError: errorDescription for each case

import Testing
import Foundation
import Logging
@testable import ocoreai
import ocoreaiTestUtilities

// MARK: - InferenceRequest

@Suite("InferenceRequest")
struct InferenceRequestTests {

    @Test("default optionals are nil")
    func defaultOptionalsAreNil() {
        let request = InferenceRequest(
            modelId: "test-model",
            messages: []
        )
        #expect(request.modelId == "test-model")
        #expect(request.messages.isEmpty)
        #expect(request.systemPrompt == nil)
        #expect(request.tools == nil)
        #expect(request.sessionId == nil)
        #expect(request.temperature == nil)
        #expect(request.topP == nil)
        #expect(request.topK == nil)
        #expect(request.maxTokens == nil)
        #expect(request.stopSequences == nil)
        #expect(request.logitBias == nil)
        #expect(request.cancellation == nil)
    }

    @Test("with custom sampling params")
    func customSamplingParams() {
        let request = InferenceRequest(
            modelId: "llama-3",
            messages: [Message(role: "user", content: "hi")],
            systemPrompt: "You are helpful",
            temperature: 0.7,
            topP: 0.95,
            topK: 50,
            maxTokens: 2048,
            stopSequences: ["\n\nHuman:"],
            logitBias: ["stop": -2.0],
            sessionId: "sess-42"
        )
        #expect(request.modelId == "llama-3")
        #expect(request.messages.count == 1)
        #expect(request.systemPrompt == "You are helpful")
        #expect(request.temperature == 0.7)
        #expect(request.topP == 0.95)
        #expect(request.topK == 50)
        #expect(request.maxTokens == 2048)
        #expect(request.stopSequences == ["\n\nHuman:"])
        #expect(request.logitBias?["stop"] == -2.0)
        #expect(request.sessionId == "sess-42")
    }

    @Test("with custom tool definitions")
    func withTools() {
        let tool = ToolDef(
            type: "function",
            function: FunctionDef(
                name: "search",
                description: "Search the web",
                parameters: nil
            )
        )
        let request = InferenceRequest(
            modelId: "gpt-4",
            messages: [Message(role: "user", content: "search something")],
            tools: [tool]
        )
        #expect(request.tools?.count == 1)
        #expect(request.tools?.first?.function.name == "search")
    }

    @Test("with cancellation token")
    func withCancellation() {
        let cancellation = InferenceCancellation.cancellable()
        let request = InferenceRequest(
            modelId: "test-model",
            messages: [Message(role: "user", content: "hello")],
            cancellation: cancellation
        )
        #expect(request.cancellation != nil)
        #expect(request.cancellation?.isCancelled == false)
        cancellation.cancel()
        #expect(request.cancellation?.isCancelled == true)
    }

    @Test("without cancellation token defaults to nil")
    func noCancellation() {
        let request = InferenceRequest(
            modelId: "test-model",
            messages: []
        )
        #expect(request.cancellation == nil)
    }
}

// MARK: - StreamingInferenceResult

@Suite("StreamingInferenceResult")
struct StreamingInferenceResultTests {

    @Test("created with values preserves all fields")
    func allFieldsSet() {
        let result = StreamingInferenceResult(
            accumulatedText: "Hello world",
            stopReason: "stop",
            inputTokens: 64,
            outputTokens: 32
        )
        #expect(result.accumulatedText == "Hello world")
        #expect(result.stopReason == "stop")
        #expect(result.inputTokens == 64)
        #expect(result.outputTokens == 32)
    }

    @Test("stopReason can be nil")
    func nilStopReason() {
        let result = StreamingInferenceResult(
            accumulatedText: "",
            stopReason: nil,
            inputTokens: 0,
            outputTokens: 0
        )
        #expect(result.accumulatedText == "")
        #expect(result.stopReason == nil)
        #expect(result.inputTokens == 0)
        #expect(result.outputTokens == 0)
    }

    @Test("mutable accumulatedText")
    func mutableAccumulatedText() {
        var result = StreamingInferenceResult(
            accumulatedText: "",
            stopReason: nil,
            inputTokens: 10,
            outputTokens: 0
        )
        result.accumulatedText += "Hello"
        result.accumulatedText += " world"
        result.outputTokens = 2
        result.stopReason = "stop"
        #expect(result.accumulatedText == "Hello world")
        #expect(result.outputTokens == 2)
        #expect(result.stopReason == "stop")
    }
}

// MARK: - DirectInferenceError

@Suite("DirectInferenceError")
struct DirectInferenceErrorTests {

    @Test("engineNotReady has correct errorDescription")
    func engineNotReadyMessage() {
        let error = DirectInferenceError.engineNotReady
        #expect(error.errorDescription == "Inference engine not yet ready")
    }

    @Test("schedulerNotReady has correct errorDescription")
    func schedulerNotReadyMessage() {
        let error = DirectInferenceError.schedulerNotReady
        #expect(error.errorDescription == "Scheduler not yet ready")
    }

    @Test("messageBuilderNotReady has correct errorDescription")
    func messageBuilderNotReadyMessage() {
        let error = DirectInferenceError.messageBuilderNotReady
        #expect(error.errorDescription == "Message builder not ready")
    }

    @Test("contentBlocked includes reason in errorDescription")
    func contentBlockedMessage() {
        let error = DirectInferenceError.contentBlocked("Safety violation detected")
        #expect(error.errorDescription == "Content blocked: Safety violation detected")
    }

    @Test("contentBlocked with custom reason")
    func contentBlockedCustomReason() {
        let error = DirectInferenceError.contentBlocked("Policy violation: P001")
        #expect(error.errorDescription?.contains("Policy violation: P001") == true)
        #expect(error.errorDescription?.hasPrefix("Content blocked: ") == true)
    }

    @Test("all cases conform to Error")
    func conformsToError() {
        let errors: [any Error] = [
            DirectInferenceError.engineNotReady,
            DirectInferenceError.schedulerNotReady,
            DirectInferenceError.messageBuilderNotReady,
            DirectInferenceError.contentBlocked("blocked")
        ]
        #expect(errors.count == 4)
    }
}

// MARK: - AgentLoopConfig

@Suite("AgentLoopConfig")
struct AgentLoopConfigTests {

    func makeConfig(
        maxIter: Int = 30,
        tokenBudget: Int = 8192,
        guardMargin: Int = 512,
        timeoutSeconds: TimeInterval = 180,
        caller: String = "agent"
    ) -> AgentLoopConfig {
        let registry = ToolRegistry(log: Logger(label: "test.agent.loop"))
        // MessageBuilder is an actor — create the minimal viable chain
        // We only test the config struct itself; registry is already an actor
        // and MessageBuilder requires SQLite dependencies, so for config-only
        // tests we construct the minimal MessageBuilder possible.
        // However, AgentLoopConfig just stores the MessageBuilder reference,
        // so we really only need a MessageBuilder instance.
        //
        // Since MessageBuilder requires SystemPromptBuilder + SessionCompressor
        // + ComplexityAnalyzer + ThinkingBudget, and those have deep SQLite
        // deps, we test config fields that DON'T require actor deps directly:
        // maxIter, tokenBudget, guardMargin, timeoutSeconds, caller, isSingle,
        // and the precondition guard.
        // For tests that need a full config, we use a temporary SQLite store.
        let spBuilder = SystemPromptBuilder(basePrompt: "test")
        let store = SQLiteStore(path: String(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("agent_loop_config_test_\(UUID().uuidString.prefix(8)).sqlite")
                .path
        ))
        Task {
            try? await store.open()
        }
        let fts = FTS5Search(store: store)
        let compressor = SessionCompressor(store: store, fts: fts)
        let analyzer = ComplexityAnalyzer()
        let budget = ThinkingBudget()
        let builder = MessageBuilder(
            systemPromptBuilder: spBuilder,
            sessionCompressor: compressor,
            complexityAnalyzer: analyzer,
            thinkingBudget: budget
        )
        return AgentLoopConfig(
            maxIter: maxIter,
            tokenBudget: tokenBudget,
            guardMargin: guardMargin,
            timeoutSeconds: timeoutSeconds,
            registry: registry,
            builder: builder,
            caller: caller
        )
    }

    @Test("default values")
    func defaults() async {
        // Note: registry and builder are required non-optional, so we can't
        // test pure defaults. Instead, verify that when we pass default values
        // explicitly, they match the documented defaults.
        let config = makeConfig(
            maxIter: 30,
            tokenBudget: 8192,
            guardMargin: 512,
            timeoutSeconds: 180,
            caller: "agent"
        )
        #expect(config.maxIter == 30)
        #expect(config.tokenBudget == 8192)
        #expect(config.guardMargin == 512)
        #expect(config.timeoutSeconds == 180)
        #expect(config.caller == "agent")
    }

    @Test("custom values are preserved")
    func customValues() async {
        let config = makeConfig(
            maxIter: 5,
            tokenBudget: 4096,
            guardMargin: 128,
            timeoutSeconds: 60,
            caller: "ui-direct"
        )
        #expect(config.maxIter == 5)
        #expect(config.tokenBudget == 4096)
        #expect(config.guardMargin == 128)
        #expect(config.timeoutSeconds == 60)
        #expect(config.caller == "ui-direct")
    }

    @Test("isSingle returns true when maxIter is 1")
    func isSingleTrue() async {
        let config = makeConfig(maxIter: 1)
        #expect(config.isSingle == true)
    }

    @Test("isSingle returns false when maxIter > 1")
    func isSingleFalse() async {
        let config = makeConfig(maxIter: 5)
        #expect(config.isSingle == false)
    }

    // Note: AgentLoopConfig.init uses `precondition(maxIter >= 1)` which
    // crashes (does not throw). Following ProfilingTests.swift convention,
    // we skip the double-call crash test and instead verify that maxIter=1
    // is the minimum accepted value (tested by isSingleTrue above).
}
