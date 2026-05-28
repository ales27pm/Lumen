import Foundation
import SwiftData

@MainActor
struct LegacyGroundingContextProvider {
    var directContext: ModelContext?

    func resolveContext() -> ModelContext? {
        if let directContext { return directContext }
        if let shared = SharedContainer.shared { return ModelContext(shared) }
        return nil
    }

    var degradedReason: String? {
        resolveContext() == nil ? "model_context_unavailable" : nil
    }
}
