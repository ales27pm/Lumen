import Foundation
import SwiftData

nonisolated enum E2ETestKind: String, Codable, Sendable, CaseIterable {
    case routing
    case toolGuard
    case chat
    case regression
}

nonisolated struct E2ETestScenario: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let title: String
    let kind: E2ETestKind
    let prompt: String
    let expectedIntent: UserIntent
    let requiredAllowedToolIDs: [String]
    let forbiddenToolIDs: [String]
    let requiredTextHints: [String]
    let forbiddenTextHints: [String]
    let requiresAgentRun: Bool

    init(
        id: String,
        title: String,
        kind: E2ETestKind,
        prompt: String,
        expectedIntent: UserIntent,
        requiredAllowedToolIDs: [String] = [],
        forbiddenToolIDs: [String],
        requiredTextHints: [String],
        forbiddenTextHints: [String],
        requiresAgentRun: Bool
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.prompt = prompt
        self.expectedIntent = expectedIntent
        self.requiredAllowedToolIDs = requiredAllowedToolIDs
        self.forbiddenToolIDs = forbiddenToolIDs
        self.requiredTextHints = requiredTextHints
        self.forbiddenTextHints = forbiddenTextHints
        self.requiresAgentRun = requiresAgentRun
    }

    static let standard: [E2ETestScenario] = regression + allToolCoverage + chatCoverage

    static let regression: [E2ETestScenario] = [
        E2ETestScenario(id: "weather-here-no-calendar", title: "Weather here must not create events", kind: .regression, prompt: "What is the weather here?", expectedIntent: .weather, requiredAllowedToolIDs: ["weather", "location.current"], forbiddenToolIDs: ["calendar.create", "calendar.list", "reminders.create", "web.search"], requiredTextHints: [], forbiddenTextHints: ["created a new event", "calendar event", "will start in", "search web for diy underground shelter"], requiresAgentRun: true),
        E2ETestScenario(id: "web-search-no-calendar", title: "Web search must not create calendar event", kind: .regression, prompt: "Search web for diy underground shelter", expectedIntent: .webSearch, requiredAllowedToolIDs: ["web.search"], forbiddenToolIDs: ["calendar.create", "calendar.list", "reminders.create", "maps.search"], requiredTextHints: [], forbiddenTextHints: ["created a new event", "calendar event", "will start in"], requiresAgentRun: true),
        E2ETestScenario(id: "vague-email-clarifies", title: "Vague email draft asks clarification", kind: .routing, prompt: "Draft a email", expectedIntent: .emailDraft, requiredAllowedToolIDs: ["mail.draft", "contacts.search"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "reminders.create"], requiredTextHints: ["who should", "what should"], forbiddenTextHints: ["i will be in touch soon", "created a new event"], requiresAgentRun: true),
        E2ETestScenario(id: "normal-chat-no-forced-tool", title: "Normal chat does not force tools", kind: .chat, prompt: "Explain why a sharp chisel is safer than a dull one.", expectedIntent: .chat, requiredAllowedToolIDs: [], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft", "reminders.create"], requiredTextHints: [], forbiddenTextHints: ["created a new event", "weather for"], requiresAgentRun: true)
    ]

    static let allToolCoverage: [E2ETestScenario] = [
        // Calendar
        E2ETestScenario(id: "tool-calendar-create", title: "calendar.create scoped", kind: .toolGuard, prompt: "Create an event tomorrow at 5 called test appointment", expectedIntent: .calendar, requiredAllowedToolIDs: ["calendar.create", "calendar.list"], forbiddenToolIDs: ["weather", "web.search", "mail.draft", "maps.search"], requiredTextHints: [], forbiddenTextHints: ["weather for", "web search"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-calendar-list", title: "calendar.list scoped", kind: .toolGuard, prompt: "List my upcoming calendar events", expectedIntent: .calendar, requiredAllowedToolIDs: ["calendar.create", "calendar.list"], forbiddenToolIDs: ["weather", "web.search", "reminders.create", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["weather for"], requiresAgentRun: false),

        // Reminders
        E2ETestScenario(id: "tool-reminders-create", title: "reminders.create scoped", kind: .toolGuard, prompt: "Remind me to call Alex tomorrow", expectedIntent: .reminder, requiredAllowedToolIDs: ["reminders.create", "reminders.list"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event", "weather for"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-reminders-list", title: "reminders.list scoped", kind: .toolGuard, prompt: "List my pending reminders", expectedIntent: .reminder, requiredAllowedToolIDs: ["reminders.create", "reminders.list"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event", "weather for"], requiresAgentRun: false),

        // Communication
        E2ETestScenario(id: "tool-contacts-search", title: "contacts.search scoped", kind: .toolGuard, prompt: "Search contacts for Alex", expectedIntent: .contactSearch, requiredAllowedToolIDs: ["contacts.search"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "maps.search"], requiredTextHints: [], forbiddenTextHints: ["calendar event", "weather for"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-messages-draft", title: "messages.draft scoped", kind: .toolGuard, prompt: "Draft a text message to Alex saying I am running late", expectedIntent: .messageDraft, requiredAllowedToolIDs: ["messages.draft", "contacts.search"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event", "weather for"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-mail-draft", title: "mail.draft scoped", kind: .toolGuard, prompt: "Write an email to alex@example.com saying the plans are ready", expectedIntent: .emailDraft, requiredAllowedToolIDs: ["mail.draft", "contacts.search"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "messages.draft"], requiredTextHints: [], forbiddenTextHints: ["created a new event", "weather for"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-phone-call", title: "phone.call scoped", kind: .toolGuard, prompt: "Call 5145551234", expectedIntent: .phoneCall, requiredAllowedToolIDs: ["phone.call", "contacts.search"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event", "weather for"], requiresAgentRun: false),

        // Location / Weather / Maps
        E2ETestScenario(id: "tool-location-current", title: "location.current scoped through local weather", kind: .toolGuard, prompt: "Use my current location for the weather here", expectedIntent: .weather, requiredAllowedToolIDs: ["weather", "location.current"], forbiddenToolIDs: ["calendar.create", "web.search", "mail.draft", "reminders.create"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-weather", title: "weather scoped", kind: .toolGuard, prompt: "What is the temperature outside right now?", expectedIntent: .weather, requiredAllowedToolIDs: ["weather", "location.current"], forbiddenToolIDs: ["calendar.create", "web.search", "mail.draft", "reminders.create"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-maps-directions", title: "maps.directions scoped", kind: .toolGuard, prompt: "Get directions to 123 Main Street", expectedIntent: .maps, requiredAllowedToolIDs: ["maps.directions", "maps.search", "location.current"], forbiddenToolIDs: ["calendar.create", "web.search", "mail.draft", "weather"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-maps-search", title: "maps.search scoped", kind: .toolGuard, prompt: "Find the closest hardware store near me", expectedIntent: .maps, requiredAllowedToolIDs: ["maps.search", "maps.directions", "location.current"], forbiddenToolIDs: ["calendar.create", "web.search", "mail.draft", "weather"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),

        // Media
        E2ETestScenario(id: "tool-photos-search", title: "photos.search scoped", kind: .toolGuard, prompt: "Search photos from last month", expectedIntent: .photos, requiredAllowedToolIDs: ["photos.search"], forbiddenToolIDs: ["web.search", "calendar.create", "camera.capture", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-camera-capture", title: "camera.capture scoped", kind: .toolGuard, prompt: "Take a photo with the camera", expectedIntent: .camera, requiredAllowedToolIDs: ["camera.capture"], forbiddenToolIDs: ["photos.search", "web.search", "calendar.create", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),

        // Health / Motion
        E2ETestScenario(id: "tool-health-summary", title: "health.summary scoped", kind: .toolGuard, prompt: "Show my health summary and steps", expectedIntent: .health, requiredAllowedToolIDs: ["health.summary"], forbiddenToolIDs: ["calendar.create", "web.search", "weather", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-motion-activity", title: "motion.activity scoped", kind: .toolGuard, prompt: "Detect my recent motion activity", expectedIntent: .motion, requiredAllowedToolIDs: ["motion.activity"], forbiddenToolIDs: ["calendar.create", "web.search", "weather", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),

        // Web / Files / Memory / RAG
        E2ETestScenario(id: "tool-web-search", title: "web.search scoped", kind: .toolGuard, prompt: "Search the web for latest SwiftData tips", expectedIntent: .webSearch, requiredAllowedToolIDs: ["web.search", "web.fetch"], forbiddenToolIDs: ["calendar.create", "maps.search", "weather", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-web-fetch", title: "web.fetch scoped", kind: .toolGuard, prompt: "Read this URL https://example.com", expectedIntent: .webSearch, requiredAllowedToolIDs: ["web.search", "web.fetch"], forbiddenToolIDs: ["calendar.create", "maps.search", "weather", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-files-read", title: "files.read scoped", kind: .toolGuard, prompt: "Read file project-notes.md", expectedIntent: .files, requiredAllowedToolIDs: ["files.read"], forbiddenToolIDs: ["web.search", "calendar.create", "weather", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-memory-save", title: "memory.save scoped", kind: .toolGuard, prompt: "Remember this: I prefer concise answers", expectedIntent: .memory, requiredAllowedToolIDs: ["memory.save", "memory.recall"], forbiddenToolIDs: ["web.search", "calendar.create", "weather", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-memory-recall", title: "memory.recall scoped", kind: .toolGuard, prompt: "What do you remember about my preferences?", expectedIntent: .memory, requiredAllowedToolIDs: ["memory.save", "memory.recall"], forbiddenToolIDs: ["web.search", "calendar.create", "weather", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-rag-search", title: "rag.search scoped", kind: .toolGuard, prompt: "Search my files for the Lumen architecture notes", expectedIntent: .rag, requiredAllowedToolIDs: ["rag.search", "files.read"], forbiddenToolIDs: ["web.search", "calendar.create", "weather", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-rag-index-files", title: "rag.index_files scoped", kind: .toolGuard, prompt: "Reindex files", expectedIntent: .rag, requiredAllowedToolIDs: ["rag.index_files", "rag.search"], forbiddenToolIDs: ["web.search", "calendar.create", "weather", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-rag-index-photos", title: "rag.index_photos scoped", kind: .toolGuard, prompt: "Reindex photos", expectedIntent: .rag, requiredAllowedToolIDs: ["rag.index_photos", "photos.search"], forbiddenToolIDs: ["web.search", "calendar.create", "weather", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),

        // Triggers
        E2ETestScenario(id: "tool-trigger-create", title: "trigger.create scoped", kind: .toolGuard, prompt: "Schedule agent run in 10 minutes to summarize reminders", expectedIntent: .trigger, requiredAllowedToolIDs: ["trigger.create", "trigger.list", "trigger.cancel"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-trigger-list", title: "trigger.list scoped", kind: .toolGuard, prompt: "List triggers", expectedIntent: .trigger, requiredAllowedToolIDs: ["trigger.create", "trigger.list", "trigger.cancel"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-trigger-cancel", title: "trigger.cancel scoped", kind: .toolGuard, prompt: "Cancel trigger named morning summary", expectedIntent: .trigger, requiredAllowedToolIDs: ["trigger.create", "trigger.list", "trigger.cancel"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),

        // Alarms
        E2ETestScenario(id: "tool-alarm-auth-status", title: "alarm.authorization_status scoped", kind: .toolGuard, prompt: "Check alarm authorization status", expectedIntent: .alarm, requiredAllowedToolIDs: ["alarm.authorization_status"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-alarm-request-auth", title: "alarm.request_authorization scoped", kind: .toolGuard, prompt: "Request alarm authorization", expectedIntent: .alarm, requiredAllowedToolIDs: ["alarm.request_authorization"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-alarm-schedule", title: "alarm.schedule scoped", kind: .toolGuard, prompt: "Set an alarm for tomorrow at 7", expectedIntent: .alarm, requiredAllowedToolIDs: ["alarm.schedule", "alarm.list"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-alarm-countdown", title: "alarm.countdown scoped", kind: .toolGuard, prompt: "Start a countdown timer for 10 minutes", expectedIntent: .alarm, requiredAllowedToolIDs: ["alarm.countdown", "alarm.list"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-alarm-list", title: "alarm.list scoped", kind: .toolGuard, prompt: "List alarms", expectedIntent: .alarm, requiredAllowedToolIDs: ["alarm.list"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-alarm-pause", title: "alarm.pause scoped", kind: .toolGuard, prompt: "Pause alarm 00000000-0000-0000-0000-000000000000", expectedIntent: .alarm, requiredAllowedToolIDs: ["alarm.pause"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-alarm-resume", title: "alarm.resume scoped", kind: .toolGuard, prompt: "Resume alarm 00000000-0000-0000-0000-000000000000", expectedIntent: .alarm, requiredAllowedToolIDs: ["alarm.resume"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-alarm-stop", title: "alarm.stop scoped", kind: .toolGuard, prompt: "Stop alarm 00000000-0000-0000-0000-000000000000", expectedIntent: .alarm, requiredAllowedToolIDs: ["alarm.stop"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-alarm-snooze", title: "alarm.snooze scoped", kind: .toolGuard, prompt: "Snooze alarm 00000000-0000-0000-0000-000000000000", expectedIntent: .alarm, requiredAllowedToolIDs: ["alarm.snooze"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false),
        E2ETestScenario(id: "tool-alarm-cancel", title: "alarm.cancel scoped", kind: .toolGuard, prompt: "Cancel alarm named morning wakeup", expectedIntent: .alarm, requiredAllowedToolIDs: ["alarm.cancel"], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft"], requiredTextHints: [], forbiddenTextHints: ["calendar event"], requiresAgentRun: false)
    ]

    static let chatCoverage: [E2ETestScenario] = [
        E2ETestScenario(id: "chat-carpentry-advice", title: "Carpentry chat stays direct", kind: .chat, prompt: "Give me three tips for fitting a door hinge cleanly.", expectedIntent: .chat, requiredAllowedToolIDs: [], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft", "reminders.create"], requiredTextHints: [], forbiddenTextHints: ["created a new event", "weather for"], requiresAgentRun: true),
        E2ETestScenario(id: "chat-code-explanation", title: "Code explanation stays chat", kind: .chat, prompt: "Explain actor isolation in Swift in simple terms.", expectedIntent: .chat, requiredAllowedToolIDs: [], forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft", "reminders.create"], requiredTextHints: [], forbiddenTextHints: ["created a new event", "weather for"], requiresAgentRun: true)
    ]
}

nonisolated struct E2ETestEvent: Codable, Sendable, Identifiable {
    let id: UUID
    let createdAt: Date
    let scenarioID: String
    let phase: String
    let message: String
}

nonisolated struct E2ETestResult: Codable, Sendable, Identifiable {
    let id: UUID
    let scenarioID: String
    let title: String
    let prompt: String
    let expectedIntent: String
    let actualIntent: String
    let passed: Bool
    let failures: [String]
    let finalText: String
    let events: [E2ETestEvent]
    let startedAt: Date
    let finishedAt: Date
}

nonisolated struct E2ETestReport: Codable, Sendable, Identifiable {
    let id: UUID
    let startedAt: Date
    let finishedAt: Date
    let passed: Int
    let failed: Int
    let results: [E2ETestResult]

    var summaryText: String {
        var lines: [String] = []
        lines.append("E2E Test Report")
        lines.append("Passed: \(passed)")
        lines.append("Failed: \(failed)")
        lines.append("")
        for result in results {
            lines.append("\(result.passed ? "✅" : "❌") \(result.title)")
            lines.append("Prompt: \(result.prompt)")
            lines.append("Intent: \(result.actualIntent) / expected \(result.expectedIntent)")
            if !result.failures.isEmpty {
                lines.append("Failures: \(result.failures.joined(separator: "; "))")
            }
            if !result.finalText.isEmpty {
                lines.append("Final: \(result.finalText)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
enum E2ETestRunner {
    static func runStandard(appState: AppState, context: ModelContext) async -> E2ETestReport {
        await run(scenarios: E2ETestScenario.standard, appState: appState, context: context)
    }

    static func run(scenarios: [E2ETestScenario], appState: AppState, context: ModelContext) async -> E2ETestReport {
        let started = Date()
        var results: [E2ETestResult] = []
        for scenario in scenarios {
            let result = await runScenario(scenario, appState: appState, context: context)
            results.append(result)
            E2ETestLogStore.append(result)
        }
        let passed = results.filter(\.passed).count
        let report = E2ETestReport(id: UUID(), startedAt: started, finishedAt: Date(), passed: passed, failed: results.count - passed, results: results)
        E2ETestLogStore.writeLatest(report)
        return report
    }

    private static func runScenario(_ scenario: E2ETestScenario, appState: AppState, context: ModelContext) async -> E2ETestResult {
        let started = Date()
        var events: [E2ETestEvent] = []
        var failures: [String] = []
        var finalText = ""

        func event(_ phase: String, _ message: String) {
            events.append(E2ETestEvent(id: UUID(), createdAt: Date(), scenarioID: scenario.id, phase: phase, message: message))
        }

        event("start", scenario.prompt)
        let routing = IntentRouter.classify(scenario.prompt)
        event("intent", "actual=\(routing.intent.rawValue), expected=\(scenario.expectedIntent.rawValue)")
        if routing.intent != scenario.expectedIntent {
            failures.append("Intent mismatch: \(routing.intent.rawValue) != \(scenario.expectedIntent.rawValue)")
        }

        for toolID in scenario.requiredAllowedToolIDs where !IntentRouter.isToolAllowed(toolID, for: routing) {
            failures.append("Required tool not allowed: \(toolID)")
        }

        for toolID in scenario.forbiddenToolIDs where IntentRouter.isToolAllowed(toolID, for: routing) {
            failures.append("Forbidden tool allowed: \(toolID)")
        }

        if scenario.requiresAgentRun {
            let stored = (try? context.fetch(FetchDescriptor<StoredModel>())) ?? []
            let modelLoaded = await ModelLoader.ensureChatLoaded(appState: appState, stored: stored)
            event("models", modelLoaded ? "chat fleet ready" : "no chat model loaded")
            if modelLoaded {
                let req = AgentRequest(
                    systemPrompt: appState.systemPrompt,
                    history: [],
                    userMessage: scenario.prompt,
                    temperature: min(appState.temperature, 0.3),
                    topP: appState.topP,
                    repetitionPenalty: appState.repetitionPenalty,
                    maxTokens: min(appState.maxTokens, 512),
                    maxSteps: min(appState.maxAgentSteps, 3),
                    availableTools: ToolRegistry.all.filter { appState.enabledToolIDs.contains($0.id) && IntentRouter.isToolAllowed($0.id, for: routing) },
                    relevantMemories: []
                )
                var steps: [AgentStep] = []
                for await agentEvent in SlotAgentService.shared.run(req) {
                    switch agentEvent {
                    case .step(let step):
                        steps.append(step)
                        event("step", "\(step.kind.rawValue): \(step.content)")
                        if let toolID = step.toolID, scenario.forbiddenToolIDs.contains(toolID) {
                            failures.append("Forbidden tool selected by agent: \(toolID)")
                        }
                    case .stepDelta:
                        break
                    case .finalDelta(let chunk):
                        finalText += chunk
                    case .done(let text, let allSteps):
                        if !text.isEmpty { finalText = text }
                        steps = allSteps.isEmpty ? steps : allSteps
                    case .error(let message):
                        failures.append("Agent error: \(message)")
                    }
                }
                finalText = FinalIntentValidator.validate(finalText, routing: routing, fallback: nil)
                event("final", finalText)
            } else {
                finalText = "No model loaded; routing-only checks completed."
            }
        } else {
            finalText = "Routing guard checks completed."
        }

        let lowerFinal = finalText.lowercased()
        for hint in scenario.requiredTextHints where !lowerFinal.contains(hint.lowercased()) {
            failures.append("Required final hint missing: \(hint)")
        }
        for hint in scenario.forbiddenTextHints where lowerFinal.contains(hint.lowercased()) {
            failures.append("Forbidden final hint present: \(hint)")
        }

        return E2ETestResult(id: UUID(), scenarioID: scenario.id, title: scenario.title, prompt: scenario.prompt, expectedIntent: scenario.expectedIntent.rawValue, actualIntent: routing.intent.rawValue, passed: failures.isEmpty, failures: failures, finalText: finalText, events: events, startedAt: started, finishedAt: Date())
    }
}

nonisolated enum E2ETestLogStore {
    static func append(_ result: E2ETestResult) {
        do {
            let directory = try reportsDirectory()
            let url = directory.appendingPathComponent("e2e-results.jsonl", isDirectory: false)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(result)
            var line = data
            line.append(0x0A)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: [.atomic])
            }
        } catch {}
    }

    static func writeLatest(_ report: E2ETestReport) {
        do {
            let directory = try reportsDirectory()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = try encoder.encode(report)
            try json.write(to: directory.appendingPathComponent("latest-e2e-report.json"), options: [.atomic])
            try report.summaryText.write(to: directory.appendingPathComponent("latest-e2e-report.txt"), atomically: true, encoding: .utf8)
        } catch {}
    }

    static func latestText() -> String {
        let url = (try? reportsDirectory().appendingPathComponent("latest-e2e-report.txt"))
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return "No E2E report yet." }
        return text
    }

    static func reportsDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Diagnostics", isDirectory: true).appendingPathComponent("E2E", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
