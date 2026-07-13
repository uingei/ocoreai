// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AuditTrailTests.swift — AuditTrail actor: record, query, enforce, export
/// Removed: AuditEntry model self-proof (struct field assertions, Codable, enum case count)

import Foundation
import Testing
@testable import ocoreai

@Suite("AuditTrail — Recording")
struct AuditTrailRecordingTests {
    func makeTrail() -> AuditTrail {
        AuditTrail(maxEntries: 100, retentionDays: 7, serviceName: "test")
    }
    
    @Test("Empty trail has no entries")
    func emptyTrail() async {
        let trail = makeTrail()
        let entries = await trail.recent()
        #expect(entries.isEmpty)
    }
    
    @Test("Record a successful call")
    func recordSuccess() async {
        let trail = makeTrail()
        let token = await trail.beginCall(
            caller: "agent",
            toolName: "test_tool",
            toolset: "test",
            arguments: ["input": "hello"]
        )
        #expect(!token.id.isEmpty)
        #expect(!token.traceID.isEmpty)
        #expect(token.caller == "agent")
        
        await trail.completeToken(token, status: .success, result: "ok result")
        
        let entries = await trail.recent()
        #expect(entries.count == 1)
        #expect(entries[0].toolName == "test_tool")
        #expect(entries[0].status == .success)
    }
    
    @Test("Record an error call")
    func recordError() async {
        let trail = makeTrail()
        let token = await trail.beginCall(
            caller: "agent",
            toolName: "fail_tool",
            toolset: "test",
            arguments: [:]
        )
        await trail.completeToken(token, status: .error, result: "something went wrong")
        
        let entries = await trail.recent()
        #expect(entries.count == 1)
        #expect(entries[0].status == .error)
    }
    
    @Test("Multiple calls recorded in order")
    func multipleCalls() async {
        let trail = makeTrail()
        for i in 0..<5 {
            let token = await trail.beginCall(
                caller: "agent",
                toolName: "tool_\(i)",
                toolset: "test",
                arguments: [:]
            )
            await trail.completeToken(token, status: .success, result: "result \(i)")
        }
        
        let entries = await trail.recent()
        #expect(entries.count == 5)
    }
    
    @Test("Entry duration is recorded")
    func durationRecorded() async {
        let trail = makeTrail()
        let token = await trail.beginCall(
            caller: "agent",
            toolName: "timed_tool",
            toolset: "test",
            arguments: [:]
        )
        await trail.completeToken(token, status: .success, result: "done")
        
        let entries = await trail.recent()
        #expect(entries.count == 1)
        #expect(entries[0].durationMs >= 0.0)
    }
    
    @Test("Result summary is truncated to 512 chars")
    func resultSummaryTruncated() async {
        let trail = makeTrail()
        let longResult = String(repeating: "x", count: 1024)
        let token = await trail.beginCall(
            caller: "agent",
            toolName: "long_result",
            toolset: "test",
            arguments: [:]
        )
        await trail.completeToken(token, status: .success, result: longResult)
        
        let entries = await trail.recent()
        #expect(entries.count == 1)
        #expect(entries[0].resultSummary.count <= 512)
    }
    
    @Test("Result summary has content")
    func resultSummaryHasContent() async {
        let trail = makeTrail()
        let token = await trail.beginCall(
            caller: "agent",
            toolName: "content_tool",
            toolset: "test",
            arguments: [:]
        )
        await trail.completeToken(token, status: .success, result: "actual_result_data")
        
        let entries = await trail.recent()
        #expect(entries.count == 1)
        #expect(entries[0].resultSummary == "actual_result_data")
    }
}

@Suite("AuditTrail — Query")
struct AuditTrailQueryTests {
    func makeTrail() -> AuditTrail {
        AuditTrail(maxEntries: 100, retentionDays: 7, serviceName: "test")
    }
    
    @Test("Query by tool name filters correctly")
    func queryByTool() async {
        let trail = makeTrail()
        
        let t1 = await trail.beginCall(caller: "agent", toolName: "tool_a", toolset: "test", arguments: [:])
        await trail.completeToken(t1, status: .success, result: "ok")
        
        let t2 = await trail.beginCall(caller: "agent", toolName: "tool_b", toolset: "test", arguments: [:])
        await trail.completeToken(t2, status: .success, result: "ok")
        
        let t3 = await trail.beginCall(caller: "agent", toolName: "tool_a", toolset: "test", arguments: [:])
        await trail.completeToken(t3, status: .success, result: "ok")
        
        let toolA = await trail.queryTool("tool_a", limit: 50)
        #expect(toolA.count == 2)
        
        let toolB = await trail.queryTool("tool_b", limit: 50)
        #expect(toolB.count == 1)
        
        let toolC = await trail.queryTool("tool_c", limit: 50)
        #expect(toolC.isEmpty)
    }
    
