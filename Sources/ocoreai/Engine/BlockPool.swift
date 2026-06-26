// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// BlockPool.swift — Paged KV Cache 核心（vLLM 风格 block pool 架构）
///
/// 设计目标：
/// - 用固定大小的 KV block 替代 session 级别的整块分配
/// - 每个 session 持有 BlockTable（block ID 列表），支持 append/trim/prefix sharing
/// - BlockPool actor 统一管理物理 block 的分配/释放/LRU 淘汰
/// - 所有共享状态通过 actor 隔离保证 Sendable
///
/// 与传统方案对比：
/// | 旧方案 | 新方案 |
/// |--------|--------|
/// | session 级别分配 | block 级别分配（16 tokens/block）|
/// | 空闲→SSD cold-store | 物理 block 回收 + 内存压力自动淘汰 |
/// | 无 prefix sharing | BlockTable 共享前缀 block（引用计数）|
///
/// 注意：此文件无 trait 编译门 — BlockPool 本身是 trait-agnostic 的内存管理组件。
/// CoreAI trait 下的 KVCacheManager 会委托给 PagedKVCache → BlockPool。

import Atomics
import Foundation
import Logging

// MARK: - 配置

/// BlockPool 配置 — 所有字段 immutable，通过值传递。
public struct BlockPoolConfig: Sendable {
	/// 每个 block 容纳的 token 数（默认 16，与 vLLM 一致）
	public var tokensPerBlock: Int

	/// 物理 block 池最大容量
	public var maxBlocks: Int

	/// 内存水位线（0.0-1.0），超过此值触发 LRU 淘汰
	public var evictionWatermark: Double

	/// 内存压力阈值（0.0-1.0），低于此值停止淘汰
	public var evictionThrottle: Double

	/// 模型 hidden size — 用于估算单 block 内存占用
	/// 默认 4096（Llama-3-8B 级别）；实际值在 EnginePool 接入时注入
	public var hiddenSize: Int

	/// 默认配置：适合 Apple Silicon UMA 的 16GB GPU 预算
	public static let `default`: BlockPoolConfig = .init()

	init(
		tokensPerBlock: Int = 16,
		maxBlocks: Int = 65536,
		evictionWatermark: Double = 0.85,
		evictionThrottle: Double = 0.60,
		hiddenSize: Int = 4096,
	) {
		self.tokensPerBlock = tokensPerBlock
		self.maxBlocks = maxBlocks
		self.evictionWatermark = evictionWatermark
		self.evictionThrottle = evictionThrottle
		self.hiddenSize = hiddenSize
	}
}

// MARK: - KV Block

/// 物理 KV block — 固定大小的缓存单元。
///
/// 每个 block 存储 ``tokensPerBlock`` 个 token 的 KV 向量（K + V）。
/// 物理 block 由 ``BlockPool`` 分配，逻辑使用通过 ``BlockTable`` 管理。
///
/// - Note: block 本身不持有 kv 数据指针 — 数据由后端的 CoreAI/MLX NDArray 管理。
///   此结构只负责元数据追踪（引用计数、访问时间、内存估算）。
public struct KVBlock: Sendable {
	public static func == (lhs: KVBlock, rhs: KVBlock) -> Bool {
		lhs.blockId == rhs.blockId
	}

	public func hash(into h: inout Hasher) {
		h.combine(blockId)
	}

	/// 物理 block 全局唯一 ID（自增整数）
	public let blockId: Int

	/// 引用计数 — 多少个 BlockTable 共享此 block
	///
	/// 用 ManagedAtomic 保证跨 actor 边界的原子操作
	/// （BlockTable 可能在 actor 外部构造/传递）。
	public var refCount: Int

	/// 块内已填充的 token 数（0 ~ tokensPerBlock）
	public var tokensUsed: Int

	/// 最后一次访问时间（LRU 淘汰用）
	public var lastAccessTime: ContinuousClock.Instant

