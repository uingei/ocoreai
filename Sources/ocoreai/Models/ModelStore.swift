// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelStore.swift — 就绪模型目录(ready-model directory)单一事实源
///
/// M7: omlx 对齐的"就绪模型目录"层——所有 hub 下载与本地模型的统一登记簿。
/// omlx 对应物: `~/.omlx/models`(`settings.py:44` DEFAULT_BASE_PATH;
/// `settings.py:232` get_model_dirs;`admin/routes.py:297` HF 直接落盘 model_dir)。
///
/// 布局(全部在 root 下,与旧 Caches 散落布局并存、互不覆盖):
/// ```
/// <root>/huggingface/models--<ns>--<name>/   HubCache 原生布局(blobs/ + snapshots/<rev>/…)
///                                             — 断点续传 ✓、与 Python huggingface 互通 ✓
/// <root>/modelscope/<ns>/<name>/<revision>/  ModelScopeDownloader 原生布局
/// <root>/local/<name>/                       用户自行放置的模型
/// ```
///
/// root 解析:`$OCOREAI_MODELS_DIR` > `~/Library/Application Support/ocoreai/models`(macOS)>
/// `~/.local/share/ocoreai/models`(Linux/其它)。
///
/// 迁移纪律:旧散落位置(~/.cache/huggingface/hub、Caches/org.ml-explore.mlx-swift-lm、
/// Caches/ocoreai/modelscope)只被**发现/清理**,不搬移数据(可逆;用户数据零损失)。
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

    /// 就绪模型根目录(env 覆盖 → 平台默认)。
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["OCOREAI_MODELS_DIR"],
            !override.isEmpty
        {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
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

    /// HF 仓库目录候选(新 root 优先,旧散落位置随后)——按序返回第一个就绪的。
    /// 新布局:`<root>/huggingface/models--<ns>--<name>/snapshots/<rev>/`(含 blobs 快路径)。
    /// 旧布局 A:`~/.cache/huggingface/hub/models--<ns>--<name>/snapshots/<rev>/`。
    /// 旧布局 B(macOS):`~/Library/Caches/org.ml-explore.mlx-swift-lm/<ns>/<name>/`(平铺,无 snapshots)。
    static func hubReadyDir(_ repoId: String) -> URL? {
        let encoded = encodeHubRepo(repoId)
        let fm = FileManager.default
        let home = FileManager.default.homeDirectoryForCurrentUser

        let newBase = hubRoot.appendingPathComponent(encoded)
        if let dir = snapshotDir(of: newBase) { return dir }

        // 旧布局 A:python 风格 home cache
        let legacyA =
            home
            .appendingPathComponent(".cache")
            .appendingPathComponent("huggingface")
            .appendingPathComponent("hub")
            .appendingPathComponent(encoded)
        if let dir = snapshotDir(of: legacyA) { return dir }

        // 旧布局 B:macOS caches 平铺(HubBridge 早期宏默认位置)
        let legacyB = fm.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("org.ml-explore.mlx-swift-lm")
            .appendingPathComponent(repoId)
        if legacyB != nil, hasValidSafetensors(in: legacyB!) { return legacyB }

        return nil
    }

    /// HubCache 布局:`prefer snapshots/<first-valid-rev>/`,否则平铺目录本身。
    private static func snapshotDir(of repoDir: URL) -> URL? {
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

    /// MS 就绪目录:`<base>/<ns>/<name>/<revision>/`(按序试 master → main → 其它已存 revision)。
    /// base 取新 root;旧 Caches 位置随后。
    static func msReadyDir(_ repoId: String) -> URL? {
        for base in msBases() {
            let repoBase = base.appendingPathComponent(repoId)
            guard FileManager.default.fileExists(atPath: repoBase.path) else { continue }
            for rev in ["master", "main"] {
                let revDir = repoBase.appendingPathComponent(rev)
                if hasValidSafetensors(in: revDir) { return revDir }
            }
            if let revs = try? FileManager.default.contentsOfDirectory(
                at: repoBase, includingPropertiesForKeys: nil)
            {
                for rev in revs where hasValidSafetensors(in: rev) { return rev }
            }
        }
        return nil
    }

    /// MS 根候选:新 root 优先,旧 Caches 散落位置随后(只读/清理,不迁移)。
    static func msBases() -> [URL] {
        var bases: [URL] = [msRoot]
        let legacy = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ocoreai/modelscope")
        if let legacy { bases.append(legacy) }
        return bases
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

        // 2) ModelScope — 三级目录 <base>/<ns>/<name>/<rev>/
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

    // MARK: - 清理(删除 = 删除目录;旧位置同样命中)

    /// 删除一个 hub 模型的全部本地权重(新 + 旧位置)。`local` 源不在此处理。
    /// `source` 仅接受 `"huggingFace"` / `"modelScope"`(其他值抛 `removeNotApplicable`)。
    static func removeReady(repoId: String, source: String) throws {
        enum ModelStoreError: Error, Equatable {
            case removeNotApplicable(source: String)
        }

        let fm = FileManager.default
        switch source {
        case "huggingFace":
            let encoded = encodeHubRepo(repoId)
            var targets: [URL] = [hubRoot.appendingPathComponent(encoded)]
            targets.append(
                fm.homeDirectoryForCurrentUser
                    .appendingPathComponent(".cache").appendingPathComponent("huggingface")
                    .appendingPathComponent("hub").appendingPathComponent(encoded))
            let legacyB = fm.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("org.ml-explore.mlx-swift-lm").appendingPathComponent(
                    repoId)
            if let legacyB { targets.append(legacyB) }
            for t in targets where fm.fileExists(atPath: t.path) {
                try fm.removeItem(at: t)
            }
        case "modelScope":
            for base in msBases() {
                let t = base.appendingPathComponent(repoId)
                if fm.fileExists(atPath: t.path) { try fm.removeItem(at: t) }
            }
        default:
            throw ModelStoreError.removeNotApplicable(source: source)
        }
    }
}
