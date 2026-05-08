import XCTest
import SwiftData
@testable import Lumen

@MainActor
final class PersistenceFailureSurfacingTests: XCTestCase {
    struct StubError: Error {}

    func testMemoryStorePersistFailureReturnsFalse() {
        let didPersist = MemoryStore.persist(
            context: makeContext(),
            operation: "test.memory",
            entityScope: "MemoryItem",
            save: { throw StubError() }
        )
        XCTAssertFalse(didPersist)
    }

    func testRAGStorePersistFailureReturnsFalse() {
        let didPersist = RAGStore.persist(
            context: makeContext(),
            operation: "test.rag",
            entityScope: "RAGChunk",
            save: { throw StubError() }
        )
        XCTAssertFalse(didPersist)
    }

    func testTriggerSchedulerPersistFailureReturnsFalse() {
        let didPersist = TriggerScheduler.shared.persist(
            context: makeContext(),
            operation: "test.trigger",
            entityScope: "Trigger",
            save: { throw StubError() }
        )
        XCTAssertFalse(didPersist)
    }

    func testModelLaunchBootstrapPersistFailureReturnsFalse() {
        let didPersist = ModelLaunchBootstrap.persist(
            context: makeContext(),
            operation: "test.bootstrap",
            entityScope: "StoredModel",
            save: { throw StubError() }
        )
        XCTAssertFalse(didPersist)
    }

    private func makeContext() -> ModelContext {
        let schema = Schema([MemoryItem.self, RAGChunk.self, Trigger.self, StoredModel.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }
}
