import Foundation
import SwiftData

@MainActor
enum MemoryRecall {
    static func recallAndNormalize(
        query: String,
        routing: IntentRoutingDecision,
        context: ModelContext,
        limit: Int = 8
    ) async -> [MemoryContextItem] {
        let raw = await MemoryStore.recall(query: query, context: context, limit: limit).map(\.content)
        let filtered = raw.filter { memory in
            FinalIntentValidator.validate(memory, routing: routing, fallback: nil) == memory.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return MemoryContextAdapter.fromLegacyStrings(filtered)
    }
}
