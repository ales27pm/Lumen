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
}
