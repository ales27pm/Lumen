import Testing
@testable import Lumen

struct ToolOutputHygieneTests {
    @Test func hygieneRejectsForbiddenArtifacts() {
        let scenario = E2ETestScenario(id: "h", title: "h", kind: .chat, prompt: "p", expectedIntent: .chat, forbiddenToolIDs: [], requiredTextHints: [], forbiddenTextHints: [], requiresAgentRun: false)
        let forbidden = ["<think hidden", "</think>", "Okay, the user wants", "Let me check", "{\"tool\":\"web.search\"}", "<lumen_web_payload>", "debug text", "noJSONObject"]
        for text in forbidden {
            let failures = E2ETestRunner.hygieneFailures(lowerRawFinal: text.lowercased(), lowerFinal: text.lowercased(), removedArtifacts: [], scenario: scenario, observations: "")
            #expect(!failures.isEmpty)
        }
    }
}
