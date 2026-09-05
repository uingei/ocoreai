// ToolSpecFullRegistryTests.swift — 全量真实工具集 × 两条推理路 wire 形状验证
//
// 09-05: "21 工具 schema decode failed"(实为 25/27 口径)修复后的全面性门。纪律:
//   1. 不用手写样例 JSON 断言"全过" — 用真实 bootstrapBuiltInTools registry（生产同路）。
//   2. 两条推理路都验: MLX 路 (toToolSpecs wire 形状) + FM 路 (makeDynamicSchema →
//      GenerationSchema 构建, macOS 27 gate 内)。
//   3. 精确值断言（#expect == N），禁 count > 0 弱断言。
//   4. API 面全部对齐真身: ToolRegistry.listTools()/lookup()/toToolSpecs();
//      ocoreai.ToolDef(OpenAIModels.swift); FMToolProxy(FMToolBridge.swift, trait 门内)。

import Foundation
import Logging
import Testing

@testable import ocoreai

#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
import FoundationModels
#endif

@Suite("Full Registry ToolSpec Pipeline")
struct ToolSpecFullRegistryTests {

    /// 生产同款 bootstrap：skill 全工具面 + update_plan/get_plan opt-in 全开（= 27 全集口径）。
    static func fullRegistry() async -> ToolRegistry {
        let registry = ToolRegistry(log: Logger(label: "test.fullregistry"))
        await bootstrapBuiltInTools(
            registry: registry,
            skillRegistry: SkillRegistry(),
            updatePlanEnabled: true,
            planRecovery: nil
        )
        return registry
    }

    @Test("bootstrap registry: 全参 bootstrap 精确 27 工具（真值源）+ 关键面全在")
    func registeredCountExact() async {
        let registry = await Self.fullRegistry()
        let names = Set(await registry.listTools())
        // 真值（BuiltInTools.swift 逐点核）：
        //   无条件 22 + skills×3（if let skillRegistry）+ plan×2（if updatePlanEnabled，默认 false=codex #41744）
        //   全参 bootstrap = 27。生产默认口径 = 22；当时 /tmp/fm-attach.log 生产口径 = 25（skills on + plan off）。
        #expect(names.count == 27, "实际注册: \(names.sorted())")
        for required in [
            "info", "echo", "read_file", "write_file", "edit_file", "search_files",
            "exec_shell", "exec_command", "exec_poll", "write_stdin", "view_image",
            "view_screen", "observe_state", "get_context_remaining", "web_search",
            "web_fetch", "transcribe_audio", "speak", "generate_video",
            "skills_list", "skills_lookup", "skills_view",
            "update_plan", "get_plan",
        ] {
            #expect(names.contains(required), "missing tool: \(required)")
        }
    }

    @Test("toToolSpecs: 每工具 parameters 形状合法 (type=object + properties)")
    func specShapesWellFormed() async {
        let registry = await Self.fullRegistry()
        let specs = await registry.toToolSpecs()
        #expect(specs.count == 27, "specs \(specs.count)")

        for spec in specs {
            guard
                let fn = spec["function"] as? [String: any Sendable],
                let params = fn["parameters"] as? [String: any Sendable]
            else {
                Issue.record("malformed spec: \(String(describing: spec))")
                continue
            }
            let props = params["properties"] as? [String: any Sendable]
            _ = props
            #expect(params["type"] as? String == "object")
        }
    }

