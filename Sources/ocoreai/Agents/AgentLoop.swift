// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Agent Loop — closes the gap between tool_call detection and tool execution.
///
/// ### Responsibility:
/// 1. Run inference → detect tool_calls → execute via ToolRegistry → inject results → repeat
/// 2. Converge when assistant produces plain text (no tool_calls)
/// 3. Guard against infinite loops: maxIterations + tokenBudget
///
/// ### Design:
/// - Non-stream path: loop runs silently, returns AgentLoopResult
/// - Stream path: middle iterations are silent, only final iteration writes SSE
/// - Token budget: decrements each iteration; if budget < guardMargin, forces convergence
///
/// ### Safety:
/// - ToolRegistry.call() enforces loop detection per-tool
/// - AgentLoop tracks per-iteration tool_count to detect model divergence
/// - Timeout per agent run (configurable, default 120s)
///
/// ### No side effects on existing files:
/// - Pure loop coordinator — uses ToolRegistry, EngineHandle, MessageBuilder
/// - Does not modify ChatHandler's Phase 1-4 pipeline (scheduler, engine, params)
/// - Does not modify stream/non-stream response building logic
/// - Does not modify SSE/SSEHelpers

import Foundation
import Logging
import NIOCore

// MARK: - Configuration

/// Agent loop configuration — defaults to maxIter=1 (single inference, no loop).
struct AgentLoopConfig {
    /// Maximum agent iterations per request.
    let maxIter: Int

    /// Token budget per request total.
    let tokenBudget: Int

    /// Minimum tokens remaining before forcing convergence.
    let guardMargin: Int

    /// Timeout for the entire agent run (seconds).
    let timeoutSeconds: TimeInterval

    /// Tool registry for dispatching tool calls.
    let registry: ToolRegistry

    /// Message builder for context assembly after tool injection.
    let builder: MessageBuilder

    /// Caller identity for audit trail.
    let caller: String

    init(
        maxIter: Int = 30,
        tokenBudget: Int = 8192,
        guardMargin: Int = 512,
        timeoutSeconds: TimeInterval = 180,
        registry: ToolRegistry,
        builder: MessageBuilder,
        caller: String = "agent"
    ) {
        precondition(maxIter >= 1, "maxIter must be >= 1")
        self.maxIter = maxIter
        self.tokenBudget = tokenBudget
        self.guardMargin = guardMargin
        self.timeoutSeconds = timeoutSeconds
        self.registry = registry
        self.builder = builder
        self.caller = caller
    }

    /// Whether this config allows single-shot only (loop disabled by design).
    var isSingle: Bool { maxIter == 1 }
}

// MARK: - Result

/// Agent loop result after all iterations complete.
struct AgentLoopResult {
    /// Final text content (assistant response or tool-call marker).
    var text: String = ""

    /// Tool calls if the loop terminated with tool calls on the last iteration.
    var toolCalls: [ToolCall]? = nil

    /// How many inference runs were performed inside the loop.
    var iterationCount: Int = 0

    /// Per-iteration breakdown.
    var iters: [AgentLoopIterationLog] = []

    /// Final finish reason string.
    var finishReason: String = "stop"

    /// Total output tokens spent by inference (not including tool-execution overhead).
    var totalTokens: Int = 0
}

/// Single iteration log entry for observability.
struct AgentLoopIterationLog: CustomStringConvertible {
    let iteration: Int
    let tok: Int
    let toolN: Int
    let ms: Double
    let tag: String

    var description: String { "iter-\(iteration) tok=\(tok) tools=\(toolN) ms=\(Int(ms)) \(tag)" }
}

// MARK: - Agent Loop (Core)

/// Stateless agent loop coordinator.
///
/// ### Flow:
/// ```
/// ┌──────────┐     ┌───────────────┐     ┌───────────────┐     ┌──────────┐
/// │  Inference ──→ │  parseToolCalls  ──→ │ executeTools   ──→ │  Inject &  │
/// │  (Engine)  │     │  (detect)      │     │  (ToolRegistry) │  │  Retry     │
/// └──────────┘     └───────────────┘     └───────────────┘     └────┬─────┘
///       ▲                                                              │
///       └──────────────────── iteration loop ──────────────────────────┘
/// ```

enum AgentLoop {

    // MARK: - Public entry points

