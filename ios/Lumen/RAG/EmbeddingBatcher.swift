import Foundation
import SwiftData

enum EmbeddingBatcherError: Error { case unavailable }

enum EmbeddingBatcher {
    static func embed(texts: [String], turnContext: AssistantTurnContext, cancel: TaskCancellationHandler? = nil) async throws -> [[Double]] {
        let batch = (!turnContext.isForeground || turnContext.lowPowerMode) ? min(texts.count, 4) : min(texts.count, 12)
        var out: [[Double]] = []
        for t in texts.prefix(batch) {
            try Task.checkCancellation()
            do { out.append(try await AppLlamaService.shared.embed(t)) } catch { throw EmbeddingBatcherError.unavailable }
        }
        return out
    }
}
