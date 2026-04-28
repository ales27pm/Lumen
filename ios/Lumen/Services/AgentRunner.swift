import Foundation
import SwiftData

@MainActor
enum AgentRunner {
    /// Foreground entry point. Uses the live `AppState` (reads its current snapshot).
    static func runHeadless(prompt: String, appState: AppState, context: ModelContext, maxSteps: Int? = nil) async -> (text: String, steps: [AgentStep]) {
        let stored = (try? context.fetch(FetchDescriptor<StoredModel>())) ?? []
        let fleet = LumenModelFleetResolver.resolveV0(appState: appState, storedModels: stored)
        return await runHeadless(
            prompt: prompt,
            settings: appState.snapshot,
            context: context,
            maxSteps: maxSteps,
            fleetSnapshot: fleet
        )
    }

    /// Background-safe entry point. Takes a Sendable settings snapshot so background
    /// tasks never depend on live in-memory mutable state.
    static func runHeadless(prompt: String, settings: SettingsSnapshot, context: ModelContext, maxSteps: Int? = nil) async -> (text: String, steps: [AgentStep]) {
        let stored = (try? context.fetch(FetchDescriptor<StoredModel>())) ?? []
        let fleet = LumenModelFleetResolver.resolveV0(settings: settings, storedModels: stored)
        return await runHeadless(
            prompt: prompt,
            settings: settings,
            context: context,
            maxSteps: maxSteps,
            fleetSnapshot: fleet
        )
    }

    private static func runHeadless(
        prompt: String,
        settings: SettingsSnapshot,
        context: ModelContext,
        maxSteps: Int?,
        fleetSnapshot: LumenModelFleetSnapshot
    ) async -> (text: String, steps: [AgentStep]) {
        let memories = await MemoryStore.recall(query: prompt, context: context).map(\.content)
        let tools = ToolRegistry.all.filter { settings.enabledToolIDs.contains($0.id) }
        let mimicry = MimicryProfiler.profile(userMessage: prompt, settings: settings)
        let req = AgentRequest(
            systemPrompt: composedSystemPrompt(basePrompt: settings.systemPrompt, fleetSnapshot: fleetSnapshot, mimicry: mimicry),
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

    private static func composedSystemPrompt(basePrompt: String, fleetSnapshot: LumenModelFleetSnapshot, mimicry: MimicryProfile) -> String {
        let trimmedBasePrompt = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let contracts = LumenModelSlotContract.all
            .filter { $0.slot != .embedding }
            .map { contract in
                "- \(contract.slot.displayName): \(contract.systemContract)"
            }
            .joined(separator: "\n")

        let assignments = LumenModelSlot.allCases
            .map { slot -> String in
                if let assignment = fleetSnapshot.assignment(for: slot) {
                    return "- \(slot.displayName): \(assignment.displayName) · \(assignment.parameters) · \(assignment.quantization)"
                }
                return "- \(slot.displayName): missing"
            }
            .joined(separator: "\n")

        let missingText = fleetSnapshot.missingSlots.isEmpty
            ? "none"
            : fleetSnapshot.missingSlots.map(\.displayName).joined(separator: ", ")

        let runtimeMode = """
        Fleet runtime mode: v0-single-runtime.
        Dedicated per-slot model execution is not available in v0. Slot contracts are behavioral routing contracts applied inside the current single local runtime.
        """

        let fleetPrompt = """
        Lumen model fleet v0 is enabled. The runtime may map several logical slots to the same small local model, but each slot has a strict behavioral contract:
        \(contracts)

        \(runtimeMode)

        Current v0 slot assignments:
        \(assignments)

        Missing slots: \(missingText).

        \(mimicry.promptFragment)

        When acting as the agent, keep decisions separate from final user-facing wording. Prefer compact structured turns when a native capability is needed.
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
