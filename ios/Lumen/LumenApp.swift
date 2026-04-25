import SwiftUI
import SwiftData
import Spezi

@main
struct LumenApp: App {
    @ApplicationDelegateAdaptor(LumenAppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

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
                .spezi(appDelegate)
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
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { @MainActor in
                            let ctx = ModelContext(sharedModelContainer)
                            await TriggerScheduler.shared.fireDueTriggers(context: ctx, appState: appState)
                        }
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
