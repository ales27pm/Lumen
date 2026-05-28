import XCTest
@testable import Lumen

final class AgentServicePromptGroundingPathTests: XCTestCase {
    func testHasAssemblerType() {
        _ = LegacyPromptAssembler.self
        XCTAssertTrue(true)
    }
}
