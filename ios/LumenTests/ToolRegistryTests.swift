import XCTest
@testable import Lumen

final class ToolRegistryTests: XCTestCase {
    func testBackgroundHidesSensitive() async {
        let ctx = ToolExecutionContext(isForeground: false, appState: nil, modelContext: nil, permissionRegistry: .shared, metricsStore: RuntimeMetricsStore.shared)
        let defs = await ToolRegistry.shared.availableDefinitions(context: ctx, source: .backgroundTrigger)
        XCTAssertFalse(defs.contains(where: { $0.category == .sensitiveAction }))
    }
}
