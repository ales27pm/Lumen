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
                    appState.runtime.startBoot()
                    appState.runtime.updateBootStep(id: "container", detail: "SwiftData container ready", state: .complete)

                    SharedContainer.shared = sharedModelContainer
                    let ctx = ModelContext(sharedModelContainer)

                    await ModelLaunchBootstrap.ensureV0FleetDownloaded(appState: appState, context: ctx)

                    appState.runtime.updateBootStep(id: "loader", detail: "Loading active chat and embedding models", state: .running)
                    let storedModels = (try? ctx.fetch(FetchDescriptor<StoredModel>())) ?? []
                    await ModelLoader.loadAtLaunch(appState: appState, stored: storedModels)
                    appState.runtime.updateBootStep(id: "loader", detail: "Model runtime initialized", state: .complete)

                    appState.runtime.updateBootStep(id: "triggers", detail: "Registering background tasks", state: .running)
                    TriggerScheduler.shared.registerTasks()
                    TriggerScheduler.shared.scheduleBackgroundRefresh()
                    await TriggerScheduler.shared.requestPermission()
                    appState.runtime.updateBootStep(id: "triggers", detail: "Background tasks ready", state: .complete)

                    await RemCycleService.runIfDue(context: ctx, appState: appState, reason: "launch")
                    appState.runtime.completeBootCore()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { @MainActor in
                            let ctx = ModelContext(sharedModelContainer)
                            await TriggerScheduler.shared.fireDueTriggers(context: ctx, appState: appState)
                            await RemCycleService.runIfDue(context: ctx, appState: appState, reason: "scene-active")
                        }
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
