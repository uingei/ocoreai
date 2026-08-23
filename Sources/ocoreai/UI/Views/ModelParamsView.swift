// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelParamsView — Per-model inference parameter editor.
/// i18n via StringKey. Full VoiceOver accessibility.

import SwiftUI

// MARK: - Root View

struct ModelParamsView: View {
    let modelId: String
    let onCancel: () -> Void
    @State private var config: ModelSamplingConfig
    @State private var topKText: String = ""
    @State private var maxTokensText: String = ""
    @State private var seedText: String = ""
    @State private var maxKVText: String = ""
    @State private var repeatWindowText: String = ""
    @Environment(\.ocoreaiTheme) private var theme

    init(modelId: String, onCancel: @escaping () -> Void = {}) {
        self.modelId = modelId
        self.onCancel = onCancel
        let store = SettingsStore.shared
        let cfg = store.loadSamplingConfig(for: modelId)
        _config = State(initialValue: cfg)
        _topKText = State(initialValue: cfg.topK.map(String.init) ?? "")
        _maxTokensText = State(initialValue: cfg.maxTokens.map(String.init) ?? "")
        _seedText = State(initialValue: cfg.seed.map(String.init) ?? "")
        _maxKVText = State(initialValue: cfg.maxKVSize.map(String.init) ?? "")
        _repeatWindowText = State(initialValue: cfg.repetitionPenaltyWindow.map(String.init) ?? "")
    }

    var body: some View {
        ScrollView {
            innerBody
                .padding(20)
        }
        .background(theme.windowBg)
        .accessibilityLabel(StringKey.modelParamsTitle.l)
    }

    private var innerBody: some View {
        VStack(alignment: .leading, spacing: 24) {
            headerBar
            temperatureCard
            topPCard
            topKCard
            maxTokensCard
            frequencyPenaltyCard
            presencePenaltyCard
            repetitionPenaltyCard
            repetitionWindowCard
            minPCard
            seedCard
            maxKVCard
            repeatContextCard
            presenceContextCard
            frequencyContextCard
            actionRow
            Spacer(minLength: 24)
        }
    }

