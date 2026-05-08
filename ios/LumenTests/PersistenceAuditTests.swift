import XCTest
@testable import Lumen

final class PersistenceAuditTests: XCTestCase {
    private struct SaveError: Error {}

    func testMemoryStoreFailedSaveSurfacesFailure() {
        let ok = MemoryStore.auditPersistence(operation: "test", scope: "MemoryItem") {}
        XCTAssertTrue(ok)

        let failed = MemoryStore.auditPersistence(operation: "test", scope: "MemoryItem") {
            throw SaveError()
        }
        XCTAssertFalse(failed)
    }

    func testRAGStoreFailedSaveSurfacesFailure() {
        let failed = RAGStore.auditPersistence(operation: "test", scope: "RAGChunk") {
            throw SaveError()
        }
        XCTAssertFalse(failed)
        let ok = RAGStore.auditPersistence(operation: "test", scope: "RAGChunk") {}
        XCTAssertTrue(ok)
    }

    @MainActor
    func testTriggerSchedulerFailedSaveSurfacesFailure() {
        let failed = TriggerScheduler.shared.auditPersistence(operation: "test", scope: "Trigger") {
            throw SaveError()
        }
        XCTAssertFalse(failed)
        let ok = TriggerScheduler.shared.auditPersistence(operation: "test", scope: "Trigger") {}
        XCTAssertTrue(ok)
    }

    func testModelLaunchBootstrapFailedSaveSurfacesFailure() {
        let failed = ModelLaunchBootstrap.auditPersistence(operation: "test", scope: "StoredModel") {
            throw SaveError()
        }
        XCTAssertFalse(failed)
        let ok = ModelLaunchBootstrap.auditPersistence(operation: "test", scope: "StoredModel") {}
        XCTAssertTrue(ok)
    }
}
