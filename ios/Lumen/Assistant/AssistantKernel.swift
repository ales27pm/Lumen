import Foundation

actor AssistantKernel {
    private let router: AssistantRuntimeRouter

    init(router: AssistantRuntimeRouter = .init()) {
        self.router = router
    }

    func selectRuntime(for context: AssistantTurnContext) -> AssistantRuntimeKind {
        router.runtime(for: context)
    }

    func runTextTurn(_ context: AssistantTurnContext) async throws -> String {
        let runtime = router.runtime(for: context)
        let decision = ComputePolicy.decide(for: context)
        let request = TextGenerationRequest(prompt: context.input, systemPrompt: "", maxTokens: decision.maxTokens)

        switch runtime {
        case .foundationModels:
            return try await router.foundation.generate(request: request)
        case .llama:
            return try await router.llama.generate(request: request)
        case .deterministicFallback, .coreML:
            return try await router.fallback.generate(request: request)
        }
    }
}
