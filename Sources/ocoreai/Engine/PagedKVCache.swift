// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// PagedKVCache.swift — Session-level paged KV cache manager
///
/// 在 BlockPool 之上提供 session 级别的 KV 缓存管理：
/// - 每个 session 持有一个 BlockTable，跟踪该 session 使用了哪些物理 block
/// - `appendTokens` 自动分配新 block 填充 token
/// - `sharePrefix` 支持 prefix sharing（浅拷贝前缀 block，引用计数 +1）
/// - `evictSession` 释放 session 所有 block 引用
/// - 内存压力检测 + 自动 block eviction（替代旧 SSD cold-store 反模式）
///
/// 并发模型：actor 隔离，所有 session 状态在 mailbox 内。
/// BlockPool 的分配/释放操作通过 async 调用委托给 BlockPool actor。

import Foundation
import Logging

// MARK: - 配置

/// PagedKVCache 配置 — 控制 session 行为与内存策略。
public struct PagedKVCacheConfig: Sendable {
	/// 每个 block 容纳的 token 数（与 BlockPool 一致）
	public var tokensPerBlock: Int

	/// 最大并发 session 数
	public var maxSessions: Int

	/// Session 空闲超时（秒），超时 session 被自动淘汰
	public var sessionTimeoutSeconds: Int

	/// 内存压力阈值（Bytes），超过此值触发 prefill admission control
	public var memoryPressureBytes: Int

	/// 是否启用 prefix sharing
	public var prefixSharingEnabled: Bool

	/// 默认配置
	public static let `default`: PagedKVCacheConfig = .init()

	/// Compute memory pressure threshold from physical RAM.
	///
	/// On Apple Silicon UMA the entire pool (CPU + GPU + KV cache) is shared,
	/// so reserve ≈45 % for system + model weights and leave the rest for KV
	/// cache before triggering admission control.
	/// Floor  3 GB — even an 8 GB Mac should guard.
	/// Ceiling 64 GB — beyond that the fixed 12 GB was already generous.
	private static func pressureBytes(from physicalBytes: UInt64) -> Int {
		let ratio: Double = 0.45
		let pressure = UInt64(Double(physicalBytes) * ratio)
		return Int(max(3 * 1024 * 1024 * 1024, min(pressure, 64 * 1024 * 1024 * 1024)))
	}

	init(
		tokensPerBlock: Int = 16,
		maxSessions: Int = 256,
		sessionTimeoutSeconds: Int = 300,
		memoryPressureBytes: Int? = nil,
		prefixSharingEnabled: Bool = true,
	) {
		self.tokensPerBlock = tokensPerBlock
		self.maxSessions = maxSessions
		self.sessionTimeoutSeconds = sessionTimeoutSeconds
		self.memoryPressureBytes = memoryPressureBytes
			?? Self.pressureBytes(from: ProcessInfo.processInfo.physicalMemory)
		self.prefixSharingEnabled = prefixSharingEnabled
	}
}

// MARK: - Session 状态

/// Session 级缓存状态快照。
private struct SessionState {
	/// Session 标识
	let sessionId: String

	/// BlockTable 跟踪该 session 使用的所有 block
	var blockTable: BlockTable

	/// 创建时间
	let createdAt: ContinuousClock.Instant

	/// 最后访问时间（LRU 用）
	var lastAccessed: ContinuousClock.Instant

	/// 累计 token 数（自 session 创建以来）
	var totalTokens: Int

	/// 标记为活跃（重置空闲计时器）
	mutating func touch() {
		lastAccessed = .now
	}

	/// 判断 session 是否已空闲超时
	func isIdle(timeout: ContinuousClock.Duration) -> Bool {
		lastAccessed + timeout < .now
	}
}

// MARK: - PagedKVCache Actor

