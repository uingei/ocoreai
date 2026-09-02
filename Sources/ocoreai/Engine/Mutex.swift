// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Lightweight generic mutex wrapper using NSRecursiveLock.
/// Decoupled from CoreAIEngine so that non-Engine modules (e.g. Multimodal)
/// can use it without pulling in a #if canImport(CoreAI) dependency.

import Foundation

final class Mutex<Value>: @unchecked Sendable {
    // 所有 `_value` 访问都经 NSRecursiveLock 串行化(唯一入口 withLock), 故 @unchecked Sendable 安全。
    private let lock: NSRecursiveLock
    private var _value: Value

    init(_ initialValue: @Sendable @escaping () -> Value) {
        self._value = initialValue()
        self.lock = NSRecursiveLock()
    }

    init(_ initialValue: Value) {
        self._value = initialValue
        self.lock = NSRecursiveLock()
    }

    func withLock<R: Sendable>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&_value)
    }
}
