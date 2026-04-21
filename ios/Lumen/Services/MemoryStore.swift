import Foundation
import SwiftData

@MainActor
enum MemoryStore {
    static func recall(query: String, context: ModelContext, limit: Int = 5) async -> [MemoryItem] {
        let queryVec = await LlamaService.shared.embed(text: query)
        let descriptor = FetchDescriptor<MemoryItem>()
        guard let all = try? context.fetch(descriptor), !all.isEmpty else { return [] }
        // Score all items; apply a pin bonus so pinned items blend into the ranking
        // rather than always crowding out more relevant unpinned items.
        let pinBonus = 0.15
        let scored: [(MemoryItem, Double)] = all.map { item in
            let base = cosine(queryVec, item.embedding)
            let boosted = item.isPinned ? base + pinBonus : base
            return (item, boosted)
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    static func remember(_ content: String, kind: MemoryKind = .fact, source: String = "manual", topic: String? = nil, context: ModelContext) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Dedup near-identical memories
        if let existing = try? context.fetch(FetchDescriptor<MemoryItem>()) {
            if existing.contains(where: { $0.content.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                return
            }
        }
        let embedding = await LlamaService.shared.embed(text: trimmed)
        let item = MemoryItem(content: trimmed, kind: kind, source: source, embedding: embedding, topic: topic)
        context.insert(item)
        try? context.save()
    }

    static func extractAndStore(userText: String, assistantText: String, context: ModelContext) async {
        let combined = userText + "\n" + assistantText
        for extracted in extractFacts(from: combined) {
            await remember(extracted.content, kind: extracted.kind, source: "auto", topic: extracted.topic, context: context)
        }
    }

    static func wipeAll(context: ModelContext) {
        guard let all = try? context.fetch(FetchDescriptor<MemoryItem>()) else { return }
        for item in all where !item.isPinned {
            context.delete(item)
        }
        try? context.save()
    }

    static func wipeEverything(context: ModelContext) {
        guard let all = try? context.fetch(FetchDescriptor<MemoryItem>()) else { return }
        for item in all { context.delete(item) }
        try? context.save()
    }

    static func exportJSON(context: ModelContext) -> String {
        guard let all = try? context.fetch(FetchDescriptor<MemoryItem>()) else { return "[]" }
        struct Export: Codable { let content: String; let kind: String; let topic: String?; let pinned: Bool; let createdAt: Date }
        let items = all.map { Export(content: $0.content, kind: $0.kind, topic: $0.topic, pinned: $0.isPinned, createdAt: $0.createdAt) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return (try? String(data: enc.encode(items), encoding: .utf8)) ?? "[]"
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot
    }

    // MARK: - Fact extraction (lightweight, rule-based)

    nonisolated struct Extracted {
        let content: String
        let kind: MemoryKind
        let topic: String?
    }

    nonisolated static func extractFacts(from text: String) -> [Extracted] {
        var results: [Extracted] = []
        let sentences = text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let prefLove = ["i love", "i like", "i enjoy", "i prefer", "my favorite", "i'm a fan of", "i am a fan of"]
        let prefHate = ["i hate", "i dislike", "i don't like", "i do not like", "i can't stand"]
        let factSelf = ["i am", "i'm", "i live", "i work", "my name is", "i was born", "i have", "my birthday"]
        let projectMarkers = ["working on", "building", "my project", "my app", "my startup"]
        let personMarkers: [(String, String)] = [
            (#"my (wife|husband|partner|boyfriend|girlfriend|mom|mother|dad|father|brother|sister|son|daughter|friend|boss|manager|teammate|colleague|neighbor|dog|cat) (?:is |named |'s name is |'s )?([A-Z][a-z]+)"#, "relation")
        ]

        var seen: Set<String> = []
        func push(_ e: Extracted) {
            let key = e.content.lowercased()
            if seen.contains(key) { return }
            seen.insert(key)
            results.append(e)
        }
        for s in sentences {
            let lower = s.lowercased()
            if prefLove.contains(where: { lower.contains($0) }) {
                push(Extracted(content: "User preference: \(cleaned(s))", kind: .preference, topic: nil))
                continue
            }
            if prefHate.contains(where: { lower.contains($0) }) {
                push(Extracted(content: "User dislike: \(cleaned(s))", kind: .preference, topic: nil))
                continue
            }
            if projectMarkers.contains(where: { lower.contains($0) }) {
                push(Extracted(content: "Project: \(cleaned(s))", kind: .project, topic: "projects"))
                continue
            }
            if factSelf.contains(where: { lower.hasPrefix($0) || lower.contains(" \($0) ") }) {
                push(Extracted(content: cleaned(s), kind: .fact, topic: nil))
                continue
            }
            for (pattern, _) in personMarkers {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                   let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                   match.numberOfRanges >= 3,
                   let rRel = Range(match.range(at: 1), in: s),
                   let rName = Range(match.range(at: 2), in: s) {
                    let rel = String(s[rRel])
                    let name = String(s[rName])
                    push(Extracted(content: "\(rel.capitalized): \(name)", kind: .person, topic: "people"))
                    break
                }
            }
        }
        return Array(results.prefix(8))
    }

    nonisolated private static func cleaned(_ s: String) -> String {
        var out = s
        if out.count > 140 { out = String(out.prefix(140)) + "…" }
        return out
    }
}