/// Paged KV 缓存 — 替代旧 KVCacheManager 的 session-level SSD cold-store 模式。
///
/// 在 Apple Silicon UMA 架构下，GPU/CPU 共享物理内存，SSD 写入是反模式。
/// 本实现用 block pool 分配 + LRU 淘汰取代 SSD spill，所有数据驻留内存。
actor PagedKVCache {
	// MARK: - 配置与状态

	/// 不可变配置
	private let config: PagedKVCacheConfig

	/// BlockPool actor 引用（物理 block 分配器）
	private let blockPool: BlockPool

	/// 日志器
	private let logger: Logger

	/// Session 状态映射：sessionId → SessionState
	private var sessions: [String: SessionState] = [:]

	/// Session 空闲检测任务
	private var idleCheckTask: Task<Void, Never>?

	// MARK: - 初始化

	/// 初始化 PagedKVCache。
	///
	/// - Parameters:
	///   - poolConfig: BlockPool 配置
	///   - cacheConfig: PagedKVCache 配置
	///   - logger: 日志器
	init(
		poolConfig: BlockPoolConfig,
		cacheConfig: PagedKVCacheConfig = .default,
		logger: Logger = Logger(label: "ocoreai.engine.pagedkvcache"),
	) {
		blockPool = BlockPool(config: poolConfig, logger: logger)
		config = cacheConfig
		self.logger = logger

		precondition(
			config.maxSessions > 0,
			"maxSessions 必须为正数",
		)

		// 后台空闲检查延迟启动（actor init 中不能直接修改 actor-isolated 属性，改用 detached Task）
		_ = Task.detached { [weak self] in
			guard let self else { return }
			await idleCheckLoop()
		}
	}

	// MARK: - Session 管理

	/// 创建新 session 并初始化 BlockTable。
	///
	/// - Parameter sessionId: Session 唯一标识
	/// - Throws: AppError.sessionLimitExceeded 当达到 session 上限时
	func attach(sessionId: String) async throws {
		guard !sessionId.isEmpty else { return }

		// 防止重复创建
		guard sessions[sessionId] == nil else {
			logger.debug("Session \(sessionId) already exists, skipping")
			return
		}

		// session 数量检查
		guard sessions.count < config.maxSessions else {
			logger.warning(
				"Session 上限 \(config.maxSessions) 达到，拒绝创建 \(sessionId)",
			)
			throw AppError.sessionLimitExceeded
		}

		// 内存压力检查 — 高压力时拒绝新 session
		let poolBytes = await blockPool.estimatedBytes
		if poolBytes > config.memoryPressureBytes {
			logger.warning(
				"内存压力: \\(poolBytes / (1024 * 1024))MB > \\(config.memoryPressureBytes / (1024 * 1024))MB, 拒绝新 session",
			)
			// 尝试先淘汰空闲 session
			await evictIdleSessions()
			// Re-check pressure after eviction — if still too high, reject
			let poolBytesAfter = await blockPool.estimatedBytes
			if poolBytesAfter > config.memoryPressureBytes {
				logger.warning(
					"内存压力仍高: \\(poolBytesAfter / (1024 * 1024))MB, 拒绝新 session \\(sessionId)",
				)
				throw AppError.memoryPressure
			}
		}

		let state = SessionState(
			sessionId: sessionId,
			blockTable: BlockTable(sessionId: sessionId),
			createdAt: .now,
			lastAccessed: .now,
			totalTokens: 0,
		)

		sessions[sessionId] = state
		logger.info("PagedKVCache attach \(sessionId), active sessions=\(sessions.count)")
	}

	/// 追加 token 到 session — 自动分配 block 填充。
	///
	/// 分配策略：
	/// 1. 先尝试填充最后一个 block 的剩余空间
	/// 2. 最后一个 block 满了则分配新 block
	/// 3. 如果 token 数超过一个 block 容量，直接预分配多个 block
	///
	/// - Parameters:
	///   - sessionId: Session 标识
	///   - numTokens: 需要存储的 token 数
	/// - Throws: AppError.sessionNotFound 当 session 不存在时
	func appendTokens(sessionId: String, numTokens: Int) async throws {
		guard numTokens > 0 else { return }
		guard !sessionId.isEmpty else { return }

		guard var state = sessions[sessionId] else {
			logger.warning("PagedKVCache appendTokens session \(sessionId) not found")
			throw AppError.sessionNotFound(sessionId)
		}

		// 标记活跃
		state.touch()
		state.totalTokens += numTokens

		var remainingTokens = numTokens
		let capacity = config.tokensPerBlock

		// 尝试填充最后一个 block
		if !state.blockTable.blockIds.isEmpty {
			let lastRemain = state.blockTable.lastBlockRemaining(capacity: capacity)
			let fillLast = min(remainingTokens, lastRemain)
			if fillLast > 0 {
				// 更新最后一个 block 的 token 数
				let lastIndex = state.blockTable.perBlockTokens.count - 1
				state.blockTable.perBlockTokens[lastIndex] += fillLast
				remainingTokens -= fillLast
			}
		}

		// 计算需要的新 block 数
		var newBlocksNeeded = remainingTokens / capacity
		if remainingTokens % capacity > 0 {
			newBlocksNeeded += 1
		}

		// 分配新 block
		for _ in 0 ..< newBlocksNeeded {
			do {
				let blockId = try await blockPool.allocate()
				let tokensInBlock = min(remainingTokens, capacity)
				state.blockTable = state.blockTable.appending(
					blockId: blockId,
					tokenCount: tokensInBlock,
				)
				// 增加 block 引用计数
				_ = await blockPool.addReference(blockId: blockId)
				remainingTokens -= tokensInBlock
			} catch {
				logger.error(
					"PagedKVCache 分配 block 失败: \(error)",
				)
				throw error
			}
		}

		sessions[sessionId] = state
		logger.debug("PagedKVCache append \(numTokens) tokens to \(sessionId), blocks=\(state.blockTable.blocksUsed)")
	}

	/// 标记 session 为活跃（重置空闲计时器）。
	///
	/// 每次请求到达时调用。
	///
	/// - Parameter sessionId: Session 标识
	func markActive(sessionId: String) {
		guard var state = sessions[sessionId] else { return }
		state.touch()
		sessions[sessionId] = state
	}

	/// 销毁 session 并释放所有 block 引用。
	///
	/// 引用计数减 1：被 prefix sharing 引用的 block 不会立即释放。
	///
	/// - Parameter sessionId: Session 标识
	func evictSession(sessionId: String) async {
		guard let state = sessions.removeValue(forKey: sessionId) else { return }

		// 同步释放该 session 所有 block 引用（不再 spawn detached Task）
		for blockId in state.blockTable.blockIds {
			await blockPool.deallocate(blockId: blockId)
		}

		logger.info("PagedKVCache evict \(sessionId), totalSessions=\(sessions.count)")
	}

	// MARK: - Prefix Sharing

	/// 从源 session 共享前缀 block 到新 session（prefix caching）。
	///
	/// 浅拷贝前 N 个 block 的引用，引用计数 +1。
	/// 新 session 的 BlockTable 共享这些 block 但不共享后续的增量 block。
	///
	/// - Parameters:
	///   - sessionId: 新 session 标识（需已 attach）
	///   - sourceSessionId: 源 session 标识
	///   - numBlocks: 要共享的 block 数
	/// - Throws: AppError.sessionNotFound 当任一 session 不存在时
	func sharePrefix(
		sessionId: String,
		sourceSessionId: String,
		numBlocks: Int,
	) async throws {
		guard config.prefixSharingEnabled else {
			logger.warning("Prefix sharing disabled")
			return
		}

		guard let sourceState = sessions[sourceSessionId] else {
			throw AppError.sessionNotFound(sourceSessionId)
		}

		guard var targetState = sessions[sessionId] else {
			throw AppError.sessionNotFound(sessionId)
		}

		let blocksToShare = min(numBlocks, sourceState.blockTable.blockIds.count)
		guard blocksToShare > 0 else { return }

		// 复制前缀 block 引用并增加引用计数
		var sharedIds: [Int] = []
		var sharedTokens: [Int] = []

		for i in 0 ..< blocksToShare {
			let blockId = sourceState.blockTable.blockIds[i]
			let tokensInBlock = sourceState.blockTable.perBlockTokens[i]

			sharedIds.append(blockId)
			sharedTokens.append(tokensInBlock)

			// 增加引用计数 — block 现在被两个 session 引用
			_ = await blockPool.addReference(blockId: blockId)
		}

		// 替换目标 session 的 block table 前缀
		var newTable = BlockTable(sessionId: sessionId)
		for (i, id) in sharedIds.enumerated() {
			newTable = newTable.appending(blockId: id, tokenCount: sharedTokens[i])
		}
		targetState.blockTable = newTable
		targetState.touch()

		sessions[sessionId] = targetState
		logger.info("PagedKVCache prefix share \(sourceSessionId) -> \(sessionId), blocks=\(blocksToShare)")
	}

	// MARK: - 后台循环

	/// 定期空闲检测 — 清除超时空闲 session。
	private func idleCheckLoop() async {
		while true {
			do {
				try await Task.sleep(for: .seconds(60))
				await evictIdleSessions()
			} catch is CancellationError {
				break
			} catch {
				logger.error("Idle check error: \(error)")
			}
		}
	}

	/// 淘汰所有空闲超过超时时间的 session。
	private func evictIdleSessions() async {
		let timeout: ContinuousClock.Duration = .seconds(config.sessionTimeoutSeconds)
		let idleSessions = sessions.values.filter { $0.isIdle(timeout: timeout) }

		guard !idleSessions.isEmpty else { return }

		logger.info("PagedKVCache idle check: found \(idleSessions.count) idle sessions")

		for session in idleSessions {
			await evictSession(sessionId: session.sessionId)
		}
	}

	// MARK: - 状态查询

	/// 当前活跃 session 数。
	var activeSessions: Int {
		sessions.count
	}

	/// 查询指定 session 的状态。
	///
	/// - Parameter sessionId: Session 标识
	/// - Returns: Session 状态快照（如存在）
	func sessionInfo(sessionId: String) -> SessionInfo? {
		guard let state = sessions[sessionId] else { return nil }
		return SessionInfo(
			sessionId: state.sessionId,
			blocksUsed: state.blockTable.blocksUsed,
			totalTokens: state.totalTokens,
			lastAccessed: state.lastAccessed,
			createdAt: state.createdAt,
		)
	}

	/// 获取所有 session 的信息。
	func allSessionInfo() -> [SessionInfo] {
		sessions.values.map {
			SessionInfo(
				sessionId: $0.sessionId,
				blocksUsed: $0.blockTable.blocksUsed,
				totalTokens: $0.totalTokens,
				lastAccessed: $0.lastAccessed,
				createdAt: $0.createdAt,
			)
		}
	}

	/// 获取内部 BlockPool 统计信息。
	func poolStats() async -> BlockPoolStats {
		await blockPool.stats()
	}

	/// 获取内存使用估算（字节）。
	///
	/// Deprecated: uses a hardcoded formula (16 tokens/block, 4096 hidden size)
	/// which is inaccurate for models with different hidden dimensions.
	/// Call ``getMemoryBytes()`` instead — it delegates to ``BlockPool/estimatedBytes``
	/// which uses ``BlockPoolConfig/hiddenSize`` for per-model accurate accounting.
	var estimatedMemoryBytes: Int {
		sessions.values.reduce(0) { $0 + $1.blockTable.blocksUsed * 16 * 2 * 4096 * 2 }
	}

	/// Async accessor for memory bytes — delegates to ``BlockPool/estimatedBytes``
	/// which uses accurate per-block accounting based on ``BlockPoolConfig/hiddenSize``.
	///
	/// Fixes: estimatedMemoryBytes hardcoded 4096 hiddenSize → actual BlockPool tracking.
	/// BlockPool tracks `refCount > 0` blocks and their real `estimatedBytes` computed at
	/// allocation time using `config.hiddenSize`, not a session-level guess.
	func getMemoryBytes() async -> Int {
		await blockPool.estimatedBytes
	}

	/// 优雅关闭（取消后台任务）。
	func shutdown() async {
		idleCheckTask?.cancel()
		logger.info("PagedKVCache closed")
	}
}

// MARK: - Session 信息

/// Session 状态只读快照。
public struct SessionInfo: Sendable {
	/// Session 标识
	public let sessionId: String

	/// 使用的 block 数
	public let blocksUsed: Int

	/// 总 token 数
	public let totalTokens: Int

	/// 最后访问时间
	public let lastAccessed: ContinuousClock.Instant

	/// 创建时间
	public let createdAt: ContinuousClock.Instant

	/// 人类可读摘要
	public var summary: String {
		"Session: \(sessionId), blocks=\(blocksUsed), tokens=\(totalTokens)"
	}
}
