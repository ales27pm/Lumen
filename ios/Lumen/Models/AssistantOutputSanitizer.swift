import Foundation

nonisolated enum AssistantOutputSanitizer {
    private static let leakedAnonymizerTokens = [
        "<PRESIDIO_ANONYMIZED_PERSON>",
        "PRESIDIO_ANONYMIZED_PERSON",
        "<PRESIDIO_ANONYMIZED_EMAIL_ADDRESS>",
        "PRESIDIO_ANONYMIZED_EMAIL_ADDRESS",
        "<PRESIDIO_ANONYMIZED_PHONE_NUMBER>",
        "PRESIDIO_ANONYMIZED_PHONE_NUMBER",
        "<ANONYMIZED_PERSON>",
        "ANONYMIZED_PERSON"
    ]

    static func sanitize(_ text: String, lastUserMessage: String? = nil) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if containsLeakedAnonymizerToken(trimmed) {
            return deterministicToolFallback(for: lastUserMessage)
        }

        if isFalseToolClaim(trimmed, lastUserMessage: lastUserMessage) {
            return neutralFallback(for: lastUserMessage)
        }

        return trimmed
    }

    static func containsLeakedAnonymizerToken(_ text: String) -> Bool {
        leakedAnonymizerTokens.contains { text.contains($0) }
    }

    static func deterministicToolFallback(for lastUserMessage: String?) -> String {
        guard let lastUserMessage else {
            return "The response contained anonymized placeholder data instead of usable content. Please retry the request."
        }

        let normalized = lastUserMessage.lowercased()
        if normalized.contains("email") || normalized.contains("mail") || normalized.contains("inbox") {
            return "Email inbox reading is not connected yet. iOS apps cannot freely read Apple Mail because of sandboxing. Connect a real Gmail, Outlook, or IMAP connector first; until then I can draft emails, but I cannot check your inbox."
        }

        return "The response contained anonymized placeholder data instead of usable content. Please retry the request through the deterministic tool router."
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

    static func neutralFallback(for lastUserMessage: String?) -> String {
        guard let lastUserMessage else { return "Hi." }
        let compact = compacted(lastUserMessage)
        switch compact {
        case "hi", "hello", "hey", "yo", "sup", "bonjour", "salut", "allo":
            return "Hi."
        case "thanks", "thankyou", "merci":
            return "You're welcome."
        case "ok", "okay":
            return "OK."
        default:
            return "I understand."
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
