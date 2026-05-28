import Foundation

struct AssistantRuntimeRouter {
    let foundation: FoundationModelsRuntimeAdapter
    let llama: LlamaRuntimeAdapter
    let fallback: DeterministicFallbackRuntime
    let coreML: CoreMLRuntimeAdapter

    init(
        foundation: FoundationModelsRuntimeAdapter = .init(),
        llama: LlamaRuntimeAdapter = .init(),
        fallback: DeterministicFallbackRuntime = .init(),
        coreML: CoreMLRuntimeAdapter = .init(modelURL: nil)
    ) {
        self.foundation = foundation
        self.llama = llama
        self.fallback = fallback
        self.coreML = coreML
    }

    func runtime(for context: AssistantTurnContext) -> AssistantRuntimeKind {
        let decision = ComputePolicy.decide(for: context)
        switch context.task {
        case .embedding, .safetyClassification:
            return coreML.isAvailable ? .coreML : .deterministicFallback
        case .backgroundTrigger, .remConsolidation:
            if decision.allowHeavyRuntime, llama.isAvailable { return .llama }
            return .deterministicFallback
        case .chat, .agentPlan, .toolDecision, .summarization, .memoryExtraction, .speechCommandParsing:
            if context.prefersFoundationModels, foundation.isAvailable, decision.allowHeavyRuntime {
                return .foundationModels
            }
            if llama.isAvailable { return .llama }
            return .deterministicFallback
        }
    }
}
