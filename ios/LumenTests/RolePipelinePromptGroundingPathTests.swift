import XCTest
@testable import Lumen

final class RolePipelinePromptGroundingPathTests: XCTestCase {
    func testPolicyAvailable() { XCTAssertFalse(LegacyPromptInjectionPolicy.rolePipeline.allowSensitiveSections) }
}
