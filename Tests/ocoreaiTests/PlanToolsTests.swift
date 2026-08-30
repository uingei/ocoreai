// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// `update_plan` 工具 — 精确值测试(全离线, fake publisher, 无 I/O).
///
/// 覆盖三个 seam:
///   1. `PlanUpdate.validate` 纯核对 — 参数化遍历:
///      空 plan / 缺 step 文本 / 状态越界 / 多 in_progress / 合法组合(含单 in_progress);
///      拒绝报告逐条精确锚定(codex 错误语义: parse/enum 越界 = 可读拒绝, 不静默).
///   2. `UpdatePlanClient.toolEntry` — 工具面(codex `plan_spec.rs` 对齐):
///      name=`update_plan` / toolset=`plan` / 参数 `explanation`(string, optional) +
///      `plan`(array, items=object, required=[step,status]) / 成功输出固定文案
///      `Plan updated`(codex `PLAN_UPDATED_MESSAGE`) / 事件经 injection publisher 交付
///      (对齐 codex `send_event(EventMsg::PlanUpdate(args))`).
///   3. `ToolEntry.toToolDef` 序列化 — `plan.items` JSON Schema 形状精确断言.
///
/// 基准: codex `codex-rs/core/src/tools/handlers/plan_spec.rs` + `plan.rs`
/// (0.160.0 HEAD, #41630 默认启用; 工具名 / 参数名 / 状态枚举 / 输出文案 = 原值).

import Foundation
import Testing

@testable import ocoreai

// MARK: - 1. validate 纯核对(参数化遍历)

@Suite("PlanUpdate.validate — rejection matrix")
struct PlanValidateRejectionTests {

    @Test
    func nilPlan() {
        let r = PlanUpdate.validate(explanation: "x", plan: nil)
        #expect(
            r.failureMessage
                == "update_plan: error: 'plan' must be a non-empty array of {step, status}")
    }

    @Test
    func emptyArray() {
        let r = PlanUpdate.validate(explanation: nil, plan: [])
        #expect(
            r.failureMessage
                == "update_plan: error: 'plan' must be a non-empty array of {step, status}")
    }

    @Test(arguments: [
        ((step: nil, status: "pending"), "plan[0].step must be a non-empty string"),
        ((step: "", status: "pending"), "plan[0].step must be a non-empty string"),
        ((step: "   ", status: "pending"), "plan[0].step must be a non-empty string"),
    ])
    func missingStep(stepAndStatus: (step: String?, status: String?), expected: String) {
        let r = PlanUpdate.validate(explanation: nil, plan: [stepAndStatus])
        #expect(r.failureMessage == "update_plan: error: \(expected)")
    }

    @Test(arguments: [
        (
            "running",
            "plan[0].status must be one of pending | in_progress | completed (got \"running\")"
        ),
        (
            "PENDING",
            "plan[0].status must be one of pending | in_progress | completed (got \"PENDING\")"
        ),
        (nil, "plan[0].status must be one of pending | in_progress | completed (got \"missing\")"),
    ])
    func badStatus(status: String?, expected: String) {
        let r = PlanUpdate.validate(explanation: nil, plan: [(step: "s", status: status)])
        #expect(r.failureMessage == "update_plan: error: \(expected)")
    }

    @Test(arguments: [
        (2, "update_plan: error: at most one step may be in_progress (got 2)"),
        (3, "update_plan: error: at most one step may be in_progress (got 3)"),
    ])
    func multiInProgress(inProgressCount: Int, expected: String) {
        let plan: [(step: String?, status: String?)] =
            (0 ..< inProgressCount).map { ("s\($0)", "in_progress") }
        let r = PlanUpdate.validate(explanation: nil, plan: plan)
        #expect(r.failureMessage == expected)
    }
}

extension Result where Failure == PlanUpdateError {
    /// 拒绝消息摊平(成功 = nil), 测试断言走单一入口。
    var failureMessage: String? {
        switch self {
        case .failure(let e): return e.message
        case .success: return nil
        }
    }
}

// MARK: - 2. validate 成功面(逐状态矩阵)

@Suite("PlanUpdate.validate — success matrix")
struct PlanValidateSuccessTests {

    @Test(arguments: ["pending", "in_progress", "completed"])
    func singleStepStatuses(status: String) {
        let r = PlanUpdate.validate(explanation: "e", plan: [(step: "do it", status: status)])
        guard case .success(let v) = r else {
            Issue.record("expected success for status \(status), got \(r.failureMessage ?? "?")")
            return
        }
        #expect(v.explanation == "e")
        #expect(v.steps.map(\.step) == ["do it"])
        #expect(v.steps.map(\.status) == [status])
    }

