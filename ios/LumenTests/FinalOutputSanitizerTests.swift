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

    @Test func removesRawSearchResultsJSONObjectOutsidePayloadTags() {
        let raw = "Before {\"kind\":\"searchResults\",\"results\":[{\"mediaKind\":\"page\",\"title\":\"Doc\"}]} after"
        let out = FinalOutputSanitizer.sanitizeUserVisibleText(raw)
        #expect(out.text == "Before after")
        #expect(out.removedArtifacts.contains(.rawToolPayload))
        #expect(!out.text.contains("searchResults"))
        #expect(!out.text.contains("mediaKind"))
    }


    @Test func removesRawSearchResultsMarkerLineWhenJSONIsMalformed() {
        let raw = "Answer line\n{\"kind\":\"searchResults\",\"sourcePageURL\":\"https://example.com\"\nFollow-up"
        let out = FinalOutputSanitizer.sanitizeUserVisibleText(raw)
        #expect(out.text == "Answer line\nFollow-up")
        #expect(out.removedArtifacts.contains(.rawToolPayload))
    }

    @Test func removesBareSearchResultsJSONObject() {
        let raw = "{\"kind\":\"searchResults\",\"results\":[{\"mediaKind\":\"page\"}]}"
        let out = FinalOutputSanitizer.sanitizeUserVisibleText(raw)
        #expect(out.removedArtifacts.contains(.rawToolPayload))
        #expect(!out.text.lowercased().contains("searchresults"))
    }

    @Test func recoveredUnsafeOutputCanBeConsumedWithRawOrSanitizedText() {
        let raw = "<think>x</think>safe"
        let sanitized = FinalOutputSanitizer.sanitizeUserVisibleText(raw)
        let recoveredByRaw = FinalOutputSanitizer.consumeRecoveredUnsafeOutput(forSanitizedText: raw)
        #expect(recoveredByRaw?.text == sanitized.text)
        #expect(recoveredByRaw?.removedArtifacts.contains(.thinkBlock) == true)

        _ = FinalOutputSanitizer.sanitizeUserVisibleText(raw)
        let recoveredBySanitized = FinalOutputSanitizer.consumeRecoveredUnsafeOutput(forSanitizedText: sanitized.text)
        #expect(recoveredBySanitized?.text == sanitized.text)
        #expect(recoveredBySanitized?.removedArtifacts.contains(.thinkBlock) == true)
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

extension FinalOutputSanitizerTests {
    @Test func streamingSanitizerWithholdsSplitThinkMarker() {
        var sanitizer = StreamingFinalOutputSanitizer()
        let first = sanitizer.ingest("Hello <thi")
        let second = sanitizer.ingest("nk>secret</think> world")
        let finalization = sanitizer.finish()
        let final = finalization.final

        #expect(!first.lowercased().contains("<thi"))
        #expect(!second.lowercased().contains("think"))
        #expect(final.text == "Hello world")
        #expect(finalization.remainingDelta.isEmpty)
    }

    @Test func streamingSanitizerWithholdsSplitPayloadMarker() {
        var sanitizer = StreamingFinalOutputSanitizer()
        _ = sanitizer.ingest("Before <lumen_")
        let delta = sanitizer.ingest("web_payload>{\"kind\":\"searchResults\"}</lumen_web_payload> after")
        let final = sanitizer.finish().final

        #expect(!delta.lowercased().contains("lumen_web_payload"))
        #expect(final.text == "Before after")
    }

    @Test func streamingSanitizerWithholdsSplitRawJSONPayload() {
        var sanitizer = StreamingFinalOutputSanitizer()
        let one = sanitizer.ingest("Result: {\"kind\":\"search")
        let two = sanitizer.ingest("Results\",\"results\":[{\"mediaKind\":\"page\"}]}")
        let final = sanitizer.finish().final

        #expect(!one.lowercased().contains("searchresults"))
        #expect(!two.lowercased().contains("searchresults"))
        #expect(final.text == "Result:")
    }

    @Test func streamingFinalizationProvidesRemainingDeltaForWhitespaceNormalization() {
        var sanitizer = StreamingFinalOutputSanitizer()
        let streamed = sanitizer.ingest("Hello  <think>x</think>\n\nworld")
        let finalization = sanitizer.finish()

        #expect(streamed == "Hello")
        #expect(finalization.remainingDelta == " world")
        #expect(streamed + finalization.remainingDelta == finalization.final.text)
        #expect(finalization.final.text == "Hello world")
    }
}
