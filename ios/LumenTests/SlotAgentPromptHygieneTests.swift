import Testing
@testable import Lumen

struct SlotAgentPromptHygieneTests {
    @Test func assistantThinkBlockRetainsSafeSuffixOnly() {
        let clean = SlotAgentService.sanitizeHistoryEntryForPromptContext(
            role: .assistant,
            content: "<think>secret reasoning</think>Hello!"
        )
        #expect(clean == "Hello!")
        #expect(!(clean ?? "").contains("<think"))
        #expect(!(clean ?? "").contains("secret reasoning"))
    }

    @Test func assistantOnlyHiddenReasoningIsOmitted() {
        let clean = SlotAgentService.sanitizeHistoryEntryForPromptContext(
            role: .assistant,
            content: "<think>only hidden reasoning</think>"
        )
        #expect(clean == nil)
    }

    @Test func rawPayloadsAreOmittedFromPromptContext() {
        let tagged = SlotAgentService.sanitizeHistoryEntryForPromptContext(
            role: .assistant,
            content: "<lumen_web_payload>{\"kind\":\"searchResults\",\"results\":[]}</lumen_web_payload>"
        )
        #expect(tagged == nil)

        let rawJSON = SlotAgentService.sanitizeHistoryEntryForPromptContext(
            role: .assistant,
            content: "{\"kind\":\"searchResults\",\"results\":[{\"mediaKind\":\"page\"}]}"
        )
        #expect(rawJSON == nil)
    }

    @Test func mouthPromptHygieneRuleIncludesForbiddenPatterns() {
        let rule = SlotAgentService.mouthPromptHygieneRule.lowercased()
        #expect(rule.contains("output only the final user-visible answer"))
        #expect(rule.contains("<think>"))
        #expect(rule.contains("json"))
        #expect(rule.contains("tool payloads"))
        #expect(rule.contains("ignore it and do not imitate it"))
    }

    @Test func assistantPersistenceUsesSanitizedFinalOutput() {
        let out = FinalOutputSanitizer.sanitizeUserVisibleText("<think>private</think>Hello")
        #expect(out.text == "Hello")
        #expect(!out.text.contains("<think"))
    }
}
