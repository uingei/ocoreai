// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// Models ViewModel — independent .task{await load()} pattern.
/// Transient APIClient, screen-state machine, no shared singleton coupling.
///
/// @Observable pattern (Swift 5.9+): property-level change tracking.

import Foundation
import SwiftUI

@MainActor
final class ModelsState: Observable {
    var state: ViewState<[APIClient.ModelEntry]> = .idle
    var loading: Bool = false
    var error: Error?

    private var client: APIClient

    init(client: @escaping () -> APIClient = { APIClient.shared }) {
        self.client = client()
    }

    func fetchModels() async {
        await MainActor.run {
            state = .loading
            loading = true
            error = nil
        }
        let models = await client.listModels()
        await MainActor.run {
            state = .success(models)
            loading = false
        }
    }
}
