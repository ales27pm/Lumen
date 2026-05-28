import Foundation

enum PromptGroundingRenderer {
    static func render(memories: MemoryContextResult, rag: RAGContextResult, tools: [SecureToolDefinition], lowPower: Bool, thermal: DeviceThermalState) -> [PromptGroundingSection] {
        let memLines = memories.selected.prefix(8).map { "- [\($0.id.uuidString.prefix(8))] \(String($0.content.prefix(120)))" }
        let ragLines = rag.selected.prefix(8).map { "- [\($0.chunkID.uuidString.prefix(8))] \($0.source.title) (\($0.retrievalMode), \(String(format: "%.2f", $0.score)))" }
        let toolLines = tools.prefix(20).map { "- \($0.id): \($0.description)" }
        return [
            .init(title: "Relevant memories", content: memLines.joined(separator: "\n"), estimatedChars: memLines.joined().count, sourceIDs: memories.sourceIDs.map { $0.uuidString }, privacyLevel: .moderate),
            .init(title: "Retrieved sources", content: ragLines.joined(separator: "\n"), estimatedChars: ragLines.joined().count, sourceIDs: rag.selected.map { $0.chunkID.uuidString }, privacyLevel: .moderate),
            .init(title: "Available tools", content: toolLines.joined(separator: "\n"), estimatedChars: toolLines.joined().count, sourceIDs: tools.map { $0.id }, privacyLevel: .low),
            .init(title: "Runtime policy", content: "lowPower=\(lowPower), thermal=\(thermal.rawValue)", estimatedChars: 48, sourceIDs: [], privacyLevel: .low)
        ].filter { !$0.content.isEmpty }
    }

    static func renderForPrompt(_ sections: [PromptGroundingSection], maxChars: Int) -> String {
        var out = ""; var chars = 0
        for s in sections {
            let block = "\n[\(s.title)]\n\(s.content)\n"
            if chars + block.count > maxChars { continue }
            out += block; chars += block.count
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
