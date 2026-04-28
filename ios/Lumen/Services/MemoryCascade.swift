import Foundation
import SwiftData

nonisolated struct MemoryCascadeResult: Sendable {
    let ephemeral: [String]
    let vectorized: [String]
    let condensed: [String]

    var promptFragments: [String] {
        var fragments: [String] = []
        if !ephemeral.isEmpty { fragments.append(contentsOf: ephemeral) }
        if !vectorized.isEmpty { fragments.append(contentsOf: vectorized) }
        if !condensed.isEmpty { fragments.append(contentsOf: condensed) }
        return fragments
    }
}

@MainActor
enum MemoryCascade {
    static func recall(
        query: String,
        history: [(role: MessageRole, content: String)],
        context: ModelContext
    ) async -> MemoryCascadeResult {
        let tier1 = history
            .suffix(12)
            .compactMap { item -> String? in
                let compact = compactAndTrim(item.content, maxLength: 260)
                guard !compact.isEmpty else { return nil }
                return "Tier 1 Ephemeral: \(compact)"
            }

        let tier2 = await MemoryStore.recall(query: query, context: context, limit: 8)
            .filter { $0.source != "rem-condensed" }
            .compactMap { item -> String? in
                let compact = compactAndTrim(item.content, maxLength: 260)
                guard !compact.isEmpty else { return nil }
                return "Tier 2 Vectorized: \(compact)"
            }

        let queryTokens = tokenSet(query)
        let condensedDescriptor = FetchDescriptor<MemoryItem>(
            predicate: #Predicate<MemoryItem> { $0.source == "rem-condensed" }
        )
        let condensedItems = (try? context.fetch(condensedDescriptor)) ?? []

        let rankedTier3 = condensedItems
            .map { item in
                (
                    item: item,
                    overlap: overlapScore(tokens: queryTokens, content: item.content)
                )
            }
            .sorted { lhs, rhs in
                if lhs.overlap != rhs.overlap { return lhs.overlap > rhs.overlap }
                return lhs.item.createdAt > rhs.item.createdAt
            }
            .prefix(8)
            .compactMap { pair -> String? in
                let compact = compactAndTrim(pair.item.content, maxLength: 260)
                guard !compact.isEmpty else { return nil }
                return "Tier 3 Condensed: \(compact)"
            }

        return MemoryCascadeResult(
            ephemeral: tier1,
            vectorized: tier2,
            condensed: Array(rankedTier3)
        )
    }

    private static func compactAndTrim(_ text: String, maxLength: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return "" }
        if normalized.count <= maxLength { return normalized }
        let end = normalized.index(normalized.startIndex, offsetBy: maxLength)
        return String(normalized[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func tokenSet(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        var tokens: Set<String> = []
        var current = ""

        for scalar in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                if current.count >= 2 {
                    tokens.insert(current)
                }
                current.removeAll(keepingCapacity: true)
            }
        }

        if current.count >= 2 {
            tokens.insert(current)
        }

        return tokens
    }

    private static func overlapScore(tokens queryTokens: Set<String>, content: String) -> Int {
        guard !queryTokens.isEmpty else { return 0 }
        let memoryTokens = tokenSet(content)
        return queryTokens.intersection(memoryTokens).count
    }
}
