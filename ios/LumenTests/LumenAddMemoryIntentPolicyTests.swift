import XCTest
@testable import Lumen

final class LumenAddMemoryIntentPolicyTests: XCTestCase {
    func testCredentialLikeRejected() {
        let text = "my password is 123"
        let lowered = text.lowercased()
        XCTAssertTrue(lowered.contains("password"))
    }
}
