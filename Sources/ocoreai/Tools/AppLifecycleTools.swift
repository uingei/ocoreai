// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// App lifecycle tools — 「自主操作计算机」的应用级动作面。
///
/// 第一性: 桌面控制 6 原语(move_mouse/click/…/key_press)全部作用于「当前前台 app」。
/// 但「让目标 app 成为前台」这个前置步骤此前只有一条间接路(shell `open`), 不是工具面:
/// 无审批语义、无 bundle id 精确寻址、无「已运行→只 activate 不重复拉起」的幂等语义、
/// 出错时模型拿不到诚实原因(找不到/已运行/权限)。
///
/// 三个一等工具:
///   1. open_app  — 已运行 → activate(幂等); 未运行 → NSWorkspace 启动(审批门)。
///   2. activate_app — 仅把给定 app 提到前台(不改启动状态), 幂等。
///   3. list_apps — 已运行 app 清单(名 + bundle id), 给模型以寻址依据(先 list 再 act)。
///
/// Apple 平台深度: NSWorkspace.shared.urlForApplication(withBundleIdentifier:)
/// (10.6+, 非弃用) + openApplication(at:configuration:)(10.15+, 非弃用,
/// launchApplication* 家族已全部弃用) + activate(from:options:)(macOS 14 新签名,
/// 基线索引)。全 Safe API, 无 as!/try!/fatalError。
/// 权限诚实: 找不到 → 明确文案, 不假装成功。
/// macOS 门(NSWorkspace/AppKit = macOS 应用面; iOS 无「多 app 并存前台」语义),
/// 与 desktop control 同 #if os(macOS) 段。
import Foundation

#if os(macOS)
import AppKit
#endif

// MARK: - Pure(离线可测 — 不触 NSWorkspace 运行时状态)

enum AppLifecycle {
    /// app 标识归一: 空白/大小写归一(bundle id 大小写不敏感匹配)。纯, 可测。
    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// app 标识解析顺序(纯语义, 与 Driver 寻址一致):
    /// bundle id(含 `.` 的形态, 如 com.apple.TextEdit)→ 优先按 id 精确寻址;
    /// 其余 → 按名(/Applications 下 `<name>.app`, 大小写不敏感)。
    /// 返回寻址类, 供单测钉语义(禁弱断言)。
    enum AddressKind {
        case bundleID
        case appName
    }

    static func addressKind(_ app: String) -> AddressKind {
        let id = normalize(app)
        return id.contains(".") ? .bundleID : .appName
    }

    /// list_apps 输出钳制: 每行 app 名最长 64 + bundle id 最长 128; 总行数上限 clamp。纯, 可测。
    static func clampList(limit: Int) -> Int {
        min(max(limit, 1), 500)
    }

    /// 行格式化: `name\tbundleID\tactive` — 列分隔可机械解析。纯, 精确可测。
    static func line(name: String, bundle: String, active: Bool) -> String {
        "\(name)\t\(bundle)\t\(active ? "active" : "background")"
    }

    /// list 输出头(给模型的语义锚): 一行元信息。纯, 可测。
    static func header(n: Int, limit: Int, filter: String?) -> String {
        "# apps \(n)\(filter == nil ? "" : " (filter: \(filter!))")/\(limit)"
    }

    /// 展示文本安全化: 压 tab/换行 + 截断(名单里个别 app 名可能带空白)。纯, 可测。
    static func display(_ s: String, max maxLen: Int = 64) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxLen else { return t }
        let idx = t.index(t.startIndex, offsetBy: maxLen)
        return String(t[t.startIndex ..< idx]) + "…"
    }

    /// 子串过滤(小写包含, 名或 bundle id 任一命中)。纯, 可测。
    static func matches(_ name: String, _ bundle: String, _ filter: String?) -> Bool {
        guard let f = filter, !f.isEmpty else { return true }
        let q = f.lowercased()
        return name.lowercased().contains(q) || bundle.lowercased().contains(q)
    }
}

