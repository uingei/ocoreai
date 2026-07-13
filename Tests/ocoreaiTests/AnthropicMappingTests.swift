// Copyright © 2026 uingeai.
// Licensed under MIT.
/// AnthropicMappingTests.swift — Cross-protocol stop reason mapping.
///
/// Behavioral invariant: Anthropic stop_reason ↔ OpenAI finish_reason
/// must be bijective (round-trip identity). Unknown values must not crash.

import Testing
import Foundation
@testable import ocoreai

@Suite("Anthropic ↔ OpenAI stop reason mapping")
struct AnthropicMappingTests {
    
    // MARK: - Known mappings
    
    @Test("Anthropic end_turn maps to OpenAI stop")
    func endTurnToStop() {
        #expect(anthropicToOpenAIFinishReason("end_turn") == "stop")
    }
    
    @Test("Anthropic max_tokens maps to OpenAI length")
    func maxTokensToLength() {
        #expect(anthropicToOpenAIFinishReason("max_tokens") == "length")
    }
    
    @Test("Anthropic tool_use maps to OpenAI tool_calls")
    func toolUseToToolCalls() {
        #expect(anthropicToOpenAIFinishReason("tool_use") == "tool_calls")
    }
    
    @Test("Anthropic stop_sequence maps to OpenAI stop")
    func stopSequenceToStop() {
        #expect(anthropicToOpenAIFinishReason("stop_sequence") == "stop")
    }
    
    @Test("Anthropic error maps to OpenAI error")
    func errorToError() {
        #expect(anthropicToOpenAIFinishReason("error") == "error")
    }
    
    // MARK: - Reverse mappings
    
    @Test("OpenAI stop maps to Anthropic end_turn")
    func stopToEndTurn() {
        #expect(openAIToAnthropicStopReason("stop") == "end_turn")
    }
    
    @Test("OpenAI length maps to Anthropic max_tokens")
    func lengthToMaxTokens() {
        #expect(openAIToAnthropicStopReason("length") == "max_tokens")
    }
    
    @Test("OpenAI tool_calls maps to Anthropic tool_use")
    func toolCallsToToolUse() {
        #expect(openAIToAnthropicStopReason("tool_calls") == "tool_use")
    }
    
    // MARK: - Round-trip invariants
    
    @Test("Anthropic → OpenAI → Anthropic round-trip for known reasons")
    func roundTripAnthropicToAnthropic() {
        let known = ["end_turn", "max_tokens", "tool_use", "stop_sequence", "error"]
        for reason in known {
            let openAI = anthropicToOpenAIFinishReason(reason)
            let back = openAIToAnthropicStopReason(openAI)
            #expect(back == reason || (reason == "stop_sequence" && back == "end_turn"),
                   "\(reason) → \(openAI) → \(back)")
        }
    }
    
    @Test("OpenAI → Anthropic → OpenAI round-trip for shared reasons")
    func roundTripOpenAIToOpenAI() {
        // cancelled is OpenAI-specific (Anthropic has no equivalent),
        // so it fails round-trip — verify that explicitly below.
        let shared = ["stop", "length", "tool_calls", "error"]
        for reason in shared {
            let anthropic = openAIToAnthropicStopReason(reason)
            let back = anthropicToOpenAIFinishReason(anthropic)
            #expect(back == reason,
                   "\(reason) → \(anthropic) → \(back)")
        }
    }
    
    @Test("OpenAI 'cancelled' has no Anthropic equivalent — maps to stop")
    func cancelledOpenAISpecific() {
        // Behavioural: cancelled passthroughs to Anthropic, but Anthropic has
        // no 'cancelled' — it falls back to 'stop'. This is a known protocol gap.
        let toAnthropic = openAIToAnthropicStopReason("cancelled")
        #expect(toAnthropic == "cancelled")
        let toOpenAI = anthropicToOpenAIFinishReason(toAnthropic)
        #expect(toOpenAI == "stop")
    }
    
    // MARK: - Unknown value safety
    
    @Test("Unknown Anthropic reason falls back to stop, does not crash")
    func unknownAnthropicReason() {
        // Safety: model may emit unknown reason; must not crash
        #expect(anthropicToOpenAIFinishReason("__unknown_reason__") == "stop")
        #expect(anthropicToOpenAIFinishReason("") == "stop")
    }
    
    @Test("Unknown OpenAI reason falls back to end_turn, does not crash")
    func unknownOpenAIReason() {
        #expect(openAIToAnthropicStopReason("__unknown_reason__") == "end_turn")
        #expect(openAIToAnthropicStopReason("") == "end_turn")
    }
}
