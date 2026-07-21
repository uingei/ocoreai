// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Skills ViewModel — bridges SkillRegistry with SwiftUI

import Foundation
import Observation

@Observable
@MainActor
final class SkillsState {
    private(set) var skills: [Skill] = []
    private(set) var categories: Set<String> = []
    private(set) var selectedSkill: Skill?
    private(set) var filteredSkills: [Skill] = []

    var selectedCategory: String?
    var isLoading: Bool = false
    var errorMessage: String?

    private var registryRef: SkillRegistry? {
        OcoreaiEngine.shared.activeSkillRegistry
    }

    func load() async {
        guard let registry = registryRef else {
            errorMessage = StringKey.skillRegistryUnavailable.l
            return
        }
        isLoading = true
        defer { isLoading = false }

        skills = await registry.resolvedSkills()
        categories = Set(skills.map(\.category))
        filteredSkills = skills
    }

    func select(_ skill: Skill) {
        selectedSkill = skill
    }

    func filterByCategory(_ category: String?) {
        selectedCategory = category
        if let category {
            filteredSkills = skills.filter { $0.category == category }
        } else {
            filteredSkills = skills
        }
    }
}
