import Foundation
import SwiftData

@MainActor
enum ModelLaunchBootstrap {
    static func ensureV0FleetDownloaded(appState: AppState, context: ModelContext) async {
        let models = uniqueByArtifact(LumenModelFleetCatalog.v0Recommended)
        guard !models.isEmpty else {
            appState.runtime.updateBootStep(id: "models", detail: "No bundled fleet catalog entries", state: .warning)
            return
        }

        appState.runtime.updateBootStep(
            id: "models",
            detail: "Checking \(models.count) fleet model artifacts",
            state: .running
        )

        var alreadyPresent = 0
        var startedDownloads = 0
        var linkedLocalFiles = 0

        for model in models {
            let result = ensureModelPresent(model, expectedFleetCount: models.count, appState: appState, context: context)
            switch result {
            case .alreadyStored, .alreadyDownloading:
                alreadyPresent += 1
            case .linkedLocalFile:
                linkedLocalFiles += 1
            case .startedDownload:
                startedDownloads += 1
            }
        }

        let fragments = [
            alreadyPresent > 0 ? "\(alreadyPresent) ready" : nil,
            linkedLocalFiles > 0 ? "\(linkedLocalFiles) linked" : nil,
            startedDownloads > 0 ? "\(startedDownloads) downloading" : nil
        ].compactMap { $0 }

        let detail = fragments.isEmpty ? "Fleet model check complete" : fragments.joined(separator: " · ")
        appState.runtime.updateBootStep(id: "models", detail: detail, state: startedDownloads > 0 ? .running : .complete)
    }

    private enum EnsureResult {
        case alreadyStored
        case linkedLocalFile
        case alreadyDownloading
        case startedDownload
    }

    private static func ensureModelPresent(
        _ model: CatalogModel,
        expectedFleetCount: Int,
        appState: AppState,
        context: ModelContext
    ) -> EnsureResult {
        let existingStored = storedModel(for: model, context: context)
        let localURL = ModelDownloader.shared.localURL(for: model)

        if FileManager.default.fileExists(atPath: localURL.path) {
            if existingStored == nil {
                let stored = insertStoredModel(for: model, localURL: localURL, appState: appState, context: context)
                Task { @MainActor in
                    await loadIfSelected(stored, appState: appState, context: context)
                    updateFleetBootProgress(expectedCount: expectedFleetCount, appState: appState, context: context)
                }
                return .linkedLocalFile
            } else if let existingStored {
                activateIfNeeded(existingStored, appState: appState)
                Task { @MainActor in
                    await loadIfSelected(existingStored, appState: appState, context: context)
                    updateFleetBootProgress(expectedCount: expectedFleetCount, appState: appState, context: context)
                }
            }
            return .alreadyStored
        }

        guard existingStored == nil || !FileManager.default.fileExists(atPath: existingStored?.localPath ?? "") else {
            if let existingStored {
                activateIfNeeded(existingStored, appState: appState)
                Task { @MainActor in
                    await loadIfSelected(existingStored, appState: appState, context: context)
                    updateFleetBootProgress(expectedCount: expectedFleetCount, appState: appState, context: context)
                }
            }
            return .alreadyStored
        }

        guard !ModelDownloader.shared.isDownloading(model) else { return .alreadyDownloading }

        ModelDownloader.shared.start(model) { localURL in
            Task { @MainActor in
                let stored: StoredModel
                if let existing = storedModel(for: model, context: context) {
                    activateIfNeeded(existing, appState: appState)
                    stored = existing
                } else {
                    stored = insertStoredModel(for: model, localURL: localURL, appState: appState, context: context)
                }

                await loadIfSelected(stored, appState: appState, context: context)
                updateFleetBootProgress(expectedCount: expectedFleetCount, appState: appState, context: context)
            }
        }
        return .startedDownload
    }

    private static func loadIfSelected(_ stored: StoredModel, appState: AppState, context: ModelContext) async {
        let allStored = (try? context.fetch(FetchDescriptor<StoredModel>())) ?? []
        switch stored.modelRole {
        case .chat:
            guard appState.activeChatModelID == stored.id.uuidString else { return }
            _ = await ModelLoader.ensureChatLoaded(appState: appState, stored: allStored)
        case .embedding:
            guard appState.activeEmbeddingModelID == stored.id.uuidString else { return }
            _ = await ModelLoader.ensureEmbedLoaded(appState: appState, stored: allStored)
        }
    }

    private static func updateFleetBootProgress(expectedCount: Int, appState: AppState, context: ModelContext) {
        let readyCount = readyFleetArtifactCount(context: context)
        let state: BootStepState = readyCount >= expectedCount ? .complete : .running
        appState.runtime.updateBootStep(
            id: "models",
            detail: "\(min(readyCount, expectedCount)) / \(expectedCount) fleet model artifacts ready",
            state: state
        )
    }

    private static func readyFleetArtifactCount(context: ModelContext) -> Int {
        let stored = (try? context.fetch(FetchDescriptor<StoredModel>())) ?? []
        let installedKeys = Set(stored.map { artifactKey(repoId: $0.repoId, fileName: $0.fileName) })
        return uniqueByArtifact(LumenModelFleetCatalog.v0Recommended).reduce(0) { count, model in
            installedKeys.contains(artifactKey(repoId: model.repoId, fileName: model.fileName)) ? count + 1 : count
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
