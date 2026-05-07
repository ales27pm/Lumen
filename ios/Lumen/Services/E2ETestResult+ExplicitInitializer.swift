import Foundation

extension E2ETestResult {
    init(
        id: UUID,
        scenarioID: String,
        title: String,
        prompt: String,
        expectedIntent: String,
        actualIntent: String,
        passed: Bool,
        failures: [String],
        finalText: String,
        missingHints: [String],
        rewriteAttempted: Bool,
        rewriteSuccess: Bool,
        events: [E2ETestEvent],
        startedAt: Date,
        finishedAt: Date,
        rawFinalPrefix: String,
        sanitizedFinalPrefix: String,
        rawFinalHadUnsafeLeakage: Bool,
        sanitizedFinalRemovedArtifacts: [String],
        outputHygieneFailures: [String]
    ) {
        self.id = id
        self.scenarioID = scenarioID
        self.title = title
        self.prompt = prompt
        self.expectedIntent = expectedIntent
        self.actualIntent = actualIntent
        self.passed = passed
        self.failures = failures
        self.finalText = finalText
        self.missingHints = missingHints
        self.rewriteAttempted = rewriteAttempted
        self.rewriteSuccess = rewriteSuccess
        self.events = events
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.rawFinalPrefix = rawFinalPrefix
        self.sanitizedFinalPrefix = sanitizedFinalPrefix
        self.rawFinalHadUnsafeLeakage = rawFinalHadUnsafeLeakage
        self.sanitizedFinalRemovedArtifacts = sanitizedFinalRemovedArtifacts
        self.outputHygieneFailures = outputHygieneFailures
    }
}
