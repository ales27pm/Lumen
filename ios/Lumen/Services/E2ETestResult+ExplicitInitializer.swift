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
        let recovered = FinalOutputSanitizer.consumeRecoveredUnsafeOutput(forSanitizedText: finalText)
        let recoveredArtifacts = recovered?.removedArtifacts.map(\.rawValue) ?? []
        let recoveredHygieneFailures = Self.hygieneFailures(from: recoveredArtifacts)
        let mergedHygieneFailures = Self.merged(outputHygieneFailures, recoveredHygieneFailures)
        let mergedFailures = Self.merged(failures, recoveredHygieneFailures)
        let mergedRemovedArtifacts = Self.merged(sanitizedFinalRemovedArtifacts, recoveredArtifacts)
        let effectiveHadLeakage = rawFinalHadUnsafeLeakage || recovered?.hadUnsafeLeakage == true

        self.id = id
        self.scenarioID = scenarioID
        self.title = title
        self.prompt = prompt
        self.expectedIntent = expectedIntent
        self.actualIntent = actualIntent
        self.passed = passed && recoveredHygieneFailures.isEmpty
        self.failures = mergedFailures
        self.finalText = finalText
        self.missingHints = missingHints
        self.rewriteAttempted = rewriteAttempted
        self.rewriteSuccess = rewriteSuccess
        self.events = events
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.rawFinalPrefix = rawFinalPrefix
        self.sanitizedFinalPrefix = sanitizedFinalPrefix.isEmpty ? String(finalText.prefix(220)) : sanitizedFinalPrefix
        self.rawFinalHadUnsafeLeakage = effectiveHadLeakage
        self.sanitizedFinalRemovedArtifacts = mergedRemovedArtifacts
        self.outputHygieneFailures = mergedHygieneFailures
    }

    private static func hygieneFailures(from artifactRawValues: [String]) -> [String] {
        var failures: [String] = []
        if artifactRawValues.contains(FinalOutputArtifact.thinkBlock.rawValue)
            || artifactRawValues.contains(FinalOutputArtifact.malformedThinkPrefix.rawValue) {
            failures.append("Hidden reasoning leaked into final output")
        }
        if artifactRawValues.contains(FinalOutputArtifact.lumenWebPayload.rawValue)
            || artifactRawValues.contains(FinalOutputArtifact.rawToolPayload.rawValue) {
            failures.append("Raw web payload leaked into final output")
        }
        if artifactRawValues.contains(FinalOutputArtifact.emptyAfterSanitization.rawValue) {
            failures.append("Final output empty after sanitization")
        }
        return failures
    }

    private static func merged(_ lhs: [String], _ rhs: [String]) -> [String] {
        var result: [String] = []
        for item in lhs + rhs where !result.contains(item) {
            result.append(item)
        }
        return result
    }
}
