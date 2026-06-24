// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// MCPCallCache — LRU cache for tool call results with configurable TTL.
///
/// 线程安全：Actor 隔离，所有访问经 mailbox。
/// 淘汰策略：LRU（最近最少使用），容量满时淘汰最旧条目。
/// 过期策略：写入时打标时间，读取时检查 TTL，过期即失效。
import Foundation

/// 缓存条目
private struct CacheEntry: Sendable {
    let value: String
    let timestamp: Date
    
    /// 条目是否已过期
    func isExpired(ttl: TimeInterval) -> Bool {
        Date().timeIntervalSince(timestamp) > ttl
    }
}

/// MCP 工具调用结果缓存（LRU + TTL，Actor 隔离）。
actor MCPCallCache {
    /// 最大缓存条目数
    private let maxEntries: Int
    /// 缓存条目存活时间（秒）
    private let ttlSeconds: TimeInterval
    /// 有序条目列表：尾部 = 最近访问，头部 = 最旧
    private var entries: [String: CacheEntry] = [:]
    private var accessOrder: [String] = []
    
    /// 创建缓存实例。
    /// - Parameters:
    ///   - maxEntries: 最大条目数（默认 256）
    ///   - ttlSeconds: 条目过期时间，单位秒（默认 60）
    init(maxEntries: Int = 256, ttlSeconds: TimeInterval = 60) {
        self.maxEntries = maxEntries
        self.ttlSeconds = ttlSeconds
    }
    
    // MARK: - 读写接口
    
    /// 按 key 查询缓存。命中则标记为最近访问（LRU 提升）。
    /// - Returns: 命中的缓存值，未命中或过期则返回 nil。
    func get(_ key: String) -> String? {
        guard let entry = entries[key] else { return nil }
        // 检查过期
        if entry.isExpired(ttl: ttlSeconds) {
            remove(key)
            return nil
        }
        // LRU 提升：移到列表尾部
        moveToEnd(key)
        return entry.value
    }
    
    /// 写入结果到缓存。若 key 已存在则更新值并提升 LRU 位置。
    /// 若缓存已满则淘汰最旧条目。
    func set(_ key: String, value: String) {
        // 若已存在，先删除旧记录
        if entries[key] != nil {
            remove(key)
        }
        
        // 容量检查：淘汰最旧条目
        while entries.count >= maxEntries {
            if let oldest = accessOrder.first {
                remove(oldest)
            }
        }
        
        // 插入新条目
        entries[key] = CacheEntry(value: value, timestamp: Date())
        accessOrder.append(key)
    }
    
    /// 清除过期条目。返回清理数量。
    @discardableResult
    func purgeExpired() -> Int {
        let now = Date()
        var removed = 0
        let expiredKeys = accessOrder.filter { key in
            guard let entry = entries[key] else { return false }
            return now.timeIntervalSince(entry.timestamp) > ttlSeconds
        }
        for key in expiredKeys {
            remove(key)
            removed += 1
        }
        return removed
    }
    
    /// 清空缓存
    func clear() {
        entries.removeAll()
        accessOrder.removeAll()
    }
    
    // MARK: - 状态查询
    
    /// 当前缓存条目数
    func count() -> Int {
        entries.count
    }
    
    /// 返回缓存状态摘要（Sendable 兼容）
    func status() -> [String: String] {
        [
            "entries": String(entries.count),
            "maxEntries": String(maxEntries),
            "ttlSeconds": String(ttlSeconds),
            "fillRatio": String(Double(entries.count) / Double(maxEntries))
        ]
    }
    
    // MARK: - 内部管理
    
    /// 从缓存中移除条目（LRU 内部使用）
    private func remove(_ key: String) {
        entries.removeValue(forKey: key)
        accessOrder.removeAll { $0 == key }
    }
    
    /// 将 key 移到访问顺序列表尾部（标记为最近访问）
    private func moveToEnd(_ key: String) {
        guard let index = accessOrder.firstIndex(of: key) else { return }
        accessOrder.remove(at: index)
        accessOrder.append(key)
    }
}
