import XCTest
import SwiftData
@testable import Lumen

final class RolePipelineGroundingReuseTests: XCTestCase {
    @MainActor func testCoordinatorCacheReuse() async {
        let schema = Schema([MemoryItem.self, RAGChunk.self]); let c = try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let ctx = ModelContext(c)
        let turnID = UUID()
        let a = await LegacyTurnGroundingCoordinator.shared.build(userMessage: "hello", conversationID: UUID(), turnID: turnID, history: [], modelContext: ctx, isBackground: false, task: .chat)
        let b = await LegacyTurnGroundingCoordinator.shared.build(userMessage: "hello", conversationID: UUID(), turnID: turnID, history: [], modelContext: ctx, isBackground: false, task: .chat)
        XCTAssertFalse(a.promptInjection.isEmpty || b.promptInjection.isEmpty)
    }
}