    /// Run agent loop (non-stream).
    static func run(
        config: AgentLoopConfig,
        handle: EngineHandle,
        initialMessages: [Message],
        modelId: String,
        sampling: SamplingConfiguration,
        options: InferenceOptions,
        logger: Logger? = nil
    ) async throws -> AgentLoopResult {
        let log: Logger = logger ?? Logger(label: "AgentLoop")
        // Fast path: single iteration
        if config.isSingle {
            return try await oneInference(
                handle: handle,
                messages: initialMessages,
                sampling: sampling,
                options: options,
                logger: log
            )
        }

        // Check registry has tools
        let toolList = await config.registry.listTools()
        if toolList.isEmpty {
            log.info("AgentLoop: registry empty, single-shot")
            return try await oneInference(
                handle: handle,
                messages: initialMessages,
                sampling: sampling,
                options: options,
                logger: log
            )
        }

        // ── Multi-turn loop ──────────────────────────────────────────────
        var msgs = initialMessages
        var budgetRemaining = config.tokenBudget
        var logs: [AgentLoopIterationLog] = []
        var iterCount = 0
        var totalTok = 0

        // Context guard: limit tool turn count to prevent context explosion.
        // Each iteration adds ~2 messages (assistant tool_call + tool result).
        // With maxIter=30 this could yield 60+ extra messages (90+ total).
        let initialMsgCount = msgs.count
        let maxToolRounds = 10  // Keep at most N rounds of tool call/results
        var toolRoundCount = 0

        log.info("AgentLoop started (max=\(config.maxIter), budget=\(config.tokenBudget), tools=\(toolList.count))")

        let deadline = ContinuousClock.now + .seconds(config.timeoutSeconds)

        for i in 1...config.maxIter {
            guard ContinuousClock.now < deadline else {
                log.warning("AgentLoop: timeout after \(iterCount) iterations")
                return AgentLoopResult(
                    text: "[agent-loop: timeout after \(Int(config.timeoutSeconds))s]",
                    iterationCount: iterCount,
                    iters: logs,
                    finishReason: "timeout",
                    totalTokens: totalTok
                )
            }

            // Respond to task cancellation before each iteration
            guard !Task.isCancelled else {
                log.info("AgentLoop: cancelled at iteration \(i)")
                return AgentLoopResult(
                    text: "[agent-loop: cancelled]",
                    iterationCount: iterCount,
                    iters: logs,
                    finishReason: "cancelled",
                    totalTokens: totalTok
                )
            }

            // Budget guard
            guard budgetRemaining >= config.guardMargin else {
                log.info("AgentLoop: budget below guardMargin (\(budgetRemaining)), stopping")
                break
            }

            iterCount = i
            let tStart = ContinuousClock.now

            // ── Inference ───────────────────────────────────────────────
            let (text, tokCount) = try await doInfer(
                handle: handle,
                messages: msgs,
                sampling: sampling,
                options: options,
                logger: log
            )

            let elapsed = tStart.duration(to: ContinuousClock.now)
            let elapsedMs = Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1e13
            totalTok += tokCount
            budgetRemaining -= tokCount

            // ── Check for tool calls ────────────────────────────────────
            if let tc = parseToolCalls(from: text), !tc.isEmpty {
                log.info("AgentLoop iter \\(i): \\(tc.count) tool_calls in \\(tokCount) tokens (\\(elapsedMs)ms)")

                // ── Execute tools ───────────────────────────────────────
                let toolResults = await executeTools(tc: tc, registry: config.registry, caller: config.caller, logger: log)

                // ── Inject tool messages ────────────────────────────────
                // Assistant message with tool calls
                msgs.append(Message(
                    role: "assistant",
                    content: nil,
                    name: nil,
                    toolCalls: tc,
                    toolCallID: nil
                ))

                // Tool result messages
                for (idx, result) in toolResults.enumerated() {
                    msgs.append(Message(
                        role: "tool",
                        content: .text(result),
                        name: tc[idx].function.name,
                        toolCalls: nil,
                        toolCallID: tc[idx].id
                    ))
                }

                // Context trimming: keep initial messages + at most
                // maxToolRounds of tool call/result pairs to prevent
                // context explosion over many iterations.
                toolRoundCount += 1
                if toolRoundCount > maxToolRounds {
                    // Prune oldest tool round, preserving initial messages
                    let toolMsgCount = msgs.count - initialMsgCount
                    let keepToolMsgs = maxToolRounds * 2  // ~2 msgs per round
                    if toolMsgCount > keepToolMsgs {
                        let pruneCount = toolMsgCount - keepToolMsgs
                        // Remove messages after initial set, skip first `pruneCount`
                        msgs.removeSubrange(initialMsgCount..<(initialMsgCount + pruneCount))
                        log.info("AgentLoop: pruned \\\\(pruneCount) old tool messages (keeping \\\\(keepToolMsgs))")
                    }
                }

                logs.append(AgentLoopIterationLog(
                    iteration: i,
                    tok: tokCount,
                    toolN: tc.count,
                    ms: elapsedMs,
                    tag: "[\(tc.map { $0.function.name }.joined(separator: ","))]"
                ))
            } else {
                // Converged — plain text response
                log.info("AgentLoop: converged after \\(i) iterations")
                logs.append(AgentLoopIterationLog(
                    iteration: i, tok: tokCount, toolN: 0, ms: elapsedMs, tag: "converged"
                ))
                return AgentLoopResult(
                    text: text,
                    iterationCount: i,
                    iters: logs,
                    finishReason: "stop",
                    totalTokens: totalTok
                )
            }
        }

        // Max iterations hit — force convergence
        log.warning("AgentLoop: exhausted \\(config.maxIter) iterations")
        return AgentLoopResult(
            text: "[agent-loop: max iterations reached]",
            iterationCount: iterCount,
            iters: logs,
            finishReason: "max_iter",
            totalTokens: totalTok
        )
    }