// MARK: - Driver + Client(macOS 门 — NSWorkspace, 全 Safe)

#if os(macOS)

/// completion 结果盒: openApplication(at:) 的回调值经信号量/continuation 回传。
/// 引用型让闭包按引用捕获; resumeOnce 用锁保证 continuation 只 resume 一次
/// (成功/失败/超时三方竞速, 先 resume 者胜, 后到者 no-op → 绝不 double-resume crash)。
private final class OpenBox: @unchecked Sendable {
    var app: NSRunningApplication?
    var error: Error?
    private var resumed = false
    private let lock = NSLock()

    /// 首次调用执行 body 并返回 true; 之后调用返回 false 且不执行。
    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        body()
    }
}

enum AppLifecycleDriver {
    /// 运行中 app 按 id/名归一匹配(语义 = inspect_ui 的 resolvePid, 同一寻址口径)。
    static func findRunning(_ app: String) -> NSRunningApplication? {
        let id = AppLifecycle.normalize(app)
        guard !id.isEmpty else { return nil }
        let apps = NSWorkspace.shared.runningApplications
        if let a = apps.first(where: { $0.bundleIdentifier?.lowercased() == id.lowercased() }) {
            return a
        }
        if let a = apps.first(where: { $0.localizedName?.lowercased() == id.lowercased() }) {
            return a
        }
        return nil
    }

