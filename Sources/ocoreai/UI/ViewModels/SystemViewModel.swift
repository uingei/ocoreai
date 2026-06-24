// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// System ViewModel — bridges MCP, Tools, and Audit with SwiftUI

import Foundation
import Observation

@Observable
@MainActor
final class SystemState {
    // MARK: - MCP

    private(set) var mcpEndpoints: [MCPBridge.MCPEndpointSummaryItem] = []
    var showMCPEndpoints: Bool = true

    // MARK: - Tools

    private(set) var toolNames: [String] = []
    var showTools: Bool = true

    // MARK: - Audit

    private(set) var auditEntries: [AuditEntry] = []
    var showAudit: Bool = true

    // MARK: - Reasoning

    var globalComplexityScore: Double = 0

    // MARK: - UI State

    var isLoading: Bool = false
    var errorMessage: String?
    var refreshing: Bool = false

    // MARK: - Engine Access

    private var bridge: MCPBridge? { OcoreaiEngine.shared.activeMCPBridge }
    private var registry: ToolRegistry? { OcoreaiEngine.shared.activeToolRegistry }
    private var trail: AuditTrail? { OcoreaiEngine.shared.activeAuditTrail }
    private var analyzer: ComplexityAnalyzer? { OcoreaiEngine.shared.activeComplexityAnalyzer }

    // MARK: - Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }
        await loadMCPEndpoints()
        await loadTools()
        await loadAudit()
        await loadComplexity()
    }

    func loadMCPEndpoints() async {
        guard let b = bridge else { return }
        mcpEndpoints = await b.listEndpointSummaries()
    }

    func loadTools() async {
        guard let r = registry else { return }
        toolNames = await r.listTools()
    }

    func loadAudit() async {
        guard let t = trail else { return }
        auditEntries = await t.recent(limit: 50)
    }

    func loadComplexity() async {
        guard let a = analyzer else { return }
        globalComplexityScore = await a.globalBaseline()
    }

    func refresh() async {
        refreshing = true
        defer { refreshing = false }
        await load()
    }

    func clearAudit() async {
        guard let t = trail else { return }
        await t.clear()
        await loadAudit()
    }

    func isConnected(for summary: MCPBridge.MCPEndpointSummaryItem) -> Bool {
        summary.status == "connected" || summary.status == "running"
    }
}
