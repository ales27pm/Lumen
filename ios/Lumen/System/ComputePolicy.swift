import Foundation

struct ComputeDecision: Sendable, Equatable {
    let maxTokens: Int
    let allowHeavyRuntime: Bool
}

enum ComputePolicy {
    static func decide(for context: AssistantTurnContext) -> ComputeDecision {
        let thermalLimited = context.thermalState == .serious || context.thermalState == .critical
        let lowPowerLimited = context.lowPowerMode
        let backgroundLimited = !context.isForeground

        if backgroundLimited {
            return ComputeDecision(maxTokens: 256, allowHeavyRuntime: false)
        }
        if thermalLimited || lowPowerLimited {
            return ComputeDecision(maxTokens: 512, allowHeavyRuntime: false)
        }
        return ComputeDecision(maxTokens: 1024, allowHeavyRuntime: true)
    }
}
