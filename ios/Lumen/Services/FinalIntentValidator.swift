import Foundation

nonisolated enum FinalIntentValidator {
    static func validate(_ text: String, routing: IntentRoutingDecision, fallback: String?) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = clean.lowercased()

        if isValid(clean, lower: lower, for: routing) {
            return clean
        }

        if let fallback {
            let fallbackClean = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackLower = fallbackClean.lowercased()
            if isValid(fallbackClean, lower: fallbackLower, for: routing) {
                return fallbackClean
            }
        }

        return safeMessage(for: routing)
    }

    private static func isValid(_ text: String, lower: String, for routing: IntentRoutingDecision) -> Bool {
        guard !text.isEmpty else { return false }
        guard !looksLikeCalendarLeak(lower, unless: routing.intent == .calendar) else { return false }
        guard !looksLikeWeatherLeak(lower, unless: routing.intent == .weather) else { return false }
        guard !looksLikeEmailLeak(lower, unless: routing.intent == .emailDraft) else { return false }
        guard !looksLikeWebSearchLeak(lower, unless: routing.intent == .webSearch) else { return false }

        switch routing.intent {
        case .weather:
            return containsAny(lower, ["weather", "temperature", "humidity", "wind", "feels like", "°c", "rain", "snow", "cloud"])
        case .webSearch:
            return containsAny(lower, ["web", "search", "result", "http", "source", "found", "not available"])
        case .emailDraft:
            if lower.contains("i will be in touch soon") { return false }
            return !looksLikeCalendarLeak(lower, unless: false) && !looksLikeWeatherLeak(lower, unless: false)
        case .calendar:
            return containsAny(lower, ["calendar", "event", "schedule", "meeting", "appointment", "requires explicit user approval", "did not create"])
        case .reminder:
            return containsAny(lower, ["reminder", "todo", "to-do", "requires explicit user approval", "did not create"])
        case .note:
            return !looksLikeCalendarLeak(lower, unless: false) && !looksLikeWeatherLeak(lower, unless: false)
        case .chat, .unknown:
            return true
        }
    }

    private static func safeMessage(for routing: IntentRoutingDecision) -> String {
        switch routing.intent {
        case .weather:
            return "I couldn’t safely complete the current weather request. Please enable location/weather access or tell me the city."
        case .webSearch:
            return "I couldn’t safely complete the web search request. I did not create a calendar event."
        case .emailDraft:
            return routing.clarificationPrompt ?? "Who should I send it to, and what should it say?"
        case .calendar:
            return "I couldn’t safely complete the calendar request."
        case .reminder:
            return "I couldn’t safely complete the reminder request."
        case .note:
            return "I couldn’t safely complete the note request."
        case .chat, .unknown:
            return "I hit a routing error. Please try again."
        }
    }

    private static func looksLikeCalendarLeak(_ lower: String, unless allowed: Bool) -> Bool {
        !allowed && containsAny(lower, ["created a new event", "successfully created", "calendar event", "will start in", "starts in 5 minutes"])
    }

    private static func looksLikeWeatherLeak(_ lower: String, unless allowed: Bool) -> Bool {
        !allowed && containsAny(lower, ["weather for", "weather at", "temperature", "humidity", "feels like", "wind ", "clear sky"])
    }

    private static func looksLikeEmailLeak(_ lower: String, unless allowed: Bool) -> Bool {
        !allowed && containsAny(lower, ["dear ", "subject:", "best regards", "sincerely", "i will be in touch soon"])
    }

    private static func looksLikeWebSearchLeak(_ lower: String, unless allowed: Bool) -> Bool {
        !allowed && containsAny(lower, ["web search", "search result", "http://", "https://"])
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }
}
