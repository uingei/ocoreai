// Copyright © 2026 uingei@163.com.
/// MCP tool-result rendering — text passthrough + non-text survival.
///
/// Baseline: codex `75cb7c903d` "Preserve MCP tool output as content items"
/// — non-text content must survive the tool-result channel.
/// ocoreai channel is text-only (`ChatSession.toolDispatch` returns `String`,
/// upstream `MLXLMCommon/ChatSession.swift:318`), so media blocks render as
/// explicit `[<type>]` placeholders instead of failing the call or vanishing.
///
/// Regression target: pre-fix, a media-only result threw "No text content in
/// response" (forward path) or returned "(no content)" (registered handler) —
/// the agent saw a hard failure or dead silence instead of "[image]".

import Testing

@testable import ocoreai

@Suite("MCP — tool result rendering (codex #40737 baseline)")
struct MCPToolResultRenderingTests {

    @Test("two text blocks joined verbatim, separator preserved")
    static func twoTextBlocks() {
        let blocks: [[String: String]] = [
            ["type": "text", "text": "a"],
            ["type": "text", "text": "b"],
        ]
        #expect(MCPBridge.renderToolResultBlocks(blocks) == "a\n---\nb")
    }

    @Test("multi-word text blocks joined verbatim")
    static func multiWordTextBlocks() {
        let blocks: [[String: String]] = [
            ["type": "text", "text": "hello"],
            ["type": "text", "text": "world"],
        ]
        #expect(MCPBridge.renderToolResultBlocks(blocks) == "hello\n---\nworld")
    }

    @Test("single text block — no separator bleed")
    static func singleTextBlock() {
        let blocks: [[String: String]] = [["type": "text", "text": "only"]]
        #expect(MCPBridge.renderToolResultBlocks(blocks) == "only")
    }

    @Test("media-only result renders [type] placeholder instead of empty")
    static func mediaOnly() {
        let blocks: [[String: String]] = [
            ["type": "image", "mimeType": "image/png", "data": "iVBORw0KGgo="],
            ["type": "audio", "mimeType": "audio/wav", "data": "R0lGODlh"],
        ]
        #expect(MCPBridge.renderToolResultBlocks(blocks) == "[image]\n---\n[audio]")
    }

    @Test("mixed text+media — text and placeholders both survive, order kept")
    static func mixedContent() {
        let blocks: [[String: String]] = [
            ["type": "text", "text": "see screenshot"],
            ["type": "image", "mimeType": "image/png", "data": "iVBORw0KGgo="],
            ["type": "text", "text": "and this note"],
        ]
        #expect(
            MCPBridge.renderToolResultBlocks(blocks)
                == "see screenshot\n---\n[image]\n---\nand this note")
    }

    @Test("unknown-type block without text still surfaces as [type]")
    static func unknownType() {
        let blocks: [[String: String]] = [["type": "resource", "uri": "file:///x"]]
        #expect(MCPBridge.renderToolResultBlocks(blocks) == "[resource]")
    }

    @Test("empty block array renders empty — callers keep their typed errors")
    static func emptyBlocks() {
        #expect(MCPBridge.renderToolResultBlocks([]) == "")
    }

    @Test("block with empty text but known type degrades to [type]")
    static func emptyTextKnownType() {
        let blocks: [[String: String]] = [["type": "text", "text": ""]]
        #expect(MCPBridge.renderToolResultBlocks(blocks) == "[text]")
    }
}
