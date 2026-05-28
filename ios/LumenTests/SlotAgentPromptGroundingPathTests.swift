import XCTest
@testable import Lumen

final class SlotAgentPromptGroundingPathTests: XCTestCase {
    func testPolicyAvailable() { XCTAssertFalse(LegacyPromptInjectionPolicy.slotAgent.allowSensitiveSections) }
}