    @Test
    func legalProgression() {
        // codex 常见节奏: completed → in_progress ×1 → pending…
        let plan: [(step: String?, status: String?)] = [
            ("scaffold", "completed"),
            ("wire runtime", "in_progress"),
            ("tests", "pending"),
        ]
        let r = PlanUpdate.validate(explanation: "plan 1/3", plan: plan)
        guard case .success(let v) = r else {
            Issue.record("expected success, got \(r.failureMessage ?? "?")")
            return
        }
        #expect(v.explanation == "plan 1/3")
        #expect(
            v.steps == [
                .init(step: "scaffold", status: "completed"),
                .init(step: "wire runtime", status: "in_progress"),
                .init(step: "tests", status: "pending"),
            ])
    }
}

// MARK: - 3. Tool 面 — codex 对齐(codex `plan_spec.rs` 原值)

@Suite("update_plan tool face — codex parity")
struct UpdatePlanToolFaceTests {

    @Test
    func exactNameAndToolset() {
        let e = UpdatePlanClient.toolEntry(publisher: PlanStateRecorder())
        #expect(e.name == "update_plan")
        #expect(e.toolset == "plan")
    }

    @Test
    func parameterSurface() {
        let e = UpdatePlanClient.toolEntry(publisher: PlanStateRecorder())
        // codex `required: vec!["plan"]` → ocoreai 工具 schema 同时声明 explanation
        // (codex spec 中 optional, ocoreai 以「description 含 Optional」表达 optional 语义,
        // required 面与 codex Rust 侧一致 = 仅 `plan` 在元素级 required 列表内)。
        let keys = Set(e.schema.parameters.keys)
        #expect(keys == Set(["explanation", "plan"]))
        #expect(e.schema.parameters["explanation"]?.type == .string)
        let plan = e.schema.parameters["plan"]
        #expect(plan?.type == .array)
        #expect(plan?.items?.type == .object)
        #expect(plan?.items?.required == ["step", "status"])
    }

    @Test
    func toolDefJSONPlanItemsShape() throws {
        // JSON Schema 形状(codex plan_spec.rs): plan = array, items = object(step/status required).
        let e = UpdatePlanClient.toolEntry(publisher: PlanStateRecorder())
        let def = e.toToolDef()
        let data = try JSONEncoder().encode(def)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let function = try #require(json?["function"] as? [String: Any])
        let params = try #require(function["parameters"] as? [String: Any])
        let properties = try #require(params["properties"] as? [String: Any])
        let plan = try #require(properties["plan"] as? [String: Any])
        #expect(plan["type"] as? String == "array")
        let items = try #require(plan["items"] as? [String: Any])
        #expect(items["type"] as? String == "object")
        #expect(items["required"] as? [String] == ["step", "status"])
        // explanation 存在且为 string(codex: optional, 在 properties 面内)
        let explanation = properties["explanation"] as? [String: Any]
        #expect(explanation?["type"] as? String == "string")
    }

    @Test
    @MainActor
    func successfulCallEmitsPlanUpdatedAndPublishesEvents() async {
        let rec = PlanStateRecorder()
        let e = UpdatePlanClient.toolEntry(publisher: rec)
        let args =
            #"{"explanation":"kicking off","plan":[{"step":"a","status":"pending"},{"step":"b","status":"in_progress"}]}"#
        let out = try? await e.handler(args)
        #expect(out == "Plan updated")
        #expect(rec.events.count == 1)
        #expect(rec.events.first?.explanation == "kicking off")
        #expect(
            rec.events.first?.steps == [
                .init(step: "a", status: "pending"),
                .init(step: "b", status: "in_progress"),
            ])
    }

    @Test
    @MainActor
    func invalidCallReturnsCodexReadbleError() async {
        let e = UpdatePlanClient.toolEntry(publisher: PlanStateRecorder())
        let bad = #"{"plan":[{"step":"a","status":"running"}]}"#
        let out = try? await e.handler(bad)
        #expect(
            out
                == "update_plan: error: plan[0].status must be one of pending | in_progress | completed (got \"running\")"
        )
        // 非法调用不得发事件(codex: 解析失败即 RespondToModel, 不发 PlanUpdate 事件)
        // — 用 fresh recorder 验证:
        let rec = PlanStateRecorder()
        let e2 = UpdatePlanClient.toolEntry(publisher: rec)
        _ = try? await e2.handler(bad)
        #expect(rec.events.count == 0)
    }

    @Test
    @MainActor
    func missingPlanReturnsExactError() async {
        let e = UpdatePlanClient.toolEntry(publisher: PlanStateRecorder())
        let out = try? await e.handler(#"{"explanation":"no plan given"}"#)
        #expect(out == "update_plan: error: 'plan' must be a non-empty array of {step, status}")
    }
}
