import SwiftUI
import SwiftData

@main
struct LumenApp: App {
    @UIApplicationDelegateAdaptor(LumenAppDelegate.self) private var appDelegate
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
                .environment(appState)
                .environment(VoiceService.shared)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    SharedContainer.shared = sharedModelContainer
                    let ctx = ModelContext(sharedModelContainer)
                    await ModelLaunchBootstrap.ensureV0FleetDownloaded(appState: appState, context: ctx)
                    let storedModels = (try? ctx.fetch(FetchDescriptor<StoredModel>())) ?? []
                    await ModelLoader.loadAtLaunch(appState: appState, stored: storedModels)
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