    /// Display-safe model name: strips mscope: / hf: prefix for user clarity
    private var displayName: String {
        modelId.progressKey
    }

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(StringKey.modelParamsTitle.l)
                    .font(.ocoreaiText(18, weight: .bold))
                    .foregroundStyle(theme.text)
                Text(displayName)
                    .font(.ocoreaiText(13))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(StringKey.clear.l) { onCancel() }
                .ocoreaiButton(.normal, size: .small)
        }
    }

    private var temperatureCard: some View {
        SliderAutoSaveView(
            label: StringKey.modelParamTemperature.l,
            hint: StringKey.modelParamTemperatureHint.l,
            display: String(format: "%.2f", config.temperature),
            value: $config.temperature,
            range: 0 ... 2,
            autoSave: { autoSave() },
        )
    }

    private var topPCard: some View {
        SliderAutoSaveView(
            label: StringKey.modelParamTopP.l,
            hint: StringKey.modelParamTopPHint.l,
            display: config.topP.map { String(format: "%.2f", $0) }
                ?? StringKey.modelParamDefaults.l,
            value: Binding(
                get: { config.topP ?? 0.95 },
                set: {
                    config.topP = $0
                    autoSave()
                },
            ),
            range: 0 ... 1,
            hasReset: true,
            resetAction: {
                config.topP = nil
                autoSave()
            },
            autoSave: {},
        )
    }

    private var topKCard: some View {
        TextFieldParamView(
            label: StringKey.modelParamTopK.l,
            hint: StringKey.modelParamTopKHint.l,
            valueText: config.topK.map(String.init) ?? StringKey.modelParamDefaults.l,
            textBinding: $topKText,
            onDone: {
                config.topK = max(Int(topKText) ?? 1, 1)
                autoSave()
            },
            resetAction: {
                config.topK = nil
                topKText = ""
                autoSave()
            },
        )
    }

    private var maxTokensCard: some View {
        TextFieldParamView(
            label: StringKey.modelParamMaxTokens.l,
            hint: StringKey.modelParamMaxTokensHint.l,
            valueText: config.maxTokens.map(String.init) ?? StringKey.modelParamDefaults.l,
            textBinding: $maxTokensText,
            onDone: {
                config.maxTokens = max(Int(maxTokensText) ?? 1, 1)
                autoSave()
            },
            resetAction: {
                config.maxTokens = nil
                maxTokensText = ""
                autoSave()
            },
        )
    }

    private var frequencyPenaltyCard: some View {
        SliderAutoSaveView(
            label: StringKey.modelParamFrequencyPenalty.l,
            hint: nil,
            display: String(format: "%.2f", config.frequencyPenalty),
            value: $config.frequencyPenalty,
            range: -2 ... 2,
            autoSave: { autoSave() },
        )
    }

    private var presencePenaltyCard: some View {
        SliderAutoSaveView(
            label: StringKey.modelParamPresencePenalty.l,
            hint: nil,
            display: String(format: "%.2f", config.presencePenalty),
            value: $config.presencePenalty,
            range: -2 ... 2,
            autoSave: { autoSave() },
        )
    }

    /// Repetition penalty (#176, coreai-models 5660fc6): nil = unset, > 1.0 active.
    private var repetitionPenaltyCard: some View {
        SliderAutoSaveView(
            label: StringKey.modelParamRepeatPenalty.l,
            hint: StringKey.modelParamRepeatPenaltyHint.l,
            display: config.repetitionPenalty.map { String(format: "%.2f", $0) }
                ?? StringKey.modelParamDefaults.l,
            value: Binding(
                get: { config.repetitionPenalty.map(Float.init) ?? 1.0 },
                set: {
                    config.repetitionPenalty = Double($0)
                    autoSave()
                },
            ),
            range: 1 ... 2,
            hasReset: true,
            resetAction: {
                config.repetitionPenalty = nil
                autoSave()
            },
            autoSave: {},
        )
    }

    private var repetitionWindowCard: some View {
        TextFieldParamView(
            label: StringKey.modelParamRepeatWindow.l,
            hint: StringKey.modelParamRepeatWindowHint.l,
            valueText: config.repetitionPenaltyWindow.map(String.init)
                ?? StringKey.modelParamDefaults.l,
            textBinding: $repeatWindowText,
            onDone: {
                config.repetitionPenaltyWindow = max(Int(repeatWindowText) ?? 1, 1)
                autoSave()
            },
            resetAction: {
                config.repetitionPenaltyWindow = nil
                repeatWindowText = ""
                autoSave()
            },
        )
    }

    private var minPCard: some View {
        SliderAutoSaveView(
            label: StringKey.modelParamMinP.l,
            hint: StringKey.modelParamMinPHint.l,
            display: config.minP.map { String(format: "%.2f", $0) }
                ?? StringKey.modelParamDefaults.l,
            value: Binding(
                get: { config.minP ?? 0.5 },
                set: {
                    config.minP = $0
                    autoSave()
                },
            ),
            range: 0 ... 1,
            hasReset: true,
            resetAction: {
                config.minP = nil
                autoSave()
            },
            autoSave: {},
        )
    }

    private var seedCard: some View {
        TextFieldParamView(
            label: StringKey.modelParamSeed.l,
            hint: StringKey.modelParamSeedHint.l,
            valueText: config.seed.map(String.init) ?? StringKey.modelParamDefaults.l,
            textBinding: $seedText,
            onDone: {
                config.seed = Int64(seedText)
                autoSave()
            },
            resetAction: {
                config.seed = nil
                seedText = ""
                autoSave()
            },
        )
    }

    private var maxKVCard: some View {
        TextFieldParamView(
            label: StringKey.modelParamMaxKV.l,
            hint: StringKey.modelParamMaxKVHint.l,
            valueText: config.maxKVSize.map(String.init) ?? StringKey.modelParamDefaults.l,
            textBinding: $maxKVText,
            onDone: {
                config.maxKVSize = max(Int(maxKVText) ?? 1, 1)
                autoSave()
            },
            resetAction: {
                config.maxKVSize = nil
                maxKVText = ""
                autoSave()
            },
        )
    }

    // MARK: - Context-window group (non-optional, default 20)

    private var repeatContextCard: some View {
        contextSizeCard(
            label: StringKey.modelParamRepeatCtx.l,
            hint: StringKey.modelParamRepeatCtxHint.l,
            value: Binding(
                get: { Float(config.repetitionContextSize) },
                set: { config.repetitionContextSize = max(Int($0), 1) },
            ),
        )
    }

    private var presenceContextCard: some View {
        contextSizeCard(
            label: StringKey.modelParamPresenceCtx.l,
            hint: StringKey.modelParamPresenceCtxHint.l,
            value: Binding(
                get: { Float(config.presenceContextSize) },
                set: { config.presenceContextSize = max(Int($0), 1) },
            ),
        )
    }

    private var frequencyContextCard: some View {
        contextSizeCard(
            label: StringKey.modelParamFrequencyCtx.l,
            hint: StringKey.modelParamFrequencyCtxHint.l,
            value: Binding(
                get: { Float(config.frequencyContextSize) },
                set: { config.frequencyContextSize = max(Int($0), 1) },
            ),
        )
    }

    private func contextSizeCard(label: String, hint: String, value: Binding<Float>) -> some View {
        SliderAutoSaveView(
            label: label,
            hint: hint,
            display: String(Int(value.wrappedValue)),
            value: value,
            range: 1 ... 256,
            autoSave: { autoSave() },
        )
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button(StringKey.modelParamReset.l) {
                Task {
                    let store = SettingsStore.shared
                    await store.resetSamplingConfig(for: modelId)
                    config = .default
                }
            }
            .ocoreaiButton(.normal, size: .regular)
            Spacer()
            Button(StringKey.modelParamSave.l) {
                Task {
                    let store = SettingsStore.shared
                    await store.saveSamplingConfig(config, for: modelId)
                    onCancel()
                }
            }
            .ocoreaiButton(.primary, size: .regular)
        }
    }

    @MainActor
    private func autoSave() {
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let store = SettingsStore.shared
            await store.saveSamplingConfig(config, for: modelId)
        }
    }
}

