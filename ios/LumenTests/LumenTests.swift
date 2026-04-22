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

    @Test func parserRejectsMultipleObjects() async throws {
        let raw = #"{"final":"first"}{"final":"second"}"#
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

}
