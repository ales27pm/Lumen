import Foundation

nonisolated struct IntentAlternative: Sendable, Codable, Hashable {
    let intent: UserIntent
    let confidence: Double
}

nonisolated struct IntentClassificationResult: Sendable, Codable {
    enum Source: String, Sendable, Codable {
        case bundledModel
        case deterministicFallback
        case policyMerged
        case unavailable
    }

    let intent: UserIntent
    let confidence: Double
    let alternatives: [IntentAlternative]
    let requiresClarification: Bool
    let clarificationPrompt: String?
    let source: Source
    let diagnostics: String?

    func asRoutingDecision() -> IntentRoutingDecision {
        IntentRoutingDecision(
            intent: intent,
            allowedToolIDs: IntentToolMapping.allowedToolIDs(for: intent),
            requiresClarification: requiresClarification,
            clarificationPrompt: clarificationPrompt
        )
    }
}

nonisolated enum IntentToolMapping {
    private static let mapping: [UserIntent: Set<String>] = Dictionary(uniqueKeysWithValues: UserIntent.allCases.map { ($0, IntentRouter.allowedToolIDs(for: $0)) })

    static func allowedToolIDs(for intent: UserIntent) -> Set<String> {
        mapping[intent] ?? []
    }
}
