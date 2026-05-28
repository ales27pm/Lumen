import XCTest

final class RolePipelinePromptGroundingPathTests: XCTestCase {
    func testRolePipelineUsesAssemblerInRunPath() throws {
        let source = try String(contentsOfFile: "ios/Lumen/Services/RolePipelineAgentService.swift")
        XCTAssertTrue(source.contains("applyLegacyGroundingAssembly"))
    }
}
