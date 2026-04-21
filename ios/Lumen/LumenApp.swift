import SwiftUI
import SwiftData

@main
struct LumenApp: App {
    @State private var appState = AppState()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Conversation.self,
            ChatMessage.self,
            MemoryItem.self,
            StoredModel.self,
            RAGChunk.self,
            Trigger.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("ModelContainer failed: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(VoiceService.shared)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    SharedContainer.shared = sharedModelContainer
                    TriggerScheduler.shared.registerTasks()
                    TriggerScheduler.shared.scheduleBackgroundRefresh()
                    await TriggerScheduler.shared.requestPermission()
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
