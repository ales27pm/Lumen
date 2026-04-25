import Foundation

/// Narrows the agent's action space before generation. The goal is not to
/// patch bad final text after the fact; it is to prevent unrelated tools from
/// being shown to the model unless the user's request actually needs them.
nonisolated enum AgentIntentRouter {
    enum Intent: Sendable, Equatable, CaseIterable {
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

    struct Decision: Sendable, Equatable {
        let intent: Intent
        let confidence: Int
        let reason: String
        let allowedToolIDs: Set<String>
        let requiresUserApproval: Bool

        var allowsTools: Bool { !allowedToolIDs.isEmpty }
    }

    private struct Candidate: Sendable {
        let intent: Intent
        let score: Int
        let reason: String
    }

    static func decide(userMessage: String, attachments: [ChatAttachment] = []) -> Decision {
        let text = normalized(userMessage)
        let compact = compacted(userMessage)

        if text.isEmpty {
            return makeDecision(.conversation, confidence: 100, reason: "empty message")
        }

        if isPureConversation(text: text, compact: compact) {
            return makeDecision(.conversation, confidence: 100, reason: "pure conversational turn")
        }

        if !attachments.isEmpty {
            return makeDecision(.answerWithContext, confidence: 92, reason: "attachments are already in prompt context")
        }

        var candidates: [Candidate] = []
        func add(_ intent: Intent, _ score: Int, _ reason: String) {
            guard score > 0 else { return }
            candidates.append(Candidate(intent: intent, score: score, reason: reason))
        }

        let hasURL = containsAny(text, ["http://", "https://", "www."])
        if hasURL {
            add(.fetchURL, score(text, strong: ["read", "open", "fetch", "summarize", "analyze", "check", "review"], weak: ["url", "link", "page", "site"]) + 8, "explicit URL/link handling")
        }

        add(.weather, score(text, strong: ["weather", "forecast", "temperature"], weak: ["rain", "snow", "wind", "humid", "feels like", "outside"]), "weather terms")
        add(.location, score(text, strong: ["where am i", "current location", "my location", "gps location"], weak: ["coordinates"]), "current location terms")
        add(.mapsDirections, score(text, strong: ["directions to", "navigate to", "route to", "take me to", "open maps to"], weak: ["drive to", "walk to"]), "navigation terms")
        add(.mapsSearch, score(text, strong: ["near me", "nearby", "closest", "around me", "around here", "in my area"], weak: ["local", "address of"]), "local search terms")

        let calendarMentions = containsAny(text, ["calendar", "event", "meeting", "appointment"])
        if calendarMentions {
            add(.calendarCreate, score(text, strong: ["create", "add", "schedule", "book", "put", "make", "set up"], weak: ["tomorrow", "today", "next week", "at "]) + 4, "calendar write intent")
            add(.calendarList, score(text, strong: ["show", "list", "what", "when", "next", "upcoming"], weak: ["today", "tomorrow", "this week"]) + 4, "calendar read intent")
        }

        let reminderMentions = containsAny(text, ["reminder", "remind me", "todo", "to do"])
        if reminderMentions {
            add(.reminderCreate, score(text, strong: ["create", "add", "set", "remind me", "make"], weak: ["tomorrow", "later", "at "]) + 4, "reminder write intent")
            add(.reminderList, score(text, strong: ["show", "list", "what", "pending"], weak: ["reminders", "todos"]) + 4, "reminder read intent")
        }

        add(.draftMessage, score(text, strong: ["send a text", "draft message", "imessage", "sms"], weak: ["text ", "message "]), "message draft intent")
        add(.draftMail, score(text, strong: ["draft email", "compose email", "send email", "write an email"], weak: ["email", "mail"]), "email draft intent")
        add(.phoneCall, score(text, strong: ["call ", "phone ", "dial "], weak: ["ring"]), "phone call intent")
        add(.contactSearch, score(text, strong: ["contact", "address book", "phone number of", "email address of"], weak: ["number for", "email for"]), "contact lookup intent")

        let photoScore = score(text, strong: ["photo", "picture", "camera roll", "image library"], weak: ["image", "album"])
        if photoScore > 0 {
            if containsAny(text, ["take", "capture", "shoot", "camera"]) { add(.cameraCapture, photoScore + 5, "camera capture intent") }
            else { add(.photosSearch, photoScore, "photo library intent") }
        }

        add(.healthSummary, score(text, strong: ["heart rate", "sleep", "health", "calories", "distance walked"], weak: ["steps"]), "health summary intent")
        add(.motionActivity, score(text, strong: ["motion activity", "am i walking", "am i running"], weak: ["walking", "running", "cycling"]), "motion activity intent")
        add(.memorySave, score(text, strong: ["remember that", "save this memory", "remember this", "store this"], weak: ["keep this in mind"]), "memory save intent")
        add(.memoryRecall, score(text, strong: ["what do you remember", "memory about", "saved memory"], weak: ["recall"]), "memory recall intent")
        add(.ragSearch, score(text, strong: ["my files", "local files", "indexed files", "personal data", "my documents", "rag search"], weak: ["my notes", "my pdfs"]), "personal data search intent")
        add(.ragIndex, score(text, strong: ["reindex", "index files", "index photos", "rebuild index"], weak: ["refresh index"]), "index rebuild intent")
        add(.fileRead, score(text, strong: ["read file", "open file", "imported file"], weak: ["file named"]), "local imported file intent")

        let triggerMentions = containsAny(text, ["trigger", "scheduled agent", "run later", "automation"])
        if triggerMentions {
            add(.triggerCreate, score(text, strong: ["create", "schedule", "add", "run later"], weak: ["every", "when"]) + 4, "trigger create intent")
            add(.triggerCancel, score(text, strong: ["cancel", "delete", "stop"], weak: ["remove"]) + 4, "trigger cancel intent")
            add(.triggerList, score(text, strong: ["show", "list", "what"], weak: ["active"]) + 4, "trigger list intent")
        }

        let alarmMentions = containsAny(text, ["alarm", "countdown", "timer"])
        if alarmMentions {
            add(.alarmRequestAuthorization, score(text, strong: ["request authorization", "ask permission"], weak: ["permission"]), "alarm permission request")
            add(.alarmStatus, score(text, strong: ["authorization", "auth status", "permission"], weak: ["status"]), "alarm status intent")
            add(.alarmSchedule, score(text, strong: ["set", "schedule", "start", "create", "wake me"], weak: ["in ", "at "]) + 4, "alarm schedule intent")
            add(.alarmControl, score(text, strong: ["pause", "resume", "stop", "snooze", "cancel", "list"], weak: ["alarms"]), "alarm control intent")
        }

        add(.webSearch, score(text, strong: ["search the web", "web search", "look up", "find online", "research online"], weak: ["google", "internet", "latest", "current", "documentation", "research"]), "web knowledge intent")

        let best = candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return priority(lhs.intent) > priority(rhs.intent)
        }.first

        guard let best, best.score >= 7 else {
            return makeDecision(.answerWithContext, confidence: 82, reason: "no tool intent above threshold")
        }

        let intent = normalizeConflicts(best.intent, text: text)
        return makeDecision(intent, confidence: min(100, best.score * 10), reason: best.reason)
    }

    static func inferIntent(from userMessage: String, attachments: [ChatAttachment] = []) -> Intent {
        decide(userMessage: userMessage, attachments: attachments).intent
    }

    static func filteredTools(from enabledTools: [ToolDefinition], userMessage: String, attachments: [ChatAttachment] = []) -> [ToolDefinition] {
        let decision = decide(userMessage: userMessage, attachments: attachments)
        guard decision.allowsTools else { return [] }
        return enabledTools.filter { decision.allowedToolIDs.contains($0.id) }
    }

    static func routingSystemNote(for decision: Decision) -> String {
        if decision.allowedToolIDs.isEmpty {
            return "\n\nRouting: No tools are available for this turn. Answer directly in natural language. Do not invent tool results or claim that actions were performed."
        }
        let tools = decision.allowedToolIDs.sorted().joined(separator: ", ")
        return "\n\nRouting: The user's inferred intent is \(decision.intent). Only these tools are available for this turn: \(tools). Use a tool only if it is necessary. Do not invent tool results. Tools that require approval must not be described as completed until they actually return a successful result."
    }

    static func allowedToolIDs(for intent: Intent) -> Set<String> {
        switch intent {
        case .conversation, .answerWithContext: []
        case .webSearch: ["web.search"]
        case .fetchURL: ["web.fetch", "web.search"]
        case .calendarList: ["calendar.list"]
        case .calendarCreate: ["calendar.create", "calendar.list"]
        case .reminderList: ["reminders.list"]
        case .reminderCreate: ["reminders.create", "reminders.list"]
        case .contactSearch: ["contacts.search"]
        case .draftMessage: ["messages.draft", "contacts.search"]
        case .draftMail: ["mail.draft", "contacts.search"]
        case .phoneCall: ["phone.call", "contacts.search"]
        case .location: ["location.current"]
        case .weather: ["weather", "location.current"]
        case .mapsSearch: ["maps.search", "location.current"]
        case .mapsDirections: ["maps.directions", "maps.search", "location.current"]
        case .photosSearch: ["photos.search"]
        case .cameraCapture: ["camera.capture"]
        case .healthSummary: ["health.summary"]
        case .motionActivity: ["motion.activity"]
        case .fileRead: ["files.read"]
        case .memorySave: ["memory.save"]
        case .memoryRecall: ["memory.recall"]
        case .ragSearch: ["rag.search"]
        case .ragIndex: ["rag.index_files", "rag.index_photos"]
        case .triggerCreate: ["trigger.create", "trigger.list"]
        case .triggerList: ["trigger.list"]
        case .triggerCancel: ["trigger.cancel", "trigger.list"]
        case .alarmStatus: ["alarm.authorization_status", "alarm.list"]
        case .alarmRequestAuthorization: ["alarm.request_authorization", "alarm.authorization_status"]
        case .alarmSchedule: ["alarm.schedule", "alarm.countdown", "alarm.list"]
        case .alarmControl: ["alarm.list", "alarm.pause", "alarm.resume", "alarm.stop", "alarm.snooze", "alarm.cancel"]
        }
    }

    private static func makeDecision(_ intent: Intent, confidence: Int, reason: String) -> Decision {
        let allowed = allowedToolIDs(for: intent)
        let requiresApproval = allowed.contains { ToolRegistry.find(id: $0)?.requiresApproval == true }
        return Decision(intent: intent, confidence: confidence, reason: reason, allowedToolIDs: allowed, requiresUserApproval: requiresApproval)
    }

    private static func normalizeConflicts(_ intent: Intent, text: String) -> Intent {
        if intent == .mapsSearch, containsAny(text, ["how to", "tutorial", "guide", "plans", "blueprint", "documentation"]) { return .webSearch }
        if intent == .calendarCreate, !containsAny(text, ["calendar", "event", "meeting", "appointment", "schedule"]) { return .answerWithContext }
        return intent
    }

    private static func isPureConversation(text: String, compact: String) -> Bool {
        if ["hi", "hello", "hey", "yo", "sup", "bonjour", "salut", "allo", "ok", "okay", "thanks", "thankyou", "merci"].contains(compact) { return true }
        if text.count < 30, containsAny(text, ["how are you", "what's up", "whats up", "good morning", "good evening"]) { return true }
        return false
    }

    private static func score(_ text: String, strong: [String], weak: [String]) -> Int {
        strong.reduce(0) { $0 + (text.contains($1) ? 8 : 0) } + weak.reduce(0) { $0 + (text.contains($1) ? 3 : 0) }
    }

    private static func priority(_ intent: Intent) -> Int {
        switch intent {
        case .conversation: 100
        case .calendarCreate, .reminderCreate, .alarmSchedule, .triggerCreate: 80
        case .mapsDirections, .draftMail, .draftMessage, .phoneCall: 70
        case .weather, .webSearch, .fetchURL: 60
        default: 50
        }
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool { needles.contains { text.contains($0) } }
    private static func normalized(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
    private static func compacted(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression) }
}