    /// 目标 URL 解析: bundle id → NSWorkspace 官方映射(非弃用); 名 → 三个标准
    /// Applications 根查找 `<name>.app`(大小写不敏感)—— NSWorkspace 无「按名查 URL」
    /// 非弃用 API, 标准根查找是其官方替代面。找不到 → nil(诚实)。
    static func resolveURL(_ app: String) -> URL? {
        switch AppLifecycle.addressKind(app) {
        case .bundleID:
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)
        case .appName:
            let name = AppLifecycle.normalize(app)
            guard !name.isEmpty else { return nil }
            let roots = [
                URL(fileURLWithPath: "/Applications"),
                URL(fileURLWithPath: "/System/Applications"),
                URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Applications"),
            ]
            for root in roots {
                let candidate = root.appendingPathComponent(name + ".app")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
                let alt = root.appendingPathComponent(name.hasSuffix(".app") ? name : name + ".app")
                if alt != candidate, FileManager.default.fileExists(atPath: alt.path) {
                    return alt
                }
            }
            return nil
        }
    }

    /// open_app 主语义: 已运行 → activate(幂等, 不重复拉起); 未运行 → 启动并激活。
    /// 返回给模型的诚实结果文本。
    ///
    /// 结构(10-06): MainActor 只做「寻址 + 运行态」快照(瞬时), 焦点落地轮询与
    /// 启动完成都在 main-actor 外用协作式 async — 旧版在 MainActor.run 里
    /// semaphore.wait(30s) 阻塞主线程, 是窗口卡顿的潜在源。
    static func openApp(_ app: String) async -> String {
        struct OpenTarget: Sendable {
            let id: String
            let running: NSRunningApplication?
            let url: URL?
        }
        let snapshot: OpenTarget? = await MainActor.run {
            let id = AppLifecycle.normalize(app)
            guard !id.isEmpty else { return nil }
            let running = findRunning(id)
            return OpenTarget(id: id, running: running, url: running == nil ? resolveURL(id) : nil)
        }
        guard let snapshot else {
            return "app_open_failed — empty app target."
        }
        if let running = snapshot.running {
            // 已运行 → 异步收敛窗内实证前台(幂等, 不重复拉起)。
            let (ok, reason) = await activateRunningAndSettle(running)
            return ok
                ? "app=\(snapshot.id) already running (pid \(running.processIdentifier)) → activated."
                : "app=\(snapshot.id) running but activate failed (pid \(running.processIdentifier); \(reason))."
        }
        guard let url = snapshot.url else {
            return "app_open_failed — '\(snapshot.id)' not found: no running app and no .app in "
                + "/Applications, /System/Applications, ~/Applications."
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            // openApplication 的 completion 可能不来(极端挂起) — 30s 兜底诚实报超时。
            let box = OpenBox()
            Task { @MainActor in
                // cfg 在 MainActor 区内构造(region isolation: 不跨区送可变引用)
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, error in
                    box.app = app
                    box.error = error
                    box.resumeOnce {
                        if let app {
                            cont.resume(
                                returning:
                                    "app=\(snapshot.id) launched (pid \(app.processIdentifier)), activated."
                            )
                        } else {
                            cont.resume(
                                returning:
                                    "app_open_failed — '\(snapshot.id)' at \(url.lastPathComponent): "
                                    + "\(error?.localizedDescription ?? "no running app returned")"
                            )
                        }
                    }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                box.resumeOnce {
                    cont.resume(
                        returning: "app_open_failed — '\(snapshot.id)': launch timed out after 30s"
                    )
                }
            }
        }
    }

    /// activate_app 主语义: 仅把运行中 app 提到前台; 未运行 → 诚实报「未运行, 用 open_app」。
    /// MainActor 只做寻址快照; 落地实证走 settle 窗(异步, 不占主线程)。
    static func activateApp(_ app: String) async -> String {
        let running: NSRunningApplication? = await MainActor.run {
            findRunning(AppLifecycle.normalize(app))
        }
        guard let running else {
            return
                "app_activate_failed — '\(app)' not running. Use open_app to launch it first."
        }
        let (ok, reason) = await activateRunningAndSettle(running)
        return ok
            ? "app=\(running.localizedName ?? app) (pid \(running.processIdentifier)) → frontmost."
            : "app_activate_failed — '\(app)' (pid \(running.processIdentifier)): \(reason)."
    }

    /// 列表清单(只读): 仅 regular 策略(用户可见 app), 名+bundle id+前台标记, 过滤 + 钳制。
    static func listApps(limit: Int, filter: String?) async -> String {
        await MainActor.run {
            let cap = AppLifecycle.clampList(limit: limit)
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            var rows: [String] = []
            for a in NSWorkspace.shared.runningApplications
                .sorted(by: {
                    ($0.localizedName ?? "\u{10FFFF}") < ($1.localizedName ?? "\u{10FFFF}")
                })
            {
                guard a.activationPolicy == .regular else { continue }
                let name = a.localizedName ?? "unknown"
                let bundle = a.bundleIdentifier ?? "(none)"
                guard AppLifecycle.matches(name, bundle, filter) else { continue }
                rows.append(
                    AppLifecycle.line(
                        name: AppLifecycle.display(name),
                        bundle: AppLifecycle.display(bundle),
                        active: a.processIdentifier == frontmost))
                if rows.count >= cap { break }
            }
            return
                (AppLifecycle.header(n: rows.count, limit: cap, filter: filter)
                + "\n" + rows.joined(separator: "\n"))
        }
    }

    /// activate(from:options:) 的 macOS 14 签名(新 API, 非弃用); 返回是否生效。
    /// 焦点落地 — Apple 文档语义: `activate(options:)` 的 Bool 是「请求是否被受理」,
    /// **不是**「已在前台」; 前台变更是异步的, canonical 真值 = 轮询
    /// `NSWorkspace.shared.frontmostApplication`(或 didBecomeActive 通知)。
    ///
    /// 活体证据(10-06 全量门, stash 基线复现): hermes 前台活跃时首窗
    /// `activate` 调用返回 true 但前台不落地, 或返回 false 且确实未落地 —
    /// 单次调用 + 立即读返回值当终局 = 谎报。真实恢复模式 = 收敛窗口内
    /// 轮询 + 中段重申一次(WindowServer focus-stealing 抑制对二次请求宽容);
    /// prohibited 策略 app 结构性无法成为前台 → 诚实报因, 不烧窗口。
    ///
    /// 协作式 async(不占 main thread): `NSRunningApplication.activate` 是 IPC,
    /// `frontmostApplication` 轮询与 AppLifecycleLiveTests 同范式(main-actor 外)。
    ///
    /// - Returns: (settled, reason) — settled=前台已实证; reason 永远诚实。
    static func activateRunningAndSettle(
        _ running: NSRunningApplication,
        pollIntervalNs: UInt64 = 50_000_000,
        maxPolls: Int = 40
    ) async -> (settled: Bool, reason: String) {
        if running.activationPolicy == .prohibited {
            return (false, "activationPolicy=prohibited — app cannot become frontmost")
        }
        _ = running.activate(from: NSRunningApplication.current, options: .activateAllWindows)
        for tick in 0 ..< maxPolls {
            try? await Task.sleep(nanoseconds: pollIntervalNs)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == running.processIdentifier
            {
                return (true, "frontmost")
            }
            if tick == maxPolls / 2 {
                _ = running.activate(
                    from: NSRunningApplication.current, options: .activateAllWindows)
            }
        }
        let nowFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        return (false, "never became frontmost (frontmost=\(nowFront))")
    }
}