	/// 估算内存占用（字节）— 分配时由 BlockPool 计算
	public let estimatedBytes: Int

	/// 创建时间
	public let createdTime: ContinuousClock.Instant

	/// 初始化一个空的物理 block。
	///
	/// - Parameters:
	///   - blockId: 全局唯一 ID
	///   - estimatedBytes: 估算内存占用
	init(blockId: Int, estimatedBytes: Int) {
		self.blockId = blockId
		refCount = 0 // 0: 刚分配，尚未被任何 BlockTable 引用；调用方负责 addReference
		tokensUsed = 0
		self.estimatedBytes = estimatedBytes
		lastAccessTime = .now
		createdTime = .now
	}

	// MARK: - 状态变更（在 BlockPool actor 内调用）

	/// 标记 block 被访问（更新 LRU 时间戳）。
	mutating func touch() {
		lastAccessTime = .now
	}

	/// 增加 token 使用量（用于跟踪 block 内填充度）。
	///
	/// - Parameters:
	///   - count: 新增加的 token 数
	///   - capacity: 单 block 容量上限（来自 BlockPoolConfig.tokensPerBlock）
	mutating func addTokens(_ count: Int, capacity: Int) {
		tokensUsed = min(tokensUsed + count, capacity)
		touch()
	}

	/// 判断是否已满（达到 tokensPerBlock 上限）。
	///
	/// - Parameter capacity: 单 block 容量
	func isFull(capacity: Int) -> Bool {
		tokensUsed >= capacity
	}

	/// 当前剩余可容纳 token 数。
	///
	/// - Parameter capacity: 单 block 容量
	func remainingCapacity(capacity: Int) -> Int {
		max(0, capacity - tokensUsed)
	}
}

// MARK: - BlockTable（Per-Request）

/// Per-request 的 block 引用列表 — 等价于 vLLM 的 BlockTable。
///
/// 每个推理 session 拥有一个 BlockTable，记录该 session 使用了哪些物理 block。
/// 支持 append（新 token 超出当前 block 容量时分配新 block）、
/// trim（投机解码回退时释放尾部 block）、以及 prefix sharing（浅拷贝前缀）。
///
/// BlockTable 本身是 Sendable 值类型，不持有可变共享状态。
/// 所有分配/释放操作通过 ``BlockPool`` actor 执行。
public struct BlockTable: Sendable {
	/// Session 或 request 的唯一标识
	public let sessionId: String

	/// 逻辑 block ID 列表（从 pool 分配的 block id）
	public var blockIds: [Int]

	/// 每个 block 内实际使用到的 token 数
	/// 最后一个 block 可能不满；其余 block 必须满。
	public var perBlockTokens: [Int]

	/// 总 token 数（懒计算，由调用方维护以保证 O(1) 查询）
	public var totalTokens: Int

	/// 创建时间
	public let createdAt: ContinuousClock.Instant

	/// 创建空的 block table。
	///
	/// - Parameter sessionId: session 标识符
	public init(sessionId: String) {
		self.sessionId = sessionId
		blockIds = []
		perBlockTokens = []
		totalTokens = 0
		createdAt = .now
	}

	// MARK: - 查询

	/// 当前 block 数。
	public var blocksUsed: Int {
		blockIds.count
	}

	/// 最后一个 block 是否已满。
	///
	/// - Parameter capacity: 单 block 容量（来自 BlockPoolConfig）
	public func lastBlockFull(capacity: Int) -> Bool {
		guard let last = perBlockTokens.last else { return false }
		return last >= capacity
	}

	/// 最后一个 block 的剩余容量。
	///
	/// - Parameter capacity: 单 block 容量
	public func lastBlockRemaining(capacity: Int) -> Int {
		guard let last = perBlockTokens.last else { return 0 }
		return max(0, capacity - last)
	}

	/// 最后一个 block 的 ID（nil 表示 table 为空）。
	public var lastBlockId: Int? {
		blockIds.last
	}

