import Testing
@testable import Lumen

struct FinalOutputSanitizerTests {
    @Test func removesCompleteThinkBlock() {
        let out = FinalOutputSanitizer.sanitizeUserVisibleText("<think>secret</think>Answer")
        #expect(out.text == "Answer")
        #expect(out.removedArtifacts.contains(.thinkBlock))
    }

    @Test func removesMalformedThinkPrefix() {
        let out = FinalOutputSanitizer.sanitizeUserVisibleText("<think>secret no close")
        #expect(!out.text.contains("<think"))
        #expect(out.removedArtifacts.contains(.malformedThinkPrefix))
    }

    @Test func preservesAnswerAfterThinkBlock() {
        let out = FinalOutputSanitizer.sanitizeUserVisibleText("<think>a</think>\n\nHi there")
        #expect(out.text == "Hi there")
    }

    @Test func removesLumenWebPayload() {
        let out = FinalOutputSanitizer.sanitizeUserVisibleText("Before <lumen_web_payload>{\"kind\":\"searchResults\"}</lumen_web_payload> after")
        #expect(out.text == "Before after")
        #expect(out.removedArtifacts.contains(.lumenWebPayload))
    }

    @Test func handlesOutputThatBecomesEmpty() {
        let out = FinalOutputSanitizer.sanitizeUserVisibleText("<think>only</think>")
        #expect(out.removedArtifacts.contains(.emptyAfterSanitization))
        #expect(!out.text.isEmpty)
    }

    @Test func preservesMarkdownAndLinks() {
        let out = FinalOutputSanitizer.sanitizeUserVisibleText("Use **bold** and [link](https://example.com)")
        #expect(out.text.contains("**bold**"))
        #expect(out.text.contains("https://example.com"))
    }

    @Test func deterministicRepeatedCalls() {
        let raw = "<think>x</think> Answer"
        #expect(FinalOutputSanitizer.sanitizeUserVisibleText(raw) == FinalOutputSanitizer.sanitizeUserVisibleText(raw))
    }
}
