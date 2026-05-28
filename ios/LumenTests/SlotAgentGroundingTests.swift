import XCTest
@testable import Lumen

final class SlotAgentGroundingTests: XCTestCase {
    func testSlotPolicyBudgetDefined() {
        XCTAssertGreaterThan(LegacyPromptInjectionPolicy.slotAgent.memoryMax, 0)
    }
}