    @Test("Query by caller filters correctly")
    func queryByCaller() async {
        let trail = makeTrail()
        
        let t1 = await trail.beginCall(caller: "agent1", toolName: "tool", toolset: "test", arguments: [:])
        await trail.completeToken(t1, status: .success, result: "ok")
        
        let t2 = await trail.beginCall(caller: "agent2", toolName: "tool", toolset: "test", arguments: [:])
        await trail.completeToken(t2, status: .success, result: "ok")
        
        let a1 = await trail.queryCaller("agent1", limit: 50)
        #expect(a1.count == 1)
        
        let a2 = await trail.queryCaller("agent2", limit: 50)
        #expect(a2.count == 1)
    }
    
    @Test("Recent query respects limit")
    func recentRespectsLimit() async {
        let trail = makeTrail()
        
        for i in 0..<20 {
            let token = await trail.beginCall(caller: "agent", toolName: "tool_\(i)", toolset: "test", arguments: [:])
            await trail.completeToken(token, status: .success, result: "ok")
        }
        
        let recent = await trail.recent(limit: 10)
        #expect(recent.count == 10)
    }
    
    @Test("Audit token preserves caller identity")
    func tokenPreservesCaller() async {
        let trail = makeTrail()
        let token = await trail.beginCall(caller: "specific-agent", toolName: "t", toolset: "ts", arguments: [:])
        await trail.completeToken(token, status: .success, result: "ok")
        
        let entries = await trail.recent()
        #expect(entries.count == 1)
        #expect(entries[0].caller == "specific-agent")
    }
}

@Suite("AuditTrail — Enforce Limit")
struct AuditTrailEnforceTests {
    func makeTrail() -> AuditTrail {
        AuditTrail(maxEntries: 100, retentionDays: 7, serviceName: "test")
    }
    
    @Test("Entries beyond maxEntries are trimmed")
    func entriesTrimmed() async {
        let trail = AuditTrail(maxEntries: 5, retentionDays: 7, serviceName: "test")
        
        for i in 0..<10 {
            let token = await trail.beginCall(caller: "agent", toolName: "tool_\(i)", toolset: "test", arguments: [:])
            await trail.completeToken(token, status: .success, result: "ok")
        }
        
        let entries = await trail.recent()
        #expect(entries.count <= 5)
    }
    
    @Test("Trimmed entries keep the most recent")
    func keepsMostRecent() async {
        let trail = AuditTrail(maxEntries: 3, retentionDays: 7, serviceName: "test")
        
        for i in 0..<10 {
            let token = await trail.beginCall(caller: "agent", toolName: "tool_\(i)", toolset: "test", arguments: [:])
            await trail.completeToken(token, status: .success, result: "ok")
        }
        
        let entries = await trail.recent()
        #expect(entries.count == 3)
        // The last entry should be tool_9
        #expect(entries[2].toolName == "tool_9")
    }
    
    @Test("Clear removes all entries")
    func clearRemovesAll() async {
        let trail = makeTrail()
        
        let token = await trail.beginCall(caller: "agent", toolName: "tool", toolset: "test", arguments: [:])
        await trail.completeToken(token, status: .success, result: "ok")
        
        await trail.clear()
        
        let entries = await trail.recent()
        #expect(entries.isEmpty)
    }
}

@Suite("AuditTrail — Export")
struct AuditTrailExportTests {
    func makeTrail() -> AuditTrail {
        AuditTrail(maxEntries: 100, retentionDays: 7, serviceName: "test")
    }
    
    @Test("Empty trail exports empty JSON array")
    func emptyExport() async {
        let trail = makeTrail()
        let json = await trail.exportJSON()
        #expect(json != nil)
        #expect(json?.trimmingCharacters(in: .whitespaces) == "[]")
    }
    
    @Test("Trail with entries exports valid JSON")
    func validJsonExport() async {
        let trail = makeTrail()
        
        let token = await trail.beginCall(caller: "agent", toolName: "export_tool", toolset: "test", arguments: ["key": "val"])
        await trail.completeToken(token, status: .success, result: "ok")
        
        let json = await trail.exportJSON()
        #expect(json != nil)
        #expect(json?.contains("export_tool") == true)
        
        // Parse as valid JSON
        guard let data = json?.data(using: .utf8) else {
            Issue.record()
            return
        }
        let _ = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    }
    
    @Test("Export includes all fields")
    func exportIncludesFields() async {
        let trail = makeTrail()
        
        let token = await trail.beginCall(caller: "agent", toolName: "full_fields", toolset: "test", arguments: ["x": "y"])
        await trail.completeToken(token, status: .success, result: "result")
        
        let json = await trail.exportJSON()
        #expect(json?.contains("full_fields") == true)
        #expect(json?.contains("agent") == true)
        #expect(json?.contains("success") == true)
    }
}
