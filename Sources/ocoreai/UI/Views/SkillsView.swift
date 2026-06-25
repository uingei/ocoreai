// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Skills View — skill list, categories, and detail
/// Accessibility: VoiceOver labels, hints, groups

import SwiftUI

struct SkillsView: View {
    @State private var viewModel = SkillsState()
    @Environment(\.ocoreaiTheme) private var theme

    var body: some View {
        Form {
            if !viewModel.categories.isEmpty {
                categoryFilterSection()
            }
            skillsListSection()
            if let skill = viewModel.selectedSkill {
                skillDetailSection(skill)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(StringKey.tabSkills.l)
        .overlay {
            if viewModel.isLoading {
                ProgressView(StringKey.loadingModels.l)
            }
        }
        .onAppear {
            Task { await viewModel.load() }
        }
        .accessibilityLabel(StringKey.tabSkills.l)
    }

    // MARK: - Category Filter

    @ViewBuilder
    private func categoryFilterSection() -> some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    CategoryButton(
                        title: StringKey.skillAll.l,
                        isSelected: viewModel.selectedCategory == nil
                    ) {
                        viewModel.filterByCategory(nil)
                    }

                    ForEach(viewModel.categories.sorted(), id: \.self) { category in
                        CategoryButton(
                            title: category,
                            isSelected: viewModel.selectedCategory == category
                        ) {
                            viewModel.filterByCategory(category)
                        }
                    }
                }
                .padding(.horizontal)
            }
        } footer: {
            EmptyView()
        }
    }

    // MARK: - Skills List

    @ViewBuilder
    private func skillsListSection() -> some View {
        if viewModel.filteredSkills.isEmpty {
            Section {
                Text(StringKey.skillListEmpty.l)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } header: {
                Text(StringKey.tabSkills.l)
            } footer: {
                EmptyView()
            }
        } else {
            Section {
                ForEach(viewModel.filteredSkills, id: \.path) { skill in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(skill.name)
                                .font(.ocoreaiText(15, weight: .medium))
                                .foregroundStyle(theme.text)
                            if !skill.description.isEmpty {
                                Text(skill.description)
                                    .font(.ocoreaiText(12))
                                    .foregroundStyle(theme.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                        .accessibilityLabel("\(skill.name): \(skill.description)")
                        Spacer()
                        Label(skill.category, systemImage: "cube.box")
                            .font(.ocoreaiText(11))
                            .foregroundStyle(theme.accent)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.select(skill) }
                    .accessibilityAddTraits(.isButton)
                }
            } header: {
                Text(StringKey.tabSkills.l)
            } footer: {
                EmptyView()
            }
        }
    }

    // MARK: - Skill Detail

    @ViewBuilder
    private func skillDetailSection(_ skill: Skill) -> some View {
        Section {
            LabeledContent(StringKey.skillName.l) { Text(skill.name) }
            LabeledContent(StringKey.skillCategory.l) { Text(skill.category) }
            LabeledContent(StringKey.skillDescription.l) {
                Text(skill.description).font(.ocoreaiText(12))
            }

            if !skill.metadata.tags.isEmpty {
                LabeledContent(StringKey.skillTags.l) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(skill.metadata.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.ocoreaiText(11))
                                    .padding(4)
                                    .background(theme.cardBg, in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                }
            }

            if !skill.metadata.dependencies.isEmpty {
                LabeledContent(StringKey.skillDependencies.l) {
                    Text(skill.metadata.dependencies.joined(separator: ", "))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(StringKey.skillContentTitle.l)
                    .font(.ocoreaiText(12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Text(skill.body)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(8)
            }
            .padding(.vertical, 4)
        } header: {
            Text(StringKey.skillContentTitle.l)
        } footer: {
            EmptyView()
        }
    }
}

// MARK: - Category Button

private struct CategoryButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.ocoreaiTheme) private var theme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ocoreaiText(12, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isSelected ? theme.accent : theme.cardBg,
                    in: Capsule()
                )
                .foregroundStyle(
                    isSelected ? .white : theme.text
                )
        }
        .buttonStyle(.plain)
    }
}
