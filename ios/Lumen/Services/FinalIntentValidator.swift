import Foundation

nonisolated enum FinalIntentValidator {
    static func validate(_ text: String, routing: IntentRoutingDecision, fallback: String?) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = clean.lowercased()
        switch routing.intent {
        case .weather:
            if lower.contains("new event") || lower.contains("calendar") {
                return fallback?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? fallback! : "I could not safely complete the weather request."
            }
        case .webSearch:
            if lower.contains("new event") || lower.contains("calendar") {
                return "I could not safely complete the web search request."
            }
        case .emailDraft:
            if lower.contains("i will be in touch soon") {
                return routing.clarificationPrompt ?? "Who should I send it to, and what should it say?"
            }
        case .calendar, .reminder, .note, .chat, .unknown:
            break
        }
        return clean
    }
}