    // MARK: - Single inference

    /// Run a single inference — extracts complete text + token count.
    static func oneInference(
        handle: EngineHandle,
        messages: [Message],
        sampling: SamplingConfiguration,
        options: InferenceOptions,
        logger: Logger
    ) async throws -> AgentLoopResult {
        let (text, tok) = try await doInfer(
            handle: handle,
            messages: messages,
            sampling: sampling,
            options: options,
            logger: logger
        )
        let tc = parseToolCalls(from: text)
        let hasNonEmptyToolCalls = (tc?.count ?? 0) > 0
        return AgentLoopResult(
        	text: text,
        	toolCalls: tc,
        	iterationCount: 1,
        	finishReason: hasNonEmptyToolCalls ? "tool_calls" : "stop",
        	totalTokens: tok
        )
    }

    // MARK: - Tool execution

    /// Execute tools in parallel and return one result string per tool call.
    /// Tool outputs are filtered through ContentGuard to prevent injection of
    /// malicious tool results back into the inference context.
    private static func executeTools(
        tc: [ToolCall],
        registry: ToolRegistry,
        caller: String,
        logger: Logger
    ) async -> [String] {
        await withTaskGroup(of: (Int, String).self) { group in
            var results = [String](repeating: "", count: tc.count)
            for (idx, tool) in tc.enumerated() {
                group.addTask {
                    do {
                        let r = try await registry.call(
                            tool.function.name,
                            arguments: tool.function.arguments,
                            caller: caller
                        )
                        // Filter tool output through ContentGuard to sanitize
                        // results before injecting back into context
                        if let contentGuard = await OcoreaiEngine.shared.activeContentGuard,
                           await contentGuard.checkOutput(r).isBlocked {
                            logger.warning("AgentLoop: tool output blocked by ContentGuard")
                            return (idx, "[tool-output-filtered: safety check failed]")
                        }
                        return (idx, r)
                    } catch {
                        return (idx, "[tool-error:\(tool.function.name)] \(error.localizedDescription)")
                    }
                }
            }
            for await (idx, r) in group {
                results[idx] = r
            }
            return results
        }
    }


    // MARK: - Inference

    /// Run one inference, return decoded text + token count.
    private static func doInfer(
        handle: EngineHandle,
        messages: [Message],
        sampling: SamplingConfiguration,
        options: InferenceOptions,
        logger: Logger
    ) async throws -> (text: String, tokens: Int) {
        let stream = handle.generateFromMessages(
            messages: messages,
            sampling: sampling,
            options: options
        )
        var accumulatedText = ""
        var tokCount = 0
        do {
            for try await ev in stream {
                // Respond to upstream task cancellation (e.g., user interrupt, model switch)
                // Check every 128 tokens to balance responsiveness vs overhead
                if tokCount.isMultiple(of: 128), tokCount > 0 {
                    try Task.checkCancellation()
                }
                switch ev.kind {
                case .token:
                    // Each .token event is one generated token (CoreAI path)
                    tokCount += 1
                case .done:
                    break
                case let .text(t):
                    accumulatedText += t
                    // Each .text event is at least one token decoded (MLX path).
                    // Counting +1 per event keeps the budget guard proportional
                    // across both backends without over-estimating.
                    tokCount += 1
                case let .error(e):
                    logger.warning("AgentLoop inference error: \(e)")
                }
            }
        } catch {
            if !Task.isCancelled {
                logger.error("AgentLoop: inference failed: \(error)")
            }
            throw error
        }
        return (accumulatedText, tokCount)
    }
}
