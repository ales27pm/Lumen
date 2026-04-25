import Foundation

/// Keeps tool access aligned with the actual user request before the model sees
/// the tool list. This is not a final-output patch: it changes the agent's
/// action space so a normal chat turn stays a chat turn, while explicit tool
/// requests still get the correct capabilities.
nonisolated enum AgentIntentRouter {
    enum Intent: Sendable, Equatable {
        case conversation
        case answerWithContext
        case webSearch
        case fetchURL
        case calendarList
        case calendarCreate
        case reminderList
        case reminderCreate
        case contactSearch
        case draftMessage
        case draftMail
        case phoneCall
        case location
        case weather
        case mapsSearch
        case mapsDirections
        case photosSearch
        case cameraCapture
        case healthSummary
        case motionActivity
        case fileRead
        case memorySave
        case memoryRecall
        case ragSearch
        case ragIndex
        case triggerCreate
        case triggerList
        case triggerCancel
        case alarmStatus
        case alarmRequestAuthorization
        case alarmSchedule
        case alarmControl
    }

    static func inferIntent(from userMessage: String, attachments: [ChatAttachment] = []) -> Intent {
        let text = normalized(userMessage)
        let compact = compacted(userMessage)

        if text.isEmpty { return .conversation }
        if isPureConversation(text: text, compact: compact) { return .conversation }
        if !attachments.isEmpty { return .answerWithContext }

        if containsAny(text, ["http://", "https://", "www."]) && containsAny(text, ["read", "open", "fetch", "summarize", "analyze", "check"]) {
            return .fetchURL
        }

        if containsAny(text, ["weather", "temperature", "forecast", "rain", "snow", "wind", "humid", "feels like"]) {
            return .weather
        }

        if containsAny(text, ["where am i", "current location", "my location", "gps location"]) {
            return .location
        }

        if containsAny(text, ["directions to", "navigate to", "route to", "take me to", "open maps to"]) {
            return .mapsDirections
        }

        if containsAny(text, ["near me", "nearby", "closest", "around me", "around here", "in my area"]) {
            return .mapsSearch
        }

        if containsAny(text, ["calendar", "event", "meeting", "appointment"]) {
            if containsAny(text, ["create", "add", "schedule", "book", "put", "make", "set up"]) {
                return .calendarCreate
            }
            if containsAny(text, ["show", "list", "what", "when", "next", "upcoming", "today", "tomorrow"]) {
                return .calendarList
            }
        }

        if containsAny(text, ["reminder", "remind me", "todo", "to do"]) {
            if containsAny(text, ["create", "add", "set", "remind me", "make"]) { return .reminderCreate }
            if containsAny(text, ["show", "list", "what", "pending"]) { return .reminderList }
        }

        if containsAny(text, ["send a text", "text ", "sms", "imessage", "draft message"]) {
            return .draftMessage
        }

        if containsAny(text, ["email", "mail", "draft email", "compose email"]) {
            return .draftMail
        }

        if containsAny(text, ["call ", "phone ", "dial "]) {
            return .phoneCall
        }

        if containsAny(text, ["contact", "address book", "phone number of", "email address of"]) {
            return .contactSearch
        }

        if containsAny(text, ["photo", "picture", "image library", "camera roll"]) {
            if containsAny(text, ["take", "capture", "shoot", "camera"]) { return .cameraCapture }
            return .photosSearch
        }

        if containsAny(text, ["steps", "heart rate", "sleep", "health", "calories", "distance walked"]) {
            return .healthSummary
        }

        if containsAny(text, ["walking", "running", "motion activity", "cycling"]) {
            return .motionActivity
        }

        if containsAny(text, ["remember that", "save this memory", "remember this", "store this"]) {
            return .memorySave
        }

        if containsAny(text, ["what do you remember", "recall", "memory about", "saved memory"]) {
            return .memoryRecall
        }

        if containsAny(text, ["my files", "local files", "indexed files", "personal data", "my documents", "rag search"]) {
            return .ragSearch
        }

        if containsAny(text, ["reindex", "index files", "index photos", "rebuild index"]) {
            return .ragIndex
        }

        if containsAny(text, ["read file", "open file", "imported file"]) {
            return .fileRead
        }

        if containsAny(text, ["trigger", "scheduled agent", "run later", "automation"]) {
            if containsAny(text, ["create", "schedule", "add", "run later"]) { return .triggerCreate }
            if containsAny(text, ["cancel", "delete", "stop"]) { return .triggerCancel }
            return .triggerList
        }

        if containsAny(text, ["alarm", "countdown", "timer"]) {
            if containsAny(text, ["permission", "authorization", "auth status"]) { return .alarmStatus }
            if containsAny(text, ["request authorization", "ask permission"]) { return .alarmRequestAuthorization }
            if containsAny(text, ["set", "schedule", "start", "create", "wake me"]) { return .alarmSchedule }
            if containsAny(text, ["pause", "resume", "stop", "snooze", "cancel", "list"]) { return .alarmControl }
        }

        if containsAny(text, ["search the web", "web search", "look up", "google", "internet", "latest", "current", "research", "find online", "documentation"]) {
            return .webSearch
        }

        return .answerWithContext
    }

    static func filteredTools(
        from enabledTools: [ToolDefinition],
        userMessage: String,
        attachments: [ChatAttachment] = []
    ) -> [ToolDefinition] {
        let intent = inferIntent(from: userMessage, attachments: attachments)
        let allowed = allowedToolIDs(for: intent)
        guard !allowed.isEmpty else { return [] }
        return enabledTools.filter { allowed.contains($0.id) }
    }

    static func allowedToolIDs(for intent: Intent) -> Set<String> {
        switch intent {
        case .conversation, .answerWithContext:
            return []
        case .webSearch:
            return ["web.search"]
        case .fetchURL:
            return ["web.fetch", "web.search"]
        case .calendarList:
            return ["calendar.list"]
        case .calendarCreate:
            return ["calendar.create", "calendar.list"]
        case .reminderList:
            return ["reminders.list"]
        case .reminderCreate:
            return ["reminders.create", "reminders.list"]
        case .contactSearch:
            return ["contacts.search"]
        case .draftMessage:
            return ["messages.draft", "contacts.search"]
        case .draftMail:
            return ["mail.draft", "contacts.search"]
        case .phoneCall:
            return ["phone.call", "contacts.search"]
        case .location:
            return ["location.current"]
        case .weather:
            return ["weather", "location.current"]
        case .mapsSearch:
            return ["maps.search", "location.current"]
        case .mapsDirections:
            return ["maps.directions", "maps.search", "location.current"]
        case .photosSearch:
            return ["photos.search"]
        case .cameraCapture:
            return ["camera.capture"]
        case .healthSummary:
            return ["health.summary"]
        case .motionActivity:
            return ["motion.activity"]
        case .fileRead:
            return ["files.read"]
        case .memorySave:
            return ["memory.save"]
        case .memoryRecall:
            return ["memory.recall"]
        case .ragSearch:
            return ["rag.search"]
        case .ragIndex:
            return ["rag.index_files", "rag.index_photos"]
        case .triggerCreate:
            return ["trigger.create", "trigger.list"]
        case .triggerList:
            return ["trigger.list"]
        case .triggerCancel:
            return ["trigger.cancel", "trigger.list"]
        case .alarmStatus:
            return ["alarm.authorization_status", "alarm.list"]
        case .alarmRequestAuthorization:
            return ["alarm.request_authorization", "alarm.authorization_status"]
        case .alarmSchedule:
            return ["alarm.schedule", "alarm.countdown", "alarm.list"]
        case .alarmControl:
            return ["alarm.list", "alarm.pause", "alarm.resume", "alarm.stop", "alarm.snooze", "alarm.cancel"]
        }
    }

    private static func isPureConversation(text: String, compact: String) -> Bool {
        if ["hi", "hello", "hey", "yo", "sup", "bonjour", "salut", "allo", "ok", "okay", "thanks", "thankyou", "merci"].contains(compact) {
            return true
        }
        if text.count < 24,
           containsAny(text, ["how are you", "what's up", "whats up", "good morning", "good evening"]) {
            return true
        }
        return false
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func compacted(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }
}
