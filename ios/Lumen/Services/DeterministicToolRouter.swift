import Foundation

/// Executes high-confidence tool intents before the local LLM is invoked.
/// This prevents small local models from hallucinating tool output or leaking
/// dataset placeholders such as PRESIDIO_ANONYMIZED_PERSON for obvious commands.
nonisolated enum DeterministicToolRouter {
    struct Decision: Sendable, Equatable {
        enum Route: Sendable, Equatable {
            case directReply(String)
            case executeTool(toolID: String, arguments: [String: String], approval: ToolExecutionApproval)
        }

        let route: Route
        let confidence: Int
        let reason: String
    }

    static func decide(userMessage: String, enabledToolIDs: Set<String>) -> Decision? {
        let text = normalized(userMessage)
        guard !text.isEmpty else { return nil }

        if containsUnsafeBypassRequest(text) {
            return Decision(
                route: .directReply("I cannot fake tool results or pretend I accessed private data. Connect the required tool first, then I can use the real result."),
                confidence: 100,
                reason: "blocked fake tool-result request"
            )
        }

        if isEmailInboxReadIntent(text) {
            return Decision(
                route: .directReply(emailInboxNotConnectedMessage),
                confidence: 98,
                reason: "email inbox read intent is not supported by iOS sandbox / no email connector configured"
            )
        }

        if enabledToolIDs.contains("calendar.list"), isCalendarReadIntent(text) {
            return Decision(
                route: .executeTool(toolID: "calendar.list", arguments: [:], approval: .autonomous),
                confidence: 92,
                reason: "calendar read intent"
            )
        }

        if enabledToolIDs.contains("reminders.list"), isReminderReadIntent(text) {
            return Decision(
                route: .executeTool(toolID: "reminders.list", arguments: [:], approval: .autonomous),
                confidence: 90,
                reason: "reminders read intent"
            )
        }

        if enabledToolIDs.contains("weather"), isWeatherIntent(text) {
            return Decision(
                route: .executeTool(toolID: "weather", arguments: extractWeatherArguments(from: text), approval: .autonomous),
                confidence: 90,
                reason: "weather intent"
            )
        }

        if enabledToolIDs.contains("location.current"), isCurrentLocationIntent(text) {
            return Decision(
                route: .executeTool(toolID: "location.current", arguments: [:], approval: .autonomous),
                confidence: 90,
                reason: "current location intent"
            )
        }

        if enabledToolIDs.contains("contacts.search"), isContactSearchIntent(text) {
            return Decision(
                route: .executeTool(toolID: "contacts.search", arguments: ["query": extractContactQuery(from: userMessage)], approval: .autonomous),
                confidence: 88,
                reason: "contact search intent"
            )
        }

        if enabledToolIDs.contains("web.search"), isWebSearchIntent(text) {
            return Decision(
                route: .executeTool(toolID: "web.search", arguments: ["query": extractWebQuery(from: userMessage)], approval: .autonomous),
                confidence: 86,
                reason: "explicit web search intent"
            )
        }

        return nil
    }

    @MainActor
    static func routeAndRun(userMessage: String, enabledToolIDs: Set<String>) async -> String? {
        guard let decision = decide(userMessage: userMessage, enabledToolIDs: enabledToolIDs) else { return nil }

        switch decision.route {
        case .directReply(let text):
            return AssistantOutputSanitizer.sanitize(text, lastUserMessage: userMessage)
        case .executeTool(let toolID, let arguments, let approval):
            let result = await ToolExecutor.shared.execute(toolID, arguments: arguments, approval: approval)
            return AssistantOutputSanitizer.sanitize(result, lastUserMessage: userMessage)
        }
    }

    private static let emailInboxNotConnectedMessage = "Email inbox reading is not connected yet. iOS apps cannot freely read Apple Mail because of sandboxing. Connect a real Gmail, Outlook, or IMAP connector first; until then I can draft emails, but I cannot check your inbox."

    private static func normalized(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compacted(_ text: String) -> String {
        normalized(text).replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func containsUnsafeBypassRequest(_ text: String) -> Bool {
        containsAny(text, [
            "pretend you checked",
            "fake tool result",
            "simulate email access",
            "invent my emails",
            "bypass tool",
            "ignore tool safety"
        ])
    }

    private static func isEmailInboxReadIntent(_ text: String) -> Bool {
        let compact = compacted(text)
        if ["checkmyemail", "readmyemail", "showmyemail", "checkmail", "readmail", "openinbox", "checkinbox"].contains(compact) {
            return true
        }

        let hasInboxObject = containsAny(text, ["email", "emails", "mail", "inbox", "gmail", "outlook"])
        let hasReadVerb = containsAny(text, ["check", "read", "show", "open", "look at", "summarize", "what's in", "whats in"])
        let hasUnreadMarker = containsAny(text, ["unread", "new email", "new emails", "latest email", "latest emails"])
        let isDraftOnly = containsAny(text, ["draft email", "compose email", "write an email", "send email", "reply to"])

        return hasInboxObject && !isDraftOnly && (hasReadVerb || hasUnreadMarker)
    }

    private static func isCalendarReadIntent(_ text: String) -> Bool {
        let hasCalendarObject = containsAny(text, ["calendar", "schedule", "agenda", "meeting", "meetings", "appointments"])
        let hasReadVerb = containsAny(text, ["check", "show", "list", "what", "when", "upcoming", "today", "tomorrow"])
        let isWrite = containsAny(text, ["create", "add", "schedule a", "book", "put it on"])
        return hasCalendarObject && hasReadVerb && !isWrite
    }

    private static func isReminderReadIntent(_ text: String) -> Bool {
        let hasObject = containsAny(text, ["reminder", "reminders", "todo", "to do"])
        let hasReadVerb = containsAny(text, ["check", "show", "list", "what", "pending"])
        let isWrite = containsAny(text, ["create", "add", "set", "remind me"])
        return hasObject && hasReadVerb && !isWrite
    }

    private static func isWeatherIntent(_ text: String) -> Bool {
        containsAny(text, ["weather", "temperature", "forecast", "is it raining", "is it snowing", "rain today", "snow today", "wind today"])
    }

    private static func isCurrentLocationIntent(_ text: String) -> Bool {
        containsAny(text, ["where am i", "current location", "my location", "gps location", "coordinates"])
    }

    private static func isContactSearchIntent(_ text: String) -> Bool {
        containsAny(text, ["find contact", "search contacts", "phone number for", "phone number of", "email address for", "email address of"])
    }

    private static func isWebSearchIntent(_ text: String) -> Bool {
        containsAny(text, ["search the web", "web search", "look up", "find online", "research online", "google "])
    }

    private static func extractWeatherArguments(from text: String) -> [String: String] {
        let cityPrefixes = ["weather in ", "temperature in ", "forecast in "]
        for prefix in cityPrefixes where text.contains(prefix) {
            let city = text.components(separatedBy: prefix).last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !city.isEmpty { return ["location": city] }
        }
        return [:]
    }

    private static func extractContactQuery(from text: String) -> String {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalizedText.lowercased()
        let prefixes = ["find contact", "search contacts", "phone number for", "phone number of", "email address for", "email address of"]
        for prefix in prefixes where lower.contains(prefix) {
            if let range = lower.range(of: prefix) {
                let query = normalizedText[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !query.isEmpty { return query }
            }
        }
        return normalizedText
    }

    private static func extractWebQuery(from text: String) -> String {
        var query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = query.lowercased()
        let prefixes = ["search the web for ", "web search for ", "search for ", "look up ", "find online ", "research online ", "google "]
        for prefix in prefixes where lower.hasPrefix(prefix) {
            query = String(query.dropFirst(prefix.count))
            break
        }
        return query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
