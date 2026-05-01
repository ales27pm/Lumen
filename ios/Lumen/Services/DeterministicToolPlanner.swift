import Foundation

nonisolated enum DeterministicToolPlanner {
    static func plan(routing: IntentRoutingDecision, prompt: String, availableToolIDs: Set<String>) -> AgentAction? {
        let text = normalized(prompt)

        func has(_ tool: String) -> Bool { availableToolIDs.contains(tool) }
        func action(_ tool: String, _ args: AgentJSONArguments = [:]) -> AgentAction? {
            guard has(tool) else { return nil }
            return AgentAction(tool: tool, args: args)
        }

        switch routing.intent {
        case .webSearch:
            if has("web.fetch"), let url = firstURL(in: prompt) { return AgentAction(tool: "web.fetch", args: ["url": .string(url)]) }
            guard has("web.search") else { return nil }
            let query = extractWebQuery(from: prompt)
            return query.isEmpty ? nil : AgentAction(tool: "web.search", args: ["query": .string(query)])
        case .outlook:
            return planOutlook(text: text, prompt: prompt, availableToolIDs: availableToolIDs)
        case .weather:
            if has("weather") {
                if let destination = extractDestination(from: prompt) { return action("weather", ["location": .string(destination)]) }
                return action("weather")
            }
            return action("location.current")
        case .maps:
            if routing.allowedToolIDs == ["location.current"] || containsAny(text, ["where are we", "where am i", "current location", "my location"]) { return action("location.current") }
            if containsAny(text, ["directions", "navigate", "route"]) { return action("maps.directions", ["destination": .string(extractDestination(from: prompt) ?? "")]) }
            if containsAny(text, ["nearby", "near me", "closest"]) { return action("maps.search", ["query": .string(extractDestination(from: prompt) ?? "")]) }
            return nil
        case .calendar:
            if containsAny(text, ["list", "show", "upcoming", "today", "tomorrow"]) { return action("calendar.list") }
            return nil
        case .reminder:
            if containsAny(text, ["list", "show", "pending"]) { return action("reminders.list") }
            if containsAny(text, ["create", "add", "remind me"]), let body = extractOutlookBody(from: prompt), !body.isEmpty { return action("reminders.create", ["title": .string(body)]) }
            return nil
        case .contactSearch:
            if let q = extractContactQuery(from: prompt), !q.isEmpty { return action("contacts.search", ["query": .string(q)]) }
            return nil
        case .photos: return action("photos.search", ["query": .string(extractDestination(from: prompt) ?? "")])
        case .health: return action("health.summary")
        case .motion: return action("motion.activity")
        case .files:
            if let name = extractFileName(from: prompt) { return action("files.read", ["name": .string(name)]) }
            return nil
        case .memory:
            if containsAny(text, ["what do you remember", "recall", "remember about"]) { return action("memory.recall", ["query": .string(extractContactQuery(from: prompt) ?? "")]) }
            if containsAny(text, ["remember", "save"]) { return action("memory.save", ["text": .string(prompt)]) }
            return nil
        case .rag:
            if containsAny(text, ["reindex", "index files"]) { return action("rag.index_files") }
            if containsAny(text, ["index photos", "reindex photos"]) { return action("rag.index_photos") }
            if containsAny(text, ["search"]) { return action("rag.search", ["query": .string(extractWebQuery(from: prompt))]) }
            return nil
        case .alarm:
            if containsAny(text, ["list", "status"]) { return action("alarm.list") ?? action("alarm.authorization_status") }
            return nil
        case .trigger:
            if text.contains("list") { return action("trigger.list") }
            if text.contains("cancel"), let token = extractContactQuery(from: prompt), !token.isEmpty { return action("trigger.cancel", ["id": .string(token)]) }
            return nil
        default:
            return nil
        }
    }

    private static func planOutlook(text: String, prompt: String, availableToolIDs: Set<String>) -> AgentAction? {
        func can(_ tool: String) -> Bool { availableToolIDs.contains(tool) }
        func action(_ tool: String, _ args: AgentJSONArguments = [:]) -> AgentAction? { can(tool) ? AgentAction(tool: tool, args: args) : nil }
        if containsAny(text, ["read", "open", "latest email", "last email"]) { return action("outlook.message.read", ["message": .string(extractOutlookMessageReference(from: text) ?? "latest")]) }
        if containsAny(text, ["search", "find", "invoice"]) {
            let q = extractOutlookSearchQuery(from: prompt)
            if !q.isEmpty { return action("outlook.messages.search", ["query": .string(q), "limit": .string("10")]) }
        }
        var args: AgentJSONArguments = ["limit": .string("10")]
        if text.contains("unread") { args["unreadOnly"] = .string("true") }
        return action("outlook.messages.list", args)
    }

    private static func normalized(_ text: String) -> String { text.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func containsAny(_ value: String, _ needles: [String]) -> Bool { needles.contains { value.contains($0) } }
    static func extractWebQuery(from text: String) -> String { SlotAgentService.shared_extractWebQuery(text) }
    static func extractOutlookSearchQuery(from text: String) -> String { SlotAgentService.shared_extractOutlookSearchQuery(text) }
    static func extractOutlookMessageReference(from text: String) -> String? { SlotAgentService.shared_extractOutlookMessageReference(text) }
    static func extractOutlookBody(from text: String) -> String? { let b = SlotAgentService.shared_extractOutlookBody(text); return b.isEmpty ? nil : b }
    static func firstURL(in text: String) -> String? { SlotAgentService.shared_firstURL(text) }

    static func extractDestination(from text: String) -> String? {
        let lower = normalized(text)
        for marker in [" to ", " near ", " for "] {
            if let r = lower.range(of: marker) { return String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return nil
    }
    static func extractContactQuery(from text: String) -> String? { extractDestination(from: text) }
    static func extractFileName(from text: String) -> String? {
        let pattern = #"[A-Za-z0-9_\- ]+\.[A-Za-z0-9]{2,6}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range)
    }
}
