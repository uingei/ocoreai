// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// Pins the wire `reasoning` → `enable_thinking` three-state resolution so the
// old silent-swallow regression (an explicit `reasoning: false` folding back
// into the model template default ON) cannot reappear. Gold standard: exact
// value assertions on `ReasoningResolution.thinkingEnabled`.

import Foundation
import Testing

@testable import ocoreai

@Suite("ReasoningResolution.thinkingEnabled")
struct ReasoningResolutionTests {

    // MARK: - reasoningLevel absent — the explicit `reasoning` bool must win

    @Test("nil level + explicit true → ON")
    func levelAbsent_reasoningTrue() {
        #expect(
            ReasoningResolution.thinkingEnabled(
                reasoningLevel: nil, enableReasoning: true) == true)
    }

    @Test("nil level + explicit false → OFF (the regression we fixed)")
    func levelAbsent_reasoningFalse() {
        #expect(
            ReasoningResolution.thinkingEnabled(
                reasoningLevel: nil, enableReasoning: false) == false)
    }

    @Test("nil level + nil bool → nil (model template default)")
    func levelAbsent_reasoningNil() {
        #expect(
            ReasoningResolution.thinkingEnabled(
                reasoningLevel: nil, enableReasoning: nil) == nil)
    }

    // MARK: - explicit reasoningLevel words

    @Test("light/moderate/deep → ON regardless of bool")
    func knownLevels_forceOn() {
        for level in ["light", "moderate", "deep"] {
            #expect(
                ReasoningResolution.thinkingEnabled(
                    reasoningLevel: level, enableReasoning: nil) == true)
            #expect(
                ReasoningResolution.thinkingEnabled(
                    reasoningLevel: level, enableReasoning: false) == true,
                "an explicit light/moderate/deep level forces ON even if bool absent")
        }
    }

    @Test("unknown level (no_think) + nil bool → OFF (not the template default)")
    func unknownLevel_absentBool_isOff() {
        #expect(
            ReasoningResolution.thinkingEnabled(
                reasoningLevel: "no_think", enableReasoning: nil) == false)
    }

    @Test("unknown level + explicit true → ON (bool overrides the disabling level)")
    func unknownLevel_explicitTrue_overrides() {
        #expect(
            ReasoningResolution.thinkingEnabled(
                reasoningLevel: "no_think", enableReasoning: true) == true)
    }

    @Test("unknown level + explicit false → OFF")
    func unknownLevel_explicitFalse_isOff() {
        #expect(
            ReasoningResolution.thinkingEnabled(
                reasoningLevel: "no_think", enableReasoning: false) == false)
    }

    // MARK: - case-insensitivity of level words

    @Test("level words are case-insensitive")
    func levelWordsCaseInsensitive() {
        for (level, expected) in [("Deep", true), ("NO_THINK", false), ("Light", true)] {
            let got = ReasoningResolution.thinkingEnabled(
                reasoningLevel: level, enableReasoning: nil)
            #expect(
                got == expected,
                "level '\(level)' resolved to \(String(describing: got)), expected \(expected)")
        }
    }

    @Test("whitespace level is trimmed to absent → explicit bool wins")
    func whitespaceLevel_trimmedToAbsent() {
        #expect(
            ReasoningResolution.thinkingEnabled(
                reasoningLevel: "   ", enableReasoning: false) == false)
        #expect(
            ReasoningResolution.thinkingEnabled(
                reasoningLevel: "   ", enableReasoning: true) == true)
        #expect(
            ReasoningResolution.thinkingEnabled(
                reasoningLevel: "   ", enableReasoning: nil) == nil)
    }
}
