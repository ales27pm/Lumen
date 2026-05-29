import XCTest
@testable import Lumen

final class SlotAgentPromptGroundingPathTests: XCTestCase {
    func testRoleMetadataAffectsAssembledPrompt() {
        let assembled = LegacyPromptAssembler.assemble(baseSystemPrompt: "sys", baseUserMessage: "hi", sections: [], policy: .slotAgent, roleMetadata: "planner")
        XCTAssertTrue(assembled.userMessage.contains("[ROLE STAGE]"))
        XCTAssertTrue(assembled.userMessage.contains("planner"))
    }
}
