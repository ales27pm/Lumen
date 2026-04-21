import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query private var storedModels: [StoredModel]
    @State private var selection: MenuItem? = .chat
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    enum MenuItem: Hashable, Identifiable, CaseIterable {
        case chat, models, memory, sources, triggers, tools, settings
        var id: Self { self }
        var title: String {
            switch self {
            case .chat: return "Chat"
            case .models: return "Models"
            case .memory: return "Memory"
            case .sources: return "Sources"
            case .triggers: return "Triggers"
            case .tools: return "Tools"
            case .settings: return "Settings"
            }
        }
        var systemImage: String {
            switch self {
            case .chat: return "bubble.left.and.text.bubble.right"
            case .models: return "cpu"
            case .memory: return "brain"
            case .sources: return "externaldrive"
            case .triggers: return "alarm"
            case .tools: return "wrench.and.screwdriver"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(MenuItem.allCases, selection: $selection) { item in
                NavigationLink(value: item) {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
            .navigationTitle("Lumen")
            .listStyle(.sidebar)
        } detail: {
            NavigationStack {
                detailView(for: selection ?? .chat)
            }
        }
        .tint(Theme.accent)
        .task(id: appState.activeChatModelID) {
            await ModelLoader.syncChat(appState: appState, stored: storedModels)
        }
        .task(id: appState.activeEmbeddingModelID) {
            await ModelLoader.syncEmbed(appState: appState, stored: storedModels)
        }
        .onChange(of: storedModels.count) { _, _ in
            Task {
                await ModelLoader.syncChat(appState: appState, stored: storedModels)
                await ModelLoader.syncEmbed(appState: appState, stored: storedModels)
            }
        }
    }

    @ViewBuilder
    private func detailView(for item: MenuItem) -> some View {
        switch item {
        case .chat: ChatHomeView()
        case .models: ModelsView()
        case .memory: MemoryView()
        case .sources: SourcesView()
        case .triggers: TriggersView()
        case .tools: ToolsView()
        case .settings: SettingsView()
        }
    }
}

enum ModelLoader {
    static func syncChat(appState: AppState, stored: [StoredModel]) async {
        guard let id = appState.activeChatModelID,
              let m = stored.first(where: { $0.id.uuidString == id }),
              m.modelRole == .chat else { return }
        guard FileManager.default.fileExists(atPath: m.localPath) else { return }
        let loaded = await LlamaService.shared.loadedChatPath
        if loaded == m.localPath { return }
        do {
            try await LlamaService.shared.loadChatModel(path: m.localPath, contextSize: appState.contextSize)
        } catch {
            print("Chat model load failed: \(error)")
        }
    }

    static func syncEmbed(appState: AppState, stored: [StoredModel]) async {
        guard let id = appState.activeEmbeddingModelID,
              let m = stored.first(where: { $0.id.uuidString == id }),
              m.modelRole == .embedding else { return }
        guard FileManager.default.fileExists(atPath: m.localPath) else { return }
        let loaded = await LlamaService.shared.loadedEmbedPath
        if loaded == m.localPath { return }
        do {
            try await LlamaService.shared.loadEmbeddingModel(path: m.localPath)
        } catch {
            print("Embed model load failed: \(error)")
        }
    }
}
