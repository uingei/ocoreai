// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Lightweight i18n layer — code-based locale mapping.
/// Zero Xcode dependency, swappable at runtime, full fallback chain.
///
/// Design:
/// - StringKey enum: each UI string gets a typed key — compile-time safe, no typos.
/// - Locale enum: supported locales.
/// - StringKey.localized(for:) resolves via fallback chain: locale → base (en).
/// - String key extension for quick inline use: key.l
/// - Locale key extension: key.l(in: .zh)
import Foundation

// MARK: - Supported Locales

/// Locales supported by ocoreai. Expand this array to add new languages.
public enum OCALocale: String, CaseIterable {
    /// English (base language — fallback for missing translation)
    case en
    /// Simplified中文 — 简体中文
    case zhHans
    /// 日本語
    case ja
    /// 한국어
    case ko
    /// Français
    case fr
    /// Español
    case es

    public var displayName: String {
        switch self {
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .fr: return "Français"
        case .es: return "Español"
        }
    }

    /// BCP 47 language tag
    public var bcp47Tag: String {
        switch self {
        case .en: return "en"
        case .zhHans: return "zh-Hans"
        case .ja: return "ja"
        case .ko: return "ko"
        case .fr: return "fr"
        case .es: return "es"
        }
    }

    /// Detect user locale from system. Falls back to ``.en``.
    /// Uses `Locale.preferredLanguages` which returns full BCP 47 tags (e.g. "zh-Hans-CN").
    public static func systemLocale() -> OCALocale {
        // preferredLanguages returns e.g. ["zh-Hans-CN", "en-US"]
        let preferredTags = Locale.preferredLanguages
        // Match from most-specific to least-specific so "zh-Hans-CN" hits zhHans before en
        for tag in preferredTags {
            for locale in OCALocale.allCases.sorted(by: { $0.bcp47Tag.count > $1.bcp47Tag.count })
                where tag.starts(with: locale.bcp47Tag)
            {
                return locale
            }
        }
        return .en
    }
}

// MARK: - String Keys (type-safe)

/// Every UI string gets a typed key. New text = new key + translations.
/// No runtime string literal lookup — compile-time safe.
public enum StringKey: String, CaseIterable {
    // — Dashboard —
    case systemOnline = "Dashboard.SystemOnline"
    case systemLoading = "Dashboard.SystemLoading"
    case metrics = "Dashboard.Metrics"
    case throughput = "Dashboard.Throughput"
    case ttft = "Dashboard.TTFT"
    case ttfb = "Dashboard.TTFB"
    case gpuMemory = "Dashboard.GPUMemory"
    case kvCache = "Dashboard.KVCache"
    case kvEvictions = "Dashboard.KVEvictions"
    case sessions = "Dashboard.Sessions"
    case modelsLoaded = "Dashboard.ModelsLoaded"
    case inferences = "Dashboard.Inferences"
    case rateLimit = "Dashboard.RateLimit"
    case uptime = "Dashboard.Uptime"
    case avgInfer = "Dashboard.AvgInfer"
    case tokenThroughput = "Dashboard.TokenThroughput"
    case gpuMemoryKVCache = "Dashboard.GPUMemoryKVCache"
    case loadingMetrics = "Dashboard.LoadingMetrics"

    // — Chat —
    case chatPlaceholder = "Chat.Placeholder"
    case send = "Chat.Send"
    case stop = "Chat.Stop"
    case newConversation = "Chat.NewConversation"

    // — Settings —
    case settingsTitle = "Settings.Title"
    case serverAddress = "Settings.ServerAddress"
    case port = "Settings.Port"
    case verifyConnection = "Settings.VerifyConnection"
    case connected = "Settings.Connected"
    case disconnected = "Settings.Disconnected"
    case connecting = "Settings.Connecting"
    case connectionFailed = "Settings.ConnectionFailed"
    case serverSection = "Settings.ServerSection"
    case ensureBackend = "Settings.EnsureBackend"
    case performanceSection = "Settings.PerformanceSection"
    case pollInterval = "Settings.PollInterval"
    case chartWindow = "Settings.ChartWindow"
    case chartWindowHint = "Settings.ChartWindowHint"
    case kvCacheSection = "Settings.KVCacheSection"
    case kvQuantToggle = "Settings.KVQuantToggle"
    case kvQuantToggleHint = "Settings.KVQuantToggleHint"
    case kvQuantBits = "Settings.KVQuantBits"
    case kvBudget = "Settings.KVBudget"
    case kvBudgetHint = "Settings.KVBudgetHint"
    case logsSection = "Settings.LogsSection"
    case logLevel = "Settings.LogLevel"
    case profileToggle = "Settings.ProfileToggle"
    case profileToggleHint = "Settings.ProfileToggleHint"
    case appSection = "Settings.AppSection"
    case localePicker = "Settings.LocalePicker"
    case themeMode = "Settings.ThemeMode"
    case themeModeAuto = "Settings.ThemeModeAuto"
    case themeModeLight = "Settings.ThemeModeLight"
    case themeModeDark = "Settings.ThemeModeDark"
    case aboutSection = "Settings.AboutSection"
    case version = "Settings.Version"
    case commitHash = "Settings.CommitHash"
    case license = "Settings.License"
    case resetSettings = "Settings.ResetSettings"
    case resetConfirm = "Settings.ResetConfirm"
    case allSections = "Settings.AllSections"

