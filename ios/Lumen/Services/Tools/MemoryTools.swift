import Foundation
import SwiftData

@MainActor
enum MemoryTools {
    static func save(content: String, kind: String) async -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Need content." }
        let k = MemoryKind(rawValue: kind) ?? .fact
        guard let container = SharedContainer.shared else { return "Memory unavailable." }
        let ctx = ModelContext(container)
        await MemoryStore.remember(trimmed, kind: k, source: "agent", context: ctx)
        return "Saved: \(trimmed)"
    }

    static func recall(query: String) async -> String {
        guard let container = SharedContainer.shared else { return "Memory unavailable." }
        let ctx = ModelContext(container)
        let items = await MemoryStore.recall(query: query, context: ctx, limit: 5)
        if items.isEmpty { return "No matching memories." }
        return items.map { "• \($0.content)" }.joined(separator: "\n")
    }

    static func ragSearch(query: String, limit: Int) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Need a search query." }
        guard let container = SharedContainer.shared else { return "RAG store unavailable." }
        let ctx = ModelContext(container)
        let expandedQuery = expandRAGQueryIfNeeded(trimmed)
        let results = await RAGStore.search(query: expandedQuery, context: ctx, limit: limit)
        if results.isEmpty {
            let counts = RAGStore.counts(context: ctx)
            let totalIndexed = counts.values.reduce(0, +)
            if totalIndexed == 0 {
                return "No matching files found for '\(trimmed)'. Your local index appears empty. Import or create local files/notes, then run reindex files."
            }
            return "No matching files found for '\(trimmed)'. Try a narrower query (file name, module name, or service/component keywords), or add more project notes before searching again."
        }
        return results.enumerated().map { idx, r in
            let src = "\(r.chunk.kind.label) · \(r.chunk.sourceName)"
            let snippet = r.chunk.content.prefix(300)
            return "[\(idx + 1)] \(src)\n\(snippet)"
        }.joined(separator: "\n\n")
    }


    private static func expandRAGQueryIfNeeded(_ query: String) -> String {
        let lower = query.lowercased()
        let shouldExpand = ["architecture notes", "architecture", "module", "service", "component", "package"].contains { lower.contains($0) }
        guard shouldExpand else { return query }
        let expansionTerms = ["architecture", "module", "service", "component", "package"]
        return query + " " + expansionTerms.joined(separator: " ")
    }

    static func ragIndexFiles() async -> String {
        guard let container = SharedContainer.shared else { return "Store unavailable." }
        let ctx = ModelContext(container)
        let n = await RAGStore.indexImportedFiles(context: ctx)
        return "Indexed \(n) chunks from imported files."
    }

    static func ragIndexPhotos(months: Int) async -> String {
        guard let container = SharedContainer.shared else { return "Store unavailable." }
        let ctx = ModelContext(container)
        let n = await RAGStore.indexPhotos(monthsBack: max(1, months), context: ctx)
        if n == 0 { return "Couldn't index photos (permission denied or empty library)." }
        return "Indexed \(n) monthly photo summaries."
    }
}
