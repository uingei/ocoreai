// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
//
// Clipboard live — NSPasteboard(UIPasteboard) 真 I/O face 的 round-trip 铁证:
//   write(marker) → read 必须 == marker(证 read/write 真走平台面, 非假回显)。
//
// 剪贴板是全局用户可见态 → 可逆纪律(用户铁律: 整理类操作必须可逆):
//   1. 先读原值备份
//   2. 写 marker 做 round-trip 证明
//   3. **无条件恢复原值**(即使 assert 失败也恢复, #expect 不 throw 会继续走到恢复)
//   4. 环境不可用(headless / TCC 拒写) → Issue.record("skipped") 而非 fail(同
//      StreamingWindowTests 条件跳过范式)。
import Foundation
import Testing

@testable import ocoreai

struct ClipboardLiveTests {

    @Test("write→read round-trip 真平台面 (原值备份后恢复)")
    func roundTripRestoresOriginal() async {
        let original = await ClipboardDriver.readText()
        let marker = "ocoreai_clip_rt_\(UUID().uuidString)"
        let ok = await ClipboardDriver.writeText(marker)
        let back = await ClipboardDriver.readText()
        let _ = await ClipboardDriver.writeText(original ?? "")  // 恢复原值(恒执行)
        if !ok {
            Issue.record("skipped: clipboard write unavailable in this environment (TCC/headless)")
            return
        }
        #expect(
            back == marker, "round-trip: wrote \(marker) but read back \(String(describing: back))")
    }

    @Test("read 真平台面: 不崩 + 报告格式合法(有内容或明确空态)")
    func readReportShape() async {
        let r = Clipboard.readReport(await ClipboardDriver.readText(), maxLen: 100)
        #expect(r.hasPrefix("clipboard(") || r == "clipboard: (empty)", "got: \(r.prefix(40))")
    }
}
