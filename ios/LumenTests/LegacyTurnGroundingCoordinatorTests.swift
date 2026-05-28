import XCTest
import SwiftData
@testable import Lumen

final class LegacyTurnGroundingCoordinatorTests: XCTestCase {
    @MainActor func testBoundedInjection() async {
        let schema = Schema([MemoryItem.self, RAGChunk.self]); let c = try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let ctx = ModelContext(c)
        let out = await LegacyTurnGroundingCoordinator.shared.build(userMessage: "hello", conversationID: nil, turnID: UUID(), history: [], modelContext: ctx, isBackground: true, task: .backgroundTrigger)
        XCTAssertLessThanOrEqual(out.promptInjection.count, 2000)
    }
}
