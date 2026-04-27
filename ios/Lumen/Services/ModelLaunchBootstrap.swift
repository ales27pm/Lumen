import Foundation
import SwiftData

@MainActor
enum ModelLaunchBootstrap {
    static func ensureV0FleetDownloaded(appState: AppState, context: ModelContext) async {
        let models = uniqueByArtifact(LumenModelFleetCatalog.v0Recommended)
        guard !models.isEmpty else { return }

        for model in models {
            ensureModelPresent(model, appState: appState, context: context)
        }
    }

    private static func ensureModelPresent(_ model: CatalogModel, appState: AppState, context: ModelContext) {
        let existingStored = storedModel(for: model, context: context)
        let localURL = ModelDownloader.shared.localURL(for: model)

        if FileManager.default.fileExists(atPath: localURL.path) {
            if existingStored == nil {
                insertStoredModel(for: model, localURL: localURL, appState: appState, context: context)
            } else if let existingStored {
                activateIfNeeded(existingStored, appState: appState)
            }
            return
        }

        guard existingStored == nil || !FileManager.default.fileExists(atPath: existingStored?.localPath ?? "") else {
            if let existingStored {
                activateIfNeeded(existingStored, appState: appState)
            }
            return
        }

        guard !ModelDownloader.shared.isDownloading(model) else { return }

        ModelDownloader.shared.start(model) { localURL in
            Task { @MainActor in
                if let existing = storedModel(for: model, context: context) {
                    activateIfNeeded(existing, appState: appState)
                    return
                }
                insertStoredModel(for: model, localURL: localURL, appState: appState, context: context)
            }
        }
    }

    private static func storedModel(for catalog: CatalogModel, context: ModelContext) -> StoredModel? {
        let models = (try? context.fetch(FetchDescriptor<StoredModel>())) ?? []
        return models.first { stored in
            artifactKey(repoId: stored.repoId, fileName: stored.fileName) == artifactKey(repoId: catalog.repoId, fileName: catalog.fileName)
        }
    }

    @discardableResult
    private static func insertStoredModel(for catalog: CatalogModel, localURL: URL, appState: AppState, context: ModelContext) -> StoredModel {
        let stored = StoredModel(
            name: catalog.name,
            repoId: catalog.repoId,
            fileName: catalog.fileName,
            sizeBytes: catalog.sizeBytes,
            quantization: catalog.quantization,
            parameters: catalog.parameters,
            role: catalog.role,
            localPath: localURL.path
        )
        context.insert(stored)
        try? context.save()
        activateIfNeeded(stored, appState: appState)
        return stored
    }

    private static func activateIfNeeded(_ stored: StoredModel, appState: AppState) {
        switch stored.modelRole {
        case .chat:
            if appState.activeChatModelID == nil {
                appState.activeChatModelID = stored.id.uuidString
            }
        case .embedding:
            if appState.activeEmbeddingModelID == nil {
                appState.activeEmbeddingModelID = stored.id.uuidString
            }
        }
    }

    private static func uniqueByArtifact(_ models: [CatalogModel]) -> [CatalogModel] {
        var seen: Set<String> = []
        var unique: [CatalogModel] = []
        unique.reserveCapacity(models.count)

        for model in models {
            let key = artifactKey(repoId: model.repoId, fileName: model.fileName)
            guard seen.insert(key).inserted else { continue }
            unique.append(model)
        }

        return unique
    }

    private static func artifactKey(repoId: String, fileName: String) -> String {
        "\(repoId.lowercased())/\(fileName.lowercased())"
    }
}
