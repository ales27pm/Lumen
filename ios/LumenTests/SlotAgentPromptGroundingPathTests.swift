import XCTest

final class SlotAgentPromptGroundingPathTests: XCTestCase {
    func testSlotAgentUsesAssemblerInRunPath() throws {
        let source = try String(contentsOfFile: "ios/Lumen/Services/SlotAgentService.swift")
        XCTAssertTrue(source.contains("applyLegacyGroundingAssembly"))
    }
}
