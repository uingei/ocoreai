// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelStore.swift — 就绪模型目录(ready-model directory)单一事实源
///
/// M7: omlx 对齐的"就绪模型目录"层——所有 hub 下载与本地模型的统一登记簿。
/// omlx 对应物: `~/.omlx/models`(`settings.py:44` DEFAULT_BASE_PATH;
/// `settings.py:232` get_model_dirs;`admin/routes.py:297` HF 直接落盘 model_dir)。
///
/// 布局(全部在 root 下,omlx `~/.omlx/models` 同构):
/// ```
/// <root>/huggingface/models--<ns>--<name>/   HubCache 原生布局(blobs/ + snapshots/<rev>/…) —
///                                             swift-huggingface 库形态硬约束(HubCache 仅
///                                             .environment / .cacheDirectory 两 init,
///                                             .build/checkouts/swift-huggingface HubCache.swift:85,93),
///                                             断点续传 ✓、与 Python huggingface 家缓存互通 ✓
/// <root>/<ns>/<name>/                         ModelScope 平铺 — omlx 对齐(无 /{revision} 三级,
///                                             对齐 omlx/admin/ms_downloader.py: "Preserve {owner}/{model}
///                                             layout to match other tools (LMStudio, huggingface-cli)")
/// <root>/local/<name>/                        用户自行放置的模型
/// ```
///
/// 根目录:`$OCOREAI_MODELS_DIR` > `~/.ocoreai/models`(平台无关;omlx `~/.omlx/models`
/// 对齐,settings.py:209 "[] means ~/.omlx/models")。
/// 旧散落位置(仅发现/清理,不搬移、不写入):旧默认根(Application Support / .local/share)、
/// 旧 `modelscope/<ns>/<name>/<rev>/` 三级、HF 家缓存 `~/.cache/huggingface/hub`、
/// `Caches/org.ml-explore.mlx-swift-lm`、`Caches/ocoreai/modelscope`。
///
/// 铁律:本文件是"哪个目录算就绪模型"的唯一事实源——下载侧(MS/HF)、加载侧(isModelCached)、
/// UI 侧(列表/删除)都从本文件取路径,禁止各自拼 Caches 路径。

import Foundation
import HuggingFace

enum ModelStore {

    // MARK: - 目录命名(与下游布局严格一致)

    /// HF HubCache 仓库目录前缀(`HubCache.swift:115`:`<kind>--<ns>--<name>`,kind=model)。
    static let hubRepoPrefix = "models--"

    static let hubSubRoot = "huggingface"
    static let msSubRoot = "modelscope"
    static let localSubRoot = "local"

    // MARK: - 根目录

    /// 就绪模型统一根(omlx `~/.omlx/models` 对齐,settings.py:209):
    /// `$OCOREAI_MODELS_DIR` > `~/.ocoreai/models`(平台无关)。
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["OCOREAI_MODELS_DIR"],
            !override.isEmpty
        {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ocoreai")
            .appendingPathComponent("models")
    }

