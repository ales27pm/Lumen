import XCTest

final class AgentServicePromptGroundingPathTests: XCTestCase {
    func testAgentServiceUsesAssemblerInRunPath() throws {
        let source = try String(contentsOfFile: "ios/Lumen/Services/AgentService.swift")
        XCTAssertTrue(source.contains("applyLegacyGroundingAssembly"))
    }
}
