import SwiftUI
import SwiftData

struct ModelsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredModel.downloadedAt, order: .reverse) private var storedModels: [StoredModel]
    @State private var showAddModel = false
    @State private var downloader = ModelDownloader.shared
    @State private var loadedPaths: Set<String> = []

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        activeRow

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Featured")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            VStack(spacing: 10) {
                                ForEach(ModelCatalog.featured) { model in
                                    ModelCard(
                                        catalog: model,
                                        stored: storedModel(for: model),
                                        progress: downloader.progresses[model.id],
                                        onDownload: { download(model) },
                                        onPause: { downloader.pause(model) },
                                        onResume: { download(model) },
                                        onCancel: { downloader.cancel(model) },
                                        onDelete: { deleteStored(for: model) },
                                        onActivate: { activate(model) }
                                    )
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Downloaded")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            if storedModels.isEmpty {
                                Text("No models yet.")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                                    .background(Theme.surface)
                                    .clipShape(.rect(cornerRadius: 10))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(Theme.border, lineWidth: 1)
                                    }
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(storedModels) { sm in
                                        DownloadedRow(model: sm,
                                                      isActiveChat: sm.id.uuidString == appState.activeChatModelID,
                                                      isActiveEmbed: sm.id.uuidString == appState.activeEmbeddingModelID,
                                                      isLoaded: loadedPaths.contains(ModelStorage.resolvedModelURL(from: sm.localPath, fileName: sm.fileName).path),
                                                      onActivate: { activate(stored: sm) },
                                                      onLoad: { load(sm) },
                                                      onUnload: { unload(sm) },
                                                      onReload: { reload(sm) },
                                                      onDelete: { deleteStoredModel(sm) })
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Models")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddModel = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddModel) {
                AddModelSheet()
                    .presentationDetents([.medium, .large])
            }
            .task(id: appState.activeChatModelID) { await refreshLoaded() }
            .task(id: appState.activeEmbeddingModelID) { await refreshLoaded() }
        }
    }

    private var activeRow: some View {
        HStack(spacing: 10) {
            ActivePill(title: "Chat", name: storedModels.first { $0.id.uuidString == appState.activeChatModelID }?.name ?? "None", icon: "bubble.left.and.bubble.right")
            ActivePill(title: "Embed", name: storedModels.first { $0.id.uuidString == appState.activeEmbeddingModelID }?.name ?? "None", icon: "point.3.connected.trianglepath.dotted")
        }
    }

    private func storedModel(for catalog: CatalogModel) -> StoredModel? {
        storedModels.first { $0.fileName == catalog.fileName }
    }

    private func download(_ model: CatalogModel) {
        downloader.start(model) { localURL in
            Task { @MainActor in
                let stored = StoredModel(
                    name: model.name, repoId: model.repoId, fileName: model.fileName,
                    sizeBytes: model.sizeBytes, quantization: model.quantization,
                    parameters: model.parameters, role: model.role, localPath: localURL.path
                )
                modelContext.insert(stored)
                try? modelContext.save()
                if model.role == .chat && appState.activeChatModelID == nil {
                    appState.activeChatModelID = stored.id.uuidString
                }
                if model.role == .embedding && appState.activeEmbeddingModelID == nil {
                    appState.activeEmbeddingModelID = stored.id.uuidString
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    private func activate(_ catalog: CatalogModel) {
        guard let stored = storedModel(for: catalog) else { return }
        activate(stored: stored)
    }

    private func activate(stored: StoredModel) {
        if stored.modelRole == .chat {
            appState.activeChatModelID = stored.id.uuidString
        } else {
            appState.activeEmbeddingModelID = stored.id.uuidString
        }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    private func deleteStored(for catalog: CatalogModel) {
        if let stored = storedModel(for: catalog) {
            deleteStoredModel(stored)
        }
        downloader.deleteLocal(catalog)
    }

    private func refreshLoaded() async {
        var set: Set<String> = []
        if let p = await AppLlamaService.shared.loadedChatPath {
            let fileName = URL(fileURLWithPath: p).lastPathComponent
            set.insert(ModelStorage.resolvedModelURL(from: p, fileName: fileName).path)
        }
        if let p = await AppLlamaService.shared.loadedEmbedPath {
            if await AppLlamaService.shared.hasSemanticEmbeddingRuntime {
                let fileName = URL(fileURLWithPath: p).lastPathComponent
                set.insert(ModelStorage.resolvedModelURL(from: p, fileName: fileName).path)
            }
        }
        loadedPaths = set
    }

    private func load(_ sm: StoredModel) {
        Task {
            do {
                if sm.modelRole == .chat {
                    let resolvedPath = ModelStorage.resolvedModelURL(from: sm.localPath, fileName: sm.fileName).path
                    try await AppLlamaService.shared.loadChatModel(path: resolvedPath, contextSize: appState.contextSize)
                } else {
                    let resolvedPath = ModelStorage.resolvedModelURL(from: sm.localPath, fileName: sm.fileName).path
                    try await AppLlamaService.shared.loadEmbeddingModel(path: resolvedPath)
                }
                await refreshLoaded()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func unload(_ sm: StoredModel) {
        Task {
            if sm.modelRole == .chat {
                await AppLlamaService.shared.unloadChat()
            } else {
                await AppLlamaService.shared.unloadEmbed()
            }
            await refreshLoaded()
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
    }

    private func reload(_ sm: StoredModel) {
        Task {
            do {
                if sm.modelRole == .chat {
                    try await AppLlamaService.shared.reloadChat(contextSize: appState.contextSize)
                } else {
                    try await AppLlamaService.shared.reloadEmbed()
                }
                await refreshLoaded()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func deleteStoredModel(_ sm: StoredModel) {
        let fm = FileManager.default
        let resolvedPath = ModelStorage.resolvedModelURL(from: sm.localPath, fileName: sm.fileName, fileManager: fm).path
        try? fm.removeItem(atPath: sm.localPath)
        if resolvedPath != sm.localPath {
            try? fm.removeItem(atPath: resolvedPath)
        }
        if sm.id.uuidString == appState.activeChatModelID { appState.activeChatModelID = nil }
        if sm.id.uuidString == appState.activeEmbeddingModelID { appState.activeEmbeddingModelID = nil }
        modelContext.delete(sm)
        try? modelContext.save()
    }
}

struct ActivePill: View {
    let title: String
    let name: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
    }
}

struct ModelCard: View {
    let catalog: CatalogModel
    let stored: StoredModel?
    let progress: DownloadProgress?
    var onDownload: () -> Void
    var onPause: () -> Void = {}
    var onResume: () -> Void = {}
    var onCancel: () -> Void
    var onDelete: () -> Void
    var onActivate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: catalog.role == .embedding ? "point.3.connected.trianglepath.dotted" : "cpu")
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(catalog.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(catalog.parameters) · \(catalog.quantization) · \(formatBytes(catalog.sizeBytes))")
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                actionButton
            }

            Text(catalog.description)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)

            if !catalog.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(catalog.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(Theme.textSecondary)
                            .background(Theme.surfaceHigh)
                            .clipShape(.rect(cornerRadius: 4))
                    }
                }
            }

            if let progress {
                switch progress.state {
                case .downloading:
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress.fractionCompleted)
                            .tint(Theme.accent)
                        Text("\(formatBytes(progress.bytesReceived)) / \(formatBytes(progress.totalBytes))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.textSecondary)
                    }
                case .paused:
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress.fractionCompleted)
                            .tint(Theme.textTertiary)
                        Text("Paused — \(formatBytes(progress.bytesReceived)) / \(formatBytes(progress.totalBytes))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.textSecondary)
                    }
                case .failed(let msg):
                    Text("Failed: \(msg)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                case .queued, .completed:
                    EmptyView()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let progress, case .downloading = progress.state {
            HStack(spacing: 6) {
                Button { onPause() } label: {
                    Image(systemName: "pause.fill").font(.caption)
                }
                .buttonStyle(.bordered)
                Button("Cancel") { onCancel() }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
        } else if let progress, case .paused = progress.state {
            HStack(spacing: 6) {
                Button { onResume() } label: {
                    Image(systemName: "play.fill").font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                Button("Cancel") { onCancel() }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
        } else if stored != nil {
            Menu {
                Button("Set as Active", systemImage: "checkmark") { onActivate() }
                Button("Delete", systemImage: "trash", role: .destructive) { onDelete() }
            } label: {
                Text("Installed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1)
                    }
            }
        } else {
            Button("Download") { onDownload() }
                .font(.caption.weight(.medium))
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
    }
}

struct DownloadedRow: View {
    let model: StoredModel
    let isActiveChat: Bool
    let isActiveEmbed: Bool
    let isLoaded: Bool
    var onActivate: () -> Void
    var onLoad: () -> Void
    var onUnload: () -> Void
    var onReload: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.modelRole == .embedding ? "point.3.connected.trianglepath.dotted" : "cpu")
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(model.name).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                    if isLoaded {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    }
                }
                Text("\(model.parameters) · \(model.quantization) · \(formatBytes(model.sizeBytes))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if isActiveChat || isActiveEmbed {
                Text("Active")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
            } else {
                Button("Use") { onActivate() }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.bordered)
            }
            Menu {
                if isLoaded {
                    Button("Reload", systemImage: "arrow.clockwise") { onReload() }
                    Button("Unload", systemImage: "eject") { onUnload() }
                } else {
                    Button("Load", systemImage: "arrow.down.circle") { onLoad() }
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
    }
}

struct ModelPickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Query private var stored: [StoredModel]

    var body: some View {
        NavigationStack {
            List {
                Section("Chat model") {
                    ForEach(stored.filter { $0.modelRole == .chat }) { m in
                        pickerRow(m, isActive: appState.activeChatModelID == m.id.uuidString) {
                            appState.activeChatModelID = m.id.uuidString
                            dismiss()
                        }
                    }
                    if stored.filter({ $0.modelRole == .chat }).isEmpty {
                        Text("Add a .gguf chat model from your app bundle or Files app.")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                }
                Section("Embedding model") {
                    ForEach(stored.filter { $0.modelRole == .embedding }) { m in
                        pickerRow(m, isActive: appState.activeEmbeddingModelID == m.id.uuidString) {
                            appState.activeEmbeddingModelID = m.id.uuidString
                            dismiss()
                        }
                    }
                    if stored.filter({ $0.modelRole == .embedding }).isEmpty {
                        Text("Add a .gguf embedding model from your app bundle or Files app.")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .navigationTitle("Active Models")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func pickerRow(_ m: StoredModel, isActive: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading) {
                    Text(m.name)
                    Text("\(m.parameters) · \(m.quantization)")
                        .font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if isActive { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
        }
    }
}

struct AddModelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @State private var candidates: [LocalModelFile] = []

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    Text("No .gguf files found in app bundle or Documents directory.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(candidates) { model in
                        Button {
                            addLocal(model)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.displayName)
                                    .font(.body.weight(.medium))
                                Text("\(model.fileName) • \(model.source)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select GGUF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") { candidates = LocalModelDiscovery.discoverGGUF() }
                }
            }
            .task { candidates = LocalModelDiscovery.discoverGGUF() }
        }
    }

    private func addLocal(_ file: LocalModelFile) {
        let fileName = file.fileName
        let role: ModelRole = fileName.lowercased().contains("embed") ? .embedding : .chat
        let attrs = (try? FileManager.default.attributesOfItem(atPath: file.url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        let stored = StoredModel(
            name: file.displayName,
            repoId: "local/\(file.source.lowercased())",
            fileName: fileName,
            sizeBytes: size,
            quantization: "local",
            parameters: "local",
            role: role,
            localPath: file.url.path
        )
        modelContext.insert(stored)
        try? modelContext.save()

        if role == .chat && appState.activeChatModelID == nil {
            appState.activeChatModelID = stored.id.uuidString
        }
        if role == .embedding && appState.activeEmbeddingModelID == nil {
            appState.activeEmbeddingModelID = stored.id.uuidString
        }

        dismiss()
    }
}
