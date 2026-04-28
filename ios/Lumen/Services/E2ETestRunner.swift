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
    let forbiddenToolIDs: [String]
    let requiredTextHints: [String]
    let forbiddenTextHints: [String]
    let requiresAgentRun: Bool

    static let standard: [E2ETestScenario] = [
        E2ETestScenario(
            id: "weather-here-no-calendar",
            title: "Weather here must not create events",
            kind: .regression,
            prompt: "What is the weather here?",
            expectedIntent: .weather,
            forbiddenToolIDs: ["calendar.create", "calendar.list", "reminders.create", "web.search"],
            requiredTextHints: [],
            forbiddenTextHints: ["created a new event", "calendar event", "will start in", "search web for diy underground shelter"],
            requiresAgentRun: true
        ),
        E2ETestScenario(
            id: "web-search-no-calendar",
            title: "Web search must not create calendar event",
            kind: .regression,
            prompt: "Search web for diy underground shelter",
            expectedIntent: .webSearch,
            forbiddenToolIDs: ["calendar.create", "calendar.list", "reminders.create", "maps.search"],
            requiredTextHints: [],
            forbiddenTextHints: ["created a new event", "calendar event", "will start in"],
            requiresAgentRun: true
        ),
        E2ETestScenario(
            id: "vague-email-clarifies",
            title: "Vague email draft asks clarification",
            kind: .routing,
            prompt: "Draft a email",
            expectedIntent: .emailDraft,
            forbiddenToolIDs: ["calendar.create", "weather", "web.search", "reminders.create"],
            requiredTextHints: ["who should", "what should"],
            forbiddenTextHints: ["i will be in touch soon", "created a new event"],
            requiresAgentRun: true
        ),
        E2ETestScenario(
            id: "calendar-only-calendar-tools",
            title: "Calendar intent scopes tools",
            kind: .toolGuard,
            prompt: "Create an event tomorrow at 5 called test appointment",
            expectedIntent: .calendar,
            forbiddenToolIDs: ["weather", "web.search", "mail.draft", "maps.search"],
            requiredTextHints: [],
            forbiddenTextHints: ["weather for", "web search"],
            requiresAgentRun: false
        ),
        E2ETestScenario(
            id: "reminder-only-reminder-tools",
            title: "Reminder intent scopes tools",
            kind: .toolGuard,
            prompt: "Remind me to call Alex tomorrow",
            expectedIntent: .reminder,
            forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft"],
            requiredTextHints: [],
            forbiddenTextHints: ["calendar event", "weather for"],
            requiresAgentRun: false
        ),
        E2ETestScenario(
            id: "normal-chat-no-forced-tool",
            title: "Normal chat does not force tools",
            kind: .chat,
            prompt: "Explain why a sharp chisel is safer than a dull one.",
            expectedIntent: .chat,
            forbiddenToolIDs: ["calendar.create", "weather", "web.search", "mail.draft", "reminders.create"],
            requiredTextHints: [],
            forbiddenTextHints: ["created a new event", "weather for"],
            requiresAgentRun: true
        )
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
        let report = E2ETestReport(
            id: UUID(),
            startedAt: started,
            finishedAt: Date(),
            passed: passed,
            failed: results.count - passed,
            results: results
        )
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

        return E2ETestResult(
            id: UUID(),
            scenarioID: scenario.id,
            title: scenario.title,
            prompt: scenario.prompt,
            expectedIntent: scenario.expectedIntent.rawValue,
            actualIntent: routing.intent.rawValue,
            passed: failures.isEmpty,
            failures: failures,
            finalText: finalText,
            events: events,
            startedAt: started,
            finishedAt: Date()
        )
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
        } catch {
            // Test logging must never crash diagnostics.
        }
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
        } catch {
            // Test logging must never crash diagnostics.
        }
    }

    static func latestText() -> String {
        let url = (try? reportsDirectory().appendingPathComponent("latest-e2e-report.txt"))
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "No E2E report yet."
        }
        return text
    }

    static func reportsDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = base
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("E2E", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
