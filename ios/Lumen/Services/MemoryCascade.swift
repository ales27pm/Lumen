import Foundation
import SwiftData

struct MemoryCascadeResult {
    let promptFragments: [String]
}

@MainActor
enum MemoryCascade {
    static func recall(
        query: String,
        _: [(role: MessageRole, content: String)],
        context: ModelContext
    ) async -> MemoryCascadeResult {
        let memories = await MemoryStore.recall(query: query, context: context).map(\.content)
        return MemoryCascadeResult(promptFragments: memories)
    }
}
