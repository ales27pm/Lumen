import Foundation

nonisolated enum AssistantOutputSanitizer {
    private static let safeCalendarFallback = "Hi. I did not create a calendar event."

    static func sanitize(_ text: String, lastUserMessage: String? = nil) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if isFalseCalendarCreationClaim(trimmed, lastUserMessage: lastUserMessage) {
            return safeCalendarFallback
        }

        return trimmed
    }

    static func isFalseCalendarCreationClaim(_ text: String, lastUserMessage: String? = nil) -> Bool {
        let normalized = text.lowercased()
        let claimsCalendarCreation =
            normalized.contains("successfully created a new event") ||
            normalized.contains("created a new event") ||
            normalized.contains("created event") ||
            normalized.contains("calendar event")

        guard claimsCalendarCreation else { return false }

        let mentionsGreetingEvent =
            normalized.contains("hi lumen") ||
            normalized.contains("titled \"hi\"") ||
            normalized.contains("titled 'hi'") ||
            normalized.contains("title: hi")

        let userWasOnlyGreeting: Bool = {
            guard let lastUserMessage else { return false }
            let compact = lastUserMessage
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
            return ["hi", "hello", "hey", "hilumen", "hellolumen", "heylumen"].contains(compact)
        }()

        return mentionsGreetingEvent || userWasOnlyGreeting
    }
}
