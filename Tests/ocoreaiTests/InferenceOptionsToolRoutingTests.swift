// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// InferenceOptionsToolRoutingTests — the native-side tool-routing contract.
///
/// The HTTP wire (ChatHandler) sets `hasNativeTools` / `declaredToolNames`
/// from the request's `tools[]`; live E2E 09-08 proved that contract closes
/// the tool loop (emit → dispatch → result → continuation) while the
/// one-shot FM guided path does NOT (EngineInference L2251 observation:
/// "tool executes… but no continuation"). The native Fast Path (desktop UI)
/// must therefore mirror the exact same contract — `InferenceOptions.
/// toolRouting` is that single source. These tests pin it so a future edit
/// cannot silently re-diverge the two paths (the divergence that left the
/// desktop UI without a working tool loop).
import Testing

@testable import ocoreai

@Suite("InferenceOptions.toolRouting — native/HTTP contract parity")
struct InferenceOptionsToolRoutingTests {

    @Test("nil tools → no native routing, nil whitelist (behavior-identical passthrough)")
    func nilTools() {
        let r = InferenceOptions.toolRouting(from: nil)
        #expect(r.hasNativeTools == false)
        #expect(r.declaredToolNames == nil)
    }

    @Test("empty tools → no native routing (empty surface = no tools declared)")
    func emptyTools() {
        let r = InferenceOptions.toolRouting(from: [])
        #expect(r.hasNativeTools == false)
        #expect(r.declaredToolNames == nil)
    }

    @Test("declared tools → hasNativeTools true + whitelist in declaration order")
    func declaredTools() {
        let defs = [
            ToolDef(
                type: "function",
                function: FunctionDef(name: "write_file", description: nil, parameters: nil)),
            ToolDef(
                type: "function",
                function: FunctionDef(name: "exec_command", description: nil, parameters: nil)),
        ]
        let r = InferenceOptions.toolRouting(from: defs)
        #expect(r.hasNativeTools == true)
        #expect(r.declaredToolNames == ["write_file", "exec_command"])
    }

    @Test("full registry surface (UI default) → routing on, whitelist = all declared names")
    func fullSurface() {
        let names = ["info", "read_file", "write_file", "exec_command", "web_search"]
        let defs = names.map { n in
            ToolDef(
                type: "function", function: FunctionDef(name: n, description: nil, parameters: nil))
        }
        let r = InferenceOptions.toolRouting(from: defs)
        #expect(r.hasNativeTools == true)
        #expect(r.declaredToolNames == names)
    }
}