    // — Navigation —
    case tabDashboard = "Navigation.Dashboard"
    case tabChat = "Navigation.Chat"
    case tabModels = "Navigation.Models"
    case tabStatus = "Navigation.Status"
    case tabSettings = "Navigation.Settings"
    case selectPanel = "Navigation.SelectPanel"
    case navigationTitle = "Navigation.Title"
    case sidebarNavigation = "Navigation.Sidebar"
    
    // — Sidebar Sections —
    case sectionServer = "Sidebar.Section.Server"
    case sectionModels = "Sidebar.Section.Models"
    case sectionGeneral = "Sidebar.Section.General"
    
    // — Quick Metrics —
    case metricOverview = "Metrics.Overview"
    case metricOverviewAccessibility = "Metrics.Overview.Descripción"
    case metricThroughput = "Metrics.Throughput"
    case metricGPUMemory = "Metrics.GPUMemory"
    case metricSessions = "Metrics.Sessions"
    case metricStatus = "Metrics.Status"
    case metricStatusActive = "Metrics.Status.Active"
    case metricStatusIdle = "Metrics.Status.Idle"

    // — Chat —
    case chatWelcomeTitle = "Chat.WelcomeTitle"
    case chatWelcomeDesc = "Chat.WelcomeDesc"

    // — Models —
    case noModelsLoaded = "Models.NoModelsLoaded"
    case loadingModels = "Models.Loading"
    case modelLoadError = "Models.LoadError"
    case modelLoadErrorDesc = "Models.LoadErrorDesc"

    // — Multimodal —
    case multimodalTitle = "Multimodal.Title"
    case multimodalCamera = "Multimodal.Camera"
    case multimodalLiveFeed = "Multimodal.LiveFeed"
    case multimodalMic = "Multimodal.Mic"
    case multimodalSpeaker = "Multimodal.Speaker"
    case multimodalTtsHint = "Multimodal.TtsHint"

    // — Dashboard —
    case dashboardTitle = "Dashboard.Title"
    case dashboardPerformance = "Dashboard.Performance"
    case dashboardSystemInfo = "Dashboard.SystemInfo"
    case dashboardTokenChartDesc = "Dashboard.TokenChartDesc"
    case dashboardMemChartDesc = "Dashboard.MemChartDesc"

    // — ViewState —
    case connectionFailedTitle = "State.ConnectionFailed"
    case connectionFailedDesc = "State.ConnectionFailedDesc"

    // — Status Pill —
    case statusRunning = "Status.Running"
    case statusStarting = "Status.Starting"
    case statusStopping = "Status.Stopping"
    case statusStopped = "Status.Stopped"
    case statusError = "Status.Error"

    // — LogLevel Display Names —
    case logLevelDebug = "LogLevel.Debug"
    case logLevelInfo = "LogLevel.Info"
    case logLevelWarning = "LogLevel.Warning"
    case logLevelError = "LogLevel.Error"
}

// MARK: - Translation Table (per locale)

extension StringKey {
    /// Quick inline access to resolved string
    public var l: String { localized(for: .systemLocale()) }

    /// Resolve via fallback chain: requested locale → base (en).
    public func localized(for locale: OCALocale = .systemLocale()) -> String {
        resolve(key: self, locale: locale)
    }
}

