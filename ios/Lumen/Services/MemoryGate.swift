import Foundation

nonisolated enum MemoryGate {
    static func filter(intent: UserIntent, items: [MemoryContextItem], userMessage: String, now: Date = Date()) -> [MemoryContextItem] {
        let normalized = normalize(userMessage)
        return items.compactMap { item in
            if let expiresAt = item.expiresAt, expiresAt <= now {
                logReject(item, reason: "expired")
                return nil
            }
            if let createdAt = item.createdAt, createdAt > now.addingTimeInterval(300) {
                logReject(item, reason: "created_in_future")
                return nil
            }

            switch intent {
            case .phoneCall, .messageDraft:
                guard allowForPhoneOrMessage(item) else {
                    logReject(item, reason: "intent_mismatch_phone_message")
                    return nil
                }
            case .weather:
                guard allowForWeather(item, userMessage: normalized) else {
                    logReject(item, reason: "intent_mismatch_weather")
                    return nil
                }
            case .webSearch:
                guard allowForWebSearch(item) else {
                    logReject(item, reason: "intent_mismatch_web")
                    return nil
                }
            default:
                break
            }
            return item
        }
    }

    private static func allowForPhoneOrMessage(_ item: MemoryContextItem) -> Bool {
        if item.scope == .person { return true }
        if item.scope == .conversation, item.authority == .referenceOnly { return true }
        if hasTopic(item, containsAny: ["contact", "recipient", "phone", "message", "imessage", "sms"]) { return true }
        if hasTopic(item, containsAny: ["weather", "forecast", "search", "calendar", "event"]) { return false }
        return item.scope != .toolObservation
    }

    private static func allowForWeather(_ item: MemoryContextItem, userMessage: String) -> Bool {
        let askedSameOrPrevious = userMessage.contains("same") || userMessage.contains("previous")
        if item.scope == .userPreference, hasTopic(item, containsAny: ["location", "city", "units", "weather"]) {
            return true
        }
        if item.scope == .currentTurn {
            return true
        }
        if item.scope == .toolObservation {
            if askedSameOrPrevious { return true }
            if let createdAt = item.createdAt {
                return Date().timeIntervalSince(createdAt) <= 15 * 60
            }
            return false
        }
        if hasTopic(item, containsAny: ["weather", "forecast", "search"]) {
            return askedSameOrPrevious
        }
        return false
    }

    private static func allowForWebSearch(_ item: MemoryContextItem) -> Bool {
        if item.scope == .project || item.scope == .userPreference { return true }
        if item.scope == .toolObservation {
            return hasTopic(item, containsAny: ["web", "search", "url", "http"])
        }
        return item.scope != .toolObservation
    }

    private static func hasTopic(_ item: MemoryContextItem, containsAny values: [String]) -> Bool {
        let haystack = "\(item.topic ?? "") \(item.source ?? "") \(item.content)".lowercased()
        return values.contains(where: { haystack.contains($0) })
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func logReject(_ item: MemoryContextItem, reason: String) {
        #if DEBUG
        print("[MemoryGate] reject reason=\(reason) scope=\(item.scope.rawValue) authority=\(item.authority.rawValue) topic=\(item.topic ?? "-") source=\(item.source ?? "-")")
        #endif
    }
}
