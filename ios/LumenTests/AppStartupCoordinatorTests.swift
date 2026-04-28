import Testing
import SwiftData
@testable import Lumen

@MainActor
struct AppStartupCoordinatorTests {
    enum TestError: Error { case failed }

    @Test func startupFailureTransitionsToFailedState() async throws {
        var coordinator = AppStartupCoordinator()
        let appState = AppState()

        await coordinator.initialize(
            appState: appState,
            createContainer: { throw TestError.failed },
            bootstrap: { _, _ in }
        )

        guard case .failed(let context) = coordinator.state else {
            Issue.record("Expected failed state")
            return
        }
        #expect(context.stage == .container)
        #expect(!context.domain.isEmpty)
    }

    @Test func retryAfterFailureTransitionsToReady() async throws {
        var coordinator = AppStartupCoordinator()
        let appState = AppState()
        var attempts = 0

        await coordinator.initialize(
            appState: appState,
            createContainer: {
                attempts += 1
                if attempts == 1 { throw TestError.failed }
                let schema = Schema([
                    Conversation.self,
                    ChatMessage.self,
                    MemoryItem.self,
                    StoredModel.self,
                    RAGChunk.self,
                    Trigger.self,
                ])
                let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                return try ModelContainer(for: schema, configurations: [config])
            },
            bootstrap: { _, _ in }
        )

        #expect(attempts == 1)
        #expect({ if case .failed = coordinator.state { true } else { false } }())

        await coordinator.initialize(
            appState: appState,
            createContainer: {
                attempts += 1
                let schema = Schema([
                    Conversation.self,
                    ChatMessage.self,
                    MemoryItem.self,
                    StoredModel.self,
                    RAGChunk.self,
                    Trigger.self,
                ])
                let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                return try ModelContainer(for: schema, configurations: [config])
            },
            bootstrap: { _, _ in }
        )

        #expect(attempts == 2)
        #expect({ if case .ready = coordinator.state { true } else { false } }())
    }
    @Test func continueInLimitedModeTransitionsToReady() async throws {
        var coordinator = AppStartupCoordinator()
        let appState = AppState()

        await coordinator.initialize(
            appState: appState,
            createContainer: { throw TestError.failed },
            bootstrap: { _, _ in }
        )

        coordinator.continueInLimitedMode(appState: appState)

        #expect({ if case .ready = coordinator.state { true } else { false } }())
    }

}
