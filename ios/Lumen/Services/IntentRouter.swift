import Foundation

nonisolated enum UserIntent: String, Sendable {
    case weather
    case webSearch
    case emailDraft
    case calendar
    case reminder
    case note
    case chat
    case unknown
}

nonisolated struct IntentRoutingDecision: Sendable {
    let intent: UserIntent
    let allowedToolIDs: Set<String>
    let requiresClarification: Bool
    let clarificationPrompt: String?
}

nonisolated enum IntentRouter {
    private static let weatherToolIDs: Set<String> = ["weather", "location.current"]
    private static let webSearchToolIDs: Set<String> = ["web.search", "web.fetch"]
    private static let emailToolIDs: Set<String> = ["mail.draft", "contacts.search"]
    private static let calendarToolIDs: Set<String> = ["calendar.create", "calendar.list"]
    private static let reminderToolIDs: Set<String> = ["reminders.create", "reminders.list"]
    private static let noteToolIDs: Set<String> = ["memory.save", "memory.recall"]

    static func classify(_ userMessage: String) -> IntentRoutingDecision {
        let text = normalized(userMessage)
        guard !text.isEmpty else {
            return IntentRoutingDecision(intent: .chat, allowedToolIDs: [], requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["weather", "forecast", "temperature", "what is it like outside", "weather here"]) {
            return IntentRoutingDecision(intent: .weather, allowedToolIDs: weatherToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["search web", "search the web", "look online", "find online", "web search", "google"]) {
            return IntentRoutingDecision(intent: .webSearch, allowedToolIDs: webSearchToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["draft an email", "draft a email", "write an email", "compose email", "email to"]) {
            let recipient = inferredRecipient(text)
            let content = inferredContent(text)
            let clarification: String?
            if !recipient && !content {
                clarification = "Who should I send it to, and what should it say?"
            } else if !recipient {
                clarification = "Who should I send it to?"
            } else if !content {
                clarification = "What should the email say?"
            } else {
                clarification = nil
            }
            return IntentRoutingDecision(
                intent: .emailDraft,
                allowedToolIDs: emailToolIDs,
                requiresClarification: clarification != nil,
                clarificationPrompt: clarification
            )
        }

        if matchesAny(text, ["remind me", "reminder", "todo", "to do"]) {
            return IntentRoutingDecision(intent: .reminder, allowedToolIDs: reminderToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["schedule", "calendar", "create event", "meeting", "appointment", "at 5", "tomorrow at"]) {
            return IntentRoutingDecision(intent: .calendar, allowedToolIDs: calendarToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["note", "save this", "remember this"]) {
            return IntentRoutingDecision(intent: .note, allowedToolIDs: noteToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        return IntentRoutingDecision(intent: .chat, allowedToolIDs: [], requiresClarification: false, clarificationPrompt: nil)
    }

    static func isToolAllowed(_ toolID: String, for decision: IntentRoutingDecision) -> Bool {
        if decision.allowedToolIDs.isEmpty { return false }
        let canonical = ToolRouteGuard.canonicalToolID(toolID)
        return decision.allowedToolIDs.contains(canonical)
    }

    static func intentRequiresTool(_ decision: IntentRoutingDecision) -> Bool {
        switch decision.intent {
        case .weather, .webSearch, .emailDraft, .calendar, .reminder, .note:
            return true
        case .chat, .unknown:
            return false
        }
    }

    static func unavailableMessage(for decision: IntentRoutingDecision) -> String {
        switch decision.intent {
        case .webSearch:
            return "Web search is not available in this build yet."
        case .weather:
            return "Weather tools are unavailable right now. Please enable weather/location tools or provide a city."
        case .emailDraft:
            return "Email drafting is not available in this build yet."
        case .calendar:
            return "Calendar tools are unavailable in this build right now."
        case .reminder:
            return "Reminder tools are unavailable in this build right now."
        case .note:
            return "Notes/memory tools are unavailable in this build right now."
        case .chat, .unknown:
            return "I can answer directly, but no matching tool is available for that action."
        }
    }

    static func blockedToolMessage(for decision: IntentRoutingDecision) -> String {
        switch decision.intent {
        case .webSearch:
            return "That request is a web search. I can only use web search tools for it, not calendar or reminder tools."
        case .weather:
            return "That request is about weather. I can only use weather/location tools for it."
        case .emailDraft:
            return "That request is for drafting an email. I can only use email composition tools for it."
        case .calendar:
            return "That request is calendar-related. I can only use calendar tools for it."
        case .reminder:
            return "That request is reminder-related. I can only use reminder tools for it."
        case .note:
            return "That request is note-related. I can only use note/memory tools for it."
        case .chat, .unknown:
            return "That tool doesn't match your request. Could you clarify what you want to do?"
        }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchesAny(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.contains($0) }
    }

    private static func inferredRecipient(_ text: String) -> Bool {
        text.contains(" to ") || text.contains("email to") || text.contains("@")
    }

    private static func inferredContent(_ text: String) -> Bool {
        text.contains(" about ") || text.contains(" saying ") || text.contains(" body ") || text.contains(" that says ") || text.split(separator: " ").count >= 8
    }
}
