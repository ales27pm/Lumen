//
//  LumenTests.swift
//  LumenTests
//
//  Created by Rork on April 20, 2026.
//

import Testing
@testable import Lumen

struct LumenTests {

    @Test func parserAcceptsNestedAction() async throws {
        let raw = #"{"thought":"look up data","action":{"tool":"weather.current","args":{"city":"Boston"}}}"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == nil)
        #expect(turn.action?.tool == "weather.current")
        #expect(turn.action?.args["city"] == "Boston")
        #expect(turn.final == nil)
    }

    @Test func parserAcceptsFlatAction() async throws {
        let raw = #"{"tool":"weather.current","args":{"city":"Boston"}}"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == nil)
        #expect(turn.action?.tool == "weather.current")
        #expect(turn.action?.args["city"] == "Boston")
    }

    @Test func parserRejectsMixedTurn() async throws {
        let raw = #"{"action":{"tool":"weather.current","args":{"city":"Boston"}},"final":"sunny"}"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == .mixedTurn)
        #expect(turn.action == nil)
        #expect(turn.final == nil)
    }

    @Test func parserAcceptsMultipleObjectsSelectingLastValidTurn() async throws {
        let raw = #"{"final":"first"}{"final":"second"}"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == nil)
        #expect(turn.final == "second")
        #expect(turn.action == nil)
    }

    @Test func parserAcceptsMultipleObjectsWithFirstMalformedSecondValid() async throws {
        let raw = #"{"final":bad}{"final":"second"}"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == nil)
        #expect(turn.final == "second")
    }

    @Test func parserAcceptsMultipleObjectsWithNoiseOutsideJSONRanges() async throws {
        let raw = #"note {"final":"first"} {"final":"second"}"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == nil)
        #expect(turn.final == "second")
        #expect(turn.hadNoise)
    }

    @Test func parserRejectsMultipleObjectsWhenAllAreInvalid() async throws {
        let raw = #"{"final":bad}{"action":42}"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == .multipleJSONObjects)
    }

    @Test func parserRejectsNonStringArgs() async throws {
        let raw = #"{"action":{"tool":"weather.current","args":{"days":3}}}"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == .invalidActionArgsType)
        #expect(turn.action == nil)
    }

    @Test func parserRejectsMalformedEscapes() async throws {
        let raw = #"{"final":"bad \q escape"}"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == .malformedEscapeSequence)
    }

    @Test func parserRejectsMissingActionAndFinal() async throws {
        let raw = #"{"thought":"I should think first"}"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == .missingActionOrFinal)
    }

    @Test func parserRejectsIncompleteJSON() async throws {
        let raw = #"{"final":"unterminated""#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == .incompleteJSON)
    }

    @Test func parserRejectsInvalidThoughtType() async throws {
        let raw = #"{"thought":123,"final":"x"}"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == .invalidThoughtType)
    }

    @Test func parserRejectsInvalidFinalType() async throws {
        let raw = #"{"thought":"ok","final":42}"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == .invalidFinalType)
    }

    @Test func parserAcceptsReasoningAndFinalAnswerAliases() async throws {
        let raw = #"{"reasoning":"Need no tools","final_answer":"All good"}"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == nil)
        #expect(turn.thought == "Need no tools")
        #expect(turn.final == "All good")
        #expect(turn.action == nil)
    }

    @Test func parserAcceptsNoisyOutputOutsideJSON() async throws {
        let raw = #"prefix {"final":"ok"} suffix"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == nil)
        #expect(turn.final == "ok")
        #expect(turn.hadNoise)
    }

