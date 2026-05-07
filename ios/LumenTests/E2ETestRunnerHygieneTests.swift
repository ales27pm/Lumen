import Foundation
import Testing
@testable import Lumen

struct E2ETestRunnerHygieneTests {
    @Test func rawThinkLeakFailsEvenWhenSanitizedFinalIsClean() {
        let scenario = E2ETestScenario(id: "s", title: "t", kind: .chat, prompt: "p", expectedIntent: .chat, forbiddenToolIDs: [], requiredTextHints: [], forbiddenTextHints: [], requiresAgentRun: false)
        let failures = E2ETestRunner.hygieneFailures(
            lowerRawFinal: "<think>secret</think> clean",
            lowerFinal: "clean",
            removedArtifacts: [.thinkBlock],
            scenario: scenario,
            observations: ""
        )
        #expect(failures.contains("Hidden reasoning leaked into final output"))
    }

    @Test func postRewriteThinkLeakFails() {
        let scenario = E2ETestScenario(id: "s", title: "t", kind: .chat, prompt: "p", expectedIntent: .chat, forbiddenToolIDs: [], requiredTextHints: [], forbiddenTextHints: [], requiresAgentRun: false)
        let failures = E2ETestRunner.hygieneFailures(lowerRawFinal: "clean", lowerFinal: "<think>x</think>", removedArtifacts: [], scenario: scenario, observations: "")
        #expect(failures.contains("Hidden reasoning leaked into final output"))
    }

    @Test func webPayloadFailuresAreDistinctAndDeduped() {
        let scenario = E2ETestScenario(id: "s", title: "t", kind: .chat, prompt: "p", expectedIntent: .chat, forbiddenToolIDs: [], requiredTextHints: [], forbiddenTextHints: [], requiresAgentRun: false)
        let failures = E2ETestRunner.hygieneFailures(
            lowerRawFinal: "<lumen_web_payload>{\"kind\":\"searchresults\",\"results\":[{\"mediakind\":\"page\"}]}</lumen_web_payload>",
            lowerFinal: "clean",
            removedArtifacts: [.lumenWebPayload, .rawToolPayload],
            scenario: scenario,
            observations: ""
        )
        #expect(failures.contains("Raw lumen_web_payload marker leaked into final output"))
        #expect(failures.contains("Raw search-results JSON leaked into final output"))
        #expect(failures.count == 2)
    }

    @Test func weatherUmbrellaOverreachStillFailsWithoutPrecipSignals() {
        let scenario = E2ETestScenario(id: "w", title: "w", kind: .chat, prompt: "p", expectedIntent: .weather, forbiddenToolIDs: [], requiredTextHints: [], forbiddenTextHints: [], requiresAgentRun: false)
        let failures = E2ETestRunner.hygieneFailures(lowerRawFinal: "bring umbrella", lowerFinal: "you should bring an umbrella", removedArtifacts: [], scenario: scenario, observations: "temperature 70 and sunny")
        #expect(failures.contains("Weather precipitation recommendation not grounded"))
    }

    @Test func cleanMarkdownLinkPassesHygieneChecks() {
        let scenario = E2ETestScenario(id: "c", title: "c", kind: .chat, prompt: "p", expectedIntent: .chat, forbiddenToolIDs: [], requiredTextHints: [], forbiddenTextHints: [], requiresAgentRun: false)
        let failures = E2ETestRunner.hygieneFailures(lowerRawFinal: "use [link](https://example.com)", lowerFinal: "use [link](https://example.com)", removedArtifacts: [], scenario: scenario, observations: "")
        #expect(failures.isEmpty)
    }
}

struct E2ETestResultExplicitInitializerTests {
    @Test func preservesPassedAndFailuresWithoutMutationFromCache() {
        _ = FinalOutputSanitizer.sanitizeUserVisibleText("<think>x</think>safe")
        let result = E2ETestResult(
            id: UUID(),
            scenarioID: "s",
            title: "t",
            prompt: "p",
            expectedIntent: "chat",
            actualIntent: "chat",
            passed: true,
            failures: ["A", "A"],
            finalText: "safe",
            missingHints: [],
            rewriteAttempted: false,
            rewriteSuccess: true,
            events: [],
            startedAt: Date(),
            finishedAt: Date(),
            rawFinalPrefix: "r",
            sanitizedFinalPrefix: "s",
            rawFinalHadUnsafeLeakage: false,
            sanitizedFinalRemovedArtifacts: ["x", "x"],
            outputHygieneFailures: ["H", "H"]
        )
        #expect(result.passed)
        #expect(result.failures == ["A"])
        #expect(result.sanitizedFinalRemovedArtifacts == ["x"])
        #expect(result.outputHygieneFailures == ["H"])
    }
}