	// MARK: - 不可变变换

	/// 追加一个已分配的 block（由 BlockPool 调用）。
	///
	/// - Parameters:
	///   - blockId: 新分配的物理 block ID
	///   - tokenCount: 该 block 内实际存放的 token 数
	/// - Returns: 新的 BlockTable（不可变更新）
	func appending(blockId: Int, tokenCount: Int) -> BlockTable {
		var copy = self
		copy.blockIds.append(blockId)
		copy.perBlockTokens.append(tokenCount)
		copy.totalTokens += tokenCount
		return copy
	}

	/// 裁剪尾部 N 个 block（投机解码回退等场景）。
	///
	/// - Parameter count: 要移除的尾部 block 数
	/// - Returns: 裁剪后的 BlockTable
	func trimmingTrailingBlocks(_ count: Int) -> BlockTable {
		var copy = self
		let removeCount = min(count, copy.blockIds.count)
		copy.blockIds.removeLast(removeCount)
		copy.perBlockTokens.removeLast(removeCount)
		// 重新计算总 token 数
		copy.totalTokens = copy.perBlockTokens.reduce(0, +)
		return copy
	}

	/// 保留前 N 个 block（前缀截断）。
	///
	/// - Parameter prefixBlocks: 要保留的 block 数
	/// - Returns: 只含前缀 block 的 BlockTable
	func keepingPrefix(upTo: Int) -> BlockTable {
		var copy = self
		let keep = min(upTo, copy.blockIds.count)
		copy.blockIds.removeLast(copy.blockIds.count - keep)
		copy.perBlockTokens.removeLast(copy.perBlockTokens.count - keep)
		copy.totalTokens = copy.perBlockTokens.reduce(0, +)
		return copy
	}

	/// 检查前缀是否与新给定的 prefix table 完全匹配。
	///
	/// - Parameter prefix: 待比较的前缀 BlockTable
	/// - Returns: true 表示当前 table 以 prefix 开头
	public func hasPrefix(_ prefix: BlockTable) -> Bool {
		guard prefix.blockIds.count <= blockIds.count else { return false }
		for (i, id) in prefix.blockIds.enumerated() {
			guard blockIds[i] == id else { return false }
		}
		return true
	}
}

// MARK: - BlockPool Actor