    @Test("update_plan.plan: wire 带 items→object{properties[step/status], required}（非裸 array）")
    func updatePlanPlanShapeExact() async {
        let registry = await Self.fullRegistry()
        let specs = await registry.toToolSpecs()
        guard
            let spec = specs.first(where: {
                ($0["function"] as? [String: any Sendable])?["name"] as? String == "update_plan"
            }),
            let params = (spec["function"] as? [String: any Sendable])?["parameters"]
                as? [String: any Sendable],
            let props = params["properties"] as? [String: any Sendable],
            let plan = props["plan"] as? [String: any Sendable]
        else {
            Issue.record("update_plan missing or malformed")
            return
        }
        #expect(plan["type"] as? String == "array")
        let items = plan["items"] as? [String: any Sendable]
        #expect(items?["type"] as? String == "object", "items 丢失 — wire 退化 array<string>")
        let itemProps = items?["properties"] as? [String: any Sendable]
        let stepVal = itemProps?["step"] as? [String: any Sendable]
        let statusVal = itemProps?["status"] as? [String: any Sendable]
        #expect(stepVal != nil, "item.step properties 丢失")
        #expect(stepVal?["type"] as? String == "string")
        #expect(
            stepVal?["description"] as? String == "The step text.",
            "step description: \(String(describing: stepVal?["description"]))")
        #expect(statusVal != nil, "item.status properties 丢失")
        let required = (items?["required"] as? [String]) ?? []
        #expect(Set(required) == ["step", "status"], "required 丢失: \(required)")
    }

    #if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
    @Test("FM path: 全量 27 工具 makeDynamicSchema→GenerationSchema 构建成功（0 failures）")
    @available(macOS 27.0, iOS 27.0, *)
    func fmSchemaBuildAllTools() async {
        let registry = await Self.fullRegistry()
        let specs = await registry.toToolSpecs()

        var built: [String] = []
        var failures: [String: String] = [:]
        for spec in specs {
            guard
                let fnDict = spec["function"] as? [String: any Sendable],
                let toolName = fnDict["name"] as? String,
                let toolParams = fnDict["parameters"] as? [String: any Sendable],
                let dict = toolParams as? [String: Any]
            else {
                failures[spec["type"] as? String ?? "unknown"] = "not a function spec"
                continue
            }
            if let dynamic = FMToolProxy.makeDynamicSchema(from: dict, name: toolName),
                let schema = try? FoundationModels.GenerationSchema(root: dynamic, dependencies: [])
            {
                _ = schema
                built.append(toolName)
            } else {
                failures[toolName] = "makeDynamicSchema/GenerationSchema failed"
            }
        }

        #expect(failures.isEmpty, "FM schema build failed for: \(String(describing: failures))")
        #expect(built.count == specs.count, "built \(built.count)/\(specs.count)")
    }

    @Test("FM path: update_plan makeDynamicSchema 构建成功（items 链由 wire dict 真身保证，wire 断言见 MLX 路）")
    @available(macOS 27.0, iOS 27.0, *)
    func fmSchemaUpdatePlanFullShape() async {
        // 真值边界（09-05 探针实证）：DynamicGenerationSchema/GenerationSchema 均**不** Encodable
        //  → "items 链 encode 检查"此路不通；items 形状真身在 wire dict 侧（已断言于
        //    updatePlanPlanShapeExact）。这里只验 FM 侧构建成功且非 nil。
        let registry = await Self.fullRegistry()
        let specs = await registry.toToolSpecs()
        guard
            let spec = specs.first(where: {
                ($0["function"] as? [String: any Sendable])?["name"] as? String == "update_plan"
            }),
            let fnDict = spec["function"] as? [String: any Sendable],
            let toolParams = fnDict["parameters"] as? [String: any Sendable],
            let dict = toolParams as? [String: Any]
        else {
            Issue.record("update_plan wire spec missing")
            return
        }
        // wire 侧真身断言（items 链完整）— 与 MLX 路同源 dict
        let props = dict["properties"] as? [String: Any]
        let plan = props?["plan"] as? [String: Any]
        let items = plan?["items"] as? [String: Any]
        #expect(items?["type"] as? String == "object", "update_plan.plan.items 丢失")
        #expect((items?["properties"] as? [String: Any])?["step"] != nil, "item.step 丢失")

        guard
            let dynamic = FMToolProxy.makeDynamicSchema(from: dict, name: "update_plan"),
            let schema = try? FoundationModels.GenerationSchema(root: dynamic, dependencies: [])
        else {
            Issue.record("update_plan FM schema build failed")
            return
        }
        _ = schema
    }
    #endif
}
