import Foundation
import SwiftData

struct MemoryContextResult: Sendable {
    let selected: [MemoryItem]
    let totalChars: Int
    let reasons: [UUID: String]
    let sourceIDs: [UUID]
}

enum MemoryContextBuilder {
    @MainActor
    static func build(query: String, budgetChars: Int, context: ModelContext) -> MemoryContextResult {
        let all = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
        let q = query.lowercased()
        let ranked = all.sorted { a,b in
            score(a,q) > score(b,q)
        }
        var picked: [MemoryItem] = []
        var reasons: [UUID:String] = [:]
        var chars = 0
        for m in ranked {
            let c = min(220, m.content.count)
            if chars + c > budgetChars { continue }
            picked.append(m); chars += c
            reasons[m.id] = m.isPinned ? "pinned" : (m.content.lowercased().contains(q) ? "query-match" : "recency")
        }
        return .init(selected: picked, totalChars: chars, reasons: reasons, sourceIDs: picked.map(\.id))
    }

    private static func score(_ m: MemoryItem, _ q: String) -> Double {
        var s = 0.0
        if m.isPinned { s += 1.5 }
        if m.content.lowercased().contains(q) { s += 1 }
        if m.topic?.lowercased().contains(q) == true { s += 0.6 }
        s += max(0, 0.3 - Date().timeIntervalSince(m.createdAt)/(60*60*24*365))
        return s
    }
}