private func resolve(key: StringKey, locale: OCALocale) -> String {
    // Base translations (en) — fallback for missing
    let base: [StringKey: String] = [
        // Dashboard
        .systemOnline: "System Online",
        .systemLoading: "System Loading",
        .metrics: "Metrics",
        .throughput: "Throughput",
        .ttft: "TTFT",
        .ttfb: "TTFB",
        .gpuMemory: "GPU Memory",
        .kvCache: "KV Cache",
        .kvEvictions: "KV Evictions",
        .sessions: "Sessions",
        .modelsLoaded: "Models Loaded",
        .inferences: "Inferences",
        .rateLimit: "Rate Limit",
        .uptime: "Uptime",
        .avgInfer: "Avg Infer",
        .tokenThroughput: "Token Throughput",
        .gpuMemoryKVCache: "GPU Memory & KV Cache",
        .loadingMetrics: "Loading metrics...",

        // Chat
        .chatPlaceholder: "Type a message...",
        .send: "Send",
        .stop: "Stop",
        .newConversation: "New Conversation",

        // Settings
        .settingsTitle: "Settings",
        .serverAddress: "Server Address",
        .port: "Port",
        .verifyConnection: "Verify Connection",
        .connected: "Connected",
        .disconnected: "Disconnected",
        .connecting: "Connecting...",
        .connectionFailed: "Connection Failed",
        .serverSection: "Server",
        .ensureBackend: "Ensure the backend is running and reachable",
        .performanceSection: "Performance",
        .pollInterval: "Metrics Poll Interval",
        .chartWindow: "Chart History Window",
        .chartWindowHint: "Number of seconds to display in charts",
        .kvCacheSection: "KV Cache",
        .kvQuantToggle: "Enable Quantization Downgrade",
        .kvQuantToggleHint: "Auto-downgrade KV cache from FP16 → INT4 to save memory",
        .kvQuantBits: "Quantization Bits",
        .kvBudget: "KV Cache Budget (GB)",
        .kvBudgetHint: "Maximum memory reserved for KV cache",
        .logsSection: "Logs & Profiling",
        .logLevel: "Log Level",
        .profileToggle: "Enable Performance Profiling",
        .profileToggleHint: "Record timing hooks for inference pipeline",
        .appSection: "Application",
        .localePicker: "Language",
        .themeMode: "Theme",
        .themeModeAuto: "Auto",
        .themeModeLight: "Light",
        .themeModeDark: "Dark",
        .aboutSection: "About",
        .version: "Version",
        .commitHash: "Commit",
        .license: "License",
        .resetSettings: "Reset All Settings",
        .resetConfirm: "Are you sure? This wipes all saved settings.",
        .allSections: "All Settings",

        // Navigation
        .tabDashboard: "Dashboard",
        .tabChat: "Chat",
        .tabModels: "Models",
        .tabStatus: "Status",
        .tabSettings: "Settings",
        .selectPanel: "Select a panel",
        .navigationTitle: "Navigation",
        .sidebarNavigation: "Navigation",
        
        // Sidebar Sections
        .sectionServer: "Server",
        .sectionModels: "Models",
        .sectionGeneral: "General",
        
        // Quick Metrics
        .metricOverview: "Overview",
        .metricOverviewAccessibility: "System Overview",
        .metricThroughput: "Throughput",
        .metricGPUMemory: "GPU Memory",
        .metricSessions: "Sessions",
        .metricStatus: "Status",
        .metricStatusActive: "Active",
        .metricStatusIdle: "Idle",

        // Chat
        .chatWelcomeTitle: "Start a conversation",
        .chatWelcomeDesc: "Send a message to begin local AI inference",

        // Models
        .noModelsLoaded: "No models loaded",
        .loadingModels: "Loading models...",
        .modelLoadError: "Load Failed",
        .modelLoadErrorDesc: "The backend server may be unavailable",

        // Multimodal
        .multimodalTitle: "Multimodal I/O",
        .multimodalCamera: "Camera (Eyes)",
        .multimodalLiveFeed: "Live Feed",
        .multimodalMic: "Microphone (Ears)",
        .multimodalSpeaker: "Speaker (Mouth)",
        .multimodalTtsHint: "TTS is active — assistant responses will be spoken aloud",

        // Dashboard
        .dashboardTitle: "Dashboard",
        .dashboardPerformance: "System information",
        .dashboardSystemInfo: "System information",
        .dashboardTokenChartDesc: "Token throughput chart",
        .dashboardMemChartDesc: "Memory chart: GPU usage and KV cache trends",

        // ViewState
        .connectionFailedTitle: "Connection Failed",
        .connectionFailedDesc: "The backend server may be unavailable",

        // Status Pill
        .statusRunning: "Running",
        .statusStarting: "Starting",
        .statusStopping: "Stopping",
        .statusStopped: "Stopped",
        .statusError: "Error",

        // LogLevel display names
        .logLevelDebug: "Debug",
        .logLevelInfo: "Info",
        .logLevelWarning: "Warning",
        .logLevelError: "Error",
        ]

    // Translation overrides per locale
    let zh: [StringKey: String] = [
        .systemOnline: "系统在线",
        .systemLoading: "系统加载中",
        .metrics: "指标",
        .throughput: "吞吐量",
        .ttft: "首字延迟",
        .ttfb: "首字节延迟",
        .gpuMemory: "GPU 显存",
        .kvCache: "KV 缓存",
        .kvEvictions: "KV 驱逐",
        .sessions: "会话",
        .modelsLoaded: "已加载模型",
        .inferences: "推理数",
        .rateLimit: "速率限制",
        .uptime: "运行时间",
        .avgInfer: "平均推理",
        .tokenThroughput: "Token 吞吐量",
        .gpuMemoryKVCache: "GPU 显存与 KV 缓存",
        .loadingMetrics: "加载指标中...",
        .chatPlaceholder: "输入消息...",
        .send: "发送",
        .stop: "停止",
        .newConversation: "新对话",
        .settingsTitle: "设置",
        .serverAddress: "服务器地址",
        .port: "端口",
        .verifyConnection: "验证连接",
        .connected: "已连接",
        .disconnected: "未连接",
        .connecting: "连接中...",
        .connectionFailed: "连接失败",
        .serverSection: "服务器",
        .ensureBackend: "确保推理后端正在运行并可访问",
        .performanceSection: "性能",
        .pollInterval: "指标轮询间隔",
        .chartWindow: "图表历史窗口",
        .chartWindowHint: "图表中展示的历史秒数",
        .kvCacheSection: "KV 缓存",
        .kvQuantToggle: "启用量化降级",
        .kvQuantToggleHint: "自动将 KV 缓存从 FP16 降级到 INT4 以节省内存",
        .kvQuantBits: "量化精度",
        .kvBudget: "KV 缓存预算（GB）",
        .kvBudgetHint: "为 KV 缓存保留的最大内存",
        .logsSection: "日志与性能分析",
        .logLevel: "日志级别",
        .profileToggle: "启用性能分析",
        .profileToggleHint: "记录推理流水线性能指标",
        .appSection: "应用",
        .localePicker: "语言",
        .themeMode: "主题",
        .themeModeAuto: "自动",
        .themeModeLight: "浅色",
        .themeModeDark: "深色",
        .aboutSection: "关于",
        .version: "版本",
        .commitHash: "提交",
        .license: "许可证",
        .resetSettings: "恢复默认设置",
        .resetConfirm: "确定吗？这将清除所有已保存的设置。",
        .allSections: "全部设置",

        // Navigation
        .tabDashboard: "仪表盘",
        .tabChat: "聊天",
        .tabModels: "模型",
        .tabStatus: "状态",
        .tabSettings: "设置",
        .selectPanel: "选择面板",
        .navigationTitle: "导航",

        // Chat
        .chatWelcomeTitle: "开始对话",
        .chatWelcomeDesc: "发送消息以开始本地 AI 推理",

        // Models
        .noModelsLoaded: "未加载模型",
        .loadingModels: "加载模型中…",
        .modelLoadError: "加载失败",
        .modelLoadErrorDesc: "推理后端服务器可能不可用",

        // Multimodal
        .multimodalTitle: "多模态输入/输出",
        .multimodalCamera: "摄像头（视觉）",
        .multimodalLiveFeed: "实时画面",
        .multimodalMic: "麦克风（听觉）",
        .multimodalSpeaker: "扬声器（语音）",
        .multimodalTtsHint: "TTS 已激活 — 助手回复将以语音播报",

        // Dashboard
        .dashboardTitle: "仪表盘",
        .dashboardPerformance: "系统信息",
        .dashboardSystemInfo: "系统信息",
        .dashboardTokenChartDesc: "Token 吞吐量图表",
        .dashboardMemChartDesc: "内存图表：GPU 显存与 KV 缓存",

        // ViewState
        .connectionFailedTitle: "连接失败",
        .connectionFailedDesc: "推理后端服务器可能不可用",

        // Status Pill
        .statusRunning: "运行中",
        .statusStarting: "启动中",
        .statusStopping: "停止中",
        .statusStopped: "已停止",
        .statusError: "错误",

        // LogLevel display names
        .logLevelDebug: "调试",
        .logLevelInfo: "信息",
        .logLevelWarning: "警告",
        .logLevelError: "错误",
        ]

    // Add more locale tables here as needed (ja, ko, fr, es...)

    let tables: [OCALocale: [StringKey: String]] = [
        .zhHans: zh,
        // .ja: jaTrans,
        // .ko: koTrans,
    ]

    if let override = tables[locale]?[key] {
        return override
    }
    return base[key] ?? "⚠️ \(key.rawValue)"
}