/// 物理 block 池管理器 — 分配/释放/回收所有 ``KVBlock`` 实例。
///
/// 职责：
/// - 通过 ``allocate()`` / ``deallocate(blockId:)`` 管理 block 生命周期
/// - 维护 LRU 队列用于内存压力下的自动淘汰
/// - 跟踪总内存占用、利用率统计
/// - 引用计数管理：block 被多个 BlockTable 共享时（prefix sharing），
///   只有 refCount 归零时才真正回收
///
/// 并发模型：actor 隔离所有可变状态，对外只暴露 async API。
actor BlockPool {
	// MARK: - 配置与状态

	/// 不可变配置引用
	private let config: BlockPoolConfig

	/// 日志器
	private let logger: Logger

	/// 下一个可用的 block ID（自增）
	private var nextBlockId: Int = 1

	/// 已分配 block 映射：blockId → KVBlock
	private var blocks: [Int: KVBlock] = [:]

	/// LRU 队列（最近最少使用 → 最近使用），用于快速定位淘汰候选
	/// 使用双端链表语义：移除旧节点 + 插入尾端 = 标记为最近使用
	/// 简化实现：数组按 LRU 排序，head 最老，tail 最新
	private var lruQueue: [Int] = []

	/// Set 追踪 lruQueue 成员，O(1) 判断 + 删除
	private var lruSet: Set<Int> = []

	/// 空闲 block 回收站 — 分配前先复用空闲块，避免系统 malloc
	private var freeBlockIds: [Int] = []

	/// 当前活跃的 block 数（refCount > 0）
	private var activeBlockCount: Int = 0

	/// 当前总内存占用（字节，仅计算 refCount > 0 的块）
	private var totalBytesUsed: Int = 0

	/// 累计分配次数（用于统计）
	private var totalAllocations: Int = 0

	/// 累计回收次数（用于统计）
	private var totalReclaims: Int = 0

	/// 累计淘汰次数（水位线触发）
	private var totalEvictions: Int = 0

	// MARK: - 初始化

	/// 初始化 BlockPool。
	///
	/// - Parameters:
	///   - config: 池配置
	///   - logger: 日志器
	init(
		config: BlockPoolConfig = .default,
		logger: Logger = Logger(label: "ocoreai.engine.blockpool"),
	) {
		self.config = config
		self.logger = logger
		precondition(config.tokensPerBlock > 0, "tokensPerBlock 必须为正数")
		precondition(config.maxBlocks > 0, "maxBlocks 必须为正数")
		precondition(
			config.evictionWatermark > config.evictionThrottle,
			"evictionWatermark 必须大于 evictionThrottle",
		)
		precondition(
			config.evictionWatermark <= 1.0 && config.evictionThrottle >= 0.0,
			"水位线必须在 [0, 1] 范围内",
		)
	}

	// MARK: - 分配 / 释放

	/// 分配一个物理 block。
	///
	/// 分配流程：
	/// 1. 如果 freeBlockIds 中有空闲 ID，复用之；否则自增 nextBlockId
	/// 2. 检查池容量限制（maxBlocks）
	/// 3. 创建 KVBlock，加入 LRU 队列
	///
	/// - Throws: ``AppError.blockPoolExhausted`` 当池容量耗尽且无法淘汰时
	/// - Returns: 新分配的 block ID
	@discardableResult
	func allocate() async throws -> Int {
		// 尝试从回收站取空闲 ID
		let blockId: Int
		if let recycled = freeBlockIds.popLast() {
			blockId = recycled
		} else {
			blockId = nextBlockId
			nextBlockId += 1
		}

		// 检查是否超过池容量
		if activeBlockCount >= config.maxBlocks {
			// 尝试淘汰最老的 block
			let reclaimed = await evictIfNeeded()
			guard reclaimed > 0 else {
				logger.error("BlockPool 耗尽：已分配 \\(activeBlockCount) 块，上限 \\(config.maxBlocks)")
				throw AppError.blockPoolExhausted
			}
		}

		// 估算单 block 内存占用（以 FP16 估算，实际由后端决定）
		let estimatedBytes = estimateBlockSize()

		// 创建 block 实例
		let block = KVBlock(blockId: blockId, estimatedBytes: estimatedBytes)

		blocks[blockId] = block
		lruQueue.append(blockId)
		lruSet.insert(blockId)
		activeBlockCount += 1
		totalBytesUsed += estimatedBytes
		totalAllocations += 1

		logger.debug(
			"BlockPool 分配 block #\\(blockId), 活跃块=\\(activeBlockCount), 内存=\\(totalBytesUsed / (1024*1024))MB",
		)

		return blockId
	}

	/// 释放一个 block 的引用。
	///
	/// 如果 refCount 归零，block 进入回收站等待复用。
	///
	/// - Parameter blockId: 要释放的 block ID
	/// - Returns: true 表示 block 被彻底回收（refCount 归零）
	@discardableResult
	func deallocate(blockId: Int) async -> Bool {
		guard var block = blocks[blockId] else {
			logger.warning("BlockPool 尝试释放不存在的 block #\\(blockId)，忽略")
			return false
		}

		let count = block.refCount
		guard count > 0 else {
			logger.warning("BlockPool block #\(blockId) refCount already 0, skip duplicate deallocate")
			return false
		}

		// 递减引用计数
		block.refCount -= 1
		let newCount = block.refCount

		if newCount == 0 {
			// 无人引用，彻底回收
			blocks.removeValue(forKey: blockId)
			freeBlockIds.append(blockId)
			activeBlockCount -= 1
			totalBytesUsed -= block.estimatedBytes
			// O(1) LRU 清理：通过 Set 判断成员后再移除
			if lruSet.remove(blockId) != nil {
				// 找到并移除 — 需要线性扫描一次（仅在 block 退出时发生，摊销成本低）
				if let idx = lruQueue.firstIndex(of: blockId) {
					lruQueue.remove(at: idx)
				}
			}
			totalReclaims += 1

			logger.debug("BlockPool 回收 block #\\(blockId), 活跃块=\\(activeBlockCount)")
			return true
		} else {
			// 还有引用，保留 block 但标记为访问过
			block.touch()
			blocks[blockId] = block
			logger.debug("BlockPool block #\\(blockId) 引用 \\(count) → \\(newCount)")
			return false
		}
	}

	/// 增加指定 block 的引用计数（prefix sharing 时调用）。
	///
	/// - Parameter blockId: 要增加引用的 block ID
	/// - Returns: true 表示操作成功
	func addReference(blockId: Int) async -> Bool {
		guard var block = blocks[blockId] else {
			return false
		}
		block.refCount += 1
		block.touch()
		blocks[blockId] = block
		let newCount = block.refCount
		logger.debug("BlockPool block #\(blockId) 引用 +1 → \(newCount)")
		return true
	}

	// MARK: - LRU 淘汰

	/// 检查内存水位线，如果超出水位线则执行淘汰。
	///
	/// - Returns: 成功回收的 block 数
	private func evictIfNeeded() async -> Int {
		let usage = usageFraction()
		guard usage > config.evictionWatermark else {
			return 0
		}

		logger.warning(
			"BlockPool 水位线触发：当前 \\(Int(usage * 100))% > 阈值 \\(Int(config.evictionWatermark * 100))%",
		)

		return await performEviction()
	}

	/// 执行 LRU 淘汰 — 从最老的 block 开始释放，直到水位线回到 throttled 以下。
	///
	/// 淘汰策略：
	/// - 按 LRU 队列从 head（最老）到 tail（最新）的顺序扫描
	/// - 只淘汰 refCount == 1 的 block（不被其他 session 共享）
	/// - 跳过 refCount > 1 的 block（共享前缀）
	/// - 返回水位线以下后停止
	private func performEviction() async -> Int {
		var reclaimed = 0

		var sharedSkips = 0 // 防御：连续跳过共享 block 上限，防止死循环
		let maxSharedSkips = 100

		while let oldestId = lruQueue.first {
			let usage = usageFraction()
			guard usage > config.evictionThrottle else {
				break
			}

			guard let block = blocks[oldestId] else {
				// 已经回收过，跳过
				lruQueue.removeFirst()
				_ = lruSet.remove(oldestId)
				continue
			}

			let refCount = block.refCount

			if refCount <= 1 {
				// 可以安全淘汰
				lruQueue.removeFirst()
				_ = lruSet.remove(oldestId)
				blocks.removeValue(forKey: oldestId)
				freeBlockIds.append(oldestId)
				activeBlockCount -= 1
				totalBytesUsed -= block.estimatedBytes
				totalReclaims += 1
				totalEvictions += 1
				reclaimed += 1

				logger.info(
					"LRU 淘汰 block #\\(oldestId)，当前水位 \\(Int(usageFraction() * 100))%",
				)
			} else {
				// 共享 block，跳过 — 但继续尝试后面的 block
				lruQueue.removeFirst()
				// 将共享 block 重新插入队列尾部（它仍然有效，只是不被淘汰）
				lruQueue.append(oldestId)
				sharedSkips += 1
				if sharedSkips >= maxSharedSkips {
					logger.warning("LRU 淘汰连续跳过 \\(sharedSkips) 个共享 block，终止本轮")
					break
				}
			}
		}

		guard reclaimed > 0 else { return 0 }
		logger.info("BlockPool 本轮淘汰 \\(reclaimed) 个 block，活跃块=\\(activeBlockCount)")
		return reclaimed
	}

	// MARK: - 批量操作

	/// 批量释放一组 block（session 结束时统一释放）。
	///
	/// - Parameter blockIds: 要释放的 block ID 列表
	func deallocate(_ blockIds: [Int]) async {
		for id in blockIds {
			await deallocate(blockId: id)
		}
	}

	// MARK: - 估算

	/// 估算单个 block 的内存占用（字节）。
	///
	/// 公式：tokensPerBlock × 2(K+V) × hiddenSize × sizeof(Float16)
	private func estimateBlockSize() -> Int {
		config.tokensPerBlock * 2 * config.hiddenSize * 2
	}

	// MARK: - 状态查询

	/// 当前已使用 block 数。
	var activeCount: Int {
		activeBlockCount
	}

	/// 当前可用 block 数（maxBlocks - activeBlockCount）。
	var availableCount: Int {
		max(0, config.maxBlocks - activeBlockCount)
	}

	/// 池使用率（0.0-1.0）。
	func usageFraction() -> Double {
		guard config.maxBlocks > 0 else { return 0.0 }
		return Double(activeBlockCount) / Double(config.maxBlocks)
	}

	/// 当前总内存估算（字节）。
	var estimatedBytes: Int {
		totalBytesUsed
	}

	/// 估算内存占用的 GB 值。
	func estimatedGB() -> Double {
		Double(totalBytesUsed) / 1_073_741_824.0
	}

	/// 查询指定 block 的信息。
	///
	/// - Parameter blockId: block ID
	/// - Returns: KVBlock 信息（如存在）
	func blockInfo(blockId: Int) -> KVBlock? {
		blocks[blockId]
	}

	/// 获取池统计信息。
	func stats() -> BlockPoolStats {
		BlockPoolStats(
			activeBlocks: activeBlockCount,
			maxBlocks: config.maxBlocks,
			usageFraction: usageFraction(),
			estimatedBytes: totalBytesUsed,
			lruQueueLength: lruQueue.count,
			freeBlockSlots: freeBlockIds.count,
			totalAllocations: totalAllocations,
			totalReclaims: totalReclaims,
			totalEvictions: totalEvictions,
		)
	}

	/// 预分配 N 个 block（prefill 场景下提前分配可减少碎片）。
	///
	/// - Parameter count: 预分配数量
	/// - Returns: 分配成功的 block ID 列表
	func preallocate(count: Int) async throws -> [Int] {
		var ids: [Int] = []
		for _ in 0 ..< count {
			let id = try await allocate()
			ids.append(id)
		}
		return ids
	}
}

// MARK: - BlockPool 统计信息

/// BlockPool 运行时的统计快照。
public struct BlockPoolStats: Sendable {
	/// 活跃 block 数
	public let activeBlocks: Int
	/// 最大 block 数
	public let maxBlocks: Int
	/// 使用率
	public let usageFraction: Double
	/// 估算内存占用（字节）
	public let estimatedBytes: Int
	/// LRU 队列长度
	public let lruQueueLength: Int
	/// 空闲 slot 数
	public let freeBlockSlots: Int
	/// 累计分配次数
	public let totalAllocations: Int
	/// 累计回收次数
	public let totalReclaims: Int
	/// 累计淘汰次数
	public let totalEvictions: Int

	/// 人类可读的统计摘要
	public var summary: String {
		"BLK:active=\\(activeBlocks)/\\(maxBlocks)(\\(Int(usageFraction * 100))%) " +
			"mem=\\(estimatedBytes / (1024*1024))MB " +
			"lrul=\\(lruQueueLength) free=\\(freeBlockSlots) " +
			"alloc=\\(totalAllocations) reclaim=\\(totalReclaims) evict=\\(totalEvictions)"
	}
}
