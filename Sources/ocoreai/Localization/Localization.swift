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

	// — Accessibility Labels —
	case appLabel = "A11y.AppLabel"
	case appTitle = "A11y.AppTitle"
	case noPanelSelected = "A11y.NoPanelSelected"
	case selectTab = "A11y.SelectTab"
	case modelSelectorLabel = "A11y.ModelSelectorLabel"
	case modelSelectorValueDefault = "A11y.ModelSelectorValueDefault"
	case clearConversationLabel = "A11y.ClearConversationLabel"
	case clearConversationHint = "A11y.ClearConversationHint"
	case chatLabel = "A11y.ChatLabel"
	case chatConnected = "A11y.ChatConnected"
	case chatLoading = "A11y.ChatLoading"
	case messagesLabel = "A11y.MessagesLabel"
	case assistantTyping = "A11y.AssistantTyping"
	case voiceInputLabel = "A11y.VoiceInputLabel"
	case voiceInputHint = "A11y.VoiceInputHint"
	case messageInputLabel = "A11y.MessageInputLabel"
	case messageInputHint = "A11y.MessageInputHint"
	case stopStreamingLabel = "A11y.StopStreamingLabel"
	case stopStreamingHint = "A11y.StopStreamingHint"
	case sendMessageLabel = "A11y.SendMessageLabel"
	case sendMessageHint = "A11y.SendMessageHint"
	case youLabel = "A11y.YouLabel"
	case ocoreaiLabel = "A11y.OcoreaiLabel"
	case suggestionHint = "A11y.SuggestionHint"
	case localLabel = "A11y.LocalLabel"
	case dashboardLabel = "A11y.DashboardLabel"
	case systemInfoLabel = "A11y.SystemInfoLabel"
	case areaGraphTokenDesc = "A11y.AreaGraphTokenDesc"
	case areaGraphGpuDesc = "A11y.AreaGraphGpuDesc"
	case kvCacheLineDesc = "A11y.KVCacheLineDesc"
	case refreshModelLabel = "A11y.RefreshModelLabel"
	case refreshModelHint = "A11y.RefreshModelHint"
	case contextKey = "A11y.ContextKey"
	case tokenizerKey = "A11y.TokenizerKey"
	case modelRunningLabel = "A11y.ModelRunningLabel"
	case multimodalControlsLabel = "A11y.MultimodalControlsLabel"
	case enableCameraLabel = "A11y.EnableCameraLabel"
	case enableCameraHint = "A11y.EnableCameraHint"
	case cameraPreviewLabel = "A11y.CameraPreviewLabel"
	case captureFrameLabel = "A11y.CaptureFrameLabel"
	case captureFrameHint = "A11y.CaptureFrameHint"
	case enableMicLabel = "A11y.EnableMicLabel"
	case enableMicHint = "A11y.EnableMicHint"
	case stopRecordingLabel = "A11y.StopRecordingLabel"
	case stopRecordingHint = "A11y.StopRecordingHint"
	case startRecordingLabel = "A11y.StartRecordingLabel"
	case startRecordingHint = "A11y.StartRecordingHint"
	case lastTranscriptLabel = "A11y.LastTranscriptLabel"
	case enableSpeakerLabel = "A11y.EnableSpeakerLabel"
	case enableSpeakerHint = "A11y.EnableSpeakerHint"
	case ttsActiveLabel = "A11y.TtsActiveLabel"
	case statusIndicatorsLabel = "A11y.StatusIndicatorsLabel"

	// — Status Dot Labels —
	case statusCameraActive = "Status.CameraActive"
	case statusRecording = "Status.Recording"
	case statusSpeaking = "Status.Speaking"
	case statusActive = "Status.Active"
	case statusInactive = "Status.Inactive"

	// — Accessibility label templates —
	case a11yStatus = "A11y.Status"
	case a11yModel = "A11y.Model"

	// — Settings / About —
	case aboutTitle = "About.Title"
	case aboutVersion = "About.Version"

	// — Model Info —
	case modelInfoContext = "ModelInfo.Context"
	case modelInfoTokenizer = "ModelInfo.Tokenizer"

	// — Chart Axis Labels (macOS Charts) —
	case chartTime = "Chart.Time"
	case chartTokPerSec = "Chart.TokPerSec"
	case chartGB = "Chart.GB"

	// — Default Model —
	case defaultModel = "Model.Default"
	case noModelSelected = "Model.NoModelSelected"
	case clear = "Chat.Clear"
	// — Refresh —
	case refreshButton = "Action.Refresh"
	// — Retry —
	case tryAgain = "Action.TryAgain"
	// — Copy —
	case copyMessage = "Action.CopyMessage"
	// — Undo —
	case undoAction = "Action.Undo"

	// — Sessions —
	case tabSessions = "Tab.Sessions"
	case sessionSearchPlaceholder = "Session.SearchPlaceholder"
	case sessionListEmpty = "Session.ListEmpty"
	case sessionSelectHint = "Session.SelectHint"
	case sessionCreate = "Session.Create"
	case sessionDelete = "Session.Delete"
	case sessionDeleteConfirm = "Session.DeleteConfirm"
	case sessionSummary = "Session.Summary"
	case sessionModel = "Session.Model"
	case sessionCreatedAt = "Session.CreatedAt"
	case sessionMessageCount = "Session.MessageCount"
	case sessionTokenCount = "Session.TokenCount"
	case memoryTitle = "Session.MemoryTitle"
	case memoryEmpty = "Session.MemoryEmpty"
	case memorySearchPlaceholder = "Session.MemorySearchPlaceholder"
	
	// — Skills —
	case tabSkills = "Tab.Skills"
	case skillListEmpty = "Skill.ListEmpty"
	case skillSelectHint = "Skill.SelectHint"
	case skillName = "Skill.Name"
	case skillCategory = "Skill.Category"
	case skillDescription = "Skill.Description"
	case skillTags = "Skill.Tags"
	case skillContentTitle = "Skill.ContentTitle"
	case skillDependencies = "Skill.Dependencies"
	
	// — System —
	case tabSystem = "Tab.System"
	case systemMCPSection = "System.MCPSection"
	case systemMCPEmpty = "System.MCPEmpty"
	case systemMCPConnected = "System.MCPConnected"
	case systemMCPDisconnected = "System.MCPDisconnected"
	case systemMCPName = "System.MCPName"
	case systemMCPCommand = "System.MCPCommand"
	case systemToolsSection = "System.ToolsSection"
	case systemToolsEmpty = "System.ToolsEmpty"
	case systemToolName = "System.ToolName"
	case systemToolReadOnly = "System.ToolReadOnly"
	case systemToolDestructive = "System.ToolDestructive"
	case systemAuditSection = "System.AuditSection"
	case systemAuditEmpty = "System.AuditEmpty"
	case systemAuditTool = "System.AuditTool"
	case systemAuditCaller = "System.AuditCaller"
	case systemAuditDuration = "System.AuditDuration"
	case systemAuditStatus = "System.AuditStatus"
	case systemReasoningSection = "System.ReasoningSection"
	case systemComplexityScore = "System.ComplexityScore"
	case systemThinkingBudget = "System.ThinkingBudget"
	case systemRefresh = "System.Refresh"
	case systemClearAudit = "System.ClearAudit"
	case systemClearAuditConfirm = "System.ClearAuditConfirm"
	
	// — Per-model Inference Params —
	case modelParamsTitle = "Models.ParamsTitle"
	case modelParamTemperature = "Models.ParamTemperature"
	case modelParamTemperatureHint = "Models.ParamTemperatureHint"
	case modelParamTopP = "Models.ParamTopP"
	case modelParamTopPHint = "Models.ParamTopPHint"
	case modelParamTopK = "Models.ParamTopK"
	case modelParamTopKHint = "Models.ParamTopKHint"
	case modelParamMaxTokens = "Models.ParamMaxTokens"
	case modelParamMaxTokensHint = "Models.ParamMaxTokensHint"
	case modelParamRepeatPenalty = "Models.ParamRepeatPenalty"
	case modelParamRepeatPenaltyHint = "Models.ParamRepeatPenaltyHint"
	case modelParamFrequencyPenalty = "Models.ParamFrequencyPenalty"
	case modelParamPresencePenalty = "Models.ParamPresencePenalty"
	case modelParamSave = "Models.ParamSave"
	case modelParamReset = "Models.ParamReset"
	case modelParamDefaults = "Models.ParamDefaults"
	case modelViewTapToEdit = "Models.TapToEdit"
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

		// Accessibility Labels
		.appLabel: "ocoreai",
		.appTitle: "ocoreai",
		.noPanelSelected: "No panel selected",
		.selectTab: "Select",
		.modelSelectorLabel: "Model Selector",
		.modelSelectorValueDefault: "No model selected",
		.clearConversationLabel: "Clear Conversation",
		.clearConversationHint: "Removes all messages from this conversation",
		.chatLabel: "Chat",
		.chatConnected: "Local backend connected",
		.chatLoading: "Backend loading",
		.messagesLabel: "Messages",
		.assistantTyping: "Assistant typing",
		.voiceInputLabel: "Voice Input",
		.voiceInputHint: "Tap to use voice input (coming soon)",
		.messageInputLabel: "Message Input",
		.messageInputHint: "Type your message and press Enter to send",
		.stopStreamingLabel: "Stop Streaming",
		.stopStreamingHint: "Tap to stop the current response",
		.sendMessageLabel: "Send Message",
		.sendMessageHint: "Tap to send your message",
		.youLabel: "You",
		.ocoreaiLabel: "ocoreai",
		.suggestionHint: "Tap to use this suggestion as your message",
		.localLabel: "Local",
		.dashboardLabel: "Dashboard",
		.systemInfoLabel: "System information",
		.areaGraphTokenDesc: "Area graph showing token throughput over time",
		.areaGraphGpuDesc: "Area graph showing GPU memory usage over time",
		.kvCacheLineDesc: "KV cache usage line graph",
		.refreshModelLabel: "Refresh Model List",
		.refreshModelHint: "Fetch the latest model list from the backend",
		.contextKey: "Context",
		.tokenizerKey: "Tokenizer",
		.modelRunningLabel: "Model is running",
		.multimodalControlsLabel: "Multimodal Controls",
		.enableCameraLabel: "Enable Camera",
		.enableCameraHint: "Turn camera on or off",
		.cameraPreviewLabel: "Camera live feed preview",
		.captureFrameLabel: "Capture Frame",
		.captureFrameHint: "Take a snapshot from the camera",
		.enableMicLabel: "Enable Microphone",
		.enableMicHint: "Turn microphone on or off",
		.stopRecordingLabel: "Stop Recording",
		.stopRecordingHint: "Stop the current audio recording",
		.startRecordingLabel: "Start Recording",
		.startRecordingHint: "Begin recording audio",
		.lastTranscriptLabel: "Last transcript",
		.enableSpeakerLabel: "Enable Speaker",
		.enableSpeakerHint: "Turn text-to-speech on or off",
		.ttsActiveLabel: "Text-to-speech is active",
		.statusIndicatorsLabel: "Multimodal status indicators",

		// Status dot labels
		.statusCameraActive: "Camera Active",
		.statusRecording: "Recording",
		.statusSpeaking: "Speaking",
		.statusActive: "Active",
		.statusInactive: "Inactive",

		// A11y templates
		.a11yStatus: "Status",
		.a11yModel: "Model",

		// Settings / About
		.aboutTitle: "ocoreai",
		.aboutVersion: "v1.0.0 · macOS 15+ / iOS 17+",

		// Model info
		.modelInfoContext: "Context",
		.modelInfoTokenizer: "Tokenizer",

		// Chart axis labels
		.chartTime: "Time",
		.chartTokPerSec: "tok/s",
		.chartGB: "GB",

		// Per-model inference params
		.modelParamsTitle: "Inference Parameters",
		.modelParamTemperature: "Temperature",
		.modelParamTemperatureHint: "Controls randomness (0.0–2.0)",
		.modelParamTopP: "Top P",
		.modelParamTopPHint: "Nucleus sampling threshold",
		.modelParamTopK: "Top K",
		.modelParamTopKHint: "Keep K most likely tokens",
		.modelParamMaxTokens: "Max Tokens",
		.modelParamMaxTokensHint: "Maximum output tokens",
		.modelParamRepeatPenalty: "Repeat Penalty",
		.modelParamRepeatPenaltyHint: "Penalty for repeated tokens",
		.modelParamFrequencyPenalty: "Frequency Penalty",
		.modelParamPresencePenalty: "Presence Penalty",
		.modelParamSave: "Save",
		.modelParamReset: "Reset to Defaults",
		.modelParamDefaults: "Defaults",
		.modelViewTapToEdit: "Tap to edit parameters",

		// Models
		.defaultModel: "default",
		.noModelSelected: "No Model",
		.clear: "Clear",
		.refreshButton: "Refresh",
		.tryAgain: "Try Again",
		.copyMessage: "Copy Message",
		.undoAction: "Undo",

		// Sessions
		.tabSessions: "Sessions",
		.sessionSearchPlaceholder: "Search sessions...",
		.sessionListEmpty: "No sessions yet",
		.sessionSelectHint: "Select a session to view details",
		.sessionCreate: "New Session",
		.sessionDelete: "Delete Session",
		.sessionDeleteConfirm: "Delete this session? All messages will be lost.",
		.sessionSummary: "Session Summary",
		.sessionModel: "Model",
		.sessionCreatedAt: "Started",
		.sessionMessageCount: "Messages",
		.sessionTokenCount: "Tokens",
		.memoryTitle: "Memory Events",
		.memoryEmpty: "No memory events",
		.memorySearchPlaceholder: "Search memory...",

		// Skills
		.tabSkills: "Skills",
		.skillListEmpty: "No skills registered",
		.skillSelectHint: "Select a skill to view details",
		.skillName: "Name",
		.skillCategory: "Category",
		.skillDescription: "Description",
		.skillTags: "Tags",
		.skillContentTitle: "Content",
		.skillDependencies: "Dependencies",

		// System
		.tabSystem: "System",
		.systemMCPSection: "MCP Servers",
		.systemMCPEmpty: "No MCP servers connected",
		.systemMCPConnected: "Connected",
		.systemMCPDisconnected: "Disconnected",
		.systemMCPName: "Server",
		.systemMCPCommand: "Command",
		.systemToolsSection: "Tools",
		.systemToolsEmpty: "No tools registered",
		.systemToolName: "Tool",
		.systemToolReadOnly: "Read-only",
		.systemToolDestructive: "Destructive",
		.systemAuditSection: "Audit Trail",
		.systemAuditEmpty: "No audit entries",
		.systemAuditTool: "Tool",
		.systemAuditCaller: "Caller",
		.systemAuditDuration: "Duration",
		.systemAuditStatus: "Status",
		.systemReasoningSection: "Reasoning Pipeline",
		.systemComplexityScore: "Complexity Score",
		.systemThinkingBudget: "Thinking Budget",
		.systemRefresh: "Refresh",
		.systemClearAudit: "Clear Audit Log",
		.systemClearAuditConfirm: "Clear all audit trail entries?",	]

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

		// Accessibility Labels
		.appLabel: "ocoreai",
		.appTitle: "ocoreai",
		.noPanelSelected: "未选择面板",
		.selectTab: "选择",
		.modelSelectorLabel: "模型选择器",
		.modelSelectorValueDefault: "未选择模型",
		.clearConversationLabel: "清空对话",
		.clearConversationHint: "移除此对话的所有消息",
		.chatLabel: "聊天",
		.chatConnected: "本地后端已连接",
		.chatLoading: "后端加载中",
		.messagesLabel: "消息",
		.assistantTyping: "助手正在输入",
		.voiceInputLabel: "语音输入",
		.voiceInputHint: "点击使用语音输入（即将推出）",
		.messageInputLabel: "消息输入框",
		.messageInputHint: "输入消息后按回车发送",
		.stopStreamingLabel: "停止流式输出",
		.stopStreamingHint: "点击停止当前回复",
		.sendMessageLabel: "发送消息",
		.sendMessageHint: "点击发送你的消息",
		.youLabel: "你",
		.ocoreaiLabel: "ocoreai",
		.suggestionHint: "点击使用此建议作为你的消息",
		.localLabel: "本地",
		.dashboardLabel: "仪表盘",
		.systemInfoLabel: "系统信息",
		.areaGraphTokenDesc: "显示 Token 吞吐量随时间变化的区域图",
		.areaGraphGpuDesc: "显示 GPU 显存使用随时间变化的区域图",
		.kvCacheLineDesc: "KV 缓存使用量折线图",
		.refreshModelLabel: "刷新模型列表",
		.refreshModelHint: "从后端获取最新模型列表",
		.contextKey: "上下文",
		.tokenizerKey: "分词器",
		.modelRunningLabel: "模型运行中",
		.multimodalControlsLabel: "多模态控制",
		.enableCameraLabel: "启用摄像头",
		.enableCameraHint: "打开或关闭摄像头",
		.cameraPreviewLabel: "摄像头实时画面预览",
		.captureFrameLabel: "捕获帧",
		.captureFrameHint: "从摄像头拍摄快照",
		.enableMicLabel: "启用麦克风",
		.enableMicHint: "打开或关闭麦克风",
		.stopRecordingLabel: "停止录音",
		.stopRecordingHint: "停止当前录音",
		.startRecordingLabel: "开始录音",
		.startRecordingHint: "开始录制音频",
		.lastTranscriptLabel: "最后语音识别结果",
		.enableSpeakerLabel: "启用扬声器",
		.enableSpeakerHint: "打开或关闭语音合成",
		.ttsActiveLabel: "语音合成已激活",
		.statusIndicatorsLabel: "多模态状态指示器",

		// Status dot labels
		.statusCameraActive: "摄像头活动中",
		.statusRecording: "录音中",
		.statusSpeaking: "语音播放中",
		.statusActive: "活动中",
		.statusInactive: "非活动",

		// A11y templates
		.a11yStatus: "状态",
		.a11yModel: "模型",

		// Settings / About
		.aboutTitle: "ocoreai",
		.aboutVersion: "v1.0.0 · macOS 15+ / iOS 17+",

		// Model info
		.modelInfoContext: "上下文",
		.modelInfoTokenizer: "分词器",

		// Chart
		.chartTime: "时间",
		.chartTokPerSec: "tok/s",
		.chartGB: "GB",

		// Models
		.defaultModel: "默认",
		.noModelSelected: "未选择模型",
		.clear: "清空",
		.refreshButton: "刷新",
		.tryAgain: "重试",
		.copyMessage: "复制消息",
		.undoAction: "撤销",

		// Sessions
		.tabSessions: "会话",
		.sessionSearchPlaceholder: "搜索会话...",
		.sessionListEmpty: "暂无会话",
		.sessionSelectHint: "选择会话查看详情",
		.sessionCreate: "新建会话",
		.sessionDelete: "删除会话",
		.sessionDeleteConfirm: "确定删除此会话？所有消息将丢失。",
		.sessionSummary: "会话摘要",
		.sessionModel: "模型",
		.sessionCreatedAt: "开始于",
		.sessionMessageCount: "消息",
		.sessionTokenCount: "Token 数",
		.memoryTitle: "记忆事件",
		.memoryEmpty: "暂无记忆事件",
		.memorySearchPlaceholder: "搜索记忆...",

		// Skills
		.tabSkills: "技能",
		.skillListEmpty: "暂无技能",
		.skillSelectHint: "选择技能查看详情",
		.skillName: "名称",
		.skillCategory: "分类",
		.skillDescription: "描述",
		.skillTags: "标签",
		.skillContentTitle: "内容",
		.skillDependencies: "依赖",

		// System
		.tabSystem: "系统",
		.systemMCPSection: "MCP 服务",
		.systemMCPEmpty: "未连接 MCP 服务",
		.systemMCPConnected: "已连接",
		.systemMCPDisconnected: "未连接",
		.systemMCPName: "服务名称",
		.systemMCPCommand: "命令",
		.systemToolsSection: "工具",
		.systemToolsEmpty: "暂无工具",
		.systemToolName: "工具",
		.systemToolReadOnly: "只读",
		.systemToolDestructive: "破坏性",
		.systemAuditSection: "审计日志",
		.systemAuditEmpty: "暂无审计记录",
		.systemAuditTool: "工具",
		.systemAuditCaller: "调用者",
		.systemAuditDuration: "耗时",
		.systemAuditStatus: "状态",
		.systemReasoningSection: "推理管线",
		.systemComplexityScore: "复杂度评分",
		.systemThinkingBudget: "思考预算",
		.systemRefresh: "刷新",
		.systemClearAudit: "清空审计日志",
		.systemClearAuditConfirm: "清空所有审计记录？",

		// Per-model inference params
		.modelParamsTitle: "推理参数",
		.modelParamTemperature: "温度",
		.modelParamTemperatureHint: "控制随机性 (0.0–2.0)",
		.modelParamTopP: "Top P",
		.modelParamTopPHint: "核采样阈值",
		.modelParamTopK: "Top K",
		.modelParamTopKHint: "保留 K 个最可能的 token",
		.modelParamMaxTokens: "最大 Token 数",
		.modelParamMaxTokensHint: "最大输出 token 数",
		.modelParamRepeatPenalty: "重复惩罚",
		.modelParamRepeatPenaltyHint: "重复 token 的惩罚系数",
		.modelParamFrequencyPenalty: "频率惩罚",
		.modelParamPresencePenalty: "存在惩罚",
		.modelParamSave: "保存",
		.modelParamReset: "恢复默认",
		.modelParamDefaults: "默认值",
		.modelViewTapToEdit: "点击编辑参数",
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
