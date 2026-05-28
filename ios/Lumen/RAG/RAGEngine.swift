import Foundation
import SwiftData
import CryptoKit

@MainActor
final class RAGEngine {
    private let indexer = RAGIndexer()

    func retrieve(query: String, limit: Int, context: ModelContext) async -> [RAGRetrievalResult] {
        let semantic = await RAGStore.search(query: query, context: context, limit: limit)
        let mapped = semantic.map { item in
            RAGRetrievalResult(chunkID: item.chunk.id, source: .init(id: item.chunk.sourceName, type: item.chunk.sourceType, title: item.chunk.sourceName, ref: item.chunk.sourceRef), excerpt: String(item.chunk.content.prefix(220)), score: item.score, retrievalMode: "semantic", offsetStart: nil, offsetEnd: nil)
        }
        var seen = Set<String>()
        return mapped.filter { r in
            let key = SHA256.hash(data: Data((r.source.id + r.excerpt).utf8)).map { String(format:"%02x", $0) }.joined()
            if seen.contains(key) { return false }; seen.insert(key); return true
        }
    }

    func buildContext(query: String, budget: Int, context: ModelContext) async -> RAGContextResult {
        let r = await retrieve(query: query, limit: 12, context: context)
        return RAGContextBuilder.build(results: r, budgetChars: budget)
    }

    func index(source: RAGSource, title: String, text: String, metadata: [String:String], context: ModelContext) async -> Int {
        await indexer.indexText(source: source, title: title, text: text, metadata: metadata, context: context)
    }

    func maintenance(context: ModelContext) async -> Bool {
        let chunks = (try? context.fetch(FetchDescriptor<RAGChunk>())) ?? []
        return !chunks.isEmpty
    }
}