    /// 旧默认根(遗留,只发现/清理不写入):
    /// macOS `~/Library/Application Support/ocoreai/models`;其它 `~/.local/share/ocoreai/models`。
    static var legacyRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return
            home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("ocoreai")
            .appendingPathComponent("models")
        #else
        return
            home
            .appendingPathComponent(".local")
            .appendingPathComponent("share")
            .appendingPathComponent("ocoreai")
            .appendingPathComponent("models")
        #endif
    }

    /// HF hub 根(root/huggingface)——`HubCache(cacheDirectory:)` 的入参。
    static var hubRoot: URL { root.appendingPathComponent(hubSubRoot) }

    /// 就绪目录锚定的 `HubClient`(认证走 `.environment`,与旧宏路径一致;
    /// 缓存固定到 `hubRoot`)。
    static func readyHubClient() -> HuggingFace.HubClient {
        ensureLayout()
        return HuggingFace.HubClient(cache: HuggingFace.HubCache(cacheDirectory: hubRoot))
    }

    /// ModelScope 根(root/modelscope)。
    static var msRoot: URL { root.appendingPathComponent(msSubRoot) }

    /// 用户自放模型根(root/local)。
    static var localRoot: URL { root.appendingPathComponent(localSubRoot) }

    // MARK: - ModelScope 布局(omlx 对齐)

    /// MS 就绪仓库目录(规范写入位,omlx 平铺):`root/<ns>/<name>/` —
    /// 无 /{revision} 三级;omlx/admin/ms_downloader.py:885
    /// `target_dir = self._model_dir / task.repo_id`,注释 "Preserve {owner}/{model}
    /// layout to match other tools (LMStudio, huggingface-cli)"。
    static func msRepoDir(_ repoId: String) -> URL {
        var dir = root
        for part in repoId.split(separator: "/") where !part.isEmpty {
            dir = dir.appendingPathComponent(String(part))
        }
        return dir
    }

    /// MS 遗留三级布局基(只发现/清理,不写入):`.../<base-modelscope>/<ns>/<name>/<rev>/`。
    /// = 旧默认根/modelscope、旧规范根/modelscope(54f92b7 时代)、旧 Caches ocoreai/modelscope。
    static func msBases() -> [URL] {
        var bases: [URL] = [
            legacyRoot.appendingPathComponent(msSubRoot),
            root.appendingPathComponent(msSubRoot),
        ]
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            bases.append(caches.appendingPathComponent("ocoreai/modelscope"))
        }
        return bases
    }

    // MARK: - 遗留落位(只发现/清理,不搬移、不写入)

    /// HF 侧遗留基目录:旧默认根 + 家缓存(`.cache/huggingface/hub`)+ Caches 平铺
    /// (`org.ml-explore.mlx-swift-lm`)。统一供 resolve/discover/remove 使用。
    static func legacyHFBases() -> [URL] {
        var bases: [URL] = [legacyRoot]
        let home = FileManager.default.homeDirectoryForCurrentUser
        bases.append(
            home
                .appendingPathComponent(".cache")
                .appendingPathComponent("huggingface")
                .appendingPathComponent("hub"))
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            bases.append(caches.appendingPathComponent("org.ml-explore.mlx-swift-lm"))
        }
        return bases
    }

    /// 确保所需子目录存在(幂等)。
    @discardableResult
    static func ensureLayout() -> URL {
        let fm = FileManager.default
        for dir in [root, hubRoot, msRoot, localRoot] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return root
    }

    // MARK: - 仓库名编码(HubCache 兼容:`/` ↔ `--`)

    /// `"org/name"` → `"models--org--name"`(第一处 `/` → 第一个 `--`)。
    static func encodeHubRepo(_ repoId: String) -> String {
        var out = hubRepoPrefix
        let parts = repoId.components(separatedBy: "/")
        for (i, p) in parts.enumerated() {
            if i > 0 { out.append("--") }
            out.append(p)
        }
        return out
    }

    /// `"models--org--name"` → `("org","name")`(在第一处 `--` 切分;name 内可含 `--`)。
    /// 非 `models--` 前缀返回 nil。
    static func decodeHubRepo(_ dirName: String) -> (namespace: String, name: String)? {
        guard dirName.hasPrefix(hubRepoPrefix) else { return nil }
        let raw = String(dirName.dropFirst(hubRepoPrefix.count))
        guard let dash = raw.firstRange(of: "--") else { return nil }
        let namespace = String(raw[..<dash.lowerBound])
        let name = String(raw[dash.upperBound...])
        guard !namespace.isEmpty, !name.isEmpty else { return nil }
        return (namespace, name)
    }

    // MARK: - 就绪判定与目录解析

    /// 目录内存在非空 `.safetensors`(与 MLXBridge.hasValidSafetensors 同判据,
    /// 抽到事实源层共享)。
    static func hasValidSafetensors(in dir: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path),
            let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey])
        else { return false }
        for item in files where item.pathExtension == "safetensors" {
            let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 0 { return true }
        }
        return false
    }

    /// HF 仓库就绪目录 — 按序解析,返回第一个含非空 safetensors 的候选:
    /// 1) 新根 `root/huggingface/models--<ns>--<name>/snapshots/<rev>/`(HubCache 形态,写入锚点)
    /// 2) 旧默认根同形态(历史 `Application Support/ocoreai/models/huggingface/…`)
    /// 3) HF 家缓存 `~/.cache/huggingface/hub/…`(Python 客户端共享)
    /// 4) Caches 平铺 `org.ml-explore.mlx-swift-lm/<repoId>/`(早期宏默认)
    static func hubReadyDir(_ repoId: String) -> URL? {
        let encoded = encodeHubRepo(repoId)
        for base in [hubRoot, legacyRoot.appendingPathComponent(hubSubRoot)] {
            if let dir = snapshotDir(of: base.appendingPathComponent(encoded)) {
                return dir
            }
        }
        if let dir = snapshotDir(of: legacyHFBases()[1].appendingPathComponent(encoded)) {
            return dir
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let caches {
            let legacyBase = caches.appendingPathComponent("org.ml-explore.mlx-swift-lm")
            for sub in [encoded, repoId] {
                let dir = legacyBase.appendingPathComponent(sub)
                if hasValidSafetensors(in: dir) { return dir }
            }
        }
        return nil
    }

    /// 目录按 HubCache 形态解析:`snapshots/<first-valid-rev>/` 优先,否则平铺目录本身。
    static func snapshotDir(of repoDir: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: repoDir.path) else { return nil }
        let snapshots = repoDir.appendingPathComponent("snapshots")
        if let kids = try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil)
        {
            for kid in kids where hasValidSafetensors(in: kid) { return kid }
        }
        if hasValidSafetensors(in: repoDir) { return repoDir }
        return nil
    }

    /// MS 就绪目录 — ① 规范平铺 `root/<ns>/<name>/`(omlx 对齐)→
    /// ② 遗留三级 `msBases()/<ns>/<name>/<rev>/`(rev 序 master → main → 任意已存)。
    static func msReadyDir(_ repoId: String) -> URL? {
        let fm = FileManager.default
        let flat = msRepoDir(repoId)
        if hasValidSafetensors(in: flat) { return flat }
        for base in msBases() {
            let repoBase = base.appendingPathComponent(repoId)
            guard fm.fileExists(atPath: repoBase.path),
                let entries = try? fm.contentsOfDirectory(
                    at: repoBase, includingPropertiesForKeys: nil)
            else { continue }
            let all = entries.filter { $0.hasDirectoryPath }
            for rev in ["master", "main"] {
                let revDir = repoBase.appendingPathComponent(rev)
                if hasValidSafetensors(in: revDir) { return revDir }
            }
            if let first = all.first(where: { hasValidSafetensors(in: $0) }) {
                return first
            }
        }
        return nil
    }

    // MARK: - 就绪模型发现(dedup,来源无关)

    /// 单个就绪模型条目。
    struct ReadyModel: Hashable, Sendable {
        /// EnginePool 约定 id:hub 模型带前缀(`hf:`/`mscope:`),本地模型为绝对路径。
        let id: String
        /// 权重目录(加载用)。
        let weightsDir: URL
        let isVlm: Bool
    }

    /// 扫描新 root + 旧散落位置,返回全部"就绪"模型(有非空 safetensors)。
    /// 去重:同一 (source, repoId) 只留第一个命中(新布局优先)。
    static func discoverReady() -> [ReadyModel] {
        let fm = FileManager.default
        var out: [ReadyModel] = []
        var seen = Set<String>()
        func add(_ m: ReadyModel) {
            let key = m.id
            if seen.insert(key).inserted { out.append(m) }
        }

        // 1) HF — 新 root + 旧 home cache(models-- 编码目录)
        let hubBases = [
            hubRoot,
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache").appendingPathComponent("huggingface")
                .appendingPathComponent("hub"),
        ]
        for base in hubBases where fm.fileExists(atPath: base.path) {
            if let entries = try? fm.contentsOfDirectory(
                at: base, includingPropertiesForKeys: nil)
            {
                for entry in entries {
                    guard let (ns, name) = decodeHubRepo(entry.lastPathComponent) else { continue }
                    let repoId = "\(ns)/\(name)"
                    guard let dir = snapshotDir(of: entry) else { continue }
                    add(
                        ReadyModel(
                            id: "hf:\(repoId)",
                            weightsDir: dir,
                            isVlm: fm.fileExists(
                                atPath: dir.appendingPathComponent("preprocessor_config.json").path)
                        ))
                }
            }
        }
        // 旧布局 B 平铺目录(org.ml-explore.mlx-swift-lm/<repoId>/)
        let legacyB = fm.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("org.ml-explore.mlx-swift-lm")
        if let legacyB, fm.fileExists(atPath: legacyB.path),
            let repos = try? fm.contentsOfDirectory(at: legacyB, includingPropertiesForKeys: nil)
        {
            for repo in repos {
                if hasValidSafetensors(in: repo) {
                    add(
                        ReadyModel(
                            id: "hf:\(repo.lastPathComponent)",
                            weightsDir: repo,
                            isVlm: fm.fileExists(
                                atPath: repo.appendingPathComponent("preprocessor_config.json").path
                            )))
                }
            }
        }

        // 2) ModelScope — 新平铺 root/<ns>/<name>/ 直扫(omlx 对齐;排除 provider 保留目录)
        let reserved = Set([hubSubRoot, localSubRoot, msSubRoot])
        if let orgEntries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
        {
            for org in orgEntries {
                guard
                    org.hasDirectoryPath,
                    !reserved.contains(org.lastPathComponent),
                    let names = try? fm.contentsOfDirectory(
                        at: org, includingPropertiesForKeys: nil)
                else { continue }
                for name in names {
                    if hasValidSafetensors(in: name) {
                        add(
                            ReadyModel(
                                id: "mscope:\(org.lastPathComponent)/\(name.lastPathComponent)",
                                weightsDir: name,
                                isVlm: fm.fileExists(
                                    atPath: name.appendingPathComponent("preprocessor_config.json")
                                        .path
                                )))
                    }
                }
            }
        }
        // 2b) MS 遗留三级 <base>/<ns>/<name>/<rev>/ — 旧默认根/旧规范根/旧 Caches
        for base in msBases() where fm.fileExists(atPath: base.path) {
            guard
                let nsList = try? fm.contentsOfDirectory(
                    at: base, includingPropertiesForKeys: nil)
            else { continue }
            for ns in nsList {
                guard
                    let nameList = try? fm.contentsOfDirectory(
                        at: ns, includingPropertiesForKeys: nil)
                else { continue }
                for name in nameList {
                    guard
                        let revs = try? fm.contentsOfDirectory(
                            at: name, includingPropertiesForKeys: nil)
                    else { continue }
                    if let ready = revs.first(where: { hasValidSafetensors(in: $0) }) {
                        add(
                            ReadyModel(
                                id: "mscope:\(ns.lastPathComponent)/\(name.lastPathComponent)",
                                weightsDir: ready,
                                isVlm: fm.fileExists(
                                    atPath: ready.appendingPathComponent("preprocessor_config.json")
                                        .path)))
                    }
                }
            }
        }

        // 3) Local — <root>/local/<name>/
        if fm.fileExists(atPath: localRoot.path),
            let names = try? fm.contentsOfDirectory(at: localRoot, includingPropertiesForKeys: nil)
        {
            for dir in names where hasValidSafetensors(in: dir) {
                add(
                    ReadyModel(
                        id: dir.standardizedFileURL.path,
                        weightsDir: dir.standardizedFileURL,
                        isVlm: fm.fileExists(
                            atPath: dir.appendingPathComponent("preprocessor_config.json").path)))
            }
        }

        return out
    }

    // MARK: - 清理(删除 = 删除目录;遗留位置同样命中,不搬移)

    /// 删除一个 hub 模型的全部本地落位(新规范位 + 全部遗留位)。`local` 源不在此处理。
    /// `source` 仅接受 `"huggingFace"` / `"modelScope"`(其他值抛 `removeNotApplicable`)。
    static func removeReady(repoId: String, source: String) throws {
        enum ModelStoreError: Error, Equatable {
            case removeNotApplicable(source: String)
        }

        let fm = FileManager.default
        func rm(_ url: URL) throws {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }

        switch source {
        case "huggingFace":
            let encoded = encodeHubRepo(repoId)
            // HubCache 形态:新根 + 旧默认根 + 家缓存
            for base in [
                hubRoot, legacyRoot.appendingPathComponent(hubSubRoot), legacyHFBases()[1],
            ] {
                try rm(base.appendingPathComponent(encoded))
            }
            // 早期宏 Caches 平铺(两种目录名形态)
            if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
                .first
            {
                let legacyBase = caches.appendingPathComponent("org.ml-explore.mlx-swift-lm")
                try rm(legacyBase.appendingPathComponent(encoded))
                try rm(legacyBase.appendingPathComponent(repoId))
            }
        case "modelScope":
            // 新平铺:root/<ns>/<name>/;旧三级:各遗留基/<ns>/<name>/ 整仓库目录
            try rm(msRepoDir(repoId))
            for base in msBases() {
                try rm(base.appendingPathComponent(repoId))
            }
        default:
            throw ModelStoreError.removeNotApplicable(source: source)
        }
    }
}
