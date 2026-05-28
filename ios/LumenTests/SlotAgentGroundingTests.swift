import XCTest
@testable import Lumen

final class SlotAgentGroundingTests: XCTestCase {
    func testPromptRendererCaps() {
        let s = [PromptGroundingSection(title: "mem", content: String(repeating: "a", count: 5000), estimatedChars: 5000, sourceIDs: [], privacyLevel: .moderate)]
        let rendered = PromptGroundingRenderer.renderForPrompt(s, maxChars: 300)
        XCTAssertLessThanOrEqual(rendered.count, 300)
    }
}
