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
            systemPrompt: composedSystemPrompt(basePrompt: settings.systemPrompt),
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

    static func composedSystemPrompt(basePrompt: String) -> String {
        let trimmedBasePrompt = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let contracts = LumenModelSlotContract.all
            .filter { $0.slot != .embedding }
            .map { contract in
                "- \(contract.slot.displayName): \(contract.systemContract)"
            }
            .joined(separator: "\n")

        let fleetPrompt = """
        Lumen model fleet v0 is enabled. The runtime may map several logical slots to the same small local model, but each slot has a strict behavioral contract:
        \(contracts)

        When acting as the agent, keep decisions separate from final user-facing wording. Prefer compact structured turns when a native capability is needed.

        Tool-call compatibility rules:
        - If you call a tool, emit exactly one JSON object and no prose around it.
        - Use either {"tool":"tool.id","args":{...}} or {"action":{"tool":"tool.id","args":{...}}}.
        - Args may contain normal JSON values: strings, numbers, booleans, arrays, objects, or null.
        - Do not emit privacy/anonymizer placeholder tokens. Use the information available in the user's message or ask a concise follow-up.
        """

        guard !trimmedBasePrompt.isEmpty else {
            return """
            You are Lumen, a concise on-device assistant.

            \(fleetPrompt)
            """
        }

        return """
        \(trimmedBasePrompt)

        \(fleetPrompt)
        """
    }
}