enum OpenAppClient {
    static let toolName = "open_app"
    struct Args: Codable, Sendable { let app: String }

    static func toolEntry() -> ToolEntry {
        ToolEntry.typed(
            name: toolName,
            toolset: "computer",
            argsType: Args.self,
            description:
                "Open a macOS app by bundle id (e.g. com.apple.TextEdit) or app name "
                + "(e.g. TextEdit, resolved against /Applications). Idempotent: if it is "
                + "already running, it is only activated (brought frontmost) — never "
                + "launched twice. Use it BEFORE any mouse/keyboard action that must "
                + "target a specific app. Returns the honest outcome: launched pid, "
                + "already-running pid, or a precise failure reason.",
            schema: ToolSchema(parameters: [
                "app": ToolParameter(
                    type: .string,
                    description: "Bundle id like com.apple.Safari, or app name like 'Safari'")
            ]),
            isDestructive: true
        ) { args in
            await AppLifecycleDriver.openApp(args.app)
        }
    }
}

enum ActivateAppClient {
    static let toolName = "activate_app"
    struct Args: Codable, Sendable { let app: String }

    static func toolEntry() -> ToolEntry {
        ToolEntry.typed(
            name: toolName,
            toolset: "computer",
            argsType: Args.self,
            description:
                "Bring a running macOS app to the front (activate it) without launching "
                + "anything new. If the app is not running, it reports that honestly — use "
                + "open_app to launch first. Use between inspect_ui / mouse / keyboard actions "
                + "to guarantee the target app has keyboard focus before typing or clicking.",
            schema: ToolSchema(parameters: [
                "app": ToolParameter(
                    type: .string,
                    description: "Bundle id or app name of a running app")
            ]),
            isDestructive: true
        ) { args in
            await AppLifecycleDriver.activateApp(args.app)
        }
    }
}

enum ListAppsClient {
    static let toolName = "list_apps"
    struct Args: Codable, Sendable {
        let limit: Int?
        let filter: String?
    }

    static func toolEntry() -> ToolEntry {
        ToolEntry.typed(
            name: toolName,
            toolset: "computer",
            argsType: Args.self,
            description:
                "List running macOS apps (user-visible ones only): name, bundle id, and which "
                + "one is frontmost. Read-only. Use it to DISCOVER the exact bundle id / name to "
                + "pass to open_app / activate_app / inspect_ui. Optional substring filter and "
                + "row limit (capped at 500).",
            schema: ToolSchema(
                parameters: [
                    "filter": ToolParameter(
                        type: .string,
                        description: "Case-insensitive substring to match name or bundle id"),
                    "limit": ToolParameter(
                        type: .integer, description: "Max rows (default 100, cap 500)"),
                ], required: []),
            isDestructive: false
        ) { args in
            await AppLifecycleDriver.listApps(limit: args.limit ?? 100, filter: args.filter)
        }
    }
}

#endif