    @Test func parserAcceptsCodeFenceWrappedJSON() async throws {
        let raw = """
        ```json
        {"final":"ok"}
        ```
        """
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == nil)
        #expect(turn.final == "ok")
        #expect(!turn.hadNoise)
    }

    @Test func parserSelectsDeterministicCandidateWithMultipleObjectsAndStrayText() async throws {
        let raw = #"notice {"final":"fallback"} stray {"tool":"web.search","args":{"query":"swift"}} trailing"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == nil)
        #expect(turn.action?.tool == "web.search")
        #expect(turn.action?.args["query"] == "swift")
        #expect(turn.hadNoise)
    }

    @Test func parserRejectsMixedActionShapes() async throws {
        let raw = #"{"action":{"tool":"web.search","args":{"query":"llama"}},"tool":"web.search","args":{"query":"llama"}}"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == .mixedActionShapes)
    }

    @Test func parserAcceptsNestedActionWithNameAliasAndArgumentsAlias() async throws {
        let raw = #"{"action":{"name":"web.search","arguments":{"query":"swift testing"}}}"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == nil)
        #expect(turn.action?.tool == "web.search")
        #expect(turn.action?.args["query"] == "swift testing")
    }

    @Test func parserAcceptsFlatActionUsingInputAlias() async throws {
        let raw = #"{"tool":"memory.save","input":{"content":"remember this","kind":"fact"}}"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == nil)
        #expect(turn.action?.tool == "memory.save")
        #expect(turn.action?.args["content"] == "remember this")
        #expect(turn.action?.args["kind"] == "fact")
    }

    @Test func parserRejectsNestedActionMissingToolName() async throws {
        let raw = #"{"action":{"args":{"query":"x"}}}"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == .missingActionTool)
    }

    @Test func parserRejectsFlatActionMissingToolName() async throws {
        let raw = #"{"args":{"query":"x"}}"#
        let turn = AgentTurnParser.parse(raw)
        #expect(turn.parseError == .missingActionTool)
    }

    @Test func streamingScannerEmitsThoughtThenFinalAcrossChunks() async throws {
        let scanner = StreamingJSONScanner()
        let events1 = scanner.feed(#"{"thought":"Plan"#)
        #expect(events1.count == 1)
        #expect(scanner.thought == "Plan")

        let events2 = scanner.feed(#" tool use","final":"Done"#)
        #expect(events2.count >= 1)
        #expect(scanner.thought == "Plan tool use")
        #expect(scanner.final == "Done")

        let events3 = scanner.feed(#""}"#)
        #expect(events3.isEmpty || scanner.final == "Done")
    }

    @Test func streamingScannerDecodesEscapes() async throws {
        let scanner = StreamingJSONScanner()
        _ = scanner.feed(#"{"thought":"line1\nline2","final":"tab\tok"}"#)
        #expect(scanner.thought == "line1\nline2")
        #expect(scanner.final == "tab\tok")
    }

    @Test func streamingScannerDecodesUnicodeEscapesAcrossChunks() async throws {
        let scanner = StreamingJSONScanner()
        _ = scanner.feed(#"{"thought":"Hello \u004"#)
        _ = scanner.feed(#"1","final":"\u263A"}"#)
        #expect(scanner.thought == "Hello A")
        #expect(scanner.final == "☺")
    }

    @Test func streamingScannerReturnsNoEventsWhenTrackedKeysAbsent() async throws {
        let scanner = StreamingJSONScanner()
        let events = scanner.feed(#"{"action":{"tool":"web.search","args":{"query":"x"}}}"#)
        #expect(events.isEmpty)
        #expect(scanner.thought.isEmpty)
        #expect(scanner.final.isEmpty)
    }

    @Test func agentActionDedupeKeyAndDisplayAreDeterministic() async throws {
        let action1 = AgentAction(tool: "web.search", args: ["q": "swift", "city": "Boston"])
        let action2 = AgentAction(tool: "web.search", args: ["city": "Boston", "q": "swift"])
        #expect(action1.dedupeKey == action2.dedupeKey)
        #expect(action1.displayContent == "web.search(city=Boston, q=swift)")
    }

    @Test @MainActor func toolExecutorReturnsUnknownToolMessage() async throws {
        let result = await ToolExecutor.shared.execute("tool.that.does.not.exist", arguments: [:])
        #expect(result == "Unknown tool: tool.that.does.not.exist")
    }

    @Test func agentStepCodecRoundTripPreservesValues() async throws {
        let original = [
            AgentStep(kind: .thought, content: "Need weather", toolID: nil, toolArgs: nil),
            AgentStep(kind: .action, content: "weather.current(city=Boston)", toolID: "weather.current", toolArgs: ["city": "Boston"]),
            AgentStep(kind: .observation, content: "72°F and sunny", toolID: "weather.current", toolArgs: nil),
            AgentStep(kind: .reflection, content: "Ready to answer", toolID: nil, toolArgs: nil)
        ]
        let encoded = AgentStepCodec.encode(original)
        #expect(encoded != nil)
        let decoded = AgentStepCodec.decode(encoded)
        #expect(decoded.count == original.count)
        #expect(decoded.map(\.kind) == original.map(\.kind))
        #expect(decoded.map(\.content) == original.map(\.content))
        #expect(decoded[1].toolID == "weather.current")
        #expect(decoded[1].toolArgs?["city"] == "Boston")
    }

}
