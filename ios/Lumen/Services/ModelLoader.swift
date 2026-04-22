import Foundation
import SwiftData

@MainActor
enum ModelLoader {
    static func syncChat(appState: AppState, stored: [StoredModel]) async {
        await ensureChatLoaded(appState: appState, stored: stored)
    }

    static func syncEmbed(appState: AppState, stored: [StoredModel]) async {
        await ensureEmbedLoaded(appState: appState, stored: stored)
    }

    /// Attempts to load both chat and embedding models at launch with multiple fallbacks.
    static func loadAtLaunch(appState: AppState, stored: [StoredModel]) async {
        async let chat = ensureChatLoaded(appState: appState, stored: stored)
        async let embed = ensureEmbedLoaded(appState: appState, stored: stored)
        _ = await (chat, embed)
    }

    @discardableResult
    static func ensureChatLoaded(appState: AppState, stored: [StoredModel]) async -> Bool {
        if await LlamaService.shared.isChatLoaded { return true }

        let candidates: [StoredModel] = candidateList(
            preferredID: appState.activeChatModelID,
            role: .chat,
            stored: stored
        )
        for candidate in candidates {
            guard FileManager.default.fileExists(atPath: candidate.localPath) else { continue }
            do {
                try await LlamaService.shared.loadChatModel(path: candidate.localPath, contextSize: appState.contextSize)
                if appState.activeChatModelID != candidate.id.uuidString {
                    appState.activeChatModelID = candidate.id.uuidString
                }
                return true
            } catch {
                // Fallback: retry once with a smaller context if init failed
                if case LlamaError.contextInitFailed = error {
                    do {
                        try await LlamaService.shared.loadChatModel(path: candidate.localPath, contextSize: 2048)
                        appState.activeChatModelID = candidate.id.uuidString
                        return true
                    } catch {
                        continue
                    }
                }
                continue
            }
        }
        return false
    }

    @discardableResult
    static func ensureEmbedLoaded(appState: AppState, stored: [StoredModel]) async -> Bool {
        if await LlamaService.shared.isEmbedLoaded { return true }

        let candidates: [StoredModel] = candidateList(
            preferredID: appState.activeEmbeddingModelID,
            role: .embedding,
            stored: stored
        )
        for candidate in candidates {
            guard FileManager.default.fileExists(atPath: candidate.localPath) else { continue }
            do {
                try await LlamaService.shared.loadEmbeddingModel(path: candidate.localPath)
                if appState.activeEmbeddingModelID != candidate.id.uuidString {
                    appState.activeEmbeddingModelID = candidate.id.uuidString
                }
                return true
            } catch {
                continue
            }
        }
        return false
    }

    private static func candidateList(preferredID: String?, role: ModelRole, stored: [StoredModel]) -> [StoredModel] {
        let pool = stored.filter { $0.modelRole == role }
        var ordered: [StoredModel] = []
        if let id = preferredID, let preferred = pool.first(where: { $0.id.uuidString == id }) {
            ordered.append(preferred)
        }
        for m in pool where !ordered.contains(where: { $0.id == m.id }) {
            ordered.append(m)
        }
        return ordered
    }
}
