import Foundation

nonisolated enum UserIntent: String, Codable, Sendable, CaseIterable, Hashable {
    case weather
    case webSearch
    case emailDraft
    case messageDraft
    case phoneCall
    case contactSearch
    case calendar
    case reminder
    case maps
    case photos
    case camera
    case health
    case motion
    case files
    case memory
    case rag
    case trigger
    case alarm
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
    private static let messageToolIDs: Set<String> = ["messages.draft", "contacts.search"]
    private static let phoneToolIDs: Set<String> = ["phone.call", "contacts.search"]
    private static let contactToolIDs: Set<String> = ["contacts.search"]
    private static let calendarToolIDs: Set<String> = ["calendar.create", "calendar.list"]
    private static let reminderToolIDs: Set<String> = ["reminders.create", "reminders.list"]
    private static let mapsToolIDs: Set<String> = ["maps.search", "maps.directions", "location.current"]
    private static let photosToolIDs: Set<String> = ["photos.search"]
    private static let cameraToolIDs: Set<String> = ["camera.capture"]
    private static let healthToolIDs: Set<String> = ["health.summary"]
    private static let motionToolIDs: Set<String> = ["motion.activity"]
    private static let filesToolIDs: Set<String> = ["files.read"]
    private static let memoryToolIDs: Set<String> = ["memory.save", "memory.recall"]
    private static let ragToolIDs: Set<String> = ["rag.search", "rag.index_files", "rag.index_photos", "files.read", "photos.search"]
    private static let triggerToolIDs: Set<String> = ["trigger.create", "trigger.list", "trigger.cancel"]
    private static let alarmToolIDs: Set<String> = [
        "alarm.authorization_status", "alarm.request_authorization", "alarm.schedule", "alarm.countdown",
        "alarm.list", "alarm.pause", "alarm.resume", "alarm.stop", "alarm.snooze", "alarm.cancel"
    ]
    private static let noteToolIDs: Set<String> = ["memory.save", "memory.recall"]

    static func classify(_ userMessage: String) -> IntentRoutingDecision {
        let text = normalized(userMessage)
        guard !text.isEmpty else {
            return IntentRoutingDecision(intent: .chat, allowedToolIDs: [], requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["alarm", "set an alarm", "set alarm", "countdown", "timer", "snooze", "pause alarm", "resume alarm", "stop alarm", "cancel alarm", "alarm authorization"]) {
            return IntentRoutingDecision(intent: .alarm, allowedToolIDs: alarmToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["schedule agent", "agent run", "background agent", "list triggers", "cancel trigger", "create trigger", "trigger"] ) {
            return IntentRoutingDecision(intent: .trigger, allowedToolIDs: triggerToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["remind me", "reminder", "todo", "to do", "list reminders", "pending reminders"]) {
            return IntentRoutingDecision(intent: .reminder, allowedToolIDs: reminderToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["weather", "forecast", "temperature", "what is it like outside", "weather here", "rain", "snow", "wind outside"]) {
            return IntentRoutingDecision(intent: .weather, allowedToolIDs: weatherToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["search web", "search the web", "look online", "find online", "web search", "google", "internet search", "fetch url", "open url", "read this url", "read this website"]) {
            return IntentRoutingDecision(intent: .webSearch, allowedToolIDs: webSearchToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["draft an email", "draft a email", "write an email", "compose email", "email to", "mail to", "send email"]) {
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
            return IntentRoutingDecision(intent: .emailDraft, allowedToolIDs: emailToolIDs, requiresClarification: clarification != nil, clarificationPrompt: clarification)
        }

        if matchesAny(text, ["draft message", "write a message", "compose message", "text message", "sms", "imessage", "message to", "send a text"]) {
            let recipient = inferredRecipient(text)
            let content = inferredContent(text)
            let clarification: String?
            if !recipient && !content { clarification = "Who should I message, and what should it say?" }
            else if !recipient { clarification = "Who should I message?" }
            else if !content { clarification = "What should the message say?" }
            else { clarification = nil }
            return IntentRoutingDecision(intent: .messageDraft, allowedToolIDs: messageToolIDs, requiresClarification: clarification != nil, clarificationPrompt: clarification)
        }

        if matchesAny(text, ["contact", "address book", "find contact", "search contacts", "phone number for", "email address for"]) {
            return IntentRoutingDecision(intent: .contactSearch, allowedToolIDs: contactToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["call ", "phone ", "dial ", "start call"]) {
            let hasTarget = text.split(separator: " ").count >= 2 || text.rangeOfCharacter(from: .decimalDigits) != nil
            return IntentRoutingDecision(intent: .phoneCall, allowedToolIDs: phoneToolIDs, requiresClarification: !hasTarget, clarificationPrompt: hasTarget ? nil : "Who should I call?")
        }

        if matchesAny(text, ["schedule", "calendar", "create event", "meeting", "appointment", "at 5", "tomorrow at", "list events", "upcoming events"]) {
            return IntentRoutingDecision(intent: .calendar, allowedToolIDs: calendarToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["directions", "navigate", "route to", "maps", "near me", "nearby", "closest", "search nearby", "find a place", "find places"]) {
            return IntentRoutingDecision(intent: .maps, allowedToolIDs: mapsToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["search photos", "find photos", "photo library", "pictures from", "photos from", "images in my library"]) {
            return IntentRoutingDecision(intent: .photos, allowedToolIDs: photosToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["take a photo", "capture image", "open camera", "use camera", "take picture"]) {
            return IntentRoutingDecision(intent: .camera, allowedToolIDs: cameraToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["health summary", "steps", "sleep", "heart rate", "active energy", "walking distance", "health data"]) {
            return IntentRoutingDecision(intent: .health, allowedToolIDs: healthToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["motion activity", "am i walking", "am i running", "device motion", "recent activity"]) {
            return IntentRoutingDecision(intent: .motion, allowedToolIDs: motionToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["read file", "open file", "read document", "imported file", "local document"]) {
            return IntentRoutingDecision(intent: .files, allowedToolIDs: filesToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["remember this", "save memory", "recall memory", "what do you remember", "memory about", "save this fact"]) {
            return IntentRoutingDecision(intent: .memory, allowedToolIDs: memoryToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["search personal data", "search my files", "search local files", "reindex files", "index files", "reindex photos", "index photos", "rag search"]) {
            return IntentRoutingDecision(intent: .rag, allowedToolIDs: ragToolIDs, requiresClarification: false, clarificationPrompt: nil)
        }

        if matchesAny(text, ["note", "save this"]) {
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
        case .weather, .webSearch, .emailDraft, .messageDraft, .phoneCall, .contactSearch, .calendar, .reminder, .maps, .photos, .camera, .health, .motion, .files, .memory, .rag, .trigger, .alarm, .note:
            return true
        case .chat, .unknown:
            return false
        }
    }

    static func unavailableMessage(for decision: IntentRoutingDecision) -> String {
        switch decision.intent {
        case .webSearch: return "Web search is not available in this build yet."
        case .weather: return "Weather tools are unavailable right now. Please enable weather/location tools or provide a city."
        case .emailDraft: return "Email drafting is not available in this build yet."
        case .messageDraft: return "Message drafting is not available in this build yet."
        case .phoneCall: return "Phone call tools are unavailable in this build right now."
        case .contactSearch: return "Contact search is unavailable in this build right now."
        case .calendar: return "Calendar tools are unavailable in this build right now."
        case .reminder: return "Reminder tools are unavailable in this build right now."
        case .maps: return "Maps/location tools are unavailable in this build right now."
        case .photos: return "Photo tools are unavailable in this build right now."
        case .camera: return "Camera tools are unavailable in this build right now."
        case .health: return "Health tools are unavailable in this build right now."
        case .motion: return "Motion tools are unavailable in this build right now."
        case .files: return "File reading tools are unavailable in this build right now."
        case .memory, .note: return "Notes/memory tools are unavailable in this build right now."
        case .rag: return "Local search/indexing tools are unavailable in this build right now."
        case .trigger: return "Scheduled agent tools are unavailable in this build right now."
        case .alarm: return "Alarm tools are unavailable in this build right now."
        case .chat, .unknown: return "I can answer directly, but no matching tool is available for that action."
        }
    }

    static func blockedToolMessage(for decision: IntentRoutingDecision) -> String {
        switch decision.intent {
        case .webSearch: return "That request is a web search. I can only use web search tools for it, not calendar or reminder tools."
        case .weather: return "That request is about weather. I can only use weather/location tools for it."
        case .emailDraft: return "That request is for drafting an email. I can only use email composition tools for it."
        case .messageDraft: return "That request is for drafting a message. I can only use message composition tools for it."
        case .phoneCall: return "That request is for a phone call. I can only use phone/contact tools for it."
        case .contactSearch: return "That request is for contact lookup. I can only use contact tools for it."
        case .calendar: return "That request is calendar-related. I can only use calendar tools for it."
        case .reminder: return "That request is reminder-related. I can only use reminder tools for it."
        case .maps: return "That request is map/location-related. I can only use maps/location tools for it."
        case .photos: return "That request is photo-library related. I can only use photo tools for it."
        case .camera: return "That request is camera-related. I can only use camera tools for it."
        case .health: return "That request is health-related. I can only use health tools for it."
        case .motion: return "That request is motion-related. I can only use motion tools for it."
        case .files: return "That request is file-related. I can only use local file tools for it."
        case .memory, .note: return "That request is note/memory-related. I can only use note/memory tools for it."
        case .rag: return "That request is local-search/indexing related. I can only use RAG/local index tools for it."
        case .trigger: return "That request is scheduled-agent related. I can only use trigger tools for it."
        case .alarm: return "That request is alarm-related. I can only use alarm tools for it."
        case .chat, .unknown: return "That tool doesn't match your request. Could you clarify what you want to do?"
        }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchesAny(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { text.contains($0) }
    }

    private static func inferredRecipient(_ text: String) -> Bool {
        text.contains(" to ") || text.contains("@") || text.contains("recipient") || text.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private static func inferredContent(_ text: String) -> Bool {
        text.contains(" about ") || text.contains(" saying ") || text.contains(" body ") || text.contains(" that says ") || text.contains(" message ") || text.split(separator: " ").count >= 8
    }
}
