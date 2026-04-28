import Foundation
import SwiftData

struct MemoryCascadeResult {
    let promptFragments: [String]
}

@MainActor
enum MemoryCascade {
    static func recall(
        query: String,
        history: [(role: MessageRole, content: String)],
        context: ModelContext
    ) async -> MemoryCascadeResult {
        _ = history
        let memories = await MemoryStore.recall(query: query, context: context).map(\.content)
        return MemoryCascadeResult(promptFragments: memories)
    }
}
