import XCTest
@testable import Lumen

final class SafeToolOutputLimiterTests: XCTestCase {
    func testTruncates() {
        let r = ToolResult(invocationID: UUID(), status: .success, displayText: String(repeating: "a", count: 20), modelText: String(repeating: "b", count: 20), structuredPayload: nil, privacyLevel: .low, metricsSummary: "", errorCode: nil)
        let out = SafeToolOutputLimiter.limit(result: r, maxOutput: 10)
        XCTAssertTrue(out.displayText.contains("truncated"))
    }
}
