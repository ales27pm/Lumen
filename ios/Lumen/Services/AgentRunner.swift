import Foundation
import SwiftData

@MainActor
enum AgentRunner {
    /// Foreground entry point. Uses the live `AppState` (reads its current snapshot).
    static func runHeadless(prompt: String, appState: AppState, context: ModelContext, maxSteps: Int? = nil) async -> (text: String, steps: [AgentStep]) {
        await runHeadless(prompt: prompt, settings: appState.snapshot, context: context, maxSteps: maxSteps)
    }

    /// Background-safe entry point. Takes a Sendable settings snapshot so background
    /// tasks never depend on live in-memory mutable state.
    static func runHeadless(prompt: String, settings: SettingsSnapshot, context: ModelContext, maxSteps: Int? = nil) async -> (text: String, steps: [AgentStep]) {
        let memories = await MemoryStore.recall(query: prompt, context: context).map(\.content)
        let tools = ToolRegistry.all.filter { settings.enabledToolIDs.contains($0.id) }
        let req = AgentRequest(
            systemPrompt: settings.systemPrompt,
            history: [],
            userMessage: prompt,
            temperature: settings.temperature,
            topP: settings.topP,
            repetitionPenalty: settings.repetitionPenalty,
            maxTokens: settings.maxTokens,
            maxSteps: maxSteps ?? settings.maxAgentSteps,
            availableTools: tools,
            relevantMemories: memories
        )

        var final = ""
        var steps: [AgentStep] = []
        for await event in AgentService.shared.run(req) {
            switch event {
            case .step(let s):
                if let idx = steps.firstIndex(where: { $0.id == s.id }) { steps[idx] = s }
                else { steps.append(s) }
            case .stepDelta(let id, let text):
                if let idx = steps.firstIndex(where: { $0.id == id }) { steps[idx].content = text }
            case .finalDelta(let chunk):
                final += chunk
            case .done(let text, let all):
                final = text.isEmpty ? final : text
                steps = all.isEmpty ? steps : all
            case .error(let msg):
                final = msg
            }
        }
        return (final.trimmingCharacters(in: .whitespacesAndNewlines), steps)
    }
}
