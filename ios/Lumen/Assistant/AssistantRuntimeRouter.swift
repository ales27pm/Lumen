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

    struct Selection: Sendable, Equatable {
        let runtime: AssistantRuntimeKind
        let reason: String
    }

    func selection(for context: AssistantTurnContext) -> Selection {
        let decision = ComputePolicy.decide(for: context)
        switch context.task {
        case .embedding, .safetyClassification:
            return coreML.isAvailable ? .init(runtime: .coreML, reason: "embedding uses CoreML") : .init(runtime: .deterministicFallback, reason: "embedding fallback")
        case .backgroundTrigger, .remConsolidation:
            if decision.allowHeavyRuntime, llama.isAvailable {
                return .init(runtime: .llama, reason: "background heavy runtime allowed")
            }
            return .init(runtime: .deterministicFallback, reason: "background constrained")
        case .chat, .agentPlan, .toolDecision, .summarization, .memoryExtraction, .speechCommandParsing:
            if context.prefersFoundationModels, foundation.isAvailable, decision.allowHeavyRuntime {
                return .init(runtime: .foundationModels, reason: "preferred on-device foundation runtime")
            }
            if llama.isAvailable { return .init(runtime: .llama, reason: "llama available") }
            return .init(runtime: .deterministicFallback, reason: "no capable runtime")
        }
    }

    func runtime(for context: AssistantTurnContext) -> AssistantRuntimeKind {
        selection(for: context).runtime
    }
}
