import Foundation
import SwiftData

@MainActor
enum AgentRunner {
    static func runHeadless(prompt: String, appState: AppState, context: ModelContext, maxSteps: Int? = nil) async -> (text: String, steps: [AgentStep]) {
        let memories = await MemoryStore.recall(query: prompt, context: context).map(\.content)
        let tools = ToolRegistry.all.filter { appState.enabledToolIDs.contains($0.id) }
        let req = AgentRequest(
            systemPrompt: appState.systemPrompt,
            history: [],
            userMessage: prompt,
            temperature: appState.temperature,
            topP: appState.topP,
            repetitionPenalty: appState.repetitionPenalty,
            maxTokens: appState.maxTokens,
            maxSteps: maxSteps ?? appState.maxAgentSteps,
            availableTools: tools,
            relevantMemories: memories
        )

        var final = ""
        var steps: [AgentStep] = []
        for await event in await AgentService.shared.run(req) {
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
