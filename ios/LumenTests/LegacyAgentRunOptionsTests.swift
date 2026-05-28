import XCTest
@testable import Lumen

final class LegacyAgentRunOptionsTests: XCTestCase {
    func testDefaults() {
        let o = LegacyAgentRunOptions.default
        XCTAssertTrue(o.allowDegradedGrounding)
        XCTAssertTrue(o.preventDoubleGrounding)
    }
}
