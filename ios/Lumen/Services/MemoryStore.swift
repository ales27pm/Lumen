import Foundation
import SwiftData

@MainActor
enum MemoryStore {
    static func recall(query: String, context: ModelContext, limit: Int = 5) async -> [MemoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        let queryVec = await AppLlamaService.shared.embed(text: trimmed)
        guard !queryVec.isEmpty else { return [] }

        MemoryVectorIndex.shared.ensureLoaded(context: context)
        let hits = MemoryVectorIndex.shared.search(query: queryVec, topK: limit, pinBonus: 0.15)
        var results: [MemoryItem] = []
        results.reserveCapacity(hits.count)
        for h in hits {
            if let item = context.model(for: h.id) as? MemoryItem {
                results.append(item)
            }
        }
        return results
    }

    static func remember(_ content: String, kind: MemoryKind = .fact, source: String = "manual", topic: String? = nil, context: ModelContext) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = try? context.fetch(FetchDescriptor<MemoryItem>()) {
            if existing.contains(where: { $0.content.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                return
            }
        }
        let embedding = await AppLlamaService.shared.embed(text: trimmed)
        let item = MemoryItem(content: trimmed, kind: kind, source: source, embedding: embedding, topic: topic)
        context.insert(item)
        try? context.save()
        MemoryVectorIndex.shared.ensureLoaded(context: context)
        MemoryVectorIndex.shared.append(id: item.persistentModelID, isPinned: item.isPinned, vector: embedding)
    }

    static func extractAndStore(userText: String, assistantText: String, transientTexts: [String] = [], context: ModelContext) async {
        let durableAssistant = durableAssistantText(assistantText, transientTexts: transientTexts)
        let combined = userText + "\n" + durableAssistant
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
        MemoryVectorIndex.shared.invalidate()
    }

    static func wipeEverything(context: ModelContext) {
        guard let all = try? context.fetch(FetchDescriptor<MemoryItem>()) else { return }
        for item in all { context.delete(item) }
        try? context.save()
        MemoryVectorIndex.shared.invalidate()
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
        let durableAllowlist = ["prefer", "favorite", "i am", "i'm", "my name is", "i live", "i work", "working on", "building", "my project", "my app", "my startup"]
        let volatileDenylist = ["weather", "temperature", "forecast", "current location", "located", "search result", "live result", "breaking", "reminder", "alarm", "calendar", "busy", "free", "availability", "tomorrow", "today"]
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
            guard durableAllowlist.contains(where: { lower.contains($0) }) else { continue }
            if volatileDenylist.contains(where: { lower.contains($0) }) { continue }
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


    nonisolated private static func durableAssistantText(_ assistantText: String, transientTexts: [String]) -> String {
        let base = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "" }
        var filtered = base
        for transient in transientTexts where !transient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = filtered.replacingOccurrences(of: transient, with: "", options: [.caseInsensitive])
        }
        let blockedMarkers = ["tool", "observation", "search results", "temporary status"]
        let lines = filtered
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in !line.isEmpty && !blockedMarkers.contains(where: { line.lowercased().contains($0) }) }
        return lines.joined(separator: " ")
    }

    nonisolated private static func cleaned(_ s: String) -> String {
        var out = s
        if out.count > 140 { out = String(out.prefix(140)) + "…" }
        return out
    }
}
