// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// PlanCard — `update_plan` 任务态面板（Recover 片 1 的 UI 消费面，UI/UX 铁律）
///
/// 第一性：plan 事件过去纯内存（生产 publish→nil 静默丢弃）**且无持久化、无面板**——
/// 模型调了 `update_plan`，用户看不到任务在推进什么。本面板消费 `PlanTaskStore.current`
/// （attach SQLite 后跨重启可恢复），在 ChatView 输入区上方常显任务轨迹：
/// 步骤列表（pending / in_progress / completed 三态）+ 可选 explanation。
///
/// - 无快照 = 不渲染（调用侧 `current == nil` 门控，零 chrome 噪声）。
/// - 三态图标：pending = 空心圆 · in_progress = 旋转环 · completed = 勾（SF Symbols）。
/// - 语言：标题走 `StringKey.planCardTitle.l`（zh/en）。
import SwiftUI

struct PlanCard: View {
    let snapshot: PlanSnapshot

    private var allDone: Bool {
        !(snapshot.items.isEmpty || snapshot.items.contains { $0.status != "completed" })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if allDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "list.clipboard")
                        .foregroundStyle(.tint)
                }
                Text(StringKey.planCardTitle.l)
                    .font(.footnote.weight(.semibold))
                Spacer()
                if let explanation = snapshot.explanation, !explanation.isEmpty {
                    Text(explanation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(snapshot.items.enumerated()), id: \.offset) { _, item in
                    stepRow(item)
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    @ViewBuilder
    private func stepRow(_ item: PlanSnapshot.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            statusIcon(item.status)
            Text(item.step)
                .font(.caption)
                .foregroundStyle(
                    item.status == "completed" || item.status == "in_progress"
                        ? .primary : .secondary)
            Text(item.status)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: String) -> some View {
        switch status {
        case "completed":
            Image(systemName: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        case "in_progress":
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.tint)
        default:
            Image(systemName: "circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

#Preview("推进中") {
    PlanCard(
        snapshot: PlanSnapshot(
            items: [
                .init(step: "Sync reference repos", status: "completed"),
                .init(step: "Audit codex baseline", status: "in_progress"),
                .init(step: "Implement Recover slice", status: "pending"),
            ],
            explanation: "Recover ring closure",
            updatedAt: 0,
        )
    )
    .frame(maxWidth: 400)
    .padding()
}
