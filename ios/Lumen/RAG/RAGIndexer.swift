import Foundation
import SwiftData

@MainActor
final class RAGIndexer {
    func indexText(source: RAGSource, title: String, text: String, metadata: [String:String], context: ModelContext) async -> Int {
        let type = RAGSourceType(rawValue: source.type) ?? .note
        let chunks = ChunkingStrategy.chunk(text, type: .plain)
        var inserted = 0
        for (i,c) in chunks.enumerated() {
            let emb = (try? await AppLlamaService.shared.embed(c.text)) ?? []
            let chunk = RAGChunk(content: c.text, sourceType: type, sourceName: title, sourceRef: source.ref, chunkIndex: i, embedding: emb)
            context.insert(chunk); inserted += 1
        }
        try? context.save(); return inserted
    }
}
