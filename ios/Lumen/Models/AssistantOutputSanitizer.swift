import Foundation

nonisolated enum AssistantOutputSanitizer {
    static func sanitize(_ text: String, lastUserMessage: String? = nil) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if isPrivacyPlaceholderArtifact(trimmed) {
            return neutralFallback(for: lastUserMessage)
        }

        if isFalseToolClaim(trimmed, lastUserMessage: lastUserMessage) {
            return neutralFallback(for: lastUserMessage)
        }

        return trimmed
    }

    static func isFalseToolClaim(_ text: String, lastUserMessage: String? = nil) -> Bool {
        isFalseCalendarCreationClaim(text, lastUserMessage: lastUserMessage)
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

        return mentionsGreetingEvent || isPureConversation(lastUserMessage)
    }

    static func isPrivacyPlaceholderArtifact(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.hasPrefix("<") && normalized.hasSuffix(">") else { return false }
        return normalized.contains("PRESIDIO_ANONYMIZED_") || normalized.contains("ANONYMIZED_PERSON")
    }

    static func neutralFallback(for lastUserMessage: String?) -> String {
        guard let lastUserMessage else { return "I couldn't complete that cleanly. Try again, or give me one more detail." }
        let compact = compacted(lastUserMessage)
        switch compact {
        case "hi", "hello", "hey", "yo", "sup", "bonjour", "salut", "allo":
            return "Hi."
        case "thanks", "thankyou", "merci":
            return "You're welcome."
        case "ok", "okay":
            return "OK."
        default:
            return "I couldn't complete that cleanly. Try again, or give me one more detail."
        }
    }

    static func isPureConversation(_ text: String?) -> Bool {
        guard let text else { return false }
        let compact = compacted(text)
        return [
            "hi", "hello", "hey", "yo", "sup", "bonjour", "salut", "allo",
            "ok", "okay", "thanks", "thankyou", "merci"
        ].contains(compact)
    }

    private static func compacted(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }
}
