import Foundation
import SwiftData
import OSLog

@MainActor
enum ModelLoader {
    private static let logger = Logger(subsystem: "com.lumen.ios", category: "ModelLoader")
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
        let preferredID = appState.activeChatModelID
        if let preferredID,
           let preferred = stored.first(where: { $0.id.uuidString == preferredID && $0.modelRole == .chat }) {
            let resolvedPath = ModelStorage.resolvedModelURL(from: preferred.localPath, fileName: preferred.fileName).path
            if await AppLlamaService.shared.isChatLoaded,
               await AppLlamaService.shared.loadedChatPath == resolvedPath {
                return true
            }
        } else if await AppLlamaService.shared.isChatLoaded {
            return true
        }

        let candidates: [StoredModel] = candidateList(
            preferredID: preferredID,
            role: .chat,
            stored: stored
        )
        for candidate in candidates {
            let resolvedPath = ModelStorage.resolvedModelURL(from: candidate.localPath, fileName: candidate.fileName).path
            guard FileManager.default.fileExists(atPath: resolvedPath) else { continue }
            do {
                try await AppLlamaService.shared.loadChatModel(path: resolvedPath, contextSize: appState.contextSize)
                if appState.activeChatModelID != candidate.id.uuidString {
                    appState.activeChatModelID = candidate.id.uuidString
                }
                return true
            } catch {
                logger.error(
                    "Primary chat load failed for candidate=\(candidate.id.uuidString, privacy: .public) path=\(resolvedPath, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                if let cocoaError = error as? CocoaError, cocoaError.code == .fileNoSuchFile {
                    continue
                }
                do {
                    try await AppLlamaService.shared.loadChatModel(path: resolvedPath, contextSize: 2048)
                    if appState.activeChatModelID != candidate.id.uuidString {
                        appState.activeChatModelID = candidate.id.uuidString
                    }
                    return true
                } catch {
                    continue
                }
            }
        }
        return false
    }

    @discardableResult
    static func ensureEmbedLoaded(appState: AppState, stored: [StoredModel]) async -> Bool {
        let preferredID = appState.activeEmbeddingModelID
        if let preferredID,
           let preferred = stored.first(where: { $0.id.uuidString == preferredID && $0.modelRole == .embedding }) {
            let resolvedPath = ModelStorage.resolvedModelURL(from: preferred.localPath, fileName: preferred.fileName).path
            if await AppLlamaService.shared.isEmbedLoaded,
               await AppLlamaService.shared.loadedEmbedPath == resolvedPath {
                return true
            }
        } else if await AppLlamaService.shared.isEmbedLoaded {
            return true
        }

        let candidates: [StoredModel] = candidateList(
            preferredID: preferredID,
            role: .embedding,
            stored: stored
        )
        for candidate in candidates {
            let resolvedPath = ModelStorage.resolvedModelURL(from: candidate.localPath, fileName: candidate.fileName).path
            guard FileManager.default.fileExists(atPath: resolvedPath) else { continue }
            do {
                try await AppLlamaService.shared.loadEmbeddingModel(path: resolvedPath)
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
