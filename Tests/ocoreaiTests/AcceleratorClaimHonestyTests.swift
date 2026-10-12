// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// AcceleratorClaimHonestyTests — UI 徽章不得声称一个从未发生过的设备切换。
///
/// 实机背景：`ComputeChannel.cpu` 这一档只关掉前缀缓存复用与投机解码，Metal 设备在
/// `ModelContainer` 装载时就绑定、运行期从不切换；此前它把徽章文案写成 "CPU"，
/// 等于告诉用户「这条回答来自另一块芯片」。本文件钉住徽章文案的事实边界。

import Testing

@testable import ocoreai

@Suite("Accelerator claims match reality", .serialized)
struct AcceleratorClaimHonestyTests {

    @Test("degraded lane never claims a CPU")
    func guardLaneIsNotADevice() {
        #expect(ComputeChannel.cpu.badgeLabel == "Guard")
        #expect(!ComputeChannel.cpu.badgeLabel.contains("CPU"))
    }

    @Test("the two real lanes keep their names")
    func realLanesKeepNames() {
        #expect(ComputeChannel.gpu.badgeLabel == "GPU")
        #expect(ComputeChannel.ane.badgeLabel == "ANE")
    }

    @Test("guard badge uses a warning mark, not a cpu glyph")
    func guardIconIsNotDeviceGlyph() {
        #expect(ComputeChannel.cpu.badgeIcon != "cpu")
        #expect(ComputeChannel.cpu.badgeIcon == "exclamationmark.triangle.fill")
    }

    @Test("every channel still renders a non-empty label and icon")
    func noEmptyBadgeSurface() {
        for channel in ComputeChannel.allCases {
            #expect(!channel.badgeLabel.isEmpty)
            #expect(!channel.badgeIcon.isEmpty)
        }
    }
}