// MARK: - Slider Card with auto-save callback

private struct SliderAutoSaveView: View {
    @Environment(\.ocoreaiTheme) private var theme
    let label: String
    let hint: String?
    let display: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let hasReset: Bool
    let resetAction: (() -> Void)?
    let autoSave: () -> Void

    init(
        label: String,
        hint: String?,
        display: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        hasReset: Bool = false,
        resetAction: (() -> Void)? = nil,
        autoSave: @escaping () -> Void,
    ) {
        self.label = label
        self.hint = hint
        self.display = display
        _value = value
        self.range = range
        self.hasReset = hasReset
        self.resetAction = resetAction
        self.autoSave = autoSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.ocoreaiText(14, weight: .semibold))
                Spacer()
                Text(display)
                    .font(.ocoreaiText(14, weight: .medium))
                    .foregroundStyle(theme.accent)
            }
            if let hint {
                Text(hint)
                    .font(.ocoreaiText(11))
                    .foregroundStyle(theme.textTertiary)
            }
            HStack(spacing: 8) {
                if hasReset {
                    Button(StringKey.modelParamDefaults.l) { resetAction?() }
                        .ocoreaiButton(.normal, size: .small)
                    Spacer()
                }
                Slider(value: $value, in: range)
                    .accentColor(theme.accent)
                    .onChange(of: value) { _, _ in
                        autoSave()
                    }
            }
        }
        .padding(16)
        .modifier(theme.cardStyle())
    }
}

// MARK: - TextField Card (TopK / MaxTokens)

private struct TextFieldParamView: View {
    @Environment(\.ocoreaiTheme) private var theme
    let label: String
    let hint: String?
    let valueText: String
    @Binding var textBinding: String
    var onDone: () -> Void
    var resetAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.ocoreaiText(14, weight: .semibold))
                Text(valueText)
                    .font(.ocoreaiText(14, weight: .medium))
                    .foregroundStyle(theme.accent)
                if let hint {
                    Text(hint)
                        .font(.ocoreaiText(11))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button(StringKey.modelParamDefaults.l) { resetAction() }
                    .ocoreaiButton(.normal, size: .small)
                TextField(StringKey.paramPlaceholder.l, text: $textBinding)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    .textContentType(.oneTimeCode)
                    .onSubmit {
                        onDone()
                    }
            }
        }
        .padding(16)
        .modifier(theme.cardStyle())
    }
}
