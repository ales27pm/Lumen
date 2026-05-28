import XCTest
@testable import Lumen

final class LegacyPromptAssemblerIdempotencyTests: XCTestCase {
    func testAssemblerInjectsOnceWhenExistingGroundingPresent() {
        let sections = [PromptGroundingSection(title: "Relevant memories", content: "- x", estimatedChars: 0, sourceIDs: [], privacyLevel: .moderate)]
        let base = "Hello\n\n" + PromptGroundingIdempotencyGuard.marker + "\n[LOCAL MEMORY]\nold"
        let out = LegacyPromptAssembler.assemble(baseSystemPrompt: "sys", baseUserMessage: base, sections: sections, policy: .foregroundChat)
        let counts = PromptGroundingIdempotencyGuard.sectionOccurrenceCounts(out.userMessage)
        XCTAssertEqual(counts["[LOCAL MEMORY]"], 1)
    }
}
