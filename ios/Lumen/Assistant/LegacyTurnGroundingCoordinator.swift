import Foundation
import SwiftData

struct LegacyTurnGroundingOutput: Sendable {
    let grounding: AssistantGroundingContext
    let sections: [PromptGroundingSection]
    let legacyTools: [ToolDefinition]
    let promptInjection: String
    let metricsSummary: String
}

@MainActor
final class LegacyTurnGroundingCoordinator {
    static let shared = LegacyTurnGroundingCoordinator()
    private let bridge = LegacyGroundingBridge()
    private let cache = LegacyGroundingCache()

    func build(userMessage: String, conversationID: UUID?, turnID: UUID?, history: [(role: MessageRole, content: String)], modelContext: ModelContext, isBackground: Bool, task: AssistantTaskKind, role: String? = nil) async -> LegacyTurnGroundingOutput {
        let key = LegacyGroundingCache.Key(conversationID: conversationID, turnID: turnID, userHash: userMessage.hashValue, background: isBackground)
        if let cached = await cache.get(key) {
            return .init(grounding: cached.grounding, sections: cached.sections, legacyTools: LegacyToolSchemaBridge.toLegacyToolDefinitions(cached.secureTools), promptInjection: cached.renderedPromptContext, metricsSummary: "cache")
        }
        let turn = AssistantTurnContext(task: task, input: userMessage, isForeground: !isBackground, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalState: ProcessInfo.processInfo.thermalState)
        let bundle = await bridge.build(userMessage: userMessage, conversationID: conversationID, turnID: turnID, history: history, modelContext: modelContext, turn: turn)
        await cache.put(key, bundle: bundle)
        return .init(grounding: bundle.grounding, sections: bundle.sections, legacyTools: LegacyToolSchemaBridge.toLegacyToolDefinitions(bundle.secureTools), promptInjection: bundle.renderedPromptContext, metricsSummary: bundle.metricsSummary)
    }


    func prepareGroundedRequest(_ request: LegacyGroundingRequest, provider: LegacyGroundingContextProvider = .init()) async -> LegacyGroundingResult {
        let context = provider.resolveContext()
        var degraded: [String] = []
        guard let modelContext = context else {
            if let reason = provider.degradedReason { degraded.append(reason) }
            let fallbackSections: [PromptGroundingSection] = [
                .init(title: "Relevant memories", content: request.externalRelevantMemories.prefix(8).map { "- \($0.content)" }.joined(separator: "\n"), estimatedChars: 0, sourceIDs: [], privacyLevel: .moderate),
                .init(title: "Available tools", content: request.externalAvailableTools.prefix(24).map { "- \($0.id): \($0.description)" }.joined(separator: "\n"), estimatedChars: 0, sourceIDs: [], privacyLevel: .low),
                .init(title: "Runtime policy", content: "degraded-legacy-grounding", estimatedChars: 0, sourceIDs: [], privacyLevel: .low)
            ].filter { !$0.content.isEmpty }
            let assembled = LegacyPromptAssembler.assemble(baseSystemPrompt: request.baseSystemPrompt, baseUserMessage: request.userMessage, sections: fallbackSections, policy: request.policy)
            return .init(systemPrompt: assembled.systemPrompt, userMessage: assembled.userMessage, grounding: nil, sections: fallbackSections, bridgedTools: request.externalAvailableTools, degradedReasons: degraded, metricsSummary: "degraded", truncationOccurred: assembled.truncationOccurred)
        }

        let output = await build(userMessage: request.userMessage, conversationID: request.conversationID, turnID: request.turnID, history: request.history, modelContext: modelContext, isBackground: request.mode != .foreground, task: request.task, role: request.roleOrSlot)
        var sections = output.sections
        if !request.externalRelevantMemories.isEmpty {
            sections.append(.init(title: "Relevant memories", content: request.externalRelevantMemories.prefix(6).map { "- \($0.content)" }.joined(separator: "\n"), estimatedChars: 0, sourceIDs: ["legacyCallerMemory"], privacyLevel: .moderate))
        }
        let assembled = LegacyPromptAssembler.assemble(baseSystemPrompt: request.baseSystemPrompt, baseUserMessage: request.userMessage, sections: sections, policy: request.policy)
        let tools = output.legacyTools.isEmpty ? request.externalAvailableTools : output.legacyTools
        return .init(systemPrompt: assembled.systemPrompt, userMessage: assembled.userMessage, grounding: output.grounding, sections: sections, bridgedTools: tools, degradedReasons: degraded, metricsSummary: output.metricsSummary, truncationOccurred: assembled.truncationOccurred)
    }
}
